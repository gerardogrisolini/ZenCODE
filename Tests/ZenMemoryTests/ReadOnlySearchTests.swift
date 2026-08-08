//
//  ReadOnlySearchTests.swift
//  ZenMemoryTests
//
//  Verifies the read-only search path: `searchReadOnly` performs the same
//  retrieval as `recall` but applies no maintenance and never touches
//  persistence, while `recall` keeps its transactional maintenance.
//

import Foundation
import Testing
@testable import ZenMemory

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
    func searchReadOnlyReturnsResults() async throws {
        let engine = ZenMemory(persistence: RecordingPersistence())
        try await engine.remember("Swift actors isolate mutable state", tags: ["swift"])
        try await engine.remember("Database migrations run at startup", tags: ["database"])

        let results = try await engine.searchReadOnly("actors mutable state")
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.memory.content.contains("actors") })
    }

    @Test
    func searchReadOnlyAndRecallSelectSameEntries() async throws {
        let engine = ZenMemory(persistence: RecordingPersistence())
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
    func searchReadOnlyDoesNotMutateRetrievalCount() async throws {
        let engine = ZenMemory(persistence: RecordingPersistence())
        try await engine.remember("Swift actors isolate mutable state", tags: ["swift"])
        try await engine.remember("Database migrations run at startup", tags: ["database"])

        let before = await engine.snapshot().metadata.retrievalCount
        _ = try await engine.searchReadOnly("actors")
        _ = try await engine.searchReadOnly("actors mutable state")
        _ = try await engine.searchReadOnly("database")
        let after = await engine.snapshot().metadata.retrievalCount

        #expect(after == before)
    }

    @Test
    func searchReadOnlyDoesNotChangeConfidence() async throws {
        let engine = ZenMemory(persistence: RecordingPersistence())
        try await engine.remember("Swift actors isolate mutable state", tags: ["swift"])
        try await engine.remember("Database migrations run at startup", tags: ["database"])

        let before = await engine.snapshot().memories.mapValues(\.confidence)
        _ = try await engine.searchReadOnly("actors mutable state")
        let after = await engine.snapshot().memories.mapValues(\.confidence)

        #expect(after == before)
    }

    @Test
    func searchReadOnlyDoesNotCreateLinks() async throws {
        let engine = ZenMemory(persistence: RecordingPersistence())
        try await engine.remember("Swift actors isolate mutable state", tags: ["swift"])
        try await engine.remember("Swift structured concurrency guide", tags: ["swift"])

        let before = await engine.snapshot().edges
        _ = try await engine.searchReadOnly("Swift concurrency actors")
        let after = await engine.snapshot().edges

        #expect(after == before)
    }

    @Test
    func searchReadOnlyNeverPersists() async throws {
        let persistence = RecordingPersistence()
        let engine = ZenMemory(persistence: persistence)
        try await engine.remember("Swift actors isolate mutable state", tags: ["swift"])

        let savesBefore = await persistence.saved.count
        _ = try await engine.searchReadOnly("actors")
        _ = try await engine.searchReadOnly("actors mutable state")
        let savesAfter = await persistence.saved.count

        #expect(savesAfter == savesBefore)
    }

    @Test
    func searchReadOnlySucceedsEvenWhenPersistenceAlwaysFails() async throws {
        let engine = ZenMemory(persistence: AlwaysFailingPersistence())
        // Seed without persistence so the failing save is not triggered by setup.
        try await engine.insert(
            MemoryEntry(id: "entry", category: .fact, content: "database migrations at startup"),
            persist: false
        )
        // Must not throw — the read-only path never calls save.
        let results = try await engine.searchReadOnly("database migrations")
        #expect(!results.isEmpty)
    }

    // MARK: - Contrast: recall keeps maintenance

    @Test
    func recallStillAppliesTransactionalMaintenance() async throws {
        let persistence = RecordingPersistence()
        let engine = ZenMemory(persistence: persistence)
        try await engine.remember("Swift actors isolate mutable state", tags: ["swift"])
        try await engine.remember("Swift structured concurrency guide", tags: ["swift"])

        let retrievalBefore = await engine.snapshot().metadata.retrievalCount
        let savesBefore = await persistence.saved.count
        _ = try await engine.recall("Swift actors concurrency")
        let retrievalAfter = await engine.snapshot().metadata.retrievalCount
        let savesAfter = await persistence.saved.count

        #expect(retrievalAfter > retrievalBefore)
        #expect(savesAfter > savesBefore)
    }

    @Test
    func recallStillCreatesCoRelevanceLinks() async throws {
        let persistence = RecordingPersistence()
        let engine = ZenMemory(persistence: persistence)
        try await engine.remember("Swift actors isolate mutable state", tags: ["swift"])
        try await engine.remember("Swift structured concurrency guide", tags: ["swift"])

        let linksBefore = await engine.snapshot().edges.values.flatMap { $0 }.count
        _ = try await engine.recall("Swift actors concurrency")
        let linksAfter = await engine.snapshot().edges.values.flatMap { $0 }.count

        // With two selected memories and strengthenCoRelevantLinks enabled,
        // recall links them in both directions.
        #expect(linksAfter > linksBefore)
    }
}
