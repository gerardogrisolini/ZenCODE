//
//  ChatSessionStateReducer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation
import ToolCore

/// Builds the observable state of one chat session (``ChatSessionSnapshot``)
/// from what its controller presents.
///
/// The reducer is a presenter: a client either passes it to the controller as
/// its presenter, or adds it as an observer with
/// ``ChatSessionController/addObserver(_:)``, which also covers the presenter
/// an ACP prompt binds to its request and whatever channel presents the
/// session (see ``ChatSessionObserver``). It records every event in
/// one ordered log, assigning each entry its ``ChatTurnEntry/sequence`` in a
/// single place, and closes the assistant blocks where the session transcript
/// closes them, with the same rules as the transcript. The text still
/// streaming stays out of the log, in ``ChatTurnState/liveAssistantText`` and
/// ``ChatTurnState/liveThought``.
///
/// After every change it publishes the new snapshot on each stream returned
/// by ``snapshots()``. A stream keeps only the newest snapshot it has not
/// delivered yet, so a slow consumer skips intermediate snapshots, never
/// receives them out of order, and always ends on the latest one.
///
/// A session change (``ChatSessionPresenter/sessionDidChange(sessionID:)``)
/// replaces the log and, for a reducer composed by hand, increases
/// ``ChatSessionSnapshot/epoch``; a restored
/// session's transcript arrives as log entries
/// (``ChatSessionPresenter/presentRestoredLog(_:)``).
///
/// It is isolated to ``ChatSessionActor``, the controller's isolation, so it
/// receives the controller's calls in order without hopping, and the
/// ``ChatPendingRequestHost`` that publishes requests in its snapshot shares
/// that isolation.
@ChatSessionActor
public final class ChatSessionStateReducer: ChatSessionObserver {
    /// The most notices ``ChatSessionSnapshot/notices`` holds.
    public nonisolated static let maximumNoticeCount = 64

    /// The origin of a turn whose request names none
    /// (``ChatTurnRequest/origin``), and the
    /// ``ChatSessionSummary/activeChannel`` while no turn is generating.
    public nonisolated let defaultOrigin: ChatTurnOrigin

    /// The current state of the session.
    public private(set) var snapshot: ChatSessionSnapshot

    /// The bound of the log, on the estimate of
    /// ``ChatTurnEntry/retainedByteCount``.
    nonisolated let maximumLogBytes: Int
    /// `true` for a reducer whose epoch is assigned from outside, by the
    /// ``ChatSessionHost`` that created it with its incarnation: a session
    /// change then replaces the log but keeps the epoch, which identifies the
    /// incarnation, not the log.
    nonisolated let keepsEpochOnSessionChange: Bool
    private var nextSequence: Int
    /// The sequence the current log started from: 1, or the next sequence
    /// when the log started over for another session in place
    /// (``resetForSession(_:)``). A ``ChatSessionSnapshot/firstRetainedSequence``
    /// past it means the log's bound dropped entries of this log.
    private(set) var logStartSequence = 1
    private var nextTurnID = 1
    /// The estimated bytes of each log entry, in log order.
    private var logByteCounts: [Int] = []
    private var logRetainedBytes = 0
    /// The turn that entries are attributed to: from its start to its
    /// file-change summary, or to the start of the next turn when it reports
    /// none.
    private var openTurn: OpenTurn?
    /// Tool calls of the current turn already logged, as the transcript
    /// dedupes them.
    private var startedToolCallIDs = Set<String>()
    private var completedToolCallIDs = Set<String>()
    private var hasFirstPrompt = false
    private var firstPromptTitle: String?
    private var subscribers: [UUID: AsyncStream<ChatSessionSnapshot>.Continuation] = [:]
    /// `true` once ``finishSnapshots()`` ended the streams: a later
    /// ``snapshots()`` ends after its first snapshot.
    private var snapshotsAreFinished = false
    /// Called after a commit that changed ``ChatSessionSnapshot/summary``:
    /// the ``ChatSessionHost`` that created the reducer sets it, to show the
    /// summary in its ``ChatShellSnapshot``.
    var summaryDidChange: (@ChatSessionActor () -> Void)?

    private struct OpenTurn {
        let id: Int
        let origin: ChatTurnOrigin
        let purpose: ChatTurnPurpose
    }

    /// A reducer for the session `sessionID`, before anything is presented.
    /// `state` is the session's selection and saved-session link, and
    /// `epoch` the epoch of the first log; sequences start at 1.
    public nonisolated convenience init(
        sessionID: String,
        workingDirectory: URL,
        defaultOrigin: ChatTurnOrigin,
        state: ChatSessionState = ChatSessionState(),
        epoch: UInt64 = 0
    ) {
        self.init(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            defaultOrigin: defaultOrigin,
            state: state,
            epoch: epoch,
            maximumLogBytes: ChatSessionController.maximumTranscriptBytes
        )
    }

    /// A reducer for the session `controller` runs now, with its working
    /// directory, selection, and saved-session link. It does not attach
    /// itself: pass it to ``ChatSessionController/addObserver(_:)``.
    public convenience init(
        controller: ChatSessionController,
        defaultOrigin: ChatTurnOrigin,
        epoch: UInt64 = 0
    ) {
        self.init(
            sessionID: controller.sessionID,
            workingDirectory: controller.workingDirectory,
            defaultOrigin: defaultOrigin,
            state: controller.sessionState,
            epoch: epoch
        )
    }

    nonisolated init(
        sessionID: String,
        workingDirectory: URL,
        defaultOrigin: ChatTurnOrigin,
        state: ChatSessionState,
        epoch: UInt64,
        maximumLogBytes: Int,
        keepsEpochOnSessionChange: Bool = false
    ) {
        self.defaultOrigin = defaultOrigin
        self.maximumLogBytes = max(1, maximumLogBytes)
        self.keepsEpochOnSessionChange = keepsEpochOnSessionChange
        self.nextSequence = 1
        self.snapshot = ChatSessionSnapshot(
            sessionID: sessionID,
            epoch: epoch,
            firstRetainedSequence: 1,
            workspace: workingDirectory,
            activeChannel: defaultOrigin,
            state: state
        )
    }

    deinit {
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    // MARK: - Observation

    /// A stream of the session's snapshots: the current one at once, then
    /// one after every change. Each call returns a new stream; it ends when
    /// the consumer stops iterating or the reducer is released, and, for a
    /// reducer a ``ChatSessionHost`` created, when its incarnation ends,
    /// after the last snapshot (at once for a stream asked for later).
    public func snapshots() -> AsyncStream<ChatSessionSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ChatSessionSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        guard !snapshotsAreFinished else {
            continuation.yield(snapshot)
            continuation.finish()
            return stream
        }
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { @ChatSessionActor in
                self.subscribers[id] = nil
            }
        }
        continuation.yield(snapshot)
        return stream
    }

    /// Ends every stream of ``snapshots()`` after the snapshot it holds, and
    /// every later one after its first: the ``ChatSessionHost`` that created
    /// the reducer calls it when the incarnation ends, so that a view that
    /// follows the slot does not keep the log of a replaced session alive.
    func finishSnapshots() {
        snapshotsAreFinished = true
        let streams = subscribers
        subscribers.removeAll()
        for continuation in streams.values {
            continuation.finish()
        }
    }

    // MARK: - Turn

    public func turnWillStart(_ request: ChatTurnRequest) async {
        let id = nextTurnID
        nextTurnID += 1
        let origin = request.origin ?? defaultOrigin
        openTurn = OpenTurn(id: id, origin: origin, purpose: request.purpose)
        startedToolCallIDs = []
        completedToolCallIDs = []
        snapshot.turn.turnID = id
        snapshot.turn.phase = .started
        snapshot.turn.outcome = nil
        snapshot.turn.isGenerating = true
        snapshot.turn.liveAssistantText = ""
        snapshot.turn.liveThought = ""
        snapshot.fileChanges.turnSummary = nil
        append(.userPrompt(text: request.prompt, attachments: request.attachments, origin: origin))
        append(.turnPhase(.started))
        commit()
    }

    public func presentThought(_ thought: String) async {
        guard !thought.isEmpty else { return }
        snapshot.turn.liveThought.append(thought)
        commit()
    }

    public func presentAssistantContent(_ content: String) async {
        guard !content.isEmpty else { return }
        snapshot.turn.liveAssistantText.append(content)
        commit()
    }

    public func presentMetrics(_ metrics: DirectAgentGenerationMetrics) async {
        // The status bar's running merge: one definition for every consumer.
        let merged = DirectAgentGenerationMetrics.merging(current: snapshot.turn.metrics, update: metrics)
        guard merged != snapshot.turn.metrics else { return }
        snapshot.turn.metrics = merged
        commit()
    }

    public func presentContextWindow(_ status: DirectAgentContextWindowStatus) async {
        guard status != snapshot.turn.contextWindow else { return }
        snapshot.turn.contextWindow = status
        commit()
    }

    public func presentSubscriptionUsage(_ status: DirectAgentSubscriptionUsageStatus) async {
        guard status != snapshot.turn.subscriptionUsage else { return }
        snapshot.turn.subscriptionUsage = status
        commit()
    }

    public func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        guard logToolCallStarted(toolCall) else { return }
        commit()
    }

    public func presentToolCallCompleted(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        // A completion without a start logs the start first, as the
        // transcript does.
        let started = logToolCallStarted(toolCall)
        let completed = completedToolCallIDs.insert(toolCall.id).inserted
        if completed {
            append(.toolCallCompleted(toolCall, result: result))
        }
        guard started || completed else { return }
        commit()
    }

    public func presentLiveFileArtifacts(_ turns: [SessionFileArtifactHistory.Turn], agentID: String?) async {
        guard !turns.isEmpty else { return }
        for turn in turns {
            append(.fileArtifacts(turn, agentID: agentID, isSealed: false))
        }
        commit()
    }

    public func presentSealedFileArtifacts(_ turn: SessionFileArtifactHistory.Turn) async {
        append(.fileArtifacts(turn, agentID: nil, isSealed: true))
        commit()
    }

    public func modelTurnDidReturn() async {
        snapshot.turn.phase = .modelReturned
        append(.turnPhase(.modelReturned))
        commit()
    }

    public func turnWillContinueAutomatically() async {
        guard closeBlock() else { return }
        commit()
    }

    public func presentFinalResponse(_ response: DirectAgentResponse) async {
        if case .plan = openTurn?.purpose {
            // The transcript records the Planner response as the turn's last
            // assistant content (`finalizePlanningTurn`): coordinator content
            // is never presented in a `/plan` turn.
            snapshot.turn.liveAssistantText.append(response.text)
        }
        let block = ChatTurnBlockRules.finalBlock(
            assistantContent: snapshot.turn.liveAssistantText,
            reasoningContent: snapshot.turn.liveThought,
            finalResponseText: response.text
        )
        snapshot.turn.liveAssistantText = block.assistantContent
        snapshot.turn.liveThought = block.reasoningContent
        closeBlock()
        commit()
    }

    public func turnWillFinish() async {
        closeBlock()
        // Blank text never reaches the log; it ends with the turn.
        snapshot.turn.liveAssistantText = ""
        snapshot.turn.liveThought = ""
        snapshot.turn.phase = .finishing
        snapshot.turn.isGenerating = false
        append(.turnPhase(.finishing))
        commit()
    }

    public func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async {
        append(.workflowNotice(notice))
        commit()
    }

    public func presentFileChangeSummary(_ summary: TurnFileChangeSummary) async {
        snapshot.fileChanges.turnSummary = summary
        // The last call of a turn that reports file changes.
        openTurn = nil
        commit()
    }

    public func presentTurnEnded(_ outcome: DirectAgentTurnOutcome) async {
        snapshot.turn.phase = .ended(outcome)
        snapshot.turn.outcome = outcome
        append(.turnPhase(.ended(outcome)))
        commit()
    }

    // MARK: - Session

    public func presentSessionNotice(_ notice: ChatSessionNotice) async {
        append(.notice(notice))
        commit()
    }

    public func presentSessionStateChanged(_ state: ChatSessionState) async {
        guard state.selection != snapshot.selection
            || state.savedSession != snapshot.savedSession else {
            return
        }
        snapshot.selection = state.selection
        snapshot.savedSession = state.savedSession
        commit()
    }

    public func sessionDidChange(sessionID: String) async {
        resetForSession(sessionID)
    }

    /// The body of ``sessionDidChange(sessionID:)``, for the host that gives a
    /// session another id in place (``ChatSessionHost/adoptSessionID(_:in:)``)
    /// and must not suspend: the log starts over under `sessionID`, with the
    /// epoch kept or advanced as `keepsEpochOnSessionChange` says.
    func resetForSession(_ sessionID: String) {
        snapshot.sessionID = sessionID
        if !keepsEpochOnSessionChange {
            snapshot.epoch &+= 1
        }
        snapshot.log = []
        snapshot.firstRetainedSequence = nextSequence
        logStartSequence = nextSequence
        snapshot.transcript = []
        snapshot.activity = []
        snapshot.notices = []
        snapshot.fileChanges = ChatFileChangesState()
        snapshot.taskGraph = nil
        snapshot.subAgents = ChatSubAgentOverview(snapshots: [])
        // Subscription usage belongs to the account, not to the session.
        let subscriptionUsage = snapshot.turn.subscriptionUsage
        snapshot.turn = ChatTurnState()
        snapshot.turn.subscriptionUsage = subscriptionUsage
        logByteCounts = []
        logRetainedBytes = 0
        openTurn = nil
        startedToolCallIDs = []
        completedToolCallIDs = []
        hasFirstPrompt = false
        firstPromptTitle = nil
        commit()
    }

    public func presentRestoredLog(_ entries: [ChatTurnEntry.Kind]) async {
        guard !entries.isEmpty else { return }
        // A restore runs outside any turn; each prompt starts a restored one.
        openTurn = nil
        var turnID: Int?
        for kind in entries {
            if case .userPrompt = kind {
                turnID = nextTurnID
                nextTurnID += 1
            }
            append(kind, turnID: turnID)
        }
        commit()
    }

    // MARK: - Overviews

    public func presentTaskGraphOverview(
        _ overview: ChatTaskGraphOverview?,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        guard overview != snapshot.taskGraph else { return }
        snapshot.taskGraph = overview
        commit()
    }

    public func presentSubAgentOverview(
        _ overview: ChatSubAgentOverview,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        guard overview != snapshot.subAgents else { return }
        snapshot.subAgents = overview
        commit()
    }

    // MARK: - Pending requests

    /// Publishes `request`, which a ``ChatPendingRequestHost`` waits on.
    func addPendingRequest(_ request: ChatPendingRequest) {
        snapshot.pendingRequests.append(request)
        commit()
    }

    /// Withdraws the request `id` once it is resolved or cancelled.
    func removePendingRequest(id: UUID) {
        guard let index = snapshot.pendingRequests.firstIndex(where: { $0.id == id }) else { return }
        snapshot.pendingRequests.remove(at: index)
        commit()
    }

    // MARK: - Log

    /// Logs the start of `toolCall` once per turn, closing the block before
    /// it. Returns `false` when it was already logged.
    private func logToolCallStarted(_ toolCall: DirectAgentToolCall) -> Bool {
        guard startedToolCallIDs.insert(toolCall.id).inserted else { return false }
        closeBlock()
        append(.toolCallStarted(toolCall))
        return true
    }

    /// Moves the streaming block to the log, as the transcript flushes it:
    /// a block that is blank stays where it is. Returns `true` when it logged
    /// the block.
    @discardableResult
    private func closeBlock() -> Bool {
        let content = snapshot.turn.liveAssistantText
        let reasoning = snapshot.turn.liveThought
        guard ChatTurnBlockRules.hasBlock(assistantContent: content, reasoningContent: reasoning) else {
            return false
        }
        for kind in ChatTurnEntry.blockKinds(assistantContent: content, reasoningContent: reasoning) {
            append(kind)
        }
        snapshot.turn.liveAssistantText = ""
        snapshot.turn.liveThought = ""
        return true
    }

    /// Appends an entry attributed to the open turn.
    private func append(_ kind: ChatTurnEntry.Kind) {
        append(kind, turnID: openTurn?.id)
    }

    /// The one place that assigns a sequence: appends the entry to the log
    /// and to its projection, then bounds the log.
    private func append(_ kind: ChatTurnEntry.Kind, turnID: Int?) {
        let entry = ChatTurnEntry(sequence: nextSequence, turnID: turnID, kind: kind)
        nextSequence += 1
        let bytes = entry.retainedByteCount
        snapshot.log.append(entry)
        logByteCounts.append(bytes)
        logRetainedBytes = ChatSessionController.saturatingSum(logRetainedBytes, bytes)
        if kind.isTranscript {
            snapshot.transcript.append(entry)
        } else if kind.isActivity {
            snapshot.activity.append(entry)
        } else if kind.isNotice {
            snapshot.notices.append(entry)
            let excess = snapshot.notices.count - Self.maximumNoticeCount
            if excess > 0 {
                snapshot.notices.removeFirst(excess)
            }
        } else if kind.isFileArtifacts {
            snapshot.fileChanges.artifactHistory.append(entry)
        }
        if case let .userPrompt(text, _, _) = kind, !hasFirstPrompt {
            hasFirstPrompt = true
            firstPromptTitle = ChatSessionController.derivedSessionName(fromFirstPrompt: text)
        }
        boundLog()
    }

    /// Drops the oldest entries, whole, while the log exceeds its bound, and
    /// the projections with them.
    private func boundLog() {
        guard logRetainedBytes > maximumLogBytes else { return }
        var dropCount = 0
        var retainedBytes = logRetainedBytes
        while dropCount < logByteCounts.count, retainedBytes > maximumLogBytes {
            retainedBytes -= logByteCounts[dropCount]
            dropCount += 1
        }
        let firstRetainedSequence = snapshot.log[dropCount - 1].sequence + 1
        snapshot.log.removeFirst(dropCount)
        logByteCounts.removeFirst(dropCount)
        logRetainedBytes = retainedBytes
        snapshot.firstRetainedSequence = firstRetainedSequence
        Self.dropEntries(below: firstRetainedSequence, from: &snapshot.transcript)
        Self.dropEntries(below: firstRetainedSequence, from: &snapshot.activity)
        Self.dropEntries(below: firstRetainedSequence, from: &snapshot.notices)
        Self.dropEntries(below: firstRetainedSequence, from: &snapshot.fileChanges.artifactHistory)
    }

    private static func dropEntries(below sequence: Int, from entries: inout [ChatTurnEntry]) {
        let count = entries.prefix { $0.sequence < sequence }.count
        if count > 0 {
            entries.removeFirst(count)
        }
    }

    /// Brings the summary up to date and publishes the snapshot.
    private func commit() {
        let previousSummary = snapshot.summary
        snapshot.summary.isGenerating = snapshot.turn.isGenerating
        snapshot.summary.pendingRequestCount = snapshot.pendingRequests.count
        snapshot.summary.activeChannel = snapshot.turn.isGenerating
            ? openTurn?.origin ?? defaultOrigin
            : defaultOrigin
        snapshot.summary.title = snapshot.savedSession.savedSessionName?.nilIfBlank ?? firstPromptTitle
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
        if snapshot.summary != previousSummary {
            summaryDidChange?()
        }
    }
}
