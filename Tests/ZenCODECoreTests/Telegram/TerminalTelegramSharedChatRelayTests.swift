//
//  TerminalTelegramSharedChatRelayTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

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

    /// There is no recipient filter: the Telegram mirror shows every message
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
        let admittedPrefix = await relay.admittedCardCount
        #expect(admittedPrefix > 0)

        let producerB = Task { await relay.forward(batchB, roomID: Self.roomID) }
        await relay.waitUntilProducersAreBlocked(count: 2)
        // B asked second and must stay behind A: nothing of B was admitted.
        #expect(await relay.admittedCardCount == admittedPrefix)

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
        let admitted = await relay.admittedCardCount
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
