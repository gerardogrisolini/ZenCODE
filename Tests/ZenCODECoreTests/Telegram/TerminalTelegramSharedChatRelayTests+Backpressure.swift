//
//  TerminalTelegramSharedChatRelayTests+Backpressure.swift
//  ZenCODE
//
//  Fence, quiescence, lossless backpressure and global FIFO tests of the
//  Telegram shared-chat relay, with the gated card recorder and the
//  completion flag they use.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

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

extension TerminalTelegramSharedChatRelayTests {
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
        await relay.waitUntilProducersAreBlocked(count: 1)
        #expect(await recorder.cards.isEmpty)

        await recorder.open()
        await producer.value
        await relay.waitForPendingCards()

        let payloads = Self.payloads(of: await recorder.cards)
        #expect(payloads == Self.expectedTexts(for: batch))
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
        await relay.waitUntilProducersAreBlocked(count: 1)
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
        await relay.waitUntilProducersAreBlocked(count: 1)
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
        await relay.waitUntilProducersAreBlocked(count: 1)
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
}
