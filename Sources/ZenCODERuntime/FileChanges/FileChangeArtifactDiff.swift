//
//  FileChangeArtifactDiff.swift
//  ZenCODE
//
//  The unified diff of a file-change artifact and the Markdown code block that
//  carries it, independent of any channel.
//

import Foundation
import ToolCore

/// Presentation-only unified diff of a ``FileChangeArtifact`` and the fenced
/// Markdown block that holds a text, shared by the channels that show patches:
/// the terminal draws the diff with its numbered `artifact-diff` blocks and ACP
/// writes it in a plain `diff` block. Nothing here reads the worktree or
/// changes the persisted and wire shape of a diff.
package enum FileChangeArtifactDiff {
    /// How a complete old/new source snapshot becomes a diff. Captured patches
    /// are already compact and ignore this choice.
    package enum Scope {
        /// One hunk covering the whole file, unchanged lines included.
        case fullFile
        /// Unified-diff hunks limited to changed lines plus surrounding context.
        case changedLines(contextLines: Int)
    }

    /// The unified diff of `artifact`. Missing evidence is not an empty file:
    /// only an added/deleted status establishes the absent side. Captured
    /// patches remain authoritative when complete source snapshots are
    /// unavailable. `nil` when there is nothing to show (a binary file is the
    /// caller's decision).
    package static func unifiedDiff(for artifact: FileChangeArtifact, scope: Scope) -> String? {
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
        switch scope {
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

    /// The lines of a fenced Markdown code block holding `text`, opened with
    /// `language` when there is one. The fence is longer than any run of
    /// backticks in `text`, so a patch that quotes Markdown cannot close it.
    package static func markdownCodeBlock(_ text: String, language: String?) -> [String] {
        let fence = markdownCodeFence(for: text, language: language)
        var lines = [fence]
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
        return lines
    }

    private static func markdownCodeFence(for text: String, language: String?) -> String {
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
}
