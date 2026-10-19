//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation

/// Cross-platform agent memory engine.
///
/// The default path is dependency-free lexical retrieval. Query analysis, semantic embeddings,
/// LLM-based selection, extraction and persistent indexes are all optional, pluggable layers.
actor MemoryEngine {
    var graph: MemoryGraph
    let embedder: (any EmbeddingProvider)?
    let lexicalIndex: any MemoryIndex
    let persistence: (any MemoryPersistence)?
    let queryAnalyzer: any MemoryQueryAnalyzer
    let selector: any MemorySelector
    private let extractor: any MemoryExtractor
    let contextFormatter: any MemoryContextFormatter
    var configuration: MemoryEngineConfiguration
    private var pending: [MemoryCandidate] = []
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    /// Visible-diagnostic sink for semantic embedding failures; defaults to one
    /// redacted ERROR line (see ``MemorySemanticFallbackDiagnostics``). Tests inject
    /// a recorder instead of touching process-global output.
    let semanticFailureReporter: @Sendable (String) -> Void
    /// Write-lock state backing ``transaction(_:)``.
    private var isWriting = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    /// Recall intents, not a stale graph: a checkpoint replays them over the
    /// newest graph while the persistence lock is held.
    var pendingRecallMaintenance: [PendingRecallMaintenance] = []
    /// Graph before the first pending intent; seeds a transactional persistence
    /// with no durable file yet (the live graph would replay that intent twice).
    var pendingRecallBaseGraph: MemoryGraph?
    /// Local state not yet across a persistence boundary: `insert(persist: false)`
    /// has no replayable intent, but `save()` must still commit it. Cleared only
    /// after the complete live graph is saved.
    var needsSave: Bool

    private static let defaultSemanticFailureReporter = MemoryEmbeddingFallback.defaultReporter

    public init(
        graph: MemoryGraph = MemoryGraph(),
        lexicalIndex: any MemoryIndex = BM25MemoryIndex(),
        embedder: (any EmbeddingProvider)? = nil,
        persistence: (any MemoryPersistence)? = nil,
        queryAnalyzer: any MemoryQueryAnalyzer = DirectMemoryQueryAnalyzer(),
        selector: any MemorySelector = TopScoreMemorySelector(),
        extractor: any MemoryExtractor = NoopMemoryExtractor(),
        contextFormatter: any MemoryContextFormatter = BulletMemoryContextFormatter(),
        configuration: MemoryEngineConfiguration = .init(),
        needsSave: Bool = false,
        semanticFailureReporter: @escaping @Sendable (String) -> Void = MemoryEngine.defaultSemanticFailureReporter
    ) {
        self.graph = graph
        self.lexicalIndex = lexicalIndex
        self.embedder = embedder
        self.persistence = persistence
        self.queryAnalyzer = queryAnalyzer
        self.selector = selector
        self.extractor = extractor
        self.contextFormatter = contextFormatter
        self.configuration = configuration
        self.needsSave = needsSave
        self.semanticFailureReporter = semanticFailureReporter
    }

    public static func open(
        persistence: any MemoryPersistence,
        lexicalIndex: any MemoryIndex = BM25MemoryIndex(),
        embedder: (any EmbeddingProvider)? = nil,
        queryAnalyzer: any MemoryQueryAnalyzer = DirectMemoryQueryAnalyzer(),
        selector: any MemorySelector = TopScoreMemorySelector(),
        extractor: any MemoryExtractor = NoopMemoryExtractor(),
        contextFormatter: any MemoryContextFormatter = BulletMemoryContextFormatter(),
        configuration: MemoryEngineConfiguration = .init(),
        semanticFailureReporter: @escaping @Sendable (String) -> Void = MemoryEngine.defaultSemanticFailureReporter
    ) async throws -> MemoryEngine {
        let graph = try await persistence.load()
        return MemoryEngine(
            graph: graph,
            lexicalIndex: lexicalIndex,
            embedder: embedder,
            persistence: persistence,
            queryAnalyzer: queryAnalyzer,
            selector: selector,
            extractor: extractor,
            contextFormatter: contextFormatter,
            configuration: configuration,
            semanticFailureReporter: semanticFailureReporter
        )
    }

    public func snapshot() -> MemoryGraph { graph }

    /// One coherent graph for a read-only store request. `snapshot()` may lag a
    /// graph another process committed, so this reloads the durable graph under
    /// the write lock and replays pending recall maintenance onto the *copy*
    /// only; nothing is persisted and live state is untouched.
    ///
    /// - A dirty engine (deferred `insert(persist: false)`) serves its local graph,
    ///   since reloading would discard that insert.
    /// - A non-transactional persistence has no reload boundary; the local graph
    ///   already contains every pending overlay.
    /// - An ordinary reload failure falls back to the local graph; cancellation and
    ///   an unsupported future graph version stay observable.
    func freshSnapshotForReadOnly() async throws -> MemoryGraph {
        try await withWriteLock { () -> MemoryGraph in
            try Task.checkCancellation()
            guard !needsSave,
                  let reloadPersistence = persistence as? any MemoryReadOnlyReloadPersistence
            else { return graph }
            do {
                var fresh = try await reloadPersistence.reloadReadOnly()
                Self.apply(pendingRecallMaintenance, to: &fresh)
                return fresh
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch let persistenceError as MemoryPersistenceError {
                // A future graph version is not a transient failure: masking it
                // would hide the required upgrade signal.
                throw persistenceError
            } catch {
                // Cancellation may surface as another error type.
                try Task.checkCancellation()
                return graph
            }
        }
    }

    // MARK: - Transactions

    /// Runs one serialized read-modify-write against the graph and commits it
    /// only once persistence has accepted it.
    ///
    /// Actor isolation alone is not enough: every persisting mutation awaits and
    /// actors are reentrant, so read-decide-write sequences could interleave and
    /// drop each other. The body is synchronous under an internal mutex, mutates a
    /// private draft, and the draft becomes the live graph only after the save
    /// succeeded; a failed save or a throwing body leaves the graph unchanged.
    ///
    /// Persistence is skipped when the body left the graph unchanged and no recall
    /// maintenance is pending; a pending batch is itself a durability boundary.
    @discardableResult
    public func transaction<T: Sendable>(
        _ body: @Sendable (inout MemoryGraph) throws -> T
    ) async throws -> T {
        try await withWriteLock {
            // The queued continuation does not observe cancellation, so re-check
            // after the lock is held and before body/save; `withWriteLock`'s
            // `defer` still releases the lock when this throws.
            try Task.checkCancellation()
            let pending = pendingRecallMaintenance
            // A transactional store reloads its file first, which would discard a
            // preceding `insert(persist: false)`; commit that local snapshot instead.
            if needsSave {
                var draft = graph
                let result = try body(&draft)
                try await persist(draft)
                adoptDurable(draft)
                return result
            }
            if let transactionalPersistence = persistence as? any MemoryTransactionalPersistence {
                // Reload inside the persistence lock so the body sees the newest
                // cross-process graph; replay pending intents exactly once (a
                // missing file is seeded with the pre-intent base graph).
                let initialGraph = pendingRecallBaseGraph ?? graph
                let committed = try await transactionalPersistence.transaction(initialGraph: initialGraph) { graph in
                    Self.apply(pending, to: &graph)
                    return try body(&graph)
                }
                // Even a no-op body may have observed a newer graph; keep it locally.
                adoptDurable(committed.graph)
                return committed.result
            }

            // No durable reload boundary: `graph` already contains the pending
            // maintenance, and replaying it would apply every recall twice.
            var draft = graph
            let result = try body(&draft)
            // A pending overlay must become durable even if the body is idempotent.
            guard draft != graph || !pending.isEmpty else { return result }
            try await persist(draft)
            adoptDurable(draft)
            return result
        }
    }

    /// Makes a graph that is now durable the live graph and drops every local
    /// pending state that it supersedes.
    func adoptDurable(_ durable: MemoryGraph) {
        graph = durable
        needsSave = false
        pendingRecallMaintenance.removeAll()
        pendingRecallBaseGraph = nil
    }

    /// Explicit durability boundary for accumulated recall maintenance.
    public func flushRecallMaintenance() async throws {
        try await withWriteLock {
            try await flushPendingRecallMaintenanceLocked()
        }
    }

    /// Serializes `body` against every other transaction on this engine. A plain
    /// `while` loop over a continuation queue: the state is actor-isolated, so a
    /// barging waiter simply re-checks the flag and queues again.
    private func withWriteLock<T>(_ body: () async throws -> T) async throws -> T {
        while isWriting {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writeWaiters.append(continuation)
            }
        }
        isWriting = true
        defer {
            isWriting = false
            if !writeWaiters.isEmpty {
                writeWaiters.removeFirst().resume()
            }
        }
        return try await body()
    }

    @discardableResult
    public func remember(
        _ content: String,
        category: EngineMemoryCategory = .fact,
        tags: [String] = [],
        source: String? = nil,
        trust: TrustLevel = .medium,
        scope: EngineMemoryScope = .project,
        confidence: Float = 1,
        id: String? = nil
    ) async throws -> EngineMemoryEntry {
        let stored = try await embeddedEntry(
            content, operation: "write", id: id, category: category, tags: tags,
            source: source, trust: trust, scope: scope, confidence: confidence
        )
        // The embedding is computed above, outside the lock: only the graph
        // mutation itself has to be serialized.
        try await transaction { $0.addMemory(stored) }
        return stored
    }

    private func embeddedEntry(
        _ content: String,
        operation: String,
        id: String?,
        category: EngineMemoryCategory,
        tags: [String],
        source: String?,
        trust: TrustLevel,
        scope: EngineMemoryScope,
        confidence: Float
    ) async throws -> EngineMemoryEntry {
        let embedded = try await MemoryEmbeddingFallback.embed(
            content,
            with: embedder,
            operation: operation,
            reporter: semanticFailureReporter
        )
        var entry = EngineMemoryEntry(
            id: id,
            category: category,
            content: content,
            tags: tags,
            source: source,
            trust: trust,
            scope: scope,
            embedding: embedded.values,
            embeddingModel: embedded.model,
            confidence: confidence
        )
        entry.refreshSearchText()
        return entry
    }

    /// Runs the configured extractor and stores the memories it returns in one
    /// transaction (a failing save leaves none of them). A no-op with the default
    /// `NoopMemoryExtractor`.
    @discardableResult
    public func learn(from context: String) async throws -> [EngineMemoryEntry] {
        let drafts = try await extractor.extract(from: context)
        var prepared: [EngineMemoryEntry] = []
        for draft in drafts where !draft.content.isEmpty {
            prepared.append(try await embeddedEntry(
                draft.content, operation: "learn", id: nil, category: draft.category,
                tags: draft.tags, source: draft.source, trust: draft.trust,
                scope: draft.scope, confidence: draft.confidence
            ))
        }
        guard !prepared.isEmpty else { return [] }
        let batch = prepared
        try await transaction { graph in
            for entry in batch { graph.addMemory(entry) }
        }
        return batch
    }

    public func extract(from context: String) async throws -> [MemoryDraft] {
        try await extractor.extract(from: context)
    }

    public func insert(_ entry: EngineMemoryEntry, persist: Bool = true) async throws {
        if persist {
            try await transaction { $0.addMemory(entry) }
        } else {
            // Still serialized: an unpersisted insert that landed while another
            // transaction was saving would be overwritten by that commit.
            _ = try await withWriteLock {
                graph.addMemory(entry)
                needsSave = true
            }
        }
    }

    public func forget(id: String) async throws -> EngineMemoryEntry? {
        try await transaction { $0.removeMemory(id: id) }
    }

    /// Automatic recall: retrieve candidates, expand their graph neighborhood and
    /// let the selector pick what to inject. After selection it applies retrieval
    /// maintenance to the live graph and queues the intent for a durable
    /// checkpoint (``flushRecallMaintenance()`` or the checkpoint threshold). For
    /// a lookup that must never mutate or fail on save use
    /// ``searchReadOnlyDetailed(_:scope:)``.
    public func recallDetailed(
        _ prompt: String,
        scope: EngineMemoryScope = .all
    ) async throws -> MemoryRecallResult {
        let (plan, candidates, selected) = try await retrieveAndSelect(prompt, scope: scope)
        // Maintenance is visible in memory at once and recorded as a replayable
        // intent, so it neither clobbers a concurrent write nor becomes
        // un-retryable when persistence is down. `retrieveAndSelect` awaited the
        // selector, so a concurrent `forget`/archive may have landed: the lock
        // re-checks existence, active and scope and records only the survivors.
        let settings = configuration
        let revalidated = try await withWriteLock {
            // Re-check cancellation after acquiring the lock so a timed-out recall
            // cannot record maintenance for a result never delivered.
            try Task.checkCancellation()

            if let transactionalPersistence = persistence as? any MemoryTransactionalPersistence,
               !needsSave {
                // Everything below builds a *proposal* on private values; engine
                // state is untouched before the durable decision (see
                // `adoptMaintenance(after:...)` for the two failure paths).
                let localValid = Self.revalidate(
                    candidates: candidates,
                    selected: selected,
                    against: graph,
                    scope: scope
                )
                let (draft, proposal) = recallProposal(localValid, scope: scope, settings: settings)
                let shouldCheckpoint = proposal.pending.count >= settings.recallMaintenanceCheckpointSize
                // Last cancellable point before a durable transaction.
                try Task.checkCancellation()
                let committed: (result: RevalidatedRecall, graph: MemoryGraph, didChange: Bool)
                do {
                    committed = try await transactionalPersistence.transaction(
                        initialGraph: proposal.initialGraph
                    ) { durable in
                        // Inside the persistence lock, before any durable mutation:
                        // aborting here discards the transaction without writing.
                        try Task.checkCancellation()
                        // Below the threshold the durable draft stays untouched so a
                        // recall cannot save every time; only a checkpoint replaces it.
                        // Revalidate against the overlay: the durable graph plus all
                        // local intents.
                        var overlay = durable
                        Self.apply(proposal.pending, to: &overlay)
                        let durableValid = Self.revalidate(
                            candidates: candidates,
                            selected: selected,
                            against: overlay,
                            scope: scope
                        )
                        if shouldCheckpoint {
                            durable = overlay
                        }
                        return durableValid
                    }
                } catch {
                    adoptMaintenance(after: error, draftGraph: draft, proposal: proposal)
                    throw error
                }
                // A below-threshold transaction does not save but can suspend on the
                // process lock; do not adopt its overlay for a cancelled caller.
                if !committed.didChange {
                    try Task.checkCancellation()
                }
                // Commit point: nothing failable may run from here on.
                if committed.didChange {
                    adoptDurable(committed.graph)
                } else {
                    // Newest durable graph without a checkpoint: overlay every
                    // pending intent for local reads and record the proposal.
                    graph = committed.graph
                    Self.apply(proposal.pending, to: &graph)
                    pendingRecallMaintenance = proposal.pending
                    pendingRecallBaseGraph = proposal.baseGraph
                }
                return committed.result
            }

            let valid = Self.revalidate(
                candidates: candidates,
                selected: selected,
                against: graph,
                scope: scope
            )
            let (draft, proposal) = recallProposal(valid, scope: scope, settings: settings)
            if proposal.pending.count >= settings.recallMaintenanceCheckpointSize {
                // Last cancellable point before the durable write.
                try Task.checkCancellation()
                do {
                    try await commitRecallMaintenance(
                        draftGraph: draft,
                        pending: proposal.pending,
                        baseGraph: proposal.baseGraph
                    )
                } catch {
                    adoptMaintenance(after: error, draftGraph: draft, proposal: proposal)
                    throw error
                }
            } else {
                // Below the threshold no persistence boundary exists: this is the
                // last cancellation point before the maintenance becomes visible.
                try Task.checkCancellation()
                graph = draft
                pendingRecallMaintenance = proposal.pending
                pendingRecallBaseGraph = proposal.baseGraph
            }
            return valid
        }
        return MemoryRecallResult(
            plan: plan,
            candidates: revalidated.candidates,
            selected: revalidated.selected
        )
    }

    public func recall(_ query: String, scope: EngineMemoryScope = .all) async throws -> [MemoryCandidate] {
        try await recallDetailed(query, scope: scope).selected
    }

    /// Returns the exact memory block that can be injected into a model prompt.
    /// An empty string means the analyzer/selector found nothing worth injecting.
    public func context(for prompt: String, scope: EngineMemoryScope = .all) async throws -> String {
        let result = try await recallDetailed(prompt, scope: scope)
        return contextFormatter.format(result.selected)
    }

    /// Starts the complete analyze -> retrieve -> select pipeline in a background task and exposes
    /// its selected memories to the next agent turn.
    public func submitContext(_ context: String, scope: EngineMemoryScope = .all) {
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.recall(context, scope: scope)
                await self.storePending(result)
            } catch {
                // Memory lookup should never break the host agent's current turn.
            }
            await self.finishBackgroundTask(token)
        }
        backgroundTasks[token] = task
    }

    public func takePending() -> [MemoryCandidate] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }

    public func waitForBackgroundTasks() async {
        let tasks = Array(backgroundTasks.values)
        for task in tasks { await task.value }
    }

    /// Persists the current graph and treats the call as a durability
    /// boundary for any automatic-recall maintenance accumulated in memory.
    /// A failed save leaves those intents queued so a later save/flush can
    /// retry them.
    public func save() async throws {
        try await withWriteLock {
            // Do not materialize a pristine graph. Conversely, a dirty local
            // graph cannot go through a transactional reload: that would lose
            // deferred inserts before they reach disk.
            if needsSave {
                try await persist(graph)
                adoptDurable(graph)
            } else if !pendingRecallMaintenance.isEmpty {
                try await flushPendingRecallMaintenanceLocked()
            }
        }
    }

    private func storePending(_ result: [MemoryCandidate]) {
        pending = result
    }

    private func finishBackgroundTask(_ token: UUID) {
        backgroundTasks[token] = nil
    }

    func persist(_ graph: MemoryGraph) async throws {
        if let persistence { try await persistence.save(graph) }
    }
}
