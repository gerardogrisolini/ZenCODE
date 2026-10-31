//
//  ChatCommandOutcome.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// What the channel does once a command has run.
enum ChatCommandAction: Sendable, Equatable {
    /// The command is complete: everything it had to say is in the outcome's
    /// notices (or was presented while it ran) and no turn follows.
    case none
    /// The command asks for a model turn with `prompt`.
    ///
    /// `locksResponseLanguage` tells a prompt the operator typed from one the
    /// command built. The terminal's `.runPrompt` (the prompt is written to
    /// the transcript, the staged attachments travel with it, and it locks the
    /// response language) is `true`; its `.runHiddenPrompt` (no echo, no
    /// attachments, the language is left alone) is `false`. Every plan, goal,
    /// and review turn the commands start is the second kind, with the
    /// `purpose` it carries.
    case startTurn(prompt: String, purpose: ChatTurnPurpose, locksResponseLanguage: Bool)
    /// The line names a command that only the channel can run (`/setup`,
    /// `/telegram`, `/voice`, `/ds4`, `/feature`, `/cron`, `/exit`,
    /// `/tools logs`); the shared commands did nothing with it.
    case channelCommand
}

/// The result of a shared slash command.
///
/// What the command shows while it runs (the echo of the submitted line, a
/// notice that precedes the next step, an overview) reaches the channel
/// through ``ChatSessionPresenter`` as it happens; the outcome carries only the
/// closing notices, in the order a text channel writes them, and the
/// ``action`` the channel takes after presenting them.
struct ChatCommandOutcome: Sendable, Equatable {
    /// The closing notices.
    let notices: [ChatSessionNotice]
    /// What follows the notices.
    let action: ChatCommandAction

    init(notices: [ChatSessionNotice] = [], action: ChatCommandAction = .none) {
        self.notices = notices
        self.action = action
    }
}
