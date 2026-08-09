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
        intelligenceFailurePolicy: MemoryIntelligenceFailurePolicy = .fallback
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
    /// recall/search. Defaults to an always-visible redacted ERROR line on the
    /// preserved stderr descriptor (plus the opt-in ZenLogger file channel
    /// unless it already targets stderr); tests inject a deterministic
    /// recorder instead of touching process-global stderr or the logger
    /// configuration.
    private let semanticFailureReporter: @Sendable (String) -> Void
    /// Write-lock state backing ``transaction(_:)``. See that method for why
    /// actor isolation alone is not enough.
    private var isWriting = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Default reporter: always emits a redacted ERROR line on the preserved
    /// stderr descriptor (visible even with `ZENCODE_LOG` off) and feeds the
    /// opt-in diagnostic file unless it already targets stderr.
    private static let defaultSemanticFailureReporter: @Sendable (String) -> Void = { message in
        MemorySemanticFallbackDiagnostics.emitVisibleError(message: message)
    }

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
    /// Persistence is skipped when the body left the graph unchanged, so a
    /// look-only or no-op transaction never touches the disk.
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
            var draft = graph
            let result = try body(&draft)
            guard draft != graph else { return result }
            try await persist(draft)
            graph = draft
            return result
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
        let embedding: [Float]?
        let embeddingModel: String?
        if let embedder {
            embedding = try await embedder.embed(content)
            embeddingModel = embedder.modelID
        } else {
            embedding = nil
            embeddingModel = nil
        }

        var entry = EngineMemoryEntry(
            id: id,
            category: category,
            content: content,
            tags: tags,
            source: source,
            trust: trust,
            scope: scope,
            embedding: embedding,
            embeddingModel: embeddingModel,
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
            var entry = EngineMemoryEntry(
                id: nil,
                category: draft.category,
                content: draft.content,
                tags: draft.tags,
                source: draft.source,
                trust: draft.trust,
                scope: draft.scope,
                embedding: try await embedder?.embed(draft.content),
                embeddingModel: embedder?.modelID,
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
    /// transactional retrieval maintenance (retrieval count, confidence
    /// boost/decay, co-relevance links) and commits it through persistence. For
    /// an explicitly read-only lookup that must never mutate the graph or fail
    /// on a save error, use ``searchReadOnlyDetailed(_:scope:)`` instead.
    public func recallDetailed(
        _ prompt: String,
        scope: EngineMemoryScope = .all
    ) async throws -> MemoryRecallResult {
        let (plan, candidates, selected) = try await retrieveAndSelect(prompt, scope: scope)
        // Retrieval maintenance is a read-modify-write like any other: it runs
        // in a transaction so it neither clobbers a concurrent write nor leaves
        // boosted confidences behind when the save fails.
        //
        // **Re-validation.** `retrieveAndSelect` built its candidates and
        // awaited the selector; a concurrent `forget` or archive can land in
        // that suspension window. The maintenance transaction takes a fresh
        // draft, so we re-check existence, active and scope *inside* it and
        // feed only the survivors to maintenance and to the returned result.
        let settings = configuration
        let revalidated = try await transaction { graph -> RevalidatedRecall in
            let valid = Self.revalidate(
                candidates: candidates,
                selected: selected,
                against: graph,
                scope: scope
            )
            Self.maintainAfterRetrieval(
                &graph,
                all: valid.candidates,
                selected: valid.selected,
                configuration: settings
            )
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

    /// Maps an embedding failure to a short, secret-free summary for the
    /// diagnostic channel. By construction it never includes the query text,
    /// embedding vectors, endpoint URLs, HTTP response bodies (which can echo
    /// input or carry credentials), or API keys — only stable status/type
    /// information that is safe to log.
    private static func embeddingFailureSummary(_ error: (any Error)?) -> String {
        guard let error else { return "unknown" }
        if let embeddingError = error as? OpenAICompatibleEmbeddingError {
            switch embeddingError {
            case .httpStatus(let status, _):
                return "httpStatus \(status)"
            case .emptyEmbedding:
                return "emptyEmbedding"
            }
        }
        if let urlError = error as? URLError {
            return "transportError \(urlError.code.rawValue)"
        }
        return "\(type(of: error))"
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

    public func save() async throws {
        try await withWriteLock { try await persist(graph) }
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
    /// candidate whose ID is gone, inactive, or outside the requested scope.
    private static func revalidate(
        candidates: [MemoryCandidate],
        selected: [MemoryCandidate],
        against graph: MemoryGraph,
        scope: EngineMemoryScope
    ) -> RevalidatedRecall {
        func isValid(_ id: String) -> Bool {
            guard let memory = graph.memories[id],
                  memory.active,
                  MemorySearch.scopeAllows(memory.scope, requested: scope) else {
                return false
            }
            return true
        }
        return RevalidatedRecall(
            candidates: candidates.filter { isValid($0.memory.id) },
            selected: selected.filter { isValid($0.memory.id) }
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

    private func persist(_ graph: MemoryGraph) async throws {
        if let persistence { try await persistence.save(graph) }
    }
}
