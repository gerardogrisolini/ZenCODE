import Foundation
import Testing
@testable import ZenMemory

/// The loader must reject graphs written by a newer engine than this build
/// supports, without rewriting or otherwise mutating the file on disk.
@Test func loadRejectsFutureGraphVersionAndKeepsFileByteIdentical() async throws {
    let json = #"""
    {
      "graph_version": 999,
      "memories": {},
      "tags": {},
      "clusters": {},
      "edges": {},
      "reverse_edges": {},
      "metadata": {"retrieval_count":0,"link_discovery_count":0}
    }
    """#

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = directory.appendingPathComponent("future-graph.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: file)
    let original = try Data(contentsOf: file)

    let persistence = JSONMemoryPersistence(url: file)
    do {
        _ = try await persistence.load()
        Issue.record("Expected unsupportedGraphVersion error")
    } catch let error as MemoryPersistenceError {
        #expect(error == .unsupportedGraphVersion(999))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    // The failed load must not mutate or rewrite the file.
    let after = try Data(contentsOf: file)
    #expect(after == original)
}

/// Older graph versions (including files without an explicit version) are
/// handled by the current contract: optional fields fall back to their
/// defaults and the in-memory version is normalized to the current one.
@Test func loadNormalizesOlderGraphVersionInMemory() async throws {
    let json = #"""
    {
      "graph_version": 1,
      "memories": {
        "mem_1": {
          "id": "mem_1",
          "category": "fact",
          "content": "Legacy entry without scope",
          "tags": [],
          "search_text": "legacy entry without scope",
          "created_at": "2026-08-07T12:00:00Z",
          "updated_at": "2026-08-07T12:00:00Z",
          "access_count": 0,
          "trust": "medium",
          "strength": 1,
          "active": true,
          "confidence": 1.0
        }
      },
      "tags": {},
      "clusters": {},
      "edges": {},
      "reverse_edges": {},
      "metadata": {"retrieval_count":0,"link_discovery_count":0}
    }
    """#

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = directory.appendingPathComponent("v1-graph.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: file)

    let persistence = JSONMemoryPersistence(url: file)
    let graph = try await persistence.load()

    #expect(graph.graphVersion == MemoryGraph.currentGraphVersion)
    #expect(graph.memories["mem_1"]?.scope == .project)
    #expect(graph.memories["mem_1"]?.active == true)
}

/// A file that predates `graph_version` entirely must still load: the key is
/// optional and falls back to the defined legacy version, contract defaults
/// fill in newer fields, and the in-memory graph is normalized to the current
/// version without touching the file — only an explicit save rewrites it.
@Test func loadFileWithoutGraphVersionKeyAppliesDefaultsAndKeepsFileByteIdentical() async throws {
    let json = #"""
    {
      "memories": {
        "mem_1": {
          "id": "mem_1",
          "category": "fact",
          "content": "Unversioned entry",
          "tags": ["legacy"],
          "created_at": "2026-08-07T12:00:00Z",
          "updated_at": "2026-08-07T12:00:00Z",
          "access_count": 0,
          "trust": "medium",
          "strength": 1,
          "confidence": 1.0
        }
      },
      "tags": {},
      "clusters": {},
      "edges": {
        "mem_1": [{"target": "tag:legacy", "kind": "has_tag"}]
      },
      "reverse_edges": {},
      "metadata": {"retrieval_count": 0, "link_discovery_count": 0}
    }
    """#

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = directory.appendingPathComponent("keyless-graph.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: file)
    let original = try Data(contentsOf: file)

    let persistence = JSONMemoryPersistence(url: file)
    let graph = try await persistence.load()

    // Normalized in memory to the current version…
    #expect(graph.graphVersion == MemoryGraph.currentGraphVersion)
    // …with contract defaults for the newer fields.
    let memory = try #require(graph.memories["mem_1"])
    #expect(memory.scope == .project)
    #expect(memory.active == true)
    #expect(memory.content == "Unversioned entry")
    #expect(memory.searchText == "unversioned entry legacy")
    #expect(graph.outgoingEdges(from: "mem_1").first?.kind == .hasTag)
    #expect(graph.incomingNodes(to: "tag:legacy") == ["mem_1"])

    // Loading never rewrites the file: it stays byte-identical until save.
    let after = try Data(contentsOf: file)
    #expect(after == original)
}

/// Saving after a keyless load writes the current format: the graph is
/// persisted with `graph_version` set to the current version and every field
/// round-trips through a reload.
@Test func saveAfterKeylessLoadWritesCurrentVersionAndRoundTripsFields() async throws {
    let json = #"""
    {
      "memories": {
        "mem_1": {
          "id": "mem_1",
          "category": "preference",
          "content": "Round trip me",
          "tags": ["legacy", "keep"],
          "created_at": "2026-08-07T12:00:00Z",
          "updated_at": "2026-08-07T12:00:00Z",
          "access_count": 3,
          "trust": "high",
          "strength": 2,
          "confidence": 0.75
        }
      },
      "tags": {
        "tag:legacy": {"id": "tag:legacy", "name": "legacy", "count": 1, "created_at": "2026-08-07T12:00:00Z"},
        "tag:keep": {"id": "tag:keep", "name": "keep", "count": 1, "created_at": "2026-08-07T12:00:00Z"}
      },
      "clusters": {},
      "edges": {
        "mem_1": [
          {"target": "tag:legacy", "kind": "has_tag"},
          {"target": "tag:keep", "kind": "has_tag"}
        ]
      },
      "reverse_edges": {},
      "metadata": {"retrieval_count": 5, "link_discovery_count": 2}
    }
    """#

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = directory.appendingPathComponent("keyless-save-graph.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: file)

    let persistence = JSONMemoryPersistence(url: file)
    let loaded = try await persistence.load()
    #expect(loaded.graphVersion == MemoryGraph.currentGraphVersion)

    try await persistence.save(loaded)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let reloaded = try decoder.decode(MemoryGraph.self, from: Data(contentsOf: file))

    #expect(reloaded.graphVersion == MemoryGraph.currentGraphVersion)
    #expect(reloaded == loaded)
    let memory = try #require(reloaded.memories["mem_1"])
    #expect(memory.content == "Round trip me")
    #expect(memory.tags == ["legacy", "keep"])
    #expect(memory.accessCount == 3)
    #expect(memory.trust == .high)
    #expect(memory.strength == 2)
    #expect(memory.confidence == 0.75)
    #expect(memory.scope == .project)
    #expect(memory.active == true)
    #expect(reloaded.tags.count == 2)
    #expect(reloaded.metadata.retrievalCount == 5)
    #expect(reloaded.metadata.linkDiscoveryCount == 2)
}
