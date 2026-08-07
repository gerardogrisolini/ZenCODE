import Foundation
import Testing
@testable import ZenMemory

@Test func categoryCodableRoundTrip() throws {
    let values: [MemoryCategory] = [.fact, .preference, .entity, .correction, .custom("procedure")]
    let data = try JSONEncoder().encode(values)
    let decoded = try JSONDecoder().decode([MemoryCategory].self, from: data)
    #expect(decoded == values)
}

@Test func confidenceDecaysByCategory() {
    let oldDate = Date().addingTimeInterval(-30 * 86_400)
    let entry = MemoryEntry(category: .fact, content: "old fact", createdAt: oldDate)
    let confidence = entry.effectiveConfidence()
    #expect(confidence > 0.45)
    #expect(confidence < 0.6)
}

@Test func cascadeTraversesSharedTag() {
    var graph = MemoryGraph()
    let a = MemoryEntry(id: "a", category: .fact, content: "Swift package", tags: ["swift"])
    let b = MemoryEntry(id: "b", category: .fact, content: "Swift actors", tags: ["swift"])
    graph.addMemory(a)
    graph.addMemory(b)

    let result = graph.cascadeRetrieve(
        seeds: [ScoredMemoryID(id: "a", score: 1)],
        maxDepth: 2,
        maxResults: 10
    )

    #expect(result.contains(where: { $0.id == "a" }))
    #expect(result.contains(where: { $0.id == "b" }))
}

@Test func semanticSearchDoesNotMixEmbeddingModels() {
    var graph = MemoryGraph()
    var a = MemoryEntry(id: "a", category: .fact, content: "A")
    a.setEmbedding([1, 0], model: "model-a")
    var b = MemoryEntry(id: "b", category: .fact, content: "B")
    b.setEmbedding([1, 0], model: "model-b")
    graph.addMemory(a)
    graph.addMemory(b)

    let result = MemorySearch.semantic(
        graph: graph,
        queryEmbedding: [1, 0],
        modelID: "model-a",
        threshold: 0,
        limit: 10
    )

    #expect(result.map(\.id) == ["a"])
}

@Test func lexicalSearchFindsEmbeddingMismatch() {
    var graph = MemoryGraph()
    var memory = MemoryEntry(id: "mismatch", category: .fact, content: "Linux Swift server memory")
    memory.setEmbedding([1, 0], model: "old-model")
    graph.addMemory(memory)

    let semantic = MemorySearch.semantic(
        graph: graph,
        queryEmbedding: [1, 0],
        modelID: "new-model",
        threshold: 0,
        limit: 10
    )
    let lexical = MemorySearch.lexicalBM25(graph: graph, query: "Swift Linux", limit: 10)

    #expect(semantic.isEmpty)
    #expect(lexical.first?.id == "mismatch")
}

@Test func jsonPersistenceRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = directory.appendingPathComponent("graph.json")
    let persistence = JSONMemoryPersistence(url: file)

    var graph = MemoryGraph()
    graph.addMemory(MemoryEntry(id: "a", category: .preference, content: "Use Swift", tags: ["swift"]))
    try await persistence.save(graph)
    let loaded = try await persistence.load()

    #expect(loaded.memories["a"]?.content == "Use Swift")
    #expect(loaded.tags["tag:swift"]?.count == 1)
    #expect(loaded.incomingNodes(to: "tag:swift").contains("a"))
}

@Test func highLevelRecallAndPendingPipeline() async throws {
    let embedder = DeterministicHashEmbeddingProvider(dimensions: 64)
    var config = ZenMemoryConfiguration()
    config.similarityThreshold = 0
    config.maxResults = 5
    let memory = ZenMemory(embedder: embedder, configuration: config)

    _ = try await memory.remember("Swift actors protect mutable state", tags: ["swift", "actors"])
    _ = try await memory.remember("Linux is a supported deployment target", tags: ["linux"])

    let direct = try await memory.recall("Swift actors")
    #expect(direct.contains(where: { $0.memory.content.contains("actors") }))

    await memory.submitContext("Swift actors")
    await memory.waitForBackgroundTasks()
    let pending = await memory.takePending()
    #expect(!pending.isEmpty)
}

@Test func decodesSnakeCaseGraphJSON() async throws {
    let json = #"""
    {
      "graph_version": 2,
      "memories": {
        "mem_1": {
          "id": "mem_1",
          "category": "fact",
          "content": "Swift runs on Linux",
          "tags": ["swift", "linux"],
          "search_text": "swift runs on linux swift linux",
          "created_at": "2026-08-07T12:00:00Z",
          "updated_at": "2026-08-07T12:00:00Z",
          "access_count": 0,
          "trust": "high",
          "strength": 1,
          "active": true,
          "embedding": [1.0, 0.0],
          "embedding_model": "example-embedding-v1",
          "confidence": 1.0
        }
      },
      "tags": {
        "tag:swift": {
          "id": "tag:swift",
          "name": "swift",
          "count": 1,
          "created_at": "2026-08-07T12:00:00Z"
        }
      },
      "clusters": {},
      "edges": {
        "mem_1": [{"target":"tag:swift","kind":"has_tag"}]
      },
      "reverse_edges": {"tag:swift":["mem_1"]},
      "metadata": {"retrieval_count":0,"link_discovery_count":0}
    }
    """#

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = directory.appendingPathComponent("zen-memory-graph.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: file)

    let persistence = JSONMemoryPersistence(url: file)
    let graph = try await persistence.load()
    #expect(graph.graphVersion == 2)
    #expect(graph.memories["mem_1"]?.scope == .project)
    #expect(graph.outgoingEdges(from: "mem_1").first?.kind == .hasTag)
}

@Test func lexicalOnlyWorksWithoutEmbedder() async throws {
    let memory = ZenMemory()
    _ = try await memory.remember("Use actors for shared mutable state", tags: ["swift", "concurrency"])
    _ = try await memory.remember("Database migrations run at application startup", tags: ["database"])

    let results = try await memory.recall("Swift actors concurrency")
    #expect(results.first?.memory.content.contains("actors") == true)
    let stored = await memory.snapshot().memories.values.first { $0.content.contains("actors") }
    #expect(stored?.embedding == nil)
}

private struct FixedQueryAnalyzer: MemoryQueryAnalyzer {
    let plan: MemoryQueryPlan
    func analyze(_ prompt: String) async throws -> MemoryQueryPlan { plan }
}

private struct IDSelector: MemorySelector {
    let ids: [String]

    func select(
        context: String,
        candidates: [MemoryCandidate],
        limit: Int
    ) async throws -> [MemoryCandidate] {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.memory.id, $0) })
        return ids.prefix(limit).compactMap { byID[$0] }
    }
}

private struct FixedExtractor: MemoryExtractor {
    let drafts: [MemoryDraft]
    func extract(from context: String) async throws -> [MemoryDraft] { drafts }
}

private actor QueuedLanguageModel: MemoryLanguageModel {
    private var responses: [String]

    init(_ responses: [String]) {
        self.responses = responses
    }

    func complete(system: String, user: String) async throws -> String {
        guard !responses.isEmpty else { return "{}" }
        return responses.removeFirst()
    }
}

@Test func analyzerCanSkipRecall() async throws {
    let memory = ZenMemory(
        queryAnalyzer: FixedQueryAnalyzer(
            plan: MemoryQueryPlan(shouldRecall: false)
        )
    )
    _ = try await memory.remember("A memory that would otherwise match", tags: ["memory"])

    let result = try await memory.recallDetailed("memory")
    #expect(result.plan.shouldRecall == false)
    #expect(result.candidates.isEmpty)
    #expect(result.selected.isEmpty)
}

@Test func analyzedQueriesFindLexicallyDistantMemory() async throws {
    let analyzer = FixedQueryAnalyzer(
        plan: MemoryQueryPlan(
            shouldRecall: true,
            queries: ["database persistence memory"],
            tags: ["storage"],
            entities: ["GRDB"],
            intent: "recall storage decision"
        )
    )
    let memory = ZenMemory(queryAnalyzer: analyzer)
    _ = try await memory.remember(
        "GRDB is the selected persistence layer",
        tags: ["storage", "database"]
    )

    let result = try await memory.recallDetailed("What did we choose to save agent state?")
    #expect(result.selected.first?.memory.content.contains("GRDB") == true)
}

@Test func selectorControlsContextInjection() async throws {
    let analyzer = FixedQueryAnalyzer(
        plan: MemoryQueryPlan(shouldRecall: true, queries: ["swift database"])
    )
    let memory = ZenMemory(
        queryAnalyzer: analyzer,
        selector: IDSelector(ids: ["db"])
    )
    _ = try await memory.remember("Swift actors manage shared state", tags: ["swift"], id: "actors")
    _ = try await memory.remember("SQLite stores durable agent memory", tags: ["database"], id: "db")

    let context = try await memory.context(for: "How is memory stored?")
    #expect(context.contains("SQLite"))
    #expect(!context.contains("actors"))
}

@Test func learnUsesConfiguredExtractor() async throws {
    let extractor = FixedExtractor(
        drafts: [
            MemoryDraft(
                content: "The project uses PostgreSQL in production",
                category: .fact,
                tags: ["database", "production"],
                trust: .high
            )
        ]
    )
    let memory = ZenMemory(extractor: extractor)
    let stored = try await memory.learn(from: "conversation text")

    #expect(stored.count == 1)
    #expect(stored[0].tags.contains("database"))
    let recalled = try await memory.recall("PostgreSQL production")
    #expect(recalled.first?.memory.content.contains("PostgreSQL") == true)
}

@Test func llmAnalyzerParsesJSONWithoutEmbeddings() async throws {
    let model = QueuedLanguageModel([
        #"{"shouldRecall":true,"queries":["deployment operating system","Ubuntu production"],"tags":["deployment"],"entities":["Ubuntu"],"intent":"recall deployment platform"}"#
    ])
    let analyzer = LLMMemoryQueryAnalyzer(model: model)
    let plan = try await analyzer.analyze("Which OS should we deploy to?")

    #expect(plan.shouldRecall)
    #expect(plan.queries.contains("Ubuntu production"))
    #expect(plan.entities == ["Ubuntu"])
}

@Test func llmSelectorUsesOnlyReturnedCandidateIDs() async throws {
    let model = QueuedLanguageModel([
        #"{"selected":["b","invented"]}"#
    ])
    let selector = LLMMemorySelector(model: model)
    let a = MemoryCandidate(memory: MemoryEntry(id: "a", category: .fact, content: "A"), score: 0.9)
    let b = MemoryCandidate(memory: MemoryEntry(id: "b", category: .fact, content: "B"), score: 0.8)

    let selected = try await selector.select(context: "test", candidates: [a, b], limit: 3)
    #expect(selected.map(\.memory.id) == ["b"])
}

@Test func llmExtractorProducesMemoryDrafts() async throws {
    let model = QueuedLanguageModel([
        #"{"memories":[{"content":"Prefer actors for shared state","category":"preference","tags":["swift","concurrency"],"trust":"high","confidence":0.9}]}"#
    ])
    let extractor = LLMMemoryExtractor(model: model, defaultScope: .global)
    let drafts = try await extractor.extract(from: "User says they prefer actors")

    #expect(drafts.count == 1)
    #expect(drafts[0].category == .preference)
    #expect(drafts[0].scope == .global)
    #expect(drafts[0].confidence == 0.9)
}
