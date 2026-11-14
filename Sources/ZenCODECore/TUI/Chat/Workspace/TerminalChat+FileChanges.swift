//
//  TerminalChat+FileChanges.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    /// How a complete old/new source snapshot is presented as a diff.
    /// Captured patches are already compact and ignore this choice.
    public enum FileArtifactDiffPresentation: Sendable {
        /// One hunk covering the whole file, unchanged lines included.
        case fullFile
        /// Unified-diff hunks limited to changed lines plus surrounding context.
        case changedLines(contextLines: Int = 3)
    }

    /// Replacing the actor also fences restores that reuse the same session ID.
    func resetFileArtifactState() {
        chatSession.resetFileArtifactState()
    }

    /// Writes `turns` in the transcript, for `/changes diff` and for the
    /// `/artifacts` history printed without the interactive layout. The live
    /// and sealed artifacts of a turn are not written: the terminal shows them
    /// only in the `/artifacts` panel (``fileArtifactsDidChange()``).
    func writeFileArtifacts(
        _ turns: [SessionFileArtifactHistory.Turn],
        includeHistoryHeadings: Bool
    ) async {
        let markdown = Self.renderFileArtifacts(
            turns,
            includeHistoryHeadings: includeHistoryHeadings
        )
        await renderCoordinator.writeMarkdownMessage(markdown, to: .standardError)
    }

    /// Output without history headings (`/changes diff`) defaults to changed
    /// lines so edits stay visible inside large files; the `/artifacts`
    /// history (history headings) defaults to the whole file.
    nonisolated static func renderFileArtifacts(
        _ turns: [SessionFileArtifactHistory.Turn],
        includeHistoryHeadings: Bool,
        diffPresentation: FileArtifactDiffPresentation? = nil
    ) -> String {
        let presentation = diffPresentation ?? (includeHistoryHeadings ? .fullFile : .changedLines())
        // The source is intentionally emitted as Markdown and rendered by the
        // same formatter as assistant output, which owns terminal width and
        // ANSI capability.
        // Output without headings starts at file metadata; only /artifacts groups turns.
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

                appendFileArtifactDiff(artifact, presentation: presentation, to: &lines)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The Markdown of the diff of one artifact, as ``renderFileArtifacts(_:includeHistoryHeadings:diffPresentation:)``
    /// writes it below the artifact's metadata: an `artifact-diff` block
    /// (`artifact-diff-<language>` when the path has a language) of the diff
    /// numbered with the source lines. `nil` for a binary file and for an
    /// artifact without a diff to show. The `/artifacts` panel renders it as
    /// the body of a file's detail.
    nonisolated static func fileArtifactDiffMarkdown(
        _ artifact: FileChangeArtifact,
        presentation: FileArtifactDiffPresentation
    ) -> String? {
        var lines: [String] = []
        guard appendFileArtifactDiff(artifact, presentation: presentation, to: &lines) else {
            return nil
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Appends the numbered diff block of `artifact` to `lines`; `false`, with
    /// nothing appended, for a binary file or without a diff.
    @discardableResult
    private nonisolated static func appendFileArtifactDiff(
        _ artifact: FileChangeArtifact,
        presentation: FileArtifactDiffPresentation,
        to lines: inout [String]
    ) -> Bool {
        guard !artifact.isBinary,
              let diff = fileArtifactDiff(artifact, presentation: presentation) else {
            return false
        }
        let languagePath = artifact.displayPath.nilIfBlank ?? artifact.absolutePath
        let language = ToolLanguageHint.hint(forPath: languagePath)
        appendMarkdownCodeBlock(
            TerminalCodeBlockRenderer.numberedArtifactDiff(diff),
            language: language.map { "artifact-diff-\($0)" } ?? "artifact-diff",
            to: &lines
        )
        return true
    }

    /// The source line numbers of a unified diff, as the terminal's file
    /// artifacts show them. `lines` are the lines of the diff without their
    /// terminators. The result has one element per line: the new line of an
    /// addition or a context line, the old line of a removal, and `nil` where
    /// the artifacts show no number (file headers, hunk headers,
    /// `\ No newline at end of file`, and any line outside a valid,
    /// unexhausted hunk). A host app uses it to number a patch as the
    /// terminal does.
    public nonisolated static func artifactDiffSourceLineNumbers(_ lines: [String]) -> [Int?] {
        TerminalCodeBlockRenderer.sourceLineNumbers(lines)
    }

    /// Presentation-only unified diff. Missing evidence is not an empty file:
    /// only an added/deleted status establishes the absent side. Captured patches
    /// remain authoritative when complete source snapshots are unavailable.
    private nonisolated static func fileArtifactDiff(
        _ artifact: FileChangeArtifact,
        presentation: FileArtifactDiffPresentation
    ) -> String? {
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

        // Interleave both sides once; each row remembers the 1-based source
        // line it consumes so hunk headers can be derived for any slice.
        struct Row {
            let marker: String
            let text: String
            let oldLine: Int?
            let newLine: Int?
            var isChange: Bool { marker != " " }
        }
        var rows: [Row] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removed.contains(oldIndex) {
                rows.append(Row(marker: "-", text: oldLines[oldIndex], oldLine: oldIndex + 1, newLine: nil))
                oldIndex += 1
            } else if newIndex < newLines.count, inserted.contains(newIndex) {
                rows.append(Row(marker: "+", text: newLines[newIndex], oldLine: nil, newLine: newIndex + 1))
                newIndex += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count {
                rows.append(Row(marker: " ", text: oldLines[oldIndex], oldLine: oldIndex + 1, newLine: newIndex + 1))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }

        let hunks: [Range<Int>]
        switch presentation {
        case .fullFile:
            // One hunk keeps unchanged evidence once, rather than printing two files.
            hunks = [rows.indices]
        case let .changedLines(contextLines):
            let context = max(0, contextLines)
            var merged: [Range<Int>] = []
            for index in rows.indices where rows[index].isChange {
                let range = max(0, index - context)..<min(rows.count, index + context + 1)
                if let last = merged.last, last.upperBound >= range.lowerBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            hunks = merged
        }

        var output: [String] = []
        for hunk in hunks {
            let slice = rows[hunk]
            let oldCount = slice.filter { $0.oldLine != nil }.count
            let newCount = slice.filter { $0.newLine != nil }.count
            // A side without lines in the hunk anchors to the last consumed
            // line before it (0 at the start), matching unified-diff convention.
            let oldStart = slice.first { $0.oldLine != nil }?.oldLine
                ?? rows[..<hunk.lowerBound].last { $0.oldLine != nil }?.oldLine ?? 0
            let newStart = slice.first { $0.newLine != nil }?.newLine
                ?? rows[..<hunk.lowerBound].last { $0.newLine != nil }?.newLine ?? 0
            output.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            for row in slice {
                if row.text.hasSuffix("\n") {
                    output.append(row.marker + row.text.dropLast())
                } else {
                    output.append(row.marker + row.text)
                    output.append("\\ No newline at end of file")
                }
            }
        }
        return output.joined(separator: "\n")
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
        TurnFileChangeSummaryPresentation.text(summary, includesCommandHint: true)
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
