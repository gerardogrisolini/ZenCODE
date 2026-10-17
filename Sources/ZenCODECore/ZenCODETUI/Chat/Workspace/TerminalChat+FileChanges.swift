//
//  TerminalChat+FileChanges.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    @TerminalChatActor
    final class FileArtifactTurnContext {
        let id: UUID
        let sessionID: String
        let history: SessionFileArtifactHistory
        let coordinator: TurnFileChangeCoordinator?
        var pendingPublication: Task<Void, Never>?
        var acceptsPublications = true

        init(id: UUID, sessionID: String, history: SessionFileArtifactHistory, coordinator: TurnFileChangeCoordinator?) {
            self.id = id
            self.sessionID = sessionID
            self.history = history
            self.coordinator = coordinator
        }
    }

    func beginFileArtifactTurn(coordinator: TurnFileChangeCoordinator? = nil) async -> FileArtifactTurnContext? {
        let observedSessionID = sessionID
        let history = fileArtifactHistory
        guard let id = await history.beginTurn(sessionID: observedSessionID),
              sessionID == observedSessionID, fileArtifactHistory === history else { return nil }
        let context = FileArtifactTurnContext(id: id, sessionID: observedSessionID, history: history, coordinator: coordinator)
        activeFileArtifactTurn = context
        return context
    }

    func publishLiveFileArtifacts(
        _ result: DirectAgentToolResult,
        callID: String,
        agentID: String? = nil,
        context: FileArtifactTurnContext?
    ) async {
        guard let context, context.acceptsPublications, sessionID == context.sessionID,
              fileArtifactHistory === context.history,
              activeFileArtifactTurn?.id == context.id else { return }
        let previous = context.pendingPublication
        let publication = Task(name: "ZenCODE.TUI.live-artifact-publication") { @TerminalChatActor [weak self] in
            await previous?.value
            await self?.publishCompletedFileArtifacts(result, callID: callID, agentID: agentID, context: context)
        }
        context.pendingPublication = publication
        await publication.value
    }

    private func publishCompletedFileArtifacts(
        _ result: DirectAgentToolResult, callID: String, agentID: String?, context: FileArtifactTurnContext
    ) async {
        guard sessionID == context.sessionID, fileArtifactHistory === context.history,
              activeFileArtifactTurn?.id == context.id else { return }
        var turns: [SessionFileArtifactHistory.Turn] = []
        if let turn = await context.history.recordLive(
            result.fileChanges, agentID: agentID, callID: callID,
            turnID: context.id, workingDirectory: configuration.workingDirectory
        ) { turns.append(turn) }
        if let summary = await context.coordinator?.collectLiveSummary(matching: result.fileChanges),
           let turn = await context.history.recordLiveSummary(
               summary, turnID: context.id, workingDirectory: configuration.workingDirectory
           ) {
            // Print each file once per completion: the workspace checkpoint
            // replaces this completion's direct artifact for the same path,
            // even when their diffs differ. Both recordings stay intact.
            let checkpointPaths = Set(turn.artifacts.map(\.absolutePath))
            turns = turns.compactMap { liveTurn in
                let artifacts = liveTurn.artifacts.filter { !checkpointPaths.contains($0.absolutePath) }
                return artifacts.isEmpty ? nil : .init(number: liveTurn.number, artifacts: artifacts)
            }
            turns.append(turn)
        }
        guard sessionID == context.sessionID, fileArtifactHistory === context.history else { return }
        guard !turns.isEmpty else { return }
        await writeFileArtifacts(
            turns,
            includeHistoryHeadings: false,
            preservingStreamingContext: true,
            replacingSubAgentOverviewFor: agentID == nil ? nil : context
        )
    }

    /// Replacing the actor also fences restores that reuse the same session ID.
    func resetFileArtifactState() {
        lastFileChangeSummary = nil
        activeFileArtifactTurn = nil
        fileArtifactHistory = SessionFileArtifactHistory(sessionID: sessionID)
        didInstallSubAgentToolEventHandler = false
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
        history expectedHistory: SessionFileArtifactHistory? = nil,
        turnID: UUID? = nil
    ) async -> TurnFileChangeSummary? {
        let observedSessionID = expectedSessionID ?? sessionID
        let history = expectedHistory ?? fileArtifactHistory
        if let turnID, let context = activeFileArtifactTurn, context.id == turnID {
            context.acceptsPublications = false
            await context.pendingPublication?.value
            guard sessionID == observedSessionID, fileArtifactHistory === history else { return nil }
            activeFileArtifactTurn = nil
        }
        let liveChanges: [OperationFileChange]
        if let turnID {
            liveChanges = await history.sealTurn(turnID)
        } else {
            liveChanges = []
        }
        let summary = await coordinator.publishSummaryIfNeeded(matching: liveChanges)
        // A session switch may race the final reconciliation of an old turn.
        // Keep both the latest-summary slot and the runtime artifact history
        // fenced to the session that started the turn.
        guard sessionID == observedSessionID, fileArtifactHistory === history else {
            return nil
        }
        let unseen: SessionFileArtifactHistory.Turn?
        if let turnID {
            let matchingPaths = await coordinator.matchingLiveArtifactPaths()
            unseen = await history.finishTurn(
                turnID, summary: summary, matchingLivePaths: matchingPaths,
                workingDirectory: configuration.workingDirectory
            )
        } else if let summary {
            unseen = await history.append(
                summary: summary, sessionID: observedSessionID,
                workingDirectory: configuration.workingDirectory
            )
        } else {
            unseen = nil
        }
        guard sessionID == observedSessionID, fileArtifactHistory === history else { return nil }
        if let summary { lastFileChangeSummary = summary }
        if let unseen { await writeFileArtifacts([unseen], includeHistoryHeadings: false) }
        guard sessionID == observedSessionID, fileArtifactHistory === history else { return nil }
        return summary
    }

    public func handleArtifactsCommand() async {
        let turns = await fileArtifactHistory.snapshot()
        guard !turns.isEmpty else {
            await writeSystemMessage("No file artifacts in the current session.\n")
            return
        }
        await writeFileArtifacts(turns, includeHistoryHeadings: true)
    }

    private func writeFileArtifacts(
        _ turns: [SessionFileArtifactHistory.Turn],
        includeHistoryHeadings: Bool,
        preservingStreamingContext: Bool = false,
        replacingSubAgentOverviewFor context: FileArtifactTurnContext? = nil
    ) async {
        let markdown = Self.renderFileArtifacts(
            turns,
            includeHistoryHeadings: includeHistoryHeadings,
            columnWidth: Self.terminalColumnCount(),
            isEnabled: AgentOutput.standardErrorIsTerminal
        )
        if let context {
            let maximumInPlaceRows = await statusBar.scrollableOutputRowCapacity()
            guard sessionID == context.sessionID,
                  fileArtifactHistory === context.history,
                  activeFileArtifactTurn?.id == context.id else { return }
            // Only a newly recorded delegated artifact removes the pending
            // overview. The coordinator clears and inserts without suspension.
            await renderCoordinator.writeSubAgentFileArtifactMessage(
                markdown,
                maximumInPlaceRows: maximumInPlaceRows
            )
        } else {
            await renderCoordinator.writeMarkdownMessage(
                markdown,
                to: .standardError,
                preservingStreamingContext: preservingStreamingContext
            )
        }
    }

    public nonisolated static func renderFileArtifacts(
        _ turns: [SessionFileArtifactHistory.Turn],
        columnWidth: Int = 100,
        isEnabled: Bool = false
    ) -> String {
        renderFileArtifacts(
            turns, includeHistoryHeadings: true,
            columnWidth: columnWidth, isEnabled: isEnabled
        )
    }

    nonisolated static func renderFileArtifacts(
        _ turns: [SessionFileArtifactHistory.Turn],
        includeHistoryHeadings: Bool,
        columnWidth: Int = 100,
        isEnabled: Bool = false
    ) -> String {
        // The source is intentionally emitted as Markdown and rendered by the
        // same formatter as assistant output. Keep these parameters for source
        // compatibility with callers that used the preformatted renderer; the
        // Markdown formatter owns terminal width and ANSI capability now.
        _ = columnWidth
        _ = isEnabled

        // Automatic chat output starts at file metadata; only /artifacts groups turns.
        var lines = includeHistoryHeadings ? ["", "🪬 Artifacts"] : []
        for turn in turns {
            if includeHistoryHeadings {
                let count = turn.artifacts.count == 1 ? "1 file" : "\(turn.artifacts.count) files"
                lines.append("")
                lines.append("### Turn \(turn.number) — \(count)")
            }
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
                if let diff = fileArtifactDiff(artifact) {
                    appendMarkdownCodeBlock(
                        TerminalCodeBlockRenderer.numberedArtifactDiff(diff),
                        language: language.map { "artifact-diff-\($0)" } ?? "artifact-diff",
                        to: &lines
                    )
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Presentation-only unified diff. Missing evidence is not an empty file:
    /// only an added/deleted status establishes the absent side. Captured patches
    /// remain authoritative when complete source snapshots are unavailable.
    private nonisolated static func fileArtifactDiff(_ artifact: FileChangeArtifact) -> String? {
        let old: String
        let new: String
        if let oldText = artifact.oldText, let newText = artifact.newText {
            old = oldText
            new = newText
        } else if artifact.status == .added, let newText = artifact.newText {
            old = ""
            new = newText
        } else if artifact.status == .deleted, let oldText = artifact.oldText {
            old = oldText
            new = ""
        } else {
            return artifact.patch?.nilIfBlank
        }

        // Retain line terminators in the comparison so a final-newline-only
        // edit is still visible, without manufacturing an extra blank line.
        func sourceLines(_ text: String) -> [String] {
            let normalized = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            guard !normalized.isEmpty else { return [] }
            let parts = normalized.components(separatedBy: "\n")
            return parts.enumerated().compactMap { index, part in
                if index < parts.count - 1 { return part + "\n" }
                return part.isEmpty ? nil : part
            }
        }
        let oldLines = sourceLines(old)
        let newLines = sourceLines(new)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newLines.difference(from: oldLines) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        guard !removed.isEmpty || !inserted.isEmpty else { return nil }

        // One hunk keeps unchanged evidence once, rather than printing two files.
        var rows = ["@@ -\(oldLines.isEmpty ? 0 : 1),\(oldLines.count) +\(newLines.isEmpty ? 0 : 1),\(newLines.count) @@"]
        func append(_ line: String, marker: String) {
            if line.hasSuffix("\n") {
                rows.append(marker + line.dropLast())
            } else {
                rows.append(marker + line)
                rows.append("\\ No newline at end of file")
            }
        }
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removed.contains(oldIndex) {
                append(oldLines[oldIndex], marker: "-")
                oldIndex += 1
            } else if newIndex < newLines.count, inserted.contains(newIndex) {
                append(newLines[newIndex], marker: "+")
                newIndex += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count {
                append(oldLines[oldIndex], marker: " ")
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }
        return rows.joined(separator: "\n")
    }

    private nonisolated static func renderFileArtifactMetadata(
        _ artifact: FileChangeArtifact
    ) -> String {
        let path = artifact.displayPath.nilIfBlank ?? artifact.absolutePath
        let displayedPath = path.nilIfBlank ?? "(unknown path)"
        let counts = artifact.hasLineCounts ? "  +\(artifact.additions) -\(artifact.deletions)" : ""
        let binary = artifact.isBinary ? " (binary)" : ""
        return "**\(artifact.status.rawValue) `\(markdownInlineCode(displayedPath))`**\(counts)\(binary)"
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

    public func writeFileChangeDiffs(_ summary: TurnFileChangeSummary) async {
        let artifacts = FileChangeArtifactMapper.artifacts(
            from: summary,
            workingDirectory: configuration.workingDirectory
        )
        // This presentation-only turn neither reads nor mutates session history.
        // Its number is unused because /changes omits history headings.
        await writeFileArtifacts(
            [.init(number: 1, artifacts: artifacts)],
            includeHistoryHeadings: false
        )
    }
}
