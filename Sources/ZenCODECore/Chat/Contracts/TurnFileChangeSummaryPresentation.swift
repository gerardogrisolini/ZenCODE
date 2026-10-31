//
//  TurnFileChangeSummaryPresentation.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// Plain-text presentation of a turn's file-change summary, shared by the
/// channels that show it as text.
enum TurnFileChangeSummaryPresentation {
    /// The summary title and one line per file. `includesCommandHint` adds the
    /// `/undo` and `/changes` hint of channels that offer those commands.
    static func text(
        _ summary: TurnFileChangeSummary,
        includesCommandHint: Bool
    ) -> String {
        let title = summary.fileCount == 1
            ? "1 file"
            : "\(summary.fileCount) files"

        var lines = ["", "🪬 Summary: \(title)  +\(summary.totalAdditions) -\(summary.totalDeletions)"]
        lines.append(contentsOf: summary.entries.map(entry))
        if includesCommandHint {
            lines.append(
                summary.canUndo
                    ? "Use /undo to revert, /changes diff to show patches."
                    : "Undo is not available for this summary."
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func entry(_ entry: TurnFileChangeSummary.Entry) -> String {
        if entry.isBinary {
            return "  \(entry.status.rawValue) \(entry.path) (binary)"
        }

        return "  \(entry.status.rawValue) \(entry.path)  +\(entry.additions) -\(entry.deletions)"
    }
}
