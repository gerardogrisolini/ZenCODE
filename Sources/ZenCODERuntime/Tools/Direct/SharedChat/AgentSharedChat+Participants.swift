//
//  AgentSharedChat+Participants.swift
//  ZenCODE
//
//  Participant, message, destination, and error types of the shared chat,
//  plus the static identity helpers for coordinators, the operator, and
//  transcripts.
//

import Foundation
import Synchronization
import ToolCore

extension AgentSharedChat {
    public enum ParticipantKind: String, Sendable, Codable {
        /// A trusted human-originated sender. Operators are represented in
        /// message snapshots only; they never occupy a room slot or mailbox.
        case `operator`
        case coordinator
        case agent

        /// Forward-compatible decoding: a raw value from a future version
        /// (or a typo in persisted/wire data) decodes to the least-privileged
        /// kind (`.agent`) instead of throwing. This keeps existing encoded
        /// data decodable across versions without reserving a public case for
        /// every future role.
        ///
        /// The encoded representation is unchanged: the `String` raw value in a
        /// single-value container, identical to the compiler-synthesized
        /// `Codable` this replaces.
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            self = ParticipantKind(rawValue: raw) ?? .agent
        }
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

        init(id: UUID = UUID(), roomID: String, sender: Participant, recipientIDs: [String], text: String) {
            self.id = id
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
        /// The terminal operator, who consumes messages through the observation
        /// stream and does not own a mailbox.
        case `operator`
        case coordinator
        /// Every other active delegated agent, never the sender.
        case peers
        /// The coordinator, every active delegated agent, and the terminal
        /// operator (the implicit room owner), except the sender. The operator
        /// consumes messages through the TUI observation stream, not a mailbox.
        case all
    }

    public struct Delivery: Sendable, Equatable {
        public let message: Message
        public let recipients: [Participant]
    }

    public enum Error: LocalizedError, Sendable, Equatable {
        case unavailable
        case roomParticipantLimitExceeded
        case unknownParticipant(String)
        case coordinatorUnavailable
        case noOtherActiveAgents
        case noRecipients
        case invalidMessage
        /// The identifier is syntactically unusable as a live identity (blank,
        /// over-long, or carrying control/bidi characters).
        case invalidParticipantIdentifier(String)
        /// The identifier belongs to the coordinator/operator namespace, which
        /// only this actor may mint.
        case reservedParticipantIdentifier(String)
        /// The identifier is already live in this room with a different kind.
        case participantIdentifierConflict(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Live messages is unavailable because the coordinator runtime is not ready."
            case .roomParticipantLimitExceeded:
                return "The live messages has reached its participant limit."
            case let .unknownParticipant(identifier):
                return "No active messages participant matches '\(Self.safeIdentifierDescription(identifier))'."
            case .coordinatorUnavailable:
                return "The live coordinator is not available in this shared-chat room."
            case .noOtherActiveAgents:
                return "No other live agent instances are active in this shared-chat room."
            case .noRecipients:
                return "The shared-chat destination has no active recipients."
            case .invalidMessage:
                return "A shared-chat message must not be empty."
            case let .invalidParticipantIdentifier(identifier):
                return "'\(Self.safeIdentifierDescription(identifier))' is not a usable shared-chat participant identifier."
            case let .reservedParticipantIdentifier(identifier):
                return "'\(Self.safeIdentifierDescription(identifier))' is reserved for the live coordinator/operator identity."
            case let .participantIdentifierConflict(identifier):
                return "'\(Self.safeIdentifierDescription(identifier))' is already registered in this shared-chat room with a different role."
            }
        }

        /// Error messages are surfaced to models and terminals, so a rejected
        /// identifier is quoted back in its neutralised single-line form.
        private static func safeIdentifierDescription(_ identifier: String) -> String {
            AgentSharedChat.promptSafeInlineText(
                identifier,
                limit: AgentSharedChat.maximumParticipantIdentifierLength
            )
        }
    }

    public static func coordinatorID(for roomID: String) -> String {
        "\(reservedCoordinatorPrefix)\(boundedRoomIdentifier(roomID))"
    }

    /// The mailbox owner for a tool execution: the delegated agent identified
    /// by `senderID`, or the room's coordinator when no agent identity is set.
    public static func mailboxParticipantID(senderID: String?, roomID: String) -> String {
        senderID ?? coordinatorID(for: roomID)
    }

    /// Resolves the shared-chat room for a tool execution: an explicit shared
    /// root session wins, then the non-blank session id, then `"default"`.
    public static func resolvedRoomID(
        sharedChatRootSessionID: String?,
        sessionID: String?
    ) -> String {
        sharedChatRootSessionID ?? sessionID?.nilIfBlank ?? "default"
    }

    /// Stable transcript identity for the terminal operator. It is never
    /// registered in a room, so it cannot be impersonated through `send`; it is
    /// instead surfaced as an implicit owner member for routing and display.
    static func operatorID(for roomID: String) -> String {
        "\(reservedOperatorPrefix)\(boundedRoomIdentifier(roomID))"
    }

    /// The terminal operator as an implicit, always-present room member.
    ///
    /// The operator is the session owner: broadcasts reach it even when it is
    /// the only other party, and it can be addressed directly. It is
    /// deliberately never registered in `room.participants`, so it holds no
    /// mailbox, does not consume one of the bounded room slots, and cannot be
    /// forged as a sender through `send` (only ``sendFromOperator(roomID:destination:text:)``
    /// may originate operator traffic). The human operator consumes messages
    /// through the TUI observation stream rather than a mailbox drain.
    static func implicitOperator(roomID: String) -> Participant {
        Participant(id: operatorID(for: roomID), name: "operator", kind: .operator)
    }

    /// Namespaces owned by this actor. Only ``registerCoordinator(roomID:name:onMessageAvailable:)``
    /// and ``sendFromOperator(roomID:destination:text:)`` may mint identities
    /// here; every other registration path is rejected.
    static let reservedCoordinatorPrefix = "coordinator:"
    static let reservedOperatorPrefix = "operator:"

    /// True when the identifier is the implicit terminal operator for any room.
    /// The operator is never registered, so this recognises the actor-owned
    /// namespace rather than a participant lookup.
    public static func isOperatorIdentifier(_ rawIdentifier: String) -> Bool {
        let identifier = rawIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return identifier.hasPrefix(reservedOperatorPrefix)
    }

    /// True when the identifier belongs to the reserved coordinator/operator
    /// namespace, in any room. The check is case-insensitive and ignores
    /// surrounding whitespace so a near-miss spelling cannot slip through.
    public static func isReservedParticipantIdentifier(_ rawIdentifier: String) -> Bool {
        guard isWithinBounds(
            rawIdentifier,
            scalarLimit: maximumParticipantIdentifierLength,
            utf8Limit: maximumParticipantIdentifierUTF8Length
        ) else {
            return false
        }
        let identifier = promptSafeInlineText(rawIdentifier, limit: maximumParticipantIdentifierLength)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return identifier.hasPrefix(reservedCoordinatorPrefix)
            || identifier.hasPrefix(reservedOperatorPrefix)
    }

    /// A type-qualified sender identity for prompts and human-facing
    /// transcripts. Display names are not identities: in particular, an agent
    /// is allowed to be named `operator`, but can never be presented as the
    /// trusted human operator.
    ///
    /// Both fields are neutralised here as well as at registration, so any
    /// `Participant` value — including one rebuilt from a decoded snapshot —
    /// yields exactly one line and cannot forge a prompt header.
    public static func transcriptIdentity(for participant: Participant) -> String {
        let id = promptSafeInlineText(participant.id, limit: maximumParticipantIdentifierLength)
        switch participant.kind {
        case .operator:
            return "Operator (human, id: \(id))"
        case .coordinator:
            return "Coordinator (id: \(id))"
        case .agent:
            return "Agent (id: \(id), name: \(displayName(for: participant)))"
        }
    }

    /// Model-facing recipient list for `agent.message`. It intentionally uses
    /// qualified transcript identities instead of `@name`: names are mutable
    /// display data and can legitimately equal `operator` or `coordinator`.
    public static func deliveryRecipientSummary(for recipients: [Participant]) -> String {
        recipients
            .map(transcriptIdentity(for:))
            .joined(separator: ", ")
    }

    /// The neutralised, bounded display name used by prompts, tool results and
    /// terminal cards. It is never an identity.
    public static func displayName(for participant: Participant) -> String {
        let name = promptSafeInlineText(participant.name, limit: maximumParticipantNameLength)
        return name.isEmpty
            ? promptSafeInlineText(participant.id, limit: maximumParticipantIdentifierLength)
            : name
    }
}
