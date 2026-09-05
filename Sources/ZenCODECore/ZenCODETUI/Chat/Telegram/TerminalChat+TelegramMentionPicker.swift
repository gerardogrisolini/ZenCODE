//
//  TerminalChat+TelegramMentionPicker.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension TerminalChat {

    // MARK: - Mention picker

    nonisolated static let telegramMentionPickerCallbackPrefix = "zencode:mention:"

    /// `/chat` opens the explicit, non-ambiguous picker for Telegram, whose Bot
    /// API has no typing events. It is intentionally available while a turn is
    /// generating: choosing a recipient does not enqueue or start work.
    func handleTelegramMentionPickerRequest(
        chatID: Int64, origin: TerminalPromptOrigin? = nil
    ) async {
        let buttons = Self.telegramMentionPickerButtons(
            from: await sharedChatMentionSuggestions()
        )
        guard !buttons.isEmpty else { return }
        let markup = TerminalTelegramReplyMarkup.inlineKeyboard(buttons.map { [$0] })
        _ = await sendTelegramReplyMarkupMessage(
            "Choose who to message. After selecting, reply to the next card with your message.",
            to: chatID,
            replyMarkup: markup,
            origin: origin
        )
    }

    nonisolated static func telegramMentionPickerButtons(
        from suggestions: [TerminalCommandSuggestion]
    ) -> [TerminalTelegramInlineKeyboardButton] {
        suggestions.compactMap { suggestion in
            let handle = suggestion.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard handle.first == "@", handle != "@all", handle.utf8.count <= 48 else { return nil }
            return TerminalTelegramInlineKeyboardButton(
                text: handle,
                callbackData: telegramMentionPickerCallbackPrefix + String(handle.dropFirst())
            )
        }
    }

    func handleTelegramMentionPickerCallback(
        _ data: String, chatID: Int64, origin: TerminalPromptOrigin? = nil
    ) async {
        guard let lease = origin?.telegramLease,
              lease.key.chatID == chatID,
              (try? await telegramSessionRouter.validate(lease)) != nil else { return }
        guard data.hasPrefix(Self.telegramMentionPickerCallbackPrefix) else { return }
        let handle = String(data.dropFirst(Self.telegramMentionPickerCallbackPrefix.count))
        guard handle.utf8.count <= 48 else { return }
        let roster = await sessionRunner.sharedChatMentionRoster(rootSessionID: sessionID)
        guard case let .route(route) = Self.parseSharedChatMention(
            from: "@\(handle) selected",
            readableHandles: roster.handleMap
        ), await isCurrentSharedChatDirectDestination(route.destination) else {
            await sendTelegramSystemMessage(
                "ZenCODE message: that agent is no longer active. Run /chat again.",
                to: chatID,
                origin: .telegramLease(lease)
            )
            return
        }
        let receipt = await sendTelegramReplyMarkupMessage(
            "Writing to @\(handle). Reply to this message with the content to send; it will not be treated as a normal prompt.",
            to: chatID,
            replyMarkup: .forceReply,
            origin: origin
        )
        guard let receipt else { return }
        await telegramSharedChatRelay.registerReplyTarget(
            Self.telegramMentionPickerReplyTarget(
                destination: route.destination, roomID: sessionID, chatID: chatID, handle: handle
            ),
            forTelegramMessageID: receipt,
            lease: lease
        )
    }

    /// Wire helper shared with the artifact-consent and relay extensions.
    func sendTelegramReplyMarkupMessage(
        _ text: String, to chatID: Int64, replyMarkup: TerminalTelegramReplyMarkup,
        origin: TerminalPromptOrigin? = nil
    ) async -> Int? {
        if let hook = onTelegramMentionPickerMessage { return await hook(text, chatID, replyMarkup) }
        guard let origin, let fence = telegramWireFence(for: origin) else { return nil }
        do {
            return try await telegramControlService.sendPlainMessageWithReceipt(
                text, to: chatID,
                topicID: origin.telegramLease?.effectiveMessageThreadID,
                replyMarkup: replyMarkup, fence: fence
            )
        }
        catch { telegramControlState.lastError = error.localizedDescription; return nil }
    }

    nonisolated static func telegramMentionPickerReplyTarget(
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
