//
//  TerminalChat+FileChanges.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    /// Replacing the actor also fences restores that reuse the same session ID.
    func resetFileArtifactState() {
        lastFileChangeSummary = nil
        fileArtifactHistory = SessionFileArtifactHistory(sessionID: sessionID)
    }

    public func publishFileChangeSummaryIfNeeded(
        from coordinator: TurnFileChangeCoordinator
    ) async -> TurnFileChangeSummary? {
        guard let summary = await collectFileChangeSummaryIfNeeded(from: coordinator) else {
            return nil
        }

        await writeFileChangeSummary(summary, includeDiff: false)
        return summary
    }

    public func collectFileChangeSummaryIfNeeded(
        from coordinator: TurnFileChangeCoordinator,
        sessionID expectedSessionID: String? = nil,
        history expectedHistory: SessionFileArtifactHistory? = nil
    ) async -> TurnFileChangeSummary? {
        let observedSessionID = expectedSessionID ?? sessionID
        let history = expectedHistory ?? fileArtifactHistory
        guard let summary = await coordinator.publishSummaryIfNeeded() else {
            return nil
        }
        // A session switch may race the final reconciliation of an old turn.
        // Keep both the latest-summary slot and the runtime artifact history
        // fenced to the session that started the turn.
        guard sessionID == observedSessionID, fileArtifactHistory === history else {
            return nil
        }
        lastFileChangeSummary = summary
        await history.append(
            summary: summary,
            sessionID: observedSessionID,
            workingDirectory: configuration.workingDirectory
        )
        guard sessionID == observedSessionID, fileArtifactHistory === history else { return nil }
        return summary
    }

    public func handleArtifactsCommand() async {
        let turns = await fileArtifactHistory.snapshot()
        guard !turns.isEmpty else {
            await writeSystemMessage("No file artifacts in the current session.\n")
            return
        }
        await renderCoordinator.writeMarkdownMessage(
            Self.renderFileArtifacts(
                turns,
                columnWidth: Self.terminalColumnCount(),
                isEnabled: AgentOutput.standardErrorIsTerminal
            ),
            to: .standardError
        )
    }

    public nonisolated static func renderFileArtifacts(
        _ turns: [SessionFileArtifactHistory.Turn],
        columnWidth: Int = 100,
        isEnabled: Bool = false
    ) -> String {
        // The source is intentionally emitted as Markdown and rendered by the
        // same formatter as assistant output. Keep these parameters for source
        // compatibility with callers that used the preformatted renderer; the
        // Markdown formatter owns terminal width and ANSI capability now.
        _ = columnWidth
        _ = isEnabled

        var lines = ["", "🪬 Artifacts"]
        for turn in turns {
            let count = turn.artifacts.count == 1 ? "1 file" : "\(turn.artifacts.count) files"
            lines.append("")
            lines.append("### Turn \(turn.number) — \(count)")
            for artifact in turn.artifacts {
                lines.append("")
                lines.append(renderFileArtifactMetadata(artifact))

                if let explanation = artifact.explanation?.nilIfBlank {
                    lines.append("Explanation: \(explanation)")
                }

                guard !artifact.isBinary else {
                    continue
                }

                let languagePath = artifact.displayPath.nilIfBlank ?? artifact.absolutePath
                let language = codeLanguageHint(forPath: languagePath)
                if let oldText = artifact.oldText, let newText = artifact.newText {
                    lines.append("**Before**")
                    appendMarkdownCodeBlock(
                        oldText,
                        language: language,
                        to: &lines
                    )
                    lines.append("**After**")
                    appendMarkdownCodeBlock(
                        newText,
                        language: language,
                        to: &lines
                    )
                } else if let text = artifact.newText ?? artifact.oldText {
                    appendMarkdownCodeBlock(
                        text,
                        language: language,
                        to: &lines
                    )
                } else if let patch = artifact.patch?.nilIfBlank {
                    lines.append("**Patch**")
                    appendMarkdownCodeBlock(
                        patch,
                        language: language,
                        to: &lines
                    )
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private nonisolated static func renderFileArtifactMetadata(
        _ artifact: FileChangeArtifact
    ) -> String {
        let path = artifact.displayPath.nilIfBlank ?? artifact.absolutePath
        let displayedPath = path.nilIfBlank ?? "(unknown path)"
        let counts = "+\(artifact.additions) -\(artifact.deletions)"
        let binary = artifact.isBinary ? " (binary)" : ""
        return "**\(artifact.status.rawValue) `\(markdownInlineCode(displayedPath))`**  \(counts)\(binary)"
    }

    private nonisolated static func appendMarkdownCodeBlock(
        _ text: String,
        language: String?,
        to lines: inout [String]
    ) {
        let fence = markdownCodeFence(for: text, language: language)
        lines.append(fence)
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var contentLines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // The separator before the closing fence represents the source's
        // trailing newline; do not turn it into an extra blank source line.
        if normalized.hasSuffix("\n"), !contentLines.isEmpty {
            contentLines.removeLast()
        }
        lines.append(contentsOf: contentLines)
        lines.append(String(repeating: "`", count: fence.prefix(while: { $0 == "`" }).count))
    }

    private nonisolated static func markdownCodeFence(
        for text: String,
        language: String?
    ) -> String {
        var longestBacktickRun = 0
        var currentBacktickRun = 0
        for character in text {
            if character == "`" {
                currentBacktickRun += 1
                longestBacktickRun = max(longestBacktickRun, currentBacktickRun)
            } else {
                currentBacktickRun = 0
            }
        }
        let length = max(3, longestBacktickRun + 1)
        return String(repeating: "`", count: length) + (language ?? "")
    }

    private nonisolated static func markdownInlineCode(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "\\`")
    }

    public func handleChangesCommand(_ command: String) async {
        let arguments = Self.slashCommandArguments(
            from: command,
            commandPrefix: "/changes"
        ).lowercased()
        let includeDiff = arguments == "diff" || arguments == "--diff"

        guard let summary = lastFileChangeSummary else {
            await writeSystemMessage("No tracked file changes.\n")
            return
        }

        await writeFileChangeSummary(summary, includeDiff: includeDiff)
    }

    public func handleUndoFileChangesCommand() async {
        do {
            try await TurnFileChangeUndoService.undoLatest(
                summary: lastFileChangeSummary,
                baseDirectoryURL: configuration.workingDirectory
            )
            lastFileChangeSummary = nil
            await writeSystemMessage("File changes reverted.\n")
        } catch let error as TurnFileChangeUndoError {
            await writeSystemMessage("\(error.localizedDescription)\n")
        } catch {
            await writeFailureMessage(
                "ZenCODE: unable to undo file changes: \(error.localizedDescription)\n"
            )
        }
    }

    public func writeFileChangeSummary(
        _ summary: TurnFileChangeSummary,
        includeDiff: Bool
    ) async {
        await writeFileChangeSummaryMessage(Self.renderFileChangeSummary(summary))

        guard includeDiff else {
            return
        }

        await writeFileChangeDiffs(summary)
    }

    /// Emits the summary as the final terminal section of a completed prompt.
    /// `/changes` continues to use `writeFileChangeSummary`, whose interleaved
    /// behavior is appropriate for an operator command and optional diff.
    func writeFinalFileChangeSummary(_ summary: TurnFileChangeSummary) async {
        await renderCoordinator.writeFinalFileChangeSummaryMessage(
            Self.renderFileChangeSummary(summary)
        )
    }

    public nonisolated static func renderFileChangeSummary(
        _ summary: TurnFileChangeSummary
    ) -> String {
        let title = summary.fileCount == 1
            ? "1 file"
            : "\(summary.fileCount) files"
        let undoText = summary.canUndo
            ? "Use /undo to revert, /changes diff to show patches."
            : "Undo is not available for this summary."

        var lines = ["", "🪬 Summary: \(title)  +\(summary.totalAdditions) -\(summary.totalDeletions)"]
        lines.append(contentsOf: summary.entries.map(Self.renderFileChangeEntry))
        lines.append(undoText)
        return lines.joined(separator: "\n") + "\n"
    }

    public nonisolated static func renderFileChangeEntry(
        _ entry: TurnFileChangeSummary.Entry
    ) -> String {
        if entry.isBinary {
            return "  \(entry.status.rawValue) \(entry.path) (binary)"
        }

        return "  \(entry.status.rawValue) \(entry.path)  +\(entry.additions) -\(entry.deletions)"
    }

    nonisolated static func renderFileChangeDiffPatch(
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

    private nonisolated static func renderFileChangeDiffLine(_ line: String) -> String {
        let reset = TerminalStyle.reset
        let meta = TerminalStyle.FileChange.metadata
        let hunk = TerminalStyle.FileChange.hunk
        let addition = TerminalStyle.FileChange.addition
        let deletion = TerminalStyle.FileChange.deletion

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

    public func writeFileChangeDiffs(_ summary: TurnFileChangeSummary) async {
        let patches = summary.entries.compactMap { entry -> String? in
            guard !entry.isBinary,
                  let patch = entry.patch?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !patch.isEmpty else {
                return nil
            }
            return patch
        }

        guard !patches.isEmpty else {
            await writeSystemMessage("No text patches available.\n")
            return
        }

        let renderedPatch = Self.renderFileChangeDiffPatch(
            patches.joined(separator: "\n"),
            isEnabled: AgentOutput.standardErrorIsTerminal
        )
        await writeChatError("\n" + renderedPatch + "\n")
    }
}
