//
//  TerminalChat+TelegramOverviews.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 15/08/26.
//

import Foundation

extension TerminalChat {
    /// Wires the render coordinator's overview hook into the Telegram mirror.
    /// Installed when the chat run loop starts (the coordinator is an actor,
    /// so the swap must be awaited and cannot happen in the synchronous
    /// initializer); the handler is a no-op unless a Telegram-mirrored turn is
    /// generating.
    func installOverviewMirroringHandler() async {
        await renderCoordinator.setOverviewMirroringHandler { [weak self]
            kind,
            signature,
            text,
            epoch in
            await self?.mirrorRenderedOverviewToTelegram(
                kind: kind,
                signature: signature,
                text: text,
                epoch: epoch
            )
        }
    }

    /// Mirrors a locally rendered task-graph overview to the linked Telegram
    /// chat while that turn's progress is mirrored. Sub-agent overviews remain
    /// terminal-only: their frequently changing full snapshots would otherwise
    /// produce excessive Telegram traffic.
    ///
    /// Task graphs are mirrored only when the content actually changed. Sends
    /// go through the turn reporter's ordered queue, so a section cannot
    /// overtake the tool activity that produced it. Outside a mirrored turn
    /// there is no remote audience and the section stays terminal-only.
    func mirrorRenderedOverviewToTelegram(
        kind: TerminalChatRenderCoordinator.OverviewKind,
        signature: String,
        text: String,
        epoch: Int
    ) async {
        guard kind == .taskGraph,
              epoch == currentTelegramMirrorEpoch,
              activeTelegramProgressReporter != nil else {
            return
        }
        guard mirroredTaskGraphOverviewSignature != signature else {
            return
        }
        mirroredTaskGraphOverviewSignature = signature

        let plainText = TerminalANSIText.stripANSI(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plainText.isEmpty else {
            return
        }
        // The reporter truncates to Telegram's message limit and preserves
        // turn ordering.
        await activeTelegramProgressReporter?.send("📋 Task graph\n\n\(plainText)")
    }

    /// Clears the per-turn mirroring dedup so the first section publication of
    /// a new turn reaches Telegram even when its content is identical to the
    /// previous turn's last section.
    func resetMirroredOverviewSignatures() {
        mirroredTaskGraphOverviewSignature = nil
    }

    /// Retires the current turn's Telegram reporting: waits for every queued
    /// overview mirror to be handed over, flushes the turn reporter so queued
    /// remote messages are delivered, and only then ends the reporting. This
    /// is the single retirement path for a turn, used both by the normal
    /// completion flow and by loop teardown paths that bypass
    /// `finishPromptResult` (end-of-input during generation, cancellation of
    /// the interactive loop's task).
    func finalizeTelegramTurnProgressReporting() async {
        await renderCoordinator.waitForOverviewMirrorsToDrain()
        await activeTelegramProgressReporter?.flush()
        endTelegramTurnProgressReporting()
    }
}
