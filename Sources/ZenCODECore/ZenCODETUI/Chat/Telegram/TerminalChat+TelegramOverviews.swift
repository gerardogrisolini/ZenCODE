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
            notification,
            epoch in
            await self?.mirrorRenderedOverviewToTelegram(
                notification: notification,
                epoch: epoch
            )
        }
    }

    /// Mirrors typed overview publications to the linked Telegram chat while
    /// that turn's progress is mirrored. The live sub-agent overview remains
    /// terminal-only; each completed model response is instead a distinct
    /// remote message.
    ///
    /// Task graphs are mirrored only when the content actually changed. Sends
    /// go through the turn reporter's ordered queue, so a section cannot
    /// overtake the tool activity that produced it. Outside a mirrored turn
    /// there is no remote audience and the section stays terminal-only.
    func mirrorRenderedOverviewToTelegram(
        notification: TerminalChatRenderCoordinator.OverviewMirrorNotification,
        epoch: Int
    ) async {
        guard epoch == currentTelegramMirrorEpoch,
              activeTelegramProgressReporter != nil else {
            return
        }
        switch notification {
        case let .taskGraph(signature, markdown):
            guard mirroredTaskGraphOverviewSignature != signature else {
                return
            }
            mirroredTaskGraphOverviewSignature = signature
            let plainText = TerminalANSIText.stripANSI(markdown)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plainText.isEmpty else {
                return
            }
            await activeTelegramProgressReporter?.enqueue(
                .tasks("📋 Task graph\n\n\(plainText)")
            )
        case let .subAgentResponse(response):
            guard let payload = Self.telegramSubAgentResponsePayload(
                heading: response.heading,
                markdown: response.markdown
            ) else {
                return
            }
            await activeTelegramProgressReporter?.enqueue(payload)
        }
    }

    /// Builds the distinct Telegram payload used for a completed sub-agent
    /// response. Keeping the discriminator here makes this routing observable
    /// before the reporter renders payloads to text.
    static func telegramSubAgentResponsePayload(
        heading: String,
        markdown: String
    ) -> TerminalTelegramTurnPayload? {
        let heading = TerminalANSIText.stripANSI(heading)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else {
            return nil
        }
        let text = heading.isEmpty ? markdown : "\(heading)\n\n\(markdown)"
        return .subAgentResponse(text)
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
    func finalizeTelegramTurnProgressReporting(
        outcome: TerminalTelegramTurnPayload? = nil,
        fileChangeSummary: TurnFileChangeSummary? = nil
    ) async {
        await renderCoordinator.waitForOverviewMirrorsToDrain()
        if let outcome {
            await activeTelegramProgressReporter?.enqueue(outcome)
        }
        if let fileChangeSummary,
           !fileChangeSummary.entries.isEmpty {
            let summary = Self.renderFileChangeSummary(fileChangeSummary)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                await activeTelegramProgressReporter?.enqueue(.summary(summary))
            }
        }
        await activeTelegramProgressReporter?.flush()
        endTelegramTurnProgressReporting()
    }
}
