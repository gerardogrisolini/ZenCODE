//
//  MemoryEngineTransactionTests.swift
//  ZenCODECoreTests (memory engine)
//
//  Covers the engine's transactional contract: explicit mutations are serialized
//  against one another despite actor reentrancy and are committed to the live
//  graph only after persistence accepts them. Automatic recall maintenance has
//  a separate contract: it is visible immediately, remains pending until a
//  checkpoint, and survives a failed checkpoint for retry.
//
//  Every test is deterministic: the failing/slow persistence doubles below make
//  the interleaving window explicit instead of relying on timing luck.
//

import Foundation
import Testing
@testable import ZenCODECore

// MARK: - Persistence doubles

private struct MemoryPersistenceFailure: Error, Equatable {
    let attempt: Int
}

/// Persistence that can be armed to fail, counts saves, and can hold each save
/// open long enough for a competing mutation to try to interleave.
private actor ControlledPersistence: MemoryPersistence {
    private var graph: MemoryGraph
    private(set) var saveCount = 0
    private(set) var lastSaved: MemoryGraph?
    private var isFailing: Bool
    private var holdEachSaveFor: Duration?
    /// Highest number of saves observed running at the same time. A correct
    /// write lock keeps this at 1.
    private(set) var maximumConcurrentSaves = 0
    private var activeSaves = 0

    init(graph: MemoryGraph = MemoryGraph(), failing: Bool = false, holdEachSaveFor: Duration? = nil) {
        self.graph = graph
        self.isFailing = failing
        self.holdEachSaveFor = holdEachSaveFor
    }

    func setFailing(_ failing: Bool) { isFailing = failing }

    func load() async throws -> MemoryGraph { graph }

    func save(_ graph: MemoryGraph) async throws {
        saveCount += 1
        activeSaves += 1
        maximumConcurrentSaves = max(maximumConcurrentSaves, activeSaves)
        defer { activeSaves -= 1 }
        if let holdEachSaveFor {
            try? await Task.sleep(for: holdEachSaveFor)
        }
        if isFailing {
            throw MemoryPersistenceFailure(attempt: saveCount)
        }
        self.graph = graph
        lastSaved = graph
    }
}

// MARK: - Rollback on a failing save

@Test func rememberLeavesGraphUnchangedWhenSaveFails() async throws {
    let persistence = ControlledPersistence(failing: true)
    let memory = MemoryEngine(persistence: persistence)

    await #expect(throws: MemoryPersistenceFailure.self) {
        _ = try await memory.remember("a durable fact", id: "kept-out")
    }

    // The in-memory graph must not diverge from what is on disk.
    let snapshot = await memory.snapshot()
    #expect(snapshot.memories.isEmpty)
    #expect(await persistence.saveCount == 1)
}

@Test func insertLeavesGraphUnchangedWhenSaveFails() async throws {
    let persistence = ControlledPersistence(failing: true)
    let memory = MemoryEngine(persistence: persistence)
    let entry = EngineMemoryEntry(id: "rejected", category: .fact, content: "not committed")

    await #expect(throws: MemoryPersistenceFailure.self) {
        try await memory.insert(entry)
    }

    #expect(await memory.snapshot().memories["rejected"] == nil)
}

@Test func forgetKeepsEntryWhenSaveFails() async throws {
    let persistence = ControlledPersistence()
    let memory = MemoryEngine(persistence: persistence)
    _ = try await memory.remember("a durable fact", id: "keeper")

    await persistence.setFailing(true)
    await #expect(throws: MemoryPersistenceFailure.self) {
        _ = try await memory.forget(id: "keeper")
    }

    // The entry is still on disk, so it must still be in memory too.
    let snapshot = await memory.snapshot()
    #expect(snapshot.memories["keeper"] != nil)
    #expect(snapshot.memories["keeper"]?.content == "a durable fact")
}

@Test func failedSaveIsRecoverableWithoutLosingLaterWrites() async throws {
    let persistence = ControlledPersistence(failing: true)
    let memory = MemoryEngine(persistence: persistence)

    await #expect(throws: MemoryPersistenceFailure.self) {
        _ = try await memory.remember("lost fact", id: "lost")
    }
    await persistence.setFailing(false)
    _ = try await memory.remember("stored fact", id: "stored")

    let snapshot = await memory.snapshot()
    #expect(snapshot.memories["lost"] == nil)
    #expect(snapshot.memories["stored"] != nil)
    // Disk and memory agree: the rolled back write is in neither.
    let saved = try #require(await persistence.lastSaved)
    #expect(saved.memories.keys.sorted() == ["stored"])
}

@Test func recallMaintenanceIsPendingWhenFlushFailsAndCanBeRetried() async throws {
    let persistence = ControlledPersistence()
    let memory = MemoryEngine(persistence: persistence)
    _ = try await memory.remember("actors protect mutable state", tags: ["swift"], id: "a")
    let before = await memory.snapshot()
    let savesAfterSetup = await persistence.saveCount

    // Automatic recall maintenance is visible immediately, but the default
    // checkpoint threshold leaves it pending instead of saving on every recall.
    await persistence.setFailing(true)
    _ = try await memory.recall("actors")
    let visible = await memory.snapshot()
    #expect(visible.metadata.retrievalCount == before.metadata.retrievalCount &+ 1)
    let beforeEntry = try #require(before.memories["a"])
    let visibleEntry = try #require(visible.memories["a"])
    #expect(visibleEntry.accessCount == beforeEntry.accessCount &+ 1)
    #expect(await persistence.saveCount == savesAfterSetup)
    let durableBefore = try #require(await persistence.lastSaved)
    #expect(durableBefore == before)

    // A failed explicit flush is observable, but must not roll back the
    // in-memory maintenance or consume its intent.
    await #expect(throws: MemoryPersistenceFailure.self) {
        try await memory.flushRecallMaintenance()
    }
    let afterFailure = await memory.snapshot()
    #expect(afterFailure == visible)
    #expect(await persistence.lastSaved == durableBefore)

    // Retrying after the store recovers persists the same maintenance exactly
    // once; a second flush proves the pending intent was consumed on success.
    await persistence.setFailing(false)
    try await memory.flushRecallMaintenance()
    let durableAfterRetry = try #require(await persistence.lastSaved)
    #expect(durableAfterRetry.metadata.retrievalCount == visible.metadata.retrievalCount)
    #expect(durableAfterRetry.memories["a"]?.accessCount == visible.memories["a"]?.accessCount)
    let savesAfterRetry = await persistence.saveCount
    try await memory.flushRecallMaintenance()
    #expect(await persistence.saveCount == savesAfterRetry)
}

@Test func failedAutomaticCheckpointRetainsPendingMaintenanceForRetry() async throws {
    let persistence = ControlledPersistence()
    let configuration = MemoryEngineConfiguration(recallMaintenanceCheckpointSize: 1)
    let memory = MemoryEngine(persistence: persistence, configuration: configuration)
    _ = try await memory.remember("actors protect mutable state", tags: ["swift"], id: "a")
    let before = await memory.snapshot()

    await persistence.setFailing(true)
    await #expect(throws: MemoryPersistenceFailure.self) {
        _ = try await memory.recall("actors")
    }

    // The automatic checkpoint failed after maintenance became visible. The
    // intent remains queued, rather than being mistaken for a rolled-back read.
    let visible = await memory.snapshot()
    #expect(visible.metadata.retrievalCount == before.metadata.retrievalCount &+ 1)
    let beforeEntry = try #require(before.memories["a"])
    let visibleEntry = try #require(visible.memories["a"])
    #expect(visibleEntry.accessCount == beforeEntry.accessCount &+ 1)
    let durableBefore = try #require(await persistence.lastSaved)
    #expect(durableBefore == before)

    await persistence.setFailing(false)
    try await memory.flushRecallMaintenance()
    let durableAfterRetry = try #require(await persistence.lastSaved)
    #expect(durableAfterRetry.metadata.retrievalCount == visible.metadata.retrievalCount)
    #expect(durableAfterRetry.memories["a"]?.accessCount == visible.memories["a"]?.accessCount)
}

@Test func successfulRecallCommitsRetrievalCount() async throws {
    let persistence = ControlledPersistence()
    let memory = MemoryEngine(persistence: persistence)
    _ = try await memory.remember("actors protect mutable state", tags: ["swift"], id: "a")

    _ = try await memory.recall("actors")

    // The maintenance is visible before its durability boundary, while the
    // previous graph remains the one saved by the setup write.
    let visible = await memory.snapshot()
    #expect(visible.metadata.retrievalCount == 1)
    #expect(await persistence.lastSaved?.metadata.retrievalCount == 0)

    try await memory.flushRecallMaintenance()
    #expect(await persistence.lastSaved?.metadata.retrievalCount == 1)
}

@Test func explicitWriteAbsorbsPendingRecallMaintenanceExactlyOnce() async throws {
    let persistence = ControlledPersistence()
    let memory = MemoryEngine(persistence: persistence)
    _ = try await memory.remember("actors protect mutable state", tags: ["swift"], id: "a")

    _ = try await memory.recall("actors")
    #expect(await memory.snapshot().metadata.retrievalCount == 1)

    // The explicit write is an immediate durability boundary. Its save must
    // include the pending recall, but must not replay it on the already-visible
    // non-transactional graph.
    _ = try await memory.remember("actors are reentrant", id: "b")
    let committed = try #require(await persistence.lastSaved)
    #expect(committed.metadata.retrievalCount == 1)
    #expect(committed.memories["a"]?.accessCount == 1)
    #expect(committed.memories["b"] != nil)
}

@Test func saveFlushesPendingRecallMaintenanceExactlyOnce() async throws {
    let persistence = ControlledPersistence()
    let memory = MemoryEngine(persistence: persistence)
    _ = try await memory.remember("actors protect mutable state", tags: ["swift"], id: "a")

    _ = try await memory.recall("actors")
    let visible = await memory.snapshot()

    // `save()` is also a durability boundary and must consume the pending
    // intent. A later flush must therefore be a no-op, not a replay.
    try await memory.save()
    let saved = try #require(await persistence.lastSaved)
    #expect(saved.metadata.retrievalCount == visible.metadata.retrievalCount)
    #expect(saved.memories["a"]?.accessCount == visible.memories["a"]?.accessCount)
    let savesAfterSave = await persistence.saveCount
    try await memory.flushRecallMaintenance()
    #expect(await persistence.saveCount == savesAfterSave)
}

@Test func noOpTransactionFlushesPendingRecallMaintenanceExactlyOnce() async throws {
    let persistence = ControlledPersistence()
    let memory = MemoryEngine(persistence: persistence)
    _ = try await memory.remember("actors protect mutable state", tags: ["swift"], id: "a")

    _ = try await memory.recall("actors")
    let visible = await memory.snapshot()
    let savesBeforeTransaction = await persistence.saveCount

    // Even an idempotent explicit transaction is a durability boundary when
    // recall maintenance is pending. A no-op without pending remains covered
    // by transactionWithoutChangesDoesNotPersist below.
    _ = try await memory.transaction { _ in () }
    #expect(await persistence.saveCount == savesBeforeTransaction + 1)
    let saved = try #require(await persistence.lastSaved)
    #expect(saved.metadata.retrievalCount == visible.metadata.retrievalCount)
    #expect(saved.memories["a"]?.accessCount == visible.memories["a"]?.accessCount)

    let savesAfterTransaction = await persistence.saveCount
    try await memory.flushRecallMaintenance()
    #expect(await persistence.saveCount == savesAfterTransaction)
}

@Test func coldJSONCheckpointReplaysPendingMaintenanceOnce() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("memory-engine-cold-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("memory.json")

    var initial = MemoryGraph()
    initial.addMemory(
        EngineMemoryEntry(
            id: "a",
            category: .fact,
            content: "actors protect mutable state",
            tags: ["swift"]
        )
    )
    let persistence = JSONMemoryPersistence(url: file)
    let memory = MemoryEngine(graph: initial, persistence: persistence)
    #expect(!FileManager.default.fileExists(atPath: file.path))

    _ = try await memory.recall("actors")
    let visible = await memory.snapshot()
    #expect(visible.metadata.retrievalCount == 1)
    #expect(visible.memories["a"]?.accessCount == 1)
    #expect(!FileManager.default.fileExists(atPath: file.path))

    try await memory.flushRecallMaintenance()
    let persisted = try await persistence.load()
    #expect(persisted.metadata.retrievalCount == 1)
    #expect(persisted.memories["a"]?.accessCount == 1)
    #expect(persisted.memories.count == 1)
}

@Test func coldJSONExplicitWriteAbsorbsPendingMaintenanceOnce() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("memory-engine-cold-write-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("memory.json")

    var initial = MemoryGraph()
    initial.addMemory(
        EngineMemoryEntry(
            id: "a",
            category: .fact,
            content: "actors protect mutable state",
            tags: ["swift"]
        )
    )
    let persistence = JSONMemoryPersistence(url: file)
    let memory = MemoryEngine(graph: initial, persistence: persistence)

    _ = try await memory.recall("actors")
    _ = try await memory.remember("actors are reentrant", id: "b")

    let persisted = try await persistence.load()
    #expect(persisted.metadata.retrievalCount == 1)
    #expect(persisted.memories["a"]?.accessCount == 1)
    #expect(persisted.memories["b"] != nil)
}

// MARK: - Serialization under actor reentrancy

@Test func concurrentTransactionsDoNotLoseUpdates() async throws {
    // Each save is held open, so every transaction is guaranteed to suspend
    // while the others are ready to run: without a write lock the reentrant
    // read-modify-write below would drop increments.
    let persistence = ControlledPersistence(holdEachSaveFor: .milliseconds(2))
    let memory = MemoryEngine(persistence: persistence)
    let rounds = 24

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<rounds {
            group.addTask {
                try? await memory.transaction { graph in
                    graph.metadata.linkDiscoveryCount += 1
                }
            }
        }
    }

    #expect(await memory.snapshot().metadata.linkDiscoveryCount == UInt64(rounds))
    // Serialized: no two saves ever overlapped.
    #expect(await persistence.maximumConcurrentSaves == 1)
}

@Test func concurrentReadModifyWriteKeepsEveryWriterField() async throws {
    let persistence = ControlledPersistence(holdEachSaveFor: .milliseconds(2))
    let memory = MemoryEngine(persistence: persistence)
    _ = try await memory.remember("shared entry", id: "shared")

    // Two writers touching different fields of the same node. Under reentrancy
    // both would read the same base copy and the second commit would erase the
    // first; inside a transaction each one merges into the current node.
    async let contentWrite: Void = memory.transaction { graph in
        guard var entry = graph.memories["shared"] else { return }
        entry.content = "updated content"
        entry.refreshSearchText()
        graph.addMemory(entry)
    }
    async let archiveWrite: Void = memory.transaction { graph in
        guard var entry = graph.memories["shared"] else { return }
        entry.active = false
        graph.addMemory(entry)
    }
    _ = try await (contentWrite, archiveWrite)

    let entry = try #require(await memory.snapshot().memories["shared"])
    #expect(entry.content == "updated content")
    #expect(!entry.active)
}

@Test func concurrentRemembersAllLand() async throws {
    let persistence = ControlledPersistence(holdEachSaveFor: .milliseconds(1))
    let memory = MemoryEngine(persistence: persistence)
    let count = 16

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<count {
            group.addTask {
                _ = try? await memory.remember("fact \(index)", id: "id-\(index)")
            }
        }
    }

    #expect(await memory.snapshot().memories.count == count)
    #expect(await persistence.lastSaved?.memories.count == count)
}

// MARK: - No-op transactions

@Test func transactionWithoutChangesDoesNotPersist() async throws {
    let persistence = ControlledPersistence()
    let memory = MemoryEngine(persistence: persistence)
    _ = try await memory.remember("a durable fact", id: "a")
    let savesAfterWrite = await persistence.saveCount

    let content = try await memory.transaction { graph in
        graph.memories["a"]?.content
    }

    #expect(content == "a durable fact")
    #expect(await persistence.saveCount == savesAfterWrite)
}

@Test func throwingTransactionCommitsNothing() async throws {
    struct Rejected: Error {}
    let persistence = ControlledPersistence()
    let memory = MemoryEngine(persistence: persistence)

    await #expect(throws: Rejected.self) {
        try await memory.transaction { graph in
            graph.addMemory(EngineMemoryEntry(id: "half-written", category: .fact, content: "x"))
            throw Rejected()
        }
    }

    #expect(await memory.snapshot().memories.isEmpty)
    #expect(await persistence.saveCount == 0)
}

// MARK: - Batch learn

private struct StubExtractor: MemoryExtractor {
    let drafts: [MemoryDraft]
    func extract(from context: String) async throws -> [MemoryDraft] { drafts }
}

@Test func learnStoresTheWholeBatchOrNothing() async throws {
    let persistence = ControlledPersistence(failing: true)
    let memory = MemoryEngine(
        persistence: persistence,
        extractor: StubExtractor(drafts: [
            MemoryDraft(content: "first extracted fact"),
            MemoryDraft(content: "second extracted fact")
        ])
    )

    await #expect(throws: MemoryPersistenceFailure.self) {
        _ = try await memory.learn(from: "conversation")
    }
    #expect(await memory.snapshot().memories.isEmpty)

    await persistence.setFailing(false)
    let stored = try await memory.learn(from: "conversation")
    #expect(stored.count == 2)
    #expect(await memory.snapshot().memories.count == 2)
    // One transaction for the batch, not one save per draft.
    #expect(await persistence.saveCount == 2)
}

private enum RecallCancellationOutcome: Sendable, Equatable {
    case succeeded
    case cancelled
    case failed
}

@Test func cancelledRecallWaitingForTheWriteLockCommitsNoMaintenance() async throws {
    let persistence = GatedPersistence()
    let memory = MemoryEngine(persistence: persistence)
    try await memory.insert(
        EngineMemoryEntry(
            id: "a",
            category: .fact,
            content: "actors protect mutable state",
            tags: ["swift"]
        ),
        persist: false
    )

    // Occupy the write lock with a save that is held by the gate.
    let holder = Task<Void, Never> {
        _ = try? await memory.transaction { graph in
            graph.metadata.linkDiscoveryCount += 1
        }
    }
    await waitForCondition { await persistence.saveEnteredCount >= 1 }

    // The recall has already started while the holder is suspended and queues
    // behind its lock. Cancelling it must be observed after the lock resumes,
    // before revalidation or maintenance can touch the graph.
    let queued = Task<RecallCancellationOutcome, Never> {
        do {
            _ = try await memory.recall("actors")
            return .succeeded
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed
        }
    }
    try? await Task.sleep(for: .milliseconds(50))
    queued.cancel()

    await persistence.release()
    let outcome = await queued.value
    _ = await holder.value
    #expect(outcome == .cancelled)

    let snapshot = await memory.snapshot()
    #expect(snapshot.metadata.retrievalCount == 0)
    let savesAfterRecall = await persistence.saveCount
    #expect(savesAfterRecall == 1)
    try await memory.flushRecallMaintenance()
    #expect(await persistence.saveCount == savesAfterRecall)
}

// MARK: - Cancellation while queued for the write lock

/// Persistence that blocks every save on a gate until `release()` is called, so
/// a test can hold the write lock for as long as it needs and observe exactly
/// when a competing transaction gets to run.
private actor GatedPersistence: MemoryPersistence {
    private var graph = MemoryGraph()
    private(set) var saveCount = 0
    private(set) var saveEnteredCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func load() async throws -> MemoryGraph { graph }

    func save(_ graph: MemoryGraph) async throws {
        saveCount += 1
        saveEnteredCount += 1
        if !isReleased {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        self.graph = graph
    }

    func release() {
        isReleased = true
        let parked = waiters
        waiters.removeAll()
        for waiter in parked { waiter.resume() }
    }
}

/// Polls `condition` until it holds or the bound elapses.
private func waitForCondition(
    _ condition: () async -> Bool,
    timeout: Duration = .seconds(2)
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

@Test func cancelledTransactionWaitingForTheWriteLockCommitsNothing() async throws {
    let persistence = GatedPersistence()
    let memory = MemoryEngine(persistence: persistence)

    // Task A takes the write lock and parks inside persistence, holding it until
    // the gate opens. Its only job is to occupy the lock.
    let holder = Task<Void, Never> {
        _ = try? await memory.transaction { graph in
            graph.metadata.linkDiscoveryCount += 1
        }
    }
    // Wait until A is genuinely inside the save: the lock is now held, so any
    // other transaction must queue behind it.
    await waitForCondition { await persistence.saveEnteredCount >= 1 }

    // Task B queues behind A for the write lock.
    let queued = Task<Bool, Never> {
        do {
            _ = try await memory.transaction { graph in
                graph.metadata.linkDiscoveryCount += 1
            }
            return true
        } catch {
            return false
        }
    }
    // Give B time to reach the lock wait rather than win a start-up race.
    try? await Task.sleep(for: .milliseconds(50))

    // Cancel B while it is parked waiting for the lock. The lock-wait
    // continuation is the non-throwing flavour, so cancellation is not observed
    // there — it has to be re-checked once the lock is actually held.
    queued.cancel()

    // Opening the gate lets A finish, which releases the lock and resumes B; B
    // then observes the cancellation before its body/save and bails out.
    await persistence.release()
    let committed = await queued.value
    #expect(!committed)
    _ = await holder.value

    // Only the holder's increment landed; the cancelled waiter committed
    // nothing, and neither its draft nor its save touched the graph.
    let snapshot = await memory.snapshot()
    #expect(snapshot.metadata.linkDiscoveryCount == 1)
    #expect(await persistence.saveCount == 1)

    // The lock was released by the failed waiter's `defer`, not stranded: a
    // fresh transaction commits normally afterwards.
    _ = try await memory.transaction { graph in
        graph.metadata.linkDiscoveryCount += 1
    }
    #expect(await memory.snapshot().metadata.linkDiscoveryCount == 2)
}
