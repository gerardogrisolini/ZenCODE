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
//  Any active entry of the copy without a vector from the provider's model is
//  re-embedded in memory (production text, at most 4 requests in flight, one
//  retry) before measuring, so the harness can evaluate an embedding model
//  other than the one that produced the stored vectors. Vectors of archived
//  entries are cleared on the copy, mirroring the product decision (retrieval
//  only reads active entries, so it is unaffected).
//
//  Environment:
//    ZENCODE_RUN_LIVE_MEMORY_AB=1        enables the test
//    ZENCODE_AB_GRAPH_PATH               path of the memory.graph.json to copy
//                                        (its memory.graph.json.vectors file,
//                                        graph version 4, is copied with it)
//    ZENCODE_AB_SETTINGS_PATH            settings.json with `memoryEmbedding`
//    ZENCODE_AB_REPORT_PATH              markdown report destination (optional)
//    ZENCODE_AB_EXCLUDE_IDS              comma-separated entry id prefixes to
//                                        drop from the copy (e.g. journal
//                                        entries that quote the queries)
//    ZENCODE_AB_EMBEDDING_MODEL          embedding model replacing the one in
//                                        settings.json (in memory only; the
//                                        endpoint and provider reference are
//                                        kept and settings.json is never written)
//    ZENCODE_AB_PRUNE_RELATIONS=1        applies ONLY `pruneRelations` (default
//                                        relation policy: at most 12 relatesTo
//                                        edges per entry) to the in-memory copy
//                                        before re-embedding, and reports how many
//                                        edges it removed; the source graph is
//                                        never touched
//    ZENCODE_AB_COMPARE_FLOAT16=1        after re-embedding, evaluates every
//                                        variant twice in the same run: on the
//                                        binary32 vectors and on a copy whose
//                                        vectors are rounded to binary16 (same
//                                        vectors, same query embeddings), and
//                                        reports both aggregate tables and the
//                                        per-query rows whose top-5 changed
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

    // MARK: - Re-embedding

    private struct ReembedJob: Sendable {
        let id: String
        /// Exactly the text production embeds for an entry.
        let text: String
    }

    private struct ReembedResult: Sendable {
        let id: String
        let values: [Float]?
        /// Latency of the request that produced `values` (0 when it failed).
        let milliseconds: Double
        let attempts: Int
        let error: String?
    }

    /// Embeds `jobs` with at most `maxConcurrent` requests in flight. A failing
    /// job is retried once; if it fails again it is returned with its error and
    /// no vector instead of aborting the run.
    private static func reembed(
        _ jobs: [ReembedJob],
        with provider: any EmbeddingProvider,
        maxConcurrent: Int
    ) async -> [ReembedResult] {
        await withTaskGroup(of: ReembedResult.self, returning: [ReembedResult].self) { group in
            var results: [ReembedResult] = []
            var next = 0
            while next < min(maxConcurrent, jobs.count) {
                let job = jobs[next]
                next += 1
                group.addTask { await Self.reembedOne(job, with: provider) }
            }
            while let result = await group.next() {
                results.append(result)
                if next < jobs.count {
                    let job = jobs[next]
                    next += 1
                    group.addTask { await Self.reembedOne(job, with: provider) }
                }
            }
            return results
        }
    }

    private static func reembedOne(_ job: ReembedJob, with provider: any EmbeddingProvider) async -> ReembedResult {
        let clock = ContinuousClock()
        var lastError = ""
        for attempt in 1...2 {
            let start = clock.now
            do {
                let values = try await provider.embed(job.text)
                return ReembedResult(
                    id: job.id, values: values, milliseconds: milliseconds(clock.now - start),
                    attempts: attempt, error: nil
                )
            } catch {
                lastError = describe(error)
            }
        }
        return ReembedResult(id: job.id, values: nil, milliseconds: 0, attempts: 2, error: lastError)
    }

    /// One-line, bounded error text for the report; credential-looking tokens
    /// are redacted defensively.
    private static func describe(_ error: Error) -> String {
        let text: String
        if case OpenAICompatibleEmbeddingError.httpStatus(let status, let body) = error {
            text = "HTTP \(status): \(body)"
        } else {
            text = String(describing: error)
        }
        let redacted = text
            .replacingOccurrences(of: #"(?i)bearer\s+\S+"#, with: "Bearer <redacted>", options: .regularExpression)
            .replacingOccurrences(of: #"sk-[A-Za-z0-9_\-]{8,}"#, with: "<redacted>", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
        return String(redacted.prefix(200))
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

    /// Every variant, and A, evaluated over one graph.
    private struct Evaluation {
        var lexical = Aggregate()
        var lexicalOutcomes: [QueryOutcome] = []
        var variants: [(Variant, Aggregate, [QueryOutcome])] = []

        /// Rows of the per-query section, in report order: A, then each variant.
        var rows: [(name: String, outcomes: [QueryOutcome], aggregate: Aggregate)] {
            [("A BM25 only", lexicalOutcomes, lexical)] + variants.map { ($0.0.name, $0.2, $0.1) }
        }
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

    /// Hermetic: the harness copies a version 4 graph with its vectors file,
    /// so the copy loads with the same vectors as the source.
    @Test func harnessCopiesTheVectorsFileWithTheGraph() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let copyDirectory = root.appendingPathComponent("copy", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: copyDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let source = sourceDirectory.appendingPathComponent("memory.graph.json")
        var graph = MemoryGraph()
        graph.addMemory(EngineMemoryEntry(
            id: "vec", category: .fact, content: "with a vector",
            embedding: [0.5, -0.25, 1], embeddingModel: "m"
        ))
        try await JSONMemoryPersistence(url: source).save(graph)

        let copy = try Self.copyGraphFiles(from: source, into: copyDirectory)

        #expect(copy.lastPathComponent == "memory.graph.json")
        #expect(try Data(contentsOf: JSONMemoryPersistence.vectorsURL(forGraphAt: copy))
            == Data(contentsOf: JSONMemoryPersistence.vectorsURL(forGraphAt: source)))
        #expect(try await JSONMemoryPersistence(url: copy).load().memories["vec"]?.embedding == [0.5, -0.25, 1])

        // Without a vectors file (a version 3 graph) only the JSON is copied.
        let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        try fileManager.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try fileManager.removeItem(at: JSONMemoryPersistence.vectorsURL(forGraphAt: source))
        let legacyCopy = try Self.copyGraphFiles(from: source, into: legacyDirectory)
        #expect(try fileManager.contentsOfDirectory(atPath: legacyDirectory.path) == [legacyCopy.lastPathComponent])
    }

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
        let graphURL = try Self.copyGraphFiles(from: URL(fileURLWithPath: graphPath), into: tempDir)
        var loadedGraph = try await JSONMemoryPersistence(url: graphURL).load()
        for id in loadedGraph.memories.keys where excludedPrefixes.contains(Self.prefix8(id)) {
            _ = loadedGraph.removeMemory(id: id)
        }

        // The exact provider production would resolve (endpoint, model, key reuse).
        // An optional model override replaces the model in memory only, keeping the
        // endpoint and provider reference; settings.json is never written.
        var manifest = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: settingsPath))
        )
        let modelOverride = env["ZENCODE_AB_EMBEDDING_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let modelOverride, !modelOverride.isEmpty {
            let current = try #require(manifest.memoryEmbedding, "settings.json has no memoryEmbedding to override")
            let endpoint = try #require(current.endpoint, "memoryEmbedding is disabled: no endpoint to keep")
            manifest = try ZenCODESetupRunner.manifestByUpdatingMemoryEmbedding(
                manifest,
                endpoint: endpoint,
                model: modelOverride,
                providerID: current.providerID
            )
        }
        let upstream = try #require(MemoryEmbedding.provider(manifest: manifest, environment: [:]))
        let modelID = upstream.modelID

        // Optional lever measurement: the relation cap alone, on the copy, before
        // anything is embedded. Nothing else of the cleanup runs.
        var prunedRelationEdges: Int?
        var relationEdgesBefore = 0
        if env["ZENCODE_AB_PRUNE_RELATIONS"] == "1" {
            relationEdgesBefore = loadedGraph.edges.values.joined().filter { $0.kind.relationWeight != nil }.count
            prunedRelationEdges = loadedGraph.pruneRelations(
                maximumPerMemory: MemoryRelationPolicy.default.maximumLinksPerMemory
            )
        }

        // Archived entries keep no vector (product decision); retrieval only reads
        // active entries, so clearing them on the copy changes nothing but fidelity.
        var archivedVectorsCleared = 0
        for id in loadedGraph.memories.keys where loadedGraph.memories[id]?.active == false {
            if loadedGraph.memories[id]?.embedding != nil { archivedVectorsCleared += 1 }
            loadedGraph.memories[id]?.setEmbedding(nil, model: nil)
        }

        // Active entries without a vector from this model are re-embedded on the
        // in-memory copy with the production text, straight through the upstream
        // provider so the memoizing query counter stays clean.
        let reembedJobs = loadedGraph.memories.values
            .filter { $0.active && !$0.embeddingMatches(model: modelID) }
            .sorted { $0.id < $1.id }
            .map { ReembedJob(id: $0.id, text: MemoryContent.normalized($0.content)) }
        let reembedResults = await Self.reembed(reembedJobs, with: upstream, maxConcurrent: 4)
        // Production holds every vector at the stored precision. The binary16
        // comparison needs the provider's binary32 values as its baseline, so
        // only then are the new vectors kept at full precision (in memory only:
        // the copy is never saved).
        let keepsFullPrecision = env["ZENCODE_AB_COMPARE_FLOAT16"] == "1"
        var reembedLatencies: [Double] = []
        var reembedFailures: [String] = []
        var reembedRetried = 0
        for result in reembedResults {
            if let values = result.values {
                if keepsFullPrecision {
                    loadedGraph.memories[result.id]?.setEmbeddingWithoutRounding(values, model: modelID)
                } else {
                    loadedGraph.memories[result.id]?.setEmbedding(values, model: modelID)
                }
                reembedLatencies.append(result.milliseconds)
                if result.attempts > 1 { reembedRetried += 1 }
            } else {
                reembedFailures.append("\(Self.prefix8(result.id)): \(result.error ?? "unknown error")")
            }
        }
        reembedFailures.sort()
        let graph = loadedGraph
        let compareFloat16 = keepsFullPrecision
        // Same vectors, each component rounded to the nearest binary16 value.
        let float16Graph = compareFloat16 ? Self.roundedToFloat16(graph) : nil

        let embedder = MemoizingEmbeddingProvider(upstream: upstream)
        let recorder = FailureRecorder()

        func makeEngine(_ configuration: MemoryEngineConfiguration, graph: MemoryGraph) -> MemoryEngine {
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
        let entryVectorLengths = Dictionary(
            grouping: entries.filter { $0.active && $0.embeddingMatches(model: embedder.modelID) }.compactMap(\.embedding),
            by: \.count
        ).mapValues(\.count)
        // The one query embedded here is cached: it is not requested again below.
        let queryVectorLength = try await embedder.embed(Self.queries[0].text).count
        let clock = ContinuousClock()

        var report = "# Memory retrieval A/B v2\n\n"
        report += "- graph: \(entries.count) entries, \(activeCount) active, \(vectorCount) active with a vector from `\(embedder.modelID)`; excluded prefixes: \(excludedPrefixes.sorted().joined(separator: ", "))\n"
        if let prunedRelationEdges {
            report += "- relation pruning (ZENCODE_AB_PRUNE_RELATIONS=1): \(prunedRelationEdges) relatesTo edges removed from the copy (cap \(MemoryRelationPolicy.default.maximumLinksPerMemory) per entry; relatesTo edges \(relationEdgesBefore) → \(relationEdgesBefore - prunedRelationEdges)); the source graph is untouched\n"
        } else {
            report += "- relation pruning: off (set ZENCODE_AB_PRUNE_RELATIONS=1 to apply the 12-per-entry cap to the copy)\n"
        }
        report += "- A = BM25 + graph cascade (no embedder); Bn = BM25 + semantic, see variants; automatic-recall configuration, scope .all, read-only `retrieveAndSelect`\n"
        report += "- metrics: MRR over the ranked candidates, recall@5 = |relevant ∩ top-5| / min(5, |relevant|), hit@1, misses = queries with no relevant entry in the top-5, exact-regressions = lexically exact queries whose relevant top-1 was displaced, Jaccard = top-5 overlap with A\n\n"

        var reembedSection = "## Embedding model and re-embedding\n\n"
        let lengthText = entryVectorLengths.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value) entries)" }.joined(separator: ", ")
        reembedSection += "- effective model: `\(modelID)`\(modelOverride?.isEmpty == false ? " (override via ZENCODE_AB_EMBEDDING_MODEL)" : " (from settings.json)")\n"
        reembedSection += "- vector length observed: entries \(lengthText.isEmpty ? "none" : lengthText); queries \(queryVectorLength)\n"
        reembedSection += "- re-embedded entries: \(reembedLatencies.count) of \(reembedJobs.count) needed (retried once: \(reembedRetried)); failed: \(reembedFailures.count)\n"
        reembedSection += "- re-embedding latency ms: median \(Self.fmt(Self.median(reembedLatencies))), max \(Self.fmt(reembedLatencies.max() ?? 0)) (successful requests, up to 4 in flight)\n"
        reembedSection += "- archived vectors cleared: \(archivedVectorsCleared)\n"
        for failure in reembedFailures { reembedSection += "  - re-embedding failure \(failure)\n" }
        reembedSection += "\n"
        report += reembedSection
        print(reembedSection)

        // A and every variant over one graph, through the production pipeline.
        // Query vectors come from the memoizing provider, so evaluating a second
        // graph reuses exactly the same query embeddings and sends no request.
        func evaluate(_ graph: MemoryGraph) async throws -> Evaluation {
            var evaluation = Evaluation()
            // A: lexical only, once per query.
            let baselineEngine = makeEngine(MemoryEngineConfiguration(), graph: graph)
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
                evaluation.lexicalOutcomes.append(outcome)
                Self.score(outcome, query: query, lexicalTop: outcome.topIDs, into: &evaluation.lexical)
            }

            for variant in Self.variants {
                let engine = makeEngine(variant.configuration, graph: graph)
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
                    Self.score(outcome, query: query, lexicalTop: evaluation.lexicalOutcomes[index].topIDs, into: &aggregate)
                }
                evaluation.variants.append((variant, aggregate, outcomes))
            }
            return evaluation
        }

        let evaluation = try await evaluate(graph)

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

        report += "## Aggregate over \(Self.queries.count) queries\n\n"
        report += Self.aggregateTable(evaluation)
        report += "\n"
        for (variant, aggregate, _) in evaluation.variants where !aggregate.exactRegressions.isEmpty {
            report += "- \(variant.name) displaced the exact lexical top-1 for: \(aggregate.exactRegressions.map { "“\($0)”" }.joined(separator: ", "))\n"
        }

        report += "\n## Per-query top-5 (✓ = relevant; `sel`=selected for injection, `sem`=semantic hits entering fusion)\n\n"
        for (index, query) in Self.queries.enumerated() {
            report += "### Q\(index + 1) [\(query.label)] “\(query.text)” — relevant: \(query.relevant.sorted().joined(separator: ", "))\n\n"
            for row in evaluation.rows {
                report += Self.row(row.name, row.outcomes[index], query: query)
            }
            report += "\n"
        }

        var float16Section = ""
        if let float16Graph {
            let float16 = try await evaluate(float16Graph)
            float16Section = Self.float16Comparison(
                float32: evaluation,
                float16: float16,
                float32Graph: graph,
                float16Graph: float16Graph
            )
            report += float16Section
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
        if !float16Section.isEmpty {
            print(float16Section)
        }
        #expect(failures.isEmpty)
        #expect(requestCount == Self.queries.count)
        // Retrieval silently skips vectors whose length differs from the query's.
        #expect(entryVectorLengths.keys.allSatisfy { $0 == queryVectorLength })
    }

    // MARK: - Helpers

    /// Copies the graph at `source` into `directory` under its own name, with
    /// its vectors file (`<graph>.vectors`, graph version 4) when there is one,
    /// and returns the copy's URL. Without the vectors file a version 4 copy
    /// would load with no vector at all.
    static func copyGraphFiles(from source: URL, into directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let copy = directory.appendingPathComponent(source.lastPathComponent)
        try fileManager.copyItem(at: source, to: copy)
        let sourceVectors = JSONMemoryPersistence.vectorsURL(forGraphAt: source)
        if fileManager.fileExists(atPath: sourceVectors.path) {
            try fileManager.copyItem(at: sourceVectors, to: JSONMemoryPersistence.vectorsURL(forGraphAt: copy))
        }
        return copy
    }

    private static func aggregateTable(_ evaluation: Evaluation) -> String {
        var table = "| variant | MRR | recall@5 | hit@1 | misses | exact-regr. | mean selected | Jaccard vs A |\n|---|---|---|---|---|---|---|---|\n"
        let lexical = evaluation.lexical
        table += "| A BM25 only | \(fmt(lexical.meanReciprocalRank)) | \(fmt(lexical.meanRecallAt5)) | \(lexical.hitAt1) | \(lexical.misses) | \(lexical.exactRegressions.count) | \(fmt(lexical.meanSelected)) | 1.00 |\n"
        for (variant, aggregate, _) in evaluation.variants {
            table += "| \(variant.name) | \(fmt(aggregate.meanReciprocalRank)) | \(fmt(aggregate.meanRecallAt5)) | \(aggregate.hitAt1) | \(aggregate.misses) | \(aggregate.exactRegressions.count) | \(fmt(aggregate.meanSelected)) | \(fmt(aggregate.meanJaccard)) |\n"
        }
        return table
    }

    private static func top5(_ outcome: QueryOutcome, query: Query) -> String {
        outcome.topIDs.prefix(5).map { id -> String in
            isRelevant(id, for: query) ? "✓\(prefix8(id))" : " \(prefix8(id))"
        }.joined(separator: "  ")
    }

    private static func row(_ name: String, _ outcome: QueryOutcome, query: Query) -> String {
        "- \(name.padding(toLength: 30, withPad: " ", startingAt: 0)) sel=\(outcome.selectedCount) sem=\(outcome.semanticHitCount) · \(top5(outcome, query: query))\n"
    }

    /// `graph` with every vector component rounded to the nearest binary16
    /// value, everything else unchanged.
    private static func roundedToFloat16(_ graph: MemoryGraph) -> MemoryGraph {
        var rounded = graph
        for (id, entry) in graph.memories {
            guard let embedding = entry.embedding else { continue }
            rounded.memories[id]?.setEmbedding(HalfPrecision.rounded(embedding), model: entry.embeddingModel)
        }
        return rounded
    }

    /// Rows checked by the storage-precision acceptance criterion.
    private static let float16CriterionRows = [
        "A BM25 only", "R25 norm robust z2.5 (chosen)", "R3 norm robust z3", "D  engine defaults",
    ]

    /// Both aggregate tables, the per-query rows whose top-5 differs, the
    /// acceptance criterion per checked row and the vector rounding error.
    private static func float16Comparison(
        float32: Evaluation,
        float16: Evaluation,
        float32Graph: MemoryGraph,
        float16Graph: MemoryGraph
    ) -> String {
        var section = "## Float16 comparison (ZENCODE_AB_COMPARE_FLOAT16=1)\n\n"

        var vectorCount = 0
        var componentCount = 0
        var changedComponents = 0
        var fullPrecisionVectors = 0
        var maximumError: Float = 0
        var cosines: [Double] = []
        for (id, entry) in float32Graph.memories {
            guard let wide = entry.embedding, let narrow = float16Graph.memories[id]?.embedding else { continue }
            vectorCount += 1
            componentCount += wide.count
            let changed = zip(wide, narrow).filter { $0.bitPattern != $1.bitPattern }.count
            changedComponents += changed
            if changed > 0 { fullPrecisionVectors += 1 }
            maximumError = max(maximumError, zip(wide, narrow).map { abs($0 - $1) }.max() ?? 0)
            var dot = 0.0, wideNorm = 0.0, narrowNorm = 0.0
            for (a, b) in zip(wide, narrow) {
                dot += Double(a) * Double(b)
                wideNorm += Double(a) * Double(a)
                narrowNorm += Double(b) * Double(b)
            }
            if wideNorm > 0, narrowNorm > 0 { cosines.append(dot / (wideNorm.squareRoot() * narrowNorm.squareRoot())) }
        }
        section += "- vectors: \(vectorCount) (\(fullPrecisionVectors) not already binary16-exact); components changed by rounding: \(changedComponents) of \(componentCount); max absolute error \(maximumError)\n"
        section += "- 1 − cosine(binary32, binary16) per vector: max \(String(format: "%.3e", 1 - (cosines.min() ?? 1))), mean \(String(format: "%.3e", cosines.isEmpty ? 0 : 1 - cosines.reduce(0, +) / Double(cosines.count)))\n"
        section += "- same query embeddings for both graphs (memoizing provider); only the stored vectors differ\n\n"

        section += "### Aggregate, binary32 vectors\n\n" + aggregateTable(float32) + "\n"
        section += "### Aggregate, binary16 vectors\n\n" + aggregateTable(float16) + "\n"

        var changedRows: [String] = []
        var totalRows = 0
        for (wideRow, narrowRow) in zip(float32.rows, float16.rows) {
            for (index, query) in queries.enumerated() {
                totalRows += 1
                let wide = Array(wideRow.outcomes[index].topIDs.prefix(5))
                let narrow = Array(narrowRow.outcomes[index].topIDs.prefix(5))
                guard wide != narrow else { continue }
                changedRows.append("  - Q\(index + 1) \(wideRow.name): \(top5(wideRow.outcomes[index], query: query)) → \(top5(narrowRow.outcomes[index], query: query))")
            }
        }
        section += "- per-query rows whose top-5 changed: \(changedRows.count) of \(totalRows)\n"
        for row in changedRows { section += row + "\n" }
        section += "\n### Criterion (no extra miss, no extra exact regression, MRR and recall@5 down by at most 0.01)\n\n"
        var passes = true
        for name in float16CriterionRows {
            guard let wide = float32.rows.first(where: { $0.name == name })?.aggregate,
                  let narrow = float16.rows.first(where: { $0.name == name })?.aggregate else {
                section += "- \(name): row missing\n"
                passes = false
                continue
            }
            let rowPasses = narrow.misses <= wide.misses
                && narrow.exactRegressions.count <= wide.exactRegressions.count
                && narrow.meanReciprocalRank >= wide.meanReciprocalRank - 0.01
                && narrow.meanRecallAt5 >= wide.meanRecallAt5 - 0.01
            passes = passes && rowPasses
            section += "- \(name): misses \(wide.misses) → \(narrow.misses), exact-regr. \(wide.exactRegressions.count) → \(narrow.exactRegressions.count), MRR \(String(format: "%.4f", wide.meanReciprocalRank)) → \(String(format: "%.4f", narrow.meanReciprocalRank)), recall@5 \(String(format: "%.4f", wide.meanRecallAt5)) → \(String(format: "%.4f", narrow.meanRecallAt5)): \(rowPasses ? "pass" : "FAIL")\n"
        }
        section += "\nResult: \(passes ? "binary16 PASSES" : "binary16 FAILS") the criterion\n"
        return section
    }

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
