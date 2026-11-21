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
    func activeAutoTrigger(roomID rawRoomID: String) -> AgentSharedChatAutoTrigger? {
        room(roomID: rawRoomID)?.activeTrigger
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
    func isTrackingRoom(roomID rawRoomID: String) -> Bool {
        room(roomID: rawRoomID) != nil
    }
    func isMonitoring(roomID rawRoomID: String) -> Bool {
        room(roomID: rawRoomID)?.monitorTask != nil
    }

}
