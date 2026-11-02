//
//  ChatSlotChannel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/11/26.
//

import Foundation

/// The channel that drives a slot: the one whose input runs the session's
/// turns and commands, whose presenter receives the session's output, and
/// whose host answers the controller's questions.
///
/// A slot is driven by the channel that opened it (``primary``) until
/// `/telegram on` hands it to the linked Telegram chat (``telegram``), and
/// back with `/telegram off` (see ``ChatSessionHost/activateTelegram(in:)``).
/// There is no mirror: one channel drives the slot at a time, the other one
/// is dormant and accepts only what takes the slot back
/// (``ChatSessionHost/admitLine(_:in:)``).
public enum ChatSlotChannel: Sendable, Equatable {
    /// The channel that opened the slot: the terminal, an ACP session, a
    /// window of a host app.
    case primary
    /// The linked Telegram chat, through the slot's ``TelegramChannel``.
    case telegram
}

/// What a dormant channel may do with a line (see
/// ``ChatSessionHost/admitLine(_:in:)``).
public enum ChatSlotAdmission: Sendable, Equatable {
    /// The channel drives the slot, or the line is one a dormant channel may
    /// run (`/telegram`, `/telegram off`, `/exit`).
    case admitted
    /// Another channel drives the slot: the channel answers `text` instead of
    /// running the line, and runs nothing.
    case refused(String)

    /// The text a dormant channel answers, with the prefix and the trailing
    /// newline of the terminal's system messages.
    public static let dormantRefusalText =
        "ZenCODE: this session is driven from Telegram. Use /telegram off to take it back.\n"

    /// The lines a dormant channel may run: the Telegram status, the command
    /// that takes the slot back, and the terminal's exit.
    nonisolated static func isAllowedWhileDormant(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "/telegram", "/telegram off", "/exit":
            return true
        default:
            return false
        }
    }
}

/// How a turn run on a slot ended, as the channel that ran it reports it to
/// the channel that drives the slot when it ends
/// (``ChatSessionHost/presentTurnEnding(_:in:)``): a turn may move from one
/// channel to the other while it runs, so its ending is presented by whoever
/// drives the slot then, not by whoever started it.
struct ChatTurnEnding: Sendable {
    enum Outcome: Sendable {
        /// The turn completed with `response`, the runtime's final response.
        case completed(DirectAgentResponse)
        /// The turn failed with this operator-facing message.
        case failed(String)
        /// The operator stopped the turn.
        case cancelled
    }

    let outcome: Outcome
    let fileChangeSummary: TurnFileChangeSummary?
    /// The approved plan the turn completed, if any.
    let automaticallyCompletedPlan: TerminalSessionPlan?

    init(
        outcome: Outcome,
        fileChangeSummary: TurnFileChangeSummary? = nil,
        automaticallyCompletedPlan: TerminalSessionPlan? = nil
    ) {
        self.outcome = outcome
        self.fileChangeSummary = fileChangeSummary
        self.automaticallyCompletedPlan = automaticallyCompletedPlan
    }

    /// The ending of a turn that returned `result`.
    init(result: ChatTurnResult) {
        self.init(
            outcome: .completed(result.response),
            fileChangeSummary: result.fileChangeSummary,
            automaticallyCompletedPlan: result.automaticallyCompletedPlan
        )
    }

    /// The ending of a turn that threw `error`: a cancellation, or a failure
    /// with the error's description.
    init(error: Error) {
        let failure = error as? ChatTurnFailure
        let underlying = failure?.underlying ?? error
        self.init(
            outcome: underlying is CancellationError
                ? .cancelled
                : .failed(underlying.localizedDescription),
            fileChangeSummary: failure?.fileChangeSummary
        )
    }
}

/// A turn that moves from one channel of the slot to the other while it
/// runs (see ``ChatSlotChannelPresenter/turnDidMoveToChannel(_:)``).
struct ChatMovedTurn: Sendable {
    /// The request the turn started with.
    let request: ChatTurnRequest
    /// The assistant text of the block streaming now, which the new channel
    /// did not see begin; blank when nothing streamed yet.
    let liveAssistantText: String
    /// The reasoning of the block streaming now; blank when none.
    let liveThought: String
}

/// What the channel that takes a slot back catches up with: the log entries
/// it did not see while the other channel drove the slot (see
/// ``ChatSessionHost/deactivateTelegram(in:presentingCatchUp:)``).
public struct ChatTelegramCatchUp: Sendable, Equatable {
    /// The id of the session the entries belong to.
    public let sessionID: String
    /// The entries, oldest first: every entry with a sequence greater than
    /// the last one the channel saw, or the whole log of the incarnation when
    /// it changed meanwhile.
    public let entries: [ChatTurnEntry]
    /// The assistant text of the block still streaming when the channel took
    /// the slot back, which is not in the log yet; blank when none.
    public let liveAssistantText: String
    /// `true` when the slot runs another incarnation than the one the channel
    /// handed over (`/sessions new` or `/sessions load` ran meanwhile): the
    /// entries are the whole log of the new session.
    public let incarnationChanged: Bool
    /// `true` when entries older than the first retained one were dropped by
    /// the log's bound, so the catch-up does not start where the channel left:
    /// entries after the last one the channel saw or, when the incarnation
    /// changed, entries of the new incarnation's log since its first one.
    public let omittedOlderEntries: Bool

    public init(
        sessionID: String,
        entries: [ChatTurnEntry],
        liveAssistantText: String = "",
        incarnationChanged: Bool,
        omittedOlderEntries: Bool
    ) {
        self.sessionID = sessionID
        self.entries = entries
        self.liveAssistantText = liveAssistantText
        self.incarnationChanged = incarnationChanged
        self.omittedOlderEntries = omittedOlderEntries
    }

    /// `true` when there is nothing to catch up with.
    public var isEmpty: Bool {
        entries.isEmpty && liveAssistantText.isEmpty && !incarnationChanged
    }
}

/// The presenter of a channel that can drive a slot: besides the turn
/// output every ``ChatSessionPresenter`` receives, it is told when a turn
/// started by the other channel moves onto it, and presents the ending of a
/// turn whichever channel ran it. The slot's presenter
/// (``ChatSlotPresenter``) calls these on the channel that drives the slot.
@ChatSessionActor
protocol ChatSlotChannelPresenter: ChatSessionPresenter {
    /// A turn that started while the other channel drove the slot continues
    /// on this channel from now on: the channel prepares to present the rest
    /// of it (its streaming state, its progress), knowing that `turn` already
    /// streamed `liveAssistantText`.
    func turnDidMoveToChannel(_ turn: ChatMovedTurn) async

    /// A turn run on the slot ended as `ending` says; the channel presents
    /// the ending as it presents the end of its own turns.
    func presentTurnEnding(_ ending: ChatTurnEnding) async
}
