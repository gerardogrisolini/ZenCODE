//
//  TerminalTelegramSharedChatRelayTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

// Test-only compatibility surface. Production has no nil-scoped relay API:
// every operation below is translated to an explicit synthetic lease.
extension TerminalTelegramSharedChatRelay {
    init(_ sender: @escaping @Sendable (String, Int64) async -> Int?) {
        self.init(
            validateLease: { _ in true },
            send: { text, chatID, _ in await sender(text, chatID) }
        )
    }

    private static func testLease(roomID: String, chatID: Int64) -> TerminalTelegramRouteLease {
        TerminalTelegramRouteLease(
            key: .init(chatID: chatID, userID: 7, roomID: roomID), generation: 1
        )
    }

    func activate(
        roomID: String, chatID: Int64, repliesEnabled: Bool = true
    ) async {
        await activate(
            roomID: roomID, chatID: chatID,
            lease: Self.testLease(roomID: roomID, chatID: chatID),
            repliesEnabled: repliesEnabled
        )
    }

    func replyTarget(
        forTelegramMessageID messageID: Int, chatID: Int64,
        roomID: String = "terminal-room"
    ) async -> TerminalTelegramSharedChatReplyTarget? {
        await replyTarget(
            forTelegramMessageID: messageID, chatID: chatID,
            lease: Self.testLease(roomID: roomID, chatID: chatID)
        )
    }
}

extension TerminalTelegramTurnProgressReporter {
    /// Unit-test fixture with an explicit lease/fence. Production has no
    /// fence-less initializer.
    init(
        chatID: Int64,
        sendMessage: @escaping @Sendable (String, Int64) async -> Bool,
        sendDraft: (@Sendable (String, Int64, Int) async throws -> Void)? = nil,
        progressCards: TerminalTelegramProgressCardLedger? = nil
    ) {
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: chatID, userID: 7, roomID: "test-room"), generation: 1
        )
        self.init(
            chatID: chatID,
            sendMessage: sendMessage,
            sendDraft: sendDraft,
            progressCards: progressCards,
            wireFence: TerminalTelegramWireFence(lease: lease, lifecycleEpoch: UUID()) { candidate in
                guard candidate == lease else { throw CancellationError() }
            }
        )
    }
}

/// Records the cards a relay delivered and hands back synthetic Telegram
/// receipts, so delivery accounting can be asserted without a transport.
private actor TelegramCardRecorder {
    struct Card: Equatable {
        let text: String
        let chatID: Int64
        let receipt: Int
    }

    private(set) var cards: [Card] = []
    private var nextReceipt = 5_000

    func send(_ text: String, to chatID: Int64) -> Int? {
        nextReceipt += 1
        cards.append(Card(text: text, chatID: chatID, receipt: nextReceipt))
        return nextReceipt
    }
}

@Suite
struct TerminalTelegramSharedChatRelayTests {
    static let roomID = "terminal-room"
    static let chatID: Int64 = 4_242

    static func message(
        kind: AgentSharedChat.ParticipantKind = .agent,
        senderID: String = "agent-1",
        name: String = "Worker",
        text: String = "build is green",
        toOperator: Bool = true,
        recipients explicitRecipients: [String]? = nil,
        roomID: String = roomID
    ) -> AgentSharedChat.Message {
        var recipients = ["coordinator:\(roomID)"]
        if toOperator {
            recipients.append(AgentSharedChat.operatorID(for: roomID))
        }
        if let explicitRecipients {
            recipients = explicitRecipients
        }
        return AgentSharedChat.Message(
            roomID: roomID,
            sender: AgentSharedChat.Participant(id: senderID, name: name, kind: kind),
            recipientIDs: recipients,
            text: text
        )
    }

    private static func makeRelay(
        _ recorder: TelegramCardRecorder
    ) -> TerminalTelegramSharedChatRelay {
        TerminalTelegramSharedChatRelay { text, chatID in
            await recorder.send(text, to: chatID)
        }
    }

    @Test
    func routeGenerationInvalidatesLedgerAndBlocksRetiredDelivery() async {
        let recorder = TelegramCardRecorder()
        let key = TerminalTelegramRouteKey(
            chatID: Self.chatID, userID: 7, topicID: nil, roomID: Self.roomID
        )
        let retired = TerminalTelegramRouteLease(
            key: key, generation: 1, effectiveMessageThreadID: 44
        )
        let current = TerminalTelegramRouteLease(
            key: key, generation: 2, effectiveMessageThreadID: 44
        )
        let relay = TerminalTelegramSharedChatRelay(
            validateLease: { $0.generation == 2 },
            send: { text, chatID, _ in await recorder.send(text, to: chatID) }
        )
        let message = Self.message()
        await relay.activate(
            roomID: Self.roomID, chatID: Self.chatID, lease: retired
        )
        await relay.forward([message], roomID: Self.roomID)
        await relay.waitForPendingCards()
        #expect(await recorder.cards.isEmpty)

        await relay.activate(
            roomID: Self.roomID, chatID: Self.chatID, lease: current
        )
        await relay.forward([message], roomID: Self.roomID)
        await relay.waitForPendingCards()
        #expect(await recorder.cards.count == 1)
    }

    @Test
    func revokedLeaseBlocksReplyRegistrationAndLookup() async {
        let recorder = TelegramCardRecorder()
        let valid = Mutex(true)
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: Self.chatID, userID: 7, roomID: Self.roomID), generation: 1
        )
        let relay = TerminalTelegramSharedChatRelay(
            validateLease: { _ in valid.withLock { $0 } },
            send: { text, chatID, _ in await recorder.send(text, to: chatID) }
        )
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID, lease: lease)
        await relay.forward([Self.message()], roomID: Self.roomID)
        await relay.waitForPendingCards()
        let receipt = await recorder.cards.first?.receipt ?? 0
        valid.withLock { $0 = false }

        #expect(await relay.replyTarget(
            forTelegramMessageID: receipt, chatID: Self.chatID, lease: lease
        ) == nil)
        await relay.registerReplyTarget(
            TerminalTelegramSharedChatReplyTarget(
                roomID: Self.roomID, chatID: Self.chatID,
                sharedChatMessageID: UUID(), senderID: "agent-2",
                senderKind: .agent, senderName: "Agent"
            ),
            forTelegramMessageID: 9_999,
            lease: lease
        )
        #expect(await relay.replyTarget(
            forTelegramMessageID: 9_999, chatID: Self.chatID, lease: lease
        ) == nil)
    }

    /// The observer replays its bounded transcript on reattach, so the same
    /// identity must be delivered at most once for a given room and chat.
    @Test
    func operatorDirectedMessageIsForwardedExactlyOncePerIdentity() async {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        let message = Self.message()
        await relay.forward([message], roomID: Self.roomID)
        await relay.forward([message, message], roomID: Self.roomID)
        await relay.waitForPendingCards()

        let cards = await recorder.cards
        #expect(cards.count == 1)
        #expect(cards.first?.chatID == Self.chatID)
        #expect(cards.first?.text.contains("build is green") == true)
    }

    /// A batch belonging to a room the relay is not bound to is ignored, so a
    /// late observer event cannot leak into the newly linked room.
    @Test
    func batchesFromAnotherRoomAreIgnored() async {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        await relay.forward(
            [Self.message(roomID: "other-room")],
            roomID: "other-room"
        )
        await relay.waitForPendingCards()

        #expect(await recorder.cards.isEmpty)
    }

    /// A route bound to another room of its own cannot bind the relay to the
    /// session's room: the lease is refused, the relay stays unbound, and one
    /// that was bound is released.
    @Test
    func aLeaseOfAnotherSpecificRoomIsRefused() async {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        let foreign = TerminalTelegramRouteLease(
            key: .init(chatID: Self.chatID, userID: 7, roomID: "other-room"), generation: 1
        )

        await relay.activate(roomID: Self.roomID, chatID: Self.chatID, lease: foreign)
        await relay.forward([Self.message()], roomID: Self.roomID)
        await relay.waitForPendingCards()
        #expect(await recorder.cards.isEmpty)

        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)
        await relay.forward([Self.message(text: "bound")], roomID: Self.roomID)
        await relay.waitForPendingCards()
        #expect(await recorder.cards.count == 1)

        await relay.activate(roomID: Self.roomID, chatID: Self.chatID, lease: foreign)
        await relay.forward([Self.message(text: "released")], roomID: Self.roomID)
        await relay.waitForPendingCards()
        #expect(await recorder.cards.count == 1)
    }

    /// An agent sender is answered directly by its stable identifier; the
    /// coordinator is answered on its reserved destination.
    @Test(arguments: [
        (AgentSharedChat.ParticipantKind.agent, AgentSharedChat.Destination.direct(["agent-7"])),
        (.coordinator, .coordinator)
    ])
    func replyTargetResolvesTheOriginalSender(
        kind: AgentSharedChat.ParticipantKind,
        expected: AgentSharedChat.Destination
    ) async {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        await relay.forward([Self.message(kind: kind, senderID: "agent-7")], roomID: Self.roomID)
        await relay.waitForPendingCards()

        let receipt = await recorder.cards.first?.receipt ?? 0
        let target = await relay.replyTarget(
            forTelegramMessageID: receipt,
            chatID: Self.chatID
        )
        #expect(target?.roomID == Self.roomID)
        #expect(target?.senderID == "agent-7")
        #expect(target?.replyDestination == expected)
    }

    /// Receipts are unique per chat, never globally, so a reply quoted in a
    /// different chat must not resolve.
    @Test
    func replyTargetIsScopedToTheLinkedChat() async {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        await relay.forward([Self.message()], roomID: Self.roomID)
        await relay.waitForPendingCards()
        let receipt = await recorder.cards.first?.receipt ?? 0

        #expect(await relay.replyTarget(forTelegramMessageID: receipt, chatID: 99) == nil)
        #expect(await relay.replyTarget(forTelegramMessageID: receipt + 1, chatID: Self.chatID) == nil)
    }

    /// Names and bodies are agent-authored. The card is plain text: control and
    /// bidi scalars are removed and no markup is introduced, so an agent cannot
    /// restyle or hide part of what the operator reads.
    @Test
    func cardTextIsPlainAndNeutralised() {
        let text = TerminalTelegramSharedChatRelay.cardText(
            for: Self.message(
                name: "Wo\u{202E}rker\u{0007}",
                text: "line one\r\nline\u{2028}two"
            )
        )

        #expect(!text.unicodeScalars.contains { $0.value == 0x202E })
        #expect(!text.unicodeScalars.contains { $0.value == 0x0007 })
        #expect(!text.contains("\r"))
        #expect(!text.unicodeScalars.contains { $0.value == 0x2028 })
        #expect(text.contains("Worker → coordinator, operator"))
        #expect(text.contains("line one\nline\ntwo"))
        #expect(text.hasSuffix("Reply to this message to answer Worker."))
    }

    // MARK: - Fence and quiescence

    /// A round trip through another room clears the ledger, so a receipt of the
    /// first binding may not reopen that retired context even though the room and
    /// chat pair matches again.
    @Test
    func receiptOfARetiredLedgerIsNotRestoredByRebindingBack() async {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        await relay.forward([Self.message()], roomID: Self.roomID)
        await relay.waitForPendingCards()
        let receipt = await recorder.cards.first?.receipt ?? 0

        await relay.activate(roomID: "terminal-room-2", chatID: Self.chatID)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        #expect(
            await relay.replyTarget(
                forTelegramMessageID: receipt,
                chatID: Self.chatID
            ) == nil
        )
    }

    // MARK: - Only new messages

    private static func lease(
        roomID: String = roomID,
        chatID: Int64 = chatID,
        generation: UInt64 = 1
    ) -> TerminalTelegramRouteLease {
        TerminalTelegramRouteLease(
            key: .init(chatID: chatID, userID: 7, roomID: roomID), generation: generation
        )
    }

    /// The message bodies of `texts`, in order (a card is route, body and
    /// footer, separated by blank lines).
    private static func bodies(of texts: [String]) -> [String] {
        texts.map { $0.components(separatedBy: "\n\n").dropFirst().first ?? "" }
    }

    /// The messages a room holds when the relay starts forwarding it are
    /// marked with the binding itself, so the observer's replay never turns
    /// them into cards: offered before the binding it is dropped (unbound),
    /// offered after it, once or twice, it is skipped. A newer message is
    /// relayed.
    @Test
    func messagesPresentWhenForwardingStartsNeverBecomeCards() async throws {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        let present = [Self.message(text: "present-1"), Self.message(text: "present-2")]

        await relay.forward(present, roomID: Self.roomID)
        let activation = try #require(await relay.activate(
            roomID: Self.roomID, chatID: Self.chatID, lease: Self.lease(),
            presentMessageIDs: present.map(\.id)
        ))
        #expect(activation.startedForwarding)
        #expect(await relay.forwards(roomID: Self.roomID, chatID: Self.chatID))
        await relay.waitForPendingCards()
        #expect(await recorder.cards.isEmpty)

        await relay.forward(present + [Self.message(text: "fresh")], roomID: Self.roomID)
        await relay.forward(present, roomID: Self.roomID)
        await relay.waitForPendingCards()

        #expect(Self.bodies(of: await recorder.cards.map(\.text)) == ["fresh"])
    }

    /// `/telegram off` → `/telegram on` on the same room and chat: what
    /// arrived while off is not relayed, what arrives afterwards is, and the
    /// card delivered before the off still resolves its reply.
    @Test
    func offThenOnSkipsWhatArrivedWhileOffAndKeepsEarlierReceipts() async throws {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        let delivered = Self.message(text: "delivered")
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID, lease: Self.lease())
        await relay.forward([delivered], roomID: Self.roomID)
        await relay.waitForPendingCards()
        let receipt = try #require(await recorder.cards.first?.receipt)

        await relay.deactivate()
        let whileOff = Self.message(text: "while off")
        let activation = try #require(await relay.activate(
            roomID: Self.roomID, chatID: Self.chatID, lease: Self.lease(),
            presentMessageIDs: [delivered.id, whileOff.id]
        ))
        #expect(activation.startedForwarding)
        await relay.forward(
            [delivered, whileOff, Self.message(text: "after on")], roomID: Self.roomID
        )
        await relay.waitForPendingCards()

        #expect(Self.bodies(of: await recorder.cards.map(\.text)) == ["delivered", "after on"])
        let target = await relay.replyTarget(forTelegramMessageID: receipt, chatID: Self.chatID)
        #expect(target?.sharedChatMessageID == delivered.id)
        #expect(target?.replyDestination == .direct(["agent-1"]))
    }

    // MARK: - Ledger sizing
}
