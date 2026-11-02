//
//  TelegramChannel+MentionPicker.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The `/chat` mention picker: a keyboard of the live recipients, then a
/// ForceReply card whose reply goes to the chosen one.
extension TelegramChannel {
    // MARK: - Mention picker

    /// The callback data prefix of a picker button, followed by the handle.
    nonisolated static let mentionPickerCallbackPrefix = "zencode:mention:"

    /// `/chat` opens the explicit, non-ambiguous picker for Telegram, whose Bot
    /// API has no typing events. It is intentionally available while a turn is
    /// generating: choosing a recipient does not enqueue or start work.
    func handleMentionPickerRequest(
        chatID: Int64, lease: TerminalTelegramRouteLease
    ) async {
        let buttons = Self.mentionPickerButtons(
            from: await sharedChatMentionSuggestions()
        )
        guard !buttons.isEmpty else { return }
        let markup = TerminalTelegramReplyMarkup.inlineKeyboard(buttons.map { [$0] })
        _ = await sendReplyMarkupMessage(
            "Choose who to message. After selecting, reply to the next card with your message.",
            to: chatID,
            replyMarkup: markup,
            lease: lease
        )
    }

    /// The live `@mention` catalogue of the session's room, from one roster
    /// snapshot (see ``SharedChatMentionParser/suggestions(for:handleMap:)``).
    func sharedChatMentionSuggestions() async -> [SharedChatMentionParser.Suggestion] {
        let roster = await sessionRunner.sharedChatMentionRoster(
            rootSessionID: sessionID
        )
        return SharedChatMentionParser.suggestions(
            for: roster.participants,
            handleMap: roster.handleMap
        )
    }

    /// One button per direct recipient: `@all` is left out, because the card
    /// that follows is a direct reply, and so is a handle too long for the
    /// callback data.
    nonisolated static func mentionPickerButtons(
        from suggestions: [SharedChatMentionParser.Suggestion]
    ) -> [TerminalTelegramInlineKeyboardButton] {
        suggestions.compactMap { suggestion in
            let handle = suggestion.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard handle.first == "@", handle != "@all", handle.utf8.count <= 48 else { return nil }
            return TerminalTelegramInlineKeyboardButton(
                text: handle,
                callbackData: mentionPickerCallbackPrefix + String(handle.dropFirst())
            )
        }
    }

    /// Answers the tap of a picker button with the ForceReply card whose
    /// reply goes to the chosen recipient, which must still be in the
    /// roster. The ingress calls it for a callback whose data has
    /// ``mentionPickerCallbackPrefix``.
    func handleMentionPickerCallback(
        _ data: String, chatID: Int64, lease: TerminalTelegramRouteLease
    ) async {
        guard lease.key.chatID == chatID,
              (try? await router.validate(lease)) != nil else { return }
        guard data.hasPrefix(Self.mentionPickerCallbackPrefix) else { return }
        let handle = String(data.dropFirst(Self.mentionPickerCallbackPrefix.count))
        guard handle.utf8.count <= 48 else { return }
        let roster = await sessionRunner.sharedChatMentionRoster(
            rootSessionID: sessionID
        )
        guard case let .route(route) = SharedChatMentionParser.parse(
            from: "@\(handle) selected",
            readableHandles: roster.handleMap
        ), await isCurrentSharedChatDirectDestination(route.destination) else {
            await sendSystemMessage(
                "ZenCODE message: that agent is no longer active. Run /chat again.",
                to: chatID,
                lease: lease
            )
            return
        }
        let receipt = await sendReplyMarkupMessage(
            "Writing to @\(handle). Reply to this message with the content to send; it will not be treated as a normal prompt.",
            to: chatID,
            replyMarkup: .forceReply,
            lease: lease
        )
        guard let receipt else { return }
        await sharedChatRelay.registerReplyTarget(
            Self.mentionPickerReplyTarget(
                destination: route.destination, roomID: sessionID,
                chatID: chatID, handle: handle
            ),
            forTelegramMessageID: receipt,
            lease: lease
        )
    }

    /// Plain-text send with a reply markup, returning the receipt. The
    /// ``onTelegramMentionPickerMessage`` seam takes it over in tests.
    func sendReplyMarkupMessage(
        _ text: String, to chatID: Int64, replyMarkup: TerminalTelegramReplyMarkup,
        lease: TerminalTelegramRouteLease
    ) async -> Int? {
        if let hook = onTelegramMentionPickerMessage { return await hook(text, chatID, replyMarkup) }
        guard let fence = wireFence(for: lease) else { return nil }
        do {
            return try await controlService.sendPlainMessageWithReceipt(
                text, to: chatID,
                topicID: lease.effectiveMessageThreadID,
                replyMarkup: replyMarkup, fence: fence
            )
        } catch {
            controlState.lastError = TerminalTelegramControlError.operatorDescription(error)
            return nil
        }
    }

    /// The reply target a picker card registers for the chosen destination.
    nonisolated static func mentionPickerReplyTarget(
        destination: AgentSharedChat.Destination, roomID: String, chatID: Int64, handle: String
    ) -> TerminalTelegramSharedChatReplyTarget {
        let senderID: String
        let senderKind: AgentSharedChat.ParticipantKind
        let senderName: String
        switch destination {
        case let .direct(ids):
            senderID = ids.first ?? ""
            senderKind = .agent
            senderName = handle
        case .coordinator:
            senderID = AgentSharedChat.coordinatorID(for: roomID)
            senderKind = .coordinator
            senderName = "coordinator"
        case .all, .operator, .peers:
            // These are excluded from the picker because force-reply is direct.
            senderID = ""
            senderKind = .operator
            senderName = handle
        }
        return TerminalTelegramSharedChatReplyTarget(
            roomID: roomID, chatID: chatID, sharedChatMessageID: UUID(),
            senderID: senderID, senderKind: senderKind, senderName: senderName
        )
    }
}
