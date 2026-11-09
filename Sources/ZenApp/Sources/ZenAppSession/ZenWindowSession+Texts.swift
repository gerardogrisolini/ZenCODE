//
//  ZenWindowSession+Texts.swift
//  ZenApp
//
//  The texts a window shows, most of them the terminal's.
//

import Foundation
import ZenCODECore

extension ZenWindowSession {
    // MARK: - Texts

    /// The ending of a turn the operator stopped.
    static let turnCancelledText = "Turn cancelled."
    /// The answer to a live mention without a message, the terminal's.
    static let mentionMissingTextMessage = "ZenCODE message: add a message after the live mention."
    /// The answer to a mention of an agent that left the room, the terminal's.
    static let mentionInactiveAgentMessage = "ZenCODE message: selected agent is no longer active."
    /// The mentions of a room without agents: `@coordinator` and `@all`.
    nonisolated static let emptyMentionSuggestions = SharedChatMentionParser.suggestions(for: [], handleMap: [:])

    /// The answer to a mention the room did not take, the terminal's.
    static func mentionFailureMessage(for error: any Error) -> String {
        "ZenCODE message: \(SharedChatMentionParser.inlineTerminalSafeText(error.localizedDescription))"
    }

    /// The row once Telegram drives the slot, the terminal's status line.
    static let telegramDrivingStatusText = "Session driven from Telegram. Type /telegram off to take it back."
    /// The answer to `/telegram` with any other argument, the terminal's.
    static let telegramUsageText = "Usage: /telegram [on|off]"
    /// The answer of a dormant window, the host's.
    static let dormantRefusalText = withoutTrailingNewlines(ChatSlotAdmission.dormantRefusalText)
    /// The answer to a dictated plain prompt the full queue refuses, the
    /// terminal's (a dictated line gets ``queueFullMessage``, as typed).
    static let voiceQueueFullMessage = "ZenCODE: prompt queue is full; voice prompt was not queued."
    /// The time between two reads of an adopted turn's reservation.
    static let adoptedTelegramTurnPollInterval: Duration = .milliseconds(100)

    /// `text` without the trailing newlines of the terminal's messages, which
    /// the core's texts keep.
    nonisolated static func withoutTrailingNewlines(_ text: String) -> String {
        var text = text
        while text.last?.isNewline == true {
            text.removeLast()
        }
        return text
    }

    nonisolated static func text(for error: ChatSessionHostError) -> String {
        switch error {
        case .sessionBusy:
            "ZenCODE: a prompt is already running in this session."
        case .shutDown:
            "ZenCODE: the app is shutting down."
        case .noSession, .unknownSlot:
            "ZenCODE: this window has no session."
        case let .savedSessionNotFound(name):
            "ZenCODE: saved session '\(name)' not found."
        default:
            "ZenCODE: \(error)"
        }
    }

    static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
