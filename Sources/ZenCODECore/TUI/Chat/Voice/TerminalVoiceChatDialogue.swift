//
//  TerminalVoiceChatDialogue.swift
//  ZenCODE
//
//  The spoken dialogue over live shared-chat messages in voice mode: new
//  messages for the operator are announced one at a time, read aloud on a
//  yes, answered on a second yes, and "message to …" phrases send without a
//  question. Pure state, driven by the terminal runtime loop; transient and
//  never persisted.
//

import Foundation

struct TerminalVoiceChatDialogue: Sendable {
    /// Older unannounced messages are dropped past this many.
    static let maximumPendingAnnouncements = 32

    enum Phase: Sendable, Equatable {
        case idle
        /// "New message from X. Do you want me to read it?" is being asked.
        case askingToRead(AgentSharedChat.Message)
        /// The message is being read, ending with "Do you want to reply?".
        case reading(AgentSharedChat.Message)
        case askingToReply(AgentSharedChat.Message)
        /// "Tell me your reply." was asked; the next utterance is the reply.
        case awaitingReplyText(AgentSharedChat.Message)
        /// "Tell me the message." was asked after a "message to …" phrase
        /// without text; the next utterance is the message.
        case awaitingMessageText(destination: AgentSharedChat.Destination, label: String)
    }

    /// What the loop does once the controller stopped speaking.
    enum SpeechEndTransition: Sendable, Equatable {
        /// A question or request was asked: its answer is awaited for a while.
        case armDeadline(UUID)
        /// Nothing is pending on the dialogue: announce the next message.
        case announceNext
        case none
    }

    /// What the loop does with a recognised utterance.
    enum Action: Sendable, Equatable {
        /// Not part of the dialogue: handled like a dictated prompt.
        case prompt
        case read(AgentSharedChat.Message)
        /// The operator declined the reading; announce the next message.
        case declined
        case askReplyText(AgentSharedChat.Message)
        case send(destination: AgentSharedChat.Destination, text: String, label: String)
        case askMessageText(destination: AgentSharedChat.Destination, label: String)
        case unknownAgent(String)
        /// The operator does not reply; announce the next message.
        case skip
    }

    private(set) var phase: Phase = .idle
    private(set) var pending: [AgentSharedChat.Message] = []
    /// Identifies the latest answer deadline; an older timer is ignored.
    private(set) var deadlineToken: UUID?

    /// The message of the current question or reading, if any.
    var currentMessage: AgentSharedChat.Message? {
        switch phase {
        case let .askingToRead(message), let .reading(message),
             let .askingToReply(message), let .awaitingReplyText(message):
            message
        case .idle, .awaitingMessageText:
            nil
        }
    }

    /// Only coordinator or agent messages addressed to the operator, directly
    /// or in a broadcast, are announced. Operator messages and traffic between
    /// the coordinator and agents stay silent in the dock.
    static func isAnnounceable(_ message: AgentSharedChat.Message) -> Bool {
        message.sender.kind != .operator
            && message.recipientIDs.contains(where: AgentSharedChat.isOperatorIdentifier)
    }

    /// Queues the announceable messages not already queued or current.
    mutating func enqueue(_ messages: [AgentSharedChat.Message]) {
        var known = Set(pending.map(\.id))
        if let current = currentMessage {
            known.insert(current.id)
        }
        for message in messages where Self.isAnnounceable(message) && known.insert(message.id).inserted {
            pending.append(message)
        }
        if pending.count > Self.maximumPendingAnnouncements {
            pending.removeFirst(pending.count - Self.maximumPendingAnnouncements)
        }
    }

    /// Takes the next unread message to announce, skipping those read in the
    /// dock meanwhile, with how many wait behind it. Only from `.idle`.
    mutating func beginAnnouncement(
        skipping isAlreadyRead: (UUID) -> Bool
    ) -> (message: AgentSharedChat.Message, remaining: Int)? {
        guard phase == .idle else {
            return nil
        }
        while !pending.isEmpty {
            let message = pending.removeFirst()
            if isAlreadyRead(message.id) {
                continue
            }
            phase = .askingToRead(message)
            deadlineToken = nil
            return (message, pending.count)
        }
        return nil
    }

    /// The announcement could not be spoken: the message returns to the head
    /// of the queue for a later attempt.
    mutating func announcementNotSpoken() {
        guard case let .askingToRead(message) = phase else {
            return
        }
        pending.insert(message, at: 0)
        phase = .idle
        deadlineToken = nil
    }

    /// The controller stopped speaking: a reading turns into the reply
    /// question, every question starts waiting for its answer, and an idle
    /// dialogue may announce the next message.
    mutating func speechEnded() -> SpeechEndTransition {
        switch phase {
        case let .reading(message):
            phase = .askingToReply(message)
            return .armDeadline(newDeadline())
        case .askingToRead, .askingToReply, .awaitingReplyText, .awaitingMessageText:
            return .armDeadline(newDeadline())
        case .idle:
            return .announceNext
        }
    }

    /// `true` when `token` is the current deadline: the question lapses in
    /// silence, its message stays unread, and the dialogue is idle again.
    mutating func deadlineElapsed(_ token: UUID) -> Bool {
        guard token == deadlineToken else {
            return false
        }
        deadlineToken = nil
        phase = .idle
        return true
    }

    /// An answer is about to be read aloud: it takes precedence. A message
    /// not yet read returns to the head of the queue and is announced again
    /// afterwards; one already read is dropped, since the reply question
    /// cannot be repeated without being spoken again; a text already asked
    /// for ("Tell me your reply.") is still awaited once the answer is over.
    mutating func answerReadingStarted() {
        deadlineToken = nil
        switch phase {
        case let .askingToRead(message):
            if !pending.contains(where: { $0.id == message.id }) {
                pending.insert(message, at: 0)
            }
            phase = .idle
        case .reading, .askingToReply:
            phase = .idle
        case .idle, .awaitingReplyText, .awaitingMessageText:
            break
        }
    }

    mutating func cancelAll() {
        phase = .idle
        pending.removeAll()
        deadlineToken = nil
    }

    /// Interprets an utterance against the current phase. While a text is
    /// awaited ("Tell me your reply.", "Tell me the message.") the whole
    /// utterance is that text. A yes/no answers the pending question: during
    /// or after the reading it answers "Do you want to reply?", since the
    /// reading ends with that question. Anything else closes the question and
    /// is handled as from idle: a "message to …" phrase sends, everything
    /// else is a prompt.
    mutating func interpret(
        _ utterance: String,
        participants: [AgentSharedChat.Participant]
    ) -> Action {
        deadlineToken = nil
        switch phase {
        case let .awaitingReplyText(message):
            phase = .idle
            let destination: AgentSharedChat.Destination = message.sender.kind == .coordinator
                ? .coordinator
                : .direct([message.sender.id])
            return .send(
                destination: destination,
                text: utterance.trimmingCharacters(in: .whitespacesAndNewlines),
                label: AgentSharedChat.displayName(for: message.sender)
            )
        case let .awaitingMessageText(destination, label):
            phase = .idle
            return .send(
                destination: destination,
                text: utterance.trimmingCharacters(in: .whitespacesAndNewlines),
                label: label
            )
        case let .askingToRead(message):
            switch TerminalVoiceChatPhrases.affirmation(in: utterance) {
            case true:
                phase = .reading(message)
                return .read(message)
            case false:
                phase = .idle
                return .declined
            case nil:
                phase = .idle
            }
        case let .reading(message), let .askingToReply(message):
            switch TerminalVoiceChatPhrases.affirmation(in: utterance) {
            case true:
                phase = .awaitingReplyText(message)
                return .askReplyText(message)
            case false:
                phase = .idle
                return .skip
            case nil:
                phase = .idle
            }
        case .idle:
            break
        }
        return interpretFromIdle(utterance, participants: participants)
    }

    private mutating func interpretFromIdle(
        _ utterance: String,
        participants: [AgentSharedChat.Participant]
    ) -> Action {
        guard let request = TerminalVoiceChatPhrases.sendRequest(in: utterance) else {
            return .prompt
        }
        switch request.target {
        case .coordinator:
            return send(to: .coordinator, label: "coordinator", text: request.text)
        case .all:
            return send(to: .all, label: "all", text: request.text)
        case let .named(remainder):
            switch TerminalVoiceChatPhrases.resolveNamedRecipient(
                remainder: remainder,
                participants: participants
            ) {
            case let .agent(participant, text):
                return send(
                    to: .direct([participant.id]),
                    label: AgentSharedChat.displayName(for: participant),
                    text: text
                )
            case let .unknown(spokenName):
                // Nothing usable was heard after the preposition: an ordinary
                // prompt rather than "No active agent is named .".
                return spokenName.isEmpty ? .prompt : .unknownAgent(spokenName)
            }
        }
    }

    private mutating func send(
        to destination: AgentSharedChat.Destination,
        label: String,
        text: String?
    ) -> Action {
        if let text {
            return .send(destination: destination, text: text, label: label)
        }
        phase = .awaitingMessageText(destination: destination, label: label)
        return .askMessageText(destination: destination, label: label)
    }

    private mutating func newDeadline() -> UUID {
        let token = UUID()
        deadlineToken = token
        return token
    }
}
