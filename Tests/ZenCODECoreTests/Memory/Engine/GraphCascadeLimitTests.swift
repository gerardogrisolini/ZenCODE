import Foundation
import Testing
@testable import ZenCODERuntime

/// The knobs that bound the graph cascade of automatic recall:
/// `cascadeRaisesSeeds` (the propagation may not overwrite the score of a
/// seed) and `maxGraphOnlySelections` (a cap on the selected entries that no
/// query hit reached). The cascade itself is off by default (`maxDepth` 0, so
/// both knobs are inert): the tests of its mechanics pass `maxDepth: 2`
/// explicitly, and the characterization tests pin the default.
///
/// The seeds of these tests are scripted (a fixed ranking that ignores the
/// query) and share no term with the prompt, so they carry no lexical evidence:
/// the suite is about the cascade and the selector, not about the evidence
/// gate (on by default, covered by `RecallEvidenceGateTests`), which would
/// select none of them. The engine helper therefore turns the gate off
/// explicitly, and nothing else of the configuration changes.
@Suite
struct GraphCascadeLimitTests {
    // MARK: - Fixtures

    /// Lexical index that ignores the query and returns a fixed ranking, so the
    /// seeds and their scores are exactly the ones a test declares.
    private struct ScriptedIndex: MemoryIndex {
        let ranking: [ScoredMemoryID]

        func search(
            query: String,
            memories: [EngineMemoryEntry],
            scope: EngineMemoryScope,
            limit: Int
        ) async throws -> [ScoredMemoryID] {
            Array(ranking.prefix(limit))
        }
    }

    private static func entry(_ id: String, tags: [String] = []) -> EngineMemoryEntry {
        EngineMemoryEntry(id: id, category: .fact, content: "Memory \(id)", tags: tags)
    }

    private static func graph(
        _ entries: [EngineMemoryEntry],
        relations: [(from: String, to: String, weight: Float)] = []
    ) -> MemoryGraph {
        var graph = MemoryGraph()
        for entry in entries { graph.addMemory(entry) }
        for relation in relations {
            graph.linkMemories(from: relation.from, to: relation.to, weight: relation.weight)
        }
        return graph
    }

    private static func engine(
        graph: MemoryGraph,
        seeds: [(id: String, score: Float)],
        configuration: MemoryEngineConfiguration
    ) -> MemoryEngine {
        MemoryEngine(
            graph: graph,
            lexicalIndex: ScriptedIndex(ranking: seeds.map { ScoredMemoryID(id: $0.id, score: $0.score) }),
            selector: ScoreThresholdMemorySelector(),
            configuration: configuration.withoutEvidenceGate
        )
    }

    private static func score(of id: String, in ranking: [ScoredMemoryID]) -> Float? {
        ranking.first { $0.id == id }?.score
    }

    private static func score(of id: String, in candidates: [MemoryCandidate]) -> Float? {
        candidates.first { $0.memory.id == id }?.score
    }

    private static func isClose(_ value: Float?, to expected: Float) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-3
    }

    /// The same entries with the same scores, up to the float noise that the
    /// age weight (computed from `Date()` at each retrieval) introduces
    /// between two runs; the order of near-ties is deliberately not compared.
    private static func sameCandidates(_ lhs: [MemoryCandidate], _ rhs: [MemoryCandidate]) -> Bool {
        guard Set(lhs.map(\.memory.id)) == Set(rhs.map(\.memory.id)) else { return false }
        return lhs.allSatisfy { candidate in
            isClose(score(of: candidate.memory.id, in: rhs), to: candidate.score)
        }
    }

    /// `strong` (1.0) → `weak` (0.2) at 0.9, `weak` → `beyond` at 0.9. With the
    /// default decay a relation of 0.9 gives the neighbour 0.9 · 0.7 = 0.63 of
    /// the source score.
    private static func chainGraph() -> MemoryGraph {
        graph(
            [entry("strong"), entry("weak"), entry("beyond")],
            relations: [("strong", "weak", 0.9), ("weak", "beyond", 0.9)]
        )
    }

    // MARK: - Configuration

    @Test
    func defaultsTurnTheCascadeOffAndLeaveItsKnobsAtTheirReference() {
        let configuration = MemoryEngineConfiguration()
        // The expansion is off; the other two knobs are inert at depth 0 and
        // keep their reference values for a cascade that is turned back on.
        #expect(configuration.maxDepth == 0)
        #expect(configuration.cascadeRaisesSeeds)
        #expect(configuration.maxGraphOnlySelections == nil)
        #expect(MemoryEngineConfiguration(maxDepth: -1).maxDepth == 0)
        #expect(MemoryEngineConfiguration(maxGraphOnlySelections: -3).maxGraphOnlySelections == 0)
        #expect(MemoryEngineConfiguration(maxDepth: 2) != configuration)
        #expect(MemoryEngineConfiguration(cascadeRaisesSeeds: false) != configuration)
        #expect(MemoryEngineConfiguration(maxGraphOnlySelections: 2) != configuration)
    }

    // MARK: - Default: the cascade is off

    /// A single seed and one neighbour that only the graph can reach: through a
    /// `relates_to` edge (0.9 → 0.63 of the seed) or through a shared tag
    /// (`has_tag` 0.8 → 0.56). Both clear the selector's relative threshold
    /// whenever the cascade runs.
    private static func neighbourGraph(linkedBy link: String) -> MemoryGraph {
        switch link {
        case "relates_to":
            return graph(
                [entry("seed"), entry("neighbour")],
                relations: [("seed", "neighbour", 0.9)]
            )
        default:
            return graph([entry("seed", tags: ["swift"]), entry("neighbour", tags: ["swift"])])
        }
    }

    @Test(arguments: ["relates_to", "shared_tag"])
    func withTheDefaultConfigurationAGraphNeighbourIsNeitherCandidateNorSelected(link: String) async throws {
        let graph = Self.neighbourGraph(linkedBy: link)
        let seeds: [(id: String, score: Float)] = [("seed", 1)]

        let result = try await Self.engine(
            graph: graph,
            seeds: seeds,
            configuration: MemoryEngineConfiguration()
        ).retrieveAndSelectDetailed("anything", scope: .all)

        #expect(result.seedIDs == ["seed"])
        #expect(result.candidates.map(\.memory.id) == ["seed"])
        #expect(result.selected.map(\.memory.id) == ["seed"])

        // Control: the same graph does reach the neighbour once the cascade is
        // on, so the assertions above are not vacuous.
        let expanded = try await Self.engine(
            graph: graph,
            seeds: seeds,
            configuration: MemoryEngineConfiguration(maxDepth: 2)
        ).retrieveAndSelectDetailed("anything", scope: .all)

        #expect(Set(expanded.candidates.map(\.memory.id)) == ["seed", "neighbour"])
        #expect(Set(expanded.selected.map(\.memory.id)) == ["seed", "neighbour"])
    }

    // MARK: - cascadeRetrieve(raisesSeeds:)

    @Test
    func cascadeRaisesAWeakSeedByDefault() {
        var graph = Self.chainGraph()
        let result = graph.cascadeRetrieve(
            seeds: [ScoredMemoryID(id: "strong", score: 1), ScoredMemoryID(id: "weak", score: 0.2)],
            maxDepth: 2,
            maxResults: 10
        )

        #expect(Self.isClose(Self.score(of: "weak", in: result), to: 0.63))
        #expect(Self.isClose(Self.score(of: "strong", in: result), to: 1))
    }

    @Test
    func cascadeKeepsSeedScoreWhenRaisingIsDisabled() {
        var graph = Self.chainGraph()
        let result = graph.cascadeRetrieve(
            seeds: [ScoredMemoryID(id: "strong", score: 1), ScoredMemoryID(id: "weak", score: 0.2)],
            maxDepth: 2,
            maxResults: 10,
            raisesSeeds: false
        )

        #expect(Self.isClose(Self.score(of: "weak", in: result), to: 0.2))
        #expect(Self.isClose(Self.score(of: "strong", in: result), to: 1))
        // The traversal through the seed is unchanged: `beyond` is still
        // reached, from the seed's own score (0.2 · 0.9 · 0.7).
        #expect(Self.isClose(Self.score(of: "beyond", in: result), to: 0.126))
    }

    @Test
    func cascadeKeepsSeedScoreAlsoThroughASharedTag() {
        func cascade(raisesSeeds: Bool) -> [ScoredMemoryID] {
            var graph = Self.graph([
                Self.entry("a", tags: ["swift"]),
                Self.entry("b", tags: ["swift"]),
                Self.entry("c", tags: ["swift"])
            ])
            return graph.cascadeRetrieve(
                seeds: [ScoredMemoryID(id: "a", score: 1), ScoredMemoryID(id: "b", score: 0.2)],
                maxDepth: 2,
                maxResults: 10,
                raisesSeeds: raisesSeeds
            )
        }

        // Through `has_tag` (0.8) the cascade gives 1 · 0.8 · 0.7 = 0.56.
        let raised = cascade(raisesSeeds: true)
        #expect(Self.isClose(Self.score(of: "b", in: raised), to: 0.56))

        let pinned = cascade(raisesSeeds: false)
        #expect(Self.isClose(Self.score(of: "b", in: pinned), to: 0.2))
        // A non-seed reached through the same tag is still scored by it.
        #expect(Self.isClose(Self.score(of: "c", in: pinned), to: 0.56))
    }

    // MARK: - Engine: cascadeRaisesSeeds

    @Test
    func engineRaisesAWeakSeedByDefault() async throws {
        let engine = Self.engine(
            graph: Self.chainGraph(),
            seeds: [("strong", 1), ("weak", 0.2)],
            configuration: MemoryEngineConfiguration(maxDepth: 2)
        )

        let result = try await engine.retrieveAndSelectDetailed("anything", scope: .all)

        #expect(Self.isClose(Self.score(of: "weak", in: result.candidates), to: 0.63))
        #expect(result.selected.map(\.memory.id).contains("weak"))
    }

    @Test
    func engineKeepsSeedScoreWhenRaisingIsDisabled() async throws {
        let engine = Self.engine(
            graph: Self.chainGraph(),
            seeds: [("strong", 1), ("weak", 0.2)],
            configuration: MemoryEngineConfiguration(maxDepth: 2, cascadeRaisesSeeds: false)
        )

        let result = try await engine.retrieveAndSelectDetailed("anything", scope: .all)

        #expect(Self.isClose(Self.score(of: "weak", in: result.candidates), to: 0.2))
        #expect(Self.isClose(Self.score(of: "beyond", in: result.candidates), to: 0.126))
        // 0.2 is below half of the strongest seed: the weak seed is no longer
        // dragged into the selection by its strong neighbour.
        #expect(result.selected.map(\.memory.id) == ["strong"])
    }

    // MARK: - Engine: maxGraphOnlySelections

    /// Two seeds (`first` 1.0, `second` 0.55) and two entries reached only
    /// through `first` at 0.63 each, ahead of `second`.
    private static func hubGraph() -> MemoryGraph {
        graph(
            [entry("first"), entry("second"), entry("graph1"), entry("graph2")],
            relations: [("first", "graph1", 0.9), ("first", "graph2", 0.9)]
        )
    }

    @Test
    func graphOnlyCapFreesSlotsForSeedsAboveThreshold() async throws {
        let seeds: [(id: String, score: Float)] = [("first", 1), ("second", 0.55)]
        let graph = Self.hubGraph()

        let unbounded = Self.engine(
            graph: graph,
            seeds: seeds,
            configuration: MemoryEngineConfiguration(maxDepth: 2, maxResults: 3)
        )
        let uncapped = try await unbounded.retrieveAndSelectDetailed("anything", scope: .all)
        // The two graph-only entries outrank the second seed and fill the slots.
        #expect(Set(uncapped.selected.map(\.memory.id)) == ["first", "graph1", "graph2"])

        let bounded = Self.engine(
            graph: graph,
            seeds: seeds,
            configuration: MemoryEngineConfiguration(maxDepth: 2, maxResults: 3, maxGraphOnlySelections: 1)
        )
        let capped = try await bounded.retrieveAndSelectDetailed("anything", scope: .all)

        let selectedIDs = capped.selected.map(\.memory.id)
        let graphOnly = selectedIDs.filter { !capped.seedIDs.contains($0) }
        #expect(graphOnly.count == 1)
        #expect(selectedIDs.contains("first"))
        // The freed slot goes to the seed that was above the threshold.
        #expect(selectedIDs.contains("second"))
        #expect(selectedIDs.count == 3)
        // The cap acts on the selection only: the candidates are the same.
        #expect(Self.sameCandidates(capped.candidates, uncapped.candidates))
    }

    @Test
    func graphOnlyCapOfZeroExcludesEveryNonSeed() async throws {
        let graph = Self.graph(
            [
                Self.entry("seed", tags: ["swift"]),
                Self.entry("tagged", tags: ["swift"]),
                Self.entry("related")
            ],
            relations: [("seed", "related", 0.9)]
        )
        let seeds: [(id: String, score: Float)] = [("seed", 1)]

        let uncapped = try await Self.engine(
            graph: graph,
            seeds: seeds,
            configuration: MemoryEngineConfiguration(maxDepth: 2)
        ).retrieveAndSelectDetailed("anything", scope: .all)
        // Both the tag neighbour (0.56) and the relation neighbour (0.63) clear
        // the relative threshold without a cap.
        #expect(Set(uncapped.selected.map(\.memory.id)) == ["seed", "tagged", "related"])

        let capped = try await Self.engine(
            graph: graph,
            seeds: seeds,
            configuration: MemoryEngineConfiguration(maxDepth: 2, maxGraphOnlySelections: 0)
        ).retrieveAndSelectDetailed("anything", scope: .all)

        #expect(capped.selected.map(\.memory.id) == ["seed"])
        #expect(Self.sameCandidates(capped.candidates, uncapped.candidates))
    }

    // MARK: - retrieveAndSelectDetailed

    @Test
    func detailedRetrievalReportsTheSeeds() async throws {
        let engine = Self.engine(
            graph: Self.hubGraph(),
            seeds: [("first", 1), ("second", 0.55)],
            configuration: MemoryEngineConfiguration(maxDepth: 2)
        )

        let detailed = try await engine.retrieveAndSelectDetailed("anything", scope: .all)
        #expect(detailed.seedIDs == ["first", "second"])
        // The graph-only entries are candidates but not seeds.
        let candidateIDs = Set(detailed.candidates.map(\.memory.id))
        #expect(candidateIDs == ["first", "second", "graph1", "graph2"])

        // The plain variant is the same pipeline without the seeds.
        let plain = try await engine.retrieveAndSelect("anything", scope: .all)
        #expect(Self.sameCandidates(plain.candidates, detailed.candidates))
        #expect(Set(plain.selected.map(\.memory.id)) == Set(detailed.selected.map(\.memory.id)))
    }

    @Test
    func detailedRetrievalHasNoSeedsWhenRecallIsSkipped() async throws {
        let engine = Self.engine(
            graph: Self.hubGraph(),
            seeds: [("first", 1)],
            configuration: MemoryEngineConfiguration()
        )

        let detailed = try await engine.retrieveAndSelectDetailed("   ", scope: .all)

        #expect(detailed.seedIDs.isEmpty)
        #expect(detailed.candidates.isEmpty)
        #expect(detailed.selected.isEmpty)
    }
}

private extension MemoryEngineConfiguration {
    /// The same configuration with the three thresholds of the recall evidence
    /// gate `nil`: every candidate is selectable, as before the gate existed.
    var withoutEvidenceGate: MemoryEngineConfiguration {
        var copy = self
        copy.recallMinimumLexicalEvidenceRatio = nil
        copy.recallMinimumSemanticSimilarity = nil
        copy.recallLexicalSupportMinimumSimilarity = nil
        return copy
    }
}
