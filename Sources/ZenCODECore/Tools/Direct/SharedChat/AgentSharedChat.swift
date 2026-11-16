//
//  AgentSharedChat.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import Synchronization
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
    /// Message length is deliberately a Unicode-scalar bound rather than a
    /// grapheme bound: one visible grapheme can otherwise contain an unbounded
    /// number of combining scalars. The matching UTF-8 bound is checked before
    /// constructing a retained snapshot.
    public static let maximumMessageLength = 12_000
    public static let maximumMessageUTF8Length = 48_000
    /// Identity fields are quoted inside prompts and terminal cards, so they
    /// are bounded independently from the message body they introduce.
    public static let maximumParticipantNameLength = 64
    public static let maximumParticipantIdentifierLength = 128
    public static let maximumParticipantIdentifierUTF8Length = 512
    /// Room IDs flow into coordinator/operator IDs, so reserve space for their
    /// trusted prefixes as well as bounding their raw scalar and byte input.
    public static let maximumRoomIdentifierLength = 96
    public static let maximumRoomIdentifierUTF8Length = 384
    /// Bounds for one serialized message inside an injected prompt. They keep
    /// a single hostile message from dominating the coordinator's context.
    public static let maximumPromptLinesPerMessage = 40
    public static let maximumPromptLineLength = 2_000
    public static let maximumPromptLineUTF8Length = 8_000

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

    /// Wakes in-process waits as soon as a message reaches a mailbox they
    /// watch. Synchronous, so a wait can start watching before it probes the
    /// mailbox and miss no delivery in between.
    nonisolated let deliverySignal = DeliverySignal()

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
                name: Self.sanitizedParticipantName(name, fallback: "coordinator"),
                kind: .coordinator
            ),
            roomID: roomID,
            onMessageAvailable: onMessageAvailable
        )
    }

    /// Registers one delegated agent instance.
    ///
    /// The identifier is minted by the runtime, never by a model: it must be a
    /// usable single-line identity and must not enter the reserved
    /// coordinator/operator namespace, otherwise an agent could impersonate the
    /// trusted human or the coordinator in prompts, cards and routing.
    @discardableResult
    public func registerAgent(
        id rawID: String,
        name: String,
        roomID rawRoomID: String,
        onMessageAvailable: (@Sendable () -> Void)? = nil
    ) throws -> Participant {
        let id = try Self.validatedAgentIdentifier(rawID)
        return try register(
            Participant(id: id, name: Self.sanitizedParticipantName(name, fallback: id), kind: .agent),
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
        rooms[roomID]?.participants.removeValue(forKey: id)
    }

    public func participants(roomID rawRoomID: String, includingInactive: Bool = false) -> [Participant] {
        let roomID = normalizedRoomID(rawRoomID)
        guard let room = rooms[roomID] else {
            return []
        }
        var members = room.participants.values
            .map(\.participant)
            .filter { includingInactive || $0.isActive }
        // The terminal operator is the implicit owner of every room: it always
        // appears in the roster even though it is never a registered participant.
        members.append(Self.implicitOperator(roomID: roomID))
        return members.sorted(by: Self.participantSortOrder)
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

    /// Non-destructive mailbox probe. Returns true when the participant's
    /// mailbox holds at least one message from someone other than itself. It
    /// never removes anything, so the mailbox's single destructive owner (the
    /// executor's inline delivery or the idle drain) still delivers the batch.
    public func hasPendingMessages(
        roomID rawRoomID: String,
        participantID: String
    ) -> Bool {
        let roomID = normalizedRoomID(rawRoomID)
        guard let state = rooms[roomID]?.participants[participantID] else {
            return false
        }
        return state.mailbox.contains { $0.sender.id != participantID }
    }

    @discardableResult
    public func send(
        roomID rawRoomID: String,
        senderID: String,
        destination: Destination,
        text rawText: String
    ) throws -> Delivery {
        let roomID = normalizedRoomID(rawRoomID)
        guard let room = rooms[roomID],
              let senderState = room.participants[senderID],
              senderState.participant.isActive else {
            throw Error.unknownParticipant(senderID)
        }
        return try deliver(
            roomID: roomID,
            sender: senderState.participant,
            destination: destination,
            rawText: rawText
        )
    }

    /// Delivers a message entered by the trusted terminal operator. The operator
    /// is the implicit owner of every room: it can be addressed and receives
    /// broadcasts, but is never registered as a participant, so it holds no
    /// mailbox, cannot be forged as a sender through `send`, and does not
    /// consume one of the bounded room slots reserved for the coordinator and
    /// live agent instances.
    @discardableResult
    func sendFromOperator(
        roomID rawRoomID: String,
        destination: Destination,
        text rawText: String,
        messageID: UUID = UUID()
    ) throws -> Delivery {
        let roomID = normalizedRoomID(rawRoomID)
        guard rooms[roomID] != nil else {
            throw Error.unavailable
        }
        return try deliver(
            roomID: roomID,
            sender: Self.implicitOperator(roomID: roomID),
            destination: destination,
            rawText: rawText,
            messageID: messageID
        )
    }

    // MARK: - Identity validation

    private static func validatedAgentIdentifier(_ rawID: String) throws -> String {
        guard isWithinBounds(
            rawID,
            scalarLimit: maximumParticipantIdentifierLength,
            utf8Limit: maximumParticipantIdentifierUTF8Length
        ) else {
            throw Error.invalidParticipantIdentifier(rawID)
        }
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw Error.invalidParticipantIdentifier(rawID)
        }
        guard id.unicodeScalars.allSatisfy({ !isNeutralizedScalar($0) && !isLineBreakScalar($0) }) else {
            throw Error.invalidParticipantIdentifier(rawID)
        }
        guard !isReservedParticipantIdentifier(id) else {
            throw Error.reservedParticipantIdentifier(rawID)
        }
        return id
    }

    private static func sanitizedParticipantName(_ rawName: String, fallback: String) -> String {
        let name = promptSafeInlineText(rawName, limit: maximumParticipantNameLength)
        return name.isEmpty
            ? promptSafeInlineText(fallback, limit: maximumParticipantNameLength)
            : name
    }

    /// Builds a deterministic, terminal-safe slug suitable for a readable
    /// `@mention` handle. Whitespace and underscores collapse to a single dash,
    /// only lowercase ASCII letters, digits and dashes survive, and consecutive
    /// or leading/trailing dashes are removed. Control, bidi and format
    /// characters are dropped entirely so a hostile display name can never
    /// produce an unparseable or visually-reordering handle.
    static func sanitizedHandleSlug(_ raw: String) -> String {
        var slug = ""
        var previousWasDash = true
        for scalar in raw.lowercased().unicodeScalars {
            let value = scalar.value
            if (0x61...0x7A).contains(value) || (0x30...0x39).contains(value) {
                slug.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if value == 0x20 || value == 0x09 || value == 0x2D || value == 0x5F {
                // Space, tab, dash or underscore: collapse to one dash.
                if !previousWasDash && !slug.isEmpty {
                    slug.append("-")
                    previousWasDash = true
                }
            }
            // Every other scalar (punctuation, control, bidi, format) is dropped.
        }
        // Trim a trailing dash added by the collapse logic.
        if slug.hasSuffix("-") {
            slug.removeLast()
        }
        return slug
    }

    private func deliver(
        roomID: String,
        sender: Participant,
        destination: Destination,
        rawText: String,
        messageID: UUID = UUID()
    ) throws -> Delivery {
        let text = Self.boundedMessageText(rawText)
        guard !text.isEmpty else {
            throw Error.invalidMessage
        }
        guard var room = rooms[roomID] else {
            throw Error.unavailable
        }

        let resolved = try resolvedRecipients(
            destination: destination,
            senderID: sender.id,
            roomID: roomID,
            room: room
        )
        let recipientIDs = resolved.map(\.id)
        let message = Message(
            id: messageID,
            roomID: roomID,
            sender: sender,
            recipientIDs: recipientIDs,
            text: text
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
        deliverySignal.notify(recipientIDs: recipientIDs)
        return Delivery(message: message, recipients: resolved)
    }

    /// Registers a fully formed participant.
    ///
    /// This is the single enforcement point for identity reuse: an identifier
    /// that is live with a different kind is rejected instead of being silently
    /// re-typed, so a room slot can never change role under an active mailbox.
    @discardableResult
    func register(
        _ participant: Participant,
        roomID: String,
        onMessageAvailable: (@Sendable () -> Void)?
    ) throws -> Participant {
        var room = rooms[roomID] ?? Room()
        if var existing = room.participants[participant.id] {
            guard existing.participant.kind == participant.kind else {
                throw Error.participantIdentifierConflict(participant.id)
            }
            existing.participant.isActive = true
            // A backend can be rebuilt while its transient messages survives.
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

    private func resolvedRecipients(
        destination: Destination,
        senderID: String,
        roomID: String,
        room: Room
    ) throws -> [Participant] {
        var active = room.participants.values
            .map(\.participant)
            .filter(\.isActive)
        // The terminal operator is an implicit, always-present member:
        // broadcasts reach it even when it is the only other party, and it can
        // be addressed directly. It holds no mailbox and is never registered,
        // so it remains unforgeable as a sender and consumes no room slot.
        active.append(Self.implicitOperator(roomID: roomID))
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
        case .operator, .coordinator, .peers:
            let kind: ParticipantKind = switch destination {
            case .operator: .operator
            case .coordinator: .coordinator
            default: .agent
            }
            recipients = active.filter { $0.kind == kind && $0.id != senderID }
        case .all:
            recipients = active.filter { $0.id != senderID }
        }
        guard !recipients.isEmpty else {
            switch destination {
            case .coordinator: throw Error.coordinatorUnavailable
            case .peers: throw Error.noOtherActiveAgents
            case .operator, .direct, .all: throw Error.noRecipients
            }
        }
        return recipients.sorted { $0.id < $1.id }
    }

    private func resolveParticipant(_ rawIdentifier: String, in participants: [Participant]) -> Participant? {
        guard Self.isWithinBounds(
            rawIdentifier,
            scalarLimit: Self.maximumParticipantIdentifierLength,
            utf8Limit: Self.maximumParticipantIdentifierUTF8Length
        ) else {
            return nil
        }
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }
        if let exact = participants.first(where: { $0.id == identifier }) {
            return exact
        }
        let folded = identifier.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let matches = participants.filter {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == folded
        }
        // A display name is not an identity and need not be unique. Routing an
        // ambiguous name to an arbitrary instance would also be
        // non-deterministic, so it is rejected instead.
        return matches.count == 1 ? matches.first : nil
    }

    private func normalizedRoomID(_ rawValue: String) -> String {
        Self.boundedRoomIdentifier(rawValue)
    }

    private static func participantSortOrder(_ lhs: Participant, _ rhs: Participant) -> Bool {
        func rank(_ kind: ParticipantKind) -> Int {
            switch kind {
            case .operator: 0
            case .coordinator: 1
            case .agent: 2
            }
        }
        if lhs.kind != rhs.kind {
            return rank(lhs.kind) < rank(rhs.kind)
        }
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return order == .orderedAscending || (order == .orderedSame && lhs.id < rhs.id)
    }
}

extension AgentSharedChat {
    /// Observers of mailbox deliveries, by participant identifier. It only
    /// shortens waits: an observer is told that a message reached a mailbox,
    /// never what it holds, and every wait still re-reads the mailbox and
    /// keeps polling as its fallback. Delivery itself and the mailbox's
    /// single destructive owner are unchanged.
    final class DeliverySignal: Sendable {
        private struct Observer: Sendable {
            let participantID: String
            let callback: @Sendable () -> Void
        }

        private let observers = Mutex<[UUID: Observer]>([:])

        /// Calls `callback` after each delivery to the mailbox of
        /// `participantID`, until ``cancel(_:)`` is called with the returned
        /// token. The callback runs after the delivery is committed, on the
        /// delivering actor: it must only schedule work.
        func observe(
            participantID: String,
            _ callback: @escaping @Sendable () -> Void
        ) -> UUID {
            let token = UUID()
            observers.withLock {
                $0[token] = Observer(participantID: participantID, callback: callback)
            }
            return token
        }

        func cancel(_ token: UUID) {
            _ = observers.withLock { $0.removeValue(forKey: token) }
        }

        func notify(recipientIDs: [String]) {
            let callbacks = observers.withLock { observers -> [@Sendable () -> Void] in
                guard !observers.isEmpty else { return [] }
                return observers.values
                    .filter { recipientIDs.contains($0.participantID) }
                    .map(\.callback)
            }
            for callback in callbacks {
                callback()
            }
        }
    }
}
