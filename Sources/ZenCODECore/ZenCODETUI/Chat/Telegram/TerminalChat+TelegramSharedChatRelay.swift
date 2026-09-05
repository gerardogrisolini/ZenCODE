//
//  TerminalChat+TelegramSharedChatRelay.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension TerminalChat {
    // MARK: - Live-message relay

    /// Reports whether `text` is already claimed by a higher-precedence route, in
    /// which case quoting a card must not change its meaning.
    ///
    /// The decision uses the real parsers: ``TerminalTelegramRemoteCommand`` for
    /// remote commands, ``CoordinatorCommandParser`` for slash commands and the
    /// actual ``parseSharedChatMention(from:readableHandles:)`` outcome for
    /// mentions — including `missingText`, which is a recognised mention whose
    /// diagnostic must not be replaced by a reply. A leading `@` that resolves to
    /// nothing is not a mention, so it does not suppress the reply route.
    func telegramReplyRoutingHasPrecedence(over text: String) async -> Bool {
        if TerminalTelegramRemoteCommand(text: text) != nil {
            return true
        }
        if CoordinatorCommandParser.isSlashCommand(text) {
            return true
        }
        switch Self.parseSharedChatMention(
            from: text,
            readableHandles: await sessionRunner.sharedChatMentionHandles(
                rootSessionID: sessionID
            )
        ) {
        case .route, .missingText:
            return true
        case .none:
            return false
        }
    }

    /// Offers one shared-chat observer batch to the Telegram relay.
    ///
    /// The TUI's single observation stays the only subscriber; the relay owns its
    /// own delivery ledger, so the terminal reader buffer (which is rebuilt on a
    /// forced reattach) can never be mistaken for a "already sent" record.
    func forwardSharedChatMessagesToTelegram(
        _ messages: [AgentSharedChat.Message],
        roomID: String
    ) async {
        guard telegramControlState.isActive,
              telegramActiveRouteLease != nil || telegramLinkedChatID != nil else {
            return
        }
        let roster = await sessionRunner.sharedChatMentionRoster(rootSessionID: roomID)
        await telegramSharedChatRelay.forward(
            messages,
            roomID: roomID,
            participants: roster.participants
        )
    }

    /// Follows a room swap (`/new`, `/resume`, observation restart). A new room
    /// invalidates the ledger and the receipt map: identifiers of a retired room
    /// must never route a reply into the live one.
    func rebindTelegramSharedChatRelay(roomID: String) async {
        guard telegramControlState.isActive,
              let lease = telegramActiveRouteLease,
              lease.key.roomID == roomID,
              (try? await telegramSessionRouter.validate(lease)) != nil else {
            // A room swap or invalidated lease retires every command receipt
            // associated with this terminal before a new route can be bound.
            telegramCommandReplyBindings.removeAll()
            await telegramSharedChatRelay.deactivate()
            return
        }
        await telegramSharedChatRelay.activate(
            roomID: roomID,
            chatID: lease.key.chatID,
            lease: lease,
            repliesEnabled: readsTelegramIngress
        )
    }

    /// Delivers one relay card as plain text and returns its Telegram receipt.
    ///
    /// A failure is recorded on the control state but never written to the
    /// terminal: cards are asynchronous notifications, and a transient Telegram
    /// error must not inject noise into the operator's transcript.
    func sendTelegramSharedChatCard(
        _ text: String, to chatID: Int64,
        lease: TerminalTelegramRouteLease
    ) async -> Int? {
        guard telegramControlState.isActive,
              let lifecycleEpoch = telegramControlState.wireLifecycleEpoch else {
            return nil
        }
        guard lease.key.chatID == chatID,
              (try? await telegramSessionRouter.validate(lease)) != nil else { return nil }
        let fence = TerminalTelegramWireFence(
            lease: lease,
            lifecycleEpoch: lifecycleEpoch,
            validateLease: { [telegramSessionRouter] lease in
                try await telegramSessionRouter.validate(lease)
            }
        )
        do {
            return try await telegramControlService.sendPlainMessageWithReceipt(
                text,
                to: chatID,
                topicID: lease.effectiveMessageThreadID,
                fence: fence
            )
        } catch {
            telegramControlState.lastError = error.localizedDescription
            return nil
        }
    }

    /// Resolves the participant a Telegram reply addresses, or `nil` when the
    /// quoted message is not an answerable card of the live room.
    ///
    /// Single source of truth for "this message is a direct reply": the text
    /// route and the voice-note guard must agree, otherwise a message could be
    /// refused as a reply on one path and treated as an ordinary prompt on the
    /// other. A card whose sender has no live destination — the operator's own
    /// mirrored traffic — is deliberately not one, so answering it by voice or by
    /// text simply prompts the session as usual.
    func telegramDirectReplyTarget(
        for message: TerminalTelegramIncomingMessage
    ) async -> TerminalTelegramSharedChatReplyTarget? {
        guard let replyToMessageID = message.replyToMessageID,
              let lease = telegramActiveRouteLease,
              lease.key.chatID == message.chatID,
              let target = await telegramSharedChatRelay.replyTarget(
                  forTelegramMessageID: replyToMessageID,
                  chatID: message.chatID,
                  lease: lease
              ),
              target.roomID == sessionID,
              target.replyDestination != nil else {
            return nil
        }
        return target
    }

    /// Routes a Telegram reply back to the participant that produced the quoted
    /// card. Returns `true` when the message was consumed as a live reply.
    ///
    /// The destination comes only from the relay's local receipt map and the
    /// stable sender id it recorded, never from the quoted text: Telegram echoes
    /// user-controlled content in `reply_to_message`, which must not be able to
    /// address an arbitrary participant. When the quoted card is unknown the
    /// message falls through to the ordinary prompt path.
    func handleTelegramSharedChatReplyIfNeeded(
        _ text: String,
        message: TerminalTelegramIncomingMessage,
        origin: TerminalPromptOrigin
    ) async -> Bool {
        guard let target = await telegramDirectReplyTarget(for: message),
              let destination = target.replyDestination else {
            return false
        }

        // The sender may have finished since its card was delivered. Fail loudly
        // instead of silently turning the reply into a root prompt: the operator
        // explicitly addressed one participant.
        guard await isCurrentSharedChatDirectDestination(destination) else {
            await sendTelegramSystemMessage(
                "ZenCODE message: that agent is no longer active, so the reply was not delivered.",
                to: message.chatID,
                origin: origin
            )
            return true
        }

        do {
            _ = try await sessionRunner.sendSharedChatMessage(
                text: text,
                destination: destination,
                rootSessionID: target.roomID
            )
            await refreshSharedChatPanelSuggestions()
        } catch {
            let safeError = Self.sharedChatInlineTerminalSafeText(error.localizedDescription)
            await sendTelegramSystemMessage(
                "ZenCODE message: \(safeError)",
                to: message.chatID,
                origin: origin
            )
        }
        return true
    }
}
