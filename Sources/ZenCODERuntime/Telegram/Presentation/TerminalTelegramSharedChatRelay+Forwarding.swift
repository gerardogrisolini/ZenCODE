//
//  TerminalTelegramSharedChatRelay+Forwarding.swift
//  ZenCODE
//
//  The card pipeline of the shared-chat relay: admission of an observer
//  batch, card rendering, the bounded queue with its backpressure, and the
//  drain that delivers each card.
//

import Foundation
import ToolCore

extension TerminalTelegramSharedChatRelay {
    // MARK: - Forwarding

    /// Offers one observer batch. Every message in the active room is relayed:
    /// operator-originated traffic, coordinator ↔ agent traffic, peer traffic,
    /// direct multi-recipient traffic and broadcasts are all visible. The
    /// messages the room already held when the relay started forwarding it are
    /// in the ledger already (``markPresent(_:roomID:generation:)``), so they
    /// are skipped like any identity already delivered.
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
                    lease: liveContext.lease,
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
    func grantCapacityToWaitersIfPossible() {
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

    /// Number of identities the ledger holds: the cards admitted so far plus
    /// the messages marked present (``markPresent(_:roomID:generation:)``),
    /// within ``maximumLedgerEntries``.
    ///
    /// Read by tests only while the relay is provably quiescent (transport gated,
    /// producers parked), where, with nothing marked, it is exactly the number of
    /// cards admitted.
    var ledgerEntryCount: Int {
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
        if await validateLease(card.lease) == false {
            inFlightDeliveries -= 1
            signalQuiescenceIfNeeded()
            return
        }
        // Validation suspends, so the relay generation must be checked again
        // before the wire call.
        guard card.generation == generation, activeContext?.lease == card.lease else {
            inFlightDeliveries -= 1
            signalQuiescenceIfNeeded()
            return
        }
        let receipt = await send(card.text, card.chatID, card.lease)
        inFlightDeliveries -= 1
        signalQuiescenceIfNeeded()
        guard let receipt else {
            // Ambiguous or failed delivery: never retried, so the card is simply
            // not answerable from Telegram.
            return
        }
        recordReceipt(receipt, for: card)
    }
}
