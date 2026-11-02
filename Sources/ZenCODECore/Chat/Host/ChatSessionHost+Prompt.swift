//
//  ChatSessionHost+Prompt.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation
import Synchronization

/// One prompt per incarnation. The reservation is taken, checked, and
/// released in single calls of the host, each atomic on ``ChatSessionActor``:
/// a channel in another isolation domain (the ACP bridge actor) awaits them,
/// but never splits a check and the write that depends on it across its own
/// suspension. Late work compares its reservation with the live one
/// (``holdsPrompt(_:)``) and a replaced or closed incarnation is never
/// matched, because its slot runs another epoch, or none.
extension ChatSessionHost {
    // MARK: - Prompt reservation

    /// Reserves the right to run one prompt on the session `slotID` runs now.
    /// Throws `.sessionBusy` while a prompt or a reconfiguration is reserved,
    /// `.noSession` or `.unknownSlot` when there is nothing to prompt (a slot
    /// retired for its close included, see
    /// ``retireIncarnation(in:controller:)``), and `.shutDown` after
    /// ``shutdown()`` or once ``beginShutdown()`` announced it.
    public func reservePrompt(in slotID: ChatSlotID) throws(ChatSessionHostError) -> ChatPromptReservation {
        try reserveIncarnation(in: slotID).reservation
    }

    /// ``reservePrompt(in:)``, returning with the reservation the slot and
    /// the incarnation it reserved, read in the same step.
    func reserveIncarnation(
        in slotID: ChatSlotID
    ) throws(ChatSessionHostError) -> (
        slot: ChatSlot, incarnation: ChatSessionIncarnation, reservation: ChatPromptReservation
    ) {
        guard !isShutDown, !retirement.isShuttingDown else { throw .shutDown }
        guard let slot = slots[slotID] else { throw .unknownSlot }
        guard !retirement.isRetired(slotID), var incarnation = slot.incarnation else { throw .noSession }
        guard incarnation.activePromptID == nil, incarnation.operationState == .idle else {
            throw .sessionBusy
        }
        let promptID = UUID()
        incarnation.activePromptID = promptID
        incarnation.operationState = .prompting(promptID)
        slot.incarnation = incarnation
        let reservation = ChatPromptReservation(
            slotID: slotID,
            sessionID: incarnation.sessionID,
            epoch: incarnation.epoch,
            promptID: promptID
        )
        return (slot, incarnation, reservation)
    }

    /// Releases `reservation` when it is still the live one of its
    /// incarnation, and returns whether it was. A reservation already
    /// cancelled, or belonging to an incarnation that ended, is left alone.
    @discardableResult
    public func releasePrompt(_ reservation: ChatPromptReservation) -> Bool {
        guard let slot = slots[reservation.slotID],
              var incarnation = reservedIncarnation(reservation) else {
            return false
        }
        incarnation.activePromptID = nil
        incarnation.operationState = .idle
        slot.incarnation = incarnation
        return true
    }

    /// `true` while `reservation` is the live reservation of the live
    /// incarnation of its slot.
    public func holdsPrompt(_ reservation: ChatPromptReservation) -> Bool {
        reservedIncarnation(reservation) != nil
    }

    /// Runs `body` with the incarnation only while `reservation` holds, in
    /// the same step as the check, and returns its result; `nil` otherwise,
    /// without running `body`.
    public func withReservedIncarnation<Result>(
        _ reservation: ChatPromptReservation,
        _ body: (ChatSessionIncarnation) throws -> Result
    ) rethrows -> Result? {
        guard let incarnation = reservedIncarnation(reservation) else { return nil }
        return try body(incarnation)
    }

    /// Runs `body` with the incarnation only while `slotID` still runs the
    /// incarnation `epoch`, in the same step as the check, and returns its
    /// result; `nil` otherwise, without running `body`. For the writes of
    /// work that suspended: a closed or replaced incarnation is never
    /// written into.
    public func withLiveIncarnation<Result>(
        _ slotID: ChatSlotID,
        epoch: UInt64,
        _ body: (ChatSessionIncarnation) throws -> Result
    ) rethrows -> Result? {
        guard let incarnation = liveIncarnation(in: slotID, epoch: epoch) else { return nil }
        return try body(incarnation)
    }

    /// The incarnation `epoch` of `slotID`, while the slot runs it and the
    /// host is not shut down.
    func liveIncarnation(in slotID: ChatSlotID, epoch: UInt64) -> ChatSessionIncarnation? {
        guard !isShutDown,
              let incarnation = slots[slotID]?.incarnation,
              incarnation.epoch == epoch else {
            return nil
        }
        return incarnation
    }

    /// The incarnation of `reservation`, while the reservation holds.
    func reservedIncarnation(_ reservation: ChatPromptReservation) -> ChatSessionIncarnation? {
        guard let incarnation = liveIncarnation(in: reservation.slotID, epoch: reservation.epoch),
              incarnation.activePromptID == reservation.promptID,
              incarnation.operationState == .prompting(reservation.promptID) else {
            return nil
        }
        return incarnation
    }

    /// The prompt reserved on the incarnation `epoch` of `slotID`, if any.
    func activePromptID(in slotID: ChatSlotID, epoch: UInt64) -> UUID? {
        liveIncarnation(in: slotID, epoch: epoch)?.activePromptID
    }

    /// The prompt reserved on the session `slotID` runs now, if any.
    func activePromptID(in slotID: ChatSlotID) -> UUID? {
        guard !isShutDown else { return nil }
        return slots[slotID]?.incarnation?.activePromptID
    }

    /// The prompts reserved on the incarnations `bindings` names (slot to
    /// epoch), by slot, read in one step for a caller that must capture them
    /// before it suspends. Incarnations that are not live have no entry.
    func activePromptIDs(in bindings: [ChatSlotID: UInt64]) -> [ChatSlotID: UUID] {
        var promptIDs: [ChatSlotID: UUID] = [:]
        for (slotID, epoch) in bindings {
            if let promptID = activePromptID(in: slotID, epoch: epoch) {
                promptIDs[slotID] = promptID
            }
        }
        return promptIDs
    }

    // MARK: - Cancel

    /// Cancels the prompt reserved on the session `slotID` runs now: the
    /// controller's turn is fenced (it can no longer write session state
    /// back) and the reservation is dropped, in one step, so the next prompt
    /// can be reserved at once. Returns the id of the cancelled prompt, or
    /// `nil` when none was reserved; the controller is fenced either way.
    ///
    /// `armingWorkflowRecovery` decides, for the cancelled prompt, whether a
    /// `/goal` workflow it was running is armed for recovery (see
    /// ``ChatSessionController/cancelActiveTurn(armingWorkflowRecovery:)``).
    ///
    /// A reconfiguration is not a prompt and is left to its owner.
    @discardableResult
    public func cancelPrompt(
        in slotID: ChatSlotID,
        armingWorkflowRecovery: (UUID) -> Bool = { _ in false }
    ) -> UUID? {
        guard !isShutDown, let slot = slots[slotID], var incarnation = slot.incarnation else {
            return nil
        }
        let cancelledPromptID = incarnation.activePromptID
        incarnation.controller.cancelActiveTurn(
            armingWorkflowRecovery: cancelledPromptID.map(armingWorkflowRecovery) ?? false
        )
        incarnation.activePromptID = nil
        if case .prompting = incarnation.operationState {
            incarnation.operationState = .idle
        }
        slot.incarnation = incarnation
        return cancelledPromptID
    }

    /// ``cancelPrompt(in:armingWorkflowRecovery:)`` for the prompt `promptID`
    /// only: the controller is fenced and the reservation dropped while
    /// `promptID` is the prompt reserved on the session `slotID` runs now;
    /// otherwise nothing happens, so a prompt reserved after `promptID` was
    /// released (by a cancel of its own) keeps its turn and its reservation.
    /// Returns whether it cancelled.
    @discardableResult
    func cancelPrompt(_ promptID: UUID, in slotID: ChatSlotID) -> Bool {
        guard activePromptID(in: slotID) == promptID else { return false }
        return cancelPrompt(in: slotID) == promptID
    }

    // MARK: - Reconfiguration

    /// Reserves the right to reconfigure the session `slotID` runs now, which
    /// no prompt can be reserved on meanwhile. Same failures as
    /// ``reservePrompt(in:)``.
    func reserveReconfiguration(
        in slotID: ChatSlotID
    ) throws(ChatSessionHostError) -> ChatReconfigurationReservation {
        guard !isShutDown, !retirement.isShuttingDown else { throw .shutDown }
        guard let slot = slots[slotID] else { throw .unknownSlot }
        guard !retirement.isRetired(slotID), var incarnation = slot.incarnation else { throw .noSession }
        guard incarnation.activePromptID == nil, incarnation.operationState == .idle else {
            throw .sessionBusy
        }
        let reconfigurationID = UUID()
        incarnation.operationState = .reconfiguring(reconfigurationID)
        slot.incarnation = incarnation
        return ChatReconfigurationReservation(
            slotID: slotID,
            sessionID: incarnation.sessionID,
            epoch: incarnation.epoch,
            reconfigurationID: reconfigurationID
        )
    }

    /// `true` while `reservation` is the live reservation of the live
    /// incarnation of its slot.
    func holdsReconfiguration(_ reservation: ChatReconfigurationReservation) -> Bool {
        guard let incarnation = liveIncarnation(in: reservation.slotID, epoch: reservation.epoch) else {
            return false
        }
        return incarnation.operationState == .reconfiguring(reservation.reconfigurationID)
    }

    /// Releases `reservation` when it is still the live one, and returns
    /// whether it was.
    @discardableResult
    func releaseReconfiguration(_ reservation: ChatReconfigurationReservation) -> Bool {
        guard let slot = slots[reservation.slotID],
              var incarnation = slot.incarnation,
              holdsReconfiguration(reservation) else {
            return false
        }
        incarnation.operationState = .idle
        slot.incarnation = incarnation
        return true
    }

    // MARK: - Retirement

    /// Retires the session `slotID` runs, for a channel that closes the slot
    /// only after it suspended (ACP's `session/close` drains the prompts of
    /// the session first): `controller`, the incarnation's, is fenced, so a
    /// turn still running cannot write session state back, and from this call
    /// on no prompt, reconfiguration, or replacement is reserved on the slot
    /// (``reservePrompt(in:)``, a turn of the slot's Telegram channel
    /// included, answers `.noSession`). What is reserved already stays, for
    /// its owner to release; the slot, its incarnation, and its Telegram
    /// channel live until ``closeSlot(_:runtimeSession:)``.
    ///
    /// It does not suspend and runs in any isolation domain, so a channel
    /// actor calls it in the same step in which it stops knowing the session,
    /// before its first suspension.
    nonisolated func retireIncarnation(in slotID: ChatSlotID, controller: ChatSessionController) {
        controller.cancelActiveTurn()
        retirement.retire(slotID)
    }

    /// Announces ``shutdown()`` to a channel that shuts the host down only
    /// after it suspended (ACP's `shutdown` closes its transport first): from
    /// this call on no prompt, reconfiguration, or replacement is reserved on
    /// any slot (they answer `.shutDown`). Like
    /// ``retireIncarnation(in:controller:)``, it does not suspend and runs in
    /// any isolation domain; fencing the controllers is the caller's.
    nonisolated func beginShutdown() {
        retirement.beginShutdown()
    }
}

/// What ``ChatSessionHost/retireIncarnation(in:controller:)`` and
/// ``ChatSessionHost/beginShutdown()`` latch, under a lock: they are called
/// from another isolation domain without suspending, and every reservation
/// reads it on ``ChatSessionActor``.
final class ChatSlotRetirement: Sendable {
    private struct State {
        var isShuttingDown = false
        var retiredSlotIDs: Set<ChatSlotID> = []
    }

    private let state = Mutex(State())

    init() {}

    /// `true` once ``beginShutdown()`` ran.
    var isShuttingDown: Bool {
        state.withLock { $0.isShuttingDown }
    }

    /// Whether `slotID` was retired and not closed yet.
    func isRetired(_ slotID: ChatSlotID) -> Bool {
        state.withLock { $0.retiredSlotIDs.contains(slotID) }
    }

    func retire(_ slotID: ChatSlotID) {
        state.withLock { _ = $0.retiredSlotIDs.insert(slotID) }
    }

    func beginShutdown() {
        state.withLock { $0.isShuttingDown = true }
    }

    /// Forgets a retired slot once it is closed: its id is unknown from now
    /// on, so nothing reads the entry again.
    func forget(_ slotID: ChatSlotID) {
        state.withLock { _ = $0.retiredSlotIDs.remove(slotID) }
    }
}
