//
//  MemoryEngine+Retrieval.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

extension MemoryEngine {
    /// Read-only analyze → retrieve → select, as ``recallDetailed(_:)`` but with no
    /// retrieval maintenance and no persistence. Use it for lookups such as
    /// `memory.search`, where mutating counters/confidence/links or failing on a
    /// save would be a surprising side effect.
    public func searchReadOnlyDetailed(
        _ prompt: String,
        scope: EngineMemoryScope = .all
    ) async throws -> MemoryRecallResult {
        let (plan, candidates, selected) = try await retrieveAndSelect(prompt, scope: scope)
        return MemoryRecallResult(plan: plan, candidates: candidates, selected: selected)
    }

    /// Read-only retrieval returning only the selected candidates.
    public func searchReadOnly(
        _ query: String,
        scope: EngineMemoryScope = .all
    ) async throws -> [MemoryCandidate] {
        try await searchReadOnlyDetailed(query, scope: scope).selected
    }

    /// Maintenance-free lexical fallback for bounded automatic recall. It runs
    /// beside the full (semantic) retrieval so a slow embedding endpoint cannot
    /// erase lexical results at the turn deadline, and performs no maintenance so
    /// confidence/counters/links are never applied twice.
    func lexicalContextReadOnly(
        for prompt: String,
        scope: EngineMemoryScope,
        graph suppliedGraph: MemoryGraph
    ) async throws -> String {
        let result = try await retrieveAndSelect(
            prompt,
            scope: scope,
            graph: suppliedGraph,
            includeSemantic: false
        )
        return contextFormatter.format(result.selected)
    }

    /// Read-only retrieval over an explicitly supplied graph: store-level reads
    /// resolve one coherent graph per request (see ``freshSnapshotForReadOnly()``)
    /// and run the pipeline over it, with no maintenance or persistence.
    ///
    /// `limit` is the number of ranked results an explicit lookup asked for:
    /// every retrieval stage is widened to at least that many hits and the
    /// selection honours it, so `candidates` can satisfy the request instead of
    /// being capped by the automatic-recall configuration.
    func searchReadOnlyDetailed(
        _ prompt: String,
        scope: EngineMemoryScope,
        graph suppliedGraph: MemoryGraph,
        limit: Int? = nil
    ) async throws -> MemoryRecallResult {
        let (plan, candidates, selected) = try await retrieveAndSelect(
            prompt,
            scope: scope,
            graph: suppliedGraph,
            limit: limit
        )
        return MemoryRecallResult(plan: plan, candidates: candidates, selected: selected)
    }

    /// The shared analyze → retrieve → select core of ``recallDetailed(_:)`` and
    /// ``searchReadOnlyDetailed(_:scope:)``. It performs no mutation or
    /// persistence; callers differ only in whether maintenance runs afterwards.
    func retrieveAndSelect(
        _ prompt: String,
        scope: EngineMemoryScope,
        graph suppliedGraph: MemoryGraph? = nil,
        includeSemantic: Bool = true,
        limit: Int? = nil
    ) async throws -> (plan: MemoryQueryPlan, candidates: [MemoryCandidate], selected: [MemoryCandidate]) {
        let plan = try await analyzeWithPolicy(prompt)
        guard plan.shouldRecall, configuration.maxResults > 0 else {
            return (plan, [], [])
        }

        // An explicit lookup limit widens every stage, so a caller asking for
        // N ranked results is not silently capped by the recall configuration;
        // automatic recall passes no limit and keeps the configured caps.
        let requested = limit ?? 0
        let lexicalLimit = max(configuration.maxLexicalHits, requested)
        let semanticLimit = max(configuration.maxSemanticHits, requested)
        let candidateLimit = max(configuration.maxCandidateResults, requested)
        let resultLimit = limit ?? configuration.maxResults

        // The live graph is captured only after the suspending analysis; a
        // supplied store snapshot stays fixed for the request.
        let graph = suppliedGraph ?? self.graph

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
                limit: lexicalLimit
            )
            if !lexical.isEmpty { rankings.append(lexical) }
        }

        let metadata = MemorySearch.metadataRanking(
            memories: activeMemories,
            tags: plan.tags,
            entities: plan.entities,
            scope: scope,
            limit: lexicalLimit
        )
        if !metadata.isEmpty { rankings.append(metadata) }

        if includeSemantic,
           let embedder,
           configuration.maxSemanticQueries > 0 {
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
                        limit: semanticLimit
                    )
                    if !semantic.isEmpty { rankings.append(semantic) }
                } catch let cancellation as CancellationError {
                    // Cancellation is not an endpoint failure; keep it observable.
                    throw cancellation
                } catch {
                    // Cancellation surfaced as another error type must not degrade
                    // into a BM25 fallback.
                    try Task.checkCancellation()
                    // BM25 rankings are already computed: report through the
                    // reporter and continue with BM25-only results.
                    semanticFailures += 1
                    if firstFailure == nil { firstFailure = error }
                }
            }
            if semanticFailures > 0 {
                // Redacted: never the query text, vectors, endpoint URLs,
                // response bodies or API keys.
                semanticFailureReporter(
                    "semantic embedding retrieval failed (\(MemorySemanticFallbackDiagnostics.embeddingFailureSummary(firstFailure))); continuing with BM25-only results (failedQueries=\(semanticFailures)/\(semanticQueries.count))."
                )
            }
        }

        let seedLimit = max(candidateLimit, lexicalLimit)
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

        // `cascadeRetrieve` is `mutating` (it counts retrievals): run it on a local
        // copy so this core never mutates the live graph. The counter is folded
        // into the maintenance transaction in `recallDetailed`, where a concurrent
        // commit cannot silently drop it.
        var traversal = graph
        let cascaded = traversal.cascadeRetrieve(
            seeds: seeds,
            maxDepth: configuration.maxDepth,
            maxResults: candidateLimit,
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

        let selected = try await selectWithPolicy(context: prompt, candidates: candidates, limit: resultLimit)
        return (plan, candidates, selected)
    }
    func retrievalQueries(from plan: MemoryQueryPlan, originalPrompt: String) -> [String] {
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

    func analyzeWithPolicy(_ prompt: String) async throws -> MemoryQueryPlan {
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

    func selectWithPolicy(
        context: String,
        candidates: [MemoryCandidate],
        limit: Int? = nil
    ) async throws -> [MemoryCandidate] {
        let resultLimit = limit ?? configuration.maxResults
        do {
            let proposed = try await selector.select(
                context: context,
                candidates: candidates,
                limit: resultLimit
            )
            let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.memory.id, $0) })
            var seen = Set<String>()
            return proposed.compactMap { candidate in
                let id = candidate.memory.id
                guard seen.insert(id).inserted else { return nil }
                return byID[id]
            }.prefix(resultLimit).map { $0 }
        } catch {
            switch configuration.intelligenceFailurePolicy {
            case .fallback:
                return Array(candidates.prefix(resultLimit))
            case .propagate:
                throw error
            }
        }
    }
}
