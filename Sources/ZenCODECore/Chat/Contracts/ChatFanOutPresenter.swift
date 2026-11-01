//
//  ChatFanOutPresenter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// A presenter that mirrors a session's output next to its primary channel,
/// such as a messaging companion that follows a terminal session.
///
/// A companion never runs alone: it is attached to the controller of a
/// session that already has a primary presenter (see
/// ``ChatSessionController/attachCompanionPresenter(_:)``), and receives the
/// same calls, in the same order, through a ``ChatFanOutPresenter``. The
/// controller holds it strongly until it is detached
/// (``ChatSessionController/detachCompanionPresenter(_:)``), and identifies it
/// by its object identity.
///
/// Like every ``ChatSessionPresenter`` it is `Sendable`, so a conforming class
/// must be safe to call from any concurrency domain: an actor, a class
/// isolated to a global actor, or a final class whose mutable state is
/// protected by a lock. The controller calls it from ``ChatSessionActor`` and
/// awaits each call before the primary's, so a companion that blocks delays
/// the primary channel's output.
///
/// A companion does not draw the task-graph or sub-agent overviews: those
/// publications are ordered by the primary channel alone, which may mirror
/// them itself. ``ChatFanOutPresenter`` still forwards
/// ``ChatSessionPresenter/presentTaskGraphOverview(_:origin:publication:)``
/// and ``ChatSessionPresenter/presentSubAgentOverview(_:origin:publication:)``
/// to it, with the primary's reservation, which is harmless only while a
/// companion keeps their no-op defaults.
public protocol ChatCompanionPresenter: AnyObject, ChatSessionPresenter {}

/// Presents every call on the companions, in the order they were attached,
/// and then on the primary presenter, awaiting each one, so every presenter
/// sees the controller's calls in event order and a companion sees each call
/// before the primary does.
///
/// The overview reservations
/// (``ChatSessionPresenter/reserveTaskGraphOverviewPublication()`` and
/// ``ChatSessionPresenter/reserveSubAgentOverviewPublication()``) are asked of
/// the primary alone: the reservation orders the primary channel's
/// publications, and companions do not draw overviews (see
/// ``ChatCompanionPresenter``).
///
/// The controller builds one from the companions attached when an operation
/// starts (see ``ChatSessionController/effectivePresenter(for:)``): a turn
/// keeps the companions it started with, and an attachment or a detachment
/// applies from the next operation.
struct ChatFanOutPresenter: ChatSessionPresenter {
    /// The channel the session belongs to, or the presenter its request bound
    /// to the turn.
    let primary: any ChatSessionPresenter
    /// The companions, in the order they were attached.
    let companions: [any ChatCompanionPresenter]

    init(primary: any ChatSessionPresenter, companions: [any ChatCompanionPresenter]) {
        self.primary = primary
        self.companions = companions
    }

    /// Runs `call` on each companion, in the order they were attached, and
    /// then on the primary, awaiting each one.
    private func fanOut(_ call: (any ChatSessionPresenter) async -> Void) async {
        for companion in companions {
            await call(companion)
        }
        await call(primary)
    }

    func turnWillStart(_ request: ChatTurnRequest) async {
        await fanOut { await $0.turnWillStart(request) }
    }

    func presentStatus(_ status: String) async {
        await fanOut { await $0.presentStatus(status) }
    }

    func presentDiagnostic(_ diagnostic: String) async {
        await fanOut { await $0.presentDiagnostic(diagnostic) }
    }

    func presentThought(_ thought: String) async {
        await fanOut { await $0.presentThought(thought) }
    }

    func presentAssistantContent(_ content: String) async {
        await fanOut { await $0.presentAssistantContent(content) }
    }

    func presentModelLoaded(_ modelID: String) async {
        await fanOut { await $0.presentModelLoaded(modelID) }
    }

    func presentMetrics(_ metrics: DirectAgentGenerationMetrics) async {
        await fanOut { await $0.presentMetrics(metrics) }
    }

    func presentContextWindow(_ status: DirectAgentContextWindowStatus) async {
        await fanOut { await $0.presentContextWindow(status) }
    }

    func presentSubscriptionUsage(_ status: DirectAgentSubscriptionUsageStatus) async {
        await fanOut { await $0.presentSubscriptionUsage(status) }
    }

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        await fanOut { await $0.presentToolCallStarted(toolCall) }
    }

    func presentToolCallCompleted(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        await fanOut { await $0.presentToolCallCompleted(toolCall, result: result) }
    }

    func presentToolCallSettled(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        await fanOut { await $0.presentToolCallSettled(toolCall, result: result) }
    }

    func presentLiveFileArtifacts(_ turns: [SessionFileArtifactHistory.Turn], agentID: String?) async {
        await fanOut { await $0.presentLiveFileArtifacts(turns, agentID: agentID) }
    }

    func presentSealedFileArtifacts(_ turn: SessionFileArtifactHistory.Turn) async {
        await fanOut { await $0.presentSealedFileArtifacts(turn) }
    }

    func presentFileChangeSummary(_ summary: TurnFileChangeSummary) async {
        await fanOut { await $0.presentFileChangeSummary(summary) }
    }

    func modelTurnDidReturn() async {
        await fanOut { await $0.modelTurnDidReturn() }
    }

    func turnWillContinueAutomatically() async {
        await fanOut { await $0.turnWillContinueAutomatically() }
    }

    func turnWillFinish() async {
        await fanOut { await $0.turnWillFinish() }
    }

    func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async {
        await fanOut { await $0.presentWorkflowNotice(notice) }
    }

    func presentTurnEnded(_ outcome: DirectAgentTurnOutcome) async {
        await fanOut { await $0.presentTurnEnded(outcome) }
    }

    func presentSessionNotice(_ notice: ChatSessionNotice) async {
        await fanOut { await $0.presentSessionNotice(notice) }
    }

    func presentSessionStateChanged(_ state: ChatSessionState) async {
        await fanOut { await $0.presentSessionStateChanged(state) }
    }

    func presentSubmittedCommand(_ line: String) async {
        await fanOut { await $0.presentSubmittedCommand(line) }
    }

    /// The primary's reservation; the companions are not asked.
    func reserveTaskGraphOverviewPublication() async -> ChatOverviewPublication? {
        await primary.reserveTaskGraphOverviewPublication()
    }

    func presentTaskGraphOverview(
        _ overview: ChatTaskGraphOverview?,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        await fanOut { await $0.presentTaskGraphOverview(overview, origin: origin, publication: publication) }
    }

    /// The primary's reservation; the companions are not asked.
    func reserveSubAgentOverviewPublication() async -> ChatOverviewPublication? {
        await primary.reserveSubAgentOverviewPublication()
    }

    func presentSubAgentOverview(
        _ overview: ChatSubAgentOverview,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        await fanOut { await $0.presentSubAgentOverview(overview, origin: origin, publication: publication) }
    }
}
