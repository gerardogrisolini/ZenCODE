//
//  AgentSharedChatCoordinator+State.swift
//  ZenCODE
//

import Foundation

extension AgentSharedChatCoordinator {
    /// One synthetic turn owned by exactly one observer.
    ///
    /// A claim is bound to the turn that *consumes* it. The trigger prompt is
    /// minted by the Core for this batch alone and every consumer injects it
    /// verbatim, so the turn carrying exactly that text is the turn this claim
    /// was granted for. Until such a turn starts the claim is unconsumed and
    /// its batch is still owed to the queue; afterwards the batch lives inside
    /// the running generation, where requeueing it would duplicate it and an
    /// unrelated turn ending must not release it.
    struct Claim {
        let triggerID: UUID
        let owner: UUID
        let messages: [AgentSharedChat.Message]
        /// Core-minted prompt of the trigger: the binding key for its turn.
        let prompt: String
        /// The turn that injected this batch, once one started.
        var consumingTurnID: UUID?

        var isConsumed: Bool { consumingTurnID != nil }
    }

    /// Identity of one turn tracked by the coordinator.
    ///
    /// ``noteTurnStarted(roomID:prompt:)`` mints it and ``noteTurnEnded(_:)``
    /// consumes it, so ending a turn can only ever end *that* turn: a repeated
    /// end is idempotent instead of double-decrementing the room, and one turn
    /// can never release the claim another turn owns.
    struct TurnToken: Sendable, Hashable {
        let id: UUID
        let roomID: String
    }

    /// Capability returned by ``beginReset(roomID:)``.
    ///
    /// It names the room *and* the suspension it opened, so a late or repeated
    /// resume cannot re-arm a room that a newer reset, stop or replacement
    /// already owns.
    struct ResetToken: Sendable, Hashable {
        let roomID: String
        let generation: UInt64
    }

    /// Whether a released claim still owes its batch to the queue.
    enum ClaimRelease {
        /// Return the batch to the head of the queue *unless* a turn already
        /// consumed it. Requeueing a consumed batch would inject it twice.
        case requeueingUnconsumedBatch
        /// The claimant keeps the batch: it received the trigger and answered
        /// for it, so the queue no longer owes it a turn.
        case keepingBatch
    }

    struct Room {
        /// Monotonic identity of this room *instance*: a poll suspended on the
        /// backend uses it to detect that its room was retired or replaced under
        /// the same id, and aborts instead of resurrecting it.
        var generation: UInt64
        var pending: [AgentSharedChat.Message] = []
        /// Published and not yet claimed. Any observer may claim or decline it.
        var activeTrigger: AgentSharedChatAutoTrigger?
        /// Claimed turn. Only its owner can release it; every other observer
        /// sees the room as busy until it does.
        var claim: Claim?
        /// Turns observed by the Core itself (`AgentCoreSessionRunner.sendPrompt`),
        /// keyed by turn identity so an end releases exactly the turn it names.
        var activeTurns: Set<UUID> = []
        /// Set between ``beginReset(roomID:)`` and ``endReset(_:)``: the source
        /// this room drains is being rebuilt, so neither a drain nor an offer
        /// may run against a backend that is about to be cleared.
        var isAwaitingSourceRebuild = false
        /// Busy state declared per observer, covering the window between a
        /// queued prompt and its actual turn start. One observer reporting
        /// itself idle can never clear another observer's declaration.
        var busyObservers: Set<UUID> = []
        var participantSignature: [String]?
        var subscribers: [UUID: AsyncStream<AgentSharedChatCoordinatorEvent>.Continuation] = [:]
        var monitorTask: Task<Void, Never>?
        var tickerTask: Task<Void, Never>?
        var signal: AsyncStream<Void>.Continuation?
        /// Single-flight guard around the asynchronous drain itself.
        var isPolling = false
        var pollRequested = false
        /// Set when a subscriber buffer evicted an event, so the next poll can
        /// re-offer an outstanding trigger that may have been evicted with it.
        var needsTriggerReoffer = false
        /// Set when a subscriber buffer evicted an event, so the next poll
        /// re-publishes the roster even when its signature did not change.
        var needsParticipantsReemit = false
        var triggerReofferCount = 0
        var droppedEventCount = 0
        /// Message IDs enqueued or delivered to each observer, per observer so a
        /// new subscriber's replay never decides what an older one has seen.
        /// Intersected with the bounded transcript after every poll; an evicted
        /// `.messages` event removes only its own IDs (see ``recordYieldResult``).
        var enqueuedMessageIDsBySubscriber: [UUID: Set<UUID>] = [:]

        var turnsInFlight: Int { activeTurns.count }

        var isBusy: Bool {
            !activeTurns.isEmpty || !busyObservers.isEmpty || claim != nil
        }

        mutating func cancelMonitor() {
            monitorTask?.cancel()
            monitorTask = nil
            tickerTask?.cancel()
            tickerTask = nil
            signal?.finish()
            signal = nil
        }
    }
}
