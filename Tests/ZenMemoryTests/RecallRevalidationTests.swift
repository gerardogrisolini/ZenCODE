//
//  RecallRevalidationTests.swift
//  ZenMemoryTests
//
//  Deterministic coverage for the recall re-validation contract: after the
//  selector `await`, a concurrent forget/archive can make previously retrieved
//  candidates stale. The maintenance transaction must re-check them against the
//  current draft and neither persist dangling edges nor return eliminated
//  entries.
//

import Foundation
import Testing
@testable import ZenMemory

// MARK: - Selector test double

/// Selector that parks inside `select` until ``release()`` is called.
///
/// This deterministically opens the reentrancy window that the default
/// ``TopScoreMemorySelector`` only exposes probabilistically: while the
/// selector is blocked the ``ZenMemory`` actor is free to process a concurrent
/// mutation, so the test can arrange exactly the interleaving that produces
/// stale candidates.
private actor BlockingSelector: MemorySelector {
    private var entered = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    func select(
        context: String,
        candidates: [MemoryCandidate],
        limit: Int
    ) async throws -> [MemoryCandidate] {
        entered = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parked.append(continuation)
        }
        // Return every candidate so the maintenance path exercises co-relevance
        // linking and confidence boost/decay for all of them — including the
        // entries that will be stale by the time the selector resumes.
        return Array(candidates.prefix(limit))
    }

    func waitUntilEntered() async {
        while !entered {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func release() {
        let toResume = parked
        parked.removeAll()
        for continuation in toResume { continuation.resume() }
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

// MARK: - linkMemories defensive guard

@Test func linkMemoriesNoOpsForMissingOrInactiveNodes() {
    var graph = MemoryGraph()
    graph.addMemory(MemoryEntry(id: "alive", category: .fact, content: "alive entry"))
    graph.addMemory(MemoryEntry(id: "buddy", category: .fact, content: "buddy entry"))
    var archived = MemoryEntry(id: "archived", category: .fact, content: "archived entry")
    archived.active = false
    graph.addMemory(archived)

    // Missing endpoint — no edge, no reverse-edge, no counter bump.
    graph.linkMemories(from: "alive", to: "ghost", weight: 0.8)
    #expect(graph.outgoingEdges(from: "alive").isEmpty)
    #expect(graph.incomingNodes(to: "ghost").isEmpty)
    #expect(graph.metadata.linkDiscoveryCount == 0)

    // Inactive endpoint — same: no-op.
    graph.linkMemories(from: "alive", to: "archived", weight: 0.8)
    #expect(graph.outgoingEdges(from: "alive").isEmpty)
    #expect(graph.incomingNodes(to: "archived").isEmpty)
    #expect(graph.metadata.linkDiscoveryCount == 0)

    // Valid active pair — edge created normally.
    graph.linkMemories(from: "alive", to: "buddy", weight: 0.7)
    let edges = graph.outgoingEdges(from: "alive")
    #expect(edges.contains { edge in
        if case .relatesTo(let weight) = edge.kind, edge.target == "buddy" {
            return weight == 0.7
        }
        return false
    })
    #expect(graph.incomingNodes(to: "buddy").contains("alive"))
    #expect(graph.metadata.linkDiscoveryCount == 1)
}

// MARK: - Recall re-validation under concurrent mutation

@Test func recallRevalidatesAfterConcurrentForgetAndArchive() async throws {
    let selector = BlockingSelector()
    let memory = ZenMemory(selector: selector)

    _ = try await memory.remember("alpha fact about swift actors", tags: ["swift"], id: "alpha")
    _ = try await memory.remember("beta fact about swift structs", tags: ["swift"], id: "beta")
    _ = try await memory.remember("gamma fact about swift classes", tags: ["swift"], id: "gamma")

    // Start recall — it parks inside the BlockingSelector, leaving the
    // ZenMemory actor free to process concurrent mutations.
    let recallTask = Task<MemoryRecallResult, Error> {
        try await memory.recallDetailed("swift")
    }

    // Wait until the selector has genuinely entered so the mutations below
    // land *during* the await, not before it.
    await selector.waitUntilEntered()

    // Forget alpha (removed entirely) and archive beta (deactivated but still
    // present) while the selector is blocked.
    _ = try await memory.forget(id: "alpha")
    try await memory.transaction { graph in
        graph.memories["beta"]?.active = false
    }

    // Release the selector — recall resumes with candidates that include the
    // now-stale alpha and beta.
    await selector.release()
    let result = try await recallTask.value

    // The returned result must not include forgotten or archived entries.
    let selectedIDs = Set(result.selected.map(\.memory.id))
    #expect(!selectedIDs.contains("alpha"))
    #expect(!selectedIDs.contains("beta"))
    #expect(selectedIDs.contains("gamma"))

    let candidateIDs = Set(result.candidates.map(\.memory.id))
    #expect(!candidateIDs.contains("alpha"))
    #expect(!candidateIDs.contains("beta"))
    #expect(candidateIDs.contains("gamma"))

    // No dangling relatesTo edges: every such edge must connect two active,
    // existing memory nodes. Tag and cluster edges are excluded.
    let snapshot = await memory.snapshot()
    for (source, edgeList) in snapshot.edges {
        for edge in edgeList {
            guard case .relatesTo = edge.kind else { continue }
            #expect(
                snapshot.memories[source]?.active == true,
                "relatesTo edge originates from a missing or inactive node: \(source)"
            )
            #expect(
                snapshot.memories[edge.target]?.active == true,
                "relatesTo edge targets a missing or inactive node: \(edge.target)"
            )
        }
    }
    // No co-relevance links were attempted for the stale entries.
    #expect(snapshot.metadata.linkDiscoveryCount == 0)
}

@Test func recallRevalidatesAfterConcurrentScopeChange() async throws {
    let selector = BlockingSelector()
    var config = ZenMemoryConfiguration()
    // Force scope .project so an entry re-scoped to .global drops out.
    let memory = ZenMemory(selector: selector, configuration: config)
    _ = try await memory.remember("alpha project fact", tags: ["topic"], scope: .project, id: "alpha")
    _ = try await memory.remember("beta project fact", tags: ["topic"], scope: .project, id: "beta")

    let recallTask = Task<MemoryRecallResult, Error> {
        try await memory.recallDetailed("topic", scope: .project)
    }

    await selector.waitUntilEntered()

    // Re-scope alpha to .global while the selector is blocked: it is still
    // active and still present, but no longer in the .project scope.
    try await memory.transaction { graph in
        guard var entry = graph.memories["alpha"] else { return }
        entry.scope = .global
        graph.addMemory(entry)
    }

    await selector.release()
    let result = try await recallTask.value

    let selectedIDs = Set(result.selected.map(\.memory.id))
    #expect(!selectedIDs.contains("alpha"))
    #expect(selectedIDs.contains("beta"))
}

// MARK: - Normal recall semantics preserved

@Test func recallMaintenancePreservesConfidenceAccessAndLinksOnStableGraph() async throws {
    let memory = ZenMemory()

    _ = try await memory.remember("alpha fact about swift", tags: ["swift"], id: "alpha")
    _ = try await memory.remember("beta fact about swift", tags: ["swift"], id: "beta")

    let before = await memory.snapshot()
    let result = try await memory.recallDetailed("swift")
    #expect(result.selected.count >= 2)

    let after = await memory.snapshot()

    // Selected entries had their confidence boosted and access count bumped.
    for candidate in result.selected {
        let id = candidate.memory.id
        let beforeEntry = try #require(before.memories[id])
        let afterEntry = try #require(after.memories[id])
        #expect(afterEntry.confidence >= beforeEntry.confidence)
        #expect(afterEntry.accessCount == beforeEntry.accessCount &+ 1)
    }

    // Co-relevance links were created between the selected pair (both directions).
    if result.selected.count >= 2 {
        let a = result.selected[0].memory.id
        let b = result.selected[1].memory.id
        let forward = after.outgoingEdges(from: a).contains { edge in
            if case .relatesTo = edge.kind, edge.target == b { return true }
            return false
        }
        let backward = after.outgoingEdges(from: b).contains { edge in
            if case .relatesTo = edge.kind, edge.target == a { return true }
            return false
        }
        #expect(forward)
        #expect(backward)
    }

    // Retrieval count was committed.
    #expect(after.metadata.retrievalCount == before.metadata.retrievalCount &+ 1)
    // linkDiscoveryCount reflects the two co-relevance links created.
    #expect(after.metadata.linkDiscoveryCount == before.metadata.linkDiscoveryCount &+ 2)
}
