//
//  ZenCODESetupRunner+SupportDirectoryCleanupFlow.swift
//  ZenCODE
//
//  Menu items, reports and the interactive flow of the support directory
//  cleanup.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

extension ZenCODESetupRunner {
    // MARK: - Menu and report

    /// One preselectable item per group that has something to delete and is
    /// not skipped.
    static func supportCleanupMenuItems(
        _ inventory: [SupportCleanupGroupInventory]
    ) -> [TerminalCheckboxMenuItem<SupportCleanupGroup>] {
        inventory
            .filter { $0.skipReason == nil && !$0.items.isEmpty }
            .map { group in
                TerminalCheckboxMenuItem(
                    value: group.group,
                    title: group.group.title,
                    detail: "\(supportCleanupByteString(group.totalBytes)), \(group.group.detail)"
                )
            }
    }

    /// One line per group of the inventory that is not offered, or `nil`.
    static func renderSupportCleanupSkippedGroups(
        _ inventory: [SupportCleanupGroupInventory]
    ) -> String? {
        let lines = inventory.compactMap { group in
            group.skipReason.map {
                "Skipped \(group.group.title) (\(supportCleanupByteString(group.totalBytes))): \($0)"
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The exact paths and sizes of the chosen groups and their total,
    /// without a trailing newline.
    static func renderSupportCleanupReport(
        _ groups: [SupportCleanupGroupInventory],
        supportDirectoryURL: URL
    ) -> String {
        var lines = ["Support directory: \(supportDirectoryURL.standardizedFileURL.path)"]
        for group in groups {
            lines.append("")
            lines.append("\(group.group.title): \(supportCleanupByteString(group.totalBytes))")
            lines += group.items.map {
                "- \($0.url.path) (\(supportCleanupByteString($0.bytes)))"
            }
        }
        lines.append("")
        lines.append("Total: \(supportCleanupByteString(groups.reduce(0) { $0 + $1.totalBytes }))")
        return lines.joined(separator: "\n")
    }

    /// Freed bytes, skipped groups and failures, without a trailing newline.
    static func renderSupportCleanupSummary(_ result: SupportCleanupResult) -> String {
        let count = result.deleted.count
        var lines = [
            "Freed \(supportCleanupByteString(result.freedBytes)) (\(count) \(count == 1 ? "path" : "paths") deleted)."
        ]
        lines += result.skipped.map { "Skipped \($0.group.title): \($0.reason)" }
        if !result.failures.isEmpty {
            lines.append("Not deleted:")
            lines += result.failures.map { "- \($0.url.path): \($0.reason)" }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Interactive flow

    /// How ``runSupportDirectoryCleanupStep(supportDirectoryURL:fileManager:write:selectGroups:confirmDeletion:)``
    /// ended.
    enum SupportCleanupStepOutcome: Equatable, Sendable {
        /// No group had something to delete (or every one was skipped).
        case nothingToClean
        /// The operator unchecked every group.
        case noGroupSelected
        /// Esc on the group menu.
        case menuCancelled
        /// No on "Delete these files?".
        case declined
        /// Esc on "Delete these files?".
        case confirmationCancelled
        /// The chosen groups were deleted; failures and skips are in the result.
        case applied(SupportCleanupResult)
    }

    /// The group menu of the cleanup: every offered group preselected.
    /// Returns `nil` on Esc.
    static func selectSupportCleanupGroups(
        _ items: [TerminalCheckboxMenuItem<SupportCleanupGroup>]
    ) -> Set<SupportCleanupGroup>? {
        TerminalCheckboxMenu.selectWithFocus(
            title: "Clean support directory",
            items: items,
            selected: Set(items.map(\.value)),
            focused: nil
        )?.selected
    }

    /// The "Delete these files?" confirmation (default No). Throws
    /// `ZenCODESetupError.cancelled` on Esc.
    static func confirmSupportCleanupDeletion() throws -> Bool {
        try promptYesNo(
            "Delete these files?",
            defaultValue: false,
            help: "No copy is kept. Everything listed is regenerated: Chrome downloads its on-device model again and rebuilds its caches, and the features, the app and ZenCRON rebuild from scratch on their next update."
        )
    }

    /// Measures, lets the operator choose the groups, shows the exact paths
    /// and deletes them after a confirmation, writing the measuring line, the
    /// skipped groups, "Nothing to clean", "No group selected", the report
    /// and the summary. Messages that depend on the outcome ("Cleanup
    /// cancelled.", …) are left to the caller. Only `ZenCODESetupError.cancelled`
    /// from `confirmDeletion` is mapped (to ``SupportCleanupStepOutcome/confirmationCancelled``);
    /// any other error propagates. Nothing is deleted unless the outcome is
    /// ``SupportCleanupStepOutcome/applied(_:)``. No copy is kept.
    ///
    /// `write`, `selectGroups` and `confirmDeletion` replace the terminal in
    /// tests.
    static func runSupportDirectoryCleanupStep(
        supportDirectoryURL: URL,
        fileManager: FileManager = .default,
        write: (String) -> Void = { AgentOutput.standardError.writeString($0) },
        selectGroups: ([TerminalCheckboxMenuItem<SupportCleanupGroup>]) -> Set<SupportCleanupGroup>? = {
            selectSupportCleanupGroups($0)
        },
        confirmDeletion: () throws -> Bool = { try confirmSupportCleanupDeletion() }
    ) throws -> SupportCleanupStepOutcome {
        write("Measuring the regenerable data under \(supportDirectoryURL.path)…\n")
        let inventory = supportCleanupInventory(
            supportDirectoryURL: supportDirectoryURL,
            fileManager: fileManager
        )
        if let skipped = renderSupportCleanupSkippedGroups(inventory) {
            write(skipped + "\n")
        }
        let items = supportCleanupMenuItems(inventory)
        guard !items.isEmpty else {
            write("Nothing to clean under \(supportDirectoryURL.path).\n\n")
            return .nothingToClean
        }

        guard let selection = selectGroups(items) else {
            return .menuCancelled
        }
        let selectedGroups = inventory.filter {
            $0.skipReason == nil && selection.contains($0.group)
        }
        guard !selectedGroups.isEmpty else {
            write("No group selected.\n\n")
            return .noGroupSelected
        }

        write(
            "\n"
                + renderSupportCleanupReport(selectedGroups, supportDirectoryURL: supportDirectoryURL)
                + "\n\n"
        )
        let confirmed: Bool
        do {
            confirmed = try confirmDeletion()
        } catch ZenCODESetupError.cancelled {
            return .confirmationCancelled
        }
        guard confirmed else {
            return .declined
        }

        let result = applySupportDirectoryCleanup(
            selectedGroups,
            supportDirectoryURL: supportDirectoryURL,
            fileManager: fileManager
        )
        write(renderSupportCleanupSummary(result) + "\n\n")
        return .applied(result)
    }

    /// Data management › Clean support directory: the cleanup step on the
    /// support directory. Esc on the group menu returns silently; No or Esc
    /// on the confirmation writes "Cleanup cancelled.". Cancelling any prompt
    /// leaves every file in place. No copy is kept.
    static func runSupportDirectoryCleanup(
        fileManager: FileManager = .default
    ) throws {
        try runSupportDirectoryCleanup(
            supportDirectoryURL: ZenFileService.supportDirectoryURL(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    /// ``runSupportDirectoryCleanup(fileManager:)`` on an explicit support
    /// directory, with the terminal replaceable in tests.
    static func runSupportDirectoryCleanup(
        supportDirectoryURL: URL,
        fileManager: FileManager = .default,
        write: (String) -> Void = { AgentOutput.standardError.writeString($0) },
        selectGroups: ([TerminalCheckboxMenuItem<SupportCleanupGroup>]) -> Set<SupportCleanupGroup>? = {
            selectSupportCleanupGroups($0)
        },
        confirmDeletion: () throws -> Bool = { try confirmSupportCleanupDeletion() }
    ) throws {
        let outcome = try runSupportDirectoryCleanupStep(
            supportDirectoryURL: supportDirectoryURL,
            fileManager: fileManager,
            write: write,
            selectGroups: selectGroups,
            confirmDeletion: confirmDeletion
        )
        switch outcome {
        case .declined, .confirmationCancelled:
            write("Cleanup cancelled.\n\n")
        case .nothingToClean, .noGroupSelected, .menuCancelled, .applied:
            break
        }
    }
}
