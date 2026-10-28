//
//  ZenCODESetupRunner+MemoryCleanup.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/10/26.
//
//  Setup › Data management › Clean memory: pick a memory graph, preview what a
//  cleanup would do, and apply it after an explicit confirmation, or delete
//  the memory folder of another project.
//

import Foundation

/// The memory cleanup flow of the data management submenu.
///
/// Only the durable graphs under `<support>/memory/` are in scope. The menu
/// builders and the report renderer are pure so tests can assert them without
/// a terminal; the interactive flow only wires them to prompts. Nothing here
/// is persisted: the thresholds are asked for each time.
extension ZenCODESetupRunner {
    /// One `memory.graph.json` found under the support directory.
    struct MemoryGraphInventoryItem: Hashable, Sendable {
        /// `<support>/memory/<directoryName>/`.
        let directoryURL: URL
        /// The graph file inside ``directoryURL``, in the form the registry keys
        /// its stores by.
        let graphURL: URL
        let directoryName: String
        /// The graph shared by every project.
        let isGlobal: Bool
        /// The graph of the project this session was launched in.
        let isCurrent: Bool
        /// Bytes of the graph JSON plus its vectors file when there is one;
        /// `nil` when the JSON's size cannot be read.
        let fileSize: Int64?
        let modifiedAt: Date?
    }

    enum MemoryCleanupAction: Hashable, Sendable {
        case clean
        case deleteFolder
        case back
    }

    enum MemoryCleanupRule: Hashable, Sendable {
        /// Rule A: remove archived entries unchanged for a while.
        case removeArchived
        /// Rule B: archive never-recalled entries unchanged for a long while.
        case archiveStale
        /// Rule C: superseded entries, dangling and excess links, empty tags and
        /// clusters, vectors the store cannot use.
        case hygiene
    }

    /// Rules ticked when the rule menu opens: the two that never discard an
    /// entry the operator still sees as active.
    static let defaultMemoryCleanupRules: Set<MemoryCleanupRule> = [.removeArchived, .hygiene]

    /// Entries listed per section of a report before "… and N more".
    static let memoryCleanupReportEntryLimit = 20

    // MARK: - Inventory

    /// The graphs under `<support>/memory/`: every sub-directory holding a
    /// graph file; other directories and stray files are ignored. The current
    /// project comes first, then the global graph, then the rest alphabetically
    /// (case-insensitive).
    static func memoryGraphInventory(
        supportDirectoryURL: URL,
        currentWorkspaceURL: URL,
        fileManager: FileManager = .default
    ) -> [MemoryGraphInventoryItem] {
        let memoryDirectoryURL = memoryDirectoryURL(supportDirectoryURL: supportDirectoryURL)
        guard let names = try? fileManager.contentsOfDirectory(atPath: memoryDirectoryURL.path) else {
            return []
        }
        let currentKey = ProjectStorageKey.key(for: currentWorkspaceURL)
        var items: [MemoryGraphInventoryItem] = []
        for name in names {
            let directoryURL = memoryDirectoryURL.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            let graphURL = directoryURL
                .appendingPathComponent(MemoryGraphLocation.graphFilename, isDirectory: false)
                .standardizedFileURL
            guard fileManager.fileExists(atPath: graphURL.path) else {
                continue
            }
            let attributes = try? fileManager.attributesOfItem(atPath: graphURL.path)
            // A graph is its JSON plus, from graph version 4, the vectors file.
            let vectorsSize = (try? fileManager.attributesOfItem(
                atPath: JSONMemoryPersistence.vectorsURL(forGraphAt: graphURL).path
            ))?[.size] as? NSNumber
            let graphSize = (attributes?[.size] as? NSNumber)?.int64Value
            items.append(
                MemoryGraphInventoryItem(
                    directoryURL: directoryURL,
                    graphURL: graphURL,
                    directoryName: name,
                    isGlobal: name == MemoryGraphLocation.globalDirectoryName,
                    isCurrent: name == currentKey,
                    fileSize: graphSize.map { $0 + (vectorsSize?.int64Value ?? 0) },
                    modifiedAt: attributes?[.modificationDate] as? Date
                )
            )
        }
        return items.sorted { lhs, rhs in
            let lhsRank = lhs.isCurrent ? 0 : (lhs.isGlobal ? 1 : 2)
            let rhsRank = rhs.isCurrent ? 0 : (rhs.isGlobal ? 1 : 2)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let order = lhs.directoryName.caseInsensitiveCompare(rhs.directoryName)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.directoryName < rhs.directoryName
        }
    }

    private static func memoryDirectoryURL(supportDirectoryURL: URL) -> URL {
        supportDirectoryURL.appendingPathComponent(
            MemoryGraphLocation.directoryName,
            isDirectory: true
        )
    }

    // MARK: - Menu builders

    static func memoryGraphMenuItems(
        _ inventory: [MemoryGraphInventoryItem]
    ) -> [TerminalCheckboxMenuItem<MemoryGraphInventoryItem>] {
        inventory.map { item in
            let size = item.fileSize.map { "\(($0 + 1_023) / 1_024) KB" } ?? "size unknown"
            let modified = item.modifiedAt.map(memoryGraphDateString) ?? "unknown"
            var detail = "\(size), modified \(modified)"
            if item.isCurrent {
                detail += ", current project"
            }
            return TerminalCheckboxMenuItem(
                value: item,
                title: item.isGlobal ? "Global graph" : item.directoryName,
                detail: detail
            )
        }
    }

    /// Deleting a folder is offered only for another project: the current
    /// project's graph is in use and the global graph is shared.
    static func memoryCleanupActionItems(
        for item: MemoryGraphInventoryItem
    ) -> [TerminalCheckboxMenuItem<MemoryCleanupAction>] {
        var items = [
            TerminalCheckboxMenuItem(
                value: MemoryCleanupAction.clean,
                title: "Clean up entries",
                detail: "preview, then clean this graph"
            )
        ]
        if !item.isGlobal, !item.isCurrent {
            items.append(
                TerminalCheckboxMenuItem(
                    value: .deleteFolder,
                    title: "Delete project memory folder",
                    detail: "remove this project's whole memory directory"
                )
            )
        }
        items.append(
            TerminalCheckboxMenuItem(
                value: .back,
                title: "Back",
                detail: "choose another graph"
            )
        )
        return items
    }

    static func memoryCleanupRuleItems() -> [TerminalCheckboxMenuItem<MemoryCleanupRule>] {
        [
            TerminalCheckboxMenuItem(
                value: .removeArchived,
                title: "Remove archived entries",
                detail: "delete archived entries unchanged for N days (default \(MemoryCleanupPolicy.defaultArchivedRetentionDays))"
            ),
            TerminalCheckboxMenuItem(
                value: .archiveStale,
                title: "Archive stale entries",
                detail: "archive never-recalled entries unchanged for N days (default \(MemoryCleanupPolicy.defaultStaleInactivityDays))"
            ),
            TerminalCheckboxMenuItem(
                value: .hygiene,
                title: "Graph hygiene",
                detail: "drop superseded entries, dangling links, excess links (more than \(MemoryRelationPolicy.default.maximumLinksPerMemory) per entry), unused tags and unusable embedding vectors"
            )
        ]
    }

    /// The policy for the chosen rules; the day counts matter only for the
    /// rules that use them.
    static func memoryCleanupPolicy(
        rules: Set<MemoryCleanupRule>,
        archivedRetentionDays: Int,
        staleInactivityDays: Int
    ) -> MemoryCleanupPolicy {
        MemoryCleanupPolicy(
            archivedRetentionDays: rules.contains(.removeArchived) ? archivedRetentionDays : nil,
            staleInactivityDays: rules.contains(.archiveStale) ? staleInactivityDays : nil,
            graphHygiene: rules.contains(.hygiene)
        )
    }

    /// A whole number of days of at least `minimum`, or `nil`.
    static func parseCleanupDays(_ rawValue: String, minimum: Int) -> Int? {
        guard let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value >= minimum else {
            return nil
        }
        return value
    }

    // MARK: - Report

    /// Human-readable preview (or result) of a cleanup, without a trailing
    /// newline. Each active rule gets a section with its count and at most
    /// ``memoryCleanupReportEntryLimit`` entry lines.
    static func renderMemoryCleanupReport(
        _ report: MemoryCleanupReport,
        graphURL: URL,
        policy: MemoryCleanupPolicy
    ) -> String {
        var lines = [
            "Graph: \(graphURL.path)",
            "Entries: \(report.totalEntries) (\(report.activeEntries) active, \(report.archivedEntries) archived)"
        ]
        guard !report.isEmpty else {
            lines.append("Nothing to clean.")
            return lines.joined(separator: "\n")
        }

        if let days = policy.archivedRetentionDays {
            let age = days == 0 ? "all" : "unchanged for at least \(plural(days, "day"))"
            lines.append("")
            lines.append("Remove archived entries (\(age)): \(report.removedArchived.count)")
            lines += entryLines(report.removedArchived)
        }
        if let days = policy.staleInactivityDays {
            lines.append("")
            lines.append(
                "Archive stale entries (never recalled, unchanged for at least \(plural(days, "day")), scaled by category): \(report.archivedStale.count)"
            )
            lines += entryLines(report.archivedStale)
        }
        if policy.graphHygiene {
            lines.append("")
            lines.append(
                "Graph hygiene: "
                    + [
                        plural(report.removedSuperseded.count, "superseded entry", plural: "superseded entries"),
                        plural(report.removedDanglingEdges, "dangling edge"),
                        plural(report.prunedRelations, "excess link"),
                        plural(report.removedTags, "unused tag"),
                        plural(report.removedClusters, "empty cluster"),
                        plural(report.clearedEmbeddings, "embedding vector")
                    ].joined(separator: ", ")
            )
            lines += entryLines(report.removedSuperseded)
            if report.clearedEmbeddings > 0 {
                lines.append("A cleared vector is regenerated when its entry is next written, updated or restored, or by Data management › Rebuild memory embeddings.")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func entryLines(_ entries: [MemoryCleanupReport.EntrySummary]) -> [String] {
        var lines = entries.prefix(memoryCleanupReportEntryLimit).map { "- [\($0.id)] \($0.title)" }
        if entries.count > memoryCleanupReportEntryLimit {
            lines.append("… and \(entries.count - memoryCleanupReportEntryLimit) more")
        }
        return lines
    }

    private static func plural(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
    }

    private static func memoryGraphDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Interactive flow

    /// Lets the operator pick a graph and clean it, or delete another
    /// project's memory folder, until they leave. Cancelling any prompt past
    /// the graph and action menus (`ZenCODESetupError.cancelled`) propagates
    /// with the data untouched.
    static func runMemoryCleanupMenu(
        fileManager: FileManager = .default
    ) async throws {
        let supportDirectoryURL = ZenFileService.supportDirectoryURL(fileManager: fileManager)
        let workspaceURL = AgentConfiguration.launchWorkingDirectoryURL(
            arguments: ZenCODECommandLineArgumentSanitizer.sanitized(CommandLine.arguments),
            environment: ProcessInfo.processInfo.environment
        )
        while true {
            let inventory = memoryGraphInventory(
                supportDirectoryURL: supportDirectoryURL,
                currentWorkspaceURL: workspaceURL,
                fileManager: fileManager
            )
            guard let first = inventory.first else {
                AgentOutput.standardError.writeString(
                    "No memory graphs found under \(memoryDirectoryURL(supportDirectoryURL: supportDirectoryURL).path).\n\n"
                )
                return
            }

            let item: MemoryGraphInventoryItem
            do {
                item = try promptMenuChoice(
                    title: "Clean memory: graph",
                    items: memoryGraphMenuItems(inventory),
                    selected: first
                )
            } catch ZenCODESetupError.cancelled {
                return
            }

            let action: MemoryCleanupAction
            do {
                action = try promptMenuChoice(
                    title: "Clean memory: \(item.isGlobal ? "Global graph" : item.directoryName)",
                    items: memoryCleanupActionItems(for: item),
                    selected: .clean
                )
            } catch ZenCODESetupError.cancelled {
                continue
            }

            switch action {
            case .back:
                continue
            case .clean:
                try await runMemoryGraphCleanup(item)
            case .deleteFolder:
                try await runMemoryFolderDeletion(item, fileManager: fileManager)
            }
        }
    }

    /// Rules, thresholds, preview, confirmation, then one atomic cleanup.
    private static func runMemoryGraphCleanup(
        _ item: MemoryGraphInventoryItem
    ) async throws {
        guard let choice = TerminalCheckboxMenu.selectWithFocus(
            title: "Clean memory: rules",
            items: memoryCleanupRuleItems(),
            selected: defaultMemoryCleanupRules,
            focused: nil
        ) else {
            return
        }
        let rules = choice.selected
        guard !rules.isEmpty else {
            AgentOutput.standardError.writeString("No rule selected.\n\n")
            return
        }

        var archivedRetentionDays = MemoryCleanupPolicy.defaultArchivedRetentionDays
        if rules.contains(.removeArchived) {
            archivedRetentionDays = try promptDays(
                "Remove archived entries older than (days)",
                defaultValue: MemoryCleanupPolicy.defaultArchivedRetentionDays,
                minimum: 0
            )
        }
        var staleInactivityDays = MemoryCleanupPolicy.defaultStaleInactivityDays
        if rules.contains(.archiveStale) {
            staleInactivityDays = try promptDays(
                "Archive entries unchanged for at least (days)",
                defaultValue: MemoryCleanupPolicy.defaultStaleInactivityDays,
                minimum: 1
            )
        }
        let policy = memoryCleanupPolicy(
            rules: rules,
            archivedRetentionDays: archivedRetentionDays,
            staleInactivityDays: staleInactivityDays
        )

        let store = try await MemoryGraphStoreRegistry.shared.store(graphURL: item.graphURL)
        let preview = try await store.cleanupPreview(policy)
        AgentOutput.standardError.writeString(
            "\n"
                + renderMemoryCleanupReport(preview, graphURL: item.graphURL, policy: policy)
                + "\n\n"
        )
        guard !preview.isEmpty else {
            return
        }

        let backup = JSONMemoryPersistence.backupURLs(forGraphAt: item.graphURL)
        let backupPath = backup.graph.path
        guard try promptYesNo(
            "Apply this cleanup to \(item.graphURL.path)?",
            defaultValue: false,
            help: "The current graph is first copied to \(backupPath) and its vectors to \(backup.vectors.lastPathComponent) (replacing any previous copy); the cleanup is one atomic transaction."
        ) else {
            AgentOutput.standardError.writeString("Cleanup cancelled.\n\n")
            return
        }

        let applied = try await store.cleanup(policy)
        var summary = "Cleanup applied.\n"
            + renderMemoryCleanupReport(applied, graphURL: item.graphURL, policy: policy)
            + "\n"
        if !applied.isEmpty {
            summary += "Backup: \(backupPath) and \(backup.vectors.lastPathComponent)\n"
        }
        AgentOutput.standardError.writeString(summary + "\n")
    }

    /// Deletes another project's whole memory directory after an explicit
    /// confirmation naming the exact path. No copy is kept.
    private static func runMemoryFolderDeletion(
        _ item: MemoryGraphInventoryItem,
        fileManager: FileManager
    ) async throws {
        guard !item.isCurrent, !item.isGlobal else {
            return
        }
        AgentOutput.standardError.writeString(
            """
            This removes the directory and every file in it:
              \(item.directoryURL.path)
            No copy is kept; export a backup from Data management first if needed.

            """
        )
        guard try promptYesNo(
            "Delete this project's memory folder?",
            defaultValue: false
        ) else {
            AgentOutput.standardError.writeString("Deletion cancelled.\n\n")
            return
        }
        await MemoryGraphStoreRegistry.shared.remove(graphURL: item.graphURL)
        try fileManager.removeItem(at: item.directoryURL)
        AgentOutput.standardError.writeString("Deleted \(item.directoryURL.path)\n\n")
    }

    /// Asks for a whole number of days, repeating until it is valid.
    private static func promptDays(
        _ label: String,
        defaultValue: Int,
        minimum: Int
    ) throws -> Int {
        while true {
            let rawValue = try promptString(
                label,
                defaultValue: String(defaultValue),
                allowEmpty: false
            )
            if let days = parseCleanupDays(rawValue, minimum: minimum) {
                return days
            }
            AgentOutput.standardError.writeString(
                "Enter a whole number of days, \(minimum) or more.\n"
            )
        }
    }
}
