import Foundation

enum MemoryIntelligenceFailurePolicy: String, Codable, Sendable, Equatable {
    /// Fall back to direct lexical retrieval / score-based selection if an analyzer or selector fails.
    case fallback
    /// Surface intelligence-layer errors to the caller.
    case propagate
}

struct MemoryEngineConfiguration: Sendable, Equatable {
    public var similarityThreshold: Float
    public var maxSemanticHits: Int
    public var maxLexicalHits: Int
    public var maxAnalyzedQueries: Int
    public var maxSemanticQueries: Int
    public var maxCandidateResults: Int
    public var maxDepth: Int
    public var maxResults: Int
    public var edgeDecay: Float
    public var rrfRankConstant: Float
    public var boostSelectedBy: Float
    public var decayRejectedBy: Float
    public var strengthenCoRelevantLinks: Bool
    public var includeOriginalQuery: Bool
    public var intelligenceFailurePolicy: MemoryIntelligenceFailurePolicy
    /// Number of automatic recalls whose derived maintenance may stay in
    /// memory before a durable checkpoint. Explicit mutations checkpoint them
    /// as part of their own immediate transaction.
    public var recallMaintenanceCheckpointSize: Int

    public init(
        similarityThreshold: Float = 0.4,
        maxSemanticHits: Int = 10,
        maxLexicalHits: Int = 10,
        maxAnalyzedQueries: Int = 4,
        maxSemanticQueries: Int = 1,
        maxCandidateResults: Int = 20,
        maxDepth: Int = 2,
        maxResults: Int = 8,
        edgeDecay: Float = 0.7,
        rrfRankConstant: Float = 60,
        boostSelectedBy: Float = 0.02,
        decayRejectedBy: Float = 0.01,
        strengthenCoRelevantLinks: Bool = true,
        includeOriginalQuery: Bool = true,
        intelligenceFailurePolicy: MemoryIntelligenceFailurePolicy = .fallback,
        recallMaintenanceCheckpointSize: Int = 4
    ) {
        self.similarityThreshold = similarityThreshold
        self.maxSemanticHits = maxSemanticHits
        self.maxLexicalHits = maxLexicalHits
        self.maxAnalyzedQueries = max(1, maxAnalyzedQueries)
        self.maxSemanticQueries = max(0, maxSemanticQueries)
        self.maxCandidateResults = max(1, maxCandidateResults)
        self.maxDepth = max(0, maxDepth)
        self.maxResults = max(0, maxResults)
        self.edgeDecay = edgeDecay
        self.rrfRankConstant = rrfRankConstant
        self.boostSelectedBy = boostSelectedBy
        self.decayRejectedBy = decayRejectedBy
        self.strengthenCoRelevantLinks = strengthenCoRelevantLinks
        self.includeOriginalQuery = includeOriginalQuery
        self.intelligenceFailurePolicy = intelligenceFailurePolicy
        self.recallMaintenanceCheckpointSize = max(1, recallMaintenanceCheckpointSize)
    }
}

/// Visible, redacted diagnostic emission for semantic embedding failures.
///
/// ``ZenLogger`` alone cannot satisfy "print a visible error": it is opt-in
/// (`ZENCODE_LOG`) and disabled by default. This helper therefore always
/// writes one redacted ERROR line to the preserved stderr descriptor
/// (``AgentOutput/standardError``, never stdout) and additionally feeds the
/// opt-in diagnostic file — unless the logger already targets stderr, in which
/// case a duplicate line is avoided. `stderrWriter` and `loggerDestination`
/// are seams so tests can prove the emission and the dedup decision without
/// touching the process-global stderr or the global logger configuration.
enum MemorySemanticFallbackDiagnostics {
    /// The visible line: same category/level/redaction contract as the
    /// diagnostic channel, with a trailing newline for the raw descriptor.
    static func visibleLine(message: String) -> String {
        ZenLogger.formattedMessage(level: .error, category: .memory, message: message) + "\n"
    }

    static func emitVisibleError(
        message: String,
        loggerDestination: String? = ZenLogger.destinationDescription,
        stderrWriter: ((Data) throws -> Void)? = nil
    ) {
        let data = Data(visibleLine(message: message).utf8)
        if let stderrWriter {
            try? stderrWriter(data)
        } else {
            try? AgentOutput.standardError.write(contentsOf: data)
        }
        if shouldDuplicateToZenLogger(destinationDescription: loggerDestination) {
            ZenLogger.error(.memory, message)
        }
    }

    /// Whether the diagnostic-file channel should also receive the line.
    /// `true` when the logger is disabled (the `ZenLogger.error` call is then
    /// a no-op) or points at a file; `false` only when it already writes to
    /// stderr, so the visible line is not duplicated.
    static func shouldDuplicateToZenLogger(destinationDescription: String?) -> Bool {
        destinationDescription != "stderr"
    }

    /// Maps an embedding failure to a short, secret-free summary for the
    /// diagnostic channel. By construction it never includes the query or
    /// memory text, embedding vectors, endpoint URLs, HTTP response bodies
    /// (which can echo input or carry credentials), or API keys — only stable
    /// status/type information that is safe to log.
    static func embeddingFailureSummary(_ error: (any Error)?) -> String {
        guard let error else { return "unknown" }
        if let embeddingError = error as? OpenAICompatibleEmbeddingError {
            switch embeddingError {
            case .httpStatus(let status, _):
                return "httpStatus \(status)"
            case .emptyEmbedding:
                return "emptyEmbedding"
            case .responseBodyTooLarge:
                return "responseBodyTooLarge"
            }
        }
        if let urlError = error as? URLError {
            return "transportError \(urlError.code.rawValue)"
        }
        return "\(type(of: error))"
    }

    /// Builds the redacted diagnostic used when a mutation keeps the text but
    /// drops its unavailable vector. The operation name is a fixed call-site
    /// label; callers must not pass user content here.
    static func mutationFallbackMessage(
        operation: String,
        error: (any Error)?
    ) -> String {
        "semantic embedding \(operation) failed (\(embeddingFailureSummary(error))); continuing without vector with BM25-only retrieval."
    }
}

/// Best-effort embedding seam for memory mutations.
///
/// Embeddings improve ranking but are never required for durable memory. A
/// provider outage therefore degrades an entry to its text/search index while
/// preserving the original operation's cancellation semantics. The caller
/// supplies the diagnostic sink so engine-level tests can capture messages and
/// product paths can keep the always-visible stderr behaviour.
enum MemoryEmbeddingFallback {
    struct Result: Sendable {
        let values: [Float]?
        let model: String?
    }

    static let defaultReporter: @Sendable (String) -> Void = { message in
        MemorySemanticFallbackDiagnostics.emitVisibleError(message: message)
    }

    static func embed(
        _ text: String,
        with embedder: (any EmbeddingProvider)?,
        operation: String,
        reporter: @escaping @Sendable (String) -> Void = MemoryEmbeddingFallback.defaultReporter
    ) async throws -> Result {
        guard let embedder else {
            return Result(values: nil, model: nil)
        }

        do {
            return Result(
                values: try await embedder.embed(text),
                model: embedder.modelID
            )
        } catch let cancellation as CancellationError {
            // A caller cancellation must not be mistaken for an endpoint
            // outage and silently commit a mutation.
            throw cancellation
        } catch {
            // Some transports surface cancellation as a different error type
            // (for example URLError.cancelled). Preserve it whenever the task
            // is actually cancelled, while treating an ordinary endpoint
            // failure as a BM25-only degradation.
            try Task.checkCancellation()
            reporter(
                MemorySemanticFallbackDiagnostics.mutationFallbackMessage(
                    operation: operation,
                    error: error
                )
            )
            return Result(values: nil, model: nil)
        }
    }
}

/// Cross-platform agent memory engine.
///
/// The default path is dependency-free lexical retrieval. Query analysis, semantic embeddings,
/// LLM-based selection, extraction and persistent indexes are all optional, pluggable layers.
actor MemoryEngine {
    private var graph: MemoryGraph
    private let embedder: (any EmbeddingProvider)?
    private let lexicalIndex: any MemoryIndex
    private let persistence: (any MemoryPersistence)?
    private let queryAnalyzer: any MemoryQueryAnalyzer
    private let selector: any MemorySelector
    private let extractor: any MemoryExtractor
    private let contextFormatter: any MemoryContextFormatter
    private var configuration: MemoryEngineConfiguration
    private var pending: [MemoryCandidate] = []
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    /// Visible-diagnostic sink for semantic embedding failures during
    /// recall/search and best-effort memory mutations. Defaults to an
    /// always-visible redacted ERROR line on the preserved stderr descriptor
    /// (plus the opt-in ZenLogger file channel
    /// unless it already targets stderr); tests inject a deterministic
    /// recorder instead of touching process-global stderr or the logger
    /// configuration.
    private let semanticFailureReporter: @Sendable (String) -> Void
    /// Write-lock state backing ``transaction(_:)``. See that method for why
    /// actor isolation alone is not enough.
    private var isWriting = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    /// Store recall intents, not a stale graph: a checkpoint replays them over
    /// the newest graph while the transactional persistence lock is held.
    private var pendingRecallMaintenance: [PendingRecallMaintenance] = []
    /// Seed used only when a transactional persistence has no durable file yet.
    /// It must represent the graph before the first pending intent; using the
    /// live graph here would replay that intent twice on a cold checkpoint.
    private var pendingRecallBaseGraph: MemoryGraph?

    /// Default reporter: always emits a redacted ERROR line on the preserved
    /// stderr descriptor (visible even with `ZENCODE_LOG` off) and feeds the
    /// opt-in diagnostic file unless it already targets stderr.
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

    public func setConfiguration(_ configuration: MemoryEngineConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Transactions

    /// Runs one serialized read-modify-write against the graph and commits it
    /// only once persistence has accepted it.
    ///
    /// This is the atomic primitive every mutation goes through, and it exists
    /// because actor isolation alone provides neither of the two properties a
    /// host needs:
    ///
    /// 1. **Serialization.** Every persisting mutation contains an `await`, and
    ///    actors are reentrant across suspension points. A caller that reads the
    ///    graph, decides something from it and writes the result back — a
    ///    deduplicating write, an in-place content update, an archive — can
    ///    therefore interleave with another such sequence and silently drop it.
    ///    A transaction body is synchronous and runs under an internal mutex, so
    ///    it reads and mutates a graph no one else can touch in between.
    /// 2. **Atomicity with respect to persistence.** The body mutates a private
    ///    draft; the draft is saved first and becomes the live graph only when
    ///    the save succeeded. A failed save therefore leaves the in-memory graph
    ///    exactly as it was instead of silently diverging from disk, and a body
    ///    that throws changes nothing at all.
    ///
    /// Persistence is skipped when the body left the graph unchanged and there
    /// is no pending recall maintenance, so a look-only or ordinary no-op
    /// transaction never touches the disk. A pending maintenance batch is
    /// itself a durability boundary for an explicit transaction.
    @discardableResult
    public func transaction<T: Sendable>(
        _ body: @Sendable (inout MemoryGraph) throws -> T
    ) async throws -> T {
        try await withWriteLock {
            // A task may have been cancelled while it was parked waiting for the
            // write lock: the continuation above is the non-throwing flavour and
            // does not observe cancellation, so without this re-check such a task
            // would resume, acquire the lock and commit anyway. The check sits
            // *after* the lock is held and *before* the body/save, and the
            // `defer` in `withWriteLock` still releases the lock when this throws,
            // so a cancelled waiter neither commits nor strands the lock.
            try Task.checkCancellation()
            let pending = pendingRecallMaintenance
            if let transactionalPersistence = persistence as? any MemoryTransactionalPersistence {
                // A separate process may have committed since this engine last
                // wrote. Reloading inside the persistence lock makes our body
                // operate on that newest graph rather than overwriting it.
                // The durable graph does not include the in-memory pending
                // maintenance, so replay those intents exactly once here. If
                // the file is still absent, the saved base is the graph from
                // before the first pending intent rather than the live overlay.
                let initialGraph = pendingRecallBaseGraph ?? graph
                let committed = try await transactionalPersistence.transaction(initialGraph: initialGraph) { graph in
                    Self.apply(pending, to: &graph)
                    return try body(&graph)
                }
                // Even a no-op body may have observed another process's newer
                // graph; retain that reload locally without causing a save.
                graph = committed.graph
                pendingRecallMaintenance.removeAll()
                pendingRecallBaseGraph = nil
                return committed.result
            }

            // Non-transactional persistence has no durable reload boundary:
            // `graph` already contains the pending maintenance as its visible
            // state. Start the draft from it directly; replaying the intents
            // here would apply every recall twice when an explicit mutation
            // absorbs the batch.
            var draft = graph
            let result = try body(&draft)
            // A pending recall overlay is already visible in `graph`; an
            // explicit transaction must still make it durable even when its
            // own body is idempotent.
            guard draft != graph || !pending.isEmpty else { return result }
            try await persist(draft)
            graph = draft
            pendingRecallMaintenance.removeAll()
            pendingRecallBaseGraph = nil
            return result
        }
    }

    /// Explicit durability boundary for accumulated automatic-recall
    /// maintenance. Read-only search never invokes this method.
    public func flushRecallMaintenance() async throws {
        try await withWriteLock {
            try await flushPendingRecallMaintenanceLocked()
        }
    }

    /// Serializes `body` against every other transaction on this engine.
    ///
    /// A plain `while` loop over a continuation queue rather than a semaphore:
    /// the state is already actor-isolated, so the loop re-checks the flag after
    /// each resumption and a barging waiter simply queues again.
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
        let embedded = try await MemoryEmbeddingFallback.embed(
            content,
            with: embedder,
            operation: "write",
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
        let stored = entry
        // The embedding is computed above, outside the lock: only the graph
        // mutation itself has to be serialized.
        try await transaction { $0.addMemory(stored) }
        return stored
    }

    /// Runs the configured extractor and stores the durable memories it returns.
    /// With the default `NoopMemoryExtractor`, this method is a no-op.
    ///
    /// The whole batch is stored in one transaction, so a failing save leaves
    /// none of it behind rather than half of it.
    @discardableResult
    public func learn(from context: String) async throws -> [EngineMemoryEntry] {
        let drafts = try await extractor.extract(from: context)
        var prepared: [EngineMemoryEntry] = []
        prepared.reserveCapacity(drafts.count)
        for draft in drafts where !draft.content.isEmpty {
            let embedded = try await MemoryEmbeddingFallback.embed(
                draft.content,
                with: embedder,
                operation: "learn",
                reporter: semanticFailureReporter
            )
            var entry = EngineMemoryEntry(
                id: nil,
                category: draft.category,
                content: draft.content,
                tags: draft.tags,
                source: draft.source,
                trust: draft.trust,
                scope: draft.scope,
                embedding: embedded.values,
                embeddingModel: embedded.model,
                confidence: draft.confidence
            )
            entry.refreshSearchText()
            prepared.append(entry)
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
            _ = try await withWriteLock { graph.addMemory(entry) }
        }
    }

    public func forget(id: String) async throws -> EngineMemoryEntry? {
        try await transaction { $0.removeMemory(id: id) }
    }

    public func tag(memoryID: String, with tag: String) async throws {
        try await transaction { $0.addTag(tag, to: memoryID) }
    }

    public func link(from: String, to: String, weight: Float = 0.8) async throws {
        try await transaction { $0.linkMemories(from: from, to: to, weight: weight) }
    }

    public func supersede(newerID: String, olderID: String) async throws {
        try await transaction { $0.supersede(newerID: newerID, olderID: olderID) }
    }

    public func contradict(_ firstID: String, _ secondID: String) async throws {
        try await transaction { $0.markContradiction(firstID, secondID) }
    }

    public func reinforce(id: String, sessionID: String, messageIndex: Int) async throws {
        try await transaction { graph in
            guard var memory = graph.memories[id] else { return }
            memory.reinforce(sessionID: sessionID, messageIndex: messageIndex)
            graph.memories[id] = memory
        }
    }

    /// Runs only the query-planning stage. Useful for debugging or for host agents that want
    /// to inspect whether a memory lookup will happen before executing it.
    public func analyze(_ prompt: String) async throws -> MemoryQueryPlan {
        try await analyzeWithPolicy(prompt)
    }

    /// Retrieves candidate memories, expands their graph neighborhood, then lets the configured
    /// selector decide which memories are safe and useful to inject into the main agent context.
    ///
    /// This is the *automatic* recall path: after selection it applies
    /// retrieval maintenance to the live in-memory graph immediately, then
    /// queues the maintenance intent for a durable checkpoint. Explicitly call
    /// ``flushRecallMaintenance()`` (or cross an automatic checkpoint threshold)
    /// to persist it. For an explicitly read-only lookup that must never mutate
    /// the graph or fail on a save error, use
    /// ``searchReadOnlyDetailed(_:scope:)`` instead.
    public func recallDetailed(
        _ prompt: String,
        scope: EngineMemoryScope = .all
    ) async throws -> MemoryRecallResult {
        let (plan, candidates, selected) = try await retrieveAndSelect(prompt, scope: scope)
        // Retrieval maintenance is immediately visible in memory and records a
        // replayable intent for the next checkpoint, so it neither clobbers a
        // concurrent write nor becomes un-retryable when persistence is down.
        //
        // **Re-validation.** `retrieveAndSelect` built its candidates and
        // awaited the selector; a concurrent `forget` or archive can land in
        // that suspension window. The maintenance lock re-checks existence,
        // active and scope, then records only the survivors for replay.
        let settings = configuration
        let revalidated = try await withWriteLock {
            // `withWriteLock` uses a non-throwing continuation while queued;
            // re-check cancellation after acquiring the lock so a timed-out
            // recall cannot mutate maintenance for a result never delivered.
            try Task.checkCancellation()

            if let transactionalPersistence = persistence as? any MemoryTransactionalPersistence {
                // Everything below builds a *proposal* on private values: engine
                // state (`graph`, `pendingRecallMaintenance`,
                // `pendingRecallBaseGraph`) is never touched before the durable
                // decision. That is what makes the failure paths meaningful —
                // see `adoptMaintenance(after:...)` for the two of them.
                let localValid = Self.revalidate(
                    candidates: candidates,
                    selected: selected,
                    against: graph,
                    scope: scope
                )
                var draft = graph
                Self.maintainAfterRetrieval(
                    &draft,
                    all: localValid.candidates,
                    selected: localValid.selected,
                    configuration: settings
                )
                let proposal = proposedMaintenance(
                    adding: PendingRecallMaintenance(
                        candidateIDs: localValid.candidates.map(\.memory.id),
                        selectedIDs: Set(localValid.selected.map(\.memory.id)),
                        scope: scope,
                        configuration: settings
                    )
                )
                let shouldCheckpoint = proposal.pending.count >= settings.recallMaintenanceCheckpointSize
                // Last cancellable point before a durable transaction begins.
                try Task.checkCancellation()
                let committed: (result: RevalidatedRecall, graph: MemoryGraph, didChange: Bool)
                do {
                    committed = try await transactionalPersistence.transaction(
                        initialGraph: proposal.initialGraph
                    ) { durable in
                        // Inside the persistence lock but before any durable
                        // mutation: aborting here makes the store discard the
                        // transaction without writing.
                        try Task.checkCancellation()
                        // Build the pending overlay separately. Leaving the durable
                        // draft untouched below the threshold guarantees that this
                        // read/revalidation transaction cannot accidentally save on
                        // every recall; only a real checkpoint replaces it.
                        var overlay = durable
                        Self.apply(proposal.pending, to: &overlay)
                        // Replay all local intents over the graph loaded under the
                        // process-wide lock, then validate the result that callers
                        // will receive against that same durable state.
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
                // A below-threshold transaction deliberately does not save.
                // It can nevertheless suspend while acquiring the process lock,
                // so do not adopt its local overlay for a caller cancelled in
                // that window.
                if !committed.didChange {
                    try Task.checkCancellation()
                }
                // Commit point. Nothing failable may run from here on, so the
                // engine can never report an error for state that is already
                // durable.
                if committed.didChange {
                    graph = committed.graph
                    pendingRecallMaintenance.removeAll()
                    pendingRecallBaseGraph = nil
                } else {
                    // The lock gave us the newest durable graph without a
                    // checkpoint; overlay every pending intent for local reads
                    // and record the proposal as the new pending batch.
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
            var draft = graph
            Self.maintainAfterRetrieval(
                &draft,
                all: valid.candidates,
                selected: valid.selected,
                configuration: settings
            )
            let proposal = proposedMaintenance(
                adding: PendingRecallMaintenance(
                    candidateIDs: valid.candidates.map(\.memory.id),
                    selectedIDs: Set(valid.selected.map(\.memory.id)),
                    scope: scope,
                    configuration: settings
                )
            )
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
                // No persistence boundary exists below the checkpoint threshold;
                // this is consequently the last cancellation point before the
                // proposed maintenance becomes visible in the engine.
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

    /// Read-only retrieval that performs the exact same analyze → retrieve →
    /// select pipeline as ``recallDetailed(_:)`` but skips retrieval maintenance
    /// and never touches persistence.
    ///
    /// Use this for explicitly read-only lookups such as `memory.search`, where
    /// mutating `retrievalCount`/`confidence`/links — or failing because a save
    /// errored — would be a surprising side effect of a query. The automatic
    /// recall path (``recallDetailed(_:)`` / ``context(for:)``) keeps its
    /// transactional maintenance unchanged.
    public func searchReadOnlyDetailed(
        _ prompt: String,
        scope: EngineMemoryScope = .all
    ) async throws -> MemoryRecallResult {
        let (plan, candidates, selected) = try await retrieveAndSelect(prompt, scope: scope)
        return MemoryRecallResult(plan: plan, candidates: candidates, selected: selected)
    }

    /// Read-only retrieval returning only the selected candidates.
    ///
    /// Convenience for ``searchReadOnlyDetailed(_:scope:)`` when callers need
    /// only the memories the selector accepted, with no maintenance side
    /// effects and no persistence dependency.
    public func searchReadOnly(
        _ query: String,
        scope: EngineMemoryScope = .all
    ) async throws -> [MemoryCandidate] {
        try await searchReadOnlyDetailed(query, scope: scope).selected
    }

    /// The shared analyze → retrieve → select core used by both the
    /// maintenance-bearing ``recallDetailed(_:)`` and the maintenance-free
    /// ``searchReadOnlyDetailed(_:scope:)``.
    ///
    /// Performs no mutation and no persistence: it reads the graph, runs the
    /// index/embedder/cascade pipeline, and returns what the selector accepts.
    /// The only difference between the two public callers is whether the
    /// resulting maintenance transaction runs afterwards.
    private func retrieveAndSelect(
        _ prompt: String,
        scope: EngineMemoryScope
    ) async throws -> (plan: MemoryQueryPlan, candidates: [MemoryCandidate], selected: [MemoryCandidate]) {
        let plan = try await analyzeWithPolicy(prompt)
        guard plan.shouldRecall, configuration.maxResults > 0 else {
            return (plan, [], [])
        }

        let activeMemories = Array(graph.memories.values)
        let queries = retrievalQueries(from: plan, originalPrompt: prompt)
        guard !queries.isEmpty else {
            return (plan, [], [])
        }

        var rankings: [[ScoredMemoryID]] = []
        rankings.reserveCapacity(queries.count + configuration.maxSemanticQueries + 1)

        for query in queries {
            let lexical = try await lexicalIndex.search(
                query: query,
                memories: activeMemories,
                scope: scope,
                limit: configuration.maxLexicalHits
            )
            if !lexical.isEmpty { rankings.append(lexical) }
        }

        let metadata = MemorySearch.metadataRanking(
            memories: activeMemories,
            tags: plan.tags,
            entities: plan.entities,
            scope: scope,
            limit: configuration.maxLexicalHits
        )
        if !metadata.isEmpty { rankings.append(metadata) }

        if let embedder, configuration.maxSemanticQueries > 0 {
            let semanticQueries = Array(queries.prefix(configuration.maxSemanticQueries))
            var semanticFailures = 0
            var firstFailure: (any Error)?
            for query in semanticQueries {
                do {
                    let queryEmbedding = try await embedder.embed(query)
                    let semantic = MemorySearch.semantic(
                        graph: graph,
                        queryEmbedding: queryEmbedding,
                        modelID: embedder.modelID,
                        scope: scope,
                        threshold: configuration.similarityThreshold,
                        limit: configuration.maxSemanticHits
                    )
                    if !semantic.isEmpty { rankings.append(semantic) }
                } catch let cancellation as CancellationError {
                    // Cancellation is not an endpoint failure: keep it
                    // observable so callers can still stop a cancelled recall.
                    throw cancellation
                } catch {
                    // A cancellation that surfaced as another error type (for
                    // example `URLError.cancelled`) must not be degraded into
                    // a BM25 fallback.
                    try Task.checkCancellation()
                    // The lexical/BM25 rankings above are already computed, so
                    // an embedding-endpoint failure must not fail the whole
                    // retrieval: report it through the configured reporter
                    // (always-visible stderr line by default) and continue
                    // with BM25-only results.
                    semanticFailures += 1
                    if firstFailure == nil { firstFailure = error }
                }
            }
            if semanticFailures > 0 {
                // Visible, redacted diagnostic. Never include the query text,
                // embedding vectors, endpoint URLs, HTTP response bodies
                // (which can echo input or carry credentials), or API keys.
                semanticFailureReporter(
                    "semantic embedding retrieval failed (\(Self.embeddingFailureSummary(firstFailure))); continuing with BM25-only results (failedQueries=\(semanticFailures)/\(semanticQueries.count))."
                )
            }
        }

        let seedLimit = max(configuration.maxCandidateResults, configuration.maxLexicalHits)
        let seeds: [ScoredMemoryID]
        if rankings.count == 1 {
            seeds = Array(rankings[0].prefix(seedLimit))
        } else {
            seeds = MemorySearch.reciprocalRankFusion(
                rankedLists: rankings,
                rankConstant: configuration.rrfRankConstant,
                limit: seedLimit
            )
        }

        guard !seeds.isEmpty else {
            return (plan, [], [])
        }

        // The cascade reads the graph, but `MemoryGraph` exposes it as
        // `mutating` because it counts retrievals. Run it on a local copy so
        // this shared core never mutates the live graph: the counter is folded
        // into the maintenance transaction in `recallDetailed` instead of being
        // written to the live graph outside the write lock, where a concurrent
        // commit would silently drop it. `searchReadOnly` simply discards the
        // copy.
        var traversal = graph
        let cascaded = traversal.cascadeRetrieve(
            seeds: seeds,
            maxDepth: configuration.maxDepth,
            maxResults: configuration.maxCandidateResults,
            edgeDecay: configuration.edgeDecay,
            scope: scope
        )

        let candidates = cascaded.compactMap { item -> MemoryCandidate? in
            guard let memory = graph.memories[item.id], memory.active else { return nil }
            return MemoryCandidate(memory: memory, score: item.score * memory.effectiveConfidence())
        }.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.memory.id < rhs.memory.id }
            return lhs.score > rhs.score
        }

        let selected = try await selectWithPolicy(context: prompt, candidates: candidates)
        return (plan, candidates, selected)
    }

    private static func embeddingFailureSummary(_ error: (any Error)?) -> String {
        MemorySemanticFallbackDiagnostics.embeddingFailureSummary(error)
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
            if pendingRecallMaintenance.isEmpty {
                try await persist(graph)
            } else {
                try await flushPendingRecallMaintenanceLocked()
            }
        }
    }

    private func retrievalQueries(from plan: MemoryQueryPlan, originalPrompt: String) -> [String] {
        var values = Array(plan.queries.prefix(configuration.maxAnalyzedQueries))
        if configuration.includeOriginalQuery {
            values.append(originalPrompt)
        }
        var seen = Set<String>()
        return values.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

    private func analyzeWithPolicy(_ prompt: String) async throws -> MemoryQueryPlan {
        do {
            return try await queryAnalyzer.analyze(prompt)
        } catch {
            switch configuration.intelligenceFailurePolicy {
            case .fallback:
                return .direct(prompt)
            case .propagate:
                throw error
            }
        }
    }

    private func selectWithPolicy(
        context: String,
        candidates: [MemoryCandidate]
    ) async throws -> [MemoryCandidate] {
        do {
            let proposed = try await selector.select(
                context: context,
                candidates: candidates,
                limit: configuration.maxResults
            )
            let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.memory.id, $0) })
            var seen = Set<String>()
            return proposed.compactMap { candidate in
                let id = candidate.memory.id
                guard seen.insert(id).inserted else { return nil }
                return byID[id]
            }.prefix(configuration.maxResults).map { $0 }
        } catch {
            switch configuration.intelligenceFailurePolicy {
            case .fallback:
                return Array(candidates.prefix(configuration.maxResults))
            case .propagate:
                throw error
            }
        }
    }

    private func storePending(_ result: [MemoryCandidate]) {
        pending = result
    }

    private func finishBackgroundTask(_ token: UUID) {
        backgroundTasks[token] = nil
    }

    /// Re-validated candidate lists returned from inside the maintenance
    /// transaction so the caller can build the final ``MemoryRecallResult``
    /// from the same filtered set maintenance operated on.
    private struct RevalidatedRecall: Sendable {
        let candidates: [MemoryCandidate]
        let selected: [MemoryCandidate]
    }

    /// Filters retrieved candidates against the *current* draft graph state.
    ///
    /// Called synchronously inside the maintenance transaction, after the
    /// selector `await` has resumed. A concurrent `forget` (entry removed) or
    /// archive (entry deactivated or scope-changed) that landed during that
    /// window makes a previously valid candidate stale. This drops any
    /// candidate whose ID is gone, inactive, or outside the requested scope,
    /// and refreshes surviving payloads from that current graph.
    private static func revalidate(
        candidates: [MemoryCandidate],
        selected: [MemoryCandidate],
        against graph: MemoryGraph,
        scope: EngineMemoryScope
    ) -> RevalidatedRecall {
        func refreshed(_ candidate: MemoryCandidate) -> MemoryCandidate? {
            guard let memory = graph.memories[candidate.memory.id],
                  memory.active,
                  MemorySearch.scopeAllows(memory.scope, requested: scope) else {
                return nil
            }
            // Retrieval happened before the durable reload. Preserve the score
            // computed for that query, but return the current persisted entry so
            // cross-process updates are visible to the caller.
            return MemoryCandidate(memory: memory, score: candidate.score)
        }
        return RevalidatedRecall(
            candidates: candidates.compactMap(refreshed),
            selected: selected.compactMap(refreshed)
        )
    }

    private static func maintainAfterRetrieval(
        _ graph: inout MemoryGraph,
        all: [MemoryCandidate],
        selected: [MemoryCandidate],
        configuration: MemoryEngineConfiguration
    ) {
        // Kept here rather than in `cascadeRetrieve`, which now runs on a copy:
        // this is the single place where a retrieval reaches the live graph.
        graph.metadata.retrievalCount &+= 1
        let selectedIDs = Set(selected.map(\.memory.id))
        for candidate in all {
            guard var memory = graph.memories[candidate.memory.id] else { continue }
            if selectedIDs.contains(memory.id) {
                memory.boostConfidence(by: configuration.boostSelectedBy)
            } else {
                memory.decayConfidence(by: configuration.decayRejectedBy)
            }
            graph.memories[memory.id] = memory
        }

        guard configuration.strengthenCoRelevantLinks, selected.count >= 2 else { return }
        for i in 0..<(selected.count - 1) {
            for j in (i + 1)..<selected.count {
                let lhs = selected[i].memory.id
                let rhs = selected[j].memory.id
                graph.linkMemories(from: lhs, to: rhs, weight: 0.7)
                graph.linkMemories(from: rhs, to: lhs, weight: 0.7)
            }
        }
    }

    private struct PendingRecallMaintenance: Sendable {
        let candidateIDs: [String]
        let selectedIDs: Set<String>
        let scope: EngineMemoryScope
        let configuration: MemoryEngineConfiguration
    }

    /// The maintenance a recall *would* record, computed without mutating the
    /// engine.
    ///
    /// Materializing the proposal separately is what makes the recall path
    /// rollback-safe: the batch, its cold-start seed and the graph a
    /// transactional store should fall back to are all decided before the first
    /// cancellable await, and the engine adopts them in one step only after the
    /// durable transaction has returned.
    private struct MaintenanceProposal: Sendable {
        /// Already recorded intents plus the new one.
        let pending: [PendingRecallMaintenance]
        /// Graph as it was before the *first* pending intent, or `nil` when no
        /// batch is open yet.
        let baseGraph: MemoryGraph?
        /// Seed for a transactional store whose file does not exist yet.
        let initialGraph: MemoryGraph
    }

    private func proposedMaintenance(
        adding intent: PendingRecallMaintenance
    ) -> MaintenanceProposal {
        // `graph` has not been touched by this recall yet, so it *is* the
        // pre-maintenance seed a cold transactional checkpoint needs to replay
        // the batch exactly once.
        let baseGraph = pendingRecallMaintenance.isEmpty ? graph : pendingRecallBaseGraph
        return MaintenanceProposal(
            pending: pendingRecallMaintenance + [intent],
            baseGraph: baseGraph,
            initialGraph: baseGraph ?? graph
        )
    }

    /// Decides what a failed maintenance checkpoint leaves behind.
    ///
    /// The two failure modes are genuinely different and must not be collapsed:
    ///
    /// - **Cancelled.** The turn was abandoned and its caller receives no
    ///   result, so the recall must leave no trace at all. Nothing is adopted:
    ///   there is no pending intent for a later explicit write to make durable,
    ///   and the graph keeps the confidences, access counts and edges it had
    ///   before the recall.
    /// - **Store unavailable.** The retrieval really happened and only
    ///   persistence failed. The batch is adopted so it stays visible in memory
    ///   and retryable at the next durability boundary — the same contract a
    ///   failed explicit ``flushRecallMaintenance()`` honours.
    private func adoptMaintenance(
        after error: any Error,
        draftGraph: MemoryGraph,
        proposal: MaintenanceProposal
    ) {
        guard !(error is CancellationError), !Task.isCancelled else { return }
        graph = draftGraph
        pendingRecallMaintenance = proposal.pending
        pendingRecallBaseGraph = proposal.baseGraph
    }

    private static func apply(_ pending: [PendingRecallMaintenance], to graph: inout MemoryGraph) {
        for record in pending {
            let candidates = record.candidateIDs.compactMap { id -> MemoryCandidate? in
                guard let memory = graph.memories[id],
                      memory.active,
                      MemorySearch.scopeAllows(memory.scope, requested: record.scope) else { return nil }
                return MemoryCandidate(memory: memory, score: 0)
            }
            let selected = candidates.filter { record.selectedIDs.contains($0.memory.id) }
            maintainAfterRetrieval(&graph, all: candidates, selected: selected, configuration: record.configuration)
        }
    }

    /// Caller owns `withWriteLock`. JSON persistence reloads the current graph
    /// under its process-wide lock before replaying pending intents and saving
    /// once. If no file exists yet, `pendingRecallBaseGraph` seeds the graph
    /// from before the first intent, avoiding a cold-start double replay. A
    /// failed checkpoint leaves the in-memory intents retryable.
    private func flushPendingRecallMaintenanceLocked() async throws {
        guard !pendingRecallMaintenance.isEmpty else { return }
        try await commitRecallMaintenance(
            draftGraph: graph,
            pending: pendingRecallMaintenance,
            baseGraph: pendingRecallBaseGraph
        )
    }

    /// Makes a maintenance batch durable and adopts it as engine state.
    ///
    /// Caller owns `withWriteLock`. Engine state is written only after
    /// persistence accepted the batch, so a cancelled or failed checkpoint
    /// leaves `graph` / `pendingRecallMaintenance` exactly as the caller found
    /// them: an already-recorded batch stays retryable, and a batch that was
    /// only a proposal is simply forgotten.
    private func commitRecallMaintenance(
        draftGraph: MemoryGraph,
        pending: [PendingRecallMaintenance],
        baseGraph: MemoryGraph?
    ) async throws {
        if let transactionalPersistence = persistence as? any MemoryTransactionalPersistence {
            let committed = try await transactionalPersistence.transaction(
                initialGraph: baseGraph ?? draftGraph
            ) { graph in
                try Task.checkCancellation()
                Self.apply(pending, to: &graph)
            }
            graph = committed.graph
        } else {
            // Same boundary as the transactional branch, as tight as an
            // arbitrary `MemoryPersistence` allows: the engine cannot see
            // inside a foreign store, so this is the last point it controls.
            try Task.checkCancellation()
            try await persist(draftGraph)
            graph = draftGraph
        }
        pendingRecallMaintenance.removeAll()
        pendingRecallBaseGraph = nil
    }

    private func persist(_ graph: MemoryGraph) async throws {
        if let persistence { try await persistence.save(graph) }
    }
}
