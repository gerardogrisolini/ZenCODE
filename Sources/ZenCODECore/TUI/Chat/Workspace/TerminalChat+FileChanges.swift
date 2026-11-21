//
//  TerminalChat+FileChanges.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore
import ZenCODERuntime

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
                lines.append(ChatSessionNoticeText.fileArtifactMetadata(artifact))

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

    /// Presentation-only unified diff of one artifact: the neutral
    /// ``FileChangeArtifactDiff``, which ACP writes in its own Markdown too.
    private nonisolated static func fileArtifactDiff(
        _ artifact: FileChangeArtifact,
        presentation: FileArtifactDiffPresentation
    ) -> String? {
        switch presentation {
        case .fullFile:
            return FileChangeArtifactDiff.unifiedDiff(for: artifact, scope: .fullFile)
        case let .changedLines(contextLines):
            return FileChangeArtifactDiff.unifiedDiff(
                for: artifact,
                scope: .changedLines(contextLines: contextLines)
            )
        }
    }

    private nonisolated static func appendMarkdownCodeBlock(
        _ text: String,
        language: String?,
        to lines: inout [String]
    ) {
        lines.append(contentsOf: FileChangeArtifactDiff.markdownCodeBlock(text, language: language))
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
