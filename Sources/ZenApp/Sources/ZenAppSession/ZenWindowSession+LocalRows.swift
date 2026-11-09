//
//  ZenWindowSession+LocalRows.swift
//  ZenApp
//
//  The rows of a window that are not in its session's log: its messages,
//  the echo of a command line, and the echo of a reply.
//

import Foundation
import ZenCODECore

extension ZenWindowSession {
    // MARK: - Local rows

    /// Adds a row of the window after the last log entry the reducer holds now.
    func appendLocal(_ content: ZenTranscriptItem.Content) async {
        guard !isClosed else { return }
        let anchor = await ZenWindowSteps.anchor(in: sessionHost, slotID: slotID)
        guard !isClosed else { return }
        insertLocal(ZenLocalTranscriptItem(
            epoch: anchor?.epoch ?? current.epoch,
            anchorSequence: anchor?.sequence ?? snapshot.map(ZenLocalTranscriptItem.anchorSequence(in:)) ?? 0,
            content: content
        ))
    }

    /// Adds a row of the window at once, after the last log entry the window
    /// has seen.
    func appendLocalNow(_ content: ZenTranscriptItem.Content) {
        guard !isClosed else { return }
        insertLocal(ZenLocalTranscriptItem(
            epoch: snapshot?.epoch ?? current.epoch,
            anchorSequence: snapshot.map(ZenLocalTranscriptItem.anchorSequence(in:)) ?? 0,
            content: content
        ))
    }

    private func insertLocal(_ item: ZenLocalTranscriptItem) {
        projection.insertLocal(item)
        if projection.composeIfNeeded() {
            transcript = projection.items
        }
    }

    /// Shows `line`, a reply the operator typed, as their prompt, as the
    /// terminal does: the session absorbed it (the goal of `/plan approve`, a
    /// Planner question, a `/goal` workflow) and the model receives the
    /// prompt the reply built, which stays hidden. Anchored at `anchor`, read
    /// before the reply ran.
    func echoReply(_ line: String, anchor: ZenWindowSteps.Anchor?) {
        guard !isClosed else { return }
        insertLocal(ZenLocalTranscriptItem(
            epoch: anchor?.epoch ?? current.epoch,
            anchorSequence: anchor?.sequence ?? snapshot.map(ZenLocalTranscriptItem.anchorSequence(in:)) ?? 0,
            content: .userPrompt(text: line, attachments: [], origin: .app)
        ))
    }
}
