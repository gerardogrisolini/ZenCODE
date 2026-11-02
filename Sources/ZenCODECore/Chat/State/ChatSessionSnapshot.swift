//
//  ChatSessionSnapshot.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation

/// The turn a session runs or ran last, with what is still streaming.
public struct ChatTurnState: Sendable, Equatable {
    /// The latest turn that ran live in this epoch (see
    /// ``ChatTurnEntry/turnID``), running or done; `nil` before the first
    /// one. Turns rebuilt from a restored transcript do not count.
    public internal(set) var turnID: Int?
    /// The latest phase of that turn.
    public internal(set) var phase: ChatTurnPhase?
    /// The latest outcome the runtime reported for that turn.
    public internal(set) var outcome: DirectAgentTurnOutcome?
    /// `true` from the start of the turn until it reaches
    /// ``ChatTurnPhase/finishing``.
    public internal(set) var isGenerating = false
    /// The assistant content of the block still streaming. It moves to the
    /// log as a ``ChatTurnEntry/Kind/assistantText(_:)`` when the block
    /// closes, and is empty then.
    public internal(set) var liveAssistantText = ""
    /// The reasoning of the block still streaming. It moves to the log as a
    /// ``ChatTurnEntry/Kind/thought(_:)`` when the block closes, and is empty
    /// then.
    public internal(set) var liveThought = ""
    /// The running metrics, merged with
    /// ``DirectAgentGenerationMetrics/merging(current:update:)`` the way the
    /// terminal's status bar merges them; a session change clears them.
    public internal(set) var metrics: DirectAgentGenerationMetrics?
    /// The latest context-window status of the session.
    public internal(set) var contextWindow: DirectAgentContextWindowStatus?
    /// The latest subscription usage. It belongs to the account, so it
    /// survives a session change.
    public internal(set) var subscriptionUsage: DirectAgentSubscriptionUsageStatus?

    init() {}
}

/// The file changes of a session.
public struct ChatFileChangesState: Sendable, Equatable {
    /// The reconciled file changes of the latest turn
    /// (``ChatSessionPresenter/presentFileChangeSummary(_:)``); `nil` while
    /// the current turn has not reported one. Cleared when a turn starts.
    public internal(set) var turnSummary: TurnFileChangeSummary?
    /// Every ``ChatTurnEntry/Kind/fileArtifacts(_:agentID:isSealed:)`` entry
    /// of the log, live and sealed, in log order: a projection of the log.
    /// The artifacts of one artifact-history turn are the union of its live
    /// entries and its sealed entry (``SessionFileArtifactHistory/Turn/number``
    /// identifies the turn).
    public internal(set) var artifactHistory: [ChatTurnEntry] = []

    init() {}
}

/// What a list of sessions shows about one session.
public struct ChatSessionSummary: Sendable, Equatable {
    /// The session's working directory.
    public internal(set) var workspace: URL
    /// The saved session's name, or a name derived from the epoch's first
    /// prompt the way an unsaved session is saved; `nil` before both.
    public internal(set) var title: String?
    /// ``ChatTurnState/isGenerating`` of the session.
    public internal(set) var isGenerating = false
    /// The number of ``ChatSessionSnapshot/pendingRequests``.
    public internal(set) var pendingRequestCount = 0
    /// The channel that drives the session: the origin of the turn that is
    /// generating, otherwise the reducer's
    /// ``ChatSessionStateReducer/defaultOrigin``.
    public internal(set) var activeChannel: ChatTurnOrigin

    init(workspace: URL, activeChannel: ChatTurnOrigin) {
        self.workspace = workspace
        self.activeChannel = activeChannel
    }
}

/// The observable state of one chat session, built by a
/// ``ChatSessionStateReducer`` from what the controller presents.
///
/// The ``log`` is the truth: every entry has a strictly increasing
/// ``ChatTurnEntry/sequence``, and ``transcript``, ``activity``, ``notices``,
/// and ``ChatFileChangesState/artifactHistory`` are projections of it, in log
/// order. The other members are independent sub-states. A client that keeps
/// the last sequence it saw catches up with
/// `log.filter { $0.sequence > lastSeen }` while ``epoch`` is unchanged and
/// `lastSeen + 1 >= firstRetainedSequence`; otherwise it rebuilds its view
/// from the snapshot.
///
/// A snapshot is transient: it is never saved with a session, nor copied
/// into a checkpoint.
public struct ChatSessionSnapshot: Sendable, Equatable {
    /// The session the controller runs.
    public internal(set) var sessionID: String
    /// Identifies the log: it changes each time the log is replaced because
    /// the controller switched session (a new session, a saved session
    /// loaded or restored from a checkpoint); compare it for equality only.
    /// A reducer composed by hand increases it by one at each switch. A
    /// reducer a ``ChatSessionHost`` created has the epoch of its
    /// incarnation, from a counter the host shares among all its slots, so
    /// it may grow by more; it stays the same when the session takes another
    /// id in place (``ChatSessionHost/adoptSessionID(_:in:)``), though the
    /// log starts over under the new ``sessionID``.
    public internal(set) var epoch: UInt64
    /// The log of the epoch, oldest first. It has the byte budget of the
    /// session transcript (128 MiB), estimated the way the transcript is: the
    /// oldest entries are dropped whole when it is exceeded.
    public internal(set) var log: [ChatTurnEntry] = []
    /// The lowest sequence the log still holds: every entry of the epoch with
    /// a sequence at or above it is in the log, the ones below were dropped
    /// by the bound or belong to an earlier epoch.
    public internal(set) var firstRetainedSequence: Int
    /// The prompts and closed assistant blocks of the log
    /// (``ChatTurnEntry/Kind/userPrompt(text:attachments:origin:)``,
    /// ``ChatTurnEntry/Kind/assistantText(_:)``, ``ChatTurnEntry/Kind/thought(_:)``).
    public internal(set) var transcript: [ChatTurnEntry] = []
    /// The tool calls of the log (``ChatTurnEntry/Kind/toolCallStarted(_:)``,
    /// ``ChatTurnEntry/Kind/toolCallCompleted(_:result:)``).
    public internal(set) var activity: [ChatTurnEntry] = []
    /// The turn that runs or ran last.
    public internal(set) var turn = ChatTurnState()
    /// The latest task-graph overview presented; `nil` when the session has
    /// no task graph.
    public internal(set) var taskGraph: ChatTaskGraphOverview?
    /// The latest sub-agent overview presented.
    public internal(set) var subAgents = ChatSubAgentOverview(snapshots: [])
    public internal(set) var fileChanges = ChatFileChangesState()
    /// The session's selection, as last presented.
    public internal(set) var selection: ChatSessionSelection
    /// The session's saved-session link, as last presented.
    public internal(set) var savedSession: ChatSavedSessionState
    /// The interactions the session waits for, oldest first (see
    /// ``ChatPendingRequestHost``).
    public internal(set) var pendingRequests: [ChatPendingRequest] = []
    /// The latest notices of the log (``ChatTurnEntry/Kind/notice(_:)``,
    /// ``ChatTurnEntry/Kind/workflowNotice(_:)``), at most
    /// ``ChatSessionStateReducer/maximumNoticeCount``.
    public internal(set) var notices: [ChatTurnEntry] = []
    public internal(set) var summary: ChatSessionSummary

    init(
        sessionID: String,
        epoch: UInt64,
        firstRetainedSequence: Int,
        workspace: URL,
        activeChannel: ChatTurnOrigin,
        state: ChatSessionState
    ) {
        self.sessionID = sessionID
        self.epoch = epoch
        self.firstRetainedSequence = firstRetainedSequence
        self.selection = state.selection
        self.savedSession = state.savedSession
        self.summary = ChatSessionSummary(workspace: workspace, activeChannel: activeChannel)
    }
}
