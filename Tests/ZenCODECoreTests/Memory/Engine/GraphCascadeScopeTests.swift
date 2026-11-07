import Foundation
import Testing
@testable import ZenCODECore

/// The graph cascade must be bounded by the requested scope: seeds, the nodes
/// it expands, and the results it returns all have to be inside the scope.
/// A node outside the scope (or archived) must never act as a bridge to its
/// neighbours.
@Test func cascadeDoesNotUseOutOfScopeNodeAsBridge() {
    var graph = MemoryGraph()
    let start = EngineMemoryEntry(id: "start", category: .fact, content: "Start", scope: .project)
    let bridge = EngineMemoryEntry(id: "bridge", category: .fact, content: "Global bridge", scope: .global)
    let end = EngineMemoryEntry(id: "end", category: .fact, content: "End", scope: .project)
    graph.addMemory(start)
    graph.addMemory(bridge)
    graph.addMemory(end)
    graph.linkMemories(from: "start", to: "bridge", weight: 0.9)
    graph.linkMemories(from: "bridge", to: "end", weight: 0.9)

    let result = graph.cascadeRetrieve(
        seeds: [ScoredMemoryID(id: "start", score: 1)],
        maxDepth: 2,
        maxResults: 10,
        scope: .project
    )

    // The global bridge is excluded and must not lead to `end`.
    #expect(result.contains(where: { $0.id == "start" }))
    #expect(!result.contains(where: { $0.id == "bridge" }))
    #expect(!result.contains(where: { $0.id == "end" }))
}

@Test func cascadeDoesNotUseArchivedNodeAsBridge() {
    var graph = MemoryGraph()
    let start = EngineMemoryEntry(id: "start", category: .fact, content: "Start")
    var archived = EngineMemoryEntry(id: "archived", category: .fact, content: "Archived bridge")
    archived.active = false
    let end = EngineMemoryEntry(id: "end", category: .fact, content: "End")
    graph.addMemory(start)
    graph.addMemory(archived)
    graph.addMemory(end)
    graph.linkMemories(from: "start", to: "archived", weight: 0.9)
    graph.linkMemories(from: "archived", to: "end", weight: 0.9)

    let result = graph.cascadeRetrieve(
        seeds: [ScoredMemoryID(id: "start", score: 1)],
        maxDepth: 2,
        maxResults: 10,
        scope: .all
    )

    // The archived bridge is never queued, so it cannot forward to `end`.
    #expect(result.contains(where: { $0.id == "start" }))
    #expect(!result.contains(where: { $0.id == "archived" }))
    #expect(!result.contains(where: { $0.id == "end" }))
}

@Test func cascadeStillTraversesActiveBridge() {
    var graph = MemoryGraph()
    let start = EngineMemoryEntry(id: "start", category: .fact, content: "Start")
    let bridge = EngineMemoryEntry(id: "bridge", category: .fact, content: "Active bridge")
    let end = EngineMemoryEntry(id: "end", category: .fact, content: "End")
    graph.addMemory(start)
    graph.addMemory(bridge)
    graph.addMemory(end)
    graph.linkMemories(from: "start", to: "bridge", weight: 0.9)
    graph.linkMemories(from: "bridge", to: "end", weight: 0.9)

    let result = graph.cascadeRetrieve(
        seeds: [ScoredMemoryID(id: "start", score: 1)],
        maxDepth: 2,
        maxResults: 10,
        scope: .all
    )

    #expect(result.contains(where: { $0.id == "end" }))
}

@Test func cascadeSharedTagTraversalStillFindsActiveInScopeMemories() {
    var graph = MemoryGraph()
    let a = EngineMemoryEntry(id: "a", category: .fact, content: "Swift package", tags: ["swift"], scope: .project)
    let b = EngineMemoryEntry(id: "b", category: .fact, content: "Swift actors", tags: ["swift"], scope: .project)
    graph.addMemory(a)
    graph.addMemory(b)

    let result = graph.cascadeRetrieve(
        seeds: [ScoredMemoryID(id: "a", score: 1)],
        maxDepth: 2,
        maxResults: 10,
        scope: .project
    )

    #expect(result.contains(where: { $0.id == "a" }))
    #expect(result.contains(where: { $0.id == "b" }))
}
