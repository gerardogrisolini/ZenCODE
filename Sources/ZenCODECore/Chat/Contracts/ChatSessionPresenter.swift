//
//  ChatSessionPresenter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// Semantic output of a chat turn, rendered by each channel in its own format.
///
/// The controller calls these methods in event order and awaits each one, so a
/// presenter may rely on the order of the calls it receives. Every method has
/// a no-op default: a channel implements only what it renders.
protocol ChatSessionPresenter: Sendable {
    func turnWillStart(_ request: ChatTurnRequest) async
    func presentStatus(_ status: String) async
    func presentDiagnostic(_ diagnostic: String) async
    func presentThought(_ thought: String) async
    func presentAssistantContent(_ content: String) async
    func presentModelLoaded(_ modelID: String) async
    func presentMetrics(_ metrics: DirectAgentGenerationMetrics) async
    func presentContextWindow(_ status: DirectAgentContextWindowStatus) async
    func presentSubscriptionUsage(_ status: DirectAgentSubscriptionUsageStatus) async
    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async
    func presentToolCallCompleted(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async
    /// The completed tool call has been fully processed: its live file
    /// artifacts were presented and the plan progress it carried was applied.
    func presentToolCallSettled(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async
    /// File artifacts recorded while the turn runs. `agentID` is non-nil when
    /// a delegated agent produced them.
    func presentLiveFileArtifacts(_ turns: [SessionFileArtifactHistory.Turn], agentID: String?) async
    /// Artifacts of the sealed turn that were not presented live.
    func presentSealedFileArtifacts(_ turn: SessionFileArtifactHistory.Turn) async
    /// The reconciled file changes of the whole turn, sent once before the
    /// controller returns or throws.
    func presentFileChangeSummary(_ summary: TurnFileChangeSummary) async
    /// One model request of the turn returned successfully.
    func modelTurnDidReturn() async
    /// A `/goal` workflow is about to continue with an automatic turn.
    func turnWillContinueAutomatically() async
    /// The turn's model work and file-change seal are done; workflow notices
    /// and the file-change summary follow before the controller returns.
    func turnWillFinish() async
    /// A `/goal` workflow changed state at the end of a turn.
    func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async
    func presentTurnEnded(_ outcome: DirectAgentTurnOutcome) async
    /// The outcome of a session operation, selection command, or shared slash
    /// command (`/sessions`, `/models`, `/think`, `/agents`, `/tools`,
    /// `/skills`, `/help`, `/plan`, `/goal`, `/review`, `/tasks`, `/changes`,
    /// `/undo`, `/artifacts`, `/open`, `/attach`). A text channel writes
    /// ``ChatSessionNoticeText/text(for:)`` on the channel named by
    /// ``ChatSessionNotice/channel``.
    func presentSessionNotice(_ notice: ChatSessionNotice) async
    /// The selection or the saved-session link of the active session changed;
    /// `state` is the complete new state, for channels that mirror it.
    func presentSessionStateChanged(_ state: ChatSessionState) async
    /// The operator submitted a slash command line that the shared commands
    /// run (`/plan`, `/goal`, `/review`, `/tasks`, and the other commands that
    /// echo their line); a channel that echoes submitted lines writes it now,
    /// before the command's output.
    func presentSubmittedCommand(_ line: String) async
    /// Reserves the next publication of the task-graph overview. The
    /// controller calls it where a publication starts, before it reads the
    /// graph: for the observer as soon as the graph changes (before the
    /// debounce), for `/tasks` and every other publication when its read
    /// begins. It passes the reservation back to
    /// ``presentTaskGraphOverview(_:origin:publication:)``, so a channel can
    /// drop a publication that a later one overtook and can drop at once a
    /// section it was holding back (see ``ChatOverviewPublication``). A channel
    /// that does not order its publications returns `nil` (the default).
    func reserveTaskGraphOverviewPublication() async -> ChatOverviewPublication?
    /// The session's task graph changed, or the operator asked for it with
    /// `/tasks`. `nil` means the session has no task graph. An
    /// ``ChatOverviewOrigin/automatic`` overview may be below the threshold
    /// (``ChatTaskGraphOverview/isSignificant``), which a channel does not
    /// show; an ``ChatOverviewOrigin/explicit`` one is always shown.
    /// `publication` is the reservation this publication started with, `nil`
    /// when the channel reserved nothing: then the overview is presented as it
    /// comes, without ordering it against other publications.
    func presentTaskGraphOverview(
        _ overview: ChatTaskGraphOverview?,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async
    /// Reserves the next publication of the sub-agent overview. The
    /// controller calls it where a publication starts, before it reads the
    /// sub-agent snapshots, and passes the reservation back to
    /// ``presentSubAgentOverview(_:origin:publication:)``, so a channel can
    /// drop a publication that a later one overtook and can drop at once a
    /// section it was holding back (see ``ChatOverviewPublication``). A channel
    /// that does not order its publications returns `nil` (the default).
    func reserveSubAgentOverviewPublication() async -> ChatOverviewPublication?
    /// The session's sub-agents, read when the channel asked the controller
    /// to publish them (see
    /// ``ChatSessionController/publishSubAgentOverviewIfChanged(relatedToolName:presenter:)``
    /// and the refresh that runs while a blocking `agent.*` tool call
    /// executes). An overview without snapshots means there is no sub-agent
    /// to show. `publication` is the reservation this publication started
    /// with, `nil` when the channel reserved nothing: then the overview is
    /// presented as it comes, without ordering it against other publications.
    func presentSubAgentOverview(
        _ overview: ChatSubAgentOverview,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async
}

extension ChatSessionPresenter {
    func turnWillStart(_ request: ChatTurnRequest) async {}
    func presentStatus(_ status: String) async {}
    func presentDiagnostic(_ diagnostic: String) async {}
    func presentThought(_ thought: String) async {}
    func presentAssistantContent(_ content: String) async {}
    func presentModelLoaded(_ modelID: String) async {}
    func presentMetrics(_ metrics: DirectAgentGenerationMetrics) async {}
    func presentContextWindow(_ status: DirectAgentContextWindowStatus) async {}
    func presentSubscriptionUsage(_ status: DirectAgentSubscriptionUsageStatus) async {}
    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {}
    func presentToolCallCompleted(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {}
    func presentToolCallSettled(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {}
    func presentLiveFileArtifacts(_ turns: [SessionFileArtifactHistory.Turn], agentID: String?) async {}
    func presentSealedFileArtifacts(_ turn: SessionFileArtifactHistory.Turn) async {}
    func presentFileChangeSummary(_ summary: TurnFileChangeSummary) async {}
    func modelTurnDidReturn() async {}
    func turnWillContinueAutomatically() async {}
    func turnWillFinish() async {}
    func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async {}
    func presentTurnEnded(_ outcome: DirectAgentTurnOutcome) async {}
    func presentSessionNotice(_ notice: ChatSessionNotice) async {}
    func presentSessionStateChanged(_ state: ChatSessionState) async {}
    func presentSubmittedCommand(_ line: String) async {}
    func reserveTaskGraphOverviewPublication() async -> ChatOverviewPublication? {
        nil
    }
    func presentTaskGraphOverview(
        _ overview: ChatTaskGraphOverview?,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {}
    func reserveSubAgentOverviewPublication() async -> ChatOverviewPublication? {
        nil
    }
    func presentSubAgentOverview(
        _ overview: ChatSubAgentOverview,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {}
}
