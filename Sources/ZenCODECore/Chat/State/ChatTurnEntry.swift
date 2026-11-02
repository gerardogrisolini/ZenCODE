//
//  ChatTurnEntry.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation
import ToolCore

/// A phase of a chat turn, as the controller presents it.
///
/// One turn goes through ``started`` once, then through ``ended(_:)`` and
/// ``modelReturned`` once per model request (a `/goal` workflow can continue
/// with automatic requests), and finally through ``finishing``.
public enum ChatTurnPhase: Sendable, Equatable {
    /// The turn started (``ChatSessionPresenter/turnWillStart(_:)``).
    case started
    /// One model request of the turn returned
    /// (``ChatSessionPresenter/modelTurnDidReturn()``).
    case modelReturned
    /// The model work is done; the workflow notices and the file-change summary
    /// of the turn may still follow (``ChatSessionPresenter/turnWillFinish()``).
    case finishing
    /// The runtime ended a model request with `outcome`
    /// (``ChatSessionPresenter/presentTurnEnded(_:)``).
    case ended(DirectAgentTurnOutcome)
}

/// One entry of a session's ordered log (see ``ChatSessionSnapshot/log``).
///
/// The log is the truth of what the session showed: the transcript and the
/// activity of a snapshot are projections of it. Assistant text and reasoning
/// are recorded in blocks, closed where the session transcript closes them
/// (the first start of a tool call, an automatic `/goal` continuation, the end
/// of the turn); the text still streaming is in ``ChatTurnState``, outside
/// the log.
public struct ChatTurnEntry: Sendable, Equatable, Identifiable {
    /// What an entry records.
    public enum Kind: Sendable, Equatable {
        /// The prompt that started a turn, with its attachments and origin.
        case userPrompt(text: String, attachments: [AgentRuntimeAttachment], origin: ChatTurnOrigin)
        /// A closed block of assistant content, as streamed (never blank).
        case assistantText(String)
        /// A closed block of reasoning, trimmed as the transcript stores it
        /// (never blank). It precedes the ``assistantText(_:)`` of the same
        /// block.
        case thought(String)
        /// A tool call started.
        case toolCallStarted(DirectAgentToolCall)
        /// A tool call completed with `result`. Its
        /// ``toolCallStarted(_:)`` entry always precedes it.
        case toolCallCompleted(DirectAgentToolCall, result: DirectAgentToolResult)
        /// File artifacts of one artifact-history turn. A live entry
        /// (`isSealed == false`) was recorded while the turn ran; `agentID`
        /// is non-nil when a delegated agent produced it. A sealed entry
        /// holds the artifacts of the sealed turn that were not presented
        /// live: a turn's artifacts are the union of its live and sealed
        /// entries.
        case fileArtifacts(SessionFileArtifactHistory.Turn, agentID: String?, isSealed: Bool)
        /// The outcome of a session operation or a shared command.
        case notice(ChatSessionNotice)
        /// A `/goal` workflow changed state.
        case workflowNotice(ChatWorkflowNotice)
        /// The turn reached `phase`.
        case turnPhase(ChatTurnPhase)
    }

    /// The entry's position in the log: strictly increasing over the life of
    /// the reducer that assigned it, across sessions and epochs, and never
    /// reused.
    public let sequence: Int
    /// The turn the entry belongs to, numbered by the reducer from 1 in the
    /// order turns start. A turn stays open from its start to its
    /// file-change summary (``ChatSessionPresenter/presentFileChangeSummary(_:)``)
    /// or, when it reports none, until the next turn starts, so a command's
    /// notice between turns then belongs to the turn before it. `nil` for an
    /// entry presented while no turn is open: before the first turn, after a
    /// turn's file-change summary, and after a session change or a restored
    /// log until the next turn starts.
    public let turnID: Int?
    public let kind: Kind

    /// The entry's ``sequence``.
    public var id: Int {
        sequence
    }

    init(sequence: Int, turnID: Int?, kind: Kind) {
        self.sequence = sequence
        self.turnID = turnID
        self.kind = kind
    }
}

extension ChatTurnEntry.Kind {
    /// `true` for the kinds of ``ChatSessionSnapshot/transcript``: prompts
    /// and assistant blocks.
    var isTranscript: Bool {
        switch self {
        case .userPrompt, .assistantText, .thought:
            true
        default:
            false
        }
    }

    /// `true` for the kinds of ``ChatSessionSnapshot/activity``: tool calls.
    var isActivity: Bool {
        switch self {
        case .toolCallStarted, .toolCallCompleted:
            true
        default:
            false
        }
    }

    /// `true` for the kinds of ``ChatSessionSnapshot/notices``.
    var isNotice: Bool {
        switch self {
        case .notice, .workflowNotice:
            true
        default:
            false
        }
    }

    /// `true` for the kinds of ``ChatFileChangesState/artifactHistory``.
    var isFileArtifacts: Bool {
        if case .fileArtifacts = self { return true }
        return false
    }
}
