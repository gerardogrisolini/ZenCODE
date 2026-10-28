//
//  MemoryBackupPersistenceTests.swift
//  ZenCODECoreTests
//
//  The rotating cleanup backup — `memory.graph.json.bak` and
//  `memory.graph.json.vectors.bak` — written in the persisted format, replaced
//  atomically, private to the owner.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct MemoryBackupPersistenceTests {
    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-backup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func sampleGraph(contents: [String]) -> MemoryGraph {
        var graph = MemoryGraph()
        for (index, content) in contents.enumerated() {
            var entry = EngineMemoryEntry(
                id: "mem-\(index)",
                category: index.isMultiple(of: 2) ? .fact : .preference,
                content: content,
                tags: ["tag-\(index)"],
                createdAt: Date(timeIntervalSince1970: 1_800_000_000.123_456_789 + Double(index)),
                embedding: [0.25, -0.5, Float(index)],
                embeddingModel: "model-a"
            )
            entry.accessCount = UInt32(index)
            graph.addMemory(entry)
        }
        return graph
    }

    @Test
    func backupPairIsNamedAfterTheGraphAndItsVectorsFile() {
        let graphURL = URL(fileURLWithPath: "/tmp/x/memory.graph.json")
        let backup = JSONMemoryPersistence.backupURLs(forGraphAt: graphURL)
        #expect(backup.graph.lastPathComponent == "memory.graph.json.bak")
        #expect(backup.vectors.lastPathComponent == "memory.graph.json.vectors.bak")
        #expect(JSONMemoryPersistence.vectorsURL(forGraphAt: graphURL).lastPathComponent == "memory.graph.json.vectors")
    }

    @Test
    func backupReloadsAsTheSameGraph() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let graphURL = directory.appendingPathComponent("memory.graph.json")
        let graph = Self.sampleGraph(contents: ["first", "second", "third"])

        try JSONMemoryPersistence.writeBackup(of: graph, forGraphAt: graphURL)

        let reloaded = try await PersistenceCharacterizationTests.loadCleanupBackup(of: graphURL)
        #expect(reloaded.memories == graph.memories)
        #expect(reloaded.memories.values.allSatisfy { $0.embedding?.count == 3 })
        #expect(reloaded.tags == graph.tags)
        #expect(reloaded.edges == graph.edges)
        #expect(reloaded.metadata == graph.metadata)
        #expect(reloaded.graphVersion == MemoryGraph.currentGraphVersion)
    }

    @Test
    func backupPayloadIsByteIdenticalToASavedGraph() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let graphURL = directory.appendingPathComponent("memory.graph.json")
        let graph = Self.sampleGraph(contents: ["alpha", "beta"])

        try await JSONMemoryPersistence(url: graphURL).save(graph)
        try JSONMemoryPersistence.writeBackup(of: graph, forGraphAt: graphURL)

        let backup = JSONMemoryPersistence.backupURLs(forGraphAt: graphURL)
        let vectorsURL = JSONMemoryPersistence.vectorsURL(forGraphAt: graphURL)
        #expect(try Data(contentsOf: backup.graph) == Data(contentsOf: graphURL))
        #expect(try Data(contentsOf: backup.vectors) == Data(contentsOf: vectorsURL))
        #expect(try JSONMemoryPersistence.encodeGraph(graph) == Data(contentsOf: graphURL))
        #expect(try MemoryVectorFile.encode(graph) == Data(contentsOf: vectorsURL))
    }

    @Test
    func secondBackupReplacesTheFirstAndLeavesNoStagingFile() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let graphURL = directory.appendingPathComponent("memory.graph.json")
        let first = Self.sampleGraph(contents: ["first"])
        let second = Self.sampleGraph(contents: ["one", "two"])

        try JSONMemoryPersistence.writeBackup(of: first, forGraphAt: graphURL)
        try JSONMemoryPersistence.writeBackup(of: second, forGraphAt: graphURL)

        let reloaded = try await PersistenceCharacterizationTests.loadCleanupBackup(of: graphURL)
        #expect(reloaded.memories == second.memories)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["memory.graph.json.bak", "memory.graph.json.vectors.bak"])
    }

    @Test
    func backupIsOwnerOnly() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let graphURL = directory.appendingPathComponent("memory.graph.json")

        try JSONMemoryPersistence.writeBackup(of: Self.sampleGraph(contents: ["secret"]), forGraphAt: graphURL)
        // A second write replaces the inodes and must be private as well.
        try JSONMemoryPersistence.writeBackup(of: Self.sampleGraph(contents: ["secret 2"]), forGraphAt: graphURL)

        let backup = JSONMemoryPersistence.backupURLs(forGraphAt: graphURL)
        for url in [backup.graph, backup.vectors] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
            #expect(permissions & 0o777 == 0o600)
        }
    }

    /// Restoring only the JSON backup over a graph whose vectors moved on is
    /// safe: an entry whose content changed since the backup loses its vector,
    /// an unchanged one keeps the vector the live file still has for it, and no
    /// entry ever gets the vector of another text.
    @Test
    func restoringOnlyTheJSONBackupNeverPairsAVectorWithAnotherText() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let graphURL = directory.appendingPathComponent("memory.graph.json")
        let backedUp = Self.sampleGraph(contents: ["unchanged", "edited later"])
        try JSONMemoryPersistence.writeBackup(of: backedUp, forGraphAt: graphURL)

        var live = backedUp
        live.memories["mem-1"]?.content = "a different text"
        live.memories["mem-1"]?.setEmbedding([9, 9, 9], model: "model-a")
        try await JSONMemoryPersistence(url: graphURL).save(live)

        // Manual restore of the JSON alone.
        let backup = JSONMemoryPersistence.backupURLs(forGraphAt: graphURL)
        try FileManager.default.removeItem(at: graphURL)
        try FileManager.default.copyItem(at: backup.graph, to: graphURL)

        let restored = try await JSONMemoryPersistence(url: graphURL).load()
        #expect(restored.memories["mem-1"]?.content == "edited later")
        #expect(restored.memories["mem-1"]?.embedding == nil)
        #expect(restored.memories["mem-0"]?.embedding == backedUp.memories["mem-0"]?.embedding)
    }
}
