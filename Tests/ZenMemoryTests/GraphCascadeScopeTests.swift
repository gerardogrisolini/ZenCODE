import Foundation
import Testing
@testable import ZenMemory

/// The graph cascade must be bounded by the requested scope: seeds, the nodes
/// it expands, and the results it returns all have to be inside the scope.
/// A node outside the scope (or archived) must never act as a bridge to its
/// neighbours.
@Test func cascadeKeepsLinkedOutOfScopeMemoryOutOfResults() {
    var graph = MemoryGraph()
    let project = MemoryEntry(id: "project", category: .fact, content: "Project fact", scope: .project)
    let global = MemoryEntry(id: "global", category: .fact, content: "Global fact", scope: .global)
    graph.addMemory(project)
    graph.addMemory(global)
    graph.linkMemories(from: "project", to: "global", weight: 0.9)
    graph.linkMemories(from: "global", to: "project", weight: 0.9)

    let result = graph.cascadeRetrieve(
        seeds: [ScoredMemoryID(id: "project", score: 1)],
        maxDepth: 2,
        maxResults: 10,
        scope: .project
    )

    #expect(result.contains(where: { $0.id == "project" }))
    #expect(!result.contains(where: { $0.id == "global" }))
}

@Test func cascadeDoesNotUseOutOfScopeNodeAsBridge() {
    var graph = MemoryGraph()
    let start = MemoryEntry(id: "start", category: .fact, content: "Start", scope: .project)
    let bridge = MemoryEntry(id: "bridge", category: .fact, content: "Global bridge", scope: .global)
    let end = MemoryEntry(id: "end", category: .fact, content: "End", scope: .project)
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

@Test func cascadeReturnsLinkedMemoryInsideScope() {
    var graph = MemoryGraph()
    let start = MemoryEntry(id: "start", category: .fact, content: "Start", scope: .project)
    let end = MemoryEntry(id: "end", category: .fact, content: "End", scope: .project)
    graph.addMemory(start)
    graph.addMemory(end)
    graph.linkMemories(from: "start", to: "end", weight: 0.9)

    let result = graph.cascadeRetrieve(
        seeds: [ScoredMemoryID(id: "start", score: 1)],
        maxDepth: 2,
        maxResults: 10,
        scope: .project
    )

    #expect(result.contains(where: { $0.id == "end" }))
}

@Test func cascadeSkipsArchivedSeed() {
    var graph = MemoryGraph()
    var archived = MemoryEntry(id: "archived", category: .fact, content: "Archived")
    archived.active = false
    graph.addMemory(archived)

    let result = graph.cascadeRetrieve(
        seeds: [ScoredMemoryID(id: "archived", score: 1)],
        maxDepth: 2,
        maxResults: 10,
        scope: .all
    )

    #expect(result.isEmpty)
}

@Test func cascadeDoesNotUseArchivedNodeAsBridge() {
    var graph = MemoryGraph()
    let start = MemoryEntry(id: "start", category: .fact, content: "Start")
    var archived = MemoryEntry(id: "archived", category: .fact, content: "Archived bridge")
    archived.active = false
    let end = MemoryEntry(id: "end", category: .fact, content: "End")
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
    let start = MemoryEntry(id: "start", category: .fact, content: "Start")
    let bridge = MemoryEntry(id: "bridge", category: .fact, content: "Active bridge")
    let end = MemoryEntry(id: "end", category: .fact, content: "End")
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
    let a = MemoryEntry(id: "a", category: .fact, content: "Swift package", tags: ["swift"], scope: .project)
    let b = MemoryEntry(id: "b", category: .fact, content: "Swift actors", tags: ["swift"], scope: .project)
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
