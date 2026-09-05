//
//  TerminalTelegramPairingService.swift
//  ZenCODE
//
//  Pairing domain of the Telegram runtime: the waiting actor, its DTOs and
//  the hard-deadline long poll. Extracted verbatim from
//  TerminalTelegramControlService.swift.
//

import Foundation
import ToolCore

public struct TerminalTelegramIncomingMessage: Equatable, Sendable {
    public let chatID: Int64
    public let userID: Int64
    public let topicID: Int?
    public let chatKind: TerminalTelegramChatKind
    public let text: String?
    public let voice: TerminalTelegramVoiceAttachment?
    public let messageID: Int
    public let chatTitle: String?
    public let username: String?
    /// Identifier of the message this one replies to, when the user used
    /// Telegram's *Reply* action. It is the only durable link between a card the
    /// bot sent and the answer typed for it.
    public let replyToMessageID: Int?
    /// Non-nil only for a Telegram inline-keyboard callback. Keeping callbacks
    /// on the existing ingress stream preserves source compatibility.
    public let callbackQueryID: String?
    public let callbackData: String?
    /// Native Telegram draft generation stopped by the linked user. This event
    /// has no ordinary message/user identifier on the Bot API wire.
    public let stoppedMessageGenerationDraftID: Int?
    /// Selective media ingress: an admitted document or photo attachment.
    /// `nil` for every message that carries neither (or whose media was
    /// refused by the ingress gate).
    public let attachment: TerminalTelegramInboundAttachment?

    /// Trailing default keeps existing call sites source-compatible while the
    /// reply link is optional on the wire.
    public init(
        chatID: Int64,
        userID: Int64,
        topicID: Int? = nil,
        chatKind: TerminalTelegramChatKind = .privateChat,
        text: String?,
        voice: TerminalTelegramVoiceAttachment?,
        messageID: Int,
        chatTitle: String?,
        username: String?,
        replyToMessageID: Int? = nil,
        callbackQueryID: String? = nil,
        callbackData: String? = nil,
        stoppedMessageGenerationDraftID: Int? = nil,
        attachment: TerminalTelegramInboundAttachment? = nil
    ) {
        self.chatID = chatID
        self.userID = userID
        self.topicID = topicID
        self.chatKind = chatKind
        self.text = text
        self.voice = voice
        self.messageID = messageID
        self.chatTitle = chatTitle
        self.username = username
        self.replyToMessageID = replyToMessageID
        self.callbackQueryID = callbackQueryID
        self.callbackData = callbackData
        self.stoppedMessageGenerationDraftID = stoppedMessageGenerationDraftID
        self.attachment = attachment
    }
}

public struct TerminalTelegramVoiceAttachment: Equatable, Sendable {
    public let fileID: String
    public let fileUniqueID: String?
    public let duration: Int?
    public let mimeType: String?
    public let fileSize: Int?
}

public struct TerminalTelegramBotIdentity: Equatable, Sendable {
    public let username: String?
}

public struct TerminalTelegramLinkedChat: Equatable, Sendable {
    public let chatID: Int64
    public let userID: Int64
    public let chatTitle: String?
}

public enum TerminalTelegramPairingError: LocalizedError, Equatable {
    case expired

    public var errorDescription: String? {
        switch self {
        case .expired:
            "Telegram pairing expired. Run /setup again to generate a new pairing link."
        }
    }
}

public actor TerminalTelegramPairingService {
    private enum PollResult: Sendable {
        case updates([TerminalTelegramUpdate])
        case expired
    }

    private let client: TerminalTelegramAPIClient
    private var lastUpdateID: Int?
    /// Single-flight guard for `waitForPairing`. Without it two overlapping
    /// waits observe the same `lastUpdateID` and a late write from one can
    /// regress the offset seen by the other, reprocessing updates and racing to
    /// complete pairing.
    private var pairingInProgress = false
    /// Grants issued by this pairing session; consumed atomically by payload.
    private let grantStore = TerminalTelegramPairingGrantStore()

    public init(botToken: String) {
        client = TerminalTelegramAPIClient(token: botToken)
    }

    init(botToken: String, transport: any TelegramHTTPTransport) {
        client = TerminalTelegramAPIClient(token: botToken, transport: transport)
    }

    public func prepare() async throws -> TerminalTelegramBotIdentity {
        _ = try? await client.deleteWebhook(dropPendingUpdates: true)
        let bot = try await client.getMe()
        return TerminalTelegramBotIdentity(username: bot.username)
    }

    /// Issues one single-use pairing grant and returns the payload to embed in
    /// the deep link (and to show for manual fallback). The terminal shows:
    ///   https://t.me/<bot>?start=<payload>
    /// and Telegram delivers `/start <payload>` back to the bot. The payload is
    /// also shown as a manual code, so a client that cannot open links still
    /// pairs by sending it as a plain message.
    public func issuePairingGrant() async -> String {
        await grantStore.issueGrant()
    }

    /// Convenience for setup: issue a grant and build the deep link for the
    /// paired bot username in one call.
    public func issuePairingDeepLink(botUsername: String?) async -> (
        payload: String, deepLink: String?
    ) {
        let payload = await grantStore.issueGrant()
        let link = botUsername.map {
            TerminalTelegramPairingGrantLink.deepLink(botUsername: $0, payload: payload)
        }
        return (payload, link)
    }

    /// Consumes a grant payload atomically. Returns `true` exactly once per
    /// issued, unexpired grant.
    public func consumePairingGrant(payload: String) async -> Bool {
        await grantStore.consume(payload: payload)
    }

    /// Chat-aware consume used by ingress: rejected group presentations never
    /// spend a grant that may still be completed from the intended private chat.
    public func consumePairingGrant(payload: String, chatType: String) async -> Bool {
        guard Self.allowsPairing(chatType: chatType) else { return false }
        return await grantStore.consume(payload: payload)
    }

    public func waitForPairing(
        code: String,
        deadline: Date? = nil
    ) async throws -> TerminalTelegramLinkedChat {
        // Single-flight: reject a second concurrent pairing wait. Two
        // overlapping waits would share `lastUpdateID` and a late write from one
        // could regress the offset seen by the other, reprocessing updates and
        // racing to complete pairing. `CancellationError` is reused so no new
        // public error case is introduced.
        guard !pairingInProgress else {
            throw CancellationError()
        }
        pairingInProgress = true
        defer { pairingInProgress = false }

        let expectedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let deadline = deadline ?? Date().addingTimeInterval(
            TerminalTelegramPairingGrant.timeToLive
        )
        while !Task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw TerminalTelegramPairingError.expired
            }
            let updates = try await updatesBeforeDeadline(
                offset: lastUpdateID.map { $0 + 1 },
                timeout: min(30, max(1, Int(remaining.rounded(.up)))),
                remaining: remaining
            )
            for update in updates {
                lastUpdateID = max(lastUpdateID ?? update.updateID, update.updateID)
                guard let message = update.message,
                      let text = message.text?.nilIfBlank,
                      let user = message.from,
                      user.isBot != true else {
                    continue
                }

                // A deep-link `/start <payload>` carries a pairing grant: it is
                // consumed exactly once, atomically, before the link is
                // accepted. The same rule covers the manual fallback, where
                // the operator types the payload (or `/start <payload>`) as a
                // plain message.
                let candidate = Self.pairingCode(in: text)
                    ?? TerminalTelegramPairingGrantLink.payload(fromStartCommand: text)
                if let candidate {
                    guard Self.allowsPairing(chatType: message.chat.type) else {
                        _ = try? await client.sendMessage(
                            "For security, ZenCODE can only be linked from a private Telegram chat.",
                            to: message.chat.id
                        )
                        continue
                    }
                    guard await consumePairingGrant(
                        payload: candidate, chatType: message.chat.type
                    ) else {
                        continue
                    }
                    try await client.sendMessage(
                        "Telegram linked to ZenCODE.",
                        to: message.chat.id
                    )
                    return TerminalTelegramLinkedChat(
                        chatID: message.chat.id,
                        userID: user.id,
                        chatTitle: message.chat.displayTitle
                    )
                }

                guard Self.pairingCode(in: text) == expectedCode else {
                    _ = try? await client.sendMessage(
                        "ZenCODE setup is waiting for the pairing code shown in the terminal.",
                        to: message.chat.id
                    )
                    continue
                }

                guard Self.allowsPairing(chatType: message.chat.type) else {
                    _ = try? await client.sendMessage(
                        "For security, ZenCODE can only be linked from a private Telegram chat.",
                        to: message.chat.id
                    )
                    continue
                }

                try await client.sendMessage(
                    "Telegram linked to ZenCODE.",
                    to: message.chat.id
                )
                return TerminalTelegramLinkedChat(
                    chatID: message.chat.id,
                    userID: user.id,
                    chatTitle: message.chat.displayTitle
                )
            }
        }
        throw CancellationError()
    }

    /// Races each long poll against the local grant deadline. Structured
    /// cancellation makes the deadline cancel and await the in-flight transport
    /// before the actor accepts another pairing wait.
    private func updatesBeforeDeadline(
        offset: Int?,
        timeout: Int,
        remaining: TimeInterval
    ) async throws -> [TerminalTelegramUpdate] {
        let client = client
        let nanoseconds = Int64(min(remaining * 1_000_000_000, Double(Int64.max)))
        return try await withThrowingTaskGroup(of: PollResult.self) { group in
            group.addTask {
                .updates(try await client.getUpdates(offset: offset, timeout: timeout))
            }
            group.addTask {
                try await Task.sleep(for: .nanoseconds(max(1, nanoseconds)))
                return .expired
            }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            switch first {
            case .updates(let updates):
                return updates
            case .expired:
                throw TerminalTelegramPairingError.expired
            }
        }
    }

    public nonisolated static func pairingCode(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace || $0.isNewline }
        )
        guard let firstPart = parts.first else {
            return nil
        }

        let command = String(firstPart).lowercased()
        if command == "/start" || command.hasPrefix("/start@") {
            guard parts.count == 2 else {
                return nil
            }
            return String(parts[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
        }

        return trimmed.uppercased()
    }

    public nonisolated static func allowsPairing(chatType: String) -> Bool {
        chatType.caseInsensitiveCompare("private") == .orderedSame
    }
}
