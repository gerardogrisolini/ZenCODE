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

    /// Mirrors a locally rendered overview section (task graph or sub-agents)
    /// to the linked Telegram chat while that turn's progress is mirrored.
    ///
    /// Sections are mirrored only when the content actually changed: the
    /// coordinator reports the same signature for republished-but-identical
    /// sections (e.g. the periodic sub-agent refresh), which keeps the remote
    /// chat free of spam while the terminal keeps its in-place refresh. Sends
    /// go through the turn reporter's ordered queue, so a section cannot
    /// overtake the tool activity that produced it. Outside a mirrored turn
    /// there is no remote audience and the section stays terminal-only.
    func mirrorRenderedOverviewToTelegram(
        kind: TerminalChatRenderCoordinator.OverviewKind,
        signature: String,
        text: String,
        epoch: Int
    ) async {
        guard epoch == currentTelegramMirrorEpoch,
              activeTelegramProgressReporter != nil else {
            return
        }
        guard mirroredOverviewSignatures[kind] != signature else {
            return
        }
        mirroredOverviewSignatures[kind] = signature

        let plainText = TerminalANSIText.stripANSI(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plainText.isEmpty else {
            return
        }
        let header: String
        switch kind {
        case .taskGraph:
            header = "📋 Task graph"
        case .subAgents:
            header = "🤖 Sub-agents"
        }
        // The reporter truncates to Telegram's message limit and preserves
        // turn ordering.
        await activeTelegramProgressReporter?.send("\(header)\n\n\(plainText)")
    }

    /// Clears the per-turn mirroring dedup so the first section publication of
    /// a new turn reaches Telegram even when its content is identical to the
    /// previous turn's last section.
    func resetMirroredOverviewSignatures() {
        mirroredOverviewSignatures.removeAll()
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
