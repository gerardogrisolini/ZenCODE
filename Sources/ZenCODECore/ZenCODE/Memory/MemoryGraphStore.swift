//
//  MemoryGraphStore.swift
//  ZenCODE
//
//  Actor-backed adapter over the vendored MemoryEngine graph engine.
//

import Foundation

/// Serializes read-modify-write sequences against one workspace graph.
///
/// The engine is already an actor, but ZenCODE's operations (deduplicating
/// write, content update, archive) are read-modify-write pairs that must not
/// interleave. This actor provides that transaction boundary; it is the
/// graph-era replacement for `FileTransactionCoordinator.withLock(for:)` on
/// MEMORY.md. `FileTransactionCoordinator` itself is unchanged and still serves
/// `SavedSessionsStore`.
actor MemoryGraphStore {
    let graphURL: URL
    private let engine: MemoryEngine
    /// Kept from `open` rather than re-resolved per call: `update` and `write`
    /// must embed with the same provider the engine was opened with, otherwise
    /// entries would carry vectors the engine refuses to compare.
    private let embedder: (any EmbeddingProvider)?
    /// Shared with the engine so mutation-time embedding degradation is
    /// observable without making the operation fail.
    private let semanticFailureReporter: @Sendable (String) -> Void

    init(
        graphURL: URL,
        engine: MemoryEngine,
        embedder: (any EmbeddingProvider)?,
        semanticFailureReporter: @escaping @Sendable (String) -> Void = MemoryEmbeddingFallback.defaultReporter
    ) {
        self.graphURL = graphURL
        self.engine = engine
        self.embedder = embedder
        self.semanticFailureReporter = semanticFailureReporter
    }

    // MARK: - Opening and migration

    /// Opens the graph for a workspace, migrating a legacy MEMORY.md exactly once.
    ///
    /// The graph is loaded (or migrated from `MEMORY.md`) entirely in memory;
    /// **nothing is persisted during open.** Persistence is deferred to the
    /// first transactional mutation or maintenance pass. This keeps a cold read
    /// — `memory.search` / `memory.read` on a workspace whose graph file does
    /// not yet exist — from creating `memory.graph.json` and from failing when
    /// the support directory is not writable. The first real write
    /// (`memory.write`, `memory.update`, …) or the first automatic recall
    /// maintenance will persist the full graph (migration + new entries) in one
    /// atomic save.
    ///
    /// Idempotence: when no graph file exists the migration runs on every cold
    /// open, but entry identity is derived deterministically from the journal,
    /// so repeated migrations converge on the same nodes instead of duplicating
    /// them. Once a mutation has persisted the file, subsequent opens load it
    /// directly and skip migration.
    static func open(
        graphURL: URL,
        workspaceRootURL: URL,
        semanticFailureReporter: @escaping @Sendable (String) -> Void = MemoryEmbeddingFallback.defaultReporter
    ) async throws -> MemoryGraphStore {
        // `FileManager.default` is used deliberately: this runs inside a
        // detached task, and `FileManager` is not `Sendable`, so an injected
        // instance must not cross the isolation boundary. Path resolution
        // (which is what an injected file manager influences) has already
        // happened by the time `graphURL` is computed.
        let fileManager = FileManager.default
        let embedder = MemoryEmbedding.provider()
        let persistence = JSONMemoryPersistence(url: graphURL)

        // Load or migrate the graph in memory only; do NOT persist. The first
        // mutation/maintenance will persist the full graph atomically.
        let initialGraph: MemoryGraph
        if fileManager.fileExists(atPath: graphURL.path) {
            initialGraph = try await persistence.load()
        } else {
            initialGraph = try await migratedGraph(
                workspaceRootURL: workspaceRootURL,
                embedder: embedder,
                semanticFailureReporter: semanticFailureReporter,
                fileManager: fileManager
            )
        }

        // Construct the engine directly with the in-memory graph and the same
        // persistence instance. The engine's `transaction(_:)` will call
        // `persist` on the first mutation, atomically writing the full graph.
        let engine = MemoryEngine(
            graph: initialGraph,
            embedder: embedder,
            persistence: persistence,
            selector: ScoreThresholdMemorySelector(),
            // Product recall is intentionally dependency-free. `learn(from:)`
            // remains an internal engine seam, but opening a product store never
            // installs a network-backed extractor or makes a generation request.
            extractor: NoopMemoryExtractor(),
            semanticFailureReporter: semanticFailureReporter
        )
        return MemoryGraphStore(
            graphURL: graphURL,
            engine: engine,
            embedder: embedder,
            semanticFailureReporter: semanticFailureReporter
        )
    }

    /// Builds the initial graph from the legacy journal, losslessly.
    private static func migratedGraph(
        workspaceRootURL: URL,
        embedder: (any EmbeddingProvider)?,
        semanticFailureReporter: @escaping @Sendable (String) -> Void,
        fileManager: FileManager
    ) async throws -> MemoryGraph {
        var graph = MemoryGraph()
        let journalURL = MemoryGraphLocation.legacyJournalURL(for: workspaceRootURL)

        switch LegacyMemoryJournal.read(at: journalURL, fileManager: fileManager) {
        case .missing:
            return graph
        case .unusable:
            // The journal exists but cannot be parsed safely. Refuse to migrate
            // rather than start an empty graph and strand the user's entries.
            throw MemoryServiceError.invalidDocument(journalURL.path)
        case let .loaded(legacyEntries):
            // The journal is newest-first. Preserve that order exactly: use the
            // entry's own Timestamp when it parses, but never let an entry sort
            // above the one that precedes it in the document. Entries without a
            // usable Timestamp inherit a slot just below their predecessor
            // instead of defaulting to "now", which would hoist undated legacy
            // entries to the top of the journal.
            let importedAt = Date()
            var previousCreatedAt: Date?
            for legacy in legacyEntries {
                let ceiling = previousCreatedAt?.addingTimeInterval(-1)
                let parsed = MemoryEntryMetadata(content: legacy.content).timestampDate
                let createdAt: Date = switch (parsed, ceiling) {
                case let (.some(parsed), .some(ceiling)): min(parsed, ceiling)
                case let (.some(parsed), .none): parsed
                case let (.none, .some(ceiling)): ceiling
                case (.none, .none): importedAt
                }
                previousCreatedAt = createdAt

                let embedded = try await MemoryEmbeddingFallback.embed(
                    legacy.content,
                    with: embedder,
                    operation: "migration",
                    reporter: semanticFailureReporter
                )
                var entry = GraphEntry(
                    id: MemoryIdentifier.canonical(legacy.id),
                    category: .fact,
                    content: legacy.content,
                    tags: [],
                    source: migrationSource,
                    trust: .medium,
                    scope: .project,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    embedding: embedded.values,
                    embeddingModel: embedded.model
                )
                entry.active = !legacy.isArchived
                graph.addMemory(entry)
            }
            return graph
        }
    }

    static let migrationSource = "memory-md-migration"

    // MARK: - Reads

    func entries(includeArchived: Bool, limit: Int) async -> [GraphEntry] {
        let graph = await engine.snapshot()
        return Self.ordered(graph.memories.values)
            .filter { includeArchived || $0.active }
            .prefix(max(limit, 0))
            .map { $0 }
    }

    func search(
        query: String,
        includeArchived: Bool,
        limit: Int
    ) async throws -> [GraphEntry] {
        let cappedLimit = max(limit, 0)
        // Read-only path: `memory.search` is a pure lookup. It must not mutate
        // retrievalCount/confidence/links or fail because a persistence save
        // errored. The engine's read-only retrieval shares the same analyze →
        // retrieve → select pipeline as automatic recall but skips the
        // transactional maintenance that `recall` applies. Automatic recall
        // (`context(for:)`) keeps its maintenance path unchanged.
        let recalled = try await engine.searchReadOnly(query, scope: .all)
        var active = recalled.map(\.memory).filter(\.active)

        guard includeArchived else {
            return Array(active.prefix(cappedLimit))
        }

        // Inactive nodes are excluded from both `recall` and the engine's
        // `lexicalBM25` by design, so archived entries are matched separately.
        let graph = await engine.snapshot()
        let archived = Self.ordered(graph.memories.values.filter { !$0.active })
            .compactMap { entry -> (entry: GraphEntry, score: Int)? in
                let score = Self.lexicalScore(entry, query: query)
                return score > 0 ? (entry, score) : nil
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.entry.id < rhs.entry.id
            }
            .map(\.entry)

        // Reserve part of the budget for archived hits. Appending them after a
        // full page of active results would make an explicitly requested
        // archived entry unreachable whenever the active set fills the limit.
        let archivedBudget = min(archived.count, cappedLimit / 2)
        let activeBudget = max(cappedLimit - archivedBudget, 0)
        active = Array(active.prefix(activeBudget))

        var seen = Set<String>()
        return (active + archived)
            .filter { seen.insert($0.id).inserted }
            .prefix(cappedLimit)
            .map { $0 }
    }

    func entry(id: String) async -> GraphEntry? {
        await engine.snapshot().memories[id]
    }

    // MARK: - Automatic turn pipeline

    /// Runs the engine's full analyze → retrieve → select → format pipeline and
    /// returns the ready-to-inject memory block, or an empty string when
    /// nothing was selected.
    ///
    /// Deliberately NOT `MemoryEngine.submitContext(_:)` / `takePending()`.
    /// That pair looks like the natural fit for "prepare memories for the next
    /// turn", but it is unsafe here: `MemoryEngine.pending` is a single unkeyed
    /// array on the engine actor, and `takePending()` drains it wholesale.
    /// Meanwhile `MemoryGraphStoreRegistry` caches exactly one store — and so
    /// one engine — per workspace graph URL, which every concurrent session,
    /// sub-agent and tool call in that workspace shares. Two overlapping turns
    /// would therefore write into the same `pending` slot and the first drain
    /// would hand one session the memories retrieved for another session's
    /// prompt. Going through this synchronous, per-call path keeps every
    /// retrieval bound to the prompt that asked for it.
    func context(
        for prompt: String,
        scope: GraphScope = .all
    ) async throws -> String {
        try await engine.context(for: prompt, scope: scope)
    }

    /// Runs the engine's configured extractor over `context` and stores what it
    /// returns. Stores opened by the product always use `NoopMemoryExtractor`,
    /// so this is a no-op there and makes no network call. The internal helper
    /// remains available for API and engine-level transaction tests that inject
    /// a deterministic extractor directly.
    ///
    /// Deliberately NOT `MemoryEngine.learn(from:)`, on two counts:
    ///
    /// - **Identity.** The engine mints library-shaped ids
    ///   (`mem_<millis>_<uuid>`), but every ZenCODE maintenance path goes
    ///   through `MemoryIdentifier.validated`, which accepts canonical UUIDs
    ///   only. An engine-minted id would therefore surface an entry that
    ///   `memory.update` and `memory.archive` cannot touch — the model could
    ///   read a stale derived fact and would have no way to correct it.
    /// - **Duplication.** `write` refuses to append a second active entry with
    ///   the same content; this helper uses the same normalization and duplicate
    ///   rule for any injected engine drafts.
    ///
    /// The whole batch is applied in one engine transaction, so the duplicate
    /// check also covers repeats *within* a batch, and a failing save stores
    /// none of it rather than part of it.
    @discardableResult
    func learn(from context: String) async throws -> [GraphEntry] {
        let drafts = try await engine.extract(from: context)
        var prepared: [GraphEntry] = []
        prepared.reserveCapacity(drafts.count)
        for draft in drafts {
            let normalizedContent = MemoryContent.normalized(draft.content)
            guard !normalizedContent.isEmpty else { continue }
            let embedded = try await MemoryEmbeddingFallback.embed(
                normalizedContent,
                with: embedder,
                operation: "learn",
                reporter: semanticFailureReporter
            )
            var entry = GraphEntry(
                id: MemoryIdentifier.makeNew(),
                category: draft.category,
                content: normalizedContent,
                tags: draft.tags,
                source: draft.source ?? MemorySource.learn,
                trust: draft.trust,
                scope: draft.scope,
                embedding: embedded.values,
                embeddingModel: embedded.model,
                confidence: draft.confidence
            )
            entry.refreshSearchText()
            prepared.append(entry)
        }
        guard !prepared.isEmpty else {
            return []
        }

        let batch = prepared
        // Awaitable draft preparation is complete by this point. Re-checking
        // cancellation immediately before the atomic transaction preserves the
        // all-or-nothing contract for direct internal callers as well.
        try Task.checkCancellation()
        return try await engine.transaction { graph in
            var stored: [GraphEntry] = []
            for entry in batch {
                // Extracted drafts carry no generated annotation, so their
                // content is compared exactly as authored.
                guard Self.activeDuplicate(
                    matching: .literal(entry.content),
                    in: graph
                ) == nil else {
                    continue
                }
                graph.addMemory(entry)
                stored.append(entry)
            }
            return stored
        }
    }

    /// Flushes the in-memory graph to disk.
    ///
    /// `remember`/`insert` already persist, so this exists for callers that
    /// need an explicit checkpoint after a direct batch of writes.
    func saveGraph() async throws {
        try await engine.save()
    }

    // MARK: - Mutations

    /// Appends a new entry, or returns the existing active entry with the same
    /// content instead of creating a duplicate.
    ///
    /// The duplicate check and the insertion happen inside a single engine
    /// transaction. Splitting them — snapshot, decide, then write — is safe only
    /// under a lock this actor cannot provide: `MemoryGraphStore` is an actor,
    /// but each `await` on the engine is a suspension point at which another
    /// call re-enters, so two concurrent writes of the same content would both
    /// observe "absent" and both insert.
    /// - Parameter generatedTimestamp: `true` only when the caller prepended
    ///   the `Timestamp:` annotation itself instead of receiving it from the
    ///   author. It is the sole condition under which that one line may be
    ///   ignored while looking for a duplicate; every other caller is compared
    ///   literally.
    func write(
        content: String,
        category: GraphCategory,
        tags: [String],
        generatedTimestamp: Bool = false
    ) async throws -> (entry: GraphEntry, created: Bool) {
        let normalizedContent = MemoryContent.normalized(content)
        guard !normalizedContent.isEmpty else {
            throw MemoryServiceError.missingField("content")
        }
        let duplicationKey: MemoryDeduplicationKey = generatedTimestamp
            ? .autoTimestamped(normalizedContent)
            : .literal(normalizedContent)

        // Fast path: an already-visible duplicate costs neither an embedding
        // call nor a transaction. It is an optimization only — the check inside
        // the transaction is the authoritative one.
        if let existing = Self.activeDuplicate(
            matching: duplicationKey,
            in: await engine.snapshot()
        ) {
            return (existing, false)
        }

        let embedded = try await MemoryEmbeddingFallback.embed(
            normalizedContent,
            with: embedder,
            operation: "write",
            reporter: semanticFailureReporter
        )
        let id = MemoryIdentifier.makeNew()
        return try await engine.transaction { graph in
            if let existing = Self.activeDuplicate(matching: duplicationKey, in: graph) {
                return (existing, false)
            }
            var entry = GraphEntry(
                id: id,
                category: category,
                content: normalizedContent,
                tags: tags,
                source: MemorySource.tool,
                trust: .medium,
                scope: .project,
                embedding: embedded.values,
                embeddingModel: embedded.model,
                autoGeneratedTimestamp: generatedTimestamp
            )
            entry.refreshSearchText()
            graph.addMemory(entry)
            return (entry, true)
        }
    }

    /// Replaces the content of an existing entry in place, preserving its id.
    ///
    /// This is deliberately NOT `supersede`: the entry keeps its identity, its
    /// creation date, its archive state and its graph edges, so an id handed to
    /// the model stays valid after an update.
    ///
    /// The merge is applied to the entry *as the transaction finds it*, never to
    /// the copy this call started from, so a concurrent archive survives an
    /// update and vice versa: each writer changes only its own fields.
    ///
    /// The embedding is the one part that cannot be computed inside the
    /// transaction (it is async) and that depends on the stored text (the
    /// preserved `Timestamp` comes from the entry being replaced). So it is
    /// predicted from a snapshot, and the transaction verifies the prediction:
    /// if a concurrent change invalidated it, the loop re-embeds the text the
    /// transaction actually produced.
    func update(
        id rawIdentifier: String,
        content: String,
        tags: [String]?,
        updatedAt: Date,
        timeZone: TimeZone
    ) async throws -> GraphEntry {
        let id = try MemoryIdentifier.validated(rawIdentifier)
        let normalizedContent = MemoryContent.normalized(content)
        guard !normalizedContent.isEmpty else {
            throw MemoryServiceError.missingField("content")
        }
        guard let current = await engine.snapshot().memories[id] else {
            throw MemoryServiceError.entryNotFound(rawIdentifier)
        }

        var embedded = try await embedded(
            MemoryService.contentWithUpdateMetadata(
                normalizedContent,
                existingEntry: current,
                updatedAt: updatedAt,
                timeZone: timeZone
            )
        )
        // Without an embedder there is no vector to keep in sync, so the
        // prediction never has to be re-checked.
        let verifiesEmbedding = embedder != nil

        for attempt in 0..<Self.maximumUpdateAttempts {
            let pending = embedded
            // Last round: accept the embedding computed for a very slightly
            // different text rather than fail a user-visible update over a
            // race. A stale vector degrades ranking; it never corrupts content.
            let acceptsStaleEmbedding = attempt == Self.maximumUpdateAttempts - 1
            let outcome = try await engine.transaction { graph -> UpdateOutcome in
                guard var entry = graph.memories[id] else {
                    return .missing
                }
                let finalContent = MemoryService.contentWithUpdateMetadata(
                    normalizedContent,
                    existingEntry: entry,
                    updatedAt: updatedAt,
                    timeZone: timeZone
                )
                guard acceptsStaleEmbedding
                        || !verifiesEmbedding
                        || pending.content == finalContent else {
                    return .staleEmbedding(finalContent)
                }
                entry.content = finalContent
                // `memory.update` receives caller-authored replacement content.
                // Do not carry timestamp provenance from the previous value:
                // an explicit machine-shaped Timestamp in the replacement must
                // remain semantically significant for later deduplication.
                entry.autoGeneratedTimestamp = false
                if let tags {
                    entry.tags = tags
                }
                entry.updatedAt = updatedAt
                entry.refreshSearchText()
                entry.setEmbedding(pending.values, model: pending.model)
                graph.addMemory(entry)
                return .updated(entry)
            }

            switch outcome {
            case let .updated(entry):
                return entry
            case .missing:
                throw MemoryServiceError.entryNotFound(rawIdentifier)
            case let .staleEmbedding(finalContent):
                embedded = try await self.embedded(finalContent)
            }
        }
        throw MemoryServiceError.entryNotFound(rawIdentifier)
    }

    func setArchived(_ isArchived: Bool, id rawIdentifier: String) async throws -> GraphEntry {
        let id = try MemoryIdentifier.validated(rawIdentifier)
        let updatedAt = Date()
        return try await engine.transaction { graph in
            guard var entry = graph.memories[id] else {
                throw MemoryServiceError.entryNotFound(rawIdentifier)
            }
            // Only the archive flag is touched, so an update that commits
            // around this one keeps its content.
            entry.active = !isArchived
            entry.updatedAt = updatedAt
            graph.addMemory(entry)
            return entry
        }
    }

    func delete(id rawIdentifier: String) async throws {
        let id = try MemoryIdentifier.validated(rawIdentifier)
        guard try await engine.forget(id: id) != nil else {
            throw MemoryServiceError.entryNotFound(rawIdentifier)
        }
    }

    // MARK: - Helpers

    /// Bounded because each retry is caused by a *concurrent* commit on the
    /// same entry; more than a couple of rounds means a pathological contention
    /// pattern, and the last round commits unconditionally anyway.
    private static let maximumUpdateAttempts = 3

    private enum UpdateOutcome: Sendable {
        case updated(GraphEntry)
        case missing
        /// The transaction produced a different text than the one embedded;
        /// carries that text so the caller can embed it and retry.
        case staleEmbedding(String)
    }

    /// An embedding paired with the exact text it describes, so a transaction
    /// can tell whether it still applies.
    private struct EmbeddedContent: Sendable {
        let content: String
        let values: [Float]?
        let model: String?
    }

    private func embedded(_ content: String) async throws -> EmbeddedContent {
        let embedded = try await MemoryEmbeddingFallback.embed(
            content,
            with: embedder,
            operation: "update",
            reporter: semanticFailureReporter
        )
        return EmbeddedContent(
            content: content,
            values: embedded.values,
            model: embedded.model
        )
    }

    /// The active entry a write would duplicate, if any.
    ///
    /// Newest-first so the answer is deterministic when several nodes share
    /// content, and case-insensitive so trivial re-phrasings of the same line do
    /// not create a second copy. What may be ignored is decided by the key, not
    /// by scanning the text for field-looking lines: see
    /// ``MemoryDeduplicationKey``.
    private static func activeDuplicate(
        matching key: MemoryDeduplicationKey,
        in graph: MemoryGraph
    ) -> GraphEntry? {
        ordered(graph.memories.values).first { $0.active && key.matches($0) }
    }

    /// Journal order: newest first, with a stable tie-break.
    private static func ordered(
        _ entries: some Sequence<GraphEntry>
    ) -> [GraphEntry] {
        entries.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    /// Term-coverage score for archived entries, which the engine's retrieval
    /// paths skip. Zero means "no match".
    private static func lexicalScore(_ entry: GraphEntry, query: String) -> Int {
        let normalizedQuery = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return 1
        }
        let haystack = entry.searchableText
        var score = 0
        if haystack.contains(normalizedQuery) {
            score += 50
        }
        var seenTerms = Set<String>()
        let terms = normalizedQuery
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && seenTerms.insert($0).inserted }
        guard !terms.isEmpty else {
            return score
        }
        var matchedTerms = 0
        for term in terms where haystack.contains(term) {
            matchedTerms += 1
            score += 10
        }
        if matchedTerms == terms.count {
            score += 25
        }
        return score
    }
}

// MARK: - Identifiers

enum MemoryIdentifier {
    /// Every ZenCODE-authored node uses a canonical uppercase UUID string, so
    /// the identifiers surfaced to the model stay in the shape callers and
    /// existing MEMORY.md `[id: …]` markers already use.
    static func canonical(_ id: UUID) -> String {
        id.uuidString
    }

    static func makeNew() -> String {
        UUID().uuidString
    }

    static func validated(_ rawIdentifier: String) throws -> String {
        let trimmed = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MemoryServiceError.missingField("id")
        }
        guard let uuid = UUID(uuidString: trimmed) else {
            throw MemoryServiceError.invalidIdentifier(rawIdentifier)
        }
        return canonical(uuid)
    }
}

enum MemorySource {
    static let tool = "memory.write"
    /// Fallback attribution for entries produced through the internal learn
    /// helper when an injected draft carries no source.
    static let learn = "memory.learn"
}

// MARK: - Store registry

/// Process-wide cache of open graph stores, keyed by resolved graph URL.
///
/// Callers commonly build a fresh `MemoryService` per tool execution; without
/// this cache each one would open an independent engine over the same file and
/// they could lose one another's updates.
actor MemoryGraphStoreRegistry {
    static let shared = MemoryGraphStoreRegistry()

    private var stores: [URL: Task<MemoryGraphStore, Error>] = [:]

    func store(
        forWorkspaceRoot workspaceRootURL: URL,
        graphURL: URL
    ) async throws -> MemoryGraphStore {
        if let pending = stores[graphURL] {
            return try await pending.value
        }

        let task = Task(executorPreference: MemoryLegacyBridge.taskExecutor) {
            try await MemoryGraphStore.open(
                graphURL: graphURL,
                workspaceRootURL: workspaceRootURL
            )
        }
        stores[graphURL] = task
        do {
            return try await task.value
        } catch {
            // A failed open must not be cached, otherwise the workspace stays
            // permanently broken for the lifetime of the process.
            stores[graphURL] = nil
            throw error
        }
    }

    /// Drops cached stores. Used when the support directory is re-pointed.
    func reset() {
        stores.removeAll()
    }
}

// MARK: - Embeddings

enum MemoryEmbedding {
    static let environmentEndpointKey = "ZENCODE_MEMORY_EMBEDDING_ENDPOINT"

    /// Task-local override for provider resolution.
    ///
    /// Embeddings are opt-in and, when configured, reach out to a real network
    /// endpoint. Tests must never make that call involuntarily just because the
    /// developer's shell exports `ZENCODE_MEMORY_EMBEDDING_ENDPOINT`. A `setenv`-based
    /// override would be process-global and racy across concurrently running
    /// tests, so the injection seam is a task-local instead — the same shape as
    /// ``AppStorageDirectory/withSupportDirectoryURL(_:operation:)``. It is
    /// inherited by the unstructured `Task` that `MemoryGraphStoreRegistry`
    /// uses to open the engine, and it never leaks into a concurrently running
    /// suite.
    ///
    /// The double optional distinguishes three states:
    /// - `nil` (outer) — the default, unbound state: resolve from persisted
    ///   settings (manifest endpoint or explicit disabled), then from the legacy
    ///   endpoint environment variable when the manifest field is absent. This
    ///   is production behavior.
    /// - `.some(nil)` — force "no provider", ignoring persisted settings and the
    ///   environment. Use this in tests to guarantee no network call is made even
    ///   when the real process carries a configured endpoint.
    /// - `.some(provider)` — force a specific provider, ignoring persisted
    ///   settings and the environment. Use this to test provider wiring
    ///   deterministically.
    @TaskLocal static var override: (any EmbeddingProvider)?? = nil

    /// Runs `operation` with a forced provider resolution.
    ///
    /// Pass `nil` to force "no provider" — no environment lookup, no network.
    /// Pass a provider to force it regardless of persisted settings or the
    /// environment. Outside this scope the unbound resolver is used: in
    /// production it consults the persisted endpoint and then the legacy
    /// environment endpoint; under a test harness it returns nil
    /// unconditionally.
    static func withProvider<T: Sendable>(
        _ provider: (any EmbeddingProvider)?,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await $override.withValue(Optional(provider)) {
            try await operation()
        }
    }

    /// Embeddings are opt-in. With no provider configured, `recall` uses pure
    /// BM25 lexical seeds and entries store no vector. The default
    /// `DeterministicHashEmbeddingProvider` is a feature-hashing bag-of-words
    /// encoder, not a semantic model, so fusing it with BM25 added noise rather
    /// than signal; it remains available but is no longer wired in by default.
    ///
    /// An OpenAI-compatible provider can be opted into through the persisted
    /// endpoint or the legacy environment endpoint without changing the graph
    /// format: entries record a stable identity derived from that endpoint, and
    /// the engine only compares vectors from a matching identity, so an endpoint
    /// change degrades to lexical BM25 retrieval instead of returning wrong
    /// matches.
    ///
    /// A task-local override (``withProvider(_:operation:)``) takes precedence
    /// over persisted settings and the environment when bound, so tests can
    /// inject or disable a provider without touching process-global state.
    ///
    /// Under a test harness the real process environment is never consulted:
    /// it may carry a network-capable embedding configuration the developer
    /// never intended a test to reach, and both process settings and
    /// `ProcessInfo` are global. Tests that need a provider must bind one
    /// explicitly via ``withProvider(_:operation:)`` or use the explicit
    /// `provider(manifest:environment:)` resolver seam.
    static func provider() -> (any EmbeddingProvider)? {
        switch override {
        case .none:
            guard !AppStorageDirectory.isRunningUnderTestHarness else {
                return nil
            }
            return provider(
                manifest: AgentSettingsManifestStore.load(),
                environment: ProcessInfo.processInfo.environment
            )
        case .some(let forced):
            return forced
        }
    }

    /// Resolves an embedding provider without I/O. This explicit seam keeps the
    /// precedence testable while `provider()` remains safe under a test harness.
    ///
    /// Resolution order: task-local override > manifest (endpoint or disabled) >
    /// legacy environment fallback (only when the manifest field is absent) > BM25.
    static func provider(
        manifest: AgentSettingsManifest?,
        environment: [String: String]
    ) -> (any EmbeddingProvider)? {
        switch override {
        case .some(let forced):
            return forced
        case .none:
            return providerFromSettings(manifest, environment)
        }
    }

    private static func providerFromSettings(
        _ manifest: AgentSettingsManifest?,
        _ environment: [String: String]
    ) -> (any EmbeddingProvider)? {
        // A present memoryEmbedding field takes precedence over the environment.
        if let settings = manifest?.memoryEmbedding {
            if settings.isExplicitlyDisabled {
                // Explicit BM25: no provider and no environment fallback.
                return nil
            }
            if let endpoint = settings.endpointURL {
                return OpenAICompatibleEmbeddingProvider(
                    endpoint: endpoint,
                    model: settings.model,
                    apiKey: providerAPIKey(
                        manifest: manifest,
                        providerID: settings.providerID,
                        endpoint: endpoint
                    )
                )
            }
            // endpoint present but invalid: degrade to absent and try the env.
        }
        // Field absent (or invalid endpoint): legacy environment fallback.
        return providerFromEnvironment(environment)
    }

    /// Derives the embedding Authorization key from the provider referenced by
    /// `providerID` (set only by the OpenRouter preset) without duplicating the
    /// secret in the embeddings manifest. The key is reused only when all of
    /// the following hold: the reference resolves to a provider actually present
    /// in the manifest, that provider is OpenRouter, and the embedding endpoint
    /// is itself an OpenRouter endpoint. Any other combination — custom/legacy
    /// endpoint-only configurations, a stale or edited providerID, or an
    /// endpoint pointing at a different host — yields no key, so a manipulated
    /// `settings.json` can never forward an OpenRouter key to an arbitrary
    /// host.
    private static func providerAPIKey(
        manifest: AgentSettingsManifest?,
        providerID: UUID?,
        endpoint: URL
    ) -> String? {
        guard let providerID,
              let manifest,
              let provider = manifest.providers.first(where: { $0.id == providerID }),
              AgentRemoteProvider.isOpenRouterBaseURL(provider.baseURL),
              AgentRemoteProvider.isOpenRouterBaseURL(endpoint.absoluteString) else {
            return nil
        }
        return manifest.remoteAPIKeysByProviderID[
            providerID.uuidString.lowercased()
        ]
    }

    private static func providerFromEnvironment(
        _ environment: [String: String]
    ) -> (any EmbeddingProvider)? {
        guard let rawEndpoint = environment[environmentEndpointKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawEndpoint.isEmpty,
              let endpoint = AgentMemoryEmbeddingSettingsManifest.url(for: rawEndpoint) else {
            return nil
        }
        return OpenAICompatibleEmbeddingProvider(endpoint: endpoint)
    }
}

// MARK: - Retrieval selection

/// Deterministic, offline score-threshold selector.
///
/// Replaces the engine's default `TopScoreMemorySelector(minimumScore: 0)`.
/// With that default, `select` returns every candidate up to `maxResults`, so
/// in `maintainAfterRetrieval` every retrieved entry is boosted and none is
/// ever decayed (confidence flattens toward 1.0), and `selected.count >= 2` is
/// nearly always true so every recall links all its results pairwise at weight
/// 0.7, saturating the graph until cascade retrieval degenerates into noise.
///
/// This selector keeps only candidates at or above a fraction of the top
/// candidate's score. That restores decay for weak candidates and limits
/// co-relevance linking to genuinely strong matches. It makes no LLM call and
/// no network request: BM25/cascade scores have no absolute scale (they depend
/// on corpus statistics), so the threshold is relative to the best hit in each
/// recall rather than a fixed cutoff.
struct ScoreThresholdMemorySelector: MemorySelector {
    /// A candidate is selected when its score is at least this fraction of the
    /// strongest candidate's score. `0.5` keeps entries within a factor of two
    /// of the best match — conservative enough to retain a cluster of genuinely
    /// relevant hits, aggressive enough to decay the long tail pulled in by
    /// graph expansion.
    let relativeThreshold: Float

    init(relativeThreshold: Float = 0.5) {
        self.relativeThreshold = relativeThreshold
    }

    func select(
        context: String,
        candidates: [MemoryCandidate],
        limit: Int
    ) async throws -> [MemoryCandidate] {
        guard limit > 0 else { return [] }
        // `recallDetailed` hands candidates in score-descending order, but a
        // selector's contract must not rely on the caller's ordering, so sort
        // defensively before deriving the threshold from the strongest hit.
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.memory.id < rhs.memory.id }
            return lhs.score > rhs.score
        }
        guard let topScore = ordered.first?.score, topScore > 0 else {
            // No positive top score: the relative threshold cannot
            // discriminate, so fall back to rank order, still honouring `limit`.
            return Array(ordered.prefix(limit))
        }
        let floor = topScore * relativeThreshold
        return ordered.filter { $0.score >= floor }.prefix(limit).map { $0 }
    }
}
