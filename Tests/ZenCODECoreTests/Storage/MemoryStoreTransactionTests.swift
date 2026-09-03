//
//  MemoryStoreTransactionTests.swift
//  ZenCODECoreTests
//
//  Covers the graph store's transactional contract, which the higher-level
//  suites cannot reach because they exercise one operation at a time:
//
//  - the internal `learn` transaction mints identifiers the maintenance tools
//    accept and applies the same duplicate rule as `write` when an engine test
//    double supplies drafts;
//  - concurrent read-modify-write sequences (deduplicating write, in-place
//    update, archive) neither duplicate nor lose one another, despite actor
//    reentrancy on every `await` against the engine;
//  - a failing `MemoryPersistence` leaves the in-memory graph untouched instead
//    of diverging from disk.
//
//  The store is built directly on an injected engine (an in-process persistence
//  double plus a deterministic extractor) so the tests are deterministic and
//  contact no network. Product stores opened through `open` use the dependency-
//  free `NoopMemoryExtractor`.
//

import Foundation
@testable import ZenCODECore
import Testing

// MARK: - Doubles

private struct StoreSaveFailure: Error, Equatable {}

/// Persistence that can be armed to fail and can hold every save open long
/// enough for a competing mutation to interleave.
private actor ControlledStorePersistence: MemoryPersistence {
    private var graph: MemoryGraph
    private var isFailing: Bool
    private let holdEachSaveFor: Duration?

    init(failing: Bool = false, holdEachSaveFor: Duration? = nil) {
        self.graph = MemoryGraph()
        self.isFailing = failing
        self.holdEachSaveFor = holdEachSaveFor
    }

    func setFailing(_ failing: Bool) { isFailing = failing }

    func load() async throws -> MemoryGraph { graph }

    func save(_ graph: MemoryGraph) async throws {
        if let holdEachSaveFor {
            try? await Task.sleep(for: holdEachSaveFor)
        }
        if isFailing { throw StoreSaveFailure() }
        self.graph = graph
    }
}

private struct DeterministicDraftExtractor: MemoryExtractor {
    let drafts: [MemoryDraft]
    func extract(from context: String) async throws -> [MemoryDraft] { drafts }
}

private func makeStore(
    persistence: ControlledStorePersistence,
    drafts: [MemoryDraft] = []
) -> MemoryGraphStore {
    MemoryGraphStore(
        graphURL: URL(fileURLWithPath: "/dev/null/graph.json"),
        engine: MemoryEngine(
            persistence: persistence,
            extractor: DeterministicDraftExtractor(drafts: drafts)
        ),
        embedder: nil
    )
}

@Suite
struct MemoryStoreTransactionTests {

    // MARK: - Internal learn transaction

    @Test
    func openedProductStoreUsesNoopExtractor() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let store = try await MemoryGraphStore.open(
                graphURL: MemoryGraphLocation.graphURL(for: workspace.workspaceURL),
                workspaceRootURL: workspace.workspaceURL
            )

            // The product's default has no extractor-backed work at all. The
            // internal helper remains a no-op unless a test injects drafts.
            let learned = try await store.learn(from: "a completed conversation")
            #expect(learned.isEmpty)
            #expect(try await store.entries(includeArchived: true, limit: 10).isEmpty)
        }
    }

    @Test
    func learnMintsIdentifiersTheMaintenanceToolsAccept() async throws {
        let persistence = ControlledStorePersistence()
        let store = makeStore(
            persistence: persistence,
            drafts: [
                MemoryDraft(content: "Summary: the deploy script calibrates the flange."),
                MemoryDraft(content: "Summary: releases are tagged from main.", tags: ["release"])
            ]
        )

        let stored = try await store.learn(from: "User: ...\nAssistant: ...")
        #expect(stored.count == 2)

        // The engine's own `learn` mints `mem_<millis>_<uuid>` ids, which
        // `MemoryIdentifier.validated` rejects — an entry the model could read
        // but never correct. Every internally learned id must be a canonical UUID.
        for entry in stored {
            #expect(UUID(uuidString: entry.id) != nil)
            #expect(entry.id == entry.id.uppercased())
        }

        // Proof rather than shape-checking: the maintenance paths accept them.
        let first = try #require(stored.first)
        let updated = try await store.update(
            id: first.id,
            content: "Summary: the deploy script calibrates the flange twice.",
            tags: nil,
            updatedAt: Date(),
            timeZone: TimeZone(identifier: "Europe/Rome") ?? .current
        )
        #expect(updated.id == first.id)
        #expect(updated.content.contains("twice"))

        let archived = try await store.setArchived(true, id: first.id)
        #expect(archived.id == first.id)
        #expect(!archived.active)

        // Archiving is not deletion: the entry is still there, inactive.
        let all = try await store.entries(includeArchived: true, limit: 10)
        #expect(all.count == 2)
        #expect(all.filter(\.active).count == 1)
    }

    @Test
    func learnDoesNotDuplicateWhatWriteAlreadyStored() async throws {
        let content = """
        Summary: the deploy script calibrates the flange.
        State: verified on main.
        """
        let persistence = ControlledStorePersistence()
        // The deterministic draft source returns the same fact with different casing and
        // padding: `write`'s normalization treats it as the same content, and
        // `learn` must agree.
        let store = makeStore(
            persistence: persistence,
            drafts: [
                MemoryDraft(content: """
                SUMMARY: THE DEPLOY SCRIPT CALIBRATES THE FLANGE.
                STATE:    VERIFIED ON MAIN.
                """)
            ]
        )

        let written = try await store.write(content: content, category: .fact, tags: [])
        #expect(written.created)

        let stored = try await store.learn(from: "conversation")
        #expect(stored.isEmpty)

        let entries = try await store.entries(includeArchived: true, limit: 10)
        #expect(entries.count == 1)
        #expect(entries.first?.id == written.entry.id)
    }

    @Test
    func learnDeduplicatesRepeatsInsideOneBatch() async throws {
        let persistence = ControlledStorePersistence()
        let store = makeStore(
            persistence: persistence,
            drafts: [
                MemoryDraft(content: "Summary: releases are tagged from main."),
                MemoryDraft(content: "summary: releases are tagged from main."),
                MemoryDraft(content: "Summary: coverage runs nightly.")
            ]
        )

        let stored = try await store.learn(from: "conversation")
        #expect(stored.count == 2)
        #expect(try await store.entries(includeArchived: true, limit: 10).count == 2)

        // Re-running the same internal draft batch must not append duplicates.
        let again = try await store.learn(from: "conversation")
        #expect(again.isEmpty)
        #expect(try await store.entries(includeArchived: true, limit: 10).count == 2)
    }

    // MARK: - Concurrent mutations

    @Test
    func concurrentWritesOfTheSameContentCreateOneEntry() async throws {
        // Every save is held open, so all eight writes are guaranteed to be in
        // flight together: each one suspends on the engine, which is exactly
        // the reentrancy window where a snapshot-then-write store duplicates.
        let persistence = ControlledStorePersistence(holdEachSaveFor: .milliseconds(2))
        let store = makeStore(persistence: persistence)
        let content = "Summary: only one node may carry this fact."

        let created = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (try? await store.write(content: content, category: .fact, tags: []))?
                        .created ?? false
                }
            }
            return await group.reduce(into: 0) { $0 += $1 ? 1 : 0 }
        }

        #expect(created == 1)
        let entries = try await store.entries(includeArchived: true, limit: 10)
        #expect(entries.count == 1)
    }

    @Test
    func concurrentUpdateAndArchiveKeepBothMutations() async throws {
        let persistence = ControlledStorePersistence(holdEachSaveFor: .milliseconds(2))
        let store = makeStore(persistence: persistence)
        let written = try await store.write(
            content: "Summary: the original state.",
            category: .fact,
            tags: []
        )
        let id = written.entry.id

        // Either order is legal; what is not legal is one of the two writers
        // erasing the other. `update` must not resurrect an archived entry and
        // `setArchived` must not restore the old content.
        async let update = store.update(
            id: id,
            content: "Summary: the corrected state.",
            tags: nil,
            updatedAt: Date(),
            timeZone: TimeZone(identifier: "Europe/Rome") ?? .current
        )
        async let archive = store.setArchived(true, id: id)
        _ = try await (update, archive)

        let entry = try #require(try await store.entry(id: id))
        #expect(entry.content.contains("the corrected state."))
        #expect(!entry.active)
        // Identity is preserved by both paths.
        #expect(entry.id == id)
    }

    @Test
    func concurrentDistinctWritesAllLand() async throws {
        let persistence = ControlledStorePersistence(holdEachSaveFor: .milliseconds(1))
        let store = makeStore(persistence: persistence)
        let total = 12

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<total {
                group.addTask {
                    _ = try? await store.write(
                        content: "Summary: distinct fact number \(index).",
                        category: .fact,
                        tags: []
                    )
                }
            }
        }

        let entries = try await store.entries(includeArchived: true, limit: total * 2)
        #expect(entries.count == total)
        #expect(Set(entries.map(\.id)).count == total)
    }

    // MARK: - Persistence failure

    @Test
    func writeStoresNothingWhenPersistenceFails() async throws {
        let persistence = ControlledStorePersistence(failing: true)
        let store = makeStore(persistence: persistence)

        await #expect(throws: StoreSaveFailure.self) {
            _ = try await store.write(
                content: "Summary: never committed.",
                category: .fact,
                tags: []
            )
        }

        // The graph must match the disk: the write reached neither.
        #expect(try await store.entries(includeArchived: true, limit: 10).isEmpty)

        // And the store stays usable once persistence recovers.
        await persistence.setFailing(false)
        let written = try await store.write(
            content: "Summary: committed after recovery.",
            category: .fact,
            tags: []
        )
        #expect(written.created)
        #expect(try await store.entries(includeArchived: true, limit: 10).count == 1)
    }

    @Test
    func learnStoresNothingWhenPersistenceFails() async throws {
        let persistence = ControlledStorePersistence(failing: true)
        let store = makeStore(
            persistence: persistence,
            drafts: [
                MemoryDraft(content: "Summary: first learned fact."),
                MemoryDraft(content: "Summary: second learned fact.")
            ]
        )

        await #expect(throws: StoreSaveFailure.self) {
            _ = try await store.learn(from: "conversation")
        }
        // All or nothing: not even the first draft of the batch is kept.
        #expect(try await store.entries(includeArchived: true, limit: 10).isEmpty)
    }

    @Test
    func updateAndArchiveAreRolledBackWhenPersistenceFails() async throws {
        let persistence = ControlledStorePersistence()
        let store = makeStore(persistence: persistence)
        let written = try await store.write(
            content: "Summary: the durable state.",
            category: .fact,
            tags: ["deploy"]
        )
        let id = written.entry.id

        await persistence.setFailing(true)

        await #expect(throws: StoreSaveFailure.self) {
            _ = try await store.update(
                id: id,
                content: "Summary: a state that never reaches the disk.",
                tags: ["rejected"],
                updatedAt: Date(),
                timeZone: TimeZone(identifier: "Europe/Rome") ?? .current
            )
        }
        var entry = try #require(try await store.entry(id: id))
        #expect(entry.content.contains("the durable state."))
        #expect(entry.tags == ["deploy"])
        #expect(entry.active)

        await #expect(throws: StoreSaveFailure.self) {
            _ = try await store.setArchived(true, id: id)
        }
        entry = try #require(try await store.entry(id: id))
        #expect(entry.active)

        await #expect(throws: StoreSaveFailure.self) {
            try await store.delete(id: id)
        }
        entry = try #require(try await store.entry(id: id))
        #expect(entry.content.contains("the durable state."))
    }

    // MARK: - Unknown entries

    @Test
    func maintenanceOfAnUnknownEntryFailsWithoutTouchingTheGraph() async throws {
        let persistence = ControlledStorePersistence()
        let store = makeStore(persistence: persistence)
        _ = try await store.write(content: "Summary: kept.", category: .fact, tags: [])
        let missing = UUID().uuidString

        await #expect(throws: MemoryServiceError.self) {
            _ = try await store.setArchived(true, id: missing)
        }
        await #expect(throws: MemoryServiceError.self) {
            try await store.delete(id: missing)
        }
        await #expect(throws: MemoryServiceError.self) {
            _ = try await store.update(
                id: missing,
                content: "Summary: nothing to update.",
                tags: nil,
                updatedAt: Date(),
                timeZone: .current
            )
        }

        let entries = try await store.entries(includeArchived: true, limit: 10)
        #expect(entries.count == 1)
        #expect(entries.first?.active == true)
    }

    // MARK: - Cancellation: a direct learn transaction queued for the lock

    @Test
    func cancelledLearnQueuedForTheLockCommitsNothing() async throws {
        let persistence = GatedStorePersistence()
        let store = MemoryGraphStore(
            graphURL: URL(fileURLWithPath: "/dev/null/graph.json"),
            engine: MemoryEngine(
                persistence: persistence,
                extractor: DeterministicDraftExtractor(drafts: [
                    MemoryDraft(content: "Summary: a late learned fact.")
                ])
            ),
            embedder: nil
        )

        // Hold the write lock: this write parks inside persistence, so the
        // direct learn transaction's own commit must queue behind it.
        let holder = Task<Void, Never> {
            _ = try? await store.write(
                content: "Summary: the holder fact.",
                category: .fact,
                tags: []
            )
        }
        await pollStoreCondition { await persistence.saveEnteredCount >= 1 }

        // The deterministic source returns its drafts instantly. What remains
        // is the atomic commit, which is queued behind the held lock.
        let pendingLearn = Task<[GraphEntry], Never> {
            (try? await store.learn(from: "conversation")) ?? []
        }
        // Give the transaction time to pass its pre-commit check and park in the
        // lock wait rather than winning a start-up race.
        try? await Task.sleep(for: .milliseconds(50))

        // Cancel the transaction while it is waiting to commit. Whether the
        // cancellation is observed at the pre-commit check in `learn` or at the
        // post-lock check in the engine's transaction, the drafts must not land.
        pendingLearn.cancel()

        // Releasing the gate lets the holder finish, which frees the lock and
        // resumes the cancelled transaction just long enough for it to bail out.
        await persistence.release()
        let stored = await pendingLearn.value
        #expect(stored.isEmpty)
        _ = await holder.value

        // The cancelled transaction committed nothing; only the holder's write is
        // present, and there was exactly one save.
        let entries = try await store.entries(includeArchived: true, limit: 10)
        #expect(entries.count == 1)
        #expect(entries.first?.content.localizedCaseInsensitiveContains("holder") ?? false)
        #expect(await persistence.saveCount == 1)
    }
}


// MARK: - Gated persistence for cancellation tests

/// Persistence that blocks every save on a gate until `release()` is called, so
/// a test can hold the write lock for as long as it needs and observe exactly
/// when a competing mutation gets to commit.
private actor GatedStorePersistence: MemoryPersistence {
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
private func pollStoreCondition(
    _ condition: () async -> Bool,
    timeout: Duration = .seconds(2)
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
}
