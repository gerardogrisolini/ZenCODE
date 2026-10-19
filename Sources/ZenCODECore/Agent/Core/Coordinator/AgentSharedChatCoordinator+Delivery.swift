//
//  AgentSharedChatCoordinator+Delivery.swift
//  ZenCODE
//

import Foundation

extension AgentSharedChatCoordinator {
    /// Prunes every observer ledger to the live bounded transcript, then offers
    /// each observer only the IDs it still lacks. This is the recovery path after
    /// a dropped `.messages` event (see `recordYieldResult`).
    func deliverTranscript(
        _ messages: [AgentSharedChat.Message],
        roomID: String
    ) {
        guard var room = rooms[roomID] else { return }
        let retainedMessageIDs = Set(messages.map(\.id))
        var prunedLedger: [UUID: Set<UUID>] = [:]
        for (subscriberID, deliveredIDs) in room.enqueuedMessageIDsBySubscriber {
            guard room.subscribers[subscriberID] != nil else { continue }
            let retainedDeliveredIDs = deliveredIDs.intersection(retainedMessageIDs)
            if !retainedDeliveredIDs.isEmpty {
                prunedLedger[subscriberID] = retainedDeliveredIDs
            }
        }
        room.enqueuedMessageIDsBySubscriber = prunedLedger
        rooms[roomID] = room
        emitMessages(messages, roomID: roomID)
    }

    /// Offers message IDs to one observer or every observer in a room. Each
    /// stream is sent only the IDs absent from its own ledger; shared by mailbox
    /// ingestion, transcript polling, attach-time replay and overflow recovery.
    func emitMessages(
        _ messages: [AgentSharedChat.Message],
        roomID: String,
        onlyTo subscriberID: UUID? = nil
    ) {
        guard !messages.isEmpty, var room = rooms[roomID] else { return }
        let subscriberIDs = subscriberID.map { [$0] } ?? Array(room.subscribers.keys)
        for id in subscriberIDs {
            guard let continuation = room.subscribers[id] else { continue }
            var knownIDs = room.enqueuedMessageIDsBySubscriber[id] ?? []
            // Also keeps a malformed source from repeating an ID within one event.
            let dueMessages = messages.filter { message in
                knownIDs.insert(message.id).inserted
            }
            guard !dueMessages.isEmpty else { continue }
            recordYieldResult(
                continuation.yield(.messages(dueMessages)),
                enqueuing: .messages(dueMessages),
                for: id,
                in: &room
            )
        }
        rooms[roomID] = room
    }

    /// Publishes an event to one observer or every observer. A trigger or roster
    /// update may evict an older `.messages` event, so yield bookkeeping lives here too.
    func emit(
        _ event: AgentSharedChatCoordinatorEvent,
        roomID: String,
        onlyTo subscriberID: UUID? = nil
    ) {
        if case let .messages(messages) = event {
            emitMessages(messages, roomID: roomID, onlyTo: subscriberID)
            return
        }
        guard var room = rooms[roomID] else { return }
        let subscriberIDs = subscriberID.map { [$0] } ?? Array(room.subscribers.keys)
        for id in subscriberIDs {
            guard let continuation = room.subscribers[id] else { continue }
            recordYieldResult(
                continuation.yield(event),
                enqueuing: event,
                for: id,
                in: &room
            )
        }
        rooms[roomID] = room
    }

    /// Records exactly what `AsyncStream` accepted. With `.bufferingNewest`, a
    /// `.dropped(consumed:)` result means the fresh event is still enqueued and
    /// the *consumed* older event is the one that became unavailable. Therefore
    /// the old event's IDs become due again before the fresh event's IDs are
    /// marked, preserving the fresh mark even if malformed input reused an ID.
    /// A terminated continuation receives no acknowledgement at all.
    func recordYieldResult(
        _ result: AsyncStream<AgentSharedChatCoordinatorEvent>.Continuation.YieldResult,
        enqueuing event: AgentSharedChatCoordinatorEvent,
        for subscriberID: UUID,
        in room: inout Room
    ) {
        switch result {
        case .enqueued:
            markMessageIDs(in: event, for: subscriberID, in: &room)
        case let .dropped(consumed: evicted):
            room.droppedEventCount += 1
            room.needsTriggerReoffer = true
            room.needsParticipantsReemit = true
            makeMessageIDsRecoverable(in: evicted, for: subscriberID, in: &room)
            markMessageIDs(in: event, for: subscriberID, in: &room)
        case .terminated:
            // `onTermination` performs the teardown; a terminated stream is never delivered.
            room.enqueuedMessageIDsBySubscriber.removeValue(forKey: subscriberID)
        @unknown default:
            break
        }
    }

    func markMessageIDs(
        in event: AgentSharedChatCoordinatorEvent,
        for subscriberID: UUID,
        in room: inout Room
    ) {
        guard case let .messages(messages) = event, !messages.isEmpty else { return }
        room.enqueuedMessageIDsBySubscriber[subscriberID, default: []]
            .formUnion(messages.map(\.id))
    }

    func makeMessageIDsRecoverable(
        in event: AgentSharedChatCoordinatorEvent,
        for subscriberID: UUID,
        in room: inout Room
    ) {
        guard case let .messages(messages) = event, !messages.isEmpty,
              var deliveredIDs = room.enqueuedMessageIDsBySubscriber[subscriberID] else {
            return
        }
        deliveredIDs.subtract(messages.map(\.id))
        if deliveredIDs.isEmpty {
            room.enqueuedMessageIDsBySubscriber.removeValue(forKey: subscriberID)
        } else {
            room.enqueuedMessageIDsBySubscriber[subscriberID] = deliveredIDs
        }
    }

    /// The single teardown path for one observer, shared by explicit detach and
    /// by stream termination. It releases exactly the state this observer owns.
    func releaseSubscriber(
        _ id: UUID,
        roomID: String,
        finishesStream: Bool
    ) {
        guard var room = rooms[roomID], room.subscribers[id] != nil else { return }
        let continuation = room.subscribers.removeValue(forKey: id)
        room.busyObservers.remove(id)
        room.enqueuedMessageIDsBySubscriber.removeValue(forKey: id)
        // A claim whose turn never started is requeued; a consumed one is not, so a
        // mid-generation detach cannot duplicate it.
        if room.claim?.owner == id {
            releaseClaim(&room, .requeueingUnconsumedBatch)
        }
        if room.subscribers.isEmpty {
            // Nobody can run a synthetic turn anymore: keep the batch for the next consumer.
            requeueActiveTrigger(&room)
            releaseClaim(&room, .requeueingUnconsumedBatch)
            room.cancelMonitor()
            room.busyObservers.removeAll()
        }
        rooms[roomID] = room
        if finishesStream {
            // Finishing after the removal keeps `onTermination` a no-op.
            continuation?.finish()
        }
        evaluate(roomID: roomID)
        requestPoll(roomID: roomID)
    }
}
