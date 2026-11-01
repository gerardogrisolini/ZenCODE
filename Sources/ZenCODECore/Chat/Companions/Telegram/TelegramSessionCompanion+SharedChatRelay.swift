//
//  TelegramSessionCompanion+SharedChatRelay.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The live shared-chat relay: operator-directed messages forwarded to the
/// linked chat as cards, Telegram replies to a card delivered back to its
/// sender, and live `@mention` messages sent from Telegram, published as the
/// terminal's `TerminalChat+SharedChat.swift` publishes the operator's own.
extension TelegramSessionCompanion {
    // MARK: - Relay

    /// Forwards operator-directed shared-chat messages to the linked chat
    /// and resolves Telegram replies back to their sender. Created on first
    /// use and owned for the companion's whole lifetime, so its ledger
    /// survives ``detach()`` → ``attach()``.
    var sharedChatRelay: TerminalTelegramSharedChatRelay {
        if let relay = sharedChatRelayStorage {
            return relay
        }
        let relay = TerminalTelegramSharedChatRelay(
            validateLease: { [weak self] lease in
                guard let self else { return false }
                return (try? await self.router.validate(lease)) != nil
            },
            send: { [weak self] text, chatID, lease in
                await self?.sendSharedChatCard(text, to: chatID, lease: lease) ?? nil
            }
        )
        sharedChatRelayStorage = relay
        return relay
    }

    // MARK: - Live-message relay

    /// Reports whether `text` is already claimed by a higher-precedence route, in
    /// which case quoting a card must not change its meaning.
    ///
    /// The decision uses the real parsers: ``CoordinatorCommandParser`` for
    /// slash commands (every remote command's canonical form is a slash line)
    /// and the actual ``SharedChatMentionParser/parse(from:readableHandles:)``
    /// outcome for mentions — including `missingText`, which is a recognised
    /// mention whose diagnostic must not be replaced by a reply. Plain-word
    /// command aliases ("status", "diff", ...) do not take precedence: quoting
    /// a card and answering "diff" is an answer to its sender, as in the
    /// terminal. A leading `@` that resolves to nothing is not a mention, so
    /// it does not suppress the reply route.
    func replyRoutingHasPrecedence(over text: String) async -> Bool {
        if CoordinatorCommandParser.isSlashCommand(text) {
            return true
        }
        switch SharedChatMentionParser.parse(
            from: text,
            readableHandles: await sessionRunner.sharedChatMentionHandles(
                rootSessionID: controller.sessionID
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
    /// The primary channel's single observation of the room stays the only
    /// subscriber and calls this with each batch; the relay owns its own
    /// delivery ledger, so a reader buffer of the channel (which may be rebuilt
    /// on a forced reattach) can never be mistaken for an "already sent"
    /// record.
    func forwardSharedChatMessages(
        _ messages: [AgentSharedChat.Message],
        roomID: String
    ) async {
        guard controlState.isActive,
              activeRouteLease != nil || linkedChatID != nil else {
            return
        }
        let roster = await sessionRunner.sharedChatMentionRoster(rootSessionID: roomID)
        await sharedChatRelay.forward(
            messages,
            roomID: roomID,
            participants: roster.participants
        )
    }

    /// Follows a room swap (`/new`, `/resume`, observation restart). A new room
    /// invalidates the ledger and the receipt map: identifiers of a retired room
    /// must never route a reply into the live one. Cards invite a reply only
    /// while ``readsIngress`` is `true`.
    func rebindSharedChatRelay(roomID: String) async {
        guard controlState.isActive,
              let lease = activeRouteLease,
              lease.key.roomID == roomID,
              (try? await router.validate(lease)) != nil else {
            // A room swap or invalidated lease retires every command receipt
            // associated with this session before a new route can be bound.
            commandReplyBindings.removeAll()
            await sharedChatRelay.deactivate()
            return
        }
        await sharedChatRelay.activate(
            roomID: roomID,
            chatID: lease.key.chatID,
            lease: lease,
            repliesEnabled: readsIngress
        )
    }

    /// Delivers one relay card as plain text and returns its Telegram receipt.
    ///
    /// A failure is recorded on the control state but never presented on the
    /// primary channel: cards are asynchronous notifications, and a transient
    /// Telegram error must not inject noise into the operator's transcript.
    func sendSharedChatCard(
        _ text: String, to chatID: Int64,
        lease: TerminalTelegramRouteLease
    ) async -> Int? {
        guard controlState.isActive,
              let lifecycleEpoch = controlState.wireLifecycleEpoch else {
            return nil
        }
        guard lease.key.chatID == chatID,
              (try? await router.validate(lease)) != nil else { return nil }
        let fence = TerminalTelegramWireFence(
            lease: lease,
            lifecycleEpoch: lifecycleEpoch,
            validateLease: { [router] lease in
                try await router.validate(lease)
            }
        )
        do {
            return try await controlService.sendPlainMessageWithReceipt(
                text,
                to: chatID,
                topicID: lease.effectiveMessageThreadID,
                fence: fence
            )
        } catch {
            controlState.lastError = TerminalTelegramControlError.operatorDescription(error)
            return nil
        }
    }

    // MARK: - Replies

    /// Resolves the participant a Telegram reply addresses, or `nil` when the
    /// quoted message is not an answerable card of the live room.
    ///
    /// Single source of truth for "this message is a direct reply": the text
    /// route and the voice-note guard must agree, otherwise a message could be
    /// refused as a reply on one path and treated as an ordinary prompt on the
    /// other. A card whose sender has no live destination — the operator's own
    /// mirrored traffic — is deliberately not one, so answering it by voice or by
    /// text simply prompts the session as usual.
    func directReplyTarget(
        for message: TerminalTelegramIncomingMessage
    ) async -> TerminalTelegramSharedChatReplyTarget? {
        guard let replyToMessageID = message.replyToMessageID,
              let lease = activeRouteLease,
              lease.key.chatID == message.chatID,
              let target = await sharedChatRelay.replyTarget(
                  forTelegramMessageID: replyToMessageID,
                  chatID: message.chatID,
                  lease: lease
              ),
              target.roomID == controller.sessionID,
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
    /// message falls through to the ordinary prompt path. A delivered reply
    /// changes the shared chat, so the primary channel is told with
    /// ``TelegramCompanionChannel/sharedChatPanelDidChange()``.
    func handleSharedChatReplyIfNeeded(
        _ text: String,
        message: TerminalTelegramIncomingMessage,
        origin: TelegramTurnOrigin
    ) async -> Bool {
        guard let target = await directReplyTarget(for: message),
              let destination = target.replyDestination else {
            return false
        }

        // The sender may have finished since its card was delivered. Fail loudly
        // instead of silently turning the reply into a root prompt: the operator
        // explicitly addressed one participant.
        guard await isCurrentSharedChatDirectDestination(destination) else {
            await sendSystemMessage(
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
            await channel?.sharedChatPanelDidChange()
        } catch {
            let safeError = SharedChatMentionParser.inlineTerminalSafeText(
                TerminalTelegramControlError.operatorDescription(error)
            )
            await sendSystemMessage(
                "ZenCODE message: \(safeError)",
                to: message.chatID,
                origin: origin
            )
        }
        return true
    }

    /// The shared-chat actor accepts legacy display names as direct
    /// identifiers. The companion must not use that ambiguous fallback:
    /// confirm that a direct destination names one current active agent by
    /// ID, in the session's mention roster, before delivery. Any other
    /// destination is current.
    func isCurrentSharedChatDirectDestination(
        _ destination: AgentSharedChat.Destination
    ) async -> Bool {
        guard case let .direct(identifiers) = destination,
              identifiers.count == 1,
              let identifier = identifiers.first else {
            return true
        }
        let roster = await sessionRunner.sharedChatMentionRoster(
            rootSessionID: controller.sessionID
        )
        return roster.participants.contains {
            $0.kind == .agent && $0.isActive && $0.id == identifier
        }
    }

    // MARK: - Live mentions

    /// Publishes a live `@mention` sent from Telegram on `origin`'s route, as
    /// the terminal's `sendSharedChatMention(_:)` publishes the operator's.
    /// Returns `true` when the room accepted the message (or the
    /// ``TelegramWorkEffectForTesting/sharedChatPublication`` seam consumed
    /// it), `false` for a direct recipient that is no longer active or a
    /// failed publication.
    ///
    /// The origin is recorded before the message crosses to the runtime, so
    /// the coordinator turn the message triggers answers on the same route
    /// (see ``takeSharedChatOrigin(for:)``). Every outcome but a failed
    /// publication tells the primary channel that the shared chat changed
    /// (``TelegramCompanionChannel/sharedChatPanelDidChange()``). A recipient
    /// that is gone is reported on the primary channel only, like the
    /// terminal; a failed publication is reported there and in the chat,
    /// through the route that admitted the mention.
    @discardableResult
    func sendSharedChatMention(
        _ route: SharedChatMentionParser.Route,
        origin: TelegramTurnOrigin
    ) async -> Bool {
        if onTelegramWorkEffectForTesting?(.sharedChatPublication) == true { return true }
        guard await isCurrentSharedChatDirectDestination(route.destination) else {
            await channel?.presentCompanionNotice(
                "ZenCODE message: selected agent is no longer active.\n",
                channel: .failure
            )
            await channel?.sharedChatPanelDidChange()
            return false
        }

        let messageID = UUID()
        // Record before crossing an actor boundary. The backend publishes and
        // wakes the coordinator while this actor is suspended, so recording
        // only after `sendSharedChatMessage` returns races the auto-trigger.
        recordSharedChatMessageOrigin(messageID, origin: origin)
        do {
            let delivery = try await sessionRunner.sendSharedChatMessage(
                text: route.text,
                destination: route.destination,
                rootSessionID: controller.sessionID,
                messageID: messageID
            )
            assert(delivery.message.id == messageID)
            await channel?.sharedChatPanelDidChange()
            return true
        } catch {
            discardSharedChatMessageOrigin(messageID)
            let safeError = SharedChatMentionParser.inlineTerminalSafeText(error.localizedDescription)
            let failureMessage = "ZenCODE message: \(safeError)"
            await channel?.presentCompanionNotice(failureMessage + "\n", channel: .failure)
            // The same generation-fenced route that admitted the mention: a
            // revoked or stale lease sends nothing, and transport details are
            // never reflected to another chat.
            await sendSystemMessageIfLinked(failureMessage, origin: origin)
            return false
        }
    }

    /// Associates a shared-chat message sent from Telegram with the
    /// coordinator turn that will consume it. The shared-chat bus carries no
    /// transport metadata, so this short-lived association keeps the
    /// Telegram route of the answer. Bounded like the retained transcript.
    func recordSharedChatMessageOrigin(_ messageID: UUID, origin: TelegramTurnOrigin) {
        if sharedChatMessageOrigins[messageID] == nil {
            sharedChatMessageOriginOrder.append(messageID)
        }
        sharedChatMessageOrigins[messageID] = origin
        let maximumOrigins = AgentSharedChat.maximumRetainedMessagesPerRoom
        while sharedChatMessageOriginOrder.count > maximumOrigins {
            let oldestMessageID = sharedChatMessageOriginOrder.removeFirst()
            sharedChatMessageOrigins.removeValue(forKey: oldestMessageID)
        }
    }

    /// Forgets the origin of a message that was never published.
    func discardSharedChatMessageOrigin(_ messageID: UUID) {
        sharedChatMessageOrigins.removeValue(forKey: messageID)
        sharedChatMessageOriginOrder.removeAll { $0 == messageID }
    }

    /// The Telegram origin of a shared-chat trigger: the origin of the first
    /// message of `messages` sent from Telegram, or `nil`. Every message's
    /// association is consumed, so a replay cannot mirror an unrelated later
    /// coordinator response.
    func takeSharedChatOrigin(for messages: [AgentSharedChat.Message]) -> TelegramTurnOrigin? {
        var origin: TelegramTurnOrigin?
        for message in messages {
            if origin == nil {
                origin = sharedChatMessageOrigins[message.id]
            }
            sharedChatMessageOrigins.removeValue(forKey: message.id)
            sharedChatMessageOriginOrder.removeAll { $0 == message.id }
        }
        return origin
    }
}
