//
//  MemoryStoreFreshnessAndFlushTests.swift
//  ZenCODECoreTests
//

import Foundation
@testable import ZenCODECore
import Testing

private struct FailingReloadPersistence: MemoryReadOnlyReloadPersistence {
    struct LoadFailed: Error {}
    struct Unavailable: Error {}

    func load() async throws -> MemoryGraph { MemoryGraph() }
    func reloadReadOnly() async throws -> MemoryGraph { throw LoadFailed() }
    func save(_ graph: MemoryGraph) async throws {}
    func transaction<T: Sendable>(
        initialGraph: MemoryGraph?,
        _ body: @Sendable (inout MemoryGraph) throws -> T
    ) async throws -> (result: T, graph: MemoryGraph, didChange: Bool) {
        throw Unavailable()
    }
}

@Suite
struct MemoryStoreFreshnessTests {
    @Test
    func entriesSearchAndEntryObserveAnotherEnginesCommittedGraph() async throws {
        try await MemoryEmbedding.withProvider(nil) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("memory-freshness-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("memory.graph.json")

            let writer = try await MemoryEngine.open(persistence: JSONMemoryPersistence(url: file))
            try await writer.remember("writers isolate mutable state", id: "writer")
            let reader = try await MemoryEngine.open(persistence: JSONMemoryPersistence(url: file))
            let store = MemoryGraphStore(graphURL: file, engine: reader, embedder: nil)
            try await writer.remember("reader fact committed later", id: "later")

            let entries = try await store.entries(includeArchived: false, limit: 50)
            #expect(Set(entries.map(\.id)) == ["writer", "later"])
            #expect(try await store.entry(id: "later")?.content == "reader fact committed later")
            let hits = try await store.search(query: "reader fact", includeArchived: false, limit: 10)
            #expect(hits.contains { $0.id == "later" })
        }
    }

    @Test
    func ordinaryReloadFailureFallsBackToLocalGraph() async throws {
        var seeded = MemoryGraph()
        seeded.addMemory(EngineMemoryEntry(id: "local", category: .fact, content: "local fact survives"))
        let cleanEngine = MemoryEngine(graph: seeded, persistence: FailingReloadPersistence())
        let store = MemoryGraphStore(graphURL: URL(fileURLWithPath: "/unused"), engine: cleanEngine, embedder: nil)
        #expect(try await store.entries(includeArchived: false, limit: 10).map(\.id) == ["local"])
    }

    @Test
    func futureVersionIsNotHiddenByLocalFallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-future-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        let persistence = JSONMemoryPersistence(url: file)
        try await persistence.save(MemoryGraph())
        let engine = try await MemoryEngine.open(persistence: persistence)
        let store = MemoryGraphStore(graphURL: file, engine: engine, embedder: nil)
        try "{\"graph_version\":999999}".write(to: file, atomically: true, encoding: .utf8)

        await #expect(throws: MemoryPersistenceError.unsupportedGraphVersion(999999)) {
            _ = try await store.entries(includeArchived: false, limit: 10)
        }
    }
}

@Suite
struct MemoryGraphStoreRegistryFlushAllTests {
    @Test
    func flushAllPersistsOnlyPendingMaintenanceAndIsIdempotent() async throws {
        try await MemoryEmbedding.withProvider(nil) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("memory-flush-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
            let graphURL = directory.appendingPathComponent("memory.graph.json")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            var graph = MemoryGraph()
            graph.addMemory(EngineMemoryEntry(id: "seed", category: .fact, content: "flush durability boundary"))
            try await JSONMemoryPersistence(url: graphURL).save(graph)

            let registry = MemoryGraphStoreRegistry()
            let store = try await registry.store(graphURL: graphURL)
            _ = try await store.context(for: "flush durability")
            #expect(try await JSONMemoryPersistence(url: graphURL).reloadReadOnly().metadata.retrievalCount == 0)
            try await registry.flushAll()
            #expect(try await JSONMemoryPersistence(url: graphURL).reloadReadOnly().metadata.retrievalCount > 0)
            let bytes = try Data(contentsOf: graphURL)
            try await registry.flushAll()
            #expect(try Data(contentsOf: graphURL) == bytes)
        }
    }

    @Test
    func deferredInsertACommitBFlushADoesNotOverwriteCommitB() async throws {
        try await MemoryEmbedding.withProvider(nil) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("memory-deferred-insert-race-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let deferredID = UUID().uuidString
            let graphURL = directory.appendingPathComponent("memory.graph.json")
            let engine = MemoryEngine(persistence: JSONMemoryPersistence(url: graphURL))
            try await engine.insert(
                EngineMemoryEntry(id: deferredID, category: .fact, content: "deferred insert A"),
                persist: false
            )
            let store = MemoryGraphStore(graphURL: graphURL, engine: engine, embedder: nil)
            // Deferred engine inserts still require their own durability boundary;
            // flushing recall maintenance must not persist unrelated local state.
            let recalledContext = try await store.context(for: "deferred insert A")
            #expect(recalledContext.contains("deferred insert A"))

            let writerB = try await MemoryEngine.open(persistence: JSONMemoryPersistence(url: graphURL))
            try await writerB.remember("commit B survives lifecycle flush", id: "commit-b")
            let bytesAfterB = try Data(contentsOf: graphURL)
            try await store.flushRecallMaintenance()

            #expect(try Data(contentsOf: graphURL) == bytesAfterB)
            let durable = try await JSONMemoryPersistence(url: graphURL).reloadReadOnly()
            #expect(durable.memories["commit-b"] != nil)
            #expect(durable.memories[deferredID] == nil)
            #expect(try await store.entries(includeArchived: false, limit: 10).contains {
                $0.id == deferredID
            })
        }
    }
}
