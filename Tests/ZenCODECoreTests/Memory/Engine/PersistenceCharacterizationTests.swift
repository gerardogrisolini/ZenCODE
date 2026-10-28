//
//  PersistenceCharacterizationTests.swift
//  ZenCODECoreTests (memory engine)
//
//  Characterization of the graph persistence contract, written before the
//  vectors moved out of the JSON: every earlier wire version loads, loading
//  never writes, a future version is rejected without touching anything, the
//  reload cache decodes once per change, a transaction that changes nothing
//  never reaches the disk, and the cleanup backup is a private, faithful copy.
//
//  The vectors in the fixtures are exactly representable at every storage
//  precision ZenCODE has used, so the expectations do not depend on it.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite struct PersistenceCharacterizationTests {
    // MARK: - Fixtures

    /// The fixture vector, `[1, -2.5, 0, 0.125]`, in the three spellings the
    /// graph JSON has used.
    enum WireVersion: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// No `graph_version` key, numeric array.
        case legacyKeyless
        /// `graph_version: 1`, numeric array.
        case version1
        /// `graph_version: 2`, numeric array.
        case version2
        /// `graph_version: 3`, base64 of little-endian binary32.
        case version3

        var testDescription: String { rawValue }

        var versionLine: String {
            switch self {
            case .legacyKeyless: ""
            case .version1: "\"graph_version\": 1,\n"
            case .version2: "\"graph_version\": 2,\n"
            case .version3: "\"graph_version\": 3,\n"
            }
        }

        var embeddingLiteral: String {
            switch self {
            case .legacyKeyless, .version1, .version2: "[1.0, -2.5, 0.0, 0.125]"
            case .version3: "\"AACAPwAAIMAAAAAAAAAAPg==\""
            }
        }
    }

    static let fixtureVector: [Float] = [1.0, -2.5, 0.0, 0.125]
    static let fixtureModel = "fixture-model"

    static func fixtureJSON(_ wire: WireVersion) -> String {
        """
        {
          \(wire.versionLine)"memories": {
            "mem_vec": {
              "id": "mem_vec",
              "category": "fact",
              "content": "Swift runs on Linux",
              "tags": ["swift"],
              "search_text": "swift runs on linux swift",
              "created_at": "2026-08-07T12:00:00Z",
              "updated_at": "2026-08-07T12:00:00Z",
              "access_count": 2,
              "trust": "high",
              "strength": 1,
              "active": true,
              "embedding": \(wire.embeddingLiteral),
              "embedding_model": "\(fixtureModel)",
              "confidence": 0.75
            },
            "mem_plain": {
              "id": "mem_plain",
              "category": "preference",
              "content": "No vector here",
              "tags": [],
              "created_at": "2026-08-07T12:00:00Z",
              "updated_at": "2026-08-07T12:00:00Z",
              "access_count": 0,
              "trust": "medium",
              "strength": 1,
              "confidence": 1.0
            }
          },
          "tags": {
            "tag:swift": {"id": "tag:swift", "name": "swift", "count": 1, "created_at": "2026-08-07T12:00:00Z"}
          },
          "clusters": {},
          "edges": {
            "mem_vec": [{"target": "tag:swift", "kind": "has_tag"}]
          },
          "reverse_edges": {"tag:swift": ["mem_vec"]},
          "metadata": {"retrieval_count": 4, "link_discovery_count": 1}
        }
        """
    }

    static func emptyGraphJSON(version: UInt32) -> String {
        """
        {
          "graph_version": \(version),
          "memories": {},
          "tags": {},
          "clusters": {},
          "edges": {},
          "reverse_edges": {},
          "metadata": {"retrieval_count": 0, "link_discovery_count": 0}
        }
        """
    }

    static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-characterization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Names, bytes, inodes and modification times of every file in a
    /// directory: equal snapshots mean nothing was created, removed, replaced
    /// or rewritten.
    struct DirectorySnapshot: Equatable {
        struct File: Equatable {
            let data: Data
            let inode: UInt64?
            let modificationDate: Date?
        }

        let files: [String: File]

        init(_ directory: URL) throws {
            let fileManager = FileManager.default
            var files: [String: File] = [:]
            for name in try fileManager.contentsOfDirectory(atPath: directory.path) {
                let url = directory.appendingPathComponent(name)
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                files[name] = File(
                    data: try Data(contentsOf: url),
                    inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                    modificationDate: attributes[.modificationDate] as? Date
                )
            }
            self.files = files
        }

        var names: Set<String> { Set(files.keys) }
    }

    // MARK: - Earlier versions load, unchanged

    @Test(arguments: WireVersion.allCases)
    func earlierVersionLoadsWithItsVectorAndDefaults(_ wire: WireVersion) async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        try Data(Self.fixtureJSON(wire).utf8).write(to: file)

        let graph = try await JSONMemoryPersistence(url: file).load()

        #expect(graph.graphVersion == MemoryGraph.currentGraphVersion)
        let withVector = try #require(graph.memories["mem_vec"])
        #expect(withVector.embedding == Self.fixtureVector)
        #expect(withVector.embeddingModel == Self.fixtureModel)
        #expect(withVector.accessCount == 2)
        #expect(withVector.confidence == 0.75)
        #expect(withVector.trust == .high)
        #expect(withVector.scope == .project)
        let plain = try #require(graph.memories["mem_plain"])
        #expect(plain.embedding == nil)
        #expect(plain.embeddingModel == nil)
        // Contract defaults for fields the oldest files lack.
        #expect(plain.active)
        #expect(plain.searchText == "no vector here")
        #expect(graph.outgoingEdges(from: "mem_vec").first?.kind == .hasTag)
        #expect(graph.incomingNodes(to: "tag:swift") == ["mem_vec"])
        #expect(graph.metadata.retrievalCount == 4)
    }

    /// Loading through every read path neither creates, removes, replaces nor
    /// rewrites a single file: not the graph, not a lock, not a staging file.
    @Test(arguments: WireVersion.allCases)
    func loadingWritesNothing(_ wire: WireVersion) async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        try Data(Self.fixtureJSON(wire).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let before = try DirectorySnapshot(directory)

        let persistence = JSONMemoryPersistence(url: file)
        _ = try await persistence.load()
        _ = try await persistence.reloadReadOnly()
        _ = try await JSONMemoryPersistence(url: file).reloadReadOnly()

        #expect(try DirectorySnapshot(directory) == before)
        #expect(before.names == ["memory.graph.json"])
    }

    /// Opening a store and reading through it is read-only as well.
    @Test func storeReadsWriteNothing() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        try Data(Self.fixtureJSON(.version3).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let before = try DirectorySnapshot(directory)

        try await MemoryEmbedding.withProvider(nil) {
            let store = try await MemoryGraphStore.open(graphURL: file)
            #expect(try await store.entries(includeArchived: true, limit: 10).count == 2)
            #expect(try await store.search(query: "swift linux", includeArchived: false, limit: 5).isEmpty == false)
            #expect(try await store.entry(id: "mem_vec")?.embedding == Self.fixtureVector)
        }

        #expect(try DirectorySnapshot(directory) == before)
    }

    // MARK: - Future versions

    /// The version after the current one is rejected by every load path,
    /// including the reload under the lock, and nothing in the directory but
    /// the stable lock file changes.
    @Test func nextVersionIsRejectedAndLeftByteIdentical() async throws {
        let future = MemoryGraph.currentGraphVersion + 1
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        try Data(Self.emptyGraphJSON(version: future).utf8).write(to: file)
        let original = try Data(contentsOf: file)
        let before = try DirectorySnapshot(directory)

        let persistence = JSONMemoryPersistence(url: file)
        await #expect(throws: MemoryPersistenceError.unsupportedGraphVersion(future)) {
            _ = try await persistence.load()
        }
        await #expect(throws: MemoryPersistenceError.unsupportedGraphVersion(future)) {
            _ = try await persistence.reloadReadOnly()
        }
        #expect(try DirectorySnapshot(directory) == before)

        await #expect(throws: MemoryPersistenceError.unsupportedGraphVersion(future)) {
            _ = try await persistence.transaction { graph in
                graph.addMemory(EngineMemoryEntry(id: "late", category: .fact, content: "late"))
            }
        }
        #expect(try Data(contentsOf: file) == original)
        let after = try DirectorySnapshot(directory)
        #expect(after.names.subtracting(["memory.graph.json.lock"]) == before.names)
        #expect(after.files["memory.graph.json"] == before.files["memory.graph.json"])
    }

    /// A store refuses to open the future file instead of starting empty.
    @Test func storeRefusesToOpenANextVersionGraph() async throws {
        let future = MemoryGraph.currentGraphVersion + 1
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        try Data(Self.emptyGraphJSON(version: future).utf8).write(to: file)
        let original = try Data(contentsOf: file)

        await #expect(throws: MemoryPersistenceError.unsupportedGraphVersion(future)) {
            _ = try await MemoryEmbedding.withProvider(nil) {
                try await MemoryGraphStore.open(graphURL: file)
            }
        }
        #expect(try Data(contentsOf: file) == original)
    }

    // MARK: - Reload cache

    @Test func cacheDecodesOncePerPublishedChange() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        try Data(Self.fixtureJSON(.version3).utf8).write(to: file)

        let persistence = JSONMemoryPersistence(url: file)
        let loaded = try await persistence.load()
        _ = try await persistence.load()
        _ = try await persistence.reloadReadOnly()
        let unchanged = try await persistence.transaction { graph in graph.memories.count }
        #expect(unchanged.result == 2)
        #expect(unchanged.didChange == false)
        #expect(await persistence.diskDecodeCount == 1)

        // Its own publish re-primes the cache: no decode for the next reads.
        let changed = try await persistence.transaction { graph in
            graph.memories["mem_plain"]?.accessCount = 7
        }
        #expect(changed.didChange)
        let afterOwnPublish = try await persistence.reloadReadOnly()
        #expect(afterOwnPublish == changed.graph)
        #expect(await persistence.diskDecodeCount == 1)

        // Another writer's publish costs exactly one decode.
        let other = JSONMemoryPersistence(url: file)
        _ = try await other.transaction { graph in
            graph.memories["mem_plain"]?.accessCount = 8
        }
        let afterForeignPublish = try await persistence.reloadReadOnly()
        #expect(afterForeignPublish.memories["mem_plain"]?.accessCount == 8)
        _ = try await persistence.reloadReadOnly()
        #expect(await persistence.diskDecodeCount == 2)

        // The cached graph is exactly what a fresh decode returns.
        let fresh = JSONMemoryPersistence(url: file)
        #expect(try await fresh.load() == afterForeignPublish)
        #expect(loaded.memories["mem_vec"] == afterForeignPublish.memories["mem_vec"])
    }

    // MARK: - Transactions that change nothing

    /// A body that reads, or writes back values equal to the stored ones,
    /// reports no change and leaves every file as it was.
    @Test func unchangedTransactionNeverTouchesTheDisk() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        try Data(Self.fixtureJSON(.version3).utf8).write(to: file)
        // A graph published by the current build, with its lock already created.
        let persistence = JSONMemoryPersistence(url: file)
        try await persistence.save(try await persistence.load())
        let before = try DirectorySnapshot(directory)
        #expect(before.names.contains("memory.graph.json.lock"))

        let readOnly = try await persistence.transaction { graph in graph.memories.count }
        let rewrittenEqual = try await persistence.transaction { graph in
            let entry = try #require(graph.memories["mem_vec"])
            graph.memories["mem_vec"]?.setEmbedding(entry.embedding, model: entry.embeddingModel)
            graph.memories["mem_vec"]?.accessCount = entry.accessCount
        }

        #expect(readOnly.didChange == false)
        #expect(rewrittenEqual.didChange == false)
        #expect(try DirectorySnapshot(directory) == before)
    }

    /// Through the engine: a no-op transaction and an explicit save with nothing
    /// pending keep every file identical.
    @Test func engineNoOpTransactionAndSaveNeverTouchTheDisk() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        try Data(Self.fixtureJSON(.version3).utf8).write(to: file)
        let seed = try await JSONMemoryPersistence(url: file).load()
        try await JSONMemoryPersistence(url: file).save(seed)
        _ = try await JSONMemoryPersistence(url: file).transaction { _ in () }
        let before = try DirectorySnapshot(directory)

        let engine = try await MemoryEngine.open(persistence: JSONMemoryPersistence(url: file))
        let count = try await engine.transaction { graph in graph.memories.count }
        try await engine.transaction { graph in
            let entry = try #require(graph.memories["mem_vec"])
            graph.memories["mem_vec"]?.setEmbedding(entry.embedding, model: entry.embeddingModel)
        }
        try await engine.save()

        #expect(count == 2)
        #expect(try DirectorySnapshot(directory) == before)
    }

    // MARK: - Cleanup backup

    /// The cleanup backup is the pre-cleanup graph, vectors included, written
    /// owner-only; the graph saved after it is the cleaned one.
    @Test func cleanupBackupIsAPrivateCopyOfThePreCleanupGraph() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            try await MemoryEmbedding.withProvider(DeterministicHashEmbeddingProvider(dimensions: 16)) {
                let service = MemoryService()
                let kept = try await service.writeEntry(
                    content: "Summary: keep this vector",
                    workspaceRootURL: workspace.workspaceURL,
                    tags: ["keep"]
                )
                let dropped = try await service.writeEntry(
                    content: "Summary: archived then removed",
                    workspaceRootURL: workspace.workspaceURL,
                    tags: ["drop"]
                )
                try await service.archiveEntry(id: dropped.id.uuidString, workspaceRootURL: workspace.workspaceURL)

                let graphURL = workspace.graphURL()
                let store = try await MemoryGraphStoreRegistry.shared.store(graphURL: graphURL)
                let before = try await store.engine.freshSnapshotForReadOnly()
                #expect(before.memories[kept.id.uuidString]?.embedding?.count == 16)

                let report = try await store.cleanup(
                    MemoryCleanupPolicy(archivedRetentionDays: 30),
                    now: Date().addingTimeInterval(40 * 86_400)
                )
                #expect(report.removedArchived.map(\.id) == [dropped.id.uuidString])

                let backup = try await Self.loadCleanupBackup(of: graphURL)
                #expect(backup == before)
                for url in Self.cleanupBackupFiles(of: graphURL) {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let mode = try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
                    #expect(mode & 0o777 == 0o600)
                }

                let onDisk = try await JSONMemoryPersistence(url: graphURL).load()
                #expect(Set(onDisk.memories.keys) == [kept.id.uuidString])
                #expect(onDisk == (await store.engine.snapshot()))
            }
        }
    }

    /// Every file of the cleanup backup that exists next to `graphURL`.
    static func cleanupBackupFiles(of graphURL: URL) -> [URL] {
        [
            graphURL.appendingPathExtension("bak"),
            graphURL.appendingPathExtension("vectors").appendingPathExtension("bak"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Restores the cleanup backup the documented way — every backup file
    /// copied over its live name — into a scratch directory and loads it.
    static func loadCleanupBackup(of graphURL: URL) async throws -> MemoryGraph {
        let scratch = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let restored = scratch.appendingPathComponent(graphURL.lastPathComponent)
        for backup in cleanupBackupFiles(of: graphURL) {
            let live = backup.deletingPathExtension().lastPathComponent
            try FileManager.default.copyItem(
                at: backup,
                to: scratch.appendingPathComponent(live)
            )
        }
        return try await JSONMemoryPersistence(url: restored).load()
    }
}
