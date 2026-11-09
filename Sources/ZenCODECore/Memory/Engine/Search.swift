//  Created by Gerardo Grisolini on 30/05/26.
//
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

    /// Semantic ranking of the active, in-scope entries that carry a vector
    /// from `modelID`, best first.
    ///
    /// Sentence embeddings are anisotropic: the cosine of a prompt against
    /// unrelated entries is not 0 but a prompt-specific baseline (about 0.35 to
    /// 0.45 for a 4096-dimensional model) with a narrow spread, so an absolute
    /// `threshold` cannot tell a real match from the top of that noise band and
    /// a prompt with no relevant memory still yields a full list. With
    /// `minimumZScore > 0` the ranking is gated per prompt: a hit must stand
    /// out from the bulk of the prompt's similarity distribution by that many
    /// robust standard deviations (median and scaled median absolute
    /// deviation, which a handful of genuine matches cannot inflate), so a
    /// flat distribution yields no hit at all. The gate needs at least
    /// ``minimumGateSampleSize`` eligible vectors — below that a single
    /// outlier cannot reach the required z — and `threshold` always applies
    /// as an absolute floor on the raw cosine.
    public static func semantic(
        graph: MemoryGraph,
        queryEmbedding: [Float],
        modelID: String,
        scope: EngineMemoryScope = .all,
        threshold: Float = 0.4,
        minimumZScore: Float = 0,
        limit: Int = 10
    ) -> [ScoredMemoryID] {
        guard limit > 0 else { return [] }
        let scored = semanticSimilarities(
            graph: graph,
            queryEmbedding: queryEmbedding,
            modelID: modelID,
            scope: scope
        )
        guard !scored.isEmpty else { return [] }

        var floor = threshold
        if minimumZScore > 0, scored.count >= minimumGateSampleSize {
            // A degenerate spread means nothing stands out for this prompt.
            guard let gate = robustOutlierGate(scored.map(\.score), zScore: minimumZScore) else {
                return []
            }
            floor = max(floor, gate)
        }

        return scored
            .filter { $0.score >= floor }
            .sorted {
                if $0.score == $1.score { return $0.id < $1.id }
                return $0.score > $1.score
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Fewest eligible vectors for which the z-score gate is applied.
    static let minimumGateSampleSize = 8

    /// `median + z · scale`, where `scale` is the median absolute deviation
    /// scaled to the standard deviation of a normal distribution (× 1.4826),
    /// falling back to the standard deviation when more than half of the
    /// values coincide. `nil` when the values have no spread at all.
    static func robustOutlierGate(_ values: [Float], zScore: Float) -> Float? {
        guard values.count >= 2 else { return nil }
        let sorted = values.sorted()
        let median = medianOfSorted(sorted)
        let deviations = values.map { abs($0 - median) }.sorted()
        var scale = 1.4826 * medianOfSorted(deviations)
        if scale <= 0 {
            let mean = values.reduce(0, +) / Float(values.count)
            scale = sqrtf(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count))
        }
        guard scale > 0 else { return nil }
        return median + zScore * scale
    }

    private static func medianOfSorted(_ sorted: [Float]) -> Float {
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Unfiltered, unsorted raw cosine of every eligible entry to the prompt.
    static func semanticSimilarities(
        graph: MemoryGraph,
        queryEmbedding: [Float],
        modelID: String,
        scope: EngineMemoryScope
    ) -> [ScoredMemoryID] {
        let dimensions = queryEmbedding.count
        guard dimensions > 0 else { return [] }
        return graph.memories.values.compactMap { entry in
            guard entry.active,
                  scopeAllows(entry.scope, requested: scope),
                  entry.embeddingMatches(model: modelID),
                  let embedding = entry.embedding,
                  embedding.count == dimensions else { return nil }
            return ScoredMemoryID(id: entry.id, score: cosineSimilarity(queryEmbedding, embedding))
        }
    }

    /// BM25 over `memories`. Inactive entries are skipped unless
    /// `requireActive` is `false`, which lets a lookup that was explicitly
    /// asked for archived entries rank them with the same scoring.
    public static func lexicalBM25(
        memories: [EngineMemoryEntry],
        query: String,
        scope: EngineMemoryScope = .all,
        limit: Int = 10,
        k1: Float = 1.2,
        b: Float = 0.75,
        requireActive: Bool = true
    ) -> [ScoredMemoryID] {
        guard limit > 0 else { return [] }
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return [] }
        return MemoryLexicalCorpus(memories: memories, scope: scope, requireActive: requireActive)
            .bm25(queryTokens: queryTokens, limit: limit, k1: k1, b: b)
    }

    /// BM25 of every query in `queries` over the same `memories`: one ranking
    /// per query, in order, each identical to
    /// ``lexicalBM25(memories:query:scope:limit:k1:b:requireActive:)`` for
    /// that query. The memories are tokenized once — and only when some query
    /// has tokens — and the corpus is shared by all the queries.
    static func lexicalBM25(
        memories: [EngineMemoryEntry],
        queries: [String],
        scope: EngineMemoryScope = .all,
        limit: Int = 10,
        k1: Float = 1.2,
        b: Float = 0.75,
        requireActive: Bool = true
    ) -> [[ScoredMemoryID]] {
        guard limit > 0 else { return queries.map { _ in [] } }
        var corpus: MemoryLexicalCorpus?
        var rankings: [[ScoredMemoryID]] = []
        rankings.reserveCapacity(queries.count)
        for query in queries {
            let queryTokens = tokens(query)
            guard !queryTokens.isEmpty else {
                rankings.append([])
                continue
            }
            let shared = corpus ?? MemoryLexicalCorpus(
                memories: memories,
                scope: scope,
                requireActive: requireActive
            )
            corpus = shared
            rankings.append(shared.bm25(queryTokens: queryTokens, limit: limit, k1: k1, b: b))
        }
        return rankings
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

    /// Max-normalised score fusion (CombSUM). Every ranking's scores are divided
    /// by that ranking's top score, so each list contributes values in `(0, 1]`
    /// regardless of its native scale (BM25 weights, cosines), and the
    /// per-entry contributions are summed. Unlike reciprocal-rank fusion the
    /// shape of each ranking survives: a hit that dominates one list keeps a
    /// score no mid-ranked entry of two lists can reach, while an entry near
    /// the top of both lists still outranks the top of either. Lists with a
    /// non-positive top score contribute nothing.
    public static func normalizedScoreFusion(
        rankedLists: [[ScoredMemoryID]],
        limit: Int = 10
    ) -> [ScoredMemoryID] {
        guard limit > 0 else { return [] }
        var scores: [String: Float] = [:]
        for list in rankedLists {
            guard let top = list.map(\.score).max(), top > 0 else { continue }
            for item in list where item.score > 0 {
                scores[item.id, default: 0] += item.score / top
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
            // Without entity tokens nothing can match: skip tokenizing the content.
            var entityMatches = 0
            if !entityTokens.isEmpty {
                let documentTokens = Set(tokens(memory.content))
                entityMatches = entityTokens.reduce(into: 0) { count, token in
                    if documentTokens.contains(token) { count += 1 }
                }
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
        MemoryTokenizer.tokens(text)
    }

    public static func scopeAllows(_ memoryScope: EngineMemoryScope, requested: EngineMemoryScope) -> Bool {
        switch requested {
        case .all: true
        case .project: memoryScope == .project || memoryScope == .all
        case .global: memoryScope == .global || memoryScope == .all
        }
    }
}

/// The BM25 documents of a memory set, tokenized once so that several queries
/// over the same set — the queries of one retrieval — share a single
/// tokenization and stemming pass. A document is an eligible entry (active
/// unless `requireActive` is `false`, and allowed by `scope`) with the term
/// frequencies and the token count of its `searchableText`.
///
/// Transient by design: it lives for one ranking call and nothing derived from
/// ``MemoryTokenizer`` is persisted.
struct MemoryLexicalCorpus: Sendable {
    struct Document: Sendable {
        let id: String
        let termFrequencies: [String: Int]
        let length: Int
    }

    let documents: [Document]
    /// Mean token count of `documents`; `0` when there are none.
    let averageLength: Float

    init(
        memories: [EngineMemoryEntry],
        scope: EngineMemoryScope = .all,
        requireActive: Bool = true
    ) {
        documents = memories
            .filter { (!requireActive || $0.active) && MemorySearch.scopeAllows($0.scope, requested: scope) }
            .map { entry in
                let tokens = MemorySearch.tokens(entry.searchableText)
                var frequencies: [String: Int] = [:]
                for token in tokens { frequencies[token, default: 0] += 1 }
                return Document(id: entry.id, termFrequencies: frequencies, length: tokens.count)
            }
        averageLength = documents.isEmpty
            ? 0
            : Float(documents.reduce(0) { $0 + $1.length }) / Float(documents.count)
    }

    /// BM25 of the already tokenized query over the documents, best first,
    /// ties broken by id.
    func bm25(queryTokens: [String], limit: Int, k1: Float, b: Float) -> [ScoredMemoryID] {
        guard limit > 0, !queryTokens.isEmpty, !documents.isEmpty, averageLength > 0 else { return [] }

        let querySet = Set(queryTokens)
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for token in querySet where document.termFrequencies[token] != nil {
                documentFrequency[token, default: 0] += 1
            }
        }

        let n = Float(documents.count)
        return documents.compactMap { document -> ScoredMemoryID? in
            guard document.length > 0 else { return nil }
            var score: Float = 0
            for token in queryTokens {
                guard let tfValue = document.termFrequencies[token], tfValue > 0 else { continue }
                let df = Float(documentFrequency[token] ?? 0)
                let idf = logf(1 + (n - df + 0.5) / (df + 0.5))
                let tf = Float(tfValue)
                let dl = Float(document.length)
                let denominator = tf + k1 * (1 - b + b * dl / averageLength)
                score += idf * (tf * (k1 + 1)) / denominator
            }
            return score > 0 ? ScoredMemoryID(id: document.id, score: score) : nil
        }
        .sorted {
            if $0.score == $1.score { return $0.id < $1.id }
            return $0.score > $1.score
        }
        .prefix(limit)
        .map { $0 }
    }
}
