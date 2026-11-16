//
//  TelegramTUITests+CardReplies.swift
//  ZenCODE
//
//  Tests for the resolution of replies to live-message cards forwarded to
//  Telegram, with the receipt recorder and message fixtures they use.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

extension TelegramTUITests {
    private static var testTelegramLease: TerminalTelegramRouteLease {
        .init(key: .init(chatID: 42, userID: 7, roomID: "terminal-room"), generation: 1)
    }

    // MARK: - Live-message card replies

    /// Cards forwarded by the terminal's own relay must resolve their sender:
    /// an agent is answered on its stable id, the coordinator on its reserved
    /// destination, and the operator's own traffic is carded too — it is
    /// evidence of what the operator said — but never gets a reply target that
    /// would address the Telegram user back to themselves.
    @Test
    func telegramCardRepliesResolveAgentAndCoordinatorSenders() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let receipts = TelegramCardReceiptRecorder()
        // Injected sender: the routing map is exercised end-to-end through the
        // terminal-owned relay without touching the Telegram transport.
        terminal.telegramChannel.sharedChatRelayStorage = TerminalTelegramSharedChatRelay {
            text, chatID in
            await receipts.record(text, chatID: chatID)
        }
        let room = terminal.sessionID
        let lease = try #require(terminal.telegramChannel.activeRouteLease)
        let relay = terminal.telegramChannel.sharedChatRelay
        await relay.activate(roomID: room, chatID: 42)

        await relay.forward(
            [
                Self.sharedChatMessage(
                    roomID: room,
                    kind: .agent,
                    senderID: "agent-7",
                    name: "Worker",
                    text: "need a decision"
                ),
                Self.sharedChatMessage(
                    roomID: room,
                    kind: .coordinator,
                    senderID: "coordinator",
                    name: "Coordinator",
                    text: "which option?"
                ),
                Self.sharedChatMessage(
                    roomID: room,
                    kind: .operator,
                    senderID: "operator",
                    name: "operator",
                    text: "echo of my own line"
                )
            ],
            roomID: room
        )
        await relay.waitForPendingCards()

        let cards = await receipts.cards
        #expect(cards.count == 3)
        let agentReceipt = try #require(
            cards.first { $0.text.contains("need a decision") }?.receipt
        )
        let coordinatorReceipt = try #require(
            cards.first { $0.text.contains("which option?") }?.receipt
        )

        let agentTarget = await relay.replyTarget(
            forTelegramMessageID: agentReceipt,
            chatID: 42,
            lease: lease
        )
        #expect(agentTarget?.replyDestination == .direct(["agent-7"]))
        #expect(agentTarget?.roomID == room)

        let coordinatorTarget = await relay.replyTarget(
            forTelegramMessageID: coordinatorReceipt,
            chatID: 42,
            lease: lease
        )
        #expect(coordinatorTarget?.replyDestination == .coordinator)
        #expect(coordinatorTarget?.roomID == room)

        // The operator card is visible, and deliberately not answerable: routing
        // a Telegram reply back to the operator would loop the human onto
        // themselves. No target is recorded for it at all.
        let operatorReceipt = try #require(
            cards.first { $0.text.contains("echo of my own line") }?.receipt
        )
        let operatorTarget = await relay.replyTarget(
            forTelegramMessageID: operatorReceipt,
            chatID: 42,
            lease: lease
        )
        #expect(operatorTarget == nil)
    }

    /// A quoted message the relay never produced, or one of a retired room, is
    /// not consumed as a live reply: it falls back to the ordinary prompt path
    /// instead of being routed to an arbitrary participant.
    @Test
    func telegramReplyToUnknownOrRetiredCardFallsBackToThePromptPath() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let receipts = TelegramCardReceiptRecorder()
        terminal.telegramChannel.sharedChatRelayStorage = TerminalTelegramSharedChatRelay {
            text, chatID in
            await receipts.record(text, chatID: chatID)
        }
        let relay = terminal.telegramChannel.sharedChatRelay
        // Bound to a room that is not the live session: a card of that binding
        // must never be routed into the current room.
        await relay.activate(roomID: "retired-room", chatID: 42)
        await relay.forward(
            [
                Self.sharedChatMessage(
                    roomID: "retired-room",
                    kind: .agent,
                    senderID: "agent-9",
                    name: "Worker",
                    text: "stale card"
                )
            ],
            roomID: "retired-room"
        )
        await relay.waitForPendingCards()
        let staleReceipt = try #require(await receipts.cards.first?.receipt)

        #expect(
            await terminal.telegramChannel.handleSharedChatReplyIfNeeded(
                "answer",
                message: Self.incomingTelegramMessage(replyToMessageID: staleReceipt),
                lease: Self.testTelegramLease
            ) == false
        )
        #expect(
            await terminal.telegramChannel.handleSharedChatReplyIfNeeded(
                "answer",
                message: Self.incomingTelegramMessage(replyToMessageID: staleReceipt + 1),
                lease: Self.testTelegramLease
            ) == false
        )
        #expect(
            await terminal.telegramChannel.handleSharedChatReplyIfNeeded(
                "answer",
                message: Self.incomingTelegramMessage(replyToMessageID: nil),
                lease: Self.testTelegramLease
            ) == false
        )
    }

    /// Quoting a card must not change what an explicitly addressed line means:
    /// remote commands, slash commands and resolving mentions keep precedence,
    /// while ordinary text — including an `@` that resolves to nothing — stays
    /// replyable.
    @Test
    func telegramReplyRoutingYieldsToCommandsAndResolvingMentions() async throws {
        let terminal = try await Self.activeTelegramTerminal()

        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "/help"))
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "/start 233B0EC4"))
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "/plan route it"))
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "@coordinator status"))
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "@all status"))
        // A recognised mention without text keeps its own diagnostic.
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "@coordinator"))
        // Not mentions, so a reply keeps its meaning.
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "@nobody hi") == false)
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "yes, ship it") == false)
        #expect(
            await terminal.telegramChannel.replyRoutingHasPrecedence(
                over: "answer with an email like a@b.com"
            ) == false
        )
        // A plain-word command alias is an answer to the quoted card, as in
        // the TUI; only its slash form keeps command precedence.
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "diff") == false)
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "status") == false)
        #expect(await terminal.telegramChannel.replyRoutingHasPrecedence(over: "/diff"))
    }

    private static func sharedChatMessage(
        roomID: String,
        kind: AgentSharedChat.ParticipantKind,
        senderID: String,
        name: String,
        text: String
    ) -> AgentSharedChat.Message {
        AgentSharedChat.Message(
            roomID: roomID,
            sender: AgentSharedChat.Participant(id: senderID, name: name, kind: kind),
            recipientIDs: [AgentSharedChat.operatorID(for: roomID)],
            text: text
        )
    }

    private static func incomingTelegramMessage(
        replyToMessageID: Int?
    ) -> TerminalTelegramIncomingMessage {
        TerminalTelegramIncomingMessage(
            chatID: 42,
            userID: 7,
            text: "answer",
            voice: nil,
            messageID: 1,
            chatTitle: nil,
            username: nil,
            replyToMessageID: replyToMessageID
        )
    }
}

/// Hands the relay synthetic Telegram receipts so card routing can be asserted
/// without a transport.
private actor TelegramCardReceiptRecorder {
    struct Card: Equatable {
        let text: String
        let chatID: Int64
        let receipt: Int
    }

    private(set) var cards: [Card] = []
    private var nextReceipt = 9_000

    func record(_ text: String, chatID: Int64) -> Int {
        nextReceipt += 1
        cards.append(Card(text: text, chatID: chatID, receipt: nextReceipt))
        return nextReceipt
    }
}
