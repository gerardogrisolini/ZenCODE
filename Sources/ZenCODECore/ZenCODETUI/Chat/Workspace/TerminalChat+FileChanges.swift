//
//  TerminalChat+FileChanges.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

extension TerminalChat {
    public func publishFileChangeSummaryIfNeeded(
        from coordinator: TurnFileChangeCoordinator
    ) async -> TurnFileChangeSummary? {
        guard let summary = await collectFileChangeSummaryIfNeeded(from: coordinator) else {
            return nil
        }

        writeFileChangeSummary(summary, includeDiff: false)
        return summary
    }

    public func collectFileChangeSummaryIfNeeded(
        from coordinator: TurnFileChangeCoordinator
    ) async -> TurnFileChangeSummary? {
        guard let summary = await coordinator.publishSummaryIfNeeded() else {
            return nil
        }

        lastFileChangeSummary = summary
        return summary
    }

    public func handleChangesCommand(_ command: String) {
        let arguments = String(command.dropFirst("/changes".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let includeDiff = arguments == "diff" || arguments == "--diff"

        guard let summary = lastFileChangeSummary else {
            writeSystemMessage("No tracked file changes.\n")
            return
        }

        writeFileChangeSummary(summary, includeDiff: includeDiff)
    }

    public func handleUndoFileChangesCommand() async {
        do {
            try await TurnFileChangeUndoService.undoLatest(
                summary: lastFileChangeSummary,
                baseDirectoryURL: configuration.workingDirectory
            )
            lastFileChangeSummary = nil
            writeSystemMessage("File changes reverted.\n")
        } catch let error as TurnFileChangeUndoError {
            writeSystemMessage("\(error.localizedDescription)\n")
        } catch {
            writeFailureMessage(
                "ZenCODE: unable to undo file changes: \(error.localizedDescription)\n"
            )
        }
    }

    public func writeFileChangeSummary(
        _ summary: TurnFileChangeSummary,
        includeDiff: Bool
    ) {
        writeFileChangeSummaryMessage(Self.renderFileChangeSummary(summary))

        guard includeDiff else {
            return
        }

        writeFileChangeDiffs(summary)
    }

    public static func renderFileChangeSummary(
        _ summary: TurnFileChangeSummary
    ) -> String {
        let title = summary.fileCount == 1
            ? "1 file"
            : "\(summary.fileCount) files"
        let undoText = summary.canUndo
            ? "Use /undo to revert, /changes diff to show patches."
            : "Undo is not available for this summary."

        var lines = ["", "Summary: \(title)  +\(summary.totalAdditions) -\(summary.totalDeletions)"]
        lines.append(contentsOf: summary.entries.map(Self.renderFileChangeEntry))
        lines.append(undoText)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func renderFileChangeEntry(
        _ entry: TurnFileChangeSummary.Entry
    ) -> String {
        if entry.isBinary {
            return "  \(entry.status.rawValue) \(entry.path) (binary)"
        }

        return "  \(entry.status.rawValue) \(entry.path)  +\(entry.additions) -\(entry.deletions)"
    }

    static func renderFileChangeDiffPatch(
        _ patch: String,
        isEnabled: Bool
    ) -> String {
        guard isEnabled, !patch.isEmpty else {
            return patch
        }

        return patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { renderFileChangeDiffLine(String($0)) }
            .joined(separator: "\n")
    }

    private static func renderFileChangeDiffLine(_ line: String) -> String {
        let reset = "\u{1B}[0m"
        let meta = "\u{1B}[38;5;244m"
        let hunk = "\u{1B}[38;5;141m"
        let addition = "\u{1B}[38;5;114m"
        let deletion = "\u{1B}[38;5;203m"

        guard !line.isEmpty else {
            return line
        }

        if line.hasPrefix("@@") {
            return "\(hunk)\(line)\(reset)"
        }
        if line.hasPrefix("diff --git")
            || line.hasPrefix("index ")
            || line.hasPrefix("--- ")
            || line.hasPrefix("+++ ")
            || line.hasPrefix("new file mode ")
            || line.hasPrefix("deleted file mode ")
            || line.hasPrefix("similarity index ")
            || line.hasPrefix("rename from ")
            || line.hasPrefix("rename to ") {
            return "\(meta)\(line)\(reset)"
        }
        if line.hasPrefix("+") {
            return "\(addition)\(line)\(reset)"
        }
        if line.hasPrefix("-") {
            return "\(deletion)\(line)\(reset)"
        }
        return line
    }

    public func writeFileChangeDiffs(_ summary: TurnFileChangeSummary) {
        let patches = summary.entries.compactMap { entry -> String? in
            guard !entry.isBinary,
                  let patch = entry.patch?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !patch.isEmpty else {
                return nil
            }
            return patch
        }

        guard !patches.isEmpty else {
            writeSystemMessage("No text patches available.\n")
            return
        }

        let renderedPatch = Self.renderFileChangeDiffPatch(
            patches.joined(separator: "\n"),
            isEnabled: AgentOutput.standardErrorIsTerminal
        )
        writeChatError("\n" + renderedPatch + "\n")
    }
}
