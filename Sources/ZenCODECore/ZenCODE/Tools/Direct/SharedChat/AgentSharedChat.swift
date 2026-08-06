//
//  AgentSharedChat.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// A bounded, in-memory message bus shared by a coordinator and its delegated
/// agents. It deliberately has no persistence hooks: task graphs remain owned
/// by `SessionTaskOrchestrator`, while this actor exists only for the lifetime
/// of the active backend tree.
public actor AgentSharedChat {
    public static let maximumParticipantsPerRoom = 64
    public static let maximumRetainedMessagesPerRoom = 512
    public static let maximumMailboxMessages = 10
    public static let maximumMessagesPerInjectedPrompt = 5
    public static let maximumMessageLength = 12_000

    public enum ParticipantKind: String, Sendable, Codable {
        case coordinator
        case agent
    }

    public struct Participant: Sendable, Codable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let kind: ParticipantKind
        public let joinedAt: Date
        public var isActive: Bool

        public init(
            id: String,
            name: String,
            kind: ParticipantKind,
            joinedAt: Date = .now,
            isActive: Bool = true
        ) {
            self.id = id
            self.name = name
            self.kind = kind
            self.joinedAt = joinedAt
            self.isActive = isActive
        }
    }

    public struct Message: Sendable, Codable, Equatable, Identifiable {
        public let id: UUID
        public let roomID: String
        public let sender: Participant
        public let recipientIDs: [String]
        public let text: String
        public let sentAt: Date

        init(
            roomID: String,
            sender: Participant,
            recipientIDs: [String],
            text: String
        ) {
            id = UUID()
            self.roomID = roomID
            self.sender = sender
            self.recipientIDs = recipientIDs
            self.text = text
            sentAt = .now
        }
    }

    public enum Destination: Sendable, Equatable {
        /// Exact participant identifiers or active participant names.
        case direct([String])
        case coordinator
        /// Every other active delegated agent, never the sender.
        case peers
        /// The coordinator and every active delegated agent except the sender.
        case all
    }

    public struct Delivery: Sendable, Equatable {
        public let message: Message
        public let recipients: [Participant]
    }

    public enum Error: LocalizedError, Sendable, Equatable {
        case roomParticipantLimitExceeded
        case unknownParticipant(String)
        case noRecipients
        case invalidMessage

        public var errorDescription: String? {
            switch self {
            case .roomParticipantLimitExceeded:
                return "The live shared chat has reached its participant limit."
            case let .unknownParticipant(identifier):
                return "No active shared-chat participant matches '\(identifier)'."
            case .noRecipients:
                return "The shared-chat destination has no active recipients."
            case .invalidMessage:
                return "A shared-chat message must not be empty."
            }
        }
    }

    private struct ParticipantState {
        var participant: Participant
        var mailbox: [Message]
        let onMessageAvailable: (@Sendable () -> Void)?
    }

    private struct Room {
        var participants: [String: ParticipantState] = [:]
        var messages: [Message] = []
    }

    private var rooms: [String: Room] = [:]

    public init() {}

    @discardableResult
    public func registerCoordinator(
        roomID rawRoomID: String,
        name: String = "coordinator",
        onMessageAvailable: (@Sendable () -> Void)? = nil
    ) throws -> Participant {
        let roomID = normalizedRoomID(rawRoomID)
        return try register(
            Participant(
                id: Self.coordinatorID(for: roomID),
                name: name.nilIfBlank ?? "coordinator",
                kind: .coordinator
            ),
            roomID: roomID,
            onMessageAvailable: onMessageAvailable
        )
    }

    @discardableResult
    public func registerAgent(
        id rawID: String,
        name: String,
        roomID rawRoomID: String,
        onMessageAvailable: (@Sendable () -> Void)? = nil
    ) throws -> Participant {
        let id = rawID.nilIfBlank ?? rawID
        guard !id.isEmpty else {
            throw Error.unknownParticipant(rawID)
        }
        return try register(
            Participant(
                id: id,
                name: name.nilIfBlank ?? id,
                kind: .agent
            ),
            roomID: normalizedRoomID(rawRoomID),
            onMessageAvailable: onMessageAvailable
        )
    }

    /// Removes a participant and its mailbox/callback from the live room.
    ///
    /// Messages retain a value snapshot of their sender, so removing a
    /// participant does not alter the bounded transcript used by diagnostics
    /// and live rendering. In contrast, retaining an inactive entry here would
    /// permanently consume one of the room's participant slots.
    public func unregisterParticipant(id: String, roomID rawRoomID: String) {
        let roomID = normalizedRoomID(rawRoomID)
        guard var room = rooms[roomID] else {
            return
        }
        room.participants.removeValue(forKey: id)
        rooms[roomID] = room
    }

    public func participants(
        roomID rawRoomID: String,
        includingInactive: Bool = false
    ) -> [Participant] {
        guard let room = rooms[normalizedRoomID(rawRoomID)] else {
            return []
        }
        return room.participants.values
            .map(\.participant)
            .filter { includingInactive || $0.isActive }
            .sorted(by: Self.participantSortOrder)
    }

    public func messages(roomID rawRoomID: String) -> [Message] {
        rooms[normalizedRoomID(rawRoomID)]?.messages ?? []
    }

    /// Removes at most `limit` messages from one mailbox. It never waits for a
    /// producer or a response, which lets callers safely drain from a wake-up
    /// callback and immediately resume an idle agent.
    public func drain(
        roomID rawRoomID: String,
        participantID: String,
        limit: Int = maximumMailboxMessages
    ) -> [Message] {
        let roomID = normalizedRoomID(rawRoomID)
        guard var room = rooms[roomID], var state = room.participants[participantID] else {
            return []
        }
        let count = min(max(0, limit), state.mailbox.count)
        guard count > 0 else { return [] }
        let result = Array(state.mailbox.prefix(count))
        state.mailbox.removeFirst(count)
        room.participants[participantID] = state
        rooms[roomID] = room
        return result
    }

    @discardableResult
    public func send(
        roomID rawRoomID: String,
        senderID: String,
        destination: Destination,
        text rawText: String
    ) throws -> Delivery {
        let roomID = normalizedRoomID(rawRoomID)
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw Error.invalidMessage
        }
        guard var room = rooms[roomID],
              let senderState = room.participants[senderID],
              senderState.participant.isActive else {
            throw Error.unknownParticipant(senderID)
        }

        let recipientIDs = try resolvedRecipientIDs(
            destination: destination,
            senderID: senderID,
            room: room
        )
        let message = Message(
            roomID: roomID,
            sender: senderState.participant,
            recipientIDs: recipientIDs,
            text: String(text.prefix(Self.maximumMessageLength))
        )

        var callbacks: [(@Sendable () -> Void)] = []
        for id in recipientIDs {
            guard var recipient = room.participants[id] else { continue }
            recipient.mailbox.append(message)
            if recipient.mailbox.count > Self.maximumMailboxMessages {
                recipient.mailbox.removeFirst(recipient.mailbox.count - Self.maximumMailboxMessages)
            }
            if let callback = recipient.onMessageAvailable {
                callbacks.append(callback)
            }
            room.participants[id] = recipient
        }
        room.messages.append(message)
        if room.messages.count > Self.maximumRetainedMessagesPerRoom {
            room.messages.removeFirst(room.messages.count - Self.maximumRetainedMessagesPerRoom)
        }
        rooms[roomID] = room

        // Invoke after committing actor state. The callbacks only schedule
        // asynchronous drains, so `send` remains non-blocking for tool calls.
        for callback in callbacks {
            callback()
        }
        let recipients = recipientIDs.compactMap { room.participants[$0]?.participant }
        return Delivery(message: message, recipients: recipients)
    }

    public static func coordinatorID(for roomID: String) -> String {
        "coordinator:\(roomID)"
    }

    private func register(
        _ participant: Participant,
        roomID: String,
        onMessageAvailable: (@Sendable () -> Void)?
    ) throws -> Participant {
        var room = rooms[roomID] ?? Room()
        if var existing = room.participants[participant.id] {
            existing.participant.isActive = true
            // A backend can be rebuilt while its transient shared chat survives.
            // Replacing the callback reconnects its mailbox to the new owner.
            room.participants[participant.id] = ParticipantState(
                participant: existing.participant,
                mailbox: existing.mailbox,
                onMessageAvailable: onMessageAvailable
            )
            rooms[roomID] = room
            return existing.participant
        }
        guard room.participants.count < Self.maximumParticipantsPerRoom else {
            throw Error.roomParticipantLimitExceeded
        }
        room.participants[participant.id] = ParticipantState(
            participant: participant,
            mailbox: [],
            onMessageAvailable: onMessageAvailable
        )
        rooms[roomID] = room
        return participant
    }

    private func resolvedRecipientIDs(
        destination: Destination,
        senderID: String,
        room: Room
    ) throws -> [String] {
        let active = room.participants.values
            .map(\.participant)
            .filter(\.isActive)
        let recipients: [Participant]
        switch destination {
        case let .direct(identifiers):
            var seen = Set<String>()
            recipients = try identifiers.map { identifier in
                guard let participant = resolveParticipant(identifier, in: active) else {
                    throw Error.unknownParticipant(identifier)
                }
                return participant
            }
            .filter { $0.id != senderID && seen.insert($0.id).inserted }
        case .coordinator:
            recipients = active.filter { $0.kind == .coordinator && $0.id != senderID }
        case .peers:
            recipients = active.filter { $0.kind == .agent && $0.id != senderID }
        case .all:
            recipients = active.filter { $0.id != senderID }
        }
        guard !recipients.isEmpty else {
            throw Error.noRecipients
        }
        return recipients.map(\.id).sorted()
    }

    private func resolveParticipant(
        _ rawIdentifier: String,
        in participants: [Participant]
    ) -> Participant? {
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }
        if let exact = participants.first(where: { $0.id == identifier }) {
            return exact
        }
        let folded = identifier.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return participants.first {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == folded
        }
    }

    private func normalizedRoomID(_ rawValue: String) -> String {
        rawValue.nilIfBlank ?? "default"
    }

    private static func participantSortOrder(_ lhs: Participant, _ rhs: Participant) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind == .coordinator
        }
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return order == .orderedAscending || (order == .orderedSame && lhs.id < rhs.id)
    }
}
