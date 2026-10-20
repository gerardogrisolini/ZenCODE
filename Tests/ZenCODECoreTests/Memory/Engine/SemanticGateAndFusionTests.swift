//
//  SemanticGateAndFusionTests.swift
//  ZenCODECoreTests (memory engine)
//
//  Characterises the two retrieval mechanisms chosen after an A/B measurement
//  on a real memory graph (see Docs/memory.md): the per-prompt robust z-score
//  gate on semantic hits and max-normalised score fusion of the lexical and
//  semantic rankings.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Semantic gate and rank fusion")
struct SemanticGateAndFusionTests {
    private static let model = "test-model"

    /// A graph whose entries sit at the given cosine similarities to the
    /// query `[1, 0]` (2-D unit vectors at the matching angle).
    private static func graph(similarities: [Float]) -> MemoryGraph {
        var graph = MemoryGraph()
        for (index, cosine) in similarities.enumerated() {
            var entry = EngineMemoryEntry(id: "m\(index)", category: .fact, content: "entry \(index)")
            entry.setEmbedding([cosine, sqrtf(max(0, 1 - cosine * cosine))], model: model)
            graph.addMemory(entry)
        }
        return graph
    }

    @Test func gateKeepsOnlyTheEntryThatStandsOutFromTheBulk() {
        // Eight bulk entries in a narrow noise band plus one genuine match.
        let graph = Self.graph(similarities: [0.45, 0.47, 0.49, 0.50, 0.50, 0.51, 0.53, 0.55, 0.95])

        let gated = MemorySearch.semantic(
            graph: graph, queryEmbedding: [1, 0], modelID: Self.model,
            threshold: 0.4, minimumZScore: 2, limit: 10
        )
        let ungated = MemorySearch.semantic(
            graph: graph, queryEmbedding: [1, 0], modelID: Self.model,
            threshold: 0.4, minimumZScore: 0, limit: 10
        )

        #expect(gated.map(\.id) == ["m8"])
        #expect(ungated.count == 9)
    }

    @Test func gateYieldsNothingForAFlatDistribution() {
        let graph = Self.graph(similarities: Array(repeating: 0.6, count: 9))

        let gated = MemorySearch.semantic(
            graph: graph, queryEmbedding: [1, 0], modelID: Self.model,
            threshold: 0.4, minimumZScore: 2, limit: 10
        )

        #expect(gated.isEmpty)
    }

    @Test func gateIsNotAppliedBelowTheMinimumSampleSize() {
        // Four entries can never produce a 2σ outlier; the absolute floor alone applies.
        let graph = Self.graph(similarities: [0.5, 0.5, 0.5, 0.7])

        let hits = MemorySearch.semantic(
            graph: graph, queryEmbedding: [1, 0], modelID: Self.model,
            threshold: 0.4, minimumZScore: 2, limit: 10
        )

        #expect(graph.memories.count < MemorySearch.minimumGateSampleSize)
        #expect(hits.count == 4)
        #expect(hits.first?.id == "m3")
    }

    @Test func robustScaleIsNotInflatedByAFewGenuineMatches() {
        // Three matches among ten: with mean/standard deviation the matches
        // inflate the spread until nothing passes 2σ; median/MAD keeps them.
        let bulk: [Float] = [0.38, 0.40, 0.41, 0.42, 0.43, 0.44, 0.46]
        let graph = Self.graph(similarities: bulk + [0.74, 0.75, 0.76])

        let hits = MemorySearch.semantic(
            graph: graph, queryEmbedding: [1, 0], modelID: Self.model,
            threshold: 0.4, minimumZScore: 2, limit: 10
        )

        #expect(Set(hits.map(\.id)) == ["m7", "m8", "m9"])
    }

    @Test func absoluteThresholdStillAppliesUnderTheGate() {
        let graph = Self.graph(similarities: [0.10, 0.11, 0.12, 0.12, 0.13, 0.13, 0.14, 0.15, 0.35])

        let hits = MemorySearch.semantic(
            graph: graph, queryEmbedding: [1, 0], modelID: Self.model,
            threshold: 0.4, minimumZScore: 2, limit: 10
        )

        #expect(hits.isEmpty)
    }

    @Test func normalizedFusionKeepsADominantSingleListHitAhead() {
        let lexical = [
            ScoredMemoryID(id: "exact", score: 10),
            ScoredMemoryID(id: "both", score: 4),
            ScoredMemoryID(id: "weak", score: 3),
        ]
        let semantic = [
            ScoredMemoryID(id: "paraphrase", score: 0.8),
            ScoredMemoryID(id: "both", score: 0.4),
            ScoredMemoryID(id: "weak", score: 0.3),
        ]

        let normalized = MemorySearch.normalizedScoreFusion(rankedLists: [lexical, semantic], limit: 10)
        let reciprocal = MemorySearch.reciprocalRankFusion(rankedLists: [lexical, semantic], rankConstant: 60, limit: 10)

        // Each list's top keeps a full unit; "both" sums 0.4 + 0.5 = 0.9.
        #expect(Set(normalized.prefix(2).map(\.id)) == ["exact", "paraphrase"])
        #expect(normalized[2].id == "both")
        // Reciprocal ranks reward mere presence in both lists.
        #expect(reciprocal.first?.id == "both")
    }

    @Test func normalizedFusionRanksAnEntryNearTheTopOfBothListsFirst() {
        let lexical = [ScoredMemoryID(id: "a", score: 10), ScoredMemoryID(id: "shared", score: 9)]
        let semantic = [ScoredMemoryID(id: "b", score: 0.7), ScoredMemoryID(id: "shared", score: 0.65)]

        let fused = MemorySearch.normalizedScoreFusion(rankedLists: [lexical, semantic], limit: 10)

        #expect(fused.first?.id == "shared")
        #expect(fused.first.map { abs($0.score - (0.9 + 0.65 / 0.7)) < 0.001 } == true)
    }

    @Test func normalizedFusionIgnoresListsWithoutPositiveScores() {
        let lexical = [ScoredMemoryID(id: "a", score: 2)]
        let empty: [ScoredMemoryID] = []
        let zeros = [ScoredMemoryID(id: "z", score: 0)]

        let fused = MemorySearch.normalizedScoreFusion(rankedLists: [lexical, empty, zeros], limit: 10)

        #expect(fused.map(\.id) == ["a"])
        #expect(fused.first?.score == 1)
    }

    @Test func engineDefaultsUseTheMeasuredConfiguration() {
        let configuration = MemoryEngineConfiguration()

        #expect(configuration.fusion == .normalizedScore)
        #expect(configuration.semanticMinimumZScore == 2.5)
        #expect(configuration.similarityThreshold == 0.4)
    }
}
