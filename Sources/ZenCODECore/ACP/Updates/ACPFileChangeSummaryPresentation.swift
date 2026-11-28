//
//  ACPFileChangeSummaryPresentation.swift
//  ZenCODE
//
//  The Summary of the files a prompt turn changed, as the last text section of
//  the turn on the ACP wire.
//

import Foundation
import ToolCore
import ZenCODERuntime

/// The wire form of a turn's file-change Summary: the same file details the
/// terminal and Telegram show, formatted as a Markdown section that two blank
/// lines separate from the answer, with highlighted `/undo` and `/changes`
/// actions, as one standard
/// `agent_message_chunk`. The Summary lives on the wire only: it is never part
/// of the model's history or the saved transcript, and `/changes` and `/undo`
/// read it from the controller. It is a message of its own (its chunk has a
/// `messageId` no other message has), so a client never joins it with the
/// model's answer.
enum ACPFileChangeSummaryPresentation {
    /// The `agent_message_chunk` that presents `summary`, or `nil` when the
    /// turn changed no file.
    static func update(
        for summary: TurnFileChangeSummary?,
        messageID: String = ZenCODEACPBridge.newMessageID()
    ) -> JSONValue? {
        guard let summary, !summary.entries.isEmpty else { return nil }
        return ZenCODEACPBridge.textChunkJSONUpdate(
            kind: "agent_message_chunk",
            text: text(for: summary),
            messageID: messageID
        )
    }

    /// A self-contained Markdown section. Clients append the chunk to the
    /// answer's text, which usually ends without a line feed, so the section
    /// opens with that line's end and two blank lines.
    static func text(for summary: TurnFileChangeSummary) -> String {
        let title = summary.fileCount == 1 ? "1 file" : "\(summary.fileCount) files"
        var lines = [
            "**🪬 Summary: \(title)  +\(summary.totalAdditions) -\(summary.totalDeletions)**",
        ]
        lines.append(contentsOf: summary.entries.map(entry))
        lines.append(
            summary.canUndo
                ? "**`/undo`** to revert · **`/changes diff`** to show patches."
                : "Undo is not available for this summary."
        )
        return "\n\n\n" + lines.joined(separator: "\n") + "\n"
    }

    /// One file of the Summary, its path in a code span: a name that holds
    /// `*`, `_`, or `[` does not change how the client renders the section, and
    /// stays copyable. The terminal and Telegram keep the plain shared text.
    static func entry(_ entry: TurnFileChangeSummary.Entry) -> String {
        // A backtick in the name would end the span early.
        let path = "`\(entry.path.replacingOccurrences(of: "`", with: "'"))`"
        if entry.isBinary {
            return "  \(entry.status.rawValue) \(path) (binary)"
        }
        return "  \(entry.status.rawValue) \(path)  +\(entry.additions) -\(entry.deletions)"
    }
}

extension ZenCODEACPBridge {
    /// Presents the Summary of the turn `turn` through its `pipeline`, as the
    /// last text section of the turn: the turn calls it after its final plan
    /// and before the reply of the prompt.
    ///
    /// The Summary goes through the same admission fence as every other update
    /// of the prompt, so it reaches the client only while the prompt still
    /// holds its incarnation. A turn ended by `session/cancel`, a close, or a
    /// shutdown has lost it, and writes nothing more: `/changes` still shows
    /// what the turn changed.
    func publishFileChangeSummary(
        _ summary: TurnFileChangeSummary?,
        for turn: ACPPromptTurn,
        pipeline: ACPPromptUpdatePipeline
    ) async {
        guard let update = ACPFileChangeSummaryPresentation.update(for: summary),
              await isCurrentPresentation(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID)
        else { return }
        await pipeline.enqueue(.init(kind: .consume(update))).value
    }
}
