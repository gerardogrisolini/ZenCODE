//
//  AgentSharedChatCoordinator+Monitor.swift
//  ZenCODE
//
//  The monitor cycle of a shared chat room: bounded, generation-fenced drains
//  of the coordinator mailbox, ingestion of participants and messages, and
//  trigger re-offers.
//

import Foundation

extension AgentSharedChatCoordinator {
    /// Wakes the monitor immediately instead of waiting for the next tick. A
    /// room whose source is being rebuilt stays parked: ``endReset(_:)`` is the
    /// only thing that may re-arm it.
    public func requestPoll(roomID rawRoomID: String) {
        let roomID = Self.normalizedRoomID(rawRoomID)
        guard rooms[roomID]?.isAwaitingSourceRebuild != true else { return }
        rooms[roomID]?.signal?.yield()
    }

    /// Performs one drain/evaluate cycle. Exposed for deterministic tests; the
    /// production monitor calls exactly the same body.
    ///
    /// Three guarantees are encoded here. *Fairness*: the drain loop is bounded
    /// by ``maximumDrainRoundsPerPoll``, and leftover work re-arms the monitor
    /// instead of holding the actor. *Generation fencing*: every suspension is
    /// followed by a check that the room instance this poll started on is still
    /// the live one, performed *before* the next suspension, so a poll that
    /// resumes into a reset, a teardown or a replacement room never consumes
    /// the mailbox of an instance it does not speak for. *Rebuild fencing*: a
    /// room whose source is being rebuilt is not polled at all.
    func poll(roomID rawRoomID: String) async {
        let roomID = Self.normalizedRoomID(rawRoomID)
        guard let room = rooms[roomID], !room.isAwaitingSourceRebuild else { return }
        let generation = room.generation
        guard !room.isPolling else {
            // Coalesce instead of starting a second drain that could double-emit a trigger.
            rooms[roomID]?.pollRequested = true
            return
        }
        rooms[roomID]?.isPolling = true
        defer {
            // A room recreated under the same id owns its own single-flight flag.
            if rooms[roomID]?.generation == generation {
                rooms[roomID]?.isPolling = false
            }
        }

        var rounds = 0
        repeat {
            rounds += 1
            rooms[roomID]?.pollRequested = false
            let participants = await source.participants(roomID)
            // The drain below is destructive, so fence before it: a stale poll must never drain.
            guard rooms[roomID]?.generation == generation else {
                // The live instance owns that mailbox: wake it.
                requestPoll(roomID: roomID)
                return
            }
            // While a coordinator turn is active its direct-tool executor owns this
            // mailbox; stealing the batch into `pending` would delay the reply.
            // `noteTurnEnded` re-arms the poll as the lossless fallback.
            let drained: [AgentSharedChat.Message]
            if rooms[roomID]?.activeTurns.isEmpty ?? true {
                drained = await source.drainCoordinatorMessages(roomID)
                guard rooms[roomID]?.generation == generation else { return }
            } else {
                drained = []
            }
            ingest(participants: participants, messages: drained, roomID: roomID)
            // Agent-to-agent messages never enter the coordinator mailbox. The
            // read-only transcript source returns the full
            // bounded history; `deliverTranscript` filters it independently for
            // each observer, so a new observer's replay can never affect an
            // existing observer's delivery.
            let allMessages = await source.allRoomMessages(roomID)
            guard rooms[roomID]?.generation == generation else { return }
            // Also the recovery path after a dropped `.messages` event: only the
            // affected observer is re-sent its evicted IDs.
            deliverTranscript(allMessages, roomID: roomID)
            if !drained.isEmpty {
                // Keep pulling until the mailbox is empty; the next round re-checks the fence.
                rooms[roomID]?.pollRequested = true
            }
        } while rooms[roomID]?.pollRequested == true && rounds < Self.maximumDrainRoundsPerPoll

        guard rooms[roomID]?.generation == generation else { return }
        // Evaluate only after the bounded drain: a trigger emitted mid-drain would race the rest of the burst.
        evaluate(roomID: roomID)
        reofferActiveTriggerIfNeeded(roomID: roomID)
        if rooms[roomID]?.pollRequested == true {
            // Budget spent with work still queued: drain the remainder in a later round.
            requestPoll(roomID: roomID)
        }
    }

    /// Republishes an outstanding trigger after a subscriber buffer evicted
    /// events. Claiming is keyed by trigger id, so a re-offer is idempotent:
    /// a consumer that already saw it simply gets `notAcquired`.
    private func reofferActiveTriggerIfNeeded(roomID: String) {
        guard var room = rooms[roomID], room.needsTriggerReoffer else { return }
        room.needsTriggerReoffer = false
        guard let trigger = room.activeTrigger, !room.subscribers.isEmpty else {
            rooms[roomID] = room
            return
        }
        guard room.triggerReofferCount < Self.maximumAutoTriggerReoffers else {
            // Budget exhausted: an unanswered offer must not stay parked in front of
            // the queue; the next idle evaluation mints a fresh trigger and budget.
            requeueActiveTrigger(&room)
            rooms[roomID] = room
            evaluate(roomID: roomID)
            return
        }
        room.triggerReofferCount += 1
        rooms[roomID] = room
        emit(.autoTrigger(trigger), roomID: roomID)
    }

    private func ingest(
        participants: [AgentSharedChat.Participant],
        messages: [AgentSharedChat.Message],
        roomID: String
    ) {
        // Never recreate a room here: a drain that outlived its room must not resurrect it.
        guard var room = rooms[roomID] else { return }
        let signature = participants.map { "\($0.id)|\($0.name)|\($0.isActive)" }
        // An empty first observation is not a change.
        let participantsChanged = room.needsParticipantsReemit
            || (room.participantSignature != signature
                && !(room.participantSignature == nil && signature.isEmpty))
        room.needsParticipantsReemit = false
        room.participantSignature = signature
        if !messages.isEmpty {
            room.pending.append(contentsOf: messages)
            if room.pending.count > Self.maximumPendingMessages {
                room.pending.removeFirst(room.pending.count - Self.maximumPendingMessages)
            }
        }
        rooms[roomID] = room

        if participantsChanged {
            emit(.participantsChanged(participants), roomID: roomID)
        }
        if !messages.isEmpty {
            emitMessages(messages, roomID: roomID)
        }
    }
}
