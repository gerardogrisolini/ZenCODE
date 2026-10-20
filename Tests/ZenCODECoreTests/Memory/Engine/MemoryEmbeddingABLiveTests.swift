//
//  MemoryEmbeddingABLiveTests.swift
//  ZenCODECoreTests (memory engine)
//
//  Opt-in live measurement of memory retrieval quality on a *copy* of a real
//  memory graph: BM25-only (A) against several BM25 + semantic configurations
//  (fusion strategy, vector centering, z-score gating) evaluated through the
//  production engine pipeline (`retrieveAndSelect`) against a hand-defined
//  relevance set. It never runs in the ordinary suite (requires
//  ZENCODE_RUN_LIVE_MEMORY_AB=1), embeds every query exactly once through the
//  provider production would resolve, never mutates the source graph and never
//  prints credentials.
//
//  Environment:
//    ZENCODE_RUN_LIVE_MEMORY_AB=1        enables the test
//    ZENCODE_AB_GRAPH_PATH               path of the memory.graph.json to copy
//    ZENCODE_AB_SETTINGS_PATH            settings.json with `memoryEmbedding`
//    ZENCODE_AB_REPORT_PATH              markdown report destination (optional)
//    ZENCODE_AB_EXCLUDE_IDS              comma-separated entry id prefixes to
//                                        drop from the copy (e.g. journal
//                                        entries that quote the queries)
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Memory embedding A/B (live, opt-in)", .serialized)
struct MemoryEmbeddingABLiveTests {
    // MARK: - Doubles

    /// Embeds each distinct text once; every engine variant shares the cache.
    private actor MemoizingEmbeddingProvider: EmbeddingProvider {
        nonisolated let modelID: String
        private let upstream: any EmbeddingProvider
        private var cache: [String: [Float]] = [:]
        private(set) var requestCount = 0
        private(set) var requestDurations: [Double] = []

        init(upstream: any EmbeddingProvider) {
            self.upstream = upstream
            self.modelID = upstream.modelID
        }

        func embed(_ text: String) async throws -> [Float] {
            if let cached = cache[text] { return cached }
            let clock = ContinuousClock()
            let start = clock.now
            let vector = try await upstream.embed(text)
            requestDurations.append(MemoryEmbeddingABLiveTests.milliseconds(clock.now - start))
            requestCount += 1
            cache[text] = vector
            return vector
        }
    }

    private final class FailureRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func record(_ message: String) {
            lock.lock()
            messages.append(message)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }
    }

    // MARK: - Queries and relevance

    private struct Query {
        let label: String
        let text: String
        /// Entry id prefixes (8 hex chars) judged relevant from the graph
        /// content, independently of any retrieval output.
        let relevant: Set<String>
        /// Queries BM25 already answers exactly: a semantic configuration must
        /// not displace their relevant top-1.
        let lexicallyExact: Bool
    }

    private static let queries: [Query] = [
        Query(label: "EN identifier only", text: "ZENCODE_MEMORY_RECALL_SEMANTIC_TIMEOUT_MS",
              relevant: ["0BC315CC", "D2C14461"], lexicallyExact: true),
        Query(label: "IT precise", text: "race EAGAIN exit FeatureManagedProcess stdout perso",
              relevant: ["9319E7DF", "4ECFD493"], lexicallyExact: true),
        Query(label: "IT vague paraphrase", text: "il processo figlio perde l'output quando termina",
              relevant: ["9319E7DF", "4ECFD493"], lexicallyExact: false),
        Query(label: "EN paraphrase of IT entry", text: "how do sub-agents inherit tool permissions from the parent",
              relevant: ["5092E69C", "7CFF6D82", "C1937A90", "4D5B8820"], lexicallyExact: false),
        Query(label: "IT vague", text: "promozione del progetto sui social",
              relevant: ["AB3B02FF", "15AB66B7", "AA9106BF"], lexicallyExact: false),
        Query(label: "EN cross-lingual", text: "publishing announcements on LinkedIn and Twitter",
              relevant: ["AA9106BF", "15AB66B7", "AB3B02FF"], lexicallyExact: false),
        Query(label: "IT paraphrase", text: "la compilazione fallisce dopo l'aggiornamento della toolchain",
              relevant: ["94FA158E", "C414D7BE", "25F54727"], lexicallyExact: false),
        Query(label: "EN vague", text: "flaky tests under CPU contention",
              relevant: ["7EF23311", "DB51C056", "9D23F9A4"], lexicallyExact: false),
        Query(label: "IT precise", text: "quoting non preservato in container machine run",
              relevant: ["0BC315CC", "243B1397", "C414D7BE"], lexicallyExact: true),
        Query(label: "EN vague", text: "where are the memory graph files stored and in which format",
              relevant: ["0BC315CC", "EB87DC0D", "ABB4BA07"], lexicallyExact: false),
        Query(label: "IT paraphrase", text: "approvare un piano prima di eseguirlo",
              relevant: ["978D40B4", "20322CEE"], lexicallyExact: false),
        Query(label: "EN cross-lingual synonym", text: "the hourglass spinner never stops for delegated tools",
              relevant: ["2EE8236A", "71E0E81E"], lexicallyExact: false),
        Query(label: "IT synonym", text: "doppio riquadro di autorizzazione",
              relevant: ["D936E4BE", "D3399591"], lexicallyExact: false),
        Query(label: "EN vague", text: "Telegram bot stops receiving updates after network errors",
              relevant: ["20466DA1", "9E06DBC9", "4382A03A"], lexicallyExact: false),
    ]

    // MARK: - Variants

    private struct Variant {
        let name: String
        let configuration: MemoryEngineConfiguration
    }

    private static let variants: [Variant] = {
        func make(
            _ name: String,
            fusion: MemoryRankFusion,
            threshold: Float = 0.4,
            zScore: Float,
            rrfConstant: Float = 60
        ) -> Variant {
            Variant(
                name: name,
                configuration: MemoryEngineConfiguration(
                    similarityThreshold: threshold,
                    semanticMinimumZScore: zScore,
                    fusion: fusion,
                    rrfRankConstant: rrfConstant
                )
            )
        }
        return [
            make("B0 rrf60 thr0.4 (pre-fix)", fusion: .reciprocalRank, zScore: 0),
            make("C0 norm thr0.4 (no gate)", fusion: .normalizedScore, zScore: 0),
            make("R2 norm robust z2", fusion: .normalizedScore, zScore: 2),
            make("R25 norm robust z2.5 (chosen)", fusion: .normalizedScore, zScore: 2.5),
            make("R3 norm robust z3", fusion: .normalizedScore, zScore: 3),
            make("R35 norm robust z3.5", fusion: .normalizedScore, zScore: 3.5),
            make("R4 norm robust z4", fusion: .normalizedScore, zScore: 4),
            make("X3 rrf60 robust z3", fusion: .reciprocalRank, zScore: 3),
            Variant(name: "D  engine defaults", configuration: MemoryEngineConfiguration()),
        ]
    }()

    // MARK: - Metrics

    private struct QueryOutcome {
        let topIDs: [String]
        let selectedCount: Int
        let candidateCount: Int
        let semanticHitCount: Int
        let milliseconds: Double
    }

    private struct Aggregate {
        var reciprocalRanks: [Double] = []
        var recallAt5: [Double] = []
        var hitAt1 = 0
        var misses = 0
        var exactRegressions: [String] = []
        var selectedCounts: [Int] = []
        var jaccardVersusLexical: [Double] = []

        var meanReciprocalRank: Double { mean(reciprocalRanks) }
        var meanRecallAt5: Double { mean(recallAt5) }
        var meanSelected: Double { mean(selectedCounts.map(Double.init)) }
        var meanJaccard: Double { mean(jaccardVersusLexical) }

        private func mean(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
    }

    private static func prefix8(_ id: String) -> String { String(id.prefix(8)).uppercased() }

    private static func isRelevant(_ id: String, for query: Query) -> Bool {
        query.relevant.contains(prefix8(id))
    }

    private static func score(_ outcome: QueryOutcome, query: Query, lexicalTop: [String], into aggregate: inout Aggregate) {
        let top5 = Array(outcome.topIDs.prefix(5))
        if let firstRelevant = outcome.topIDs.firstIndex(where: { isRelevant($0, for: query) }) {
            aggregate.reciprocalRanks.append(1 / Double(firstRelevant + 1))
        } else {
            aggregate.reciprocalRanks.append(0)
        }
        let relevantInTop5 = top5.filter { isRelevant($0, for: query) }.count
        aggregate.recallAt5.append(Double(relevantInTop5) / Double(min(5, query.relevant.count)))
        if let first = top5.first, isRelevant(first, for: query) { aggregate.hitAt1 += 1 }
        if relevantInTop5 == 0 { aggregate.misses += 1 }
        if query.lexicallyExact,
           let lexicalFirst = lexicalTop.first, isRelevant(lexicalFirst, for: query),
           !(top5.first.map { isRelevant($0, for: query) } ?? false) {
            aggregate.exactRegressions.append(query.text)
        }
        aggregate.selectedCounts.append(outcome.selectedCount)
        let a = Set(lexicalTop.prefix(5)), b = Set(top5)
        let union = a.union(b)
        aggregate.jaccardVersusLexical.append(union.isEmpty ? 1 : Double(a.intersection(b).count) / Double(union.count))
    }

    // MARK: - Test

    @Test func compareRetrievalConfigurationsOnRealGraph() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ZENCODE_RUN_LIVE_MEMORY_AB"] == "1" else { return }
        let graphPath = try #require(env["ZENCODE_AB_GRAPH_PATH"])
        let settingsPath = try #require(env["ZENCODE_AB_SETTINGS_PATH"])
        let reportPath = env["ZENCODE_AB_REPORT_PATH"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("zencode-memory-ab-report.md").path
        let excludedPrefixes = Set(
            (env["ZENCODE_AB_EXCLUDE_IDS"] ?? "")
                .split(separator: ",")
                .map { Self.prefix8($0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
        )

        // Private copy: the pipeline is read-only, but a measurement must never
        // touch the source graph.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let graphURL = tempDir.appendingPathComponent("memory.graph.json")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: graphPath), to: graphURL)
        var loadedGraph = try await JSONMemoryPersistence(url: graphURL).load()
        for id in loadedGraph.memories.keys where excludedPrefixes.contains(Self.prefix8(id)) {
            _ = loadedGraph.removeMemory(id: id)
        }
        let graph = loadedGraph

        // The exact provider production would resolve (endpoint, model, key reuse).
        let manifest = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: settingsPath))
        )
        let upstream = try #require(MemoryEmbedding.provider(manifest: manifest, environment: [:]))
        let embedder = MemoizingEmbeddingProvider(upstream: upstream)
        let recorder = FailureRecorder()

        func makeEngine(_ configuration: MemoryEngineConfiguration) -> MemoryEngine {
            MemoryEngine(
                graph: graph,
                embedder: embedder,
                selector: ScoreThresholdMemorySelector(),
                configuration: configuration,
                semanticFailureReporter: { recorder.record($0) }
            )
        }

        let entries = Array(graph.memories.values)
        let activeCount = entries.filter(\.active).count
        let vectorCount = entries.filter { $0.active && $0.embeddingMatches(model: embedder.modelID) }.count
        let clock = ContinuousClock()

        var report = "# Memory retrieval A/B v2\n\n"
        report += "- graph: \(entries.count) entries, \(activeCount) active, \(vectorCount) active with a vector from `\(embedder.modelID)`; excluded prefixes: \(excludedPrefixes.sorted().joined(separator: ", "))\n"
        report += "- A = BM25 + graph cascade (no embedder); Bn = BM25 + semantic, see variants; automatic-recall configuration, scope .all, read-only `retrieveAndSelect`\n"
        report += "- metrics: MRR over the ranked candidates, recall@5 = |relevant ∩ top-5| / min(5, |relevant|), hit@1, misses = queries with no relevant entry in the top-5, exact-regressions = lexically exact queries whose relevant top-1 was displaced, Jaccard = top-5 overlap with A\n\n"

        // A: lexical only, once per query.
        let baselineEngine = makeEngine(MemoryEngineConfiguration())
        var lexicalTops: [[String]] = []
        var lexicalAggregate = Aggregate()
        var lexicalOutcomes: [QueryOutcome] = []
        for query in Self.queries {
            let start = clock.now
            let result = try await baselineEngine.retrieveAndSelect(query.text, scope: .all, graph: graph, includeSemantic: false)
            let outcome = QueryOutcome(
                topIDs: result.candidates.map(\.memory.id),
                selectedCount: result.selected.count,
                candidateCount: result.candidates.count,
                semanticHitCount: 0,
                milliseconds: Self.milliseconds(clock.now - start)
            )
            lexicalOutcomes.append(outcome)
            lexicalTops.append(outcome.topIDs)
            Self.score(outcome, query: query, lexicalTop: outcome.topIDs, into: &lexicalAggregate)
        }

        // Pure semantic distribution analysis from the cached vectors.
        report += "## Pure semantic ranking (raw cosine)\n\n"
        report += "Per query: distribution of the cosine over all eligible entries (median, robust scale = 1.4826·MAD, top and its robust z), how many entries pass robust z ≥ 3, and the rank/robust z of each relevant entry.\n\n"
        var bestRelevantRanks: [Int] = []
        for (index, query) in Self.queries.enumerated() {
            let vector = try await embedder.embed(query.text)
            let scored = MemorySearch.semanticSimilarities(
                graph: graph, queryEmbedding: vector, modelID: embedder.modelID, scope: .all
            )
            let values = scored.map(\.score).sorted()
            let middle = values.count / 2
            let median: Float = values.isEmpty ? 0 : (values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle])
            let gate = MemorySearch.robustOutlierGate(scored.map(\.score), zScore: 1) ?? median
            let scale = gate - median
            let ordered = scored.sorted {
                if $0.score == $1.score { return $0.id < $1.id }
                return $0.score > $1.score
            }
            let z: (Float) -> Float = { scale > 0 ? ($0 - median) / scale : 0 }
            let top = ordered.first?.score ?? 0
            let relevantRanks = ordered.enumerated().compactMap { position, item -> String? in
                Self.isRelevant(item.id, for: query) ? "\(Self.prefix8(item.id))#\(position + 1)(z\(Self.fmt(Double(z(item.score)))))" : nil
            }
            bestRelevantRanks.append(ordered.firstIndex { Self.isRelevant($0.id, for: query) }.map { $0 + 1 } ?? 999)
            report += "- Q\(index + 1) [\(query.label)]: median \(Self.fmt(Double(median))), scale \(Self.fmt(Double(scale))), top \(Self.fmt(Double(top))) (z \(Self.fmt(Double(z(top))))), n(z≥3)=\(ordered.filter { z($0.score) >= 3 }.count); relevant: \(relevantRanks.isEmpty ? "none ranked" : relevantRanks.joined(separator: " "))\n"
        }
        report += "\nSummary: best relevant rank median \(Self.fmt(Self.median(bestRelevantRanks.map(Double.init)))); queries with a relevant entry at pure-semantic #1: \(bestRelevantRanks.filter { $0 == 1 }.count)/\(Self.queries.count)\n\n"

        // Variants through the production pipeline.
        var variantAggregates: [(Variant, Aggregate, [QueryOutcome])] = []
        for variant in Self.variants {
            let engine = makeEngine(variant.configuration)
            var aggregate = Aggregate()
            var outcomes: [QueryOutcome] = []
            for (index, query) in Self.queries.enumerated() {
                let start = clock.now
                let result = try await engine.retrieveAndSelect(query.text, scope: .all, graph: graph, includeSemantic: true)
                let vector = try await embedder.embed(query.text)
                let semanticHits = MemorySearch.semantic(
                    graph: graph, queryEmbedding: vector, modelID: embedder.modelID, scope: .all,
                    threshold: variant.configuration.similarityThreshold,
                    minimumZScore: variant.configuration.semanticMinimumZScore,
                    limit: variant.configuration.maxSemanticHits * 4
                ).count
                let outcome = QueryOutcome(
                    topIDs: result.candidates.map(\.memory.id),
                    selectedCount: result.selected.count,
                    candidateCount: result.candidates.count,
                    semanticHitCount: semanticHits,
                    milliseconds: Self.milliseconds(clock.now - start)
                )
                outcomes.append(outcome)
                Self.score(outcome, query: query, lexicalTop: lexicalTops[index], into: &aggregate)
            }
            variantAggregates.append((variant, aggregate, outcomes))
        }

        report += "## Aggregate over \(Self.queries.count) queries\n\n"
        report += "| variant | MRR | recall@5 | hit@1 | misses | exact-regr. | mean selected | Jaccard vs A |\n|---|---|---|---|---|---|---|---|\n"
        report += "| A BM25 only | \(Self.fmt(lexicalAggregate.meanReciprocalRank)) | \(Self.fmt(lexicalAggregate.meanRecallAt5)) | \(lexicalAggregate.hitAt1) | \(lexicalAggregate.misses) | \(lexicalAggregate.exactRegressions.count) | \(Self.fmt(lexicalAggregate.meanSelected)) | 1.00 |\n"
        for (variant, aggregate, _) in variantAggregates {
            report += "| \(variant.name) | \(Self.fmt(aggregate.meanReciprocalRank)) | \(Self.fmt(aggregate.meanRecallAt5)) | \(aggregate.hitAt1) | \(aggregate.misses) | \(aggregate.exactRegressions.count) | \(Self.fmt(aggregate.meanSelected)) | \(Self.fmt(aggregate.meanJaccard)) |\n"
        }
        report += "\n"
        for (variant, aggregate, _) in variantAggregates where !aggregate.exactRegressions.isEmpty {
            report += "- \(variant.name) displaced the exact lexical top-1 for: \(aggregate.exactRegressions.map { "“\($0)”" }.joined(separator: ", "))\n"
        }

        report += "\n## Per-query top-5 (✓ = relevant; `sel`=selected for injection, `sem`=semantic hits entering fusion)\n\n"
        for (index, query) in Self.queries.enumerated() {
            report += "### Q\(index + 1) [\(query.label)] “\(query.text)” — relevant: \(query.relevant.sorted().joined(separator: ", "))\n\n"
            func row(_ name: String, _ outcome: QueryOutcome) -> String {
                let ids = outcome.topIDs.prefix(5).map { id -> String in
                    Self.isRelevant(id, for: query) ? "✓\(Self.prefix8(id))" : " \(Self.prefix8(id))"
                }
                return "- \(name.padding(toLength: 30, withPad: " ", startingAt: 0)) sel=\(outcome.selectedCount) sem=\(outcome.semanticHitCount) · \(ids.joined(separator: "  "))\n"
            }
            report += row("A BM25 only", lexicalOutcomes[index])
            for (variant, _, outcomes) in variantAggregates {
                report += row(variant.name, outcomes[index])
            }
            report += "\n"
        }

        let durations = await embedder.requestDurations
        let requestCount = await embedder.requestCount
        report += "## Embedding requests\n\n- requests: \(requestCount) (one per distinct query); latency ms median \(Self.fmt(Self.median(durations))), min \(Self.fmt(durations.min() ?? 0)), max \(Self.fmt(durations.max() ?? 0))\n"
        let failures = recorder.all
        report += "- semantic failures reported by the engine: \(failures.count)\n"
        for failure in failures { report += "  - \(failure)\n" }

        try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        if let summaryStart = report.range(of: "## Aggregate over") {
            print(String(report[summaryStart.lowerBound...].prefix(4_000)))
        }
        #expect(failures.isEmpty)
        #expect(requestCount == Self.queries.count)
    }

    // MARK: - Helpers

    fileprivate static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
