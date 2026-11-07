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
}
