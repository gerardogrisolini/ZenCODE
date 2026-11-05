//
//  ZenTranscriptItem.swift
//  ZenApp
//
//  One row of a window's transcript, projected from the session log
//  (`ChatSessionSnapshot.log`) or created by the window itself.
//

import Foundation
import ToolCore
import ZenCODECore

/// One row of the transcript a window renders: a log entry of the session, a
/// file-change summary, or a message of the window. The block still streaming
/// is not a row: the window publishes it on its own (see
/// `ZenWindowSession.liveAssistantText`).
public struct ZenTranscriptItem: Identifiable, Equatable, Sendable {
    /// What a row shows.
    public enum Content: Equatable, Sendable {
        /// The prompt that started a turn. Only a prompt the operator typed is
        /// a row: the prompt a command built (`/plan`, `/goal`, `/review`, an
        /// approved plan, a Planner continuation) is hidden, as in the
        /// terminal. A reply the operator typed that built a hidden prompt
        /// shows as a local row with this content.
        case userPrompt(text: String, attachments: [AgentRuntimeAttachment], origin: ChatTurnOrigin)
        /// The echo of a slash command the operator ran.
        case commandLine(String)
        /// Assistant content: a closed block, or the block still streaming.
        case assistantText(String, isStreaming: Bool)
        /// Reasoning: a closed block, or the block still streaming.
        case thought(String, isStreaming: Bool)
        /// A tool call, with its result once it completed.
        case toolCall(call: DirectAgentToolCall, result: DirectAgentToolResult?)
        /// File artifacts of one artifact-history turn (see
        /// `ChatTurnEntry.Kind.fileArtifacts`): `isSealed` tells the artifacts
        /// recorded at the seal of the turn from the live ones.
        case fileArtifacts(SessionFileArtifactHistory.Turn, agentID: String?, isSealed: Bool)
        /// The outcome of a session operation or a shared command.
        case notice(ChatSessionNotice)
        /// A `/goal` workflow changed state.
        case workflowNotice(ChatWorkflowNotice)
        /// The reconciled file changes of a turn, after its last row.
        case fileChangeSummary(TurnFileChangeSummary)
        /// A message of the window itself (a refusal, a failed turn).
        case local(text: String, isFailure: Bool)
        /// The task graph as the window showed it, like the terminal's
        /// `Tasks` section: the card of a turn, which follows the graph's
        /// latest significant change while the turn generates, or the card of
        /// a `/tasks` line. Only a local row (``ZenLocalTranscriptItem``) has
        /// it; it is never saved.
        case taskGraph(ChatTaskGraphOverview)
    }

    /// Stable identity, unique across the incarnations of a window:
    /// `<epoch>-log-<sequence>` for a log entry, `<epoch>-summary-<turnID>`
    /// for a file-change summary, `local-<uuid>` for a message of the window.
    public let id: String
    /// The turn the row belongs to (`ChatTurnEntry.turnID`); `nil` outside a
    /// turn and for the messages of the window.
    public let turnID: Int?
    /// The row starts a visible turn: it is a prompt the operator typed, from
    /// the log or the local echo of a reply. The turn separator goes before
    /// such a row only (after the first one).
    public let startsTurn: Bool
    public let content: Content

    public init(id: String, turnID: Int?, startsTurn: Bool = false, content: Content) {
        self.id = id
        self.turnID = turnID
        self.startsTurn = startsTurn
        self.content = content
    }
}

/// A row the window adds to its transcript (a command echo, the echo of a
/// reply the operator typed, a refusal, the ending of a turn, a task-graph
/// card), anchored after the last log entry present when it was created (or
/// last moved, see ``ZenTranscriptProjection/moveLocal(id:to:content:)``). It
/// belongs to one epoch and disappears when the epoch changes.
public struct ZenLocalTranscriptItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The epoch of the session log the row belongs to.
    public let epoch: UInt64
    /// The last log sequence present when the row was created or last
    /// moved: the row follows every log row with a sequence up to it.
    public let anchorSequence: Int
    public let content: ZenTranscriptItem.Content

    public init(
        id: UUID = UUID(),
        epoch: UInt64,
        anchorSequence: Int,
        content: ZenTranscriptItem.Content
    ) {
        self.id = id
        self.epoch = epoch
        self.anchorSequence = anchorSequence
        self.content = content
    }

    /// A row anchored after the last entry of `snapshot`'s log.
    public init(id: UUID = UUID(), anchoredIn snapshot: ChatSessionSnapshot, content: ZenTranscriptItem.Content) {
        self.init(
            id: id,
            epoch: snapshot.epoch,
            anchorSequence: Self.anchorSequence(in: snapshot),
            content: content
        )
    }

    /// The last sequence of `snapshot`'s log, or the one before its first
    /// retained sequence when the log is empty.
    public static func anchorSequence(in snapshot: ChatSessionSnapshot) -> Int {
        snapshot.log.last?.sequence ?? snapshot.firstRetainedSequence - 1
    }

    /// The transcript row of this item. A prompt the operator typed as a
    /// reply starts a visible turn, as a log prompt does.
    public var transcriptItem: ZenTranscriptItem {
        let startsTurn: Bool
        if case .userPrompt = content {
            startsTurn = true
        } else {
            startsTurn = false
        }
        return ZenTranscriptItem(
            id: "local-\(id.uuidString.lowercased())",
            turnID: nil,
            startsTurn: startsTurn,
            content: content
        )
    }
}
