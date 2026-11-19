//
//  ACPFileChangeSummaryPresentation.swift
//  ZenCODE
//
//  The Summary of the files a prompt turn changed, as the last text section of
//  the turn on the ACP wire.
//

import Foundation
import ToolCore

/// The wire form of a turn's file-change Summary: the text the terminal and
/// Telegram show (``TurnFileChangeSummaryPresentation``), with the `/undo` and
/// `/changes` hint, as one standard `agent_message_chunk`. The Summary lives
/// on the wire only: it is never part of the model's history or the saved
/// transcript, and `/changes` and `/undo` read it from the controller.
enum ACPFileChangeSummaryPresentation {
    /// The `agent_message_chunk` that presents `summary`, or `nil` when the
    /// turn changed no file.
    static func update(for summary: TurnFileChangeSummary?) -> JSONValue? {
        guard let summary, !summary.entries.isEmpty else { return nil }
        return ZenCODEACPBridge.textChunkJSONUpdate(
            kind: "agent_message_chunk",
            text: TurnFileChangeSummaryPresentation.text(summary, includesCommandHint: true)
        )
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
