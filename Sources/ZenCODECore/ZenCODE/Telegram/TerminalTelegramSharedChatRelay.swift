//
//  TerminalTelegramSharedChatRelay.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// Resolved destination of a Telegram reply to a forwarded shared-chat card.
///
/// Routing is derived exclusively from this locally recorded target, never from
/// the quoted text Telegram echoes back in `reply_to_message`: that payload is
/// user-controlled and could otherwise be used to address an arbitrary
/// participant.
public struct TerminalTelegramSharedChatReplyTarget: Sendable, Equatable {
    /// Room the card was forwarded from. Always the observation's room
    /// identifier, so it can be handed back to the runner as `rootSessionID`
    /// without depending on how the bus normalises room ids.
    public let roomID: String
    public let chatID: Int64
    public let sharedChatMessageID: UUID
    public let senderID: String
    public let senderKind: AgentSharedChat.ParticipantKind
    public let senderName: String

    /// Live destination that answers the original sender.
    ///
    /// `.operator` senders never produce a target (the operator is the human
    /// reading Telegram), so the fallback is deliberately absent rather than
    /// silently broadcasting.
    public var replyDestination: AgentSharedChat.Destination? {
        switch senderKind {
        case .agent:
            return .direct([senderID])
        case .coordinator:
            return .coordinator
        case .operator:
            return nil
        }
    }
}

/// Forwards every shared-chat message of the active room into the linked
/// Telegram chat and remembers which Telegram message each card became.
///
/// The relay deliberately does **not** open a second shared-chat observation:
/// the TUI already owns exactly one observer with recovery and rebinding, and a
/// second subscriber would duplicate delivery accounting. Batches are offered to
/// this actor from that single observer instead.
///
/// Delivery is **lossless**: the outbound queue is bounded, but a producer that
/// finds it full is suspended (bounded backpressure) instead of having its card
/// dropped, so a batch larger than the queue is forwarded in full and in order.
///
/// Delivery is **at-most-once per (room, chat, message id)** for as long as the
/// ledger of that binding lives: it survives `/telegram off` → `/telegram on`
/// and a forced reattach of the same room and chat, and is cleared when the
/// binding changes room or chat, at teardown, or when the bounded ledger evicts
/// its oldest entries. The Telegram Bot API has no idempotency key for
/// `sendMessage`, so a message id is marked as attempted *before* the HTTP call:
/// an ambiguous outcome loses a card rather than risking a duplicate, and
/// nothing is retried automatically.
actor TerminalTelegramSharedChatRelay {
    /// Sends one card and returns the Telegram receipt, or `nil` when delivery
    /// failed. Injected so the actor never depends on the TUI or on a concrete
    /// transport.
    typealias CardSender = @Sendable (_ text: String, _ chatID: Int64) async -> Int?

    /// Bounded outbound FIFO. The bound limits memory, never delivery: when the
    /// queue is full the *producer* waits for a free slot (see
    /// ``acquireCapacitySlot(generation:)``) and no card is ever discarded.
    /// Capacity is granted in strict arrival order, so FIFO survives
    /// backpressure, and a batch or replay of any size is forwarded completely.
    static let maximumQueuedCards = 512
    /// Bounded "already attempted" ledger, kept per active room+chat.
    ///
    /// The bound is not free to choose: it must cover **both** what a replay can
    /// legitimately re-offer and what this relay can hold at once.
    ///
    /// * `AgentSharedChat.maximumRetainedMessagesPerRoom` is the largest
    ///   transcript the observer can replay on a forced reattach. A smaller
    ///   ledger would evict the head of that very replay while the tail is still
    ///   being admitted, so already delivered cards would be sent again.
    /// * `maximumQueuedCards + 1` covers every card that is queued *plus* the one
    ///   currently in flight. A ledger smaller than that would forget an identity
    ///   the relay has not even delivered yet, and each eviction would readmit it
    ///   and evict another — a self-sustaining cascade of duplicates.
    ///
    /// Taking the maximum of the two satisfies both at once and keeps the
    /// invariant checkable from tests instead of being a hand-tuned constant.
    static let maximumLedgerEntries = max(
        AgentSharedChat.maximumRetainedMessagesPerRoom,
        TerminalTelegramSharedChatRelay.maximumQueuedCards + 1
    )
    /// Bounded receipt map. Replying to a card older than this falls back to the
    /// ordinary prompt path.
    static let maximumReplyTargets = 256

    private struct Context: Equatable {
        let roomID: String
        let chatID: Int64
    }

    /// A receipt observed while the relay was unbound, kept until the same
    /// binding is re-activated.
    private struct PendingReceipt {
        let ledgerEpoch: Int
        let receipt: Int
        let target: TerminalTelegramSharedChatReplyTarget
    }

    private struct PendingCard {
        let generation: Int
        /// Identity of the ledger that recorded this card. A receipt may install a
        /// reply mapping only while that same ledger is still live.
        let ledgerEpoch: Int
        let chatID: Int64
        let text: String
        let target: TerminalTelegramSharedChatReplyTarget
    }

    /// A producer parked until the bounded queue has room for its next card.
    private struct CapacityWaiter {
        let id: Int
        /// Binding the producer was admitted for. A waiter of a retired binding
        /// is woken with `false` instead of being granted a slot.
        let generation: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// A test observer waiting for at least `threshold` parked producers.
    private struct CapacityWaitObserver {
        let threshold: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let send: CardSender
    /// Non-nil only while Telegram is active and bound to a room.
    private var activeContext: Context?
    /// Context the ledger and receipt map belong to. Kept across `/telegram off`
    /// → `/telegram on` for the same room and chat so re-enabling cannot resend
    /// cards the chat already received.
    private var ledgerContext: Context?
    /// Bumped by every binding change so a card queued for a retired binding
    /// cannot be sent for the current one.
    private var generation = 0
    /// True while the surface that owns this relay also consumes Telegram
    /// ingress. When false, cards say so instead of inviting a reply nobody
    /// reads.
    private var repliesEnabled = true
    /// Bumped by every ledger reset, so a card rendered under a retired delivery
    /// history is recognisable even when the room and chat happen to match again.
    private var ledgerEpoch = 0
    /// Number of `send` calls currently suspended. The fence uses it to wait
    /// until no delivery of a retired binding can still be running.
    private var inFlightDeliveries = 0
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var queue: [PendingCard] = []
    private var drainTask: Task<Void, Never>?
    private var forwardedIDs: Set<UUID> = []
    private var forwardedOrder: [UUID] = []
    private var replyTargets: [Int: TerminalTelegramSharedChatReplyTarget] = [:]
    private var replyTargetOrder: [Int] = []
    /// Receipts of cards that were still in flight when the binding was
    /// suspended by `/telegram off`. Bounded exactly like ``replyTargets`` and
    /// cleared by every ledger reset, so a genuinely retired context can never
    /// be reopened from here.
    private var pendingReceipts: [PendingReceipt] = []
    /// Number of callers currently parked inside ``waitForQuiescence()``.
    /// Observed by ``waitUntilFenceIsWaiting()`` so a test can prove the fence
    /// was entered instead of inferring it from scheduling.
    private var fenceEntryObservers: [CheckedContinuation<Void, Never>] = []
    /// Producers suspended because the outbound queue is full, in arrival order.
    private var capacityWaiters: [CapacityWaiter] = []
    private var nextCapacityWaiterID = 0
    /// Slots granted to a producer that has not enqueued its card yet. Counted
    /// with the queue so a grant can never oversubscribe the bound.
    ///
    /// The invariant is stronger than "bounded": it never exceeds 1. The reserve
    /// → enqueue section is serialised, which is what makes the queue order
    /// global rather than per producer.
    private var reservedSlots = 0
    /// High-water mark of ``reservedSlots``, so a test can assert the
    /// serialisation invariant directly instead of inferring it from the
    /// resulting order.
    private(set) var peakUncommittedReservations = 0
    /// Set by ``shutdown()`` and never cleared: after teardown nothing may be
    /// admitted, and no producer may stay parked waiting for a worker that is
    /// gone.
    private var isShutDown = false
    /// Observers of ``waitUntilProducersAreBlocked(count:)``, each waiting for a
    /// number of parked producers, so a test can prove the backpressure wait was
    /// entered instead of inferring it from scheduling.
    private var capacityWaitObservers: [CapacityWaitObserver] = []

    init(send: @escaping CardSender) {
        self.send = send
    }

    // MARK: - Lifecycle

    /// Binds the relay to a room and linked chat.
    ///
    /// Re-binding to the *same* pair is a no-op: it must not fence, drop queued
    /// cards or invalidate receipts, because `/new` on an unchanged room and a
    /// repeated activation are indistinguishable from here and would otherwise
    /// lose in-flight work. Any other change fences the previous binding first
    /// (see ``fence()``) and then clears the ledger, because message identifiers
    /// of a retired room say nothing about what the new binding delivered.
    /// Registers a bot-authored composition card as a safe reply target. Unlike
    /// forwarded cards, the target is selected from the current live catalogue;
    /// quoted Telegram text is never consulted for routing.
    func registerReplyTarget(
        _ target: TerminalTelegramSharedChatReplyTarget,
        forTelegramMessageID receipt: Int
    ) {
        guard ledgerContext == Context(roomID: target.roomID, chatID: target.chatID) else { return }
        recordReplyTarget(target, receipt: receipt)
    }

    func activate(roomID: String, chatID: Int64, repliesEnabled: Bool = true) async {
        let context = Context(roomID: roomID, chatID: chatID)
        guard activeContext != context else {
            // Idempotent: only the (purely cosmetic) reply affordance is refreshed.
            self.repliesEnabled = repliesEnabled
            return
        }
        await fence()
        self.repliesEnabled = repliesEnabled
        if ledgerContext != context {
            resetLedger()
            ledgerContext = context
        }
        activeContext = context
        // A send that started before `/telegram off` may have answered while the
        // relay was unbound. Its card really is in this chat, so its receipt is
        // installed now that the very same binding is live again.
        promotePendingReceipts()
    }

    /// Unbinds without discarding the ledger, so `/telegram off` → `/telegram on`
    /// on the same room and chat does not replay cards and still accepts replies
    /// to the cards already delivered there.
    ///
    /// A send that started before this call can still answer while unbound. Its
    /// card is really in that chat, so its receipt is parked in a bounded list
    /// and installed only if the very same room and chat are activated again;
    /// any binding change clears the ledger and the parked receipts with it.
    func deactivate() async {
        guard activeContext != nil else {
            // Already unbound, but a concurrent fence may still be waiting out an
            // in-flight send: the caller is about to release the transport, so it
            // must not return before that send has finished. Parked producers are
            // refused here too, because nothing is bound to admit them.
            grantCapacityToWaitersIfPossible()
            await waitForQuiescence()
            return
        }
        await fence()
    }

    /// Retires the current binding and waits until nothing sent for it can still
    /// be in flight.
    ///
    /// Bumping the generation and clearing the queue stops *future* sends, but a
    /// card already handed to the transport would otherwise land in the chat
    /// after the caller believes the rebind is complete. Waiting for quiescence
    /// is what makes "no card of room A is sent after the rebind to room B
    /// returned" an invariant rather than a race.
    private func fence() async {
        generation &+= 1
        activeContext = nil
        queue.removeAll()
        // Every parked producer belongs to the generation just retired, so the
        // grant loop wakes them with a refusal: no one stays blocked on a queue
        // that will never drain for them, and nothing of the retired binding is
        // admitted afterwards.
        grantCapacityToWaitersIfPossible()
        await waitForQuiescence()
    }

    private func waitForQuiescence() async {
        while inFlightDeliveries > 0 {
            await withCheckedContinuation { continuation in
                quiescenceWaiters.append(continuation)
                signalFenceEntry()
            }
        }
    }

    /// Returns once a caller is parked waiting for quiescence.
    ///
    /// This is the deterministic handshake the fence tests use: it proves the
    /// rebind or teardown actually entered the wait, so "it has not returned
    /// yet" is an observed state rather than a scheduling assumption.
    func waitUntilFenceIsWaiting() async {
        guard quiescenceWaiters.isEmpty else { return }
        await withCheckedContinuation { continuation in
            fenceEntryObservers.append(continuation)
        }
    }

    private func signalFenceEntry() {
        guard !fenceEntryObservers.isEmpty else { return }
        let observers = fenceEntryObservers
        fenceEntryObservers.removeAll()
        for observer in observers {
            observer.resume()
        }
    }

    private func signalQuiescenceIfNeeded() {
        guard inFlightDeliveries == 0, !quiescenceWaiters.isEmpty else { return }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Cancels the drain worker and waits for it, so teardown leaves no task
    /// running after the owning chat is gone.
    func shutdown() async {
        // Set before the fence so a producer that wakes during teardown is
        // refused rather than re-admitted into a queue nothing will drain.
        isShutDown = true
        await fence()
        resetLedger()
        ledgerContext = nil
        let task = drainTask
        drainTask = nil
        task?.cancel()
        await task?.value
    }

    // MARK: - Forwarding

    /// Offers one observer batch. Every message in the active room is mirrored:
    /// operator-originated traffic, coordinator ↔ agent traffic, peer traffic,
    /// direct multi-recipient traffic and broadcasts are all visible.
    ///
    /// Nothing is dropped. When the bounded queue is full the call suspends until
    /// the drain worker frees a slot, so a batch or a replay larger than the queue
    /// is forwarded completely and in order. The suspension happens *before* the
    /// message identity is written to the ledger: admission and deduplication are
    /// therefore one indivisible actor step, and a producer whose wait is
    /// cancelled — or whose binding is retired while it waits — leaves no
    /// "already forwarded" mark behind, so the message can be replayed safely.
    func forward(
        _ messages: [AgentSharedChat.Message],
        roomID: String,
        participants: [AgentSharedChat.Participant] = []
    ) async {
        guard !isShutDown, let context = activeContext, context.roomID == roomID else {
            return
        }
        // Cards are rendered for the binding observed on entry; a rebind during
        // the wait retires this producer instead of letting it write into the
        // new binding's queue.
        let entryGeneration = generation
        let recipientNames = Dictionary(
            uniqueKeysWithValues: participants.map { ($0.id, $0.name) }
        )
        for message in messages {
            guard isAdmitting(generation: entryGeneration, roomID: roomID) else { return }
            // Cheap pre-check: an identity already delivered for this binding
            // never consumes a slot and never waits.
            guard !forwardedIDs.contains(message.id) else { continue }
            guard await acquireCapacitySlot(generation: entryGeneration) else { return }
            // From here to the enqueue there is no suspension point, so the
            // reservation, the ledger mark and the queue insertion commit
            // together.
            defer { releaseReservedSlot() }
            guard !Task.isCancelled,
                  isAdmitting(generation: entryGeneration, roomID: roomID),
                  let liveContext = activeContext else {
                return
            }
            guard forwardedIDs.insert(message.id).inserted else { continue }
            forwardedOrder.append(message.id)
            trimLedgerIfNeeded()
            queue.append(
                PendingCard(
                    generation: entryGeneration,
                    ledgerEpoch: ledgerEpoch,
                    chatID: liveContext.chatID,
                    text: Self.cardText(
                        for: message,
                        recipientNames: recipientNames,
                        repliesEnabled: repliesEnabled
                    ),
                    target: TerminalTelegramSharedChatReplyTarget(
                        roomID: liveContext.roomID,
                        chatID: liveContext.chatID,
                        sharedChatMessageID: message.id,
                        senderID: message.sender.id,
                        senderKind: message.sender.kind,
                        senderName: message.sender.name
                    )
                )
            )
            startDrainIfNeeded()
        }
        startDrainIfNeeded()
    }

    /// Returns the recorded destination of a Telegram reply, when the quoted
    /// message is a card this relay sent for the currently bound chat.
    ///
    /// Only answerable cards are reported. A card without a live destination is
    /// never recorded in the first place; the check is repeated here so the
    /// contract holds for every caller — "a target exists" and "replying to it
    /// routes somewhere" are the same statement.
    func replyTarget(
        forTelegramMessageID messageID: Int,
        chatID: Int64
    ) -> TerminalTelegramSharedChatReplyTarget? {
        guard let context = activeContext,
              context.chatID == chatID,
              let target = replyTargets[messageID],
              target.replyDestination != nil,
              target.chatID == chatID,
              target.roomID == context.roomID else {
            return nil
        }
        return target
    }

    /// Waits until the outbound queue is drained and no send is in flight.
    ///
    /// The worker retires itself from inside the actor when the queue empties, so
    /// this terminates once no card is pending. Used by teardown-sensitive tests
    /// to observe delivery without polling.
    func waitForPendingCards() async {
        while let task = drainTask {
            await task.value
        }
        await waitForQuiescence()
    }

    // MARK: - Card rendering

    /// Renders a card as plain text.
    ///
    /// Name and body are agent-authored, so control and bidi scalars are removed
    /// and no Markdown parse mode is requested by the sender: unintended markup
    /// must not be able to restyle or hide part of an agent's message.
    ///
    /// The footer states what the surface can actually do: a terminal running the
    /// blocking input fallback forwards cards but never reads Telegram ingress,
    /// so inviting a reply there would promise a delivery that cannot happen.
    static func cardText(
        for message: AgentSharedChat.Message,
        recipientNames: [String: String] = [:],
        repliesEnabled: Bool = true
    ) -> String {
        let sender = safeDisplayName(message.sender.name, fallback: message.sender.id)
        let recipients = message.recipientIDs.map {
            recipientDisplayName($0, roomID: message.roomID, names: recipientNames)
        }
        let route = "\(sender) → \(recipients.isEmpty ? "(no recipients)" : recipients.joined(separator: ", "))"
        let body = AgentSharedChat.promptSafeTextLines(message.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let footer: String
        if !repliesEnabled {
            footer = "This ZenCODE session does not read Telegram messages; answer from the terminal."
        } else if message.sender.kind == .operator {
            // The Telegram user is the operator: the card is evidence of their
            // own outbound message, never an invitation to target themselves.
            footer = "Operator-originated message; replies use normal Telegram routing."
        } else {
            footer = "Reply to this message to answer \(sender)."
        }
        return """
        \(route)

        \(body)

        \(footer)
        """
    }

    private static func safeDisplayName(_ value: String, fallback: String) -> String {
        let name = AgentSharedChat.promptSafeInlineText(value, limit: 80)
        if !name.isEmpty { return name }
        let stableID = AgentSharedChat.promptSafeInlineText(fallback, limit: 128)
        return stableID.isEmpty ? "unknown participant" : stableID
    }

    private static func recipientDisplayName(
        _ id: String,
        roomID: String,
        names: [String: String]
    ) -> String {
        if id == AgentSharedChat.operatorID(for: roomID) { return "operator" }
        if id == AgentSharedChat.coordinatorID(for: roomID) { return "coordinator" }
        return safeDisplayName(names[id] ?? "", fallback: id)
    }

    // MARK: - Queue and backpressure

    /// True while a card rendered for `generation` may still be admitted.
    private func isAdmitting(generation entryGeneration: Int, roomID: String) -> Bool {
        !isShutDown && generation == entryGeneration && activeContext?.roomID == roomID
    }

    /// Reserved slots count against the bound: a granted producer already owns
    /// its place in the queue even before it appends the card.
    private var hasFreeCapacity: Bool {
        queue.count + reservedSlots < Self.maximumQueuedCards
    }

    /// Reserves one queue slot, suspending while the queue is full.
    ///
    /// Returns `false` when the producer must stop: teardown, a retired binding
    /// or cancellation. A refusal never leaves state behind, so the caller has
    /// marked nothing and the message stays replayable.
    private func acquireCapacitySlot(generation entryGeneration: Int) async -> Bool {
        guard !Task.isCancelled else { return false }
        // Jumping ahead of parked producers would reorder the transcript, so a
        // free slot is taken directly only while nobody is waiting *and* no
        // reservation is outstanding.
        //
        // `reservedSlots == 0` is what makes the order global rather than
        // per-producer. A grant hands its winner the actor only later, when its
        // continuation is resumed; in that window `capacityWaiters` may already
        // be empty even though the granted producer has not enqueued its card
        // yet. Without this condition a second producer entering that window
        // would take the fast path and land in the queue *before* the producer
        // that asked for capacity first, silently reordering the transcript.
        if capacityWaiters.isEmpty, reservedSlots == 0, hasFreeCapacity {
            reserveSlot()
            return true
        }
        let id = nextCapacityWaiterID
        nextCapacityWaiterID &+= 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                capacityWaiters.append(
                    CapacityWaiter(
                        id: id,
                        generation: entryGeneration,
                        continuation: continuation
                    )
                )
                signalCapacityWaitEntry()
            }
        } onCancel: {
            Task { await self.cancelCapacityWaiter(id) }
        }
    }

    /// Takes the single outstanding reservation, recording the high-water mark
    /// that makes the serialisation invariant observable.
    private func reserveSlot() {
        reservedSlots += 1
        peakUncommittedReservations = max(peakUncommittedReservations, reservedSlots)
    }

    /// Releases the reservation of a producer that enqueued its card or gave up,
    /// and hands the freed capacity to the next waiter.
    private func releaseReservedSlot() {
        reservedSlots -= 1
        grantCapacityToWaitersIfPossible()
    }

    /// Wakes parked producers in arrival order.
    ///
    /// At most **one** reservation is uncommitted at any time: a grant is issued
    /// only while `reservedSlots == 0`, and the next one follows the winner's
    /// enqueue (which releases it). Serialising the reserve → enqueue section
    /// this way is what makes the queue order match the order in which producers
    /// asked for capacity, globally and regardless of how continuations are
    /// scheduled.
    ///
    /// Refusals are *not* gated on reservations: waiters of a retired binding —
    /// or every waiter once the relay is shut down or unbound — must be woken
    /// even while a reservation is outstanding, otherwise a fence issued in that
    /// window would leave them parked forever. That refusal pass is what makes
    /// teardown deadlock-free.
    private func grantCapacityToWaitersIfPossible() {
        while let waiter = capacityWaiters.first {
            guard !isShutDown,
                  waiter.generation == generation,
                  activeContext != nil else {
                capacityWaiters.removeFirst()
                waiter.continuation.resume(returning: false)
                continue
            }
            // A granted producer still owes an enqueue: until it commits, nobody
            // else may be admitted, not even into a slot that just freed.
            guard reservedSlots == 0, hasFreeCapacity else { return }
            capacityWaiters.removeFirst()
            reserveSlot()
            waiter.continuation.resume(returning: true)
            return
        }
    }

    private func cancelCapacityWaiter(_ id: Int) {
        guard let index = capacityWaiters.firstIndex(where: { $0.id == id }) else {
            // Already granted or already refused: the producer re-checks
            // cancellation itself and releases the reservation it was given.
            return
        }
        let waiter = capacityWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    /// Returns once at least `count` producers are parked waiting for capacity.
    ///
    /// Deterministic handshake for the backpressure tests: "these producers are
    /// blocked, in this order" becomes an observed state instead of a timing
    /// assumption, which is what lets a multi-producer test assert an exact
    /// global sequence.
    func waitUntilProducersAreBlocked(count: Int = 1) async {
        guard capacityWaiters.count < count else { return }
        await withCheckedContinuation { continuation in
            capacityWaitObservers.append(
                CapacityWaitObserver(threshold: count, continuation: continuation)
            )
        }
    }

    /// Returns once at least one producer is parked waiting for capacity.
    func waitUntilProducerIsBlocked() async {
        await waitUntilProducersAreBlocked(count: 1)
    }

    /// Number of identities the ledger has admitted so far.
    ///
    /// Read by tests only while the relay is provably quiescent (transport gated,
    /// producers parked), where it is exactly the number of cards admitted.
    var admittedCardCount: Int {
        forwardedOrder.count
    }

    private func signalCapacityWaitEntry() {
        guard !capacityWaitObservers.isEmpty else { return }
        let parked = capacityWaiters.count
        let reached = capacityWaitObservers.filter { parked >= $0.threshold }
        guard !reached.isEmpty else { return }
        capacityWaitObservers.removeAll { parked >= $0.threshold }
        for observer in reached {
            observer.continuation.resume()
        }
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil, !queue.isEmpty else { return }
        drainTask = Task(name: "ZenCODE.Telegram.shared-chat-relay") { [weak self] in
            while let card = await self?.dequeueNextCard() {
                await self?.deliver(card)
            }
        }
    }

    /// Pops the next deliverable card, retiring the worker when the queue drains.
    /// Both the check and the retirement are actor-isolated, so a concurrent
    /// `forward` either sees a live worker or starts exactly one replacement.
    /// Every pop frees a slot, so a producer parked on backpressure is woken
    /// here as delivery progresses.
    private func dequeueNextCard() -> PendingCard? {
        while !queue.isEmpty {
            let card = queue.removeFirst()
            grantCapacityToWaitersIfPossible()
            guard card.generation == generation, activeContext != nil else {
                continue
            }
            return card
        }
        drainTask = nil
        grantCapacityToWaitersIfPossible()
        return nil
    }

    private func deliver(_ card: PendingCard) async {
        // Dequeue and delivery are separate actor entries, so the binding can be
        // retired in between. Re-check immediately before the transport call:
        // this is the last point at which a stale card can still be stopped.
        guard card.generation == generation, activeContext != nil else {
            return
        }
        inFlightDeliveries += 1
        let receipt = await send(card.text, card.chatID)
        inFlightDeliveries -= 1
        signalQuiescenceIfNeeded()
        guard let receipt else {
            // Ambiguous or failed delivery: never retried, so the card is simply
            // not answerable from Telegram.
            return
        }
        recordReceipt(receipt, for: card)
    }

    /// Installs the receipt of a delivered card, or parks it when the binding is
    /// only suspended.
    ///
    /// Ledger continuity, not the generation, is the authority. The ledger of a
    /// card is still live exactly when the relay's ledger belongs to the same
    /// room and chat *and* was never reset since the card was rendered, which is
    /// true across `/telegram off` → `/telegram on` on that pair and false after
    /// a real room change — including an A→B→A round trip, whose reset makes the
    /// epoch differ even though the pair matches again.
    ///
    /// When the ledger is live but nothing is bound, the send started before
    /// `/telegram off` and answered during it: the card exists in that chat, so
    /// its receipt is kept (bounded) and installed if and only if the same pair
    /// is activated again.
    ///
    /// A card whose sender has no live destination — today the operator's own
    /// traffic, which is mirrored as evidence and must never address the Telegram
    /// user back to themselves — gets **no** target at all: not installed, not
    /// parked. Recording one would make the card look answerable to every caller
    /// that only asks "is this a reply to a card?", such as the voice-note guard,
    /// and would divert an ordinary voice prompt into a refusal.
    private func recordReceipt(_ receipt: Int, for card: PendingCard) {
        guard card.target.replyDestination != nil else { return }
        let cardContext = Context(roomID: card.target.roomID, chatID: card.chatID)
        guard ledgerContext == cardContext, card.ledgerEpoch == ledgerEpoch else {
            return
        }
        if activeContext == cardContext {
            recordReplyTarget(card.target, receipt: receipt)
        } else if activeContext == nil {
            parkPendingReceipt(card.target, receipt: receipt)
        }
    }

    private func parkPendingReceipt(
        _ target: TerminalTelegramSharedChatReplyTarget,
        receipt: Int
    ) {
        pendingReceipts.append(
            PendingReceipt(ledgerEpoch: ledgerEpoch, receipt: receipt, target: target)
        )
        while pendingReceipts.count > Self.maximumReplyTargets {
            pendingReceipts.removeFirst()
        }
    }

    /// Moves parked receipts of the live ledger into the reply map. The epoch is
    /// re-checked defensively: a reset clears this list, so a surviving entry of
    /// another epoch would be a bug, never a routable target.
    private func promotePendingReceipts() {
        guard !pendingReceipts.isEmpty else { return }
        let promotable = pendingReceipts
        pendingReceipts.removeAll()
        for entry in promotable where entry.ledgerEpoch == ledgerEpoch {
            guard entry.target.roomID == activeContext?.roomID,
                  entry.target.chatID == activeContext?.chatID else {
                continue
            }
            recordReplyTarget(entry.target, receipt: entry.receipt)
        }
    }

    private func recordReplyTarget(
        _ target: TerminalTelegramSharedChatReplyTarget,
        receipt: Int
    ) {
        if replyTargets.updateValue(target, forKey: receipt) == nil {
            replyTargetOrder.append(receipt)
        }
        while replyTargetOrder.count > Self.maximumReplyTargets {
            let oldest = replyTargetOrder.removeFirst()
            replyTargets.removeValue(forKey: oldest)
        }
    }

    private func trimLedgerIfNeeded() {
        while forwardedOrder.count > Self.maximumLedgerEntries {
            let oldest = forwardedOrder.removeFirst()
            forwardedIDs.remove(oldest)
        }
    }

    private func resetLedger() {
        ledgerEpoch &+= 1
        forwardedIDs.removeAll()
        forwardedOrder.removeAll()
        replyTargets.removeAll()
        replyTargetOrder.removeAll()
        pendingReceipts.removeAll()
    }
}
