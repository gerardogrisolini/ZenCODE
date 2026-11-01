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

    /// Hands typed overview publications to the Telegram companion, which
    /// mirrors them to the linked chat while that turn's progress is
    /// mirrored. Transient sub-agent metadata remains terminal-only; each
    /// visible 💬 answer block and each completed model response is instead a
    /// distinct remote message.
    ///
    /// `epoch` is the render coordinator's mirror epoch the publication was
    /// queued under, the same value the turn passed to
    /// ``TelegramSessionCompanion/beginTurn(origin:mirrorEpoch:)``: the
    /// companion drops a section of a turn that ended, and a task graph whose
    /// signature it already mirrored during the turn. A task graph without
    /// visible text is not handed over. Sends go through the turn reporter's
    /// ordered queue, so a section cannot overtake the tool activity that
    /// produced it; outside a mirrored turn there is no remote audience and
    /// the section stays terminal-only.
    func mirrorRenderedOverviewToTelegram(
        notification: TerminalChatRenderCoordinator.OverviewMirrorNotification,
        epoch: Int
    ) async {
        switch notification {
        case let .taskGraph(signature, markdown):
            let plainText = TerminalANSIText.stripANSI(markdown)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plainText.isEmpty else {
                return
            }
            await telegramCompanion.enqueueOverview(
                .tasks("📋 Task graph\n\n\(plainText)"),
                epoch: epoch,
                taskGraphSignature: signature
            )
        case let .subAgentPartialResponse(response):
            guard let payload = Self.telegramSubAgentResponsePayload(
                heading: response.heading,
                markdown: response.markdown
            ) else {
                return
            }
            await telegramCompanion.enqueueOverview(payload, epoch: epoch)
        case let .subAgentResponse(response):
            guard let payload = Self.telegramSubAgentResponsePayload(
                heading: response.heading,
                markdown: response.markdown
            ) else {
                return
            }
            await telegramCompanion.enqueueOverview(payload, epoch: epoch)
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
}
