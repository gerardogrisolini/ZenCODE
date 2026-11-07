//
//  ReadOnlySearchTests.swift
//  ZenCODECoreTests (memory engine)
//
//  Verifies the read-only search path: `searchReadOnly` performs the same
//  retrieval as `recall` but applies no maintenance and never touches
//  persistence, while `recall` keeps its transactional maintenance.
//

import Foundation
import Testing
@testable import ZenCODECore

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

        // searchReadOnly first: it does not mutate, so recall sees the same graph
        // and must select the same entries.
        let readOnly = try await engine.searchReadOnly("actors mutable state")
        let recalled = try await engine.recall("actors mutable state")

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
        _ = try await engine.searchReadOnly("Swift concurrency actors")
        let after = await engine.snapshot().edges

        #expect(after == before)
    }

    @Test
    func searchReadOnlySucceedsEvenWhenPersistenceAlwaysFails() async throws {
        let engine = MemoryEngine(persistence: AlwaysFailingPersistence())
        // Seed without persistence so the failing save is not triggered by setup.
        try await engine.insert(
            EngineMemoryEntry(id: "entry", category: .fact, content: "database migrations at startup"),
            persist: false
        )
        // Must not throw — the read-only path never calls save.
        let results = try await engine.searchReadOnly("database migrations")
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

        _ = try await engine.recall("Swift actors concurrency")
        _ = try await engine.recall("Swift actors concurrency")
        #expect(await persistence.saved.count == savesAfterSetup)

        // The third derived maintenance record triggers one checkpoint, rather
        // than encoding the complete graph after each useful recall.
        _ = try await engine.recall("Swift actors concurrency")
        #expect(await persistence.saved.count == savesAfterSetup + 1)

        _ = try await engine.recall("Swift actors concurrency")
        let beforeExplicitWrite = await persistence.saved.count
        try await engine.remember("An explicit durable fact", tags: ["swift"])
        // The explicit write commits itself and the pending recall in one save.
        #expect(await persistence.saved.count == beforeExplicitWrite + 1)
    }
}
