//
//  ChatSelectionOutcome.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// How the running session took a new selection.
enum ChatSelectionChange: Sendable, Equatable {
    /// The session took the new options in place: its options were updated,
    /// or its prompt-skill selection was replaced.
    case sessionUpdated
    /// The session was created anew (another model or agent, or a tool
    /// change that altered the allowlist); the conversation is kept.
    case sessionRecreated
}

/// The result of a selection command (`/models`, `/think`, `/agents`,
/// `/tools`, `/skills`).
///
/// Notices raised while the command runs (a refused workspace access, an
/// install that started, a failed update) reach the channel through
/// ``ChatSessionPresenter/presentSessionNotice(_:)`` as they happen; the
/// outcome carries only the closing ones, which the channel presents after
/// its own steps for ``change``.
struct ChatSelectionOutcome: Sendable, Equatable {
    /// How the session took the selection; `nil` when no selection was
    /// applied (a cancelled menu, a refusal, a channel without menus).
    let change: ChatSelectionChange?
    /// The closing notices, in the order a text channel writes them.
    let notices: [ChatSessionNotice]

    init(change: ChatSelectionChange? = nil, notices: [ChatSessionNotice] = []) {
        self.change = change
        self.notices = notices
    }
}

/// Errors of the selection operations that have no terminal counterpart.
enum ChatSelectionError: LocalizedError, Equatable {
    /// No available model has this ID.
    case unknownModel(String)

    var errorDescription: String? {
        switch self {
        case let .unknownModel(modelID):
            return "Unknown model '\(modelID)'."
        }
    }
}
