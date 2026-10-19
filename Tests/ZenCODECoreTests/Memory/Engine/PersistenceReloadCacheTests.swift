import Foundation
import Testing
@testable import ZenCODECore

@Suite struct PersistenceReloadCacheTests {
    private static func graphJSON(id: String = "mem_1", content: String = "Swift runs on Linux") -> String {
        """
        {
          "graph_version": 2,
          "memories": {
            "\(id)": {
              "id": "\(id)",
              "category": "fact",
              "content": "\(content)",
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
            "\(id)": [{"target":"tag:swift","kind":"has_tag"}]
          },
          "reverse_edges": {"tag:swift":["\(id)"]},
          "metadata": {"retrieval_count":0,"link_discovery_count":0}
        }
        """
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func entry(_ id: String, _ content: String) -> EngineMemoryEntry {
        EngineMemoryEntry(id: id, category: .fact, content: content)
    }

    @Test func repeatedLoadsDecodeOnce() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("graph.json")
        try Data(Self.graphJSON().utf8).write(to: file)

        let persistence = JSONMemoryPersistence(url: file)
        let first = try await persistence.load()
        let second = try await persistence.load()
        let third = try await persistence.reloadReadOnly()
        #expect(await persistence.diskDecodeCount == 1)
        #expect(first == second)
        #expect(second == third)
    }

    @Test func missingFileYieldsEmptyGraphWithoutDecoding() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("absent.json")

        let persistence = JSONMemoryPersistence(url: file)
        let graph = try await persistence.load()
        #expect(graph.memories.isEmpty)
        #expect(await persistence.diskDecodeCount == 0)
    }

    @Test func atomicReplacementIsObserved() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("graph.json")
        try Data(Self.graphJSON().utf8).write(to: file)

        let persistence = JSONMemoryPersistence(url: file)
        let initial = try await persistence.load()
        #expect(initial.memories["mem_1"] != nil)
        #expect(await persistence.diskDecodeCount == 1)

        try Data(Self.graphJSON(id: "mem_2", content: "Different content").utf8)
            .write(to: file, options: .atomic)
        let reloaded = try await persistence.reloadReadOnly()
        #expect(await persistence.diskDecodeCount == 2)
        #expect(reloaded.memories["mem_2"]?.content == "Different content")
        #expect(reloaded.memories["mem_1"] == nil)

        _ = try await persistence.reloadReadOnly()
        #expect(await persistence.diskDecodeCount == 2)
    }

    @Test func inPlaceRewriteWithDifferentSizeIsObserved() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("graph.json")
        try Data(Self.graphJSON().utf8).write(to: file)

        let persistence = JSONMemoryPersistence(url: file)
        _ = try await persistence.load()
        #expect(await persistence.diskDecodeCount == 1)

        let rewritten = Data(
            Self.graphJSON(id: "mem_long", content: "A considerably longer piece of content than before").utf8
        )
        try rewritten.write(to: file)
        let reloaded = try await persistence.reloadReadOnly()
        #expect(await persistence.diskDecodeCount == 2)
        #expect(reloaded.memories["mem_long"] != nil)
        #expect(reloaded.memories["mem_1"] == nil)
    }

    @Test func deletingTheFileDropsTheCache() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("graph.json")
        try Data(Self.graphJSON().utf8).write(to: file)

        let persistence = JSONMemoryPersistence(url: file)
        _ = try await persistence.load()
        try FileManager.default.removeItem(at: file)

        let empty = try await persistence.reloadReadOnly()
        #expect(empty.memories.isEmpty)

        try Data(Self.graphJSON().utf8).write(to: file)
        let restored = try await persistence.load()
        #expect(await persistence.diskDecodeCount == 2)
        #expect(restored.memories["mem_1"] != nil)
    }

    @Test func saveReprimesTheCache() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("graph.json")
        try Data(Self.graphJSON().utf8).write(to: file)

        let persistence = JSONMemoryPersistence(url: file)
        var graph = try await persistence.load()
        #expect(await persistence.diskDecodeCount == 1)

        graph.addMemory(Self.entry("added", "Added after load"))
        try await persistence.save(graph)

        let reloaded = try await persistence.reloadReadOnly()
        #expect(reloaded.memories["added"] != nil)
        #expect(await persistence.diskDecodeCount == 1)

        let fresh = JSONMemoryPersistence(url: file)
        let fromDisk = try await fresh.load()
        #expect(await fresh.diskDecodeCount == 1)
        #expect(fromDisk == reloaded)
    }

    @Test func transactionObservesExternalChangeUnderLock() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("graph.json")
        try Data(Self.graphJSON().utf8).write(to: file)

        let a = JSONMemoryPersistence(url: file)
        let b = JSONMemoryPersistence(url: file)
        _ = try await a.load()
        #expect(await a.diskDecodeCount == 1)

        let external = Self.entry("from_b", "Written by B")
        _ = try await b.transaction { graph in
            graph.addMemory(external)
        }

        let outcome = try await a.transaction { graph in graph.memories.count }
        #expect(outcome.result == 2)
        #expect(outcome.graph.memories["from_b"] != nil)
        #expect(outcome.didChange == false)
        #expect(await a.diskDecodeCount == 2)
    }

    @Test func transactionDoesNotDecodeWhenUnchanged() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("graph.json")
        try Data(Self.graphJSON().utf8).write(to: file)

        let persistence = JSONMemoryPersistence(url: file)
        _ = try await persistence.load()
        #expect(await persistence.diskDecodeCount == 1)

        let outcome = try await persistence.transaction { graph in graph.memories.count }
        #expect(outcome.result == 1)
        #expect(outcome.didChange == false)
        #expect(await persistence.diskDecodeCount == 1)
    }
}
