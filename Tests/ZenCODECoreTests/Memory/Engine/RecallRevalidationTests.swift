//
//  RecallRevalidationTests.swift
//  ZenCODECoreTests (memory engine)
//
//  Deterministic coverage for the recall re-validation contract: after the
//  selector `await`, a concurrent forget/archive can make previously retrieved
//  candidates stale. The maintenance transaction must re-check them against the
//  current draft and neither persist dangling edges nor return eliminated
//  entries.
//

import Foundation
import Testing
@testable import ZenCODECore

// MARK: - Selector test double

/// Selector that parks inside `select` until ``release()`` is called.
///
/// This deterministically opens the reentrancy window that the default
/// ``TopScoreMemorySelector`` only exposes probabilistically: while the
/// selector is blocked the ``MemoryEngine`` actor is free to process a concurrent
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

    /// Non-blocking view of the same flag, for bounded waits.
    var hasEntered: Bool { entered }

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
    graph.addMemory(EngineMemoryEntry(id: "alive", category: .fact, content: "alive entry"))
    graph.addMemory(EngineMemoryEntry(id: "buddy", category: .fact, content: "buddy entry"))
    var archived = EngineMemoryEntry(id: "archived", category: .fact, content: "archived entry")
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
    let memory = MemoryEngine(selector: selector)

    _ = try await memory.remember("alpha fact about swift actors", tags: ["swift"], id: "alpha")
    _ = try await memory.remember("beta fact about swift structs", tags: ["swift"], id: "beta")
    _ = try await memory.remember("gamma fact about swift classes", tags: ["swift"], id: "gamma")

    // Start recall — it parks inside the BlockingSelector, leaving the
    // MemoryEngine actor free to process concurrent mutations.
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

@Test func recallRevalidatesAgainstCrossProcessDurableGraph() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("recall-cross-process-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("memory.json")

    let writer = try await MemoryEngine.open(
        persistence: JSONMemoryPersistence(url: file)
    )
    _ = try await writer.remember(
        "actors protect mutable state",
        tags: ["swift"],
        id: "a"
    )

    let selector = BlockingSelector()
    let reader = try await MemoryEngine.open(
        persistence: JSONMemoryPersistence(url: file),
        selector: selector
    )
    let recallTask = Task<MemoryRecallResult, Error> {
        try await reader.recallDetailed("actors")
    }
    await selector.waitUntilEntered()

    // The reader's local graph still contains `a`, but another engine commits
    // its removal while the selector is suspended. Revalidation must happen
    // against the durable graph under the same persistence lock as checkpoint.
    _ = try await writer.forget(id: "a")

    await selector.release()
    let result = try await recallTask.value
    #expect(result.candidates.isEmpty)
    #expect(result.selected.isEmpty)
    #expect(await reader.snapshot().memories["a"] == nil)

    let persisted = try await JSONMemoryPersistence(url: file).load()
    #expect(persisted.memories["a"] == nil)
}

@Test func recallReturnsCurrentCrossProcessUpdateWithoutCheckpointSave() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("recall-cross-process-update-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("memory.json")

    let writer = try await MemoryEngine.open(
        persistence: JSONMemoryPersistence(url: file)
    )
    _ = try await writer.remember(
        "actors protect mutable state",
        tags: ["swift"],
        id: "a"
    )

    let selector = BlockingSelector()
    let reader = try await MemoryEngine.open(
        persistence: JSONMemoryPersistence(url: file),
        selector: selector
    )
    let recallTask = Task<MemoryRecallResult, Error> {
        try await reader.recallDetailed("actors")
    }
    await selector.waitUntilEntered()

    try await writer.transaction { graph in
        guard var entry = graph.memories["a"] else { return }
        entry.content = "actors now protect updated state"
        entry.refreshSearchText()
        graph.addMemory(entry)
    }
    let durableBeforeRecall = try Data(contentsOf: file)

    await selector.release()
    let result = try await recallTask.value
    let candidate = try #require(result.candidates.first { $0.memory.id == "a" })
    #expect(candidate.memory.content == "actors now protect updated state")
    #expect((await reader.snapshot()).memories["a"]?.content == "actors now protect updated state")

    // One pending recall is below the default checkpoint threshold, so the
    // cross-process reload/revalidation must not rewrite the durable bytes.
    let durableAfterRecall = try Data(contentsOf: file)
    #expect(durableAfterRecall == durableBeforeRecall)
}

@Test func recallRevalidatesAfterConcurrentScopeChange() async throws {
    let selector = BlockingSelector()
    let config = MemoryEngineConfiguration()
    // Force scope .project so an entry re-scoped to .global drops out.
    let memory = MemoryEngine(selector: selector, configuration: config)
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
    let memory = MemoryEngine()

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


// MARK: - Cancelled recall: the two windows that can leak maintenance
//
// A recall that its turn coordinator abandons must leave *nothing* behind. Two
// distinct windows can violate that, and each test below opens exactly one of
// them deterministically instead of relying on timing:
//
//  1. selector → write lock: the recall has candidates but has not decided
//     anything durable yet;
//  2. inside the maintenance transaction: the recall has decided what to record
//     and is awaiting the durable store.
//
// The discriminating assertion is not "no file was written by the recall" — a
// recall below the checkpoint threshold never writes anyway. It is that a
// *later, healthy* write cannot resurrect the abandoned maintenance, which is
// exactly what an intent recorded before the cancellable point would do.

/// Transactional persistence whose `transaction` can be parked once, on demand.
///
/// `JSONMemoryPersistence` offers no seam inside its lock, so this double
/// reproduces its contract (reload, run body, commit only when the draft
/// changed, and check cancellation *before* the commit and never after it)
/// while letting a test stop the world in the middle of the durable window.
private actor GatedTransactionalPersistence: MemoryTransactionalPersistence {
    struct Unavailable: Error {}

    private var stored: MemoryGraph
    private var armed = false
    private var failNext = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private(set) var gateEntered = false
    private(set) var commits = 0

    init(graph: MemoryGraph = MemoryGraph()) {
        stored = graph
    }

    func load() async throws -> MemoryGraph { stored }

    func save(_ graph: MemoryGraph) async throws {
        stored = graph
        commits += 1
    }

    func transaction<T: Sendable>(
        initialGraph: MemoryGraph?,
        _ body: @Sendable (inout MemoryGraph) throws -> T
    ) async throws -> (result: T, graph: MemoryGraph, didChange: Bool) {
        if armed {
            armed = false
            gateEntered = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parked.append(continuation)
            }
        }
        if failNext {
            failNext = false
            throw Unavailable()
        }
        var draft = stored
        let result = try body(&draft)
        let didChange = draft != stored
        if didChange {
            // Mirrors the production store: the last cancellable point sits
            // before the commit, so an error is never reported for state that
            // is already durable.
            try Task.checkCancellation()
            stored = draft
            commits += 1
        }
        return (result, draft, didChange)
    }

    /// Parks the *next* transaction only, so test setup commits normally.
    func armGate() { armed = true }

    /// Fails the next transaction without cancelling anything.
    func armFailure() { failNext = true }

    func openGate() {
        let waiting = parked
        parked.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    func snapshot() -> MemoryGraph { stored }
}

/// Polls `condition` until it holds, returning `false` if the bound elapses.
/// Every wait in these tests is bounded so a regression fails instead of hanging.
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// Window 1 — cancelled between the selector and the maintenance decision, on
/// the real JSON store. The abandoned recall must not survive as an intent that
/// the next explicit write makes durable.
@Test func recallCancelledAfterSelectionLeavesNothingForALaterWriteToPersist() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cancelled-recall-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("memory.json")
    let selector = BlockingSelector()
    var configuration = MemoryEngineConfiguration()
    configuration.recallMaintenanceCheckpointSize = 1
    let memory = try await MemoryEngine.open(
        persistence: JSONMemoryPersistence(url: file),
        selector: selector,
        configuration: configuration
    )
    _ = try await memory.remember("actors protect mutable state", id: "actors")
    // Remove the durable file so any later persistence is attributable to this
    // test's own actions rather than to the setup write.
    try FileManager.default.removeItem(at: file)

    let recall = Task<MemoryRecallResult, Error> {
        try await memory.recallDetailed("actors")
    }
    guard await waitUntil({ await selector.hasEntered }) else {
        recall.cancel()
        await selector.release()
        Issue.record("Selector never entered; the cancellation window never opened.")
        return
    }
    recall.cancel()
    await selector.release()

    await #expect(throws: CancellationError.self) {
        _ = try await recall.value
    }
    // A recall that never returned must not have published a checkpoint...
    #expect(!FileManager.default.fileExists(atPath: file.path))
    // ...and no intent may be waiting for the next explicit durability
    // boundary either.
    try await memory.flushRecallMaintenance()
    #expect(!FileManager.default.fileExists(atPath: file.path))

    // The discriminating half: a healthy write afterwards persists its own
    // change and nothing else. A maintenance intent recorded before the
    // cancellable point would ride along here and bump the retrieval counter.
    _ = try await memory.remember("channels are not actors", id: "channels")
    let durable = try await JSONMemoryPersistence(url: file).load()
    #expect(durable.memories["channels"] != nil)
    #expect(durable.metadata.retrievalCount == 0)
    #expect(durable.metadata.linkDiscoveryCount == 0)
    let reloadedActors = try #require(durable.memories["actors"])
    #expect(reloadedActors.accessCount == 0)
}

/// Window 2 — cancelled while the maintenance transaction is already running.
/// The engine has decided what it would record; the durable store has not
/// accepted it yet. Engine state must roll back completely.
@Test func recallCancelledInsideMaintenanceTransactionRollsBackCompletely() async throws {
    let selector = BlockingSelector()
    let persistence = GatedTransactionalPersistence()
    var configuration = MemoryEngineConfiguration()
    // Stay below the checkpoint threshold: the failure this guards against is
    // an in-memory intent surviving, not a premature save.
    configuration.recallMaintenanceCheckpointSize = 8
    let memory = try await MemoryEngine.open(
        persistence: persistence,
        selector: selector,
        configuration: configuration
    )
    _ = try await memory.remember("alpha fact about swift actors", tags: ["swift"], id: "alpha")
    _ = try await memory.remember("beta fact about swift structs", tags: ["swift"], id: "beta")
    let commitsBeforeRecall = await persistence.commits

    await persistence.armGate()
    let recall = Task<MemoryRecallResult, Error> {
        try await memory.recallDetailed("swift")
    }
    guard await waitUntil({ await selector.hasEntered }) else {
        recall.cancel()
        await selector.release()
        Issue.record("Selector never entered.")
        return
    }
    await selector.release()
    // Cancel only once the recall is genuinely inside the durable window.
    guard await waitUntil({ await persistence.gateEntered }) else {
        recall.cancel()
        await persistence.openGate()
        Issue.record("Maintenance transaction never started.")
        return
    }
    recall.cancel()
    await persistence.openGate()

    await #expect(throws: CancellationError.self) {
        _ = try await recall.value
    }
    #expect(await persistence.commits == commitsBeforeRecall)

    // Nothing pending: an explicit flush has no batch to write...
    try await memory.flushRecallMaintenance()
    #expect(await persistence.commits == commitsBeforeRecall)

    // ...and the next real write carries only its own change.
    _ = try await memory.remember("gamma fact about swift classes", tags: ["swift"], id: "gamma")
    let durable = await persistence.snapshot()
    #expect(durable.memories["gamma"] != nil)
    #expect(durable.metadata.retrievalCount == 0)
    #expect(durable.metadata.linkDiscoveryCount == 0)
    // Only co-relevance edges are maintenance; `hasTag` edges come from the
    // explicit writes above and must stay.
    let coRelevance = durable.outgoingEdges(from: "alpha").contains { edge in
        if case .relatesTo = edge.kind { return true }
        return false
    }
    #expect(!coRelevance)
    let alpha = try #require(durable.memories["alpha"])
    #expect(alpha.accessCount == 0)
}

/// A recall that is *not* cancelled must still record and replay its
/// maintenance: the rollback above must not have turned into "never record".
@Test func healthyRecallStillRecordsMaintenanceForTheNextWrite() async throws {
    let persistence = GatedTransactionalPersistence()
    var configuration = MemoryEngineConfiguration()
    configuration.recallMaintenanceCheckpointSize = 8
    let memory = try await MemoryEngine.open(
        persistence: persistence,
        configuration: configuration
    )
    _ = try await memory.remember("alpha fact about swift actors", tags: ["swift"], id: "alpha")
    _ = try await memory.remember("beta fact about swift structs", tags: ["swift"], id: "beta")

    let result = try await memory.recallDetailed("swift")
    #expect(!result.candidates.isEmpty)

    _ = try await memory.remember("gamma fact about swift classes", tags: ["swift"], id: "gamma")
    let durable = await persistence.snapshot()
    #expect(durable.metadata.retrievalCount == 1)
    let alpha = try #require(durable.memories["alpha"])
    #expect(alpha.accessCount == 1)
}

/// Failing is not the same as being cancelled, and the rollback must not blur
/// the two. When only the store was unavailable the retrieval really happened,
/// so the batch stays visible and retryable — the contract a failed explicit
/// flush already honours.
@Test func recallWhoseCheckpointFailsKeepsMaintenanceRetryable() async throws {
    let persistence = GatedTransactionalPersistence()
    var configuration = MemoryEngineConfiguration()
    configuration.recallMaintenanceCheckpointSize = 1
    let memory = try await MemoryEngine.open(
        persistence: persistence,
        configuration: configuration
    )
    _ = try await memory.remember("alpha fact about swift actors", tags: ["swift"], id: "alpha")
    let before = await memory.snapshot()

    await persistence.armFailure()
    await #expect(throws: GatedTransactionalPersistence.Unavailable.self) {
        _ = try await memory.recallDetailed("swift")
    }

    // Visible in memory...
    let visible = await memory.snapshot()
    #expect(visible.metadata.retrievalCount == before.metadata.retrievalCount &+ 1)
    #expect(await persistence.snapshot().metadata.retrievalCount == 0)

    // ...and still queued, so the next durability boundary persists it.
    try await memory.flushRecallMaintenance()
    #expect(
        await persistence.snapshot().metadata.retrievalCount == visible.metadata.retrievalCount
    )
}
