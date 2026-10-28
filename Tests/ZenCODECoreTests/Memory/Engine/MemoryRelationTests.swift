//
//  MemoryRelationTests.swift
//  ZenCODECoreTests (memory engine)
//
//  The co-relevance (`relatesTo`) lever: birth weight, reinforcement, the
//  per-entry cap with symmetric eviction, pruning of existing graphs, and the
//  recall maintenance path (direct and replayed) that drives it.
//

import Foundation
import Testing
@testable import ZenCODECore

// MARK: - Helpers

private func makeGraph(_ ids: [String], tags: [String] = []) -> MemoryGraph {
    var graph = MemoryGraph()
    for id in ids {
        graph.addMemory(EngineMemoryEntry(id: id, category: .fact, content: "entry \(id)", tags: tags))
    }
    return graph
}

private func numbered(_ prefix: String, _ range: Range<Int>) -> [String] {
    range.map { String(format: "\(prefix)%02d", $0) }
}

/// Outgoing `relatesTo` edges of `id`, in array order.
private func relations(_ graph: MemoryGraph, from id: String) -> [(target: String, weight: Float)] {
    graph.outgoingEdges(from: id).compactMap { edge in
        edge.kind.relationWeight.map { (edge.target, $0) }
    }
}

private func relationTargets(_ graph: MemoryGraph, from id: String) -> [String] {
    relations(graph, from: id).map(\.target)
}

private func weight(_ graph: MemoryGraph, _ from: String, _ to: String) -> Float? {
    relations(graph, from: from).first { $0.target == to }?.weight
}

private func isApproximately(_ value: Float?, _ expected: Float) -> Bool {
    value.map { abs($0 - expected) < 0.0001 } ?? false
}

/// Both directions of a legacy-style link, created the way old builds did.
private func linkLegacy(_ graph: inout MemoryGraph, _ first: String, _ second: String, weight: Float = 0.7) {
    graph.addEdge(from: first, to: second, kind: .relatesTo(weight: weight))
    graph.addEdge(from: second, to: first, kind: .relatesTo(weight: weight))
}

/// The reverse index equals the one a rebuild from `edges` would produce, with
/// no repeated entry.
private func reverseIndexIsConsistent(_ graph: MemoryGraph) -> Bool {
    var rebuilt = graph
    rebuilt.rebuildReverseEdges()
    let unique = graph.reverseEdges.values.allSatisfy { Set($0).count == $0.count }
    return unique && graph.reverseEdges.mapValues(Set.init) == rebuilt.reverseEdges.mapValues(Set.init)
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Policy

@Suite("Memory relation policy")
struct MemoryRelationPolicyTests {
    @Test func defaultPolicyHoldsTheApprovedValues() {
        let policy = MemoryRelationPolicy.default
        #expect(policy.maximumLinksPerMemory == 12)
        #expect(policy.initialWeight == 0.7)
        #expect(policy.reinforcementStep == 0.05)
        #expect(policy.maximumWeight == 0.9)
        #expect(MemoryEngineConfiguration().relationPolicy == .default)
    }

    @Test func reinforcedWeightClimbsByOneStepAndStopsAtTheMaximum() {
        let policy = MemoryRelationPolicy.default
        #expect(isApproximately(policy.reinforcedWeight(from: 0.7), 0.75))
        #expect(isApproximately(policy.reinforcedWeight(from: 0.85), 0.9))
        #expect(isApproximately(policy.reinforcedWeight(from: 0.88), 0.9))
        #expect(policy.reinforcedWeight(from: 0.9) == 0.9)
    }

    @Test func reinforcedWeightNeverLowersAHeavierExistingWeight() {
        let policy = MemoryRelationPolicy.default
        #expect(policy.reinforcedWeight(from: 1) == 1)
        #expect(policy.reinforcedWeight(from: 0.93) == 0.93)
    }

    @Test func initClampsNonsensicalValues() {
        let policy = MemoryRelationPolicy(
            maximumLinksPerMemory: 0,
            initialWeight: 2,
            reinforcementStep: -1,
            maximumWeight: 0.1
        )
        #expect(policy.maximumLinksPerMemory == 1)
        #expect(policy.initialWeight == 1)
        #expect(policy.reinforcementStep == 0)
        #expect(policy.maximumWeight == policy.initialWeight)
    }
}

// MARK: - Graph: creation and reinforcement

@Suite("Memory graph relations")
struct MemoryGraphRelationTests {
    @Test func newPairIsBornAtTheInitialWeightInBothDirections() {
        var graph = makeGraph(["a", "b"])

        let created = graph.reinforceRelation(between: "a", and: "b")

        #expect(created)
        #expect(weight(graph, "a", "b") == 0.7)
        #expect(weight(graph, "b", "a") == 0.7)
        #expect(graph.incomingNodes(to: "b") == ["a"])
        #expect(graph.incomingNodes(to: "a") == ["b"])
        #expect(graph.metadata.linkDiscoveryCount == 2)
        #expect(reverseIndexIsConsistent(graph))
    }

    @Test func repeatedCoSelectionRaisesTheWeightByOneStepUpToTheMaximum() {
        var graph = makeGraph(["a", "b"])
        let expected: [Float] = [0.7, 0.75, 0.8, 0.85, 0.9, 0.9, 0.9]

        for want in expected {
            graph.reinforceRelation(between: "a", and: "b")
            #expect(isApproximately(weight(graph, "a", "b"), want))
            #expect(isApproximately(weight(graph, "b", "a"), want))
        }
        #expect(weight(graph, "a", "b") == 0.9)
        #expect(weight(graph, "b", "a") == 0.9)
        // Reversed argument order is the same pair.
        graph.reinforceRelation(between: "b", and: "a")
        #expect(weight(graph, "a", "b") == 0.9)
        #expect(graph.metadata.linkDiscoveryCount == 16)
    }

    @Test func reinforcementKeepsOneEdgePerDirectionInPlace() {
        var graph = makeGraph(["a", "b", "c", "d"])
        for other in ["b", "c", "d"] {
            graph.reinforceRelation(between: "a", and: other)
        }
        #expect(relationTargets(graph, from: "a") == ["b", "c", "d"])

        graph.reinforceRelation(between: "a", and: "b")

        // Same slots, so the creation order the cap relies on is preserved.
        #expect(relationTargets(graph, from: "a") == ["b", "c", "d"])
        #expect(relations(graph, from: "a").map(\.weight) == [0.75, 0.7, 0.7])
        #expect(relationTargets(graph, from: "b") == ["a"])
        #expect(graph.edgeCount == 6)
        #expect(reverseIndexIsConsistent(graph))
    }

    @Test func aLegacyHeavierWeightIsNeverLowered() {
        var symmetric = makeGraph(["a", "b"])
        linkLegacy(&symmetric, "a", "b", weight: 1)
        symmetric.reinforceRelation(between: "a", and: "b")
        #expect(weight(symmetric, "a", "b") == 1)
        #expect(weight(symmetric, "b", "a") == 1)
        #expect(symmetric.edgeCount == 2)

        // One direction legacy 1.0, the other 0.7: the pair takes the heavier.
        var mixed = makeGraph(["a", "b"])
        mixed.addEdge(from: "a", to: "b", kind: .relatesTo(weight: 0.7))
        mixed.addEdge(from: "b", to: "a", kind: .relatesTo(weight: 1))
        mixed.reinforceRelation(between: "a", and: "b")
        #expect(weight(mixed, "a", "b") == 1)
        #expect(weight(mixed, "b", "a") == 1)
        #expect(mixed.edgeCount == 2)
    }

    @Test func aMissingDirectionIsInsertedAtTheReinforcedWeight() {
        var graph = makeGraph(["a", "b"])
        graph.addEdge(from: "a", to: "b", kind: .relatesTo(weight: 0.8))

        graph.reinforceRelation(between: "b", and: "a")

        #expect(isApproximately(weight(graph, "a", "b"), 0.85))
        #expect(isApproximately(weight(graph, "b", "a"), 0.85))
        #expect(graph.edgeCount == 2)
        #expect(reverseIndexIsConsistent(graph))
    }

    @Test func missingInactiveOrIdenticalEndpointsAreANoOp() {
        var graph = makeGraph(["alive", "buddy"])
        var archived = EngineMemoryEntry(id: "archived", category: .fact, content: "archived entry")
        archived.active = false
        graph.addMemory(archived)
        let before = graph

        let results = [
            graph.reinforceRelation(between: "alive", and: "ghost"),
            graph.reinforceRelation(between: "ghost", and: "alive"),
            graph.reinforceRelation(between: "alive", and: "archived"),
            graph.reinforceRelation(between: "archived", and: "alive"),
            graph.reinforceRelation(between: "alive", and: "alive"),
        ]

        #expect(results == [false, false, false, false, false])
        #expect(graph == before)
        #expect(graph.metadata.linkDiscoveryCount == 0)
    }

    // MARK: Cap

    private static func hubGraph(neighbours count: Int, tags: [String] = []) -> MemoryGraph {
        var graph = makeGraph(["hub"] + numbered("n", 0..<count))
        if !tags.isEmpty {
            for tag in tags { graph.addTag(tag, to: "hub") }
        }
        return graph
    }

    @Test func theCapEvictsTheWeakestThenTheOldestRelation() {
        var graph = Self.hubGraph(neighbours: 13)
        for id in numbered("n", 0..<12) {
            graph.reinforceRelation(between: "hub", and: id)
        }
        // n00 becomes stronger, so n01 is now the oldest of the weakest. Just
        // reinforcing an existing link never evicts anything.
        graph.reinforceRelation(between: "hub", and: "n00")
        #expect(relations(graph, from: "hub").count == 12)

        graph.reinforceRelation(between: "hub", and: "n12")

        let expected = ["n00"] + numbered("n", 2..<12) + ["n12"]
        #expect(relationTargets(graph, from: "hub") == expected)
        #expect(isApproximately(weight(graph, "hub", "n00"), 0.75))
        #expect(weight(graph, "hub", "n12") == 0.7)
        #expect(weight(graph, "n12", "hub") == 0.7)
        #expect(reverseIndexIsConsistent(graph))
    }

    @Test func theCapEvictsEvenWhenTheWeakestIsHeavierThanTheNewLink() {
        var graph = Self.hubGraph(neighbours: 13)
        for id in numbered("n", 0..<12) {
            for _ in 0..<5 { graph.reinforceRelation(between: "hub", and: id) }
        }
        #expect(relations(graph, from: "hub").allSatisfy { $0.weight == 0.9 })

        graph.reinforceRelation(between: "hub", and: "n12")

        // The oldest 0.9 link made room for a 0.7 newcomer.
        #expect(relationTargets(graph, from: "hub") == numbered("n", 1..<12) + ["n12"])
        #expect(weight(graph, "hub", "n12") == 0.7)
        #expect(relations(graph, from: "hub").count == 12)
    }

    @Test func evictionRemovesTheMirrorLinkAndItsReverseIndexEntries() {
        var graph = Self.hubGraph(neighbours: 13)
        for id in numbered("n", 0..<13) {
            graph.reinforceRelation(between: "hub", and: id)
        }

        #expect(relationTargets(graph, from: "hub") == numbered("n", 1..<13))
        #expect(relations(graph, from: "n00").isEmpty)
        #expect(graph.edges["n00"] == nil)
        #expect(!graph.incomingNodes(to: "n00").contains("hub"))
        #expect(!graph.incomingNodes(to: "hub").contains("n00"))
        #expect(reverseIndexIsConsistent(graph))
    }

    @Test func edgesOfOtherKindsBetweenTheSamePairSurviveEviction() {
        var graph = Self.hubGraph(neighbours: 14, tags: ["topic"])
        // n00: a one-way supersedes edge. n01: a two-way contradiction.
        graph.addEdge(from: "hub", to: "n00", kind: .supersedes)
        graph.markContradiction("hub", "n01")
        // n02: derivedFrom the other way round only.
        graph.addEdge(from: "n02", to: "hub", kind: .derivedFrom)
        for id in numbered("n", 0..<12) {
            graph.reinforceRelation(between: "hub", and: id)
        }

        graph.reinforceRelation(between: "hub", and: "n12") // evicts n00
        graph.reinforceRelation(between: "hub", and: "n13") // evicts n01
        graph.reinforceRelation(between: "hub", and: "n12") // reinforce only

        #expect(!relationTargets(graph, from: "hub").contains("n00"))
        #expect(!relationTargets(graph, from: "hub").contains("n01"))
        #expect(relations(graph, from: "n00").isEmpty)
        #expect(relations(graph, from: "n01").isEmpty)
        // The non-relatesTo edges are still there, with the index entries they need.
        #expect(graph.outgoingEdges(from: "hub").contains { $0.target == "n00" && $0.kind == .supersedes })
        #expect(graph.outgoingEdges(from: "hub").contains { $0.target == "n01" && $0.kind == .contradicts })
        #expect(graph.outgoingEdges(from: "n01").contains { $0.target == "hub" && $0.kind == .contradicts })
        #expect(graph.incomingNodes(to: "n00") == ["hub"])
        #expect(graph.incomingNodes(to: "n01").contains("hub"))
        #expect(graph.incomingNodes(to: "hub").contains("n01"))
        // ...while the dropped mirror leaves no stale entry behind.
        #expect(!graph.incomingNodes(to: "hub").contains("n00"))
        // n02 keeps its relatesTo link and its derivedFrom edge.
        #expect(weight(graph, "hub", "n02") != nil)
        #expect(graph.outgoingEdges(from: "n02").contains { $0.target == "hub" && $0.kind == .derivedFrom })
        // Tags are never touched.
        #expect(graph.outgoingEdges(from: "hub").contains { $0.target == "tag:topic" && $0.kind == .hasTag })
        #expect(graph.incomingNodes(to: "tag:topic") == ["hub"])
        #expect(reverseIndexIsConsistent(graph))
    }

    @Test func aLegacyOverCapMemoryIsBroughtBackToTheCapByANewLink() {
        var graph = Self.hubGraph(neighbours: 31, tags: ["topic"])
        for id in numbered("n", 0..<30) {
            linkLegacy(&graph, "hub", id)
        }
        #expect(relations(graph, from: "hub").count == 30)

        graph.reinforceRelation(between: "hub", and: "n30")

        // 11 newest legacy links + the new one; every dropped link took its
        // mirror and its reverse index entries along.
        #expect(relationTargets(graph, from: "hub") == numbered("n", 19..<30) + ["n30"])
        for id in numbered("n", 0..<19) {
            #expect(relations(graph, from: id).isEmpty)
            #expect(!graph.incomingNodes(to: id).contains("hub"))
            #expect(!graph.incomingNodes(to: "hub").contains(id))
        }
        for id in numbered("n", 19..<30) {
            #expect(weight(graph, id, "hub") == 0.7)
        }
        #expect(graph.outgoingEdges(from: "hub").contains { $0.target == "tag:topic" && $0.kind == .hasTag })
        #expect(reverseIndexIsConsistent(graph))
    }

    @Test func aPolicyWithAnotherCapAndWeightsIsHonoured() {
        let policy = MemoryRelationPolicy(
            maximumLinksPerMemory: 2,
            initialWeight: 0.5,
            reinforcementStep: 0.1,
            maximumWeight: 0.7
        )
        var graph = makeGraph(["a", "b", "c", "d"])

        graph.reinforceRelation(between: "a", and: "b", policy: policy)
        graph.reinforceRelation(between: "a", and: "c", policy: policy)
        graph.reinforceRelation(between: "a", and: "b", policy: policy)
        graph.reinforceRelation(between: "a", and: "b", policy: policy)
        graph.reinforceRelation(between: "a", and: "b", policy: policy)
        graph.reinforceRelation(between: "a", and: "d", policy: policy)

        #expect(isApproximately(weight(graph, "a", "b"), 0.7))
        #expect(relationTargets(graph, from: "a") == ["b", "d"])
        #expect(weight(graph, "a", "d") == 0.5)
    }

    // MARK: Invariants

    @Test func relationInvariantsHoldUnderManyMixedOperations() {
        let ids = numbered("m", 0..<24)
        var graph = makeGraph(ids, tags: ["shared"])
        var generator = SplitMix64(state: 7)
        var derivedPairs = Set<[String]>()

        for step in 0..<600 {
            let first = ids[Int(generator.next() % 24)]
            let second = ids[Int(generator.next() % 24)]
            graph.reinforceRelation(between: first, and: second)
            if step % 40 == 0, first != second {
                graph.addEdge(from: first, to: second, kind: .derivedFrom)
                derivedPairs.insert([first, second])
            }
        }

        for id in ids {
            let own = relations(graph, from: id)
            #expect(own.count <= MemoryRelationPolicy.default.maximumLinksPerMemory)
            #expect(Set(own.map(\.target)).count == own.count)
            for link in own {
                #expect(link.weight >= 0.7 && link.weight <= 0.9)
                // Stored as a symmetric pair.
                #expect(weight(graph, link.target, id) == link.weight)
            }
            #expect(graph.outgoingEdges(from: id).contains { $0.target == "tag:shared" && $0.kind == .hasTag })
        }
        for pair in derivedPairs {
            #expect(graph.outgoingEdges(from: pair[0]).contains { $0.target == pair[1] && $0.kind == .derivedFrom })
        }
        #expect(graph.incomingNodes(to: "tag:shared").count == ids.count)
        #expect(reverseIndexIsConsistent(graph))
    }

    // MARK: Pruning

    @Test func pruningKeepsTheNewestLinksWhenWeightsAreEqualAndRemovesMirrors() {
        var graph = Self.hubGraph(neighbours: 20, tags: ["topic"])
        for id in numbered("n", 0..<20) {
            linkLegacy(&graph, "hub", id)
        }
        let linkCount = graph.metadata.linkDiscoveryCount

        let removed = graph.pruneRelations(maximumPerMemory: 12)

        // 8 links over the cap, each stored in both directions.
        #expect(removed == 16)
        #expect(relationTargets(graph, from: "hub") == numbered("n", 8..<20))
        for id in numbered("n", 0..<8) {
            #expect(relations(graph, from: id).isEmpty)
            #expect(!graph.incomingNodes(to: id).contains("hub"))
            #expect(!graph.incomingNodes(to: "hub").contains(id))
        }
        for id in numbered("n", 8..<20) {
            #expect(weight(graph, id, "hub") == 0.7)
        }
        #expect(graph.outgoingEdges(from: "hub").contains { $0.target == "tag:topic" && $0.kind == .hasTag })
        #expect(graph.metadata.linkDiscoveryCount == linkCount)
        #expect(reverseIndexIsConsistent(graph))
    }

    @Test func pruningRemovesTheWeakestLinksFirst() {
        var graph = Self.hubGraph(neighbours: 20)
        for id in numbered("n", 0..<20) {
            linkLegacy(&graph, "hub", id, weight: id < "n04" ? 0.9 : 0.7)
        }

        graph.pruneRelations(maximumPerMemory: 12)

        // The four oldest links are the heaviest, so they stay; the eight
        // oldest of the 0.7 ones go.
        #expect(relationTargets(graph, from: "hub") == numbered("n", 0..<4) + numbered("n", 12..<20))
    }

    @Test func pruningIsDeterministicAndIdempotent() {
        var graph = makeGraph(numbered("m", 0..<30))
        var generator = SplitMix64(state: 99)
        for _ in 0..<500 {
            let first = numbered("m", 0..<30)[Int(generator.next() % 30)]
            let second = numbered("m", 0..<30)[Int(generator.next() % 30)]
            guard first != second else { continue }
            linkLegacy(&graph, first, second, weight: generator.next() % 3 == 0 ? 0.8 : 0.7)
        }
        #expect(graph.edges.values.contains { $0.count > 12 })

        var first = graph
        var second = graph
        let removedFirst = first.pruneRelations(maximumPerMemory: 12)
        let removedSecond = second.pruneRelations(maximumPerMemory: 12)

        #expect(removedFirst > 0)
        #expect(removedFirst == removedSecond)
        #expect(first == second)
        for id in first.memories.keys {
            #expect(relations(first, from: id).count <= 12)
        }
        let again = first
        let removedAgain = first.pruneRelations(maximumPerMemory: 12)
        #expect(removedAgain == 0)
        #expect(first == again)
        #expect(reverseIndexIsConsistent(first))
    }

    @Test func pruningLeavesEdgesOfOtherKindsAlone() {
        var graph = Self.hubGraph(neighbours: 20, tags: ["topic"])
        graph.addEdge(from: "hub", to: "n00", kind: .supersedes)
        graph.markContradiction("hub", "n01")
        for id in numbered("n", 0..<20) {
            linkLegacy(&graph, "hub", id)
        }
        let others = graph.edges.values.joined().filter { $0.kind.relationWeight == nil }.count

        graph.pruneRelations(maximumPerMemory: 12)

        #expect(graph.edges.values.joined().filter { $0.kind.relationWeight == nil }.count == others)
        #expect(graph.outgoingEdges(from: "hub").contains { $0.target == "n00" && $0.kind == .supersedes })
        #expect(graph.incomingNodes(to: "n00") == ["hub"])
        #expect(graph.incomingNodes(to: "n01").contains("hub"))
        #expect(graph.incomingNodes(to: "hub").contains("n01"))
        #expect(!graph.incomingNodes(to: "hub").contains("n00"))
        #expect(reverseIndexIsConsistent(graph))
    }

    @Test func pruningAtOrBelowTheLimitChangesNothing() {
        var graph = Self.hubGraph(neighbours: 12)
        for id in numbered("n", 0..<12) {
            linkLegacy(&graph, "hub", id)
        }
        let before = graph

        let removed = graph.pruneRelations(maximumPerMemory: 12)
        #expect(removed == 0)
        #expect(graph == before)
    }
}

// MARK: - Recall maintenance

/// Selects exactly the scripted ids (in script order), one list per recall.
private actor ScriptedSelector: MemorySelector {
    private let script: [[String]]
    private var position = 0

    init(_ script: [[String]]) {
        self.script = script
    }

    func select(
        context: String,
        candidates: [MemoryCandidate],
        limit: Int
    ) async throws -> [MemoryCandidate] {
        guard position < script.count else { return [] }
        let ids = script[position]
        position += 1
        let byID = Dictionary(candidates.map { ($0.memory.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }
}

@Suite("Recall maintenance relations")
struct MemoryRecallRelationTests {
    @Test func repeatedRecallsReinforceThePairUpToTheMaximum() async throws {
        let selector = ScriptedSelector(Array(repeating: ["alpha", "beta"], count: 7))
        let memory = MemoryEngine(selector: selector)
        _ = try await memory.remember("alpha fact about swift", tags: ["swift"], id: "alpha")
        _ = try await memory.remember("beta fact about swift", tags: ["swift"], id: "beta")

        var observed: [Float] = []
        for _ in 0..<7 {
            let result = try await memory.recallDetailed("swift")
            #expect(result.selected.map(\.memory.id) == ["alpha", "beta"])
            let graph = await memory.snapshot()
            observed.append(weight(graph, "alpha", "beta") ?? -1)
            #expect(weight(graph, "beta", "alpha") == weight(graph, "alpha", "beta"))
        }

        let expected: [Float] = [0.7, 0.75, 0.8, 0.85, 0.9, 0.9, 0.9]
        #expect(zip(observed, expected).allSatisfy { isApproximately($0, $1) })
        let graph = await memory.snapshot()
        #expect(relations(graph, from: "alpha").count == 1)
        #expect(graph.metadata.linkDiscoveryCount == 14)
    }

    @Test func recallsKeepEveryMemoryAtOrBelowTheCap() async throws {
        let ids = numbered("m", 0..<16)
        let script = ids.dropFirst().map { ["m00", $0] }
        let memory = MemoryEngine(selector: ScriptedSelector(script))
        for id in ids {
            _ = try await memory.remember("note \(id) about swift", tags: ["swift"], id: id)
        }

        for expected in script {
            let result = try await memory.recallDetailed("swift")
            #expect(result.selected.map(\.memory.id) == expected)
        }

        let graph = await memory.snapshot()
        // 15 partners were linked in turn; the 3 oldest made room.
        #expect(relationTargets(graph, from: "m00") == numbered("m", 4..<16))
        for id in numbered("m", 1..<4) {
            #expect(relations(graph, from: id).isEmpty)
        }
        for id in ids {
            #expect(relations(graph, from: id).count <= 12)
        }
        #expect(reverseIndexIsConsistent(graph))
    }

    @Test func aRecallTrimsALegacyOverCapMemoryAndItsReverseIndex() async throws {
        var seed = MemoryGraph()
        seed.addMemory(EngineMemoryEntry(id: "hub", category: .fact, content: "zebra hub", tags: ["swift"]))
        seed.addMemory(EngineMemoryEntry(id: "newcomer", category: .fact, content: "zebra newcomer"))
        for id in numbered("n", 0..<30) {
            seed.addMemory(EngineMemoryEntry(id: id, category: .fact, content: "filler \(id)"))
            linkLegacy(&seed, "hub", id)
        }
        #expect(relations(seed, from: "hub").count == 30)
        let memory = MemoryEngine(graph: seed, selector: ScriptedSelector([["hub", "newcomer"]]))

        let result = try await memory.recallDetailed("zebra")
        #expect(result.selected.map(\.memory.id) == ["hub", "newcomer"])

        let graph = await memory.snapshot()
        #expect(relationTargets(graph, from: "hub") == numbered("n", 19..<30) + ["newcomer"])
        #expect(weight(graph, "newcomer", "hub") == 0.7)
        for id in numbered("n", 0..<19) {
            #expect(relations(graph, from: id).isEmpty)
            #expect(!graph.incomingNodes(to: id).contains("hub"))
            #expect(!graph.incomingNodes(to: "hub").contains(id))
        }
        #expect(graph.outgoingEdges(from: "hub").contains { $0.target == "tag:swift" && $0.kind == .hasTag })
        #expect(reverseIndexIsConsistent(graph))
    }

    @Test func replayedBatchMatchesTheDirectPathWhateverTheSelectionOrder() {
        var base = makeGraph(["a", "b", "c", "d", "e"])
        // A cap of 1 makes the order in which pairs are linked decide the outcome.
        let configuration = MemoryEngineConfiguration(
            relationPolicy: MemoryRelationPolicy(maximumLinksPerMemory: 1)
        )
        let intents: [(candidates: [String], selected: [String])] = [
            (["a", "b", "c", "d"], ["c", "a", "b"]),
            (["a", "b", "c", "d"], ["d", "b"]),
            (["a", "c", "e"], ["e", "c", "a"]),
            (["a", "b", "c", "d", "e"], ["b", "e", "d", "a"]),
        ]
        base.metadata.retrievalCount = 5

        func candidates(_ ids: [String], in graph: MemoryGraph) -> [MemoryCandidate] {
            ids.compactMap { id in graph.memories[id].map { MemoryCandidate(memory: $0, score: 0.5) } }
        }

        var direct = base
        for intent in intents {
            MemoryEngine.maintainAfterRetrieval(
                &direct,
                all: candidates(intent.candidates, in: direct),
                selected: candidates(intent.selected, in: direct),
                configuration: configuration
            )
        }

        var replayed = base
        MemoryEngine.apply(
            intents.map {
                MemoryEngine.PendingRecallMaintenance(
                    candidateIDs: $0.candidates,
                    selectedIDs: $0.selected,
                    scope: .all,
                    configuration: configuration
                )
            },
            to: &replayed
        )

        #expect(replayed == direct)
        #expect(direct.edgeCount > 0)
        #expect(direct.metadata.linkDiscoveryCount > 0)
        for id in direct.memories.keys {
            #expect(relations(direct, from: id).count <= 1)
        }
    }

    @Test func pendingBatchReplayedOnTheDurableGraphMatchesTheDirectPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relation-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")

        let ids = numbered("m", 0..<16)
        // Three-way selections in a non-ranking order, repeated pairs, a hub
        // that overflows the cap: all of it must replay identically.
        var script: [[String]] = ids.dropFirst().map { ["m00", $0] }
        script += [["m05", "m02", "m09"], ["m09", "m05"], ["m02", "m15", "m00"]]
        let memory = try await MemoryEngine.open(
            persistence: JSONMemoryPersistence(url: file),
            selector: ScriptedSelector(script),
            configuration: MemoryEngineConfiguration(recallMaintenanceCheckpointSize: 100)
        )
        for id in ids {
            _ = try await memory.remember("note \(id) about swift", tags: ["swift"], id: id)
        }
        for expected in script {
            let result = try await memory.recallDetailed("swift")
            #expect(result.selected.map(\.memory.id) == expected)
        }
        let direct = await memory.snapshot()
        #expect(relations(direct, from: "m00").count == 12)

        // Nothing durable yet: flushing reloads the file and replays the batch.
        try await memory.flushRecallMaintenance()
        let durable = try await JSONMemoryPersistence(url: file).load()

        #expect(durable.edges == direct.edges)
        #expect(durable.metadata.linkDiscoveryCount == direct.metadata.linkDiscoveryCount)
        #expect(durable.reverseEdges.mapValues(Set.init) == direct.reverseEdges.mapValues(Set.init))
        #expect(durable.graphVersion == MemoryGraph.currentGraphVersion)
    }
}
