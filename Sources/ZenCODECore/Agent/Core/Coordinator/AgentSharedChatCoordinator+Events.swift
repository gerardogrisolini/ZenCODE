//
//  AgentSharedChatCoordinator+Events.swift
//  ZenCODE
//

import Foundation

/// One synthetic coordinator turn requested by the Core auto-trigger.
///
/// The batch is already bounded by ``AgentSharedChat/maximumMessagesPerInjectedPrompt``
/// and its ``prompt`` is built by the Core, so every consumer (terminal UI,
/// ACP, tests, headless drivers) injects exactly the same text.
public struct AgentSharedChatAutoTrigger: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let roomID: String
    public let messages: [AgentSharedChat.Message]
    public let prompt: String

    init(
        id: UUID = UUID(),
        roomID: String,
        messages: [AgentSharedChat.Message],
        prompt: String
    ) {
        self.id = id
        self.roomID = roomID
        self.messages = messages
        self.prompt = prompt
    }
}

/// How a consumer answered an auto-trigger. `declined` returns the batch to the
/// head of the pending queue, so refusing a turn never drops a live message.
public enum AgentSharedChatAutoTriggerResolution: Sendable, Equatable {
    /// The consumer owns the turn now and reports itself busy until it ends.
    case started
    /// The consumer cannot run the turn; the Core re-offers the same messages.
    case declined
}

/// The result of attempting to take an auto-triggered coordinator turn.
///
/// A trigger is broadcast to every observer of a room. Observers must start a
/// synthetic generation only after receiving ``acquired``: the actor makes the
/// active-trigger check, its removal and the claim ownership record one atomic
/// operation, so exactly one observer can acquire a given trigger.
public enum AgentSharedChatAutoTriggerClaimResult: Sendable, Equatable {
    /// This consumer atomically acquired the active trigger and owns its turn.
    case acquired
    /// The trigger was stale, belonged to another room, was already claimed by
    /// a different observer, or the caller is no longer an attached observer.
    /// It must be treated as a no-op.
    case notAcquired
}

/// Events published by the Core auto-trigger. Rendering surfaces consume
/// `messages`/`participantsChanged`; `autoTrigger` carries the single-flight
/// decision that used to live inside the terminal input loop.
public enum AgentSharedChatCoordinatorEvent: Sendable, Equatable {
    case messages([AgentSharedChat.Message])
    case participantsChanged([AgentSharedChat.Participant])
    case autoTrigger(AgentSharedChatAutoTrigger)
}
