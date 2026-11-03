//
//  ZenFileChangeFormatting.swift
//  ZenApp
//
//  Pure helpers of the file-change views: the summary header and hint, the
//  lines of a unified patch, and the diff of a file artifact. They mirror the
//  terminal UI's file-change summary (`TurnFileChangeSummaryPresentation`)
//  and live artifacts (`TerminalChat+FileChanges`).
//

import Foundation
import ToolCore
import ZenCODECore

/// One line of a unified patch, classified for coloring.
public struct ZenPatchLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `@@ -a,b +c,d @@`
        case hunk
        /// `diff`, `index`, `---`, `+++` and the other file headers.
        case header
        case addition
        case deletion
        case context
        /// `\ No newline at end of file`
        case note
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Pure presentation helpers of file changes.
public enum ZenFileChangeFormatting {
    /// Patch lines a file shows before "Show more".
    public static let patchPreviewLineLimit = 400

    /// `1 file changed` or `N files changed`.
    public static func fileCountText(_ count: Int) -> String {
        count == 1 ? "1 file changed" : "\(count) files changed"
    }

    /// The header of a summary as text: `N files changed  +A −D`.
    public static func summaryHeaderText(_ summary: TurnFileChangeSummary) -> String {
        "\(fileCountText(summary.fileCount))  +\(summary.totalAdditions) −\(summary.totalDeletions)"
    }

    /// The hint under a summary, as the terminal writes it.
    public static func hintText(_ summary: TurnFileChangeSummary) -> String {
        summary.canUndo
            ? "Use /undo to revert, /changes diff to show patches."
            : "Undo is not available for this summary."
    }

    /// The lines of a unified patch, classified.
    public static func patchLines(_ patch: String) -> [ZenPatchLine] {
        ZenToolCallFormatting.lines(of: patch).map { line in
            ZenPatchLine(kind: kind(ofPatchLine: line), text: line)
        }
    }

    private static func kind(ofPatchLine line: String) -> ZenPatchLine.Kind {
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .header }
        if line.hasPrefix("diff ") || line.hasPrefix("index ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file")
            || line.hasPrefix("rename ") || line.hasPrefix("similarity ")
            || line.hasPrefix("old mode") || line.hasPrefix("new mode")
            || line.hasPrefix("Binary files") {
            return .header
        }
        if line.hasPrefix("+") { return .addition }
        if line.hasPrefix("-") { return .deletion }
        if line.hasPrefix("\\") { return .note }
        return .context
    }

    /// The path an artifact row shows: the display path, else the absolute one.
    public static func displayPath(of artifact: FileChangeArtifact) -> String {
        ZenTranscriptText.nonBlank(artifact.displayPath)
            ?? ZenTranscriptText.nonBlank(artifact.absolutePath)
            ?? "(unknown path)"
    }

    /// The diff of an artifact, when its evidence establishes one: the complete
    /// old and new texts (only an added or deleted status establishes the
    /// absent side), else the captured patch. `nil` without evidence.
    public static func artifactDiff(_ artifact: FileChangeArtifact) -> ZenArtifactDiff? {
        guard !artifact.isBinary else { return nil }
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
        } else if let patch = ZenTranscriptText.nonBlank(artifact.patch) {
            return .patch(patchLines(patch))
        } else {
            return nil
        }
        let hunks = ZenToolCallFormatting.contextHunks(ZenToolCallFormatting.lineDiff(old: old, new: new))
        return hunks.isEmpty ? nil : .hunks(hunks)
    }
}

/// The diff a file artifact shows.
public enum ZenArtifactDiff: Sendable, Equatable {
    /// Changed lines with their context, from the complete old and new texts.
    case hunks([[ZenTranscriptDiffRow]])
    /// A captured unified patch.
    case patch([ZenPatchLine])
}
