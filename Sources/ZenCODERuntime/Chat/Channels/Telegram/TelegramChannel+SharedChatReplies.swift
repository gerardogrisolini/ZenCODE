//
//  TelegramChannel+SharedChatReplies.swift
//  ZenCODE
//
//  Telegram replies to a shared-chat card, delivered back to their sender,
//  and the live `@mention` messages sent from Telegram, with the route each
//  message arrived on.
//

import Foundation
import ToolCore

extension TelegramChannel {
    // MARK: - Replies

    /// Resolves the participant a Telegram reply addresses, or `nil` when the
    /// quoted message is not an answerable card of the live room.
    ///
    /// Single source of truth for "this message is a direct reply": the text
    /// route and the voice-note guard must agree, otherwise a message could be
    /// refused as a reply on one path and treated as an ordinary prompt on the
    /// other. A card whose sender has no live destination — the operator's own
    /// traffic — is deliberately not one, so answering it by voice or by text
    /// simply prompts the session as usual.
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
    func handleSharedChatReplyIfNeeded(
        _ text: String,
        message: TerminalTelegramIncomingMessage,
        lease: TerminalTelegramRouteLease
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
                lease: lease
            )
            return true
        }

        do {
            _ = try await sessionRunner.sendSharedChatMessage(
                text: text,
                destination: destination,
                rootSessionID: target.roomID
            )
        } catch {
            let safeError = SharedChatMentionParser.inlineTerminalSafeText(
                TerminalTelegramControlError.operatorDescription(error)
            )
            await sendSystemMessage(
                "ZenCODE message: \(safeError)",
                to: message.chatID,
                lease: lease
            )
        }
        return true
    }

    /// The shared-chat actor accepts legacy display names as direct
    /// identifiers. The channel must not use that ambiguous fallback: confirm
    /// that a direct destination names one current active agent by ID, in
    /// the session's mention roster, before delivery. Any other destination
    /// is current.
    func isCurrentSharedChatDirectDestination(
        _ destination: AgentSharedChat.Destination
    ) async -> Bool {
        guard case let .direct(identifiers) = destination,
              identifiers.count == 1,
              let identifier = identifiers.first else {
            return true
        }
        let roster = await sessionRunner.sharedChatMentionRoster(
            rootSessionID: sessionID
        )
        return roster.participants.contains {
            $0.kind == .agent && $0.isActive && $0.id == identifier
        }
    }

    // MARK: - Live mentions

    /// Routes a live shared-chat line that the busy gate would refuse, as the
    /// terminal routes a live mention before its busy branches: the agents
    /// and the coordinator are reachable exactly while they work. The
    /// precedence is the one of a free session: a slash command is never a
    /// live line (the gate answers it), a resolving `@mention` is published
    /// and a recognised one without text is diagnosed, and otherwise a reply
    /// to an answerable card (a forwarded live message, or the `/chat`
    /// picker's ForceReply card) goes to its sender. Returns `true` when the
    /// line was consumed; anything else meets the busy gate.
    func handleLiveSharedChatLineWhileBusy(
        _ text: String,
        message: TerminalTelegramIncomingMessage,
        lease: TerminalTelegramRouteLease
    ) async -> Bool {
        guard !CoordinatorCommandParser.isSlashCommand(text) else { return false }
        switch SharedChatMentionParser.parse(
            from: text,
            readableHandles: await sessionRunner.sharedChatMentionHandles(
                rootSessionID: sessionID
            )
        ) {
        case let .route(route):
            await sendSharedChatMention(route, lease: lease)
            return true
        case .missingText:
            await sendSystemMessageIfLinked(
                "ZenCODE message: add a message after the live mention.", lease: lease
            )
            return true
        case .none:
            return await handleSharedChatReplyIfNeeded(text, message: message, lease: lease)
        }
    }

    /// Publishes a live `@mention` sent from Telegram on `lease`, as the
    /// terminal's `sendSharedChatMention(_:)` publishes the operator's.
    /// Returns `true` when the room accepted the message, `false` for a
    /// direct recipient that is no longer active or a failed publication.
    ///
    /// The route is recorded before the message crosses to the runtime, so
    /// the coordinator turn the message triggers answers on the same route
    /// (see ``takeSharedChatLease(for:)``). A recipient that is gone and a
    /// failed publication are reported in the chat, through the route that
    /// admitted the mention, and on the primary channel.
    @discardableResult
    func sendSharedChatMention(
        _ route: SharedChatMentionParser.Route,
        lease: TerminalTelegramRouteLease
    ) async -> Bool {
        guard await isCurrentSharedChatDirectDestination(route.destination) else {
            await presentNotice(
                "ZenCODE message: selected agent is no longer active.\n",
                channel: .failure
            )
            await sendSystemMessageIfLinked(
                "ZenCODE message: selected agent is no longer active.", lease: lease
            )
            return false
        }

        let messageID = UUID()
        // Record before crossing an actor boundary. The backend publishes and
        // wakes the coordinator while this actor is suspended, so recording
        // only after `sendSharedChatMessage` returns races the auto-trigger.
        recordSharedChatMessageLease(messageID, lease: lease)
        do {
            let delivery = try await sessionRunner.sendSharedChatMessage(
                text: route.text,
                destination: route.destination,
                rootSessionID: sessionID,
                messageID: messageID
            )
            assert(delivery.message.id == messageID)
            return true
        } catch {
            discardSharedChatMessageLease(messageID)
            let safeError = SharedChatMentionParser.inlineTerminalSafeText(error.localizedDescription)
            let failureMessage = "ZenCODE message: \(safeError)"
            await presentNotice(failureMessage + "\n", channel: .failure)
            // The same generation-fenced route that admitted the mention: a
            // revoked or stale lease sends nothing, and transport details are
            // never reflected to another chat.
            await sendSystemMessageIfLinked(failureMessage, lease: lease)
            return false
        }
    }

    /// Associates a shared-chat message sent from Telegram with the
    /// coordinator turn that will consume it. The shared-chat bus carries no
    /// transport metadata, so this short-lived association keeps the
    /// Telegram route of the answer. Bounded like the retained transcript.
    func recordSharedChatMessageLease(_ messageID: UUID, lease: TerminalTelegramRouteLease) {
        sharedChatMessageLeases.record(messageID, lease: lease)
    }

    /// Forgets the route of a message that was never published.
    func discardSharedChatMessageLease(_ messageID: UUID) {
        sharedChatMessageLeases.discard(messageID)
    }

    /// The Telegram route of a shared-chat trigger: the route of the first
    /// message of `messages` sent from Telegram, or `nil`. Every message's
    /// association is consumed, so a replay cannot route an unrelated later
    /// coordinator response.
    func takeSharedChatLease(for messages: [AgentSharedChat.Message]) -> TerminalTelegramRouteLease? {
        sharedChatMessageLeases.take(for: messages)
    }

    /// The route of the first of `messages` the channel recorded one for,
    /// without forgetting it (``takeSharedChatLease(for:)`` does).
    func sharedChatLease(for messages: [AgentSharedChat.Message]) -> TerminalTelegramRouteLease? {
        sharedChatMessageLeases.lease(for: messages)
    }
}
