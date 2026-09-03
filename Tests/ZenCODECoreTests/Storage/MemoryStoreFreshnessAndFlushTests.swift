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

private struct CancellingReloadPersistence: MemoryReadOnlyReloadPersistence {
    func load() async throws -> MemoryGraph { MemoryGraph() }
    func reloadReadOnly() async throws -> MemoryGraph {
        try await Task.sleep(for: .seconds(30))
        return MemoryGraph()
    }
    func save(_ graph: MemoryGraph) async throws {}
    func transaction<T: Sendable>(
        initialGraph: MemoryGraph?,
        _ body: @Sendable (inout MemoryGraph) throws -> T
    ) async throws -> (result: T, graph: MemoryGraph, didChange: Bool) {
        fatalError("unused")
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
    func freshReadsRemainPurePreserveModeAndPendingMaintenance() async throws {
        try await MemoryEmbedding.withProvider(nil) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("memory-freshness-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("memory.graph.json")
            let writer = try await MemoryEngine.open(persistence: JSONMemoryPersistence(url: file))
            try await writer.remember("writers isolate mutable state", id: "writer")
            let reader = try await MemoryEngine.open(persistence: JSONMemoryPersistence(url: file))
            let store = MemoryGraphStore(graphURL: file, engine: reader, embedder: nil)
            _ = try await reader.recall("writers isolate")
            try await writer.remember("reader fact committed later", id: "later")

            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
            let beforeAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let bytesBefore = try Data(contentsOf: file)
            let snapshotBefore = await reader.snapshot()

            _ = try await store.entries(includeArchived: false, limit: 50)
            _ = try await store.search(query: "reader fact", includeArchived: false, limit: 10)

            let afterAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect(try Data(contentsOf: file) == bytesBefore)
            #expect(afterAttributes[.posixPermissions] as? NSNumber == beforeAttributes[.posixPermissions] as? NSNumber)
            #expect(afterAttributes[.modificationDate] as? Date == beforeAttributes[.modificationDate] as? Date)
            #expect(await reader.snapshot() == snapshotBefore)

            try await reader.flushRecallMaintenance()
            let durable = try await JSONMemoryPersistence(url: file).reloadReadOnly()
            #expect(durable.metadata.retrievalCount == snapshotBefore.metadata.retrievalCount)
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

    @Test
    func taskCancellationIsNotHiddenByLocalFallback() async throws {
        let engine = MemoryEngine(graph: MemoryGraph(), persistence: CancellingReloadPersistence())
        let store = MemoryGraphStore(graphURL: URL(fileURLWithPath: "/unused"), engine: engine, embedder: nil)
        let read = Task { try await store.entry(id: "anything") }
        read.cancel()
        await #expect(throws: CancellationError.self) { _ = try await read.value }
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
            let store = try await registry.store(forWorkspaceRoot: workspace, graphURL: graphURL)
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
    func migrationACommitBFlushADoesNotOverwriteCommitB() async throws {
        try await MemoryEmbedding.withProvider(nil) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("memory-migration-race-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let legacyID = UUID().uuidString
            let canonicalLegacyID = MemoryIdentifier.canonical(try #require(UUID(uuidString: legacyID)))
            try "# MEMORY.md\n\n## Active\n\n- [id: \(legacyID)] Summary: lazy migration A.\n"
                .write(to: workspace.appendingPathComponent(MemoryService.filename), atomically: true, encoding: .utf8)
            let graphURL = directory.appendingPathComponent("memory.graph.json")
            let registry = MemoryGraphStoreRegistry()
            let store = try await registry.store(forWorkspaceRoot: workspace, graphURL: graphURL)
            // Exercise A's automatic recall path once, below the default
            // checkpoint threshold, so flushAll sees pending maintenance while
            // the lazy migration still needs its own explicit durability boundary.
            let recalledContext = try await store.context(for: "lazy migration A")
            #expect(recalledContext.contains("lazy migration A"))

            let writerB = try await MemoryEngine.open(persistence: JSONMemoryPersistence(url: graphURL))
            try await writerB.remember("commit B survives lifecycle flush", id: "commit-b")
            let bytesAfterB = try Data(contentsOf: graphURL)
            try await registry.flushAll()

            #expect(try Data(contentsOf: graphURL) == bytesAfterB)
            let durable = try await JSONMemoryPersistence(url: graphURL).reloadReadOnly()
            #expect(durable.memories["commit-b"] != nil)
            #expect(durable.memories[canonicalLegacyID] == nil)
            #expect(try await store.entries(includeArchived: false, limit: 10).contains {
                $0.id == canonicalLegacyID
            })
        }
    }

    @Test
    func flushAllAttemptsEveryStoreAndRethrowsDeterministicFailure() async throws {
        try await MemoryEmbedding.withProvider(nil) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("memory-flush-error-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let registry = MemoryGraphStoreRegistry()
            var stores: [(URL, MemoryGraphStore)] = []
            for name in ["broken", "healthy"] {
                let workspace = directory.appendingPathComponent(name, isDirectory: true)
                let graphURL = directory.appendingPathComponent("\(name).json")
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                var graph = MemoryGraph()
                graph.addMemory(EngineMemoryEntry(id: name, category: .fact, content: "\(name) flush target"))
                try await JSONMemoryPersistence(url: graphURL).save(graph)
                stores.append((graphURL, try await registry.store(forWorkspaceRoot: workspace, graphURL: graphURL)))
            }
            _ = try await stores[0].1.context(for: "broken flush")
            _ = try await stores[1].1.context(for: "healthy flush")
            let brokenBytes = Data("{\"graph_version\":999999}".utf8)
            try brokenBytes.write(to: stores[0].0, options: .atomic)

            await #expect(throws: MemoryPersistenceError.unsupportedGraphVersion(999999)) {
                try await registry.flushAll()
            }
            #expect(try Data(contentsOf: stores[0].0) == brokenBytes)
            #expect(try await JSONMemoryPersistence(url: stores[1].0).reloadReadOnly().metadata.retrievalCount > 0)
        }
    }
}

@Suite(.serialized)
struct MemoryFlushLifecycleCleanupTests {
    @Test
    func shutdownCompletesPreexistingCleanupBeforeSurfacingMemoryError() async throws {
        try await MemoryEmbedding.withProvider(nil) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("memory-lifecycle-error-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
            let graphURL = directory.appendingPathComponent("memory.graph.json")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            var graph = MemoryGraph()
            graph.addMemory(EngineMemoryEntry(id: "seed", category: .fact, content: "lifecycle flush target"))
            try await JSONMemoryPersistence(url: graphURL).save(graph)

            let registry = MemoryGraphStoreRegistry()
            let store = try await registry.store(forWorkspaceRoot: workspace, graphURL: graphURL)
            _ = try await store.context(for: "lifecycle flush")
            try Data("{\"graph_version\":999999}".utf8).write(to: graphURL, options: .atomic)

            let runner = AgentCoreSessionRunner(
                taskGraphStore: nil,
                sessionTurnLease: AgentSessionTurnLease(),
                memoryGraphStoreRegistry: registry
            )
            let orchestrator = await runner.taskOrchestrator
            let stream = await orchestrator.events(sessionID: "cleanup-observer")
            var iterator = stream.makeAsyncIterator()

            await #expect(throws: MemoryPersistenceError.unsupportedGraphVersion(999999)) {
                try await runner.shutdownBackendKeepingExternalToolsThrowing()
            }
            // This occurs after task flush in the pre-existing teardown. If the
            // memory error escaped early, the continuation would remain open and
            // this await would hang rather than immediately return nil.
            #expect(await iterator.next() == nil)
        }
    }
}
