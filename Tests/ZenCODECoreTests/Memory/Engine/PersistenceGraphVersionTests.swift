import Foundation
import Testing
@testable import ZenCODECore

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


// MARK: - Durable graph privacy

#if canImport(Darwin) || canImport(Glibc)
private func posixMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
#endif

@Test func graphPersistenceCreatesPrivateGraphLockAndDirectory() async throws {
    #if canImport(Darwin) || canImport(Glibc)
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fileManager.removeItem(at: directory) }
    let file = directory.appendingPathComponent("memory.graph.json")

    let persistence = JSONMemoryPersistence(url: file)
    try await persistence.save(MemoryGraph())

    #expect(try posixMode(directory) == 0o700)
    #expect(try posixMode(file) == 0o600)
    // A transaction creates the stable adjacent lock and must harden it too.
    _ = try await persistence.transaction { _ in () }
    #expect(try posixMode(file.appendingPathExtension("lock")) == 0o600)
    // The staging file used to publish the graph must not survive the commit.
    let leftovers = try fileManager.contentsOfDirectory(atPath: directory.path)
        .filter { $0.contains("staging") }
    #expect(leftovers.isEmpty)
    #else
    return
    #endif
}

/// A graph published over a world-readable predecessor must never be readable
/// by anyone else, not even for the instant between write and `chmod`.
///
/// The check is indirect but exact: the file that ends up at `url` must be a
/// *different inode* than the permissive one, because the publication stages a
/// private file and renames it over the old path. Correcting the mode after
/// `Data.write(options: .atomic)` cannot satisfy this — that path writes the
/// content first and tightens afterwards.
@Test func graphPublicationNeverInheritsOrExposesAPermissiveMode() async throws {
    #if canImport(Darwin) || canImport(Glibc)
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fileManager.removeItem(at: directory) }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("memory.graph.json")
    // A store left behind by an older build: readable and writable by everyone.
    try Data("{}".utf8).write(to: file)
    try fileManager.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
    try fileManager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
    let permissiveInode = (try fileManager.attributesOfItem(atPath: file.path)[.systemFileNumber]
        as? NSNumber)?.intValue

    var graph = MemoryGraph()
    graph.addMemory(EngineMemoryEntry(id: "mem_1", category: .fact, content: "private"))
    let persistence = JSONMemoryPersistence(url: file)
    try await persistence.save(graph)

    #expect(try posixMode(file) == 0o600)
    #expect(try posixMode(directory) == 0o700)
    let publishedInode = (try fileManager.attributesOfItem(atPath: file.path)[.systemFileNumber]
        as? NSNumber)?.intValue
    #expect(publishedInode != permissiveInode)
    // Publication is still a complete, decodable replacement.
    let reloaded = try await JSONMemoryPersistence(url: file).load()
    #expect(reloaded.memories["mem_1"]?.content == "private")
    #else
    return
    #endif
}

/// Opening an existing permissive store must tighten it, not wait for the next
/// write. The lock file is included: it is created adjacent to the graph and
/// older builds left it with the ambient umask.
@Test func loadingHardensAPreExistingPermissiveStore() async throws {
    #if canImport(Darwin) || canImport(Glibc)
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fileManager.removeItem(at: directory) }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("memory.graph.json")
    let lock = file.appendingPathExtension("lock")

    var graph = MemoryGraph()
    graph.addMemory(EngineMemoryEntry(id: "mem_1", category: .fact, content: "legacy"))
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(graph).write(to: file)
    try Data().write(to: lock)
    try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    try fileManager.setAttributes([.posixPermissions: 0o646], ofItemAtPath: lock.path)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

    let bytesBefore = try Data(contentsOf: file)
    let loaded = try await JSONMemoryPersistence(url: file).load()

    #expect(loaded.memories["mem_1"]?.content == "legacy")
    #expect(try posixMode(file) == 0o600)
    #expect(try posixMode(lock) == 0o600)
    #expect(try posixMode(directory) == 0o700)
    // Hardening is a mode change only: loading never rewrites the graph.
    #expect(try Data(contentsOf: file) == bytesBefore)
    #else
    return
    #endif
}

/// A mode that is already stricter than the target must not be widened.
@Test func hardeningNeverWidensAnAlreadyStrictMode() async throws {
    #if canImport(Darwin) || canImport(Glibc)
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fileManager.removeItem(at: directory) }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("memory.graph.json")
    try Data("{}".utf8).write(to: file)
    try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)

    _ = try? await JSONMemoryPersistence(url: file).load()

    #expect(try posixMode(file) == 0o400)
    #else
    return
    #endif
}

/// The closure → save window.
///
/// A transaction body can run long (revalidation, replay of pending recall
/// maintenance) and the caller's deadline can pass while it does. Cancelling
/// from *inside* the body reproduces exactly that instant deterministically:
/// the draft is already dirty, the store has not written yet. The transaction
/// must abort before publishing and leave the previous bytes untouched.
@Test func cancellationBetweenTransactionBodyAndSaveLeavesTheGraphUnpublished() async throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fileManager.removeItem(at: directory) }
    let file = directory.appendingPathComponent("memory.graph.json")
    let persistence = JSONMemoryPersistence(url: file)

    var seed = MemoryGraph()
    seed.addMemory(EngineMemoryEntry(id: "seed", category: .fact, content: "seed"))
    try await persistence.save(seed)
    let bytesBefore = try Data(contentsOf: file)

    let task = Task<Void, Error> {
        _ = try await persistence.transaction { graph in
            graph.addMemory(EngineMemoryEntry(id: "late", category: .fact, content: "late"))
            // The body has produced a dirty draft; the deadline passes here.
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(try Data(contentsOf: file) == bytesBefore)
    let reloaded = try await JSONMemoryPersistence(url: file).load()
    #expect(reloaded.memories["late"] == nil)
    #expect(reloaded.memories["seed"] != nil)
    // No staging file was left behind by the aborted publication.
    let leftovers = try fileManager.contentsOfDirectory(atPath: directory.path)
        .filter { $0.contains("staging") }
    #expect(leftovers.isEmpty)
}

/// The same window, but with a body that changed nothing: an unchanged graph
/// never reaches the save path, so cancellation there is not a failure to hide
/// — the transaction simply reports its read-only result.
@Test func cancellationInAReadOnlyTransactionBodyStillAborts() async throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fileManager.removeItem(at: directory) }
    let file = directory.appendingPathComponent("memory.graph.json")
    let persistence = JSONMemoryPersistence(url: file)
    try await persistence.save(MemoryGraph())
    let bytesBefore = try Data(contentsOf: file)

    let task = Task<Bool, Error> {
        let committed = try await persistence.transaction { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return true
        }
        return committed.didChange
    }
    #expect(try await task.value == false)
    #expect(try Data(contentsOf: file) == bytesBefore)
}
