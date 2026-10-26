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

    private static func summary(_ id: String, title: String = "Title") -> MemoryCleanupReport.EntrySummary {
        MemoryCleanupReport.EntrySummary(
            id: id,
            title: title,
            category: "fact",
            lastChange: Date(timeIntervalSince1970: 1_700_000_000)
        )
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

    @Test
    func inventoryIsEmptyWithoutAMemoryDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(fixture.inventory().isEmpty)
        try fixture.makeProjectDirectory("empty-0123456789abcdef01234567")
        #expect(fixture.inventory().isEmpty)
    }

    // MARK: - Menus

    @Test
    func graphMenuItemsDescribeEachGraph() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeProjectDirectory(fixture.currentKey, graphBytes: 1_500)
        try fixture.makeProjectDirectory("global", graphBytes: 1_024)
        try fixture.makeProjectDirectory("other-0123456789abcdef01234567", graphBytes: 0)

        let items = Runner.memoryGraphMenuItems(fixture.inventory())

        #expect(items.map(\.title) == [fixture.currentKey, "Global graph", "other-0123456789abcdef01234567"])
        let details = try items.map { try #require($0.detail) }
        for detail in details {
            #expect(detail.range(
                of: #"^\d+ KB, modified \d{4}-\d{2}-\d{2}"#,
                options: .regularExpression
            ) != nil)
        }
        #expect(details[0].hasPrefix("2 KB, modified "))
        #expect(details[0].hasSuffix(", current project"))
        #expect(details[1].hasPrefix("1 KB, modified "))
        #expect(!details[1].contains("current project"))
        #expect(details[2].hasPrefix("0 KB, modified "))
        #expect(!details[2].contains("current project"))
    }

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
    func ruleItemsCiteTheDefaultsAndPreselectTheSafeRules() {
        let items = Runner.memoryCleanupRuleItems()

        #expect(items.map(\.title) == [
            "Remove archived entries",
            "Archive stale entries",
            "Graph hygiene",
        ])
        #expect(items.map(\.value) == [.removeArchived, .archiveStale, .hygiene])
        #expect(items[0].detail?.contains("30") == true)
        #expect(items[1].detail?.contains("180") == true)
        #expect(Runner.defaultMemoryCleanupRules == [.removeArchived, .hygiene])
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

    @Test
    func dayCountsMustBeWholeNumbersAtLeastTheMinimum() {
        #expect(Runner.parseCleanupDays("30", minimum: 0) == 30)
        #expect(Runner.parseCleanupDays(" 0 ", minimum: 0) == 0)
        #expect(Runner.parseCleanupDays("0", minimum: 1) == nil)
        #expect(Runner.parseCleanupDays("-4", minimum: 0) == nil)
        #expect(Runner.parseCleanupDays("2.5", minimum: 0) == nil)
        #expect(Runner.parseCleanupDays("many", minimum: 0) == nil)
        #expect(Runner.parseCleanupDays("", minimum: 0) == nil)
    }

    // MARK: - Report

    @Test
    func emptyReportRendersNothingToClean() {
        let report = MemoryCleanupReport(totalEntries: 7, activeEntries: 5, archivedEntries: 2)
        let url = URL(fileURLWithPath: "/tmp/memory.graph.json")
        let text = Runner.renderMemoryCleanupReport(
            report,
            graphURL: url,
            policy: MemoryCleanupPolicy(archivedRetentionDays: 30, graphHygiene: true)
        )

        #expect(text.contains("/tmp/memory.graph.json"))
        #expect(text.contains("Entries: 7 (5 active, 2 archived)"))
        #expect(text.hasSuffix("Nothing to clean."))
        #expect(!text.contains("Remove archived"))
    }

    @Test
    func reportListsAtMostTwentyEntriesThenCountsTheRest() {
        var report = MemoryCleanupReport(totalEntries: 30, activeEntries: 0, archivedEntries: 30)
        report.removedArchived = (0..<25).map { Self.summary(String(format: "id-%02d", $0), title: "Entry \($0)") }
        let text = Runner.renderMemoryCleanupReport(
            report,
            graphURL: URL(fileURLWithPath: "/tmp/memory.graph.json"),
            policy: MemoryCleanupPolicy(archivedRetentionDays: 30)
        )

        #expect(text.contains("Remove archived entries (unchanged for at least 30 days): 25"))
        let entryLines = text.split(separator: "\n").filter { $0.hasPrefix("- [") }
        #expect(entryLines.count == 20)
        #expect(entryLines.first == "- [id-00] Entry 0")
        #expect(entryLines.last == "- [id-19] Entry 19")
        #expect(text.contains("… and 5 more"))
        #expect(!text.contains("id-20"))
        // Only the active rule has a section.
        #expect(!text.contains("Archive stale"))
        #expect(!text.contains("Graph hygiene"))
    }

    @Test
    func reportShowsOneSectionPerActiveRule() {
        var report = MemoryCleanupReport(totalEntries: 10, activeEntries: 6, archivedEntries: 4)
        report.removedArchived = [Self.summary("a1", title: "Old archived")]
        report.archivedStale = [Self.summary("s1", title: "Stale one"), Self.summary("s2", title: "Stale two")]
        report.removedSuperseded = [Self.summary("u1", title: "Superseded")]
        report.removedDanglingEdges = 3
        report.removedTags = 1
        report.removedClusters = 0
        report.clearedEmbeddings = 4
        let text = Runner.renderMemoryCleanupReport(
            report,
            graphURL: URL(fileURLWithPath: "/tmp/memory.graph.json"),
            policy: MemoryCleanupPolicy(
                archivedRetentionDays: 0,
                staleInactivityDays: 180,
                graphHygiene: true
            )
        )

        #expect(text.contains("Remove archived entries (all): 1"))
        #expect(text.contains("- [a1] Old archived"))
        #expect(text.contains("Archive stale entries (never recalled, unchanged for at least 180 days, scaled by category): 2"))
        #expect(text.contains("- [s2] Stale two"))
        #expect(text.contains(
            "Graph hygiene: 1 superseded entry, 3 dangling edges, 1 unused tag, 0 empty clusters, 4 embedding vectors"
        ))
        #expect(text.contains("- [u1] Superseded"))
        #expect(!text.contains("Nothing to clean."))
    }
}
