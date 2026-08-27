//
//  TelegramChatRoundTripTests.swift
//  ZenCODE
//
//  Bidirectional coverage of the Telegram chat flow: an incoming Telegram
//  message must be routed to the shared prompt queue, and the reply of that turn
//  must leave through the ordered outbound channel of the same chat.
//
//  Nothing here touches the network: ingress is driven with the same value the
//  control service yields, and egress is observed through the turn reporter's
//  injected delivery closure.
//

import Foundation
import Testing
@testable import ZenCODECore

@TerminalChatActor
@Suite
struct TelegramChatRoundTripTests {
    private static func makeTerminal(linkedChatID: Int64?) throws -> TerminalChat {
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: URL(
                    fileURLWithPath: "/tmp/telegram-round-trip-\(UUID().uuidString)",
                    isDirectory: true
                )
            ),
            stdinIsTerminal: false
        )
        terminal.telegramLinkedChatID = linkedChatID
        terminal.telegramControlState = TerminalTelegramControlState(
            isConfigured: true,
            isActive: true,
            statusText: "Active",
            botUsername: "zencode_bot",
            lastError: nil,
            lastMessagePreview: nil
        )
        return terminal
    }

    private static func message(
        _ text: String,
        chatID: Int64 = 42,
        messageID: Int = 1
    ) -> TerminalTelegramIncomingMessage {
        TerminalTelegramIncomingMessage(
            chatID: chatID,
            userID: 7,
            text: text,
            voice: nil,
            messageID: messageID,
            chatTitle: "Gerardo",
            username: "gerardo"
        )
    }

    /// Ingress is closed while Telegram is off: a message that arrives after the
    /// service was stopped must not become a prompt.
    @Test
    func messageIsIgnoredWhileTelegramIsNotActive() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        terminal.telegramControlState.isActive = false
        var queuedPrompts = TerminalQueuedPromptBuffer()

        await terminal.handleTelegramMessage(
            Self.message("questo non deve partire"),
            queuedPrompts: &queuedPrompts,
            eventQueue: TerminalChatEventQueue(),
            transcriptions: TerminalVoiceTranscriptionRegistry()
        )

        #expect(queuedPrompts.isEmpty)
    }

    /// A blank message carries no prompt, so it must not occupy a queue slot.
    @Test
    func blankMessageIsNotQueued() async throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)
        var queuedPrompts = TerminalQueuedPromptBuffer()

        await terminal.handleTelegramMessage(
            Self.message("   \n  "),
            queuedPrompts: &queuedPrompts,
            eventQueue: TerminalChatEventQueue(),
            transcriptions: TerminalVoiceTranscriptionRegistry()
        )

        #expect(queuedPrompts.isEmpty)
    }

    /// The outbound channel is bound to the chat that asked: a reply must never
    /// be routed to a chat other than the linked one. The causal round-trip
    /// (`TelegramCausalRoundTripTests`) covers the full path for the linked
    /// chat, including generation and delivery through the control service.
    @Test
    func repliesAreOnlyRoutedToTheLinkedChat() throws {
        let terminal = try Self.makeTerminal(linkedChatID: 42)

        #expect(terminal.makeTelegramTurnProgressReporter(
            for: .telegram(chatID: 42)
        ) != nil)
        #expect(terminal.makeTelegramTurnProgressReporter(
            for: .telegram(chatID: 99)
        ) == nil)
    }
}
