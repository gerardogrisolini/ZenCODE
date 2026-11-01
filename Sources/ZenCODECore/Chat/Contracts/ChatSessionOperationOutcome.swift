//
//  ChatSessionOperationOutcome.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// A saved session that replaced the active one: loaded from the store, or
/// restored from an entry of its checkpoint tree.
public struct ChatRestoredSession: Sendable, Equatable {
    /// Name of the saved session.
    public let name: String
    /// The conversation to present, oldest first: the saved transcript, or
    /// the checkpoint branch the session was restored from.
    public let transcript: [AgentRuntimeMessage]
    /// The context window the session was saved with.
    public let contextWindow: TerminalSavedSessionContextWindow?
}

/// The result of a session operation (`/sessions` and its subcommands).
///
/// Notices raised while the operation runs (a saved session, a loaded
/// session, the engine-checkpoint progress) reach the channel through
/// ``ChatSessionPresenter/presentSessionNotice(_:)`` as they happen; the
/// outcome carries only the closing ones.
public struct ChatSessionOperationOutcome: Sendable, Equatable {
    /// The saved session that replaced the active one; `nil` when none did
    /// (a save, a deletion, a cancelled menu, a refusal).
    public let restoredSession: ChatRestoredSession?
    /// The closing notices, in the order a text channel writes them.
    public let notices: [ChatSessionNotice]

    public init(restoredSession: ChatRestoredSession? = nil, notices: [ChatSessionNotice] = []) {
        self.restoredSession = restoredSession
        self.notices = notices
    }
}

/// The result of compacting the session context.
public struct ChatSessionCompactionOutcome: Sendable {
    /// The estimated context window after compaction, for the channel's
    /// display; `nil` when there was nothing to compact.
    public let contextWindow: DirectAgentContextWindowStatus?
    /// The closing notice.
    public let notice: ChatSessionNotice
}
