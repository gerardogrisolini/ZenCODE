//
//  MemoryCleanupStoreTests.swift
//  ZenCODECoreTests
//
//  The store-level cleanup: one engine transaction that backs the graph up,
//  applies the plan and saves, or does nothing at all.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct MemoryCleanupStoreTests {
    private static let day: TimeInterval = 86_400

    /// Entries get distinct tags so every reverse-edge list has one source and
    /// graph equality does not depend on dictionary iteration order.
    private static func seed(
        _ workspace: MemoryTestWorkspace,
        contents: [String]
    ) async throws -> [String] {
        let service = MemoryService()
        var identifiers: [String] = []
        for (index, content) in contents.enumerated() {
            let entry = try await service.writeEntry(
                content: content,
                workspaceRootURL: workspace.workspaceURL,
                tags: ["tag-\(index)"]
            )
            identifiers.append(entry.id.uuidString)
        }
        return identifiers
    }

    private struct FileFingerprint: Equatable {
        let data: Data
        let modificationDate: Date?
        let fileNumber: UInt64?

        init(_ url: URL) throws {
            data = try Data(contentsOf: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            modificationDate = attributes[.modificationDate] as? Date
            fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        }
    }

    // MARK: - Cleanup transaction

    @Test
    func cleanupRemovesArchivedEntriesAndLeavesAMatchingBackup() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            try await MemoryEmbedding.withProvider(nil) {
                let identifiers = try await Self.seed(
                    workspace,
                    contents: ["Summary: keep this", "Summary: archive one", "Summary: archive two"]
                )
                let service = MemoryService()
                for id in identifiers.dropFirst() {
                    try await service.archiveEntry(id: id, workspaceRootURL: workspace.workspaceURL)
                }
                let graphURL = workspace.graphURL()
                let store = try await MemoryGraphStoreRegistry.shared.store(graphURL: graphURL)
                let before = try await store.engine.freshSnapshotForReadOnly()
                #expect(before.memories.count == 3)

                let report = try await store.cleanup(
                    MemoryCleanupPolicy(archivedRetentionDays: 30),
                    now: Date().addingTimeInterval(40 * Self.day)
                )

                #expect(Set(report.removedArchived.map(\.id)) == Set(identifiers.dropFirst()))
                #expect(report.archivedStale.isEmpty)
                #expect(report.totalEntries == 3)

                let backupURL = graphURL.appendingPathExtension("bak")
                #expect(backupURL.lastPathComponent == "memory.graph.json.bak")
                let backup = try await JSONMemoryPersistence(url: backupURL).load()
                #expect(backup == before)

                let inMemory = await store.engine.snapshot()
                #expect(Set(inMemory.memories.keys) == [identifiers[0]])
                let onDisk = try await JSONMemoryPersistence(url: graphURL).load()
                #expect(onDisk == inMemory)

                // The backup is never read by the engine as the graph.
                let reopened = try await MemoryGraphStore.open(graphURL: graphURL)
                #expect(try await reopened.entries(includeArchived: true, limit: 10).count == 1)
            }
        }
    }

    @Test
    func previewReportsTheCleanupWithoutChangingAnything() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            try await MemoryEmbedding.withProvider(nil) {
                let identifiers = try await Self.seed(workspace, contents: ["Summary: one", "Summary: two"])
                try await MemoryService().archiveEntry(
                    id: identifiers[1],
                    workspaceRootURL: workspace.workspaceURL
                )
                let graphURL = workspace.graphURL()
                let store = try await MemoryGraphStoreRegistry.shared.store(graphURL: graphURL)
                let policy = MemoryCleanupPolicy(archivedRetentionDays: 30)
                let now = Date().addingTimeInterval(40 * Self.day)
                let fingerprint = try FileFingerprint(graphURL)

                let preview = try await store.cleanupPreview(policy, now: now)

                #expect(preview.removedArchived.map(\.id) == [identifiers[1]])
                #expect(try FileFingerprint(graphURL) == fingerprint)
                #expect(!FileManager.default.fileExists(atPath: graphURL.appendingPathExtension("bak").path))
                #expect(await store.engine.snapshot().memories.count == 2)

                let applied = try await store.cleanup(policy, now: now)
                #expect(applied == preview)
            }
        }
    }

    @Test
    func cleanupWithNothingToDoLeavesGraphAndBackupAlone() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            try await MemoryEmbedding.withProvider(nil) {
                let identifiers = try await Self.seed(workspace, contents: ["Summary: one", "Summary: two"])
                try await MemoryService().archiveEntry(
                    id: identifiers[1],
                    workspaceRootURL: workspace.workspaceURL
                )
                let graphURL = workspace.graphURL()
                let backupURL = graphURL.appendingPathExtension("bak")
                let store = try await MemoryGraphStoreRegistry.shared.store(graphURL: graphURL)
                let policy = MemoryCleanupPolicy(archivedRetentionDays: 30, graphHygiene: true)

                // Nothing is old enough yet: no backup, no rewrite.
                let early = try await store.cleanup(policy, now: Date())
                #expect(early.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: backupURL.path))

                let first = try await store.cleanup(policy, now: Date().addingTimeInterval(40 * Self.day))
                #expect(!first.isEmpty)
                let graphAfterFirst = try FileFingerprint(graphURL)
                let backupAfterFirst = try FileFingerprint(backupURL)

                let second = try await store.cleanup(policy, now: Date().addingTimeInterval(41 * Self.day))
                #expect(second.isEmpty)
                #expect(try FileFingerprint(graphURL) == graphAfterFirst)
                #expect(try FileFingerprint(backupURL) == backupAfterFirst)
            }
        }
    }

    @Test
    func failingBackupLeavesTheGraphUntouched() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            try await MemoryEmbedding.withProvider(nil) {
                let identifiers = try await Self.seed(workspace, contents: ["Summary: one", "Summary: two"])
                try await MemoryService().archiveEntry(
                    id: identifiers[1],
                    workspaceRootURL: workspace.workspaceURL
                )
                let graphURL = workspace.graphURL()
                let store = try await MemoryGraphStoreRegistry.shared.store(graphURL: graphURL)
                // A directory where the backup must go makes the backup fail.
                let backupURL = graphURL.appendingPathExtension("bak")
                try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: false)
                let fingerprint = try FileFingerprint(graphURL)
                let before = await store.engine.snapshot()

                await #expect(throws: (any Error).self) {
                    try await store.cleanup(
                        MemoryCleanupPolicy(archivedRetentionDays: 30),
                        now: Date().addingTimeInterval(40 * Self.day)
                    )
                }

                #expect(try FileFingerprint(graphURL) == fingerprint)
                #expect(await store.engine.snapshot() == before)
            }
        }
    }

    // MARK: - Rules through the store

    @Test
    func staleRuleArchivesNeverRecalledEntriesThroughTheStore() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            try await MemoryEmbedding.withProvider(nil) {
                let identifiers = try await Self.seed(workspace, contents: ["Summary: one", "Summary: two"])
                let graphURL = workspace.graphURL()
                let store = try await MemoryGraphStoreRegistry.shared.store(graphURL: graphURL)

                let report = try await store.cleanup(
                    MemoryCleanupPolicy(staleInactivityDays: 180),
                    now: Date().addingTimeInterval(400 * Self.day)
                )

                #expect(Set(report.archivedStale.map(\.id)) == Set(identifiers))
                let onDisk = try await JSONMemoryPersistence(url: graphURL).load()
                #expect(onDisk.memories.count == 2)
                #expect(onDisk.memories.values.allSatisfy { !$0.active })
            }
        }
    }

    // MARK: - Embeddings

    @Test
    func hygieneKeepsOnlyVectorsFromTheStoresOwnProvider() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            let modelA = DeterministicHashEmbeddingProvider(modelID: "model-a")
            let modelB = DeterministicHashEmbeddingProvider(modelID: "model-b")

            for (provider, content) in [
                (modelA as (any EmbeddingProvider)?, "Summary: embedded with a"),
                (modelB, "Summary: embedded with b"),
                (nil, "Summary: not embedded"),
            ] {
                let writer = try await MemoryEmbedding.withProvider(provider) {
                    try await MemoryGraphStore.open(graphURL: graphURL)
                }
                _ = try await writer.write(content: content, category: .fact, tags: [])
            }
            let seeded = try await JSONMemoryPersistence(url: graphURL).load()
            #expect(Set(seeded.memories.values.compactMap(\.embeddingModel)) == ["model-a", "model-b"])

            let storeA = try await MemoryEmbedding.withProvider(modelA) {
                try await MemoryGraphStore.open(graphURL: graphURL)
            }
            let policy = MemoryCleanupPolicy(graphHygiene: true)
            let previewA = try await storeA.cleanupPreview(policy)
            #expect(previewA.clearedEmbeddings == 1)
            let reportA = try await storeA.cleanup(policy)
            #expect(reportA.clearedEmbeddings == 1)

            let afterA = try await JSONMemoryPersistence(url: graphURL).load()
            #expect(afterA.memories.count == 3)
            #expect(afterA.memories.values.compactMap(\.embeddingModel) == ["model-a"])
            #expect(afterA.memories.values.filter { $0.embedding != nil }.count == 1)

            // Without a provider nothing can use any vector.
            let storeNone = try await MemoryEmbedding.withProvider(nil) {
                try await MemoryGraphStore.open(graphURL: graphURL)
            }
            let reportNone = try await storeNone.cleanup(policy)
            #expect(reportNone.clearedEmbeddings == 1)
            let afterNone = try await JSONMemoryPersistence(url: graphURL).load()
            #expect(afterNone.memories.values.allSatisfy { $0.embedding == nil && $0.embeddingModel == nil })
        }
    }

    // MARK: - Registry

    @Test
    func removeDiscardsOnlyThatGraphsCachedStore() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            try await MemoryEmbedding.withProvider(nil) {
                let registry = MemoryGraphStoreRegistry()
                let graphURL = workspace.graphURL()
                let otherURL = workspace.rootURL
                    .appendingPathComponent("other", isDirectory: true)
                    .appendingPathComponent("memory.graph.json")

                let store = try await registry.store(graphURL: graphURL)
                let other = try await registry.store(graphURL: otherURL)
                #expect(try await registry.store(graphURL: graphURL) === store)
                _ = try await store.write(content: "Summary: persisted", category: .fact, tags: [])

                await registry.remove(graphURL: graphURL)

                let reopened = try await registry.store(graphURL: graphURL)
                #expect(reopened !== store)
                #expect(try await reopened.entries(includeArchived: true, limit: 10).count == 1)
                #expect(try await registry.store(graphURL: otherURL) === other)
            }
        }
    }
}
