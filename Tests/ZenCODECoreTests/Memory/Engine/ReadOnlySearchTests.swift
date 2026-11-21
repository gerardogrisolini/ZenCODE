//
//  ReadOnlySearchTests.swift
//  ZenCODECoreTests (memory engine)
//
//  Verifies the read-only search path of `memory.search` (a fresh read-only
//  snapshot searched with `searchReadOnlyDetailed(_:scope:graph:limit:)`): it
//  performs the same retrieval as `recallDetailed` but applies no maintenance
//  and never touches persistence, while recall keeps its transactional
//  maintenance.
//

import Foundation
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

// MARK: - Doubles

/// Records every save so a test can prove a read-only path never persisted.
private actor RecordingPersistence: MemoryPersistence {
    private(set) var saved: [MemoryGraph] = []

    func load() async throws -> MemoryGraph { MemoryGraph() }
    func save(_ graph: MemoryGraph) async throws { saved.append(graph) }
}

/// Always fails on save, proving a read-only path does not depend on save.
private struct AlwaysFailingPersistence: MemoryPersistence {
    struct SaveFailed: Error {}
    func load() async throws -> MemoryGraph { MemoryGraph() }
    func save(_ graph: MemoryGraph) async throws { throw SaveFailed() }
}

// MARK: - Tests

@Suite
struct ReadOnlySearchTests {

    @Test
    func searchReadOnlyAndRecallSelectSameEntries() async throws {
        let engine = MemoryEngine(persistence: RecordingPersistence())
        try await engine.remember("Swift actors isolate mutable state", tags: ["swift"])
        try await engine.remember("Database migrations run at startup", tags: ["database"])

        // The read-only search first: it does not mutate, so recall sees the
        // same graph and must select the same entries.
        let readOnly = try await engine.searchReadOnlyDetailed(
            "actors mutable state",
            scope: .all,
            graph: engine.freshSnapshotForReadOnly()
        ).selected
        let recalled = try await engine.recallDetailed("actors mutable state").selected

        let readOnlyContents = readOnly.map(\.memory.content)
        let recalledContents = recalled.map(\.memory.content)
        #expect(readOnlyContents == recalledContents)
    }

    @Test
    func searchReadOnlyDoesNotCreateLinks() async throws {
        let engine = MemoryEngine(persistence: RecordingPersistence())
        try await engine.remember("Swift actors isolate mutable state", tags: ["swift"])
        try await engine.remember("Swift structured concurrency guide", tags: ["swift"])

        let before = await engine.snapshot().edges
        _ = try await engine.searchReadOnlyDetailed(
            "Swift concurrency actors",
            scope: .all,
            graph: engine.freshSnapshotForReadOnly()
        )
        let after = await engine.snapshot().edges

        #expect(after == before)
    }

    @Test
    func searchReadOnlySucceedsEvenWhenPersistenceAlwaysFails() async throws {
        // Seed the graph the engine opens with, so setup never saves.
        var seeded = MemoryGraph()
        seeded.addMemory(EngineMemoryEntry(id: "entry", category: .fact, content: "database migrations at startup"))
        let engine = MemoryEngine(graph: seeded, persistence: AlwaysFailingPersistence())
        // Must not throw — the read-only path never calls save.
        let results = try await engine.searchReadOnlyDetailed(
            "database migrations",
            scope: .all,
            graph: engine.freshSnapshotForReadOnly()
        ).selected
        #expect(!results.isEmpty)
    }

    // MARK: - Contrast: recall keeps maintenance

    @Test
    func recallMaintenanceBatchesUntilCheckpointAndExplicitWritesAbsorbIt() async throws {
        let persistence = RecordingPersistence()
        let configuration = MemoryEngineConfiguration(recallMaintenanceCheckpointSize: 3)
        let engine = MemoryEngine(persistence: persistence, configuration: configuration)
        try await engine.remember("Swift actors isolate mutable state", tags: ["swift"])
        try await engine.remember("Swift structured concurrency guide", tags: ["swift"])
        let savesAfterSetup = await persistence.saved.count

        _ = try await engine.recallDetailed("Swift actors concurrency")
        _ = try await engine.recallDetailed("Swift actors concurrency")
        #expect(await persistence.saved.count == savesAfterSetup)

        // The third derived maintenance record triggers one checkpoint, rather
        // than encoding the complete graph after each useful recall.
        _ = try await engine.recallDetailed("Swift actors concurrency")
        #expect(await persistence.saved.count == savesAfterSetup + 1)

        _ = try await engine.recallDetailed("Swift actors concurrency")
        let beforeExplicitWrite = await persistence.saved.count
        try await engine.remember("An explicit durable fact", tags: ["swift"])
        // The explicit write commits itself and the pending recall in one save.
        #expect(await persistence.saved.count == beforeExplicitWrite + 1)
    }
}
