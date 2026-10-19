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
    /// that turn's progress is mirrored. Transient sub-agent metadata remains
    /// terminal-only; each visible 💬 answer block and each completed model
    /// response is instead a distinct remote message.
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
        case let .subAgentPartialResponse(response):
            guard let payload = Self.telegramSubAgentResponsePayload(
                heading: response.heading,
                markdown: response.markdown
            ) else {
                return
            }
            await activeTelegramProgressReporter?.enqueue(payload)
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
    /// overview mirror to be handed over, drops the trailing root response text
    /// that no tool call closed (it is the turn's final response, delivered here
    /// once as `outcome`), flushes the turn reporter so queued remote messages
    /// are delivered, and only then ends the reporting. This is the single
    /// retirement path for a turn, used both by the normal completion flow and
    /// by loop teardown paths that bypass `finishPromptResult` (end-of-input
    /// during generation, cancellation of the interactive loop's task).
    ///
    /// When no reporter owns the linked chat — Telegram was enabled without a
    /// mirrored reporter, or the turn produced no progress — the outcome and
    /// Summary are still delivered directly to the linked chat.
    func finalizeTelegramTurnProgressReporting(
        outcome: TerminalTelegramTurnPayload? = nil,
        fileChangeSummary: TurnFileChangeSummary? = nil
    ) async {
        await renderCoordinator.waitForOverviewMirrorsToDrain()
        let summaryPayload: TerminalTelegramTurnPayload?
        if let fileChangeSummary,
           !fileChangeSummary.entries.isEmpty {
            let summary = Self.renderFileChangeSummary(fileChangeSummary)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            summaryPayload = summary.isEmpty ? nil : .summary(summary)
        } else {
            summaryPayload = nil
        }

        if let reporter = activeTelegramProgressReporter {
            // Trailing content never closed by a tool call is the final
            // response: dropping it here is what keeps `outcome` from being
            // mirrored twice.
            await reporter.discardPendingAgentResponse()
            if let outcome {
                await reporter.enqueue(outcome)
            }
            if let summaryPayload {
                await reporter.enqueue(summaryPayload)
            }
            await reporter.flush()
            await reporter.retire()
        } else if let origin = activeTelegramTurnOrigin {
            if let outcome {
                await sendTelegramTurnMessageIfLinked(outcome, origin: origin)
            }
            if let summaryPayload {
                await sendTelegramTurnMessageIfLinked(summaryPayload, origin: origin)
            }
        }
        await endTelegramTurnProgressReporting()
    }
}
