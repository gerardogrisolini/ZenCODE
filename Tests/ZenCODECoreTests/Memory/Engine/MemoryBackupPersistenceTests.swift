//
//  MemoryBackupPersistenceTests.swift
//  ZenCODECoreTests
//
//  The rotating `memory.graph.json.bak` copy: written in the persisted format,
//  replaced atomically, private to the owner.
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
    func backupReloadsAsTheSameGraph() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backupURL = directory.appendingPathComponent("memory.graph.json.bak")
        let graph = Self.sampleGraph(contents: ["first", "second", "third"])

        try JSONMemoryPersistence.writeBackup(of: graph, to: backupURL)

        let reloaded = try await JSONMemoryPersistence(url: backupURL).load()
        #expect(reloaded.memories == graph.memories)
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
        let backupURL = directory.appendingPathComponent("memory.graph.json.bak")
        let graph = Self.sampleGraph(contents: ["alpha", "beta"])

        try await JSONMemoryPersistence(url: graphURL).save(graph)
        try JSONMemoryPersistence.writeBackup(of: graph, to: backupURL)

        #expect(try Data(contentsOf: backupURL) == Data(contentsOf: graphURL))
        #expect(try JSONMemoryPersistence.encodeGraph(graph) == Data(contentsOf: graphURL))
    }

    @Test
    func secondBackupReplacesTheFirstAndLeavesNoStagingFile() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backupURL = directory.appendingPathComponent("memory.graph.json.bak")
        let first = Self.sampleGraph(contents: ["first"])
        let second = Self.sampleGraph(contents: ["one", "two"])

        try JSONMemoryPersistence.writeBackup(of: first, to: backupURL)
        try JSONMemoryPersistence.writeBackup(of: second, to: backupURL)

        let reloaded = try await JSONMemoryPersistence(url: backupURL).load()
        #expect(reloaded.memories == second.memories)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == ["memory.graph.json.bak"])
    }

    @Test
    func backupIsOwnerOnly() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backupURL = directory.appendingPathComponent("memory.graph.json.bak")

        try JSONMemoryPersistence.writeBackup(of: Self.sampleGraph(contents: ["secret"]), to: backupURL)
        // A second write replaces the inode and must be private as well.
        try JSONMemoryPersistence.writeBackup(of: Self.sampleGraph(contents: ["secret 2"]), to: backupURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: backupURL.path)
        let permissions = try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
        #expect(permissions & 0o777 == 0o600)
    }
}
