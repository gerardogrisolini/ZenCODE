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
}
