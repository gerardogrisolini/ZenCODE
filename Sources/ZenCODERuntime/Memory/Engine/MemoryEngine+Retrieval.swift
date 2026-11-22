//
//  MemoryEngine+Retrieval.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

extension MemoryEngine {
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

    /// Read-only analyze → retrieve → select, as ``recallDetailed(_:scope:visibility:)`` but
    /// with no retrieval maintenance and no persistence, for lookups such as
    /// `memory.search`, where mutating counters/confidence/links or failing on a
    /// save would be a surprising side effect. It runs over an explicitly
    /// supplied graph: store-level reads resolve one coherent graph per request
    /// (see ``freshSnapshotForReadOnly()``) and run the pipeline over it.
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

    /// The shared analyze → retrieve → select core of ``recallDetailed(_:scope:visibility:)``
    /// and ``searchReadOnlyDetailed(_:scope:graph:limit:)``. It performs no
    /// mutation or persistence; callers differ only in whether maintenance runs
    /// afterwards.
    func retrieveAndSelect(
        _ prompt: String,
        scope: EngineMemoryScope,
        graph suppliedGraph: MemoryGraph? = nil,
        includeSemantic: Bool = true,
        limit: Int? = nil,
        visibility: MemoryAuthorScope? = nil
    ) async throws -> (plan: MemoryQueryPlan, candidates: [MemoryCandidate], selected: [MemoryCandidate]) {
        let detailed = try await retrieveAndSelectDetailed(
            prompt,
            scope: scope,
            graph: suppliedGraph,
            includeSemantic: includeSemantic,
            limit: limit,
            visibility: visibility,
            // The evidence is not returned here: it is only worked out when the
            // minimum evidence gate needs it to decide the selection.
            collectEvidence: false
        )
        return (detailed.plan, detailed.candidates, detailed.selected)
    }

    /// ``retrieveAndSelect(_:scope:graph:includeSemantic:limit:)`` that also
    /// reports the ids of the retrieval seeds (the fused lexical/semantic hits
    /// before the graph cascade), so a measurement can tell the entries found
    /// by the query from those reached only through the graph. `seedIDs` is
    /// empty when the recall is skipped or finds no seed.
    ///
    /// `evidence` holds, for every candidate, what it shares with the query
    /// (see ``MemoryCandidateEvidence``), `lexicalScale` the corpus size `n` and
    /// `idfMax(n)` the relative lexical threshold is taken on, and `semanticRan`
    /// tells whether the semantic search completed for this prompt (an embedder,
    /// `includeSemantic` and a query embedding that did not fail): the facts the
    /// minimum evidence gate (``MemoryEngineConfiguration/recallMinimumLexicalEvidenceRatio``,
    /// ``MemoryEngineConfiguration/recallMinimumSemanticSimilarity``,
    /// ``MemoryEngineConfiguration/recallLexicalSupportMinimumSimilarity``)
    /// decides on. The gate only narrows what the selector may choose from:
    /// `candidates` are always the full list, and `selected` is empty when none
    /// qualifies.
    ///
    /// The lexical evidence needs the corpus the BM25 ranks. With the default
    /// BM25 index the memories are tokenized once per retrieval and that corpus
    /// serves both the rankings and the evidence (the scores are those of
    /// ``BM25MemoryIndex``); a custom index keeps its own ranking and the
    /// evidence costs one more tokenization pass. `collectEvidence: false` skips
    /// the evidence unless the gate is on, in which case the selection needs it
    /// and `evidence` is filled anyway.
    ///
    /// `visibility` restricts the retrieval to the entries one profile owns
    /// (``MemoryGraph/restricted(to:)``): rankings, semantic hits and lexical
    /// statistics (the BM25 IDF, `idfMax(n)` of the evidence gate) are those of
    /// the visible entries only. `nil` retrieves from the whole graph.
    func retrieveAndSelectDetailed(
        _ prompt: String,
        scope: EngineMemoryScope,
        graph suppliedGraph: MemoryGraph? = nil,
        includeSemantic: Bool = true,
        limit: Int? = nil,
        visibility: MemoryAuthorScope? = nil,
        collectEvidence: Bool = true
    ) async throws -> (
        plan: MemoryQueryPlan,
        candidates: [MemoryCandidate],
        selected: [MemoryCandidate],
        seedIDs: Set<String>,
        evidence: [String: MemoryCandidateEvidence],
        lexicalScale: MemoryLexicalScale,
        semanticRan: Bool
    ) {
        let plan = try await analyzeWithPolicy(prompt)
        guard plan.shouldRecall, configuration.maxResults > 0 else {
            return (plan, [], [], [], [:], .empty, false)
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
        // supplied store snapshot stays fixed for the request. Either is
        // restricted to the entries `visibility` allows before anything ranks.
        let graph = (suppliedGraph ?? self.graph).restricted(to: visibility)

        let activeMemories = Array(graph.memories.values)
        let queries = retrievalQueries(from: plan, originalPrompt: prompt)
        guard !queries.isEmpty else {
            return (plan, [], [], [], [:], .empty, false)
        }

        // Age/confidence weight of every entry, computed once per retrieval.
        // It is applied to each ranking *before* fusion so that it reorders by
        // relevance × freshness within a list; applied after reciprocal-rank
        // fusion it would act on near-flat rank scores and simply sort by age.
        let now = Date()
        let agePolicy = configuration.agePolicy
        let weights: [String: Float] = Dictionary(
            uniqueKeysWithValues: activeMemories.map { memory in
                (memory.id, memory.effectiveConfidence(at: now, policy: agePolicy))
            }
        )
        // Each stage fetches more than it keeps, so an entry just outside the
        // raw top list can still enter it once freshness is accounted for.
        func weighted(_ ranking: [ScoredMemoryID], keeping limit: Int) -> [ScoredMemoryID] {
            ranking
                .map { ScoredMemoryID(id: $0.id, score: $0.score * (weights[$0.id] ?? 1)) }
                .sorted {
                    if $0.score == $1.score { return $0.id < $1.id }
                    return $0.score > $1.score
                }
                .prefix(limit)
                .map { $0 }
        }
        let overfetch = 4

        // The embedding request does not depend on the local rankings, so it
        // starts before them: the endpoint's latency overlaps the BM25 pass
        // over the whole graph instead of following it.
        let semanticQueries = includeSemantic && embedder != nil && configuration.maxSemanticQueries > 0
            ? Array(queries.prefix(configuration.maxSemanticQueries))
            : []
        async let pendingQueryEmbeddings = Self.embeddings(for: semanticQueries, using: embedder)

        var rankings: [[ScoredMemoryID]] = []
        rankings.reserveCapacity(queries.count + configuration.maxSemanticQueries + 1)

        // One batch call: the default BM25 index tokenizes the memories once
        // and shares them across every query of this retrieval. When the
        // evidence is needed too (the recall gate, or the caller asked for it)
        // the same corpus also serves the evidence, so a retrieval does not
        // tokenize the memories a second time; a custom index is searched as
        // it is and the evidence builds its own corpus later.
        // The cosine thresholds were measured on one model: for any other the
        // raw cosine scale differs and they count as `nil`. The gate is on when
        // at least one threshold is effectively set.
        let semanticThresholdsApply = configuration.appliesSemanticThresholds(toModelID: embedder?.modelID)
        let minimumLexicalRatio = configuration.recallMinimumLexicalEvidenceRatio
        let minimumSemantic = semanticThresholdsApply ? configuration.recallMinimumSemanticSimilarity : nil
        let minimumLexicalSupport = semanticThresholdsApply ? configuration.recallLexicalSupportMinimumSimilarity : nil
        let evidenceGateActive = minimumLexicalRatio != nil || minimumSemantic != nil || minimumLexicalSupport != nil
        let needsEvidence = collectEvidence || evidenceGateActive

        let lexicalRankings: [[ScoredMemoryID]]
        let sharedLexical: MemoryLexicalRetrieval?
        if needsEvidence, let bm25 = lexicalIndex as? BM25MemoryIndex {
            let shared = await Self.sharedLexicalRetrieval(
                using: bm25,
                queries: queries,
                memories: activeMemories,
                scope: scope,
                limit: lexicalLimit * overfetch
            )
            sharedLexical = shared.retrieval
            lexicalRankings = shared.rankings
        } else {
            sharedLexical = nil
            lexicalRankings = try await lexicalIndex.search(
                queries: queries,
                memories: activeMemories,
                scope: scope,
                limit: lexicalLimit * overfetch
            )
        }
        for lexical in lexicalRankings where !lexical.isEmpty {
            rankings.append(weighted(lexical, keeping: lexicalLimit))
        }

        let metadata = MemorySearch.metadataRanking(
            memories: activeMemories,
            tags: plan.tags,
            entities: plan.entities,
            scope: scope,
            limit: lexicalLimit * overfetch
        )
        if !metadata.isEmpty { rankings.append(weighted(metadata, keeping: lexicalLimit)) }

        let queryEmbeddings = await pendingQueryEmbeddings
        // What the minimum evidence gate needs from the semantic search: that
        // it completed, the first query vector it used (the cosine of the
        // evidence), and the ids of the hits that passed the semantic gate.
        var semanticRan = false
        var evidenceQueryEmbedding: [Float]?
        var gatedSemanticHitIDs = Set<String>()
        if let embedder, !semanticQueries.isEmpty {
            var semanticFailures = 0
            var firstFailure: (any Error)?
            for embedding in queryEmbeddings {
                do {
                    let queryEmbedding = try embedding.get()
                    // Gated per prompt (see `MemorySearch.semantic`): a prompt
                    // with no semantic outlier contributes no semantic seeds
                    // instead of a noise-filled list.
                    let semantic = MemorySearch.semantic(
                        graph: graph,
                        queryEmbedding: queryEmbedding,
                        modelID: embedder.modelID,
                        scope: scope,
                        threshold: configuration.similarityThreshold,
                        minimumZScore: configuration.semanticMinimumZScore,
                        limit: semanticLimit * overfetch
                    )
                    if !queryEmbedding.isEmpty {
                        semanticRan = true
                        if evidenceQueryEmbedding == nil { evidenceQueryEmbedding = queryEmbedding }
                        gatedSemanticHitIDs.formUnion(semantic.map(\.id))
                    }
                    if !semantic.isEmpty { rankings.append(weighted(semantic, keeping: semanticLimit)) }
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
            // Measured on a real graph (see Docs/memory.md): max-normalised
            // score fusion keeps an exact lexical hit on top where reciprocal
            // ranks let any entry present in both lists outrank it.
            switch configuration.fusion {
            case .reciprocalRank:
                seeds = MemorySearch.reciprocalRankFusion(
                    rankedLists: rankings,
                    rankConstant: configuration.rrfRankConstant,
                    limit: seedLimit
                )
            case .normalizedScore:
                seeds = MemorySearch.normalizedScoreFusion(
                    rankedLists: rankings,
                    limit: seedLimit
                )
            }
        }

        guard !seeds.isEmpty else {
            return (plan, [], [], [], [:], sharedLexical?.scale ?? .empty, semanticRan)
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
            scope: scope,
            raisesSeeds: configuration.cascadeRaisesSeeds
        )

        // Seeds already carry their weight; a node reached only through the
        // graph inherits a decayed seed score, so it is weighted here by its
        // own age and confidence — exactly once either way.
        let seedIDs = Set(seeds.map(\.id))
        let candidates = cascaded.compactMap { item -> MemoryCandidate? in
            guard let memory = graph.memories[item.id], memory.active else { return nil }
            let weight = seedIDs.contains(item.id) ? 1 : (weights[item.id] ?? 1)
            return MemoryCandidate(memory: memory, score: item.score * weight)
        }.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.memory.id < rhs.memory.id }
            return lhs.score > rhs.score
        }

        let evidence: [String: MemoryCandidateEvidence]
        var lexicalScale = sharedLexical?.scale ?? .empty
        if needsEvidence, !candidates.isEmpty {
            let lexicalRetrieval = sharedLexical ?? MemoryLexicalRetrieval(
                memories: activeMemories,
                queries: queries,
                scope: scope
            )
            lexicalScale = lexicalRetrieval.scale
            evidence = Self.candidateEvidence(
                for: candidates,
                lexical: lexicalRetrieval.evidence(ids: Set(candidates.map(\.memory.id))),
                seedIDs: seedIDs,
                queryEmbedding: evidenceQueryEmbedding,
                modelID: embedder?.modelID
            )
        } else {
            evidence = [:]
        }

        // The minimum evidence gate and the graph-only cap both narrow the list
        // the selector chooses from; the returned `candidates` stay complete.
        let selectable = Self.limitingGraphOnly(
            Self.filteringByMinimumEvidence(
                candidates,
                evidence: evidence,
                lexicalScale: lexicalScale,
                semanticRan: semanticRan,
                gatedSemanticHitIDs: gatedSemanticHitIDs,
                minimumLexicalRatio: minimumLexicalRatio,
                minimumSemantic: minimumSemantic,
                minimumLexicalSupportSimilarity: minimumLexicalSupport
            ),
            seedIDs: seedIDs,
            maximum: configuration.maxGraphOnlySelections
        )
        // Nothing with enough evidence: there is nothing to select from, so the
        // selector (possibly a model call) is not asked.
        if evidenceGateActive, selectable.isEmpty {
            return (plan, candidates, [], seedIDs, evidence, lexicalScale, semanticRan)
        }
        let selected = try await selectWithPolicy(context: prompt, candidates: selectable, limit: resultLimit)
        return (plan, candidates, selected, seedIDs, evidence, lexicalScale, semanticRan)
    }

    /// The BM25 rankings of the default index for every query and the lexical
    /// retrieval (queries tokenized, corpus built) they were computed on, which
    /// the candidate evidence reads again. Static and `async` like the call to
    /// a ``MemoryIndex``: the tokenization of the whole graph runs off the
    /// engine actor, so a concurrent lexical-only recall is not serialized
    /// behind it. The rankings are those of ``BM25MemoryIndex/search(queries:memories:scope:limit:)``.
    private static func sharedLexicalRetrieval(
        using index: BM25MemoryIndex,
        queries: [String],
        memories: [EngineMemoryEntry],
        scope: EngineMemoryScope,
        limit: Int
    ) async -> (retrieval: MemoryLexicalRetrieval, rankings: [[ScoredMemoryID]]) {
        let retrieval = MemoryLexicalRetrieval(memories: memories, queries: queries, scope: scope)
        return (retrieval, retrieval.rankings(limit: limit, k1: index.k1, b: index.b))
    }

    /// The evidence of each candidate: its `lexical` evidence (computed over
    /// the corpus the BM25 ranks, the active entries of the retrieval scope,
    /// for the union of the distinct terms of all the retrieval queries) and
    /// its raw cosine to the first query embedding when the semantic search
    /// ran. Computed for the candidates only.
    private static func candidateEvidence(
        for candidates: [MemoryCandidate],
        lexical: [String: Float],
        seedIDs: Set<String>,
        queryEmbedding: [Float]?,
        modelID: String?
    ) -> [String: MemoryCandidateEvidence] {
        guard !candidates.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: candidates.map { candidate in
            let semantic: Float? = if let queryEmbedding, let modelID {
                MemorySearch.semanticSimilarity(of: candidate.memory, to: queryEmbedding, modelID: modelID)
            } else {
                nil
            }
            return (candidate.memory.id, MemoryCandidateEvidence(
                lexical: lexical[candidate.memory.id] ?? 0,
                semantic: semantic,
                isSeed: seedIDs.contains(candidate.memory.id)
            ))
        })
    }

    /// The candidates with enough evidence to be selected, in the same order.
    /// With the three thresholds `nil` the gate is off and every candidate
    /// stays. Otherwise a candidate must be a retrieval seed and
    /// - `lexicalOK` is its lexical evidence ≥ `minimumLexicalRatio × idfMax(n)`
    ///   (`lexicalScale`; with no ratio: any evidence at all, > 0). With no
    ///   document in the corpus (`n = 0`) the lexical rule selects nothing;
    /// - when the semantic search ran for the prompt *and* the candidate has a
    ///   cosine (a vector of the embedder's model), it is selectable if
    ///   `semanticOK || (lexicalOK && cosineOK)`, where `semanticOK` is cosine
    ///   ≥ `minimumSemantic` (with none: being a hit that passed the semantic
    ///   gate) and `cosineOK` is cosine ≥ `minimumLexicalSupportSimilarity`
    ///   (with none: always true), so a lexically supported entry that is far
    ///   from the query in the embedding space is rejected;
    /// - otherwise (no semantic search, an endpoint failure, `includeSemantic`
    ///   off, or a candidate without a vector of the model) only `lexicalOK`
    ///   decides and both cosine thresholds are ignored.
    ///
    /// The caller passes the cosine thresholds already resolved against the
    /// embedder's model (``MemoryEngineConfiguration/appliesSemanticThresholds(toModelID:)``):
    /// `nil` for a model they were not measured on.
    ///
    /// With `minimumLexicalSupportSimilarity` `nil` this is the plain
    /// "lexically or semantically supported" rule.
    private static func filteringByMinimumEvidence(
        _ candidates: [MemoryCandidate],
        evidence: [String: MemoryCandidateEvidence],
        lexicalScale: MemoryLexicalScale,
        semanticRan: Bool,
        gatedSemanticHitIDs: Set<String>,
        minimumLexicalRatio: Float?,
        minimumSemantic: Float?,
        minimumLexicalSupportSimilarity: Float?
    ) -> [MemoryCandidate] {
        guard minimumLexicalRatio != nil || minimumSemantic != nil || minimumLexicalSupportSimilarity != nil else {
            return candidates
        }
        let lexicalThreshold = minimumLexicalRatio.map { lexicalScale.threshold(ratio: $0) }
        return candidates.filter { candidate in
            let id = candidate.memory.id
            guard let evidence = evidence[id], evidence.isSeed else { return false }
            // An empty corpus has no term to be evidenced by.
            let lexicalOK = lexicalScale.documentCount > 0
                && (lexicalThreshold.map { evidence.lexical >= $0 } ?? (evidence.lexical > 0))
            guard semanticRan, let cosine = evidence.semantic else { return lexicalOK }
            let semanticOK = minimumSemantic.map { cosine >= $0 } ?? gatedSemanticHitIDs.contains(id)
            guard !semanticOK else { return true }
            let cosineOK = minimumLexicalSupportSimilarity.map { cosine >= $0 } ?? true
            return lexicalOK && cosineOK
        }
    }

    /// The candidates the selector may choose from: scanning in order, the
    /// entries that are not seeds beyond the first `maximum` are dropped, so
    /// the slots they would take go to the following candidates. `nil` keeps
    /// every candidate.
    private static func limitingGraphOnly(
        _ candidates: [MemoryCandidate],
        seedIDs: Set<String>,
        maximum: Int?
    ) -> [MemoryCandidate] {
        guard let maximum else { return candidates }
        var graphOnly = 0
        return candidates.filter { candidate in
            guard !seedIDs.contains(candidate.memory.id) else { return true }
            graphOnly += 1
            return graphOnly <= maximum
        }
    }

    /// The embedding of each query, in order, or the error its request ended
    /// with. Off the engine actor, so the requests run while the engine ranks
    /// locally; the caller handles the failures where it used to await them.
    private static func embeddings(
        for queries: [String],
        using embedder: (any EmbeddingProvider)?
    ) async -> [Result<[Float], any Error>] {
        guard let embedder else { return [] }
        var embeddings: [Result<[Float], any Error>] = []
        embeddings.reserveCapacity(queries.count)
        for query in queries {
            do {
                embeddings.append(.success(try await embedder.embed(query)))
            } catch {
                embeddings.append(.failure(error))
            }
        }
        return embeddings
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
