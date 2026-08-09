import Foundation

struct ScoredMemoryID: Codable, Sendable, Equatable {
    public var id: String
    public var score: Float

    public init(id: String, score: Float) {
        self.id = id
        self.score = score
    }
}

struct MemoryCandidate: Sendable, Equatable {
    public var memory: EngineMemoryEntry
    public var score: Float

    public init(memory: EngineMemoryEntry, score: Float) {
        self.memory = memory
        self.score = score
    }
}

enum MemorySearch {
    public static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        return dot / (sqrtf(lhsNorm) * sqrtf(rhsNorm))
    }

    public static func semantic(
        graph: MemoryGraph,
        queryEmbedding: [Float],
        modelID: String,
        scope: EngineMemoryScope = .all,
        threshold: Float = 0.4,
        limit: Int = 10
    ) -> [ScoredMemoryID] {
        graph.memories.values
            .lazy
            .filter { $0.active && scopeAllows($0.scope, requested: scope) && $0.embeddingMatches(model: modelID) }
            .compactMap { entry -> ScoredMemoryID? in
                guard let embedding = entry.embedding else { return nil }
                let score = cosineSimilarity(queryEmbedding, embedding)
                guard score >= threshold else { return nil }
                return ScoredMemoryID(id: entry.id, score: score)
            }
            .sorted {
                if $0.score == $1.score { return $0.id < $1.id }
                return $0.score > $1.score
            }
            .prefix(limit)
            .map { $0 }
    }

    public static func lexicalBM25(
        graph: MemoryGraph,
        query: String,
        scope: EngineMemoryScope = .all,
        limit: Int = 10,
        k1: Float = 1.2,
        b: Float = 0.75
    ) -> [ScoredMemoryID] {
        lexicalBM25(
            memories: Array(graph.memories.values),
            query: query,
            scope: scope,
            limit: limit,
            k1: k1,
            b: b
        )
    }

    public static func lexicalBM25(
        memories: [EngineMemoryEntry],
        query: String,
        scope: EngineMemoryScope = .all,
        limit: Int = 10,
        k1: Float = 1.2,
        b: Float = 0.75
    ) -> [ScoredMemoryID] {
        guard limit > 0 else { return [] }
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return [] }

        let documents: [(EngineMemoryEntry, [String])] = memories
            .filter { $0.active && scopeAllows($0.scope, requested: scope) }
            .map { ($0, tokens($0.searchableText)) }

        guard !documents.isEmpty else { return [] }
        let averageLength = Float(documents.reduce(0) { $0 + $1.1.count }) / Float(documents.count)
        guard averageLength > 0 else { return [] }

        let querySet = Set(queryTokens)
        var documentFrequency: [String: Int] = [:]
        for (_, documentTokens) in documents {
            for token in Set(documentTokens) where querySet.contains(token) {
                documentFrequency[token, default: 0] += 1
            }
        }

        return documents.compactMap { entry, documentTokens -> ScoredMemoryID? in
            guard !documentTokens.isEmpty else { return nil }
            var frequencies: [String: Int] = [:]
            for token in documentTokens { frequencies[token, default: 0] += 1 }

            var score: Float = 0
            for token in queryTokens {
                guard let tfValue = frequencies[token], tfValue > 0 else { continue }
                let n = Float(documents.count)
                let df = Float(documentFrequency[token] ?? 0)
                let idf = logf(1 + (n - df + 0.5) / (df + 0.5))
                let tf = Float(tfValue)
                let dl = Float(documentTokens.count)
                let denominator = tf + k1 * (1 - b + b * dl / averageLength)
                score += idf * (tf * (k1 + 1)) / denominator
            }

            return score > 0 ? ScoredMemoryID(id: entry.id, score: score) : nil
        }
        .sorted {
            if $0.score == $1.score { return $0.id < $1.id }
            return $0.score > $1.score
        }
        .prefix(limit)
        .map { $0 }
    }

    public static func reciprocalRankFusion(
        semantic: [ScoredMemoryID],
        lexical: [ScoredMemoryID],
        rankConstant: Float = 60,
        limit: Int = 10
    ) -> [ScoredMemoryID] {
        reciprocalRankFusion(
            rankedLists: [semantic, lexical],
            rankConstant: rankConstant,
            limit: limit
        )
    }

    public static func reciprocalRankFusion(
        rankedLists: [[ScoredMemoryID]],
        rankConstant: Float = 60,
        limit: Int = 10
    ) -> [ScoredMemoryID] {
        guard limit > 0 else { return [] }
        var scores: [String: Float] = [:]
        for list in rankedLists where !list.isEmpty {
            for (rank, item) in list.enumerated() {
                scores[item.id, default: 0] += 1 / (rankConstant + Float(rank + 1))
            }
        }
        return scores.map { ScoredMemoryID(id: $0.key, score: $0.value) }
            .sorted {
                if $0.score == $1.score { return $0.id < $1.id }
                return $0.score > $1.score
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Creates a lightweight ranking from analyzer-produced tags and entities. Exact tag matches
    /// are strongest; entity token matches in content provide an additional lexical signal.
    public static func metadataRanking(
        memories: [EngineMemoryEntry],
        tags: [String],
        entities: [String],
        scope: EngineMemoryScope = .all,
        limit: Int = 10
    ) -> [ScoredMemoryID] {
        guard limit > 0, !tags.isEmpty || !entities.isEmpty else { return [] }
        let wantedTags = Set(tags.map { $0.lowercased() })
        let entityTokens = entities.flatMap(tokens)

        return memories.compactMap { memory -> ScoredMemoryID? in
            guard memory.active, scopeAllows(memory.scope, requested: scope) else { return nil }
            let memoryTags = Set(memory.tags.map { $0.lowercased() })
            let tagMatches = wantedTags.intersection(memoryTags).count
            let documentTokens = Set(tokens(memory.content))
            let entityMatches = entityTokens.reduce(into: 0) { count, token in
                if documentTokens.contains(token) { count += 1 }
            }
            let score = Float(tagMatches) * 2 + Float(entityMatches)
            return score > 0 ? ScoredMemoryID(id: memory.id, score: score) : nil
        }
        .sorted {
            if $0.score == $1.score { return $0.id < $1.id }
            return $0.score > $1.score
        }
        .prefix(limit)
        .map { $0 }
    }

    public static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    public static func scopeAllows(_ memoryScope: EngineMemoryScope, requested: EngineMemoryScope) -> Bool {
        switch requested {
        case .all: true
        case .project: memoryScope == .project || memoryScope == .all
        case .global: memoryScope == .global || memoryScope == .all
        }
    }
}
