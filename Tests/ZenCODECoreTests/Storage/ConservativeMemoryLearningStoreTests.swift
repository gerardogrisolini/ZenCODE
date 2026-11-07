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
