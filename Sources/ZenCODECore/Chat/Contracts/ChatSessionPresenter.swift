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
}
