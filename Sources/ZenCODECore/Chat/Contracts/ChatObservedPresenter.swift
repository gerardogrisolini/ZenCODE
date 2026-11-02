//
//  ChatObservedPresenter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// The presenter the controller presents through: it presents every call on
/// the controller's observers (``ChatSessionObserver``), in the order they
/// were added, and then on the primary presenter, awaiting each one, so every
/// presenter sees the controller's calls in event order and an observer sees
/// each call before the primary does. Internal: channels and observers never
/// see it; the controller creates one per operation
/// (``ChatSessionController/effectivePresenter(for:)``).
///
/// The overview reservations
/// (``ChatSessionPresenter/reserveTaskGraphOverviewPublication()`` and
/// ``ChatSessionPresenter/reserveSubAgentOverviewPublication()``) are asked of
/// the primary alone: the reservation orders the presenting channel's
/// publications, and observers do not draw overviews.
///
/// The observers are read from the controller at every call: an observer
/// added while a turn runs (the reducer a Telegram handover creates) sees
/// the rest of that turn, and one removed stops seeing it at once.
struct ChatObservedPresenter: ChatSessionPresenter {
    /// The channel's presenter, or the presenter the request bound to the
    /// turn.
    let primary: any ChatSessionPresenter
    /// The controller whose observers are presented on.
    private let controller: ChatSessionController

    init(primary: any ChatSessionPresenter, controller: ChatSessionController) {
        self.primary = primary
        self.controller = controller
    }

    /// Runs `call` on each observer, in the order they were added, and then
    /// on the primary, awaiting each one.
    private func present(_ call: (any ChatSessionPresenter) async -> Void) async {
        for observer in await controller.observers {
            await call(observer)
        }
        await call(primary)
    }

    func turnWillStart(_ request: ChatTurnRequest) async {
        await present { await $0.turnWillStart(request) }
    }

    func presentStatus(_ status: String) async {
        await present { await $0.presentStatus(status) }
    }

    func presentDiagnostic(_ diagnostic: String) async {
        await present { await $0.presentDiagnostic(diagnostic) }
    }

    func presentThought(_ thought: String) async {
        await present { await $0.presentThought(thought) }
    }

    func presentAssistantContent(_ content: String) async {
        await present { await $0.presentAssistantContent(content) }
    }

    func presentModelLoaded(_ modelID: String) async {
        await present { await $0.presentModelLoaded(modelID) }
    }

    func presentMetrics(_ metrics: DirectAgentGenerationMetrics) async {
        await present { await $0.presentMetrics(metrics) }
    }

    func presentContextWindow(_ status: DirectAgentContextWindowStatus) async {
        await present { await $0.presentContextWindow(status) }
    }

    func presentSubscriptionUsage(_ status: DirectAgentSubscriptionUsageStatus) async {
        await present { await $0.presentSubscriptionUsage(status) }
    }

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        await present { await $0.presentToolCallStarted(toolCall) }
    }

    func presentToolCallCompleted(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        await present { await $0.presentToolCallCompleted(toolCall, result: result) }
    }

    func presentToolCallSettled(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        await present { await $0.presentToolCallSettled(toolCall, result: result) }
    }

    func presentLiveFileArtifacts(_ turns: [SessionFileArtifactHistory.Turn], agentID: String?) async {
        await present { await $0.presentLiveFileArtifacts(turns, agentID: agentID) }
    }

    func presentSealedFileArtifacts(_ turn: SessionFileArtifactHistory.Turn) async {
        await present { await $0.presentSealedFileArtifacts(turn) }
    }

    func presentFileChangeSummary(_ summary: TurnFileChangeSummary) async {
        await present { await $0.presentFileChangeSummary(summary) }
    }

    func modelTurnDidReturn() async {
        await present { await $0.modelTurnDidReturn() }
    }

    func presentFinalResponse(_ response: DirectAgentResponse) async {
        await present { await $0.presentFinalResponse(response) }
    }

    func turnWillContinueAutomatically() async {
        await present { await $0.turnWillContinueAutomatically() }
    }

    func turnWillFinish() async {
        await present { await $0.turnWillFinish() }
    }

    func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async {
        await present { await $0.presentWorkflowNotice(notice) }
    }

    func presentTurnEnded(_ outcome: DirectAgentTurnOutcome) async {
        await present { await $0.presentTurnEnded(outcome) }
    }

    func presentSessionNotice(_ notice: ChatSessionNotice) async {
        await present { await $0.presentSessionNotice(notice) }
    }

    func presentSessionStateChanged(_ state: ChatSessionState) async {
        await present { await $0.presentSessionStateChanged(state) }
    }

    func sessionDidChange(sessionID: String) async {
        await present { await $0.sessionDidChange(sessionID: sessionID) }
    }

    func presentRestoredLog(_ entries: [ChatTurnEntry.Kind]) async {
        await present { await $0.presentRestoredLog(entries) }
    }

    func presentSubmittedCommand(_ line: String) async {
        await present { await $0.presentSubmittedCommand(line) }
    }

    /// The primary's reservation; the observers are not asked.
    func reserveTaskGraphOverviewPublication() async -> ChatOverviewPublication? {
        await primary.reserveTaskGraphOverviewPublication()
    }

    func presentTaskGraphOverview(
        _ overview: ChatTaskGraphOverview?,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        await present { await $0.presentTaskGraphOverview(overview, origin: origin, publication: publication) }
    }

    /// The primary's reservation; the observers are not asked.
    func reserveSubAgentOverviewPublication() async -> ChatOverviewPublication? {
        await primary.reserveSubAgentOverviewPublication()
    }

    func presentSubAgentOverview(
        _ overview: ChatSubAgentOverview,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        await present { await $0.presentSubAgentOverview(overview, origin: origin, publication: publication) }
    }
}
