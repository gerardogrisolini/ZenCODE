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
protocol ChatCompanionPresenter: AnyObject, ChatSessionPresenter {}

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

    func turnWillStart(_ request: ChatTurnRequest) async {
        for companion in companions {
            await companion.turnWillStart(request)
        }
        await primary.turnWillStart(request)
    }

    func presentStatus(_ status: String) async {
        for companion in companions {
            await companion.presentStatus(status)
        }
        await primary.presentStatus(status)
    }

    func presentDiagnostic(_ diagnostic: String) async {
        for companion in companions {
            await companion.presentDiagnostic(diagnostic)
        }
        await primary.presentDiagnostic(diagnostic)
    }

    func presentThought(_ thought: String) async {
        for companion in companions {
            await companion.presentThought(thought)
        }
        await primary.presentThought(thought)
    }

    func presentAssistantContent(_ content: String) async {
        for companion in companions {
            await companion.presentAssistantContent(content)
        }
        await primary.presentAssistantContent(content)
    }

    func presentModelLoaded(_ modelID: String) async {
        for companion in companions {
            await companion.presentModelLoaded(modelID)
        }
        await primary.presentModelLoaded(modelID)
    }

    func presentMetrics(_ metrics: DirectAgentGenerationMetrics) async {
        for companion in companions {
            await companion.presentMetrics(metrics)
        }
        await primary.presentMetrics(metrics)
    }

    func presentContextWindow(_ status: DirectAgentContextWindowStatus) async {
        for companion in companions {
            await companion.presentContextWindow(status)
        }
        await primary.presentContextWindow(status)
    }

    func presentSubscriptionUsage(_ status: DirectAgentSubscriptionUsageStatus) async {
        for companion in companions {
            await companion.presentSubscriptionUsage(status)
        }
        await primary.presentSubscriptionUsage(status)
    }

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        for companion in companions {
            await companion.presentToolCallStarted(toolCall)
        }
        await primary.presentToolCallStarted(toolCall)
    }

    func presentToolCallCompleted(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        for companion in companions {
            await companion.presentToolCallCompleted(toolCall, result: result)
        }
        await primary.presentToolCallCompleted(toolCall, result: result)
    }

    func presentToolCallSettled(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        for companion in companions {
            await companion.presentToolCallSettled(toolCall, result: result)
        }
        await primary.presentToolCallSettled(toolCall, result: result)
    }

    func presentLiveFileArtifacts(_ turns: [SessionFileArtifactHistory.Turn], agentID: String?) async {
        for companion in companions {
            await companion.presentLiveFileArtifacts(turns, agentID: agentID)
        }
        await primary.presentLiveFileArtifacts(turns, agentID: agentID)
    }

    func presentSealedFileArtifacts(_ turn: SessionFileArtifactHistory.Turn) async {
        for companion in companions {
            await companion.presentSealedFileArtifacts(turn)
        }
        await primary.presentSealedFileArtifacts(turn)
    }

    func presentFileChangeSummary(_ summary: TurnFileChangeSummary) async {
        for companion in companions {
            await companion.presentFileChangeSummary(summary)
        }
        await primary.presentFileChangeSummary(summary)
    }

    func modelTurnDidReturn() async {
        for companion in companions {
            await companion.modelTurnDidReturn()
        }
        await primary.modelTurnDidReturn()
    }

    func turnWillContinueAutomatically() async {
        for companion in companions {
            await companion.turnWillContinueAutomatically()
        }
        await primary.turnWillContinueAutomatically()
    }

    func turnWillFinish() async {
        for companion in companions {
            await companion.turnWillFinish()
        }
        await primary.turnWillFinish()
    }

    func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async {
        for companion in companions {
            await companion.presentWorkflowNotice(notice)
        }
        await primary.presentWorkflowNotice(notice)
    }

    func presentTurnEnded(_ outcome: DirectAgentTurnOutcome) async {
        for companion in companions {
            await companion.presentTurnEnded(outcome)
        }
        await primary.presentTurnEnded(outcome)
    }

    func presentSessionNotice(_ notice: ChatSessionNotice) async {
        for companion in companions {
            await companion.presentSessionNotice(notice)
        }
        await primary.presentSessionNotice(notice)
    }

    func presentSessionStateChanged(_ state: ChatSessionState) async {
        for companion in companions {
            await companion.presentSessionStateChanged(state)
        }
        await primary.presentSessionStateChanged(state)
    }

    func presentSubmittedCommand(_ line: String) async {
        for companion in companions {
            await companion.presentSubmittedCommand(line)
        }
        await primary.presentSubmittedCommand(line)
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
        for companion in companions {
            await companion.presentTaskGraphOverview(overview, origin: origin, publication: publication)
        }
        await primary.presentTaskGraphOverview(overview, origin: origin, publication: publication)
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
        for companion in companions {
            await companion.presentSubAgentOverview(overview, origin: origin, publication: publication)
        }
        await primary.presentSubAgentOverview(overview, origin: origin, publication: publication)
    }
}
