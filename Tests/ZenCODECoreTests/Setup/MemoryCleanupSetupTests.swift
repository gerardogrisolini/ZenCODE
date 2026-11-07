//
//  MemoryCleanupSetupTests.swift
//  ZenCODECoreTests
//
//  The pure parts of Data management › Clean memory: graph inventory, menu
//  builders, policy mapping and the report renderer.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct MemoryCleanupSetupTests {
    private typealias Runner = ZenCODESetupRunner

    private struct Fixture {
        let rootURL: URL
        let supportURL: URL
        let workspaceURL: URL
        let currentKey: String

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("zencode-memory-cleanup-\(UUID().uuidString)", isDirectory: true)
            supportURL = rootURL.appendingPathComponent("support", isDirectory: true)
            workspaceURL = rootURL.appendingPathComponent("Current Project", isDirectory: true)
            currentKey = ProjectStorageKey.key(for: workspaceURL)
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }

        /// Creates `<support>/memory/<name>/` with an optional graph file.
        @discardableResult
        func makeProjectDirectory(_ name: String, graphBytes: Int? = nil) throws -> URL {
            let directory = supportURL
                .appendingPathComponent("memory", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let graphBytes {
                try Data(repeating: 0x20, count: graphBytes)
                    .write(to: directory.appendingPathComponent("memory.graph.json"))
            }
            return directory
        }

        func inventory() -> [ZenCODESetupRunner.MemoryGraphInventoryItem] {
            ZenCODESetupRunner.memoryGraphInventory(
                supportDirectoryURL: supportURL,
                currentWorkspaceURL: workspaceURL
            )
        }
    }

    // MARK: - Inventory

    @Test
    func inventoryListsGraphDirectoriesCurrentThenGlobalThenAlphabetical() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeProjectDirectory("zeta-0123456789abcdef01234567", graphBytes: 10)
        try fixture.makeProjectDirectory("Alpha-0123456789abcdef01234567", graphBytes: 20)
        try fixture.makeProjectDirectory("beta-0123456789abcdef01234567", graphBytes: 30)
        try fixture.makeProjectDirectory("global", graphBytes: 40)
        try fixture.makeProjectDirectory(fixture.currentKey, graphBytes: 1_500)
        // Not graphs: a directory without the file, one holding only a backup,
        // and a stray file.
        try fixture.makeProjectDirectory("empty-0123456789abcdef01234567")
        let backupOnly = try fixture.makeProjectDirectory("backup-0123456789abcdef01234567")
        try Data("{}".utf8).write(to: backupOnly.appendingPathComponent("memory.graph.json.bak"))
        try Data("note".utf8).write(
            to: fixture.supportURL.appendingPathComponent("memory/notes.txt")
        )

        let inventory = fixture.inventory()

        #expect(inventory.map(\.directoryName) == [
            fixture.currentKey,
            "global",
            "Alpha-0123456789abcdef01234567",
            "beta-0123456789abcdef01234567",
            "zeta-0123456789abcdef01234567",
        ])
        #expect(inventory.map(\.isCurrent) == [true, false, false, false, false])
        #expect(inventory.map(\.isGlobal) == [false, true, false, false, false])
        #expect(inventory.map(\.fileSize) == [1_500, 40, 20, 30, 10])
        #expect(inventory.allSatisfy { $0.modifiedAt != nil })
        for item in inventory {
            #expect(item.graphURL.lastPathComponent == "memory.graph.json")
            #expect(item.graphURL.deletingLastPathComponent().lastPathComponent == item.directoryName)
            #expect(item.directoryURL.lastPathComponent == item.directoryName)
        }
    }

    @Test
    func inventoryGraphURLMatchesTheOneTheRegistryKeysTheCurrentProjectBy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeProjectDirectory(fixture.currentKey, graphBytes: 2)

        let expected = AppStorageDirectory.withSupportDirectoryURL(fixture.supportURL) {
            MemoryGraphLocation.graphURL(for: fixture.workspaceURL)
        }
        let current = try #require(fixture.inventory().first)

        #expect(current.isCurrent)
        #expect(current.graphURL == expected)
    }

    // MARK: - Menus

    @Test
    func deleteFolderIsOfferedOnlyForAnotherProject() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeProjectDirectory(fixture.currentKey, graphBytes: 1)
        try fixture.makeProjectDirectory("global", graphBytes: 1)
        try fixture.makeProjectDirectory("other-0123456789abcdef01234567", graphBytes: 1)
        let inventory = fixture.inventory()
        let current = try #require(inventory.first { $0.isCurrent })
        let global = try #require(inventory.first { $0.isGlobal })
        let other = try #require(inventory.first { !$0.isCurrent && !$0.isGlobal })

        #expect(Runner.memoryCleanupActionItems(for: current).map(\.value) == [.clean, .back])
        #expect(Runner.memoryCleanupActionItems(for: global).map(\.value) == [.clean, .back])
        let otherItems = Runner.memoryCleanupActionItems(for: other)
        #expect(otherItems.map(\.value) == [.clean, .deleteFolder, .back])
        #expect(otherItems.map(\.title) == [
            "Clean up entries",
            "Delete project memory folder",
            "Back",
        ])
    }

    @Test
    func policyUsesDaysOnlyForTheChosenRules() {
        #expect(
            Runner.memoryCleanupPolicy(
                rules: Runner.defaultMemoryCleanupRules,
                archivedRetentionDays: 30,
                staleInactivityDays: 180
            ) == MemoryCleanupPolicy(archivedRetentionDays: 30, staleInactivityDays: nil, graphHygiene: true)
        )
        #expect(
            Runner.memoryCleanupPolicy(
                rules: [.archiveStale],
                archivedRetentionDays: 30,
                staleInactivityDays: 90
            ) == MemoryCleanupPolicy(archivedRetentionDays: nil, staleInactivityDays: 90, graphHygiene: false)
        )
    }
}
