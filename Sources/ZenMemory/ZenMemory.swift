import Foundation

public enum MemoryIntelligenceFailurePolicy: String, Codable, Sendable, Equatable {
    /// Fall back to direct lexical retrieval / score-based selection if an analyzer or selector fails.
    case fallback
    /// Surface intelligence-layer errors to the caller.
    case propagate
}

public struct ZenMemoryConfiguration: Sendable, Equatable {
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

/// Cross-platform agent memory engine.
///
/// The default path is dependency-free lexical retrieval. Query analysis, semantic embeddings,
/// LLM-based selection, extraction and persistent indexes are all optional, pluggable layers.
public actor ZenMemory {
    private var graph: MemoryGraph
    private let embedder: (any EmbeddingProvider)?
    private let lexicalIndex: any MemoryIndex
    private let persistence: (any MemoryPersistence)?
    private let queryAnalyzer: any MemoryQueryAnalyzer
    private let selector: any MemorySelector
    private let extractor: any MemoryExtractor
    private let contextFormatter: any MemoryContextFormatter
    private var configuration: ZenMemoryConfiguration
    private var pending: [MemoryCandidate] = []
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        graph: MemoryGraph = MemoryGraph(),
        lexicalIndex: any MemoryIndex = BM25MemoryIndex(),
        embedder: (any EmbeddingProvider)? = nil,
        persistence: (any MemoryPersistence)? = nil,
        queryAnalyzer: any MemoryQueryAnalyzer = DirectMemoryQueryAnalyzer(),
        selector: any MemorySelector = TopScoreMemorySelector(),
        extractor: any MemoryExtractor = NoopMemoryExtractor(),
        contextFormatter: any MemoryContextFormatter = BulletMemoryContextFormatter(),
        configuration: ZenMemoryConfiguration = .init()
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
    }

    public static func open(
        persistence: any MemoryPersistence,
        lexicalIndex: any MemoryIndex = BM25MemoryIndex(),
        embedder: (any EmbeddingProvider)? = nil,
        queryAnalyzer: any MemoryQueryAnalyzer = DirectMemoryQueryAnalyzer(),
        selector: any MemorySelector = TopScoreMemorySelector(),
        extractor: any MemoryExtractor = NoopMemoryExtractor(),
        contextFormatter: any MemoryContextFormatter = BulletMemoryContextFormatter(),
        configuration: ZenMemoryConfiguration = .init()
    ) async throws -> ZenMemory {
        let graph = try await persistence.load()
        return ZenMemory(
            graph: graph,
            lexicalIndex: lexicalIndex,
            embedder: embedder,
            persistence: persistence,
            queryAnalyzer: queryAnalyzer,
            selector: selector,
            extractor: extractor,
            contextFormatter: contextFormatter,
            configuration: configuration
        )
    }

    public func snapshot() -> MemoryGraph { graph }

    public func setConfiguration(_ configuration: ZenMemoryConfiguration) {
        self.configuration = configuration
    }

    @discardableResult
    public func remember(
        _ content: String,
        category: MemoryCategory = .fact,
        tags: [String] = [],
        source: String? = nil,
        trust: TrustLevel = .medium,
        scope: MemoryScope = .project,
        confidence: Float = 1,
        id: String? = nil
    ) async throws -> MemoryEntry {
        let embedding: [Float]?
        let embeddingModel: String?
        if let embedder {
            embedding = try await embedder.embed(content)
            embeddingModel = embedder.modelID
        } else {
            embedding = nil
            embeddingModel = nil
        }

        var entry = MemoryEntry(
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
        graph.addMemory(entry)
        try await persistIfNeeded()
        return entry
    }

    /// Runs the configured extractor and stores the durable memories it returns.
    /// With the default `NoopMemoryExtractor`, this method is a no-op.
    @discardableResult
    public func learn(from context: String) async throws -> [MemoryEntry] {
        let drafts = try await extractor.extract(from: context)
        var stored: [MemoryEntry] = []
        stored.reserveCapacity(drafts.count)
        for draft in drafts where !draft.content.isEmpty {
            let entry = try await remember(
                draft.content,
                category: draft.category,
                tags: draft.tags,
                source: draft.source,
                trust: draft.trust,
                scope: draft.scope,
                confidence: draft.confidence
            )
            stored.append(entry)
        }
        return stored
    }

    public func extract(from context: String) async throws -> [MemoryDraft] {
        try await extractor.extract(from: context)
    }

    public func insert(_ entry: MemoryEntry, persist: Bool = true) async throws {
        graph.addMemory(entry)
        if persist { try await persistIfNeeded() }
    }

    public func forget(id: String) async throws -> MemoryEntry? {
        let removed = graph.removeMemory(id: id)
        if removed != nil { try await persistIfNeeded() }
        return removed
    }

    public func tag(memoryID: String, with tag: String) async throws {
        graph.addTag(tag, to: memoryID)
        try await persistIfNeeded()
    }

    public func link(from: String, to: String, weight: Float = 0.8) async throws {
        graph.linkMemories(from: from, to: to, weight: weight)
        try await persistIfNeeded()
    }

    public func supersede(newerID: String, olderID: String) async throws {
        graph.supersede(newerID: newerID, olderID: olderID)
        try await persistIfNeeded()
    }

    public func contradict(_ firstID: String, _ secondID: String) async throws {
        graph.markContradiction(firstID, secondID)
        try await persistIfNeeded()
    }

    public func reinforce(id: String, sessionID: String, messageIndex: Int) async throws {
        guard var memory = graph.memories[id] else { return }
        memory.reinforce(sessionID: sessionID, messageIndex: messageIndex)
        graph.memories[id] = memory
        try await persistIfNeeded()
    }

    /// Runs only the query-planning stage. Useful for debugging or for host agents that want
    /// to inspect whether a memory lookup will happen before executing it.
    public func analyze(_ prompt: String) async throws -> MemoryQueryPlan {
        try await analyzeWithPolicy(prompt)
    }

    /// Retrieves candidate memories, expands their graph neighborhood, then lets the configured
    /// selector decide which memories are safe and useful to inject into the main agent context.
    public func recallDetailed(
        _ prompt: String,
        scope: MemoryScope = .all
    ) async throws -> MemoryRecallResult {
        let plan = try await analyzeWithPolicy(prompt)
        guard plan.shouldRecall, configuration.maxResults > 0 else {
            return MemoryRecallResult(plan: plan, candidates: [], selected: [])
        }

        let activeMemories = Array(graph.memories.values)
        let queries = retrievalQueries(from: plan, originalPrompt: prompt)
        guard !queries.isEmpty else {
            return MemoryRecallResult(plan: plan, candidates: [], selected: [])
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
            for query in queries.prefix(configuration.maxSemanticQueries) {
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
            return MemoryRecallResult(plan: plan, candidates: [], selected: [])
        }

        let cascaded = graph.cascadeRetrieve(
            seeds: seeds,
            maxDepth: configuration.maxDepth,
            maxResults: configuration.maxCandidateResults,
            edgeDecay: configuration.edgeDecay
        )

        let candidates = cascaded.compactMap { item -> MemoryCandidate? in
            guard let memory = graph.memories[item.id], memory.active else { return nil }
            return MemoryCandidate(memory: memory, score: item.score * memory.effectiveConfidence())
        }.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.memory.id < rhs.memory.id }
            return lhs.score > rhs.score
        }

        let selected = try await selectWithPolicy(context: prompt, candidates: candidates)
        maintainAfterRetrieval(all: candidates, selected: selected)
        try await persistIfNeeded()
        return MemoryRecallResult(plan: plan, candidates: candidates, selected: selected)
    }

    public func recall(_ query: String, scope: MemoryScope = .all) async throws -> [MemoryCandidate] {
        try await recallDetailed(query, scope: scope).selected
    }

    /// Returns the exact memory block that can be injected into a model prompt.
    /// An empty string means the analyzer/selector found nothing worth injecting.
    public func context(for prompt: String, scope: MemoryScope = .all) async throws -> String {
        let result = try await recallDetailed(prompt, scope: scope)
        return contextFormatter.format(result.selected)
    }

    /// Starts the complete analyze -> retrieve -> select pipeline in a background task and exposes
    /// its selected memories to the next agent turn.
    public func submitContext(_ context: String, scope: MemoryScope = .all) {
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
        try await persistIfNeeded()
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

    private func maintainAfterRetrieval(all: [MemoryCandidate], selected: [MemoryCandidate]) {
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

    private func persistIfNeeded() async throws {
        if let persistence { try await persistence.save(graph) }
    }
}
