//
//  TerminalTelegramSharedChatRelayTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

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
    private var failuresRemaining = 0

    func failNextDeliveries(_ count: Int) {
        failuresRemaining = count
    }

    func send(_ text: String, to chatID: Int64) -> Int? {
        guard failuresRemaining == 0 else {
            failuresRemaining -= 1
            return nil
        }
        nextReceipt += 1
        cards.append(Card(text: text, chatID: chatID, receipt: nextReceipt))
        return nextReceipt
    }
}

/// Records cards behind a gate the test opens explicitly, so the window between
/// "a card was handed to the transport" and "the transport answered" is a state
/// the test controls instead of a race it hopes to hit.
private actor GatedCardRecorder {
    struct Card: Equatable {
        let text: String
        let chatID: Int64
        let receipt: Int
    }

    private(set) var cards: [Card] = []
    private(set) var inFlight = 0
    private var nextReceipt = 7_000
    private var isOpen = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func send(_ text: String, to chatID: Int64) async -> Int? {
        inFlight += 1
        let started = startWaiters
        startWaiters.removeAll()
        for waiter in started {
            waiter.resume()
        }
        if !isOpen {
            await withCheckedContinuation { continuation in
                openWaiters.append(continuation)
            }
        }
        inFlight -= 1
        nextReceipt += 1
        cards.append(Card(text: text, chatID: chatID, receipt: nextReceipt))
        return nextReceipt
    }

    /// Returns once at least one send is suspended inside the gate.
    func waitUntilSendStarted() async {
        guard inFlight == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// One-shot completion flag, so a test can assert that an operation is *still*
/// blocked without sleeping.
private actor CompletionFlag {
    private(set) var isSet = false

    func set() {
        isSet = true
    }
}

@Suite
struct TerminalTelegramSharedChatRelayTests {
    private static let roomID = "terminal-room"
    private static let chatID: Int64 = 4_242

    private static func message(
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

    /// There is no recipient filter: the Telegram relay shows every message
    /// observed for its active room, regardless of sender or destination shape.
    @Test
    func everySharedChatTrafficShapeIsForwardedWithReadableRoute() async {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)
        let operatorID = AgentSharedChat.operatorID(for: Self.roomID)
        let coordinatorID = AgentSharedChat.coordinatorID(for: Self.roomID)

        await relay.forward(
            [
                Self.message(senderID: "agent-a", name: "Alpha", text: "agent to coordinator", toOperator: false),
                Self.message(kind: .coordinator, senderID: coordinatorID, name: "Coordinator", text: "coordinator to agent", recipients: ["agent-a"]),
                Self.message(senderID: "agent-a", name: "Alpha", text: "agent to agent", recipients: ["agent-b"]),
                Self.message(senderID: "agent-a", name: "Alpha", text: "direct multiple", recipients: ["agent-b", "agent-c"]),
                Self.message(kind: .operator, senderID: operatorID, name: "operator", text: "operator broadcast", recipients: [coordinatorID, "agent-a", "agent-b"]),
                Self.message(senderID: "agent-a", name: "Alpha", text: "broadcast", recipients: [operatorID, coordinatorID, "agent-b"])
            ],
            roomID: Self.roomID,
            participants: [
                .init(id: "agent-a", name: "Alpha", kind: .agent),
                .init(id: "agent-b", name: "Beta", kind: .agent),
                .init(id: "agent-c", name: "Gamma", kind: .agent)
            ]
        )
        await relay.waitForPendingCards()

        let cards = await recorder.cards
        #expect(cards.count == 6)
        #expect(cards[0].text.contains("Alpha → coordinator"))
        #expect(cards[1].text.contains("Coordinator → Alpha"))
        #expect(cards[2].text.contains("Alpha → Beta"))
        #expect(cards[3].text.contains("Alpha → Beta, Gamma"))
        #expect(cards[4].text.contains("operator → coordinator, Alpha, Beta"))
        #expect(cards[5].text.contains("Alpha → operator, coordinator, Beta"))
    }

    @Test
    func routeUsesStableIDForUnknownRecipient() {
        let text = TerminalTelegramSharedChatRelay.cardText(
            for: Self.message(recipients: ["retired-agent-id"])
        )
        #expect(text.contains("Worker → retired-agent-id"))
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

    @Test
    func nothingIsForwardedWhileTheRelayIsInactive() async {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)

        await relay.forward([Self.message()], roomID: Self.roomID)
        await relay.waitForPendingCards()

        #expect(await recorder.cards.isEmpty)
    }

    /// The route every session shares serves the room of any session: the
    /// relay bound through it forwards the room's batches, which carry the
    /// room of the session and never the route's own.
    @Test
    func theSharedRouteServesTheRoomOfTheSession() async {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        let shared = TerminalTelegramRouteLease(
            key: .init(chatID: Self.chatID, userID: 7, roomID: TerminalTelegramRouteKey.sharedRoomID),
            generation: 1
        )
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID, lease: shared)

        await relay.forward([Self.message()], roomID: Self.roomID)
        await relay.forward(
            [Self.message(roomID: TerminalTelegramRouteKey.sharedRoomID)],
            roomID: TerminalTelegramRouteKey.sharedRoomID
        )
        await relay.waitForPendingCards()

        #expect(await recorder.cards.count == 1)
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

    /// The rule behind the binding: a route serves its own room, and the
    /// shared one serves every room.
    @Test
    func aRouteAdmitsItsOwnRoomAndTheSharedRouteAdmitsEveryRoom() {
        func key(_ roomID: String) -> TerminalTelegramRouteKey {
            TerminalTelegramRouteKey(chatID: Self.chatID, userID: 7, roomID: roomID)
        }

        #expect(TerminalTelegramRouteKey.sharedRoomID == "default")
        #expect(key(Self.roomID).admits(roomID: Self.roomID))
        #expect(!key(Self.roomID).admits(roomID: "other-room"))
        #expect(key(TerminalTelegramRouteKey.sharedRoomID).admits(roomID: Self.roomID))
        #expect(key(TerminalTelegramRouteKey.sharedRoomID).admits(roomID: TerminalTelegramRouteKey.sharedRoomID))
        #expect(!key(Self.roomID).admits(roomID: TerminalTelegramRouteKey.sharedRoomID))
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

    /// `/telegram off` → `/telegram on` on the same room and chat must not
    /// resend cards the chat already received.
    @Test
    func reactivationOnTheSameBindingKeepsTheDeliveryLedger() async {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        let message = Self.message()
        await relay.forward([message], roomID: Self.roomID)
        await relay.waitForPendingCards()

        await relay.deactivate()
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)
        await relay.forward([message], roomID: Self.roomID)
        await relay.waitForPendingCards()

        #expect(await recorder.cards.count == 1)
    }

    /// A room swap (`/new`, `/resume`) retires the receipt map: a reply to a
    /// card of the retired room must never be routed into the live one.
    @Test
    func rebindingToAnotherRoomClearsTheReceiptMap() async {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        await relay.forward([Self.message()], roomID: Self.roomID)
        await relay.waitForPendingCards()
        let receipt = await recorder.cards.first?.receipt ?? 0

        await relay.activate(roomID: "terminal-room-2", chatID: Self.chatID)

        #expect(await relay.replyTarget(forTelegramMessageID: receipt, chatID: Self.chatID) == nil)
    }

    /// A card whose delivery failed is never retried (at-most-once) and is not
    /// answerable, because no receipt was observed.
    @Test
    func failedDeliveryIsNotRetriedAndRecordsNoReplyTarget() async {
        let recorder = TelegramCardRecorder()
        await recorder.failNextDeliveries(1)
        let relay = Self.makeRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        let message = Self.message()
        await relay.forward([message], roomID: Self.roomID)
        await relay.waitForPendingCards()
        await relay.forward([message], roomID: Self.roomID)
        await relay.waitForPendingCards()

        #expect(await recorder.cards.isEmpty)
    }

    /// Shutdown quiesces the worker so no card is delivered after teardown.
    @Test
    func shutdownStopsForwarding() async {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)
        await relay.shutdown()

        await relay.forward([Self.message()], roomID: Self.roomID)
        await relay.waitForPendingCards()

        #expect(await recorder.cards.isEmpty)
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

    @Test
    func operatorCardIsVisibleButDoesNotCreateAReplyTarget() async {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)
        await relay.forward([
            Self.message(
                kind: .operator,
                senderID: AgentSharedChat.operatorID(for: Self.roomID),
                name: "operator",
                recipients: [AgentSharedChat.coordinatorID(for: Self.roomID)]
            )
        ], roomID: Self.roomID)
        await relay.waitForPendingCards()

        let card = await recorder.cards.first
        #expect(card?.text.contains("operator → coordinator") == true)
        // No target at all, not merely one without a destination: callers that
        // only ask "is this a reply to a card?" — the voice-note guard — must see
        // an operator card as ordinary traffic.
        let target = await relay.replyTarget(
            forTelegramMessageID: card?.receipt ?? 0,
            chatID: Self.chatID
        )
        #expect(target == nil)
    }

    @Test
    func operatorSenderHasNoReplyDestination() {
        let target = TerminalTelegramSharedChatReplyTarget(
            roomID: Self.roomID,
            chatID: Self.chatID,
            sharedChatMessageID: UUID(),
            senderID: "operator",
            senderKind: .operator,
            senderName: "operator"
        )
        #expect(target.replyDestination == nil)
    }

    /// A surface that forwards cards but never reads Telegram ingress must not
    /// invite a reply it would silently drop.
    @Test
    func cardWithoutIngressDoesNotInviteAReply() {
        let text = TerminalTelegramSharedChatRelay.cardText(
            for: Self.message(),
            repliesEnabled: false
        )

        #expect(!text.contains("Reply to this message"))
        #expect(text.contains("answer from the terminal"))
    }

    // MARK: - Fence and quiescence

    private static func makeGatedRelay(
        _ recorder: GatedCardRecorder
    ) -> TerminalTelegramSharedChatRelay {
        TerminalTelegramSharedChatRelay { text, chatID in
            await recorder.send(text, to: chatID)
        }
    }

    /// The blocker this fence exists for: once a rebind to room B has returned,
    /// no card of room A may still reach the chat. Dequeue and delivery are
    /// separate actor entries, so a card already popped for the retired room must
    /// be stopped by the pre-send re-check, and the rebind must not return while
    /// a send of the retired room is still in flight.
    @Test
    func rebindFencesCardsOfTheRetiredRoom() async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        await relay.forward(
            [Self.message(text: "first"), Self.message(text: "second")],
            roomID: Self.roomID
        )
        await recorder.waitUntilSendStarted()

        let rebindCompleted = CompletionFlag()
        let rebind = Task {
            await relay.activate(roomID: "terminal-room-2", chatID: Self.chatID)
            await rebindCompleted.set()
        }
        // Deterministic handshake: the rebind is observed *inside* the fence,
        // waiting on the still-gated card of room A. Returning from there would
        // mean returning while a card of the retired room is in flight.
        await relay.waitUntilFenceIsWaiting()
        #expect(await rebindCompleted.isSet == false)
        #expect(await recorder.inFlight == 1)

        await recorder.open()
        await rebind.value

        // The rebind is complete: nothing of room A may be sent from here on.
        #expect(await recorder.inFlight == 0)
        await relay.waitForPendingCards()
        let cards = await recorder.cards
        #expect(cards.count == 1)
        #expect(cards.first?.text.contains("first") == true)
    }

    /// Re-activating the *same* room and chat is idempotent: it is not a rebind,
    /// so it must neither fence nor drop the queue nor invalidate receipts of
    /// cards that are still in flight.
    @Test
    func reactivatingTheSameContextPreservesQueueAndReceipts() async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        await relay.forward(
            [Self.message(text: "first"), Self.message(text: "second")],
            roomID: Self.roomID
        )
        await recorder.waitUntilSendStarted()

        // Same pair: returns without waiting for the in-flight send. Awaiting it
        // while the gate is still closed is the proof — a fencing implementation
        // could not complete here — and the card is still in flight afterwards.
        let reattach = Task {
            await relay.activate(roomID: Self.roomID, chatID: Self.chatID)
        }
        await reattach.value
        #expect(await recorder.inFlight == 1)
        await recorder.open()
        await relay.waitForPendingCards()

        let cards = await recorder.cards
        #expect(cards.count == 2)
        for card in cards {
            let target = await relay.replyTarget(
                forTelegramMessageID: card.receipt,
                chatID: Self.chatID
            )
            #expect(target?.roomID == Self.roomID)
        }
    }

    /// Cards keep the order of the observer batch: the outbound worker is a FIFO,
    /// so a conversation is not reordered on its way to Telegram.
    @Test
    func queuedCardsAreDeliveredInOrder() async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        await relay.forward(
            (1...5).map { Self.message(text: "card-\($0)") },
            roomID: Self.roomID
        )
        await recorder.open()
        await relay.waitForPendingCards()

        let texts = await recorder.cards.map(\.text)
        #expect(texts.count == 5)
        for (index, text) in texts.enumerated() {
            #expect(text.contains("card-\(index + 1)"))
        }
    }

    /// A receipt that arrives after the binding was retired is not answerable
    /// while nothing is bound: a reply then has no live room to be routed to.
    @Test
    func receiptArrivingAfterDeactivationIsNotAnswerableWhileUnbound() async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        await relay.forward([Self.message()], roomID: Self.roomID)
        await recorder.waitUntilSendStarted()

        let stop = Task { await relay.deactivate() }
        await relay.waitUntilFenceIsWaiting()
        await recorder.open()
        await stop.value

        let receipt = await recorder.cards.first?.receipt ?? 0
        #expect(
            await relay.replyTarget(
                forTelegramMessageID: receipt,
                chatID: Self.chatID
            ) == nil
        )
    }

    /// A send that started before `/telegram off` and answered during it must
    /// stay recoverable: the card really is in the chat, so re-enabling the same
    /// room and chat installs its mapping instead of losing the answer.
    @Test
    func receiptArrivingWhileUnboundIsRecoveredByReactivatingTheSamePair() async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        await relay.forward([Self.message()], roomID: Self.roomID)
        await recorder.waitUntilSendStarted()

        // `/telegram off` while the send is in flight: the teardown is observed
        // inside the fence before the transport answers.
        let stop = Task { await relay.deactivate() }
        await relay.waitUntilFenceIsWaiting()
        await recorder.open()
        await stop.value

        let receipt = await recorder.cards.first?.receipt ?? 0
        // While unbound nothing is answerable.
        #expect(
            await relay.replyTarget(
                forTelegramMessageID: receipt,
                chatID: Self.chatID
            ) == nil
        )

        // `/telegram on` on the same pair: the parked receipt becomes routable.
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)
        let target = await relay.replyTarget(
            forTelegramMessageID: receipt,
            chatID: Self.chatID
        )
        #expect(target?.roomID == Self.roomID)
        #expect(target?.replyDestination == .direct(["agent-1"]))
    }

    /// The same in-flight receipt must *not* be reopened when the binding really
    /// changed and later came back: that round trip retired the ledger, so the
    /// card belongs to a context nothing may address again.
    @Test
    func receiptArrivingWhileUnboundIsDiscardedAfterARealRoomChange() async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        await relay.forward([Self.message()], roomID: Self.roomID)
        await recorder.waitUntilSendStarted()

        let stop = Task { await relay.deactivate() }
        await relay.waitUntilFenceIsWaiting()
        await recorder.open()
        await stop.value
        let receipt = await recorder.cards.first?.receipt ?? 0

        // A → B → A: the detour clears the ledger and the parked receipt with it.
        await relay.activate(roomID: "terminal-room-2", chatID: Self.chatID)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        #expect(
            await relay.replyTarget(
                forTelegramMessageID: receipt,
                chatID: Self.chatID
            ) == nil
        )
    }

    /// A parked receipt belongs to one pair only: linking another chat retires it
    /// even though the room is unchanged.
    @Test
    func receiptArrivingWhileUnboundIsDiscardedAfterAChatChange() async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        await relay.forward([Self.message()], roomID: Self.roomID)
        await recorder.waitUntilSendStarted()

        let stop = Task { await relay.deactivate() }
        await relay.waitUntilFenceIsWaiting()
        await recorder.open()
        await stop.value
        let receipt = await recorder.cards.first?.receipt ?? 0

        await relay.activate(roomID: Self.roomID, chatID: 9_999)

        #expect(
            await relay.replyTarget(forTelegramMessageID: receipt, chatID: 9_999) == nil
        )
        #expect(
            await relay.replyTarget(
                forTelegramMessageID: receipt,
                chatID: Self.chatID
            ) == nil
        )
    }

    /// Teardown discards parked receipts: nothing may become answerable after the
    /// relay was shut down.
    @Test
    func shutdownDiscardsParkedReceipts() async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        await relay.forward([Self.message()], roomID: Self.roomID)
        await recorder.waitUntilSendStarted()

        let stop = Task { await relay.shutdown() }
        await relay.waitUntilFenceIsWaiting()
        await recorder.open()
        await stop.value
        let receipt = await recorder.cards.first?.receipt ?? 0

        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)
        #expect(
            await relay.replyTarget(
                forTelegramMessageID: receipt,
                chatID: Self.chatID
            ) == nil
        )
    }

    /// `/telegram off` → `/telegram on` on the same pair keeps the receipts of
    /// cards already delivered there: those Telegram messages still exist in that
    /// chat, and the ledger they belong to was never cleared.
    @Test
    func offThenOnOnTheSameBindingStillAcceptsEarlierReceipts() async {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        await relay.forward([Self.message()], roomID: Self.roomID)
        await relay.waitForPendingCards()
        let receipt = await recorder.cards.first?.receipt ?? 0

        await relay.deactivate()
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        let target = await relay.replyTarget(
            forTelegramMessageID: receipt,
            chatID: Self.chatID
        )
        #expect(target?.roomID == Self.roomID)
        #expect(target?.replyDestination == .direct(["agent-1"]))
    }

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

    // MARK: - Lossless backpressure

    /// Batch larger than the bounded queue, delivered through a gate the test
    /// opens itself.
    private static let backpressureBatchSize =
        TerminalTelegramSharedChatRelay.maximumQueuedCards + 128

    private static func orderedBatch(
        count: Int = backpressureBatchSize
    ) -> [AgentSharedChat.Message] {
        (0..<count).map { message(text: "card-\(String(format: "%04d", $0))") }
    }

    private static func expectedTexts(
        for messages: [AgentSharedChat.Message]
    ) -> [String] {
        messages.map(\.text)
    }

    /// Delivered card texts reduced to the payload line the batch encodes, so
    /// order can be compared against the batch itself.
    private static func payloads(of cards: [GatedCardRecorder.Card]) -> [String] {
        cards.compactMap { card in
            card.text
                .split(separator: "\n")
                .map(String.init)
                .first { $0.hasPrefix("card-") }
        }
    }

    /// The blocker this rewrite exists for: a batch far larger than the bounded
    /// queue must be forwarded **completely** and in order. The producer is
    /// suspended on backpressure — observed, not assumed — while the transport
    /// gate is shut, and every card still arrives once the gate opens.
    @Test
    func batchLargerThanTheQueueIsForwardedCompletelyAndInOrder() async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        let batch = Self.orderedBatch()
        #expect(batch.count >= 512)
        let producer = Task { await relay.forward(batch, roomID: Self.roomID) }

        // The queue is bounded, so a batch of this size cannot be admitted in
        // one go: the producer is parked instead of losing its tail.
        await relay.waitUntilProducerIsBlocked()
        #expect(await recorder.cards.isEmpty)

        await recorder.open()
        await producer.value
        await relay.waitForPendingCards()

        let payloads = Self.payloads(of: await recorder.cards)
        #expect(payloads == Self.expectedTexts(for: batch))
    }

    /// Cancelling a blocked producer must not consume the identities it never
    /// admitted: the ledger is written together with the admission, so replaying
    /// the same batch delivers exactly the missing tail, once, in order.
    @Test
    func cancellingABlockedProducerLeavesTheUnadmittedTailReplayable() async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        let batch = Self.orderedBatch()
        let producer = Task { await relay.forward(batch, roomID: Self.roomID) }
        await relay.waitUntilProducerIsBlocked()

        producer.cancel()
        await producer.value
        await recorder.open()
        await relay.waitForPendingCards()

        let firstPass = Self.payloads(of: await recorder.cards)
        #expect(firstPass.count < batch.count)
        #expect(firstPass == Array(Self.expectedTexts(for: batch).prefix(firstPass.count)))

        // Replay of the very same batch: already delivered identities are
        // skipped, the cancelled tail is delivered.
        await relay.forward(batch, roomID: Self.roomID)
        await relay.waitForPendingCards()

        let payloads = Self.payloads(of: await recorder.cards)
        #expect(payloads == Self.expectedTexts(for: batch))
    }

    /// A rebind while a producer is parked on backpressure must wake it with a
    /// refusal instead of leaving it waiting for a queue that will never drain
    /// for the retired binding.
    @Test
    func rebindWakesABlockedProducerWithoutDeadlock() async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        let batch = Self.orderedBatch()
        let producer = Task { await relay.forward(batch, roomID: Self.roomID) }
        await relay.waitUntilProducerIsBlocked()
        // A card is inside the gate, so the fence below really has something to
        // wait out instead of returning before the producer is woken.
        await recorder.waitUntilSendStarted()

        let rebind = Task {
            await relay.activate(roomID: "terminal-room-2", chatID: Self.chatID)
        }
        // The fence waits out the card that is still inside the gate; opening it
        // is what lets the rebind finish. The producer must not outlive it.
        await relay.waitUntilFenceIsWaiting()
        await recorder.open()
        await rebind.value
        await producer.value

        // Whatever reached the chat belongs to room A and kept its order; the
        // retired binding admits nothing after the rebind returned.
        let payloads = Self.payloads(of: await recorder.cards)
        #expect(payloads == Array(Self.expectedTexts(for: batch).prefix(payloads.count)))

        let stillBlocked = Task { await relay.forward(batch, roomID: Self.roomID) }
        await stillBlocked.value
    }

    /// Teardown has the same duty: a producer parked on capacity is refused, so
    /// shutdown cannot hang behind it.
    @Test
    func shutdownWakesABlockedProducerWithoutDeadlock() async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        let batch = Self.orderedBatch()
        let producer = Task { await relay.forward(batch, roomID: Self.roomID) }
        await relay.waitUntilProducerIsBlocked()
        await recorder.waitUntilSendStarted()

        let teardown = Task { await relay.shutdown() }
        await relay.waitUntilFenceIsWaiting()
        await recorder.open()
        await teardown.value
        await producer.value

        // Nothing may be admitted after teardown, and asking for it must return.
        await relay.forward(batch, roomID: Self.roomID)
        let deliveredAfterShutdown = Self.payloads(of: await recorder.cards).count
        await relay.waitForPendingCards()
        #expect(Self.payloads(of: await recorder.cards).count == deliveredAfterShutdown)
    }

    // MARK: - Global FIFO across concurrent producers

    /// Two batches whose cards are distinguishable, so the *global* order can be
    /// asserted instead of each producer's own order.
    private static func labelledBatch(
        prefix: String,
        count: Int
    ) -> [AgentSharedChat.Message] {
        (0..<count).map { message(text: "\(prefix)-\(String(format: "%04d", $0))") }
    }

    private static func labelledPayloads(of cards: [GatedCardRecorder.Card]) -> [String] {
        cards.compactMap { card in
            card.text
                .split(separator: "\n")
                .map(String.init)
                .first { $0.hasPrefix("producer-a-") || $0.hasPrefix("producer-b-") }
        }
    }

    /// The exact sequence the relay must produce once two producers are parked.
    ///
    /// Capacity is granted to one waiter at a time, in arrival order, and the
    /// winner must commit its card before the next grant. So after the prefix
    /// producer A admitted alone, the two alternate strictly — A first, because
    /// it parked first — and whichever batch outlives the other takes every
    /// remaining grant.
    private static func expectedGlobalOrder(
        admittedPrefix: Int,
        first: [String],
        second: [String]
    ) -> [String] {
        var expected = Array(first.prefix(admittedPrefix))
        var firstIndex = admittedPrefix
        var secondIndex = 0
        var takeFirst = true
        while firstIndex < first.count || secondIndex < second.count {
            if takeFirst, firstIndex < first.count {
                expected.append(first[firstIndex])
                firstIndex += 1
                takeFirst = false
            } else if secondIndex < second.count {
                expected.append(second[secondIndex])
                secondIndex += 1
                takeFirst = true
            } else {
                expected.append(first[firstIndex])
                firstIndex += 1
                takeFirst = false
            }
        }
        return expected
    }

    /// Two concurrent producers share **one** queue order, and it is the order in
    /// which they asked for capacity.
    ///
    /// The state is pinned before anything is asserted: the transport gate holds
    /// exactly one card, so no slot can free, and both producers are observed
    /// parked. From there the admitted prefix is exact and the sequence that
    /// follows is fully determined — which is what makes an exact comparison
    /// legitimate rather than a scheduling coincidence. Before the reservation
    /// was serialised, a producer entering the window between a grant and its
    /// enqueue took the fast path and overtook the producer that asked first.
    @Test
    func concurrentProducersShareOneGlobalFIFOOrder() async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        let batchA = Self.labelledBatch(
            prefix: "producer-a",
            count: Self.backpressureBatchSize
        )
        let batchB = Self.labelledBatch(prefix: "producer-b", count: 6)

        let producerA = Task { await relay.forward(batchA, roomID: Self.roomID) }
        // The worker holds one card inside the closed gate and A is parked:
        // nothing can free a slot, so the admitted prefix is now stable.
        await recorder.waitUntilSendStarted()
        await relay.waitUntilProducerIsBlocked()
        let admittedPrefix = await relay.ledgerEntryCount
        #expect(admittedPrefix > 0)

        let producerB = Task { await relay.forward(batchB, roomID: Self.roomID) }
        await relay.waitUntilProducersAreBlocked(count: 2)
        // B asked second and must stay behind A: nothing of B was admitted.
        #expect(await relay.ledgerEntryCount == admittedPrefix)

        await recorder.open()
        await producerA.value
        await producerB.value
        await relay.waitForPendingCards()

        #expect(
            Self.labelledPayloads(of: await recorder.cards) == Self.expectedGlobalOrder(
                admittedPrefix: admittedPrefix,
                first: batchA.map(\.text),
                second: batchB.map(\.text)
            )
        )
        // The order above is a consequence of this invariant: the reserve →
        // enqueue section is serialised, so at no point did two producers hold a
        // slot that neither had committed.
        let peakReservations = await relay.peakUncommittedReservations
        #expect(peakReservations == 1)
    }

    /// Cancelling a producer that is **provably** parked consumes nothing beyond
    /// the prefix it had already admitted: the delivered cards are exactly that
    /// prefix, and replaying the same batch delivers the remainder once, in
    /// order, with no duplicate and no gap.
    @Test
    func cancellingAProvablyParkedProducerReplaysTheExactRemainder() async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        let batch = Self.labelledBatch(
            prefix: "producer-a",
            count: Self.backpressureBatchSize
        )
        let producer = Task { await relay.forward(batch, roomID: Self.roomID) }
        await recorder.waitUntilSendStarted()
        await relay.waitUntilProducerIsBlocked()
        // The gate is shut, so no grant can happen: the producer is cancelled
        // while it demonstrably holds no reservation.
        let admitted = await relay.ledgerEntryCount
        #expect(admitted < batch.count)

        producer.cancel()
        await producer.value
        await recorder.open()
        await relay.waitForPendingCards()

        let texts = batch.map(\.text)
        #expect(
            Self.labelledPayloads(of: await recorder.cards) == Array(texts.prefix(admitted))
        )

        await relay.forward(batch, roomID: Self.roomID)
        await relay.waitForPendingCards()
        #expect(Self.labelledPayloads(of: await recorder.cards) == texts)
    }

    enum LifecycleTransition: String, CaseIterable, Sendable {
        case rebind
        case deactivate
        case shutdown
    }

    /// Every lifecycle transition must wake **all** parked producers, not just the
    /// head of the queue: a refusal pass that stopped at the first waiter — or one
    /// suppressed because a reservation was outstanding — would leave the rest
    /// waiting for a queue that will never drain for them.
    @Test(arguments: LifecycleTransition.allCases)
    func lifecycleTransitionsWakeEveryBlockedProducer(
        _ transition: LifecycleTransition
    ) async {
        let recorder = GatedCardRecorder()
        let relay = Self.makeGatedRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        let batchA = Self.labelledBatch(
            prefix: "producer-a",
            count: Self.backpressureBatchSize
        )
        let batchB = Self.labelledBatch(prefix: "producer-b", count: 6)
        let producerA = Task { await relay.forward(batchA, roomID: Self.roomID) }
        await recorder.waitUntilSendStarted()
        await relay.waitUntilProducerIsBlocked()
        let producerB = Task { await relay.forward(batchB, roomID: Self.roomID) }
        await relay.waitUntilProducersAreBlocked(count: 2)

        let lifecycle = Task {
            switch transition {
            case .rebind:
                await relay.activate(roomID: "terminal-room-2", chatID: Self.chatID)
            case .deactivate:
                await relay.deactivate()
            case .shutdown:
                await relay.shutdown()
            }
        }
        // The fence waits out the card still inside the gate; opening it is what
        // lets the transition finish. Neither producer may outlive it.
        await relay.waitUntilFenceIsWaiting()
        await recorder.open()
        await lifecycle.value
        await producerA.value
        await producerB.value

        // Whatever reached the chat belongs to the retired binding and kept its
        // order: no card of the second producer overtook the first.
        let payloads = Self.labelledPayloads(of: await recorder.cards)
        #expect(payloads == Array(batchA.map(\.text).prefix(payloads.count)))
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

    /// `markPresent(_:roomID:generation:)` marks for the live binding without
    /// queuing a card: a message marked, then offered by the replay, is not a
    /// card, and a message offered with it is.
    @Test
    func aMarkedMessageOfferedByTheReplayIsNotACard() async throws {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        let activation = try #require(await relay.activate(
            roomID: Self.roomID, chatID: Self.chatID, lease: Self.lease()
        ))
        let present = Self.message(text: "present")

        #expect(await relay.markPresent(
            [present.id], roomID: Self.roomID, generation: activation.generation
        ))
        await relay.waitForPendingCards()
        #expect(await recorder.cards.isEmpty)

        await relay.forward([present, Self.message(text: "fresh")], roomID: Self.roomID)
        await relay.waitForPendingCards()

        #expect(Self.bodies(of: await recorder.cards.map(\.text)) == ["fresh"])
    }

    /// Marks are written only for the live binding: unbound, for a retired
    /// generation (even of the same room and chat, after `/telegram off` →
    /// `/telegram on`), for another room, or after teardown, the call is
    /// refused and marks nothing, so those messages are still relayed.
    @Test
    func markPresentIsRefusedOutsideTheLiveBinding() async throws {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        let stale = Self.message(text: "stale generation")
        let foreign = Self.message(text: "another room")

        #expect(await relay.markPresent([stale.id], roomID: Self.roomID, generation: 0) == false)
        let first = try #require(await relay.activate(
            roomID: Self.roomID, chatID: Self.chatID, lease: Self.lease()
        ))
        await relay.deactivate()
        #expect(await relay.markPresent(
            [stale.id], roomID: Self.roomID, generation: first.generation
        ) == false)

        // Bound again to the same pair: the ledger is kept, the generation is new.
        let second = try #require(await relay.activate(
            roomID: Self.roomID, chatID: Self.chatID, lease: Self.lease()
        ))
        #expect(second.generation != first.generation)
        #expect(await relay.markPresent(
            [stale.id], roomID: Self.roomID, generation: first.generation
        ) == false)
        #expect(await relay.markPresent(
            [foreign.id], roomID: "terminal-room-2", generation: second.generation
        ) == false)

        await relay.forward([stale, foreign], roomID: Self.roomID)
        await relay.waitForPendingCards()
        #expect(Self.bodies(of: await recorder.cards.map(\.text)) == [
            "stale generation", "another room",
        ])

        await relay.shutdown()
        #expect(await relay.markPresent(
            [UUID()], roomID: Self.roomID, generation: second.generation
        ) == false)
    }

    /// Marks share the ledger's bound. Of a list longer than the ledger only
    /// the newest `maximumLedgerEntries` are kept; an identity already in the
    /// ledger moves to the tail with the other marks, so the trim evicts only
    /// entries the room no longer holds; and a card already queued is still
    /// delivered, once, even when the marks evict its own entry.
    @Test
    func presentMarksRespectTheLedgerBound() async throws {
        let bound = TerminalTelegramSharedChatRelay.maximumLedgerEntries
        #expect(bound >= AgentSharedChat.maximumRetainedMessagesPerRoom)

        // A list longer than the bound keeps its newest `bound` marks.
        do {
            let recorder = TelegramCardRecorder()
            let relay = Self.makeRelay(recorder)
            let marked = Self.labelledBatch(prefix: "present", count: bound + 2)
            let activation = try #require(await relay.activate(
                roomID: Self.roomID, chatID: Self.chatID, lease: Self.lease(),
                presentMessageIDs: marked.map(\.id)
            ))
            #expect(activation.startedForwarding)
            #expect(await relay.ledgerEntryCount == bound)

            await relay.forward([marked[marked.count - 1]], roomID: Self.roomID)
            await relay.forward([marked[0]], roomID: Self.roomID)
            await relay.waitForPendingCards()
            #expect(Self.bodies(of: await recorder.cards.map(\.text)) == [marked[0].text])
        }

        // A delivered identity the room still holds survives the trim.
        do {
            let recorder = TelegramCardRecorder()
            let relay = Self.makeRelay(recorder)
            let activation = try #require(await relay.activate(
                roomID: Self.roomID, chatID: Self.chatID, lease: Self.lease()
            ))
            let delivered = Self.labelledBatch(prefix: "delivered", count: 3)
            await relay.forward(delivered, roomID: Self.roomID)
            await relay.waitForPendingCards()
            // The oldest delivered message is still in the room's transcript.
            let transcript = [delivered[0]]
                + Self.labelledBatch(prefix: "present", count: bound - 1)

            #expect(await relay.markPresent(
                transcript.map(\.id), roomID: Self.roomID, generation: activation.generation
            ))
            #expect(await relay.ledgerEntryCount == bound)
            await relay.forward(transcript, roomID: Self.roomID)
            await relay.waitForPendingCards()
            #expect(await recorder.cards.count == delivered.count)
        }

        // Queued cards outside the transcript keep their place in the queue.
        do {
            let recorder = GatedCardRecorder()
            let relay = Self.makeGatedRelay(recorder)
            let activation = try #require(await relay.activate(
                roomID: Self.roomID, chatID: Self.chatID, lease: Self.lease()
            ))
            let queued = Self.labelledBatch(prefix: "queued", count: 3)
            await relay.forward(queued, roomID: Self.roomID)
            await recorder.waitUntilSendStarted()
            let transcript = Self.labelledBatch(
                prefix: "present", count: AgentSharedChat.maximumRetainedMessagesPerRoom
            )

            #expect(await relay.markPresent(
                transcript.map(\.id), roomID: Self.roomID, generation: activation.generation
            ))
            #expect(await relay.ledgerEntryCount == bound)
            await recorder.open()
            await relay.waitForPendingCards()
            #expect(Self.bodies(of: await recorder.cards.map(\.text)) == queued.map(\.text))
            // Offered once the gate is open, so a regression fails here
            // instead of parking the producer on a queue that never drains.
            await relay.forward(transcript, roomID: Self.roomID)
            await relay.waitForPendingCards()
            #expect(Self.bodies(of: await recorder.cards.map(\.text)) == queued.map(\.text))
        }
    }

    /// Only an activation that starts forwarding the room to the chat marks:
    /// a repeated activation and a new lease of the pair already forwarded (a
    /// route refresh) start nothing, so a new message the observation has not
    /// offered yet still arrives. After `/telegram off`, or on another chat,
    /// the next activation starts again and marks.
    @Test
    func aRouteRefreshOfTheForwardedPairMarksNothing() async throws {
        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        let started = try #require(await relay.activate(
            roomID: Self.roomID, chatID: Self.chatID, lease: Self.lease()
        ))
        #expect(started.startedForwarding)

        let buffered = Self.message(text: "buffered during the refresh")
        let repeated = try #require(await relay.activate(
            roomID: Self.roomID, chatID: Self.chatID, lease: Self.lease(),
            presentMessageIDs: [buffered.id]
        ))
        #expect(!repeated.startedForwarding)
        let refreshed = try #require(await relay.activate(
            roomID: Self.roomID, chatID: Self.chatID, lease: Self.lease(generation: 2),
            presentMessageIDs: [buffered.id]
        ))
        #expect(!refreshed.startedForwarding)
        #expect(refreshed.generation != started.generation)
        await relay.forward([buffered], roomID: Self.roomID)
        await relay.waitForPendingCards()
        #expect(Self.bodies(of: await recorder.cards.map(\.text)) == [buffered.text])

        await relay.deactivate()
        #expect(await relay.forwards(roomID: Self.roomID, chatID: Self.chatID) == false)
        let whileOff = Self.message(text: "while off")
        let restarted = try #require(await relay.activate(
            roomID: Self.roomID, chatID: Self.chatID, lease: Self.lease(generation: 2),
            presentMessageIDs: [whileOff.id]
        ))
        #expect(restarted.startedForwarding)
        await relay.forward([whileOff], roomID: Self.roomID)

        let otherChat: Int64 = 4_343
        let onOtherChat = Self.message(text: "held when the other chat starts")
        let moved = try #require(await relay.activate(
            roomID: Self.roomID, chatID: otherChat, lease: Self.lease(chatID: otherChat),
            presentMessageIDs: [onOtherChat.id]
        ))
        #expect(moved.startedForwarding)
        await relay.forward([onOtherChat], roomID: Self.roomID)
        await relay.waitForPendingCards()
        #expect(Self.bodies(of: await recorder.cards.map(\.text)) == [buffered.text])
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

    /// The ledger bound is an invariant, not a taste: it must cover the largest
    /// transcript a forced reattach can replay *and* everything the relay can hold
    /// at once (the full queue plus the card in flight). Undersizing it evicts an
    /// identity that has not been delivered yet, which readmits it and evicts
    /// another — a self-sustaining cascade of duplicates.
    @Test
    func ledgerCoversTheReplayableTranscriptAndTheWholeQueue() async {
        #expect(
            TerminalTelegramSharedChatRelay.maximumLedgerEntries
                >= AgentSharedChat.maximumRetainedMessagesPerRoom
        )
        #expect(
            TerminalTelegramSharedChatRelay.maximumLedgerEntries
                >= TerminalTelegramSharedChatRelay.maximumQueuedCards + 1
        )

        let recorder = TelegramCardRecorder()
        let relay = Self.makeRelay(recorder)
        await relay.activate(roomID: Self.roomID, chatID: Self.chatID)

        // A full replayable transcript, offered exactly as the observer would
        // re-offer it after a forced reattach: not one card may be sent twice.
        let transcript = Self.labelledBatch(
            prefix: "producer-a",
            count: AgentSharedChat.maximumRetainedMessagesPerRoom
        )
        await relay.forward(transcript, roomID: Self.roomID)
        await relay.waitForPendingCards()
        #expect(await recorder.cards.count == transcript.count)

        await relay.forward(transcript, roomID: Self.roomID)
        await relay.waitForPendingCards()
        #expect(await recorder.cards.count == transcript.count)
    }
}
