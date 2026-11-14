//
//  ZenFileChangeFormatting.swift
//  ZenApp
//
//  Pure helpers of the file-change views: the summary header and hint, the
//  lines of a unified patch, and the diff of a file artifact. They mirror the
//  terminal UI's file-change summary (`TurnFileChangeSummaryPresentation`)
//  and file artifacts (`TerminalChat+FileChanges`).
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

    /// The syntax-highlighting language of an artifact's file, from the
    /// extension of its display path (else its absolute path), as the terminal
    /// UI chooses it (`TerminalChat.codeLanguageHint(forPath:)`). `nil` for
    /// text, documentation, configuration, and unknown files.
    public static func sourceLanguage(of artifact: FileChangeArtifact) -> String? {
        TerminalChat.codeLanguageHint(
            forPath: ZenTranscriptText.nonBlank(artifact.displayPath) ?? artifact.absolutePath
        )
    }

    /// The diff marker and the source of a patch line that carries source, as
    /// the terminal UI splits them before it colors the source: an addition, a
    /// deletion, or a context line that starts with a space. `nil` for hunk
    /// and file headers, notes, and any other line.
    public static func patchSource(of line: ZenPatchLine) -> (marker: String, source: String)? {
        switch line.kind {
        case .addition, .deletion:
            break
        case .context:
            guard line.text.hasPrefix(" ") else { return nil }
        case .hunk, .header, .note:
            return nil
        }
        // The marker is one ASCII scalar: a combining scalar after it stays
        // with the source.
        guard let marker = line.text.unicodeScalars.first else { return nil }
        return (String(marker), String(line.text.unicodeScalars.dropFirst()))
    }

    /// The source line number of each patch line, as the terminal's file
    /// artifacts number it (`TerminalChat.artifactDiffSourceLineNumbers(_:)`,
    /// hunk-aware): the old line of a removal, the new line of an addition or
    /// a context line, `nil` for file and hunk headers, notes, and any line
    /// outside a valid hunk. One element per line.
    public static func patchLineNumbers(_ lines: [ZenPatchLine]) -> [Int?] {
        TerminalChat.artifactDiffSourceLineNumbers(lines.map(\.text))
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
