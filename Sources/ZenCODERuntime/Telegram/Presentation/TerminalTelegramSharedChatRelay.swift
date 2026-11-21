//
//  TerminalTelegramSharedChatRelay.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

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
///
/// Only **new** messages reach the chat. When the relay starts forwarding a
/// room — the first `/telegram on`, `/telegram on` after `/telegram off`, a
/// room swap, a link that gets its route back — the messages the room already
/// holds are marked as handled without a card (see
/// ``activate(roomID:chatID:lease:repliesEnabled:presentMessageIDs:)`` and
/// ``markPresent(_:roomID:generation:)``), so the observer's replay of the
/// retained transcript forwards nothing: only what the room says afterwards
/// is relayed.
actor TerminalTelegramSharedChatRelay {
    /// Sends one card and returns the Telegram receipt, or `nil` when delivery
    /// failed. Injected so the actor never depends on the TUI or on a concrete
    /// transport.
    typealias CardSender = @Sendable (
        _ text: String, _ chatID: Int64, _ lease: TerminalTelegramRouteLease
    ) async -> Int?
    typealias LeaseValidator = @Sendable (TerminalTelegramRouteLease) async -> Bool

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
    /// The marks of the messages already present when the relay starts
    /// forwarding a room come from the same transcript, so they are bounded by
    /// the first term; how they share the ledger with queued cards is explained
    /// in ``recordPresent(_:)``.
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

    struct Context: Equatable {
        let roomID: String
        let chatID: Int64
        let lease: TerminalTelegramRouteLease
    }

    /// The room and chat a binding forwards, whatever its lease.
    private struct Route: Equatable {
        let roomID: String
        let chatID: Int64
    }

    /// The binding an
    /// ``activate(roomID:chatID:lease:repliesEnabled:presentMessageIDs:)``
    /// call left live.
    struct Activation: Sendable, Equatable {
        /// Generation of the live binding, the token
        /// ``markPresent(_:roomID:generation:)`` checks.
        let generation: Int
        /// `true` when the call started forwarding the room to the chat: the
        /// relay was unbound, or forwarded another room or chat. A repeated
        /// activation and a new lease of the pair already forwarded (a route
        /// refresh) start nothing.
        let startedForwarding: Bool
    }

    /// A receipt observed while the relay was unbound, kept until the same
    /// binding is re-activated.
    private struct PendingReceipt {
        let ledgerEpoch: Int
        let receipt: Int
        let target: TerminalTelegramSharedChatReplyTarget
    }

    struct PendingCard {
        let generation: Int
        /// Identity of the ledger that recorded this card. A receipt may install a
        /// reply mapping only while that same ledger is still live.
        let ledgerEpoch: Int
        let chatID: Int64
        let lease: TerminalTelegramRouteLease
        let text: String
        let target: TerminalTelegramSharedChatReplyTarget
    }

    /// A producer parked until the bounded queue has room for its next card.
    struct CapacityWaiter {
        let id: Int
        /// Binding the producer was admitted for. A waiter of a retired binding
        /// is woken with `false` instead of being granted a slot.
        let generation: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// A test observer waiting for at least `threshold` parked producers.
    struct CapacityWaitObserver {
        let threshold: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    let send: CardSender
    let validateLease: LeaseValidator
    /// Non-nil only while Telegram is active and bound to a room.
    var activeContext: Context?
    /// Context the ledger and receipt map belong to. Kept across `/telegram off`
    /// → `/telegram on` for the same room and chat so re-enabling cannot resend
    /// cards the chat already received.
    private var ledgerContext: Context?
    /// Room and chat of the binding last made live, cleared only by an explicit
    /// unbind (``deactivate()``, ``shutdown()``). Unlike ``activeContext`` it
    /// survives the transient fence of a rebind, so "this activation starts
    /// forwarding the room" is decided against what the chat was really
    /// receiving, not against a concurrent rebind caught halfway.
    private var forwardingRoute: Route?
    /// Bumped by every binding change so a card queued for a retired binding
    /// cannot be sent for the current one.
    var generation = 0
    /// True while the surface that owns this relay also consumes Telegram
    /// ingress. When false, cards say so instead of inviting a reply nobody
    /// reads.
    var repliesEnabled = true
    /// Bumped by every ledger reset, so a card rendered under a retired delivery
    /// history is recognisable even when the room and chat happen to match again.
    var ledgerEpoch = 0
    /// Number of `send` calls currently suspended. The fence uses it to wait
    /// until no delivery of a retired binding can still be running.
    var inFlightDeliveries = 0
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    var queue: [PendingCard] = []
    var drainTask: Task<Void, Never>?
    var forwardedIDs: Set<UUID> = []
    var forwardedOrder: [UUID] = []
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
    var capacityWaiters: [CapacityWaiter] = []
    var nextCapacityWaiterID = 0
    /// Slots granted to a producer that has not enqueued its card yet. Counted
    /// with the queue so a grant can never oversubscribe the bound.
    ///
    /// The invariant is stronger than "bounded": it never exceeds 1. The reserve
    /// → enqueue section is serialised, which is what makes the queue order
    /// global rather than per producer.
    var reservedSlots = 0
    /// High-water mark of ``reservedSlots``, so a test can assert the
    /// serialisation invariant directly instead of inferring it from the
    /// resulting order.
    var peakUncommittedReservations = 0
    /// Set by ``shutdown()`` and never cleared: after teardown nothing may be
    /// admitted, and no producer may stay parked waiting for a worker that is
    /// gone.
    var isShutDown = false
    /// Observers of ``waitUntilProducersAreBlocked(count:)``, each waiting for a
    /// number of parked producers, so a test can prove the backpressure wait was
    /// entered instead of inferring it from scheduling.
    var capacityWaitObservers: [CapacityWaitObserver] = []

    init(validateLease: @escaping LeaseValidator, send: @escaping CardSender) {
        self.validateLease = validateLease
        self.send = send
    }

    // MARK: - Lifecycle

    /// Registers a bot-authored composition card as a safe reply target. Unlike
    /// forwarded cards, the target is selected from the current live catalogue;
    /// quoted Telegram text is never consulted for routing.
    func registerReplyTarget(
        _ target: TerminalTelegramSharedChatReplyTarget,
        forTelegramMessageID receipt: Int,
        lease: TerminalTelegramRouteLease
    ) async {
        guard await validateLease(lease) else { return }
        guard ledgerContext?.roomID == target.roomID,
              ledgerContext?.chatID == target.chatID,
              activeContext?.lease == lease else { return }
        recordReplyTarget(target, receipt: receipt)
    }

    /// Binds the relay to a room and linked chat, and returns the binding now
    /// live, or `nil` when the lease cannot serve the room (the relay is then
    /// unbound).
    ///
    /// Re-binding to the *same* pair is a no-op: it must not fence, drop queued
    /// cards or invalidate receipts, because `/new` on an unchanged room and a
    /// repeated activation are indistinguishable from here and would otherwise
    /// lose in-flight work. Any other change fences the previous binding first
    /// (see ``fence()``) and then clears the ledger, because message identifiers
    /// of a retired room say nothing about what the new binding delivered.
    ///
    /// When the call starts forwarding the room to the chat (see
    /// ``Activation/startedForwarding``), `presentMessageIDs` — the room's
    /// messages, read by the caller just before the call — are marked as
    /// handled without a card, in the same actor step that makes the binding
    /// live: a producer running concurrently either finds the relay unbound
    /// or finds the marks already written, so a message already present never
    /// becomes a card whichever order the observer's replay takes. The decision
    /// is taken after the fence, against the binding last made live: a new
    /// lease of the pair already forwarded marks nothing, because the messages
    /// a running observation has still to offer are new and must arrive.
    @discardableResult
    func activate(
        roomID: String, chatID: Int64,
        lease: TerminalTelegramRouteLease,
        repliesEnabled: Bool = true,
        presentMessageIDs: [UUID] = []
    ) async -> Activation? {
        // The lease must serve the room: its own, or any when it is the shared
        // route; a route bound to another room never binds the relay.
        guard lease.key.admits(roomID: roomID), lease.key.chatID == chatID,
              await validateLease(lease) else {
            await deactivate()
            return nil
        }
        let context = Context(roomID: roomID, chatID: chatID, lease: lease)
        guard activeContext != context else {
            // Idempotent: only the (purely cosmetic) reply affordance is refreshed.
            self.repliesEnabled = repliesEnabled
            return Activation(generation: generation, startedForwarding: false)
        }
        await fence()
        self.repliesEnabled = repliesEnabled
        if ledgerContext != context {
            resetLedger()
            ledgerContext = context
        }
        // No suspension from here to the return: the binding, the decision and
        // the marks commit together.
        let route = Route(roomID: roomID, chatID: chatID)
        let startedForwarding = forwardingRoute != route
        activeContext = context
        forwardingRoute = route
        if startedForwarding {
            recordPresent(presentMessageIDs)
        }
        // A send that started before `/telegram off` may have answered while the
        // relay was unbound. Its card really is in this chat, so its receipt is
        // installed now that the very same binding is live again.
        promotePendingReceipts()
        return Activation(generation: generation, startedForwarding: startedForwarding)
    }

    /// Marks the messages already present in `roomID` as handled for the
    /// binding `generation`, without queuing a card for any of them, and
    /// returns whether it did.
    ///
    /// For a caller that knows nothing is being forwarded for the room yet,
    /// such as an observation that is bound but has not offered its first
    /// event: there the marks are needed even when the activation itself was a
    /// no-op (the binding was already made, by a Telegram message for
    /// instance), and no producer can slip in before them. The marks share the
    /// ledger's bound (see ``recordPresent(_:)``). Refused, touching nothing,
    /// after teardown, once the binding `generation` was retired, or while the
    /// live binding serves another room.
    @discardableResult
    func markPresent(
        _ messageIDs: [UUID],
        roomID: String,
        generation expectedGeneration: Int
    ) -> Bool {
        guard !isShutDown,
              generation == expectedGeneration,
              activeContext?.roomID == roomID else {
            return false
        }
        recordPresent(messageIDs)
        return true
    }

    /// Whether the relay forwards `roomID` to `chatID` now, whatever the lease.
    /// An activation for that pair starts nothing and marks nothing, so its
    /// caller need not read the room's present messages.
    func forwards(roomID: String, chatID: Int64) -> Bool {
        forwardingRoute == Route(roomID: roomID, chatID: chatID)
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
        // Explicitly unbound: the next activation starts forwarding again, so
        // the messages the room holds by then are not relayed.
        forwardingRoute = nil
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

    func signalQuiescenceIfNeeded() {
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
        forwardingRoute = nil
        await fence()
        resetLedger()
        ledgerContext = nil
        let task = drainTask
        drainTask = nil
        task?.cancel()
        await task?.value
    }

    // MARK: - Forwarding

    /// Returns the recorded destination of a Telegram reply, when the quoted
    /// message is a card this relay sent for the currently bound chat.
    ///
    /// Only answerable cards are reported. A card without a live destination is
    /// never recorded in the first place; the check is repeated here so the
    /// contract holds for every caller — "a target exists" and "replying to it
    /// routes somewhere" are the same statement.
    func replyTarget(
        forTelegramMessageID messageID: Int,
        chatID: Int64,
        lease: TerminalTelegramRouteLease
    ) async -> TerminalTelegramSharedChatReplyTarget? {
        guard await validateLease(lease) else { return nil }
        guard let context = activeContext,
              context.chatID == chatID,
              context.lease == lease,
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

    // MARK: - Ledger

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
    /// traffic, which is relayed as evidence and must never address the Telegram
    /// user back to themselves — gets **no** target at all: not installed, not
    /// parked. Recording one would make the card look answerable to every caller
    /// that only asks "is this a reply to a card?", such as the voice-note guard,
    /// and would divert an ordinary voice prompt into a refusal.
    func recordReceipt(_ receipt: Int, for card: PendingCard) {
        guard card.target.replyDestination != nil else { return }
        let cardContext = Context(
            roomID: card.target.roomID, chatID: card.chatID, lease: card.lease
        )
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

    /// Writes "already handled" marks for the messages present in the room, in
    /// transcript order, at the tail of the ledger, without queuing a card.
    ///
    /// The marks fit the bound: they come from the room's transcript, so there
    /// are at most `AgentSharedChat.maximumRetainedMessagesPerRoom` of them,
    /// which ``maximumLedgerEntries`` covers (of a longer list only the newest
    /// `maximumLedgerEntries` are kept). An identity already in the ledger moves
    /// to the tail with the others, so afterwards every message the room still
    /// retains sits behind every entry the room no longer holds. The trim that
    /// follows therefore evicts only identities the transcript has dropped
    /// already, which neither the observer's replay nor a poll can offer again,
    /// and never the mark of a message still present. Queued cards keep their
    /// place in the queue: a card already admitted is still delivered, once.
    private func recordPresent(_ messageIDs: [UUID]) {
        var marked = Set<UUID>()
        var ordered: [UUID] = []
        for id in messageIDs.suffix(Self.maximumLedgerEntries) where marked.insert(id).inserted {
            ordered.append(id)
        }
        guard !ordered.isEmpty else { return }
        forwardedOrder.removeAll { marked.contains($0) }
        forwardedOrder.append(contentsOf: ordered)
        forwardedIDs.formUnion(ordered)
        trimLedgerIfNeeded()
    }

    func trimLedgerIfNeeded() {
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
