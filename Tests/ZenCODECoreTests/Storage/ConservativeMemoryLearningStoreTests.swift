import Foundation
import Testing
@testable import ZenCODECore

@Suite struct ConservativeMemoryLearningStoreTests {
    @Test func manualWriteDuringProposalMakesCommitNoop() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let store = try await MemoryGraphStore.open(graphURL: MemoryGraphLocation.graphURL(for: workspace.workspaceURL))
            let snapshot = try #require(try await store.learningSnapshot(query: "Widget"))
            _ = try await store.write(content: "Summary: Widget is one-based.", category: .fact, tags: [])
            let committed = try await store.commitLearning(content: "Summary: Widget uses one-based indexes.", existingID: nil,
                snapshot: snapshot, permit: MemoryLearningPermit(), event: UUID())
            #expect(!committed)
            #expect(try await store.entries(includeArchived: true, limit: 10).count == 1)
        }
    }

    @Test func oneEventAndThreeMutationCapIncludeUpdatesAndConcurrentRetries() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let store = try await MemoryGraphStore.open(graphURL: MemoryGraphLocation.graphURL(for: workspace.workspaceURL))
            let permit = MemoryLearningPermit()
            let event = UUID()
            let snapshot = try #require(try await store.learningSnapshot())
            async let first = store.commitLearning(content: "Summary: Widget starts at one.", existingID: nil, snapshot: snapshot, permit: permit, event: event)
            async let retry = store.commitLearning(content: "Summary: Widget starts at one.", existingID: nil, snapshot: snapshot, permit: permit, event: event)
            let outcomes = try await [first, retry]
            #expect(outcomes.filter { $0 }.count == 1)
            for index in 0..<3 {
                let fresh = try #require(try await store.learningSnapshot())
                let committed = try await store.commitLearning(content: "Summary: Distinct component \(index) uses format \(index).", existingID: nil,
                    snapshot: fresh, permit: permit, event: UUID())
                #expect(committed == (index < 2))
            }
        }
    }

    @Test func lookupIDsOnlyArchiveFenceAndCancellation() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let store = try await MemoryGraphStore.open(graphURL: MemoryGraphLocation.graphURL(for: workspace.workspaceURL))
            let original = try await store.write(content: "Summary: Widget offset is one.\nTimestamp: 2026-01-01", category: .fact, tags: ["manual"])
            let snapshot = try #require(try await store.learningSnapshot(query: "Widget"))
            #expect(!(try await store.commitLearning(content: "Summary: Verified Widget offset.", existingID: UUID().uuidString,
                snapshot: snapshot, permit: MemoryLearningPermit(), event: UUID())))
            _ = try await store.setArchived(true, id: original.entry.id)
            #expect(!(try await store.commitLearning(content: "Summary: Verified Widget offset.", existingID: original.entry.id,
                snapshot: snapshot, permit: MemoryLearningPermit(), event: UUID())))
            let permit = MemoryLearningPermit()
            permit.invalidate()
            let fresh = try #require(try await store.learningSnapshot())
            #expect(!(try await store.commitLearning(content: "Summary: Verified Widget offset.", existingID: nil,
                snapshot: fresh, permit: permit, event: UUID())))
            #expect(try await store.entry(id: original.entry.id)?.active == false)
        }
    }

    @Test func boundedLookupDoesNotDisableMatureStoreAndUpdatePreservesManualInformation() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let store = try await MemoryGraphStore.open(graphURL: MemoryGraphLocation.graphURL(for: workspace.workspaceURL))
            for index in 0..<42 {
                _ = try await store.write(content: "Summary: Unrelated subsystem \(index).", category: .fact, tags: [])
            }
            let entry = try await store.write(content: "Summary: Widget is one-based.\nTimestamp: 2026-01-01\nSources: old-ref", category: .fact, tags: ["manual"])
            _ = try await store.write(content: "password=not-for-the-model", category: .fact, tags: [])
            let snapshot = try #require(try await store.learningSnapshot(query: "Widget"))
            #expect(snapshot.entries.contains { $0.id == entry.entry.id })
            #expect(!snapshot.entries.contains { $0.content.contains("password") })
            #expect(snapshot.comparison.count == 44)
            #expect(try await store.commitLearning(content: "Summary: Widget handles empty input.\nSources: new-ref", existingID: entry.entry.id,
                snapshot: snapshot, permit: MemoryLearningPermit(), event: UUID()))
            let updated = try #require(try await store.entry(id: entry.entry.id))
            #expect(updated.content.contains("one-based"))
            #expect(updated.content.contains("old-ref"))
            #expect(updated.content.contains("new-ref"))
            #expect(updated.content.contains("Timestamp: 2026-01-01"))
            #expect(updated.tags == ["manual"])
        }
    }
}

extension ConservativeMemoryLearningStoreTests {
    @Test func retiredIncarnationCannotCommitAndRotationCannotReplenishQuota() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let store = try await MemoryGraphStore.open(graphURL: MemoryGraphLocation.graphURL(for: workspace.workspaceURL))
            let old = MemoryLearningPermit()
            let pending = try #require(try await store.learningSnapshot())
            let current = old.renewed()
            #expect(!(try await store.commitLearning(content: "Summary: Stale proposal.", existingID: nil,
                snapshot: pending, permit: old, event: UUID())))
            #expect(try await store.entries(includeArchived: true, limit: 10).isEmpty)
            for index in 0..<3 {
                let snapshot = try #require(try await store.learningSnapshot())
                #expect(try await store.commitLearning(content: "Summary: Verified component \(index).", existingID: nil,
                    snapshot: snapshot, permit: current, event: UUID()))
            }
            let rebuilt = current.renewed()
            let snapshot = try #require(try await store.learningSnapshot())
            #expect(!(try await store.commitLearning(content: "Summary: Fourth mutation.", existingID: nil,
                snapshot: snapshot, permit: rebuilt, event: UUID())))
            #expect(try await store.entries(includeArchived: true, limit: 10).count == 3)
        }
    }
}
