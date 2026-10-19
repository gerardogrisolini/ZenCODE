//
//  AgentSharedChatCoordinator+Inspection.swift
//  ZenCODE
//

import Foundation

extension AgentSharedChatCoordinator {
    func room(roomID rawRoomID: String) -> Room? {
        rooms[Self.normalizedRoomID(rawRoomID)]
    }

    // MARK: - Introspection (diagnostics and tests)

    func pendingMessageCount(roomID rawRoomID: String) -> Int {
        room(roomID: rawRoomID)?.pending.count ?? 0
    }
    func activeAutoTriggerID(roomID rawRoomID: String) -> UUID? {
        room(roomID: rawRoomID)?.activeTrigger?.id
    }
    func activeAutoTrigger(roomID rawRoomID: String) -> AgentSharedChatAutoTrigger? {
        room(roomID: rawRoomID)?.activeTrigger
    }
    func activeAutoTriggerMessageCount(roomID rawRoomID: String) -> Int {
        room(roomID: rawRoomID)?.activeTrigger?.messages.count ?? 0
    }
    /// Parked, offered and claimed messages, read in one actor step.
    func retainedMessageCount(roomID rawRoomID: String) -> Int {
        guard let room = room(roomID: rawRoomID) else { return 0 }
        return room.pending.count
            + (room.activeTrigger?.messages.count ?? 0)
            + (room.claim?.messages.count ?? 0)
    }
    func claimedAutoTriggerOwnerID(roomID rawRoomID: String) -> UUID? {
        room(roomID: rawRoomID)?.claim?.owner
    }
    /// A consumed batch lives inside a running generation and must never be requeued.
    func hasConsumedClaim(roomID rawRoomID: String) -> Bool {
        room(roomID: rawRoomID)?.claim?.isConsumed ?? false
    }
    func turnsInFlight(roomID rawRoomID: String) -> Int {
        room(roomID: rawRoomID)?.turnsInFlight ?? 0
    }
    func isAwaitingSourceRebuild(roomID rawRoomID: String) -> Bool {
        room(roomID: rawRoomID)?.isAwaitingSourceRebuild ?? false
    }
    func busyObserverCount(roomID rawRoomID: String) -> Int {
        room(roomID: rawRoomID)?.busyObservers.count ?? 0
    }
    func isTrackingRoom(roomID rawRoomID: String) -> Bool {
        room(roomID: rawRoomID) != nil
    }
    func droppedEventCount(roomID rawRoomID: String) -> Int {
        room(roomID: rawRoomID)?.droppedEventCount ?? 0
    }
    func isMonitoring(roomID rawRoomID: String) -> Bool {
        room(roomID: rawRoomID)?.monitorTask != nil
    }

}
