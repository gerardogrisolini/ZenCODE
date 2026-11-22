//
//  RecallEvidenceGateTests.swift
//  ZenCODECoreTests
//
//  The minimum evidence gate of automatic recall
//  (`recallMinimumLexicalEvidenceRatio` = L, `recallMinimumSemanticSimilarity` = C,
//  `recallLexicalSupportMinimumSimilarity` = C2, `recallSemanticThresholdModels`):
//  a retrieval seed is offered to the selector only if it shares enough of the
//  query's vocabulary (IDF-weighted, the threshold being a ratio of `idfMax(n)`
//  so it scales with the corpus) or sits close enough to its embedding, and a
//  lexically supported entry may also be required to keep a minimum cosine; the
//  cosine thresholds apply only to the embedding models they were measured on.
//  The gate narrows the selection only: the candidates stay complete. It is on
//  by default; the tests that need the plain retrieval build the gate off
//  explicitly with `nil` thresholds. The lexical evidence reads the corpus the
//  default BM25 ranks, tokenized once per retrieval.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODERuntime

@Suite
struct RecallEvidenceGateTests {
    // MARK: - Fixtures

    private static let modelID = "evidence-test"

    /// Embeds every text — queries included — as the same fixed vector, so the
    /// cosine of each entry is exactly the one its own vector was built with.
    private struct FixedEmbedder: EmbeddingProvider {
        let modelID: String
        let vector: [Float]

        init(vector: [Float], modelID: String = RecallEvidenceGateTests.modelID) {
            self.vector = vector
            self.modelID = modelID
        }

        func embed(_ text: String) async throws -> [Float] { vector }
    }

    /// An endpoint that is down.
    private struct DownEmbedder: EmbeddingProvider {
        let modelID = RecallEvidenceGateTests.modelID

        func embed(_ text: String) async throws -> [Float] {
            throw URLError(.cannotConnectToHost)
        }
    }

    private struct ScriptedAnalyzer: MemoryQueryAnalyzer {
        let plan: MemoryQueryPlan

        func analyze(_ prompt: String) async throws -> MemoryQueryPlan { plan }
    }

    /// The top-score selector that also records the candidate ids of every call.
    private final class RecordingSelector: MemorySelector, Sendable {
        private let calls = Mutex<[[String]]>([])

        var offered: [[String]] { calls.withLock { $0 } }

        func select(
            context: String,
            candidates: [MemoryCandidate],
            limit: Int
        ) async throws -> [MemoryCandidate] {
            calls.withLock { $0.append(candidates.map(\.memory.id)) }
            return try await TopScoreMemorySelector().select(context: context, candidates: candidates, limit: limit)
        }
    }

    /// The query direction every embedded text maps to.
    private static let queryVector: [Float] = [1, 0, 0, 0]

    /// A vector whose cosine to ``queryVector`` is `cosine`.
    private static func vector(cosine: Float) -> [Float] {
        [cosine, (1 - cosine * cosine).squareRoot(), 0, 0]
    }

    private static func entry(
        _ id: String,
        _ content: String,
        tags: [String] = [],
        cosine: Float? = nil,
        model: String = modelID
    ) -> EngineMemoryEntry {
        EngineMemoryEntry(
            id: id,
            category: .fact,
            content: content,
            tags: tags,
            embedding: cosine.map(vector(cosine:)),
            embeddingModel: cosine == nil ? nil : model
        )
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
        _ entries: [EngineMemoryEntry],
        relations: [(from: String, to: String, weight: Float)] = [],
        configuration: MemoryEngineConfiguration = MemoryEngineConfiguration(),
        lexicalIndex: any MemoryIndex = BM25MemoryIndex(),
        embedder: (any EmbeddingProvider)? = nil,
        analyzer: any MemoryQueryAnalyzer = DirectMemoryQueryAnalyzer(),
        selector: any MemorySelector = TopScoreMemorySelector()
    ) -> MemoryEngine {
        MemoryEngine(
            graph: graph(entries, relations: relations),
            lexicalIndex: lexicalIndex,
            embedder: embedder,
            queryAnalyzer: analyzer,
            selector: selector,
            configuration: configuration,
            semanticFailureReporter: { _ in }
        )
    }

    /// The gate off, built explicitly: the three thresholds are `nil`, not the
    /// defaults, so the retrieval is the plain one.
    private static func gateOff(maxDepth: Int = 0) -> MemoryEngineConfiguration {
        MemoryEngineConfiguration(
            maxDepth: maxDepth,
            recallMinimumLexicalEvidenceRatio: nil,
            recallMinimumSemanticSimilarity: nil,
            recallLexicalSupportMinimumSimilarity: nil
        )
    }

    /// A gate with the given thresholds (explicit: a `nil` is a `nil`, not the
    /// default). `models` defaults to every model so the cosine thresholds apply
    /// to the fixture embedder; a test about the model set passes its own.
    private static func gate(
        _ lexicalRatio: Float? = nil,
        _ semantic: Float? = nil,
        support: Float? = nil,
        models: Set<String> = [MemoryEngineConfiguration.anyEmbeddingModel],
        maxDepth: Int = 0
    ) -> MemoryEngineConfiguration {
        MemoryEngineConfiguration(
            maxDepth: maxDepth,
            recallMinimumLexicalEvidenceRatio: lexicalRatio,
            recallMinimumSemanticSimilarity: semantic,
            recallLexicalSupportMinimumSimilarity: support,
            recallSemanticThresholdModels: models
        )
    }

    /// Six entries, four of which contain the common term `red` (df 4 of 6) and
    /// one the rare `zed` (df 1). With the query `red zed` the IDF of `red` is
    /// ln(1 + 2.5/4.5) ≈ 0.442 and that of `zed` ln(1 + 5.5/1.5) ≈ 1.540, which
    /// is also `idfMax(6)`: a ratio of 0.5 puts the threshold at ≈ 0.77.
    private static let animals: [EngineMemoryEntry] = [
        entry("weak", "red cat"),
        entry("dog", "red dog"),
        entry("owl", "red owl"),
        entry("ant", "red ant"),
        entry("strong", "zed fox"),
        entry("other", "gnu hen")
    ]

    private static func ids(_ candidates: [MemoryCandidate]) -> [String] {
        candidates.map(\.memory.id)
    }

    private static func isClose(_ value: Float?, to expected: Float, tolerance: Float = 1e-3) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < tolerance
    }

    /// The same entries with the same scores, up to the float noise that the
    /// age weight (computed from `Date()` at each retrieval) introduces
    /// between two runs; the order of near-ties is deliberately not compared.
    private static func sameCandidates(
        _ lhs: [MemoryCandidate],
        _ rhs: [MemoryCandidate],
        tolerance: Float = 1e-3
    ) -> Bool {
        guard Set(ids(lhs)) == Set(ids(rhs)) else { return false }
        return lhs.allSatisfy { candidate in
            isClose(rhs.first { $0.memory.id == candidate.memory.id }?.score, to: candidate.score, tolerance: tolerance)
        }
    }

    // MARK: - Configuration

    @Test
    func theGateIsOnByDefaultWithTheMeasuredThresholds() {
        let configuration = MemoryEngineConfiguration()
        #expect(configuration.recallMinimumLexicalEvidenceRatio == 0.55)
        #expect(configuration.recallMinimumSemanticSimilarity == 0.55)
        #expect(configuration.recallLexicalSupportMinimumSimilarity == 0.45)
        #expect(configuration.recallSemanticThresholdModels == ["qwen/qwen3-embedding-8b"])

        // Turning it off is explicit: all three thresholds `nil`.
        let off = Self.gateOff()
        #expect(off.recallMinimumLexicalEvidenceRatio == nil)
        #expect(off.recallMinimumSemanticSimilarity == nil)
        #expect(off.recallLexicalSupportMinimumSimilarity == nil)
        #expect(off != configuration)
        #expect(MemoryEngineConfiguration(recallMinimumLexicalEvidenceRatio: 1) != configuration)
        #expect(MemoryEngineConfiguration(recallMinimumSemanticSimilarity: 0.5) != configuration)
        #expect(MemoryEngineConfiguration(recallLexicalSupportMinimumSimilarity: 0.4) != configuration)
        #expect(MemoryEngineConfiguration(recallSemanticThresholdModels: ["*"]) != configuration)
    }

    @Test
    func aNegativeRatioIsClampedToZero() {
        #expect(MemoryEngineConfiguration(recallMinimumLexicalEvidenceRatio: -1).recallMinimumLexicalEvidenceRatio == 0)
        #expect(MemoryEngineConfiguration(recallMinimumLexicalEvidenceRatio: nil).recallMinimumLexicalEvidenceRatio == nil)
    }

    // MARK: - (a) The default gate: conversational prompts

    /// Eight entries, four of which contain the common word `with`.
    private static let conversationalCorpus: [EngineMemoryEntry] = [
        entry("parser", "pair the parser with the cache layer"),
        entry("linter", "run the linter with the strict flag"),
        entry("server", "start the server with the debug port"),
        entry("report", "export the report with the date range"),
        entry("storage", "storage note about caching"),
        entry("shell", "shell note about quoting"),
        entry("tokens", "tokens note about stemming"),
        entry("network", "network note about retries")
    ]

    @Test
    func aConversationalPromptSelectsNothingWithTheDefaultGate() async throws {
        let selector = RecordingSelector()
        let result = try await Self.engine(Self.conversationalCorpus, selector: selector)
            .retrieveAndSelectDetailed("ok, go ahead with it", scope: .all)

        // The only word of the prompt found in the corpus is `with` (df 4 of 8,
        // IDF ln 2 ≈ 0.69), under 0.55 × idfMax(8) ≈ 0.99: candidates, but no
        // evidence worth injecting.
        #expect(Set(Self.ids(result.candidates)) == ["parser", "linter", "server", "report"])
        #expect(result.selected.isEmpty)
        #expect(selector.offered.isEmpty)
        #expect(result.lexicalScale.documentCount == 8)
        for id in ["parser", "linter", "server", "report"] {
            #expect(Self.isClose(result.evidence[id]?.lexical, to: Float(log(2.0)), tolerance: 1e-4))
            #expect((result.evidence[id]?.lexical ?? 1) < 0.55 * result.lexicalScale.maximumEvidence)
        }

        // The control: the plain retrieval selects those same entries.
        let open = try await Self.engine(Self.conversationalCorpus, configuration: Self.gateOff())
            .retrieveAndSelectDetailed("ok, go ahead with it", scope: .all)
        #expect(Set(Self.ids(open.selected)) == ["parser", "linter", "server", "report"])
        #expect(Self.sameCandidates(open.candidates, result.candidates))
    }

    @Test
    func aPromptWithASpecificTermStillSelectsItsEntryWithTheDefaultGate() async throws {
        let result = try await Self.engine(Self.conversationalCorpus)
            .retrieveAndSelectDetailed("linter with the strict flag", scope: .all)
        // `linter`, `strict` and `flag` are in one entry only; `with` and `the`
        // (in four) add up on the other entries that contain them, which is why
        // the ranking, not the gate, puts `linter` first.
        #expect(Self.ids(result.selected).first == "linter")
        #expect(!Set(Self.ids(result.selected)).contains("storage"))
    }

    // MARK: - (b) A small corpus keeps selecting the entry with a rare term

    @Test(arguments: [1, 2, 3, 4, 5, 8, 20, 120])
    func aSmallCorpusSelectsTheEntryWithARareQueryTerm(size: Int) async throws {
        // `zebra` is in one entry, `note` in all of them: with an absolute
        // threshold of 3 no corpus under ~350 entries could ever select it (the
        // IDF of a term in one entry is 2.64 among 20); the threshold being a
        // ratio of idfMax(n), the entry with the rare term is selected at any size.
        var entries = [Self.entry("rare", "zebra note")]
        entries += (1..<size).map { Self.entry("filler\($0)", "plain note item\($0)") }

        let result = try await Self.engine(entries).retrieveAndSelectDetailed("zebra note", scope: .all)

        #expect(result.lexicalScale.documentCount == size)
        #expect(Self.ids(result.selected) == ["rare"], "n = \(size)")
        #expect(result.candidates.contains { $0.memory.id == "rare" })
        if size > 1 {
            // The fillers share `note`: candidates, not selected.
            #expect(result.candidates.count > 1)
        }
        let evidence = try #require(result.evidence["rare"]?.lexical)
        #expect(evidence >= 0.55 * result.lexicalScale.maximumEvidence)
    }

    // MARK: - Lexical threshold

    @Test
    func withAllThresholdsNilTheSelectorSeesEveryCandidate() async throws {
        let selector = RecordingSelector()
        let engine = Self.engine(Self.animals, configuration: Self.gateOff(), selector: selector)

        let result = try await engine.retrieveAndSelectDetailed("red zed", scope: .all)

        // The weak-evidence entries are candidates, offered to the selector
        // as they are, and selected.
        #expect(Set(Self.ids(result.candidates)) == ["weak", "dog", "owl", "ant", "strong"])
        #expect(selector.offered == [Self.ids(result.candidates)])
        #expect(Set(Self.ids(result.selected)) == Set(Self.ids(result.candidates)))
        #expect(result.seedIDs == Set(Self.ids(result.candidates)))
        #expect(!result.semanticRan)

        // The three-value form is the same retrieval.
        let plain = try await engine.retrieveAndSelect("red zed", scope: .all)
        #expect(Self.sameCandidates(plain.candidates, result.candidates))
        #expect(Self.sameCandidates(plain.selected, result.selected))
    }

    @Test
    func aThresholdChangesOnlyTheSelectionNeverTheCandidates() async throws {
        let open = try await Self.engine(Self.animals, configuration: Self.gateOff())
            .retrieveAndSelectDetailed("red zed", scope: .all)
        let gated = try await Self.engine(Self.animals, configuration: Self.gate(0.5))
            .retrieveAndSelectDetailed("red zed", scope: .all)

        #expect(Self.sameCandidates(gated.candidates, open.candidates))
        #expect(gated.seedIDs == open.seedIDs)
        #expect(gated.evidence == open.evidence)
        #expect(Self.ids(gated.selected) != Self.ids(open.selected))
    }

    @Test
    func aSharedCommonTermIsNotEnoughButARareOneIs() async throws {
        // `red` (IDF ≈ 0.44) is below 0.5 × idfMax(6) ≈ 0.77, `zed` (≈ 1.54) above.
        for configuration in [Self.gate(0.5), MemoryEngineConfiguration()] {
            let result = try await Self.engine(Self.animals, configuration: configuration)
                .retrieveAndSelectDetailed("red zed", scope: .all)

            #expect(Self.ids(result.selected) == ["strong"])
            #expect(Set(Self.ids(result.candidates)) == ["weak", "dog", "owl", "ant", "strong"])
        }
    }

    @Test
    func theLexicalThresholdIsInclusive() async throws {
        // `zed` is in one entry: its evidence is exactly idfMax(6), the effective
        // threshold of ratio 1.
        let probe = try await Self.engine(Self.animals, configuration: Self.gateOff())
            .retrieveAndSelectDetailed("red zed", scope: .all)
        let exact = try #require(probe.evidence["strong"]?.lexical)
        #expect(exact == probe.lexicalScale.maximumEvidence)

        let atTheThreshold = try await Self.engine(Self.animals, configuration: Self.gate(1))
            .retrieveAndSelectDetailed("red zed", scope: .all)
        #expect(Self.ids(atTheThreshold.selected) == ["strong"])

        let above = try await Self.engine(Self.animals, configuration: Self.gate(1.01))
            .retrieveAndSelectDetailed("red zed", scope: .all)
        #expect(above.selected.isEmpty)
    }

    @Test
    func withNoLexicalRatioAnySharedTermQualifiesOnceTheSemanticOneIsSet() async throws {
        // The endpoint is down, so only the lexical rule applies; with a `nil`
        // ratio it asks for any evidence at all, which every candidate sharing
        // a term has.
        let result = try await Self.engine(
            Self.animals,
            configuration: Self.gate(nil, 0.5),
            embedder: DownEmbedder()
        ).retrieveAndSelectDetailed("red zed", scope: .all)

        #expect(!result.semanticRan)
        #expect(Set(Self.ids(result.selected)) == Set(Self.ids(result.candidates)))
    }

    // MARK: - Semantic threshold

    /// Two entries that share no term with the query `qux` and sit at cosine
    /// 0.9 and 0.6 from the query vector; a third at 0.2 falls under the
    /// semantic floor and is not even a candidate.
    private static let semanticEntries: [EngineMemoryEntry] = [
        entry("near", "owl gnu", cosine: 0.9),
        entry("mid", "hen emu", cosine: 0.6),
        entry("far", "yak elk", cosine: 0.2)
    ]

    private static var fixedEmbedder: FixedEmbedder { FixedEmbedder(vector: queryVector) }

    @Test
    func aSemanticEntryUnderTheThresholdIsNotSelectedAndOneAboveIs() async throws {
        let open = try await Self.engine(
            Self.semanticEntries, configuration: Self.gateOff(), embedder: Self.fixedEmbedder
        ).retrieveAndSelectDetailed("qux", scope: .all)
        #expect(open.semanticRan)
        #expect(Set(Self.ids(open.candidates)) == ["near", "mid"])
        #expect(Set(Self.ids(open.selected)) == ["near", "mid"])

        let gated = try await Self.engine(
            Self.semanticEntries,
            configuration: Self.gate(nil, 0.75),
            embedder: Self.fixedEmbedder
        ).retrieveAndSelectDetailed("qux", scope: .all)

        #expect(Self.ids(gated.selected) == ["near"])
        #expect(Self.sameCandidates(gated.candidates, open.candidates))
        // The evidence behind the decision: no shared term, the raw cosines.
        #expect(gated.evidence["near"]?.lexical == 0)
        #expect(Self.isClose(gated.evidence["near"]?.semantic, to: 0.9))
        #expect(Self.isClose(gated.evidence["mid"]?.semantic, to: 0.6))
        #expect(gated.evidence["near"]?.isSeed == true)
    }

    @Test
    func theSemanticThresholdIsInclusive() async throws {
        let probe = try await Self.engine(
            Self.semanticEntries, configuration: Self.gateOff(), embedder: Self.fixedEmbedder
        ).retrieveAndSelectDetailed("qux", scope: .all)
        let exact = try #require(probe.evidence["mid"]?.semantic)

        let result = try await Self.engine(
            Self.semanticEntries,
            configuration: Self.gate(nil, exact),
            embedder: Self.fixedEmbedder
        ).retrieveAndSelectDetailed("qux", scope: .all)
        #expect(Set(Self.ids(result.selected)) == ["near", "mid"])
    }

    @Test
    func withNoSemanticThresholdTheSemanticGateHitsQualify() async throws {
        // Only the lexical ratio is set: the entries that passed the semantic
        // gate (cosine above its floor) are still selectable; the lexical
        // threshold does not close the semantic path.
        let result = try await Self.engine(
            Self.semanticEntries,
            configuration: Self.gate(5),
            embedder: Self.fixedEmbedder
        ).retrieveAndSelectDetailed("qux", scope: .all)

        #expect(Set(Self.ids(result.selected)) == ["near", "mid"])
    }

    // MARK: - Nothing selectable

    @Test
    func whenNothingQualifiesTheSelectionIsEmptyAndTheCandidatesAreIntact() async throws {
        let selector = RecordingSelector()
        let open = try await Self.engine(
            Self.semanticEntries, configuration: Self.gateOff(), embedder: Self.fixedEmbedder
        ).retrieveAndSelectDetailed("qux", scope: .all)

        let gated = try await Self.engine(
            Self.semanticEntries,
            configuration: Self.gate(nil, 0.95),
            embedder: Self.fixedEmbedder,
            selector: selector
        ).retrieveAndSelectDetailed("qux", scope: .all)

        #expect(gated.selected.isEmpty)
        #expect(Self.sameCandidates(gated.candidates, open.candidates))
        #expect(!gated.candidates.isEmpty)
        // Nothing to choose from: the selector is not asked.
        #expect(selector.offered.isEmpty)
    }

    @Test
    func aLexicalRatioAboveEveryEvidenceSelectsNothing() async throws {
        let result = try await Self.engine(Self.animals, configuration: Self.gate(100))
            .retrieveAndSelectDetailed("red zed", scope: .all)

        #expect(result.selected.isEmpty)
        #expect(Set(Self.ids(result.candidates)) == ["weak", "dog", "owl", "ant", "strong"])
    }

    @Test
    func aPromptWithoutContentSharesNothingWithTheCorpus() async throws {
        // The word is in no entry: BM25 finds nothing, so the recall is empty
        // with or without the gate.
        let result = try await Self.engine(Self.animals, configuration: Self.gate(0.3))
            .retrieveAndSelectDetailed("procedi", scope: .all)

        #expect(result.candidates.isEmpty)
        #expect(result.selected.isEmpty)
        #expect(result.evidence.isEmpty)
    }

    // MARK: - (d) An empty corpus selects nothing lexically

    /// Seeds from the tags alone, with no query token: the corpus is not built
    /// (`n = 0`), so no entry has lexical evidence and the lexical rule selects
    /// nothing, even at a ratio of 0 (which accepts any evidence when `n > 0`).
    @Test
    func withoutACorpusTheLexicalRuleSelectsNothing() async throws {
        let entries = [
            Self.entry("tagged", "gnu hen", tags: ["pets"]),
            Self.entry("other", "emu yak")
        ]
        let analyzer = ScriptedAnalyzer(plan: MemoryQueryPlan(queries: ["!!!"], tags: ["pets"]))

        // No token in the prompt: nothing is evidenced, n = 0.
        let empty = try await Self.engine(entries, configuration: Self.gate(0), analyzer: analyzer)
            .retrieveAndSelectDetailed("!!!", scope: .all)
        #expect(Self.ids(empty.candidates) == ["tagged"])
        #expect(empty.lexicalScale.documentCount == 0)
        #expect(empty.lexicalScale.maximumEvidence == 0)
        #expect(empty.selected.isEmpty)

        // With a token (in no entry) the corpus exists, and ratio 0 asks for
        // nothing: the tagged seed, which shares no term, is selectable.
        let withCorpus = try await Self.engine(entries, configuration: Self.gate(0), analyzer: analyzer)
            .retrieveAndSelectDetailed("zebra", scope: .all)
        #expect(withCorpus.lexicalScale.documentCount == 2)
        #expect(Self.ids(withCorpus.selected) == ["tagged"])
    }

    @Test
    func anEmptyGraphHasNoScaleAndNoSelection() async throws {
        let result = try await Self.engine([]).retrieveAndSelectDetailed("zebra", scope: .all)

        #expect(result.candidates.isEmpty)
        #expect(result.selected.isEmpty)
        #expect(result.lexicalScale == .empty)
        #expect(MemoryLexicalScale(documentCount: 0).threshold(ratio: 0.55) == 0)
    }

    // MARK: - No semantic search ran: the semantic threshold is ignored

    /// `tagged` is a metadata seed (plan tag `pets`) that shares no term with
    /// the query `zed` yet sits at cosine 0.9; `lex` shares the term `zed`.
    private static let metadataEntries: [EngineMemoryEntry] = [
        entry("lex", "zed fox", cosine: 0.1),
        entry("tagged", "gnu hen", tags: ["pets"], cosine: 0.9),
        entry("noise", "emu yak")
    ]

    private static let metadataAnalyzer = ScriptedAnalyzer(
        plan: MemoryQueryPlan(queries: ["zed"], tags: ["pets"])
    )

    /// A lexical ratio under the evidence of `zed` (df 1 of 3) and C = 0.75.
    private static var semanticThreshold: MemoryEngineConfiguration { gate(0.3, 0.75) }

    @Test
    func withSemanticsTheTaggedEntryQualifiesThroughItsCosine() async throws {
        let result = try await Self.engine(
            Self.metadataEntries,
            configuration: Self.semanticThreshold,
            embedder: Self.fixedEmbedder,
            analyzer: Self.metadataAnalyzer
        ).retrieveAndSelectDetailed("zed", scope: .all)

        #expect(result.semanticRan)
        #expect(Set(Self.ids(result.selected)) == ["lex", "tagged"])
        #expect(Self.isClose(result.evidence["tagged"]?.semantic, to: 0.9))
        #expect(result.evidence["tagged"]?.lexical == 0)
    }

    @Test
    func withoutSemanticsOnlyTheLexicalRuleApplies() async throws {
        // Same graph and threshold; the cosine of `tagged` would pass, but the
        // semantic search is switched off for this prompt.
        let result = try await Self.engine(
            Self.metadataEntries,
            configuration: Self.semanticThreshold,
            embedder: Self.fixedEmbedder,
            analyzer: Self.metadataAnalyzer
        ).retrieveAndSelectDetailed("zed", scope: .all, includeSemantic: false)

        #expect(!result.semanticRan)
        #expect(Set(Self.ids(result.candidates)).isSuperset(of: ["lex", "tagged"]))
        #expect(Self.ids(result.selected) == ["lex"])
        #expect(result.evidence["tagged"]?.semantic == nil)
        #expect(result.evidence["tagged"]?.lexical == 0)
        #expect((result.evidence["lex"]?.lexical ?? 0) > 0)
    }

    @Test
    func withoutAnEmbedderOnlyTheLexicalRuleApplies() async throws {
        let result = try await Self.engine(
            Self.metadataEntries,
            configuration: Self.semanticThreshold,
            analyzer: Self.metadataAnalyzer
        ).retrieveAndSelectDetailed("zed", scope: .all)

        #expect(!result.semanticRan)
        #expect(Self.ids(result.selected) == ["lex"])
        #expect(result.evidence.values.allSatisfy { $0.semantic == nil })
    }

    @Test
    func whenTheEndpointFailsOnlyTheLexicalRuleApplies() async throws {
        let result = try await Self.engine(
            Self.metadataEntries,
            configuration: Self.semanticThreshold,
            embedder: DownEmbedder(),
            analyzer: Self.metadataAnalyzer
        ).retrieveAndSelectDetailed("zed", scope: .all)

        #expect(!result.semanticRan)
        #expect(Self.ids(result.selected) == ["lex"])
        #expect(result.evidence["tagged"]?.semantic == nil)
    }

    @Test
    func theLexicalThresholdStillAppliesWhenSemanticsDidNotRun() async throws {
        let result = try await Self.engine(
            Self.animals,
            configuration: Self.gate(0.5, 0.1),
            embedder: DownEmbedder()
        ).retrieveAndSelectDetailed("red zed", scope: .all)

        #expect(!result.semanticRan)
        #expect(Self.ids(result.selected) == ["strong"])
    }

    // MARK: - Graph-only entries

    @Test
    func anEntryReachedOnlyThroughTheGraphIsNotSelectableOnceAThresholdIsSet() async throws {
        let entries = [
            Self.entry("seed", "zed fox"),
            Self.entry("neighbour", "gnu hen")
        ]
        let relations: [(from: String, to: String, weight: Float)] = [("seed", "neighbour", 0.9)]

        // Control: with the gate off the cascade does reach the neighbour.
        let open = try await Self.engine(entries, relations: relations, configuration: Self.gateOff(maxDepth: 2))
            .retrieveAndSelectDetailed("zed", scope: .all)
        #expect(Set(Self.ids(open.selected)) == ["seed", "neighbour"])

        let gated = try await Self.engine(entries, relations: relations, configuration: Self.gate(0.1, maxDepth: 2))
            .retrieveAndSelectDetailed("zed", scope: .all)

        #expect(Set(Self.ids(gated.candidates)) == ["seed", "neighbour"])
        #expect(Self.ids(gated.selected) == ["seed"])
        #expect(gated.evidence["neighbour"]?.isSeed == false)
        #expect(gated.evidence["neighbour"]?.lexical == 0)
        #expect(gated.evidence["seed"]?.isSeed == true)
    }

    // MARK: - The exposed lexical evidence is the IDF of the corpus

    /// Seven entries: `red` in five of them, `zed` in two.
    private static let handBuilt: [EngineMemoryEntry] = [
        entry("weak", "red cat"),
        entry("dog", "red dog"),
        entry("owl", "red owl"),
        entry("ant", "red ant"),
        entry("strong", "zed fox"),
        entry("both", "red zed"),
        entry("other", "gnu hen")
    ]

    @Test
    func theLexicalEvidenceIsTheSumOfTheIDFOfTheDistinctSharedTerms() async throws {
        // n = 7 active entries; df(red) = 5, df(zed) = 2; the BM25 formula
        // ln(1 + (n - df + 0.5) / (df + 0.5)).
        let red = Float(log(1 + (7.0 - 5 + 0.5) / (5 + 0.5)))
        let zed = Float(log(1 + (7.0 - 2 + 0.5) / (2 + 0.5)))
        #expect(Self.isClose(red, to: 0.3747, tolerance: 1e-4))
        #expect(Self.isClose(zed, to: 1.1632, tolerance: 1e-4))

        // A repeated query term counts once.
        let result = try await Self.engine(Self.handBuilt)
            .retrieveAndSelectDetailed("red red zed zed", scope: .all)

        #expect(Self.isClose(result.evidence["weak"]?.lexical, to: red, tolerance: 1e-5))
        #expect(Self.isClose(result.evidence["strong"]?.lexical, to: zed, tolerance: 1e-5))
        #expect(Self.isClose(result.evidence["both"]?.lexical, to: red + zed, tolerance: 1e-5))
        #expect(result.evidence["other"] == nil)
        #expect(result.evidence.count == result.candidates.count)
    }

    @Test
    func theLexicalEvidenceUnitesTheTermsOfEveryRetrievalQuery() async throws {
        // The analyzer splits the need into two queries; the original prompt
        // (`foo`, in no entry) is a third. The evidence is over their union.
        let red = Float(log(1 + (7.0 - 5 + 0.5) / (5 + 0.5)))
        let zed = Float(log(1 + (7.0 - 2 + 0.5) / (2 + 0.5)))
        let analyzer = ScriptedAnalyzer(plan: MemoryQueryPlan(queries: ["red", "zed"]))

        let result = try await Self.engine(Self.handBuilt, analyzer: analyzer)
            .retrieveAndSelectDetailed("foo", scope: .all)

        #expect(Self.isClose(result.evidence["both"]?.lexical, to: red + zed, tolerance: 1e-5))
        #expect(Self.isClose(result.evidence["weak"]?.lexical, to: red, tolerance: 1e-5))
    }

    @Test
    func theCorpusIsTheActiveEntriesOfTheScope() async throws {
        // An archived entry and a global one do not count in a project lookup:
        // n = 4 and df(red) = 3 there, against n = 6 and df(red) = 5 overall.
        var archived = Self.entry("archived", "red cat")
        archived.active = false
        let entries = [
            Self.entry("a", "red cat"),
            Self.entry("b", "red dog"),
            Self.entry("c", "red owl"),
            Self.entry("d", "gnu hen"),
            archived,
            EngineMemoryEntry(id: "global", category: .fact, content: "red ant", scope: .global)
        ]

        let project = try await Self.engine(entries).retrieveAndSelectDetailed("red", scope: .project)
        let expected = Float(log(1 + (4.0 - 3 + 0.5) / (3 + 0.5)))
        #expect(Self.isClose(project.evidence["a"]?.lexical, to: expected, tolerance: 1e-5))
        #expect(project.evidence["archived"] == nil)
        #expect(project.evidence["global"] == nil)
        // The scale is that of the same corpus: 4 documents.
        #expect(project.lexicalScale.documentCount == 4)
    }

    @Test
    func theEvidenceIsComputedOnlyForTheCandidates() async throws {
        let entries = (0..<60).map { Self.entry("e\($0)", "zed filler\($0 % 7) number\($0)") }
        let result = try await Self.engine(
            entries,
            configuration: MemoryEngineConfiguration(maxLexicalHits: 3, maxCandidateResults: 5)
        ).retrieveAndSelectDetailed("zed", scope: .all)

        #expect(result.candidates.count <= 5)
        #expect(Set(result.evidence.keys) == Set(Self.ids(result.candidates)))
    }

    @Test
    func theEvidenceIsSkippedOnlyWhenNothingNeedsIt() async throws {
        // Gate off and not asked for: no evidence, the retrieval is unchanged.
        let open = try await Self.engine(Self.animals, configuration: Self.gateOff())
            .retrieveAndSelectDetailed("red zed", scope: .all, collectEvidence: false)
        #expect(open.evidence.isEmpty)
        #expect(Set(Self.ids(open.selected)) == ["weak", "dog", "owl", "ant", "strong"])

        // The gate decides on the evidence, so it is worked out regardless —
        // also with the default gate, which is on.
        for configuration in [Self.gate(0.5), MemoryEngineConfiguration()] {
            let gated = try await Self.engine(Self.animals, configuration: configuration)
                .retrieveAndSelectDetailed("red zed", scope: .all, collectEvidence: false)
            #expect(Self.ids(gated.selected) == ["strong"])
            #expect(Set(gated.evidence.keys) == Set(Self.ids(gated.candidates)))
        }
    }

    @Test
    func aSkippedRecallExposesNoEvidence() async throws {
        let analyzer = ScriptedAnalyzer(plan: MemoryQueryPlan(shouldRecall: false))
        let result = try await Self.engine(
            Self.animals,
            embedder: Self.fixedEmbedder,
            analyzer: analyzer
        ).retrieveAndSelectDetailed("red zed", scope: .all)

        #expect(result.candidates.isEmpty)
        #expect(result.selected.isEmpty)
        #expect(result.evidence.isEmpty)
        #expect(result.lexicalScale == .empty)
        #expect(!result.semanticRan)
    }

    // MARK: - (e) The effective threshold is ratio × idfMax(n)

    @Test
    func idfMaxIsTheIDFOfATermInASingleDocument() {
        // ln(1 + (n − 0.5) / 1.5): 5.46 for the 353 entries of the measured
        // graph, 2.64 for 20, and the BM25 formula itself for df = 1.
        #expect(Self.isClose(MemoryLexicalCorpus.maximumInverseDocumentFrequency(documentCount: 353), to: 5.464, tolerance: 1e-3))
        #expect(Self.isClose(MemoryLexicalCorpus.maximumInverseDocumentFrequency(documentCount: 20), to: 2.639, tolerance: 1e-3))
        #expect(Self.isClose(MemoryLexicalCorpus.maximumInverseDocumentFrequency(documentCount: 1), to: Float(log(4.0 / 3)), tolerance: 1e-5))
        for n in [1, 2, 6, 7, 20, 353] {
            #expect(
                MemoryLexicalCorpus.maximumInverseDocumentFrequency(documentCount: n)
                    == MemoryLexicalCorpus.inverseDocumentFrequency(documentCount: Float(n), documentFrequency: 1)
            )
        }
        // No document, no IDF.
        #expect(MemoryLexicalCorpus.maximumInverseDocumentFrequency(documentCount: 0) == 0)
        #expect(MemoryLexicalScale(documentCount: 353).threshold(ratio: 0.55) > 3)
        #expect(MemoryLexicalScale(documentCount: 353).threshold(ratio: 0.55) < 3.01)
    }

    @Test
    func theEffectiveThresholdIsTheRatioTimesIdfMaxOfTheCorpus() async throws {
        // n = 7: idfMax(7) = ln(1 + 6.5/1.5); `zed` in two entries is worth
        // ln(1 + 5.5/2.5) = 1.1632, `red` in five 0.3747.
        let idfMax = Float(log(1 + (7.0 - 1 + 0.5) / (1 + 0.5)))
        let probe = try await Self.engine(Self.handBuilt, configuration: Self.gateOff())
            .retrieveAndSelectDetailed("red zed", scope: .all)
        #expect(probe.lexicalScale.documentCount == 7)
        #expect(Self.isClose(probe.lexicalScale.maximumEvidence, to: idfMax, tolerance: 1e-5))
        #expect(probe.lexicalScale.threshold(ratio: 0.5) == 0.5 * probe.lexicalScale.maximumEvidence)
        let zed = try #require(probe.evidence["strong"]?.lexical)
        let ratio = zed / probe.lexicalScale.maximumEvidence

        // A hair under the evidence of `zed`: `strong` and `both` (red + zed).
        let under = try await Self.engine(Self.handBuilt, configuration: Self.gate(ratio * 0.99))
            .retrieveAndSelectDetailed("red zed", scope: .all)
        #expect(Set(Self.ids(under.selected)) == ["strong", "both"])

        // A hair over it: only `both`, whose two terms add up to more.
        let over = try await Self.engine(Self.handBuilt, configuration: Self.gate(ratio * 1.01))
            .retrieveAndSelectDetailed("red zed", scope: .all)
        #expect(Self.ids(over.selected) == ["both"])
    }

    @Test
    func theSameRatioIsAnAbsoluteThresholdOfThreeOnTheMeasuredGraph() async throws {
        // 353 entries: `zorbx` in one (5.46), `g3` in twenty (2.85), under the
        // default 0.55 × idfMax(353) = 3.005 — about the absolute 3 the ratio
        // was derived from — so only the entry with the unique term is selected;
        // at 0.5 (2.73) the twenty-entry group qualifies as well.
        var entries = (0..<353).map { Self.entry("e\($0)", "n\($0) g\($0 % 18)") }
        entries[7] = Self.entry("e7", "zorbx n7 g7")

        let defaultGate = try await Self.engine(entries).retrieveAndSelectDetailed("zorbx g3", scope: .all)
        #expect(defaultGate.lexicalScale.documentCount == 353)
        #expect(Self.isClose(defaultGate.lexicalScale.maximumEvidence, to: 5.464, tolerance: 1e-3))
        #expect(Self.isClose(defaultGate.evidence["e7"]?.lexical, to: defaultGate.lexicalScale.maximumEvidence, tolerance: 1e-5))
        let group = Float(log(1 + (353.0 - 20 + 0.5) / (20 + 0.5)))
        #expect(Self.isClose(group, to: 2.849, tolerance: 1e-3))
        let others = defaultGate.candidates.filter { $0.memory.id != "e7" }
        #expect(!others.isEmpty)
        for candidate in others {
            #expect(Self.isClose(defaultGate.evidence[candidate.memory.id]?.lexical, to: group, tolerance: 1e-4))
        }
        #expect(Self.ids(defaultGate.selected) == ["e7"])

        let lower = try await Self.engine(entries, configuration: Self.gate(0.5))
            .retrieveAndSelectDetailed("zorbx g3", scope: .all)
        #expect(lower.selected.count > 1)
        #expect(lower.selected.contains { $0.memory.id == "e7" })
    }

    // MARK: - (c) The cosine thresholds follow the embedder's model

    @Test
    func theModelSetMatchesTheEmbeddersModelCaseInsensitively() {
        let configuration = MemoryEngineConfiguration()
        #expect(configuration.appliesSemanticThresholds(toModelID: "qwen/qwen3-embedding-8b"))
        #expect(configuration.appliesSemanticThresholds(toModelID: "Qwen/Qwen3-Embedding-8B"))
        #expect(configuration.appliesSemanticThresholds(toModelID: "  qwen/qwen3-embedding-8b "))
        #expect(!configuration.appliesSemanticThresholds(toModelID: "text-embedding-3-small"))
        #expect(!configuration.appliesSemanticThresholds(toModelID: nil))

        // An empty set means never, not every model.
        let never = MemoryEngineConfiguration(recallSemanticThresholdModels: [])
        #expect(!never.appliesSemanticThresholds(toModelID: "qwen/qwen3-embedding-8b"))
        #expect(!never.appliesSemanticThresholds(toModelID: "anything"))

        // Every model needs the explicit wildcard.
        let any = MemoryEngineConfiguration(recallSemanticThresholdModels: ["*"])
        #expect(any.appliesSemanticThresholds(toModelID: "anything"))
        #expect(any.appliesSemanticThresholds(toModelID: "qwen/qwen3-embedding-8b"))

        let custom = MemoryEngineConfiguration(recallSemanticThresholdModels: ["My-Model", "other"])
        #expect(custom.appliesSemanticThresholds(toModelID: "my-model"))
        #expect(custom.appliesSemanticThresholds(toModelID: "OTHER"))
        #expect(!custom.appliesSemanticThresholds(toModelID: "qwen/qwen3-embedding-8b"))
    }

    @Test
    func aModelOutsideTheSetIgnoresCAndAModelInsideAppliesIt() async throws {
        // `mid` sits at cosine 0.6 (over the 0.4 semantic floor, under C = 0.75).
        func selected(models: Set<String>) async throws -> Set<String> {
            let result = try await Self.engine(
                Self.semanticEntries,
                configuration: Self.gate(0.3, 0.75, support: 0.45, models: models),
                embedder: Self.fixedEmbedder
            ).retrieveAndSelectDetailed("qux", scope: .all)
            #expect(result.semanticRan)
            return Set(Self.ids(result.selected))
        }

        // Outside the set: C counts as `nil`, a hit of the z-score gate is
        // semantic support, so `mid` stays.
        #expect(try await selected(models: ["another-model"]) == ["near", "mid"])
        #expect(try await selected(models: []) == ["near", "mid"])
        // Inside the set — whatever the case — and with the wildcard: C applies.
        #expect(try await selected(models: [Self.modelID]) == ["near"])
        #expect(try await selected(models: ["EVIDENCE-TEST"]) == ["near"])
        #expect(try await selected(models: ["another-model", Self.modelID]) == ["near"])
        #expect(try await selected(models: ["*"]) == ["near"])
    }

    @Test
    func aModelOutsideTheSetIgnoresC2AndAModelInsideAppliesIt() async throws {
        // `noisy` shares `zed` but sits at cosine 0.30; C2 = 0.45 rejects it.
        func selected(models: Set<String>) async throws -> Set<String> {
            try await Self.supportRun(Self.gate(0.3, 0.7, support: 0.45, models: models)).selected
        }

        let withC2: Set<String> = ["supported", "unembedded", "foreign", "semantic"]
        #expect(try await selected(models: [Self.modelID]) == withC2)
        #expect(try await selected(models: ["*"]) == withC2)
        // C2 (and C) count as `nil`: `noisy` is lexically supported and kept.
        #expect(try await selected(models: ["another-model"]) == withC2.union(["noisy"]))
        #expect(try await selected(models: []) == withC2.union(["noisy"]))
    }

    @Test
    func theDefaultAppliesTheCosineThresholdsOnlyToTheMeasuredModel() async throws {
        // One entry at cosine 0.5: over the semantic floor (0.4), under C = 0.55.
        func run(model: String) async throws -> (selected: [String], candidates: [String]) {
            let entries = [
                Self.entry("hit", "gnu hen", cosine: 0.5, model: model),
                Self.entry("far", "yak elk", cosine: 0.2, model: model)
            ]
            // The default configuration, untouched.
            let result = try await Self.engine(
                entries,
                embedder: FixedEmbedder(vector: Self.queryVector, modelID: model)
            ).retrieveAndSelectDetailed("qux", scope: .all)
            #expect(result.semanticRan)
            return (Self.ids(result.selected), Self.ids(result.candidates))
        }

        // The measured model: C = 0.55 applies and rejects the 0.5.
        let measured = try await run(model: "qwen/qwen3-embedding-8b")
        #expect(measured.candidates == ["hit"])
        #expect(measured.selected.isEmpty)

        // Another model: C counts as `nil`, the semantic gate decides.
        let other = try await run(model: "text-embedding-3-small")
        #expect(other.candidates == ["hit"])
        #expect(other.selected == ["hit"])
    }

    @Test
    func withNoThresholdLeftEffectiveTheGateIsOff() async throws {
        // No lexical ratio and cosine thresholds that do not apply to this
        // model: all three count as `nil`, the retrieval is the plain one.
        let result = try await Self.engine(
            Self.metadataEntries,
            configuration: Self.gate(nil, 0.75, support: 0.45, models: ["another-model"]),
            embedder: Self.fixedEmbedder,
            analyzer: Self.metadataAnalyzer
        ).retrieveAndSelectDetailed("zed", scope: .all)

        #expect(Set(Self.ids(result.selected)) == Set(Self.ids(result.candidates)))
        #expect(Set(Self.ids(result.selected)).isSuperset(of: ["lex", "tagged"]))
    }

    // MARK: - Lexical support: L, C and C2 together

    /// `zed` is in four of the eight entries (IDF ln 2 ≈ 0.69, against
    /// `idfMax(8)` ≈ 1.79: a ratio of 0.3 puts the threshold at ≈ 0.54). The
    /// query is `zed` and every text embeds as the query direction, so the
    /// cosine of an entry is the one it was built with. Fewer than eight
    /// entries carry a vector of the model, so only the 0.4 semantic floor
    /// applies.
    private static let supportEntries: [EngineMemoryEntry] = [
        // Shares `zed`, cosine 0.30: under the floor, a lexical seed only.
        entry("noisy", "zed fox", cosine: 0.30),
        // Shares `zed`, cosine 0.50: between C2 = 0.45 and C = 0.7.
        entry("supported", "zed owl", cosine: 0.50),
        // Shares `zed`, no vector at all.
        entry("unembedded", "zed ant"),
        // Shares `zed`, a vector of another model: no cosine to compare.
        EngineMemoryEntry(
            id: "foreign",
            category: .fact,
            content: "zed yak",
            embedding: vector(cosine: 0.9),
            embeddingModel: "another-model"
        ),
        // Shares nothing, cosine 0.90: a semantic seed only.
        entry("semantic", "gnu hen", cosine: 0.90),
        // Shares nothing, cosine 0.20: not even a candidate.
        entry("far", "emu elk", cosine: 0.20),
        entry("filler", "pig ram"),
        entry("filler2", "cow bee")
    ]

    private struct SupportRun {
        let selected: Set<String>
        let candidates: Set<String>
        let evidence: [String: MemoryCandidateEvidence]
        let semanticRan: Bool
    }

    /// The prompt `zed` over ``supportEntries`` with the given gate.
    private static func supportRun(
        _ configuration: MemoryEngineConfiguration,
        embedder: (any EmbeddingProvider)? = RecallEvidenceGateTests.fixedEmbedder,
        includeSemantic: Bool = true
    ) async throws -> SupportRun {
        let result = try await engine(supportEntries, configuration: configuration, embedder: embedder)
            .retrieveAndSelectDetailed("zed", scope: .all, includeSemantic: includeSemantic)
        return SupportRun(
            selected: Set(ids(result.selected)),
            candidates: Set(ids(result.candidates)),
            evidence: result.evidence,
            semanticRan: result.semanticRan
        )
    }

    @Test
    func aLexicallySupportedEntryFarFromTheQueryIsExcluded() async throws {
        // With no support threshold the entry is kept for its shared term alone
        // (the OR rule): lexical evidence 0.69 ≥ 0.3 × idfMax(8) ≈ 0.54, cosine 0.30.
        let open = try await Self.supportRun(Self.gate(0.3, 0.7))
        #expect(open.selected == ["noisy", "supported", "unembedded", "foreign", "semantic"])
        #expect((open.evidence["noisy"]?.lexical ?? 0) >= 0.5)
        #expect(Self.isClose(open.evidence["noisy"]?.semantic, to: 0.30))

        // C2 = 0.45 rejects it: plenty of vocabulary, too far from the query.
        let supported = try await Self.supportRun(Self.gate(0.3, 0.7, support: 0.45))
        #expect(supported.semanticRan)
        #expect(supported.selected == ["supported", "unembedded", "foreign", "semantic"])

        // The gate narrows the selection only: the candidates are the same.
        #expect(supported.candidates == open.candidates)
        #expect(supported.candidates.contains("noisy"))
        #expect(supported.evidence == open.evidence)
    }

    @Test
    func aCosineBetweenTheTwoThresholdsKeepsALexicallySupportedEntry() async throws {
        let probe = try await Self.supportRun(Self.gate(0.3, 0.7))
        let cosine = try #require(probe.evidence["supported"]?.semantic)
        #expect(Self.isClose(cosine, to: 0.50))
        // Under C: the semantic path alone would not keep it.
        #expect(cosine < 0.7)

        // C2 under the cosine keeps it, and the threshold is inclusive.
        let under = try await Self.supportRun(Self.gate(0.3, 0.7, support: 0.45))
        #expect(under.selected.contains("supported"))
        let exact = try await Self.supportRun(Self.gate(0.3, 0.7, support: cosine))
        #expect(exact.selected.contains("supported"))

        // Just over it, the entry is out.
        let over = try await Self.supportRun(Self.gate(0.3, 0.7, support: cosine + 0.01))
        #expect(!over.selected.contains("supported"))
    }

    @Test
    func aCosineAtTheSemanticThresholdNeedsNoSharedTermNorTheSupportCosine() async throws {
        let probe = try await Self.supportRun(Self.gate(0.3, 0.7))
        let cosine = try #require(probe.evidence["semantic"]?.semantic)
        #expect(probe.evidence["semantic"]?.lexical == 0)

        // C2 above every cosine closes the support path; the entry that shares
        // no term but reaches C stays, whatever C2 says.
        let strict = try await Self.supportRun(Self.gate(0.3, 0.7, support: 0.95))
        #expect(strict.selected == ["semantic", "unembedded", "foreign"])

        // C is inclusive.
        let exact = try await Self.supportRun(Self.gate(0.3, cosine, support: 0.95))
        #expect(exact.selected.contains("semantic"))
        let over = try await Self.supportRun(Self.gate(0.3, cosine + 0.01, support: 0.95))
        #expect(!over.selected.contains("semantic"))
    }

    @Test
    func anEntryWithoutAVectorOfTheModelIsDecidedByItsLexicalEvidenceAlone() async throws {
        // The semantic search ran, yet `unembedded` has no vector and `foreign`
        // a vector of another model: no cosine, so C and C2 do not apply, even
        // at 0.99, where they would reject any entry that has one.
        let strict = try await Self.supportRun(Self.gate(0.3, 0.99, support: 0.99))
        #expect(strict.semanticRan)
        #expect(strict.selected == ["unembedded", "foreign"])
        #expect(strict.evidence["unembedded"]?.semantic == nil)
        #expect(strict.evidence["foreign"]?.semantic == nil)
        #expect((strict.evidence["unembedded"]?.lexical ?? 0) >= 0.5)

        // The lexical threshold is the one that can close them.
        let demanding = try await Self.supportRun(Self.gate(3, 0.7, support: 0.45))
        #expect(demanding.selected == ["semantic"])
    }

    @Test
    func withoutASemanticSearchTheCosineThresholdsAreIgnored() async throws {
        // C and C2 at 0.99 would reject every entry with a cosine; with no
        // semantic search there is none, and the lexical evidence decides.
        let configuration = Self.gate(0.3, 0.99, support: 0.99)
        let expected: Set<String> = ["noisy", "supported", "unembedded", "foreign"]

        let switchedOff = try await Self.supportRun(configuration, includeSemantic: false)
        let endpointDown = try await Self.supportRun(configuration, embedder: DownEmbedder())
        let noEmbedder = try await Self.supportRun(configuration, embedder: nil)
        for run in [switchedOff, endpointDown, noEmbedder] {
            #expect(!run.semanticRan)
            #expect(run.selected == expected)
            #expect(run.evidence.values.allSatisfy { $0.semantic == nil })
        }
    }

    @Test
    func theSupportThresholdAloneTurnsTheGateOn() async throws {
        let open = try await Self.supportRun(Self.gateOff())
        #expect(open.selected == open.candidates)
        #expect(open.selected.contains("noisy"))

        // L nil asks for any shared term; C nil for a hit of the semantic
        // gate (cosine 0.50 and 0.90, over the 0.4 floor).
        let gated = try await Self.supportRun(Self.gate(support: 0.45))
        #expect(gated.selected == ["supported", "unembedded", "foreign", "semantic"])
        #expect(gated.candidates == open.candidates)
    }

    @Test
    func aSupportThresholdUnderEveryCosineLeavesTheOrRule() async throws {
        let orRule = try await Self.supportRun(Self.gate(0.3, 0.7))
        let low = try await Self.supportRun(Self.gate(0.3, 0.7, support: -1))
        #expect(low.selected == orRule.selected)
        #expect(low.evidence == orRule.evidence)
    }

    // MARK: - One corpus for the ranking and the evidence

    /// An index with the BM25 of the default one, but not the default index:
    /// the engine searches it as it is, query by query, and tokenizes the
    /// corpus again for the evidence.
    private struct SeparateBM25Index: MemoryIndex {
        let wrapped: BM25MemoryIndex

        func search(
            query: String,
            memories: [EngineMemoryEntry],
            scope: EngineMemoryScope,
            limit: Int
        ) async throws -> [ScoredMemoryID] {
            try await wrapped.search(query: query, memories: memories, scope: scope, limit: limit)
        }
    }

    @Test
    func theSharedCorpusRanksAndEvidencesLikeTheSeparatePasses() async throws {
        let queries = ["red zed", "red cat", "gnu hen owl"]
        let analyzer = ScriptedAnalyzer(plan: MemoryQueryPlan(queries: queries))
        let gated = Self.gate(0.1)

        for (k1, b) in [(Float(1.2), Float(0.75)), (Float(2), Float(0.3))] {
            let index = BM25MemoryIndex(k1: k1, b: b)

            // The default index with the gate on: ranking and evidence share a corpus.
            let shared = try await Self.engine(
                Self.handBuilt, configuration: gated, lexicalIndex: index, analyzer: analyzer
            ).retrieveAndSelectDetailed("red zed", scope: .all)
            // A custom index: its own ranking and a second corpus for the evidence.
            let separate = try await Self.engine(
                Self.handBuilt, configuration: gated, lexicalIndex: SeparateBM25Index(wrapped: index), analyzer: analyzer
            ).retrieveAndSelectDetailed("red zed", scope: .all)
            // The default index with nothing asking for the evidence: the plain
            // `BM25MemoryIndex.search(queries:)` path, as before the gate existed.
            let plain = try await Self.engine(
                Self.handBuilt, configuration: Self.gateOff(), lexicalIndex: index, analyzer: analyzer
            ).retrieveAndSelectDetailed("red zed", scope: .all, collectEvidence: false)

            let label = "k1=\(k1) b=\(b)"
            #expect(!plain.candidates.isEmpty, "\(label)")
            #expect(plain.evidence.isEmpty, "\(label)")
            #expect(Self.sameCandidates(shared.candidates, plain.candidates, tolerance: 1e-5), "\(label)")
            #expect(Self.sameCandidates(separate.candidates, plain.candidates, tolerance: 1e-5), "\(label)")
            #expect(shared.seedIDs == plain.seedIDs, "\(label)")
            #expect(separate.seedIDs == plain.seedIDs, "\(label)")

            // The evidence is the one of a corpus built on its own, on the same scale.
            let terms = Set(queries.flatMap(MemorySearch.tokens))
            let expected = MemoryLexicalCorpus(memories: Self.handBuilt, scope: .all)
                .lexicalEvidence(terms: terms, ids: Set(Self.ids(shared.candidates)))
            #expect(!shared.evidence.isEmpty, "\(label)")
            #expect(shared.evidence == separate.evidence, "\(label)")
            #expect(shared.lexicalScale == separate.lexicalScale, "\(label)")
            #expect(shared.lexicalScale.documentCount == Self.handBuilt.count, "\(label)")
            for (id, evidence) in shared.evidence {
                #expect(evidence.lexical == expected[id], "\(label) \(id)")
            }
        }
    }

    @Test
    func aPromptWithoutTokensBuildsNoCorpusAndSelectsNothing() async throws {
        // Punctuation only: no query has a token, so the memories are not even
        // tokenized; with or without the gate nothing is found.
        for configuration in [MemoryEngineConfiguration(), Self.gate(0.3, 0.7, support: 0.45)] {
            let result = try await Self.engine(Self.animals, configuration: configuration)
                .retrieveAndSelectDetailed("!!!", scope: .all)
            #expect(result.candidates.isEmpty)
            #expect(result.selected.isEmpty)
            #expect(result.evidence.isEmpty)
            #expect(result.lexicalScale == .empty)
        }
    }
}
