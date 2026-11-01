//
//  ChatSlotPresenter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/11/26.
//

import Foundation
import ToolCore

/// The presenter of every controller a slot runs: it forwards each call to
/// the presenter of the channel that drives the slot now
/// (``ChatSlot/activeChannel``), the channel's own presenter or the slot's
/// ``TelegramChannel``, so the controller presents the same way whichever
/// channel drives it. The reducer is not here: it observes the controller
/// (``ChatSessionController/addObserver(_:)``) and sees every event before
/// this presenter forwards it.
///
/// It tracks the turn in progress, so a channel switch during a turn tells
/// the new channel the turn moved onto it
/// (``ChatSlotChannelPresenter/turnDidMoveToChannel(_:)``) with the block
/// already streaming, and the overview reservations follow the channel too.
/// The slot holds it; it holds the slot weakly.
@ChatSessionActor
final class ChatSlotPresenter: ChatSessionPresenter {
    private weak var slot: ChatSlot?
    /// The presenter of the channel that opened the slot.
    private let primary: any ChatSessionPresenter
    /// The request of the turn running now, from ``turnWillStart(_:)`` to
    /// ``turnWillFinish()``.
    private(set) var openTurnRequest: ChatTurnRequest?
    /// The block streaming now, as the reducer keeps it: what a channel the
    /// turn moves onto did not see begin.
    private(set) var liveAssistantText = ""
    private(set) var liveThought = ""

    init(slot: ChatSlot, primary: any ChatSessionPresenter) {
        self.slot = slot
        self.primary = primary
    }

    /// The presenter of the channel that drives the slot now.
    var activePresenter: any ChatSessionPresenter {
        guard let slot else { return primary }
        switch slot.activeChannel {
        case .primary:
            return primary
        case .telegram:
            return slot.telegramChannel?.presenter ?? primary
        }
    }

    /// `true` between the start and the finish of a turn.
    var isTurnOpen: Bool {
        openTurnRequest != nil
    }

    /// The turn in progress as a moved turn, for the channel it moves onto;
    /// `nil` when no turn runs.
    var movedTurn: ChatMovedTurn? {
        guard let openTurnRequest else { return nil }
        return ChatMovedTurn(
            request: openTurnRequest,
            liveAssistantText: liveAssistantText,
            liveThought: liveThought
        )
    }

    /// Tells the channel that drives the slot now that the turn in progress
    /// moved onto it, when one runs and the channel can take it.
    func presentTurnMoveIfNeeded() async {
        guard let turn = movedTurn,
              let channelPresenter = activePresenter as? any ChatSlotChannelPresenter else {
            return
        }
        await channelPresenter.turnDidMoveToChannel(turn)
    }

    /// Presents `ending` on the channel that drives the slot now, when it
    /// presents endings; returns whether it did.
    @discardableResult
    func presentTurnEnding(_ ending: ChatTurnEnding) async -> Bool {
        guard let channelPresenter = activePresenter as? any ChatSlotChannelPresenter else {
            return false
        }
        await channelPresenter.presentTurnEnding(ending)
        return true
    }

    // MARK: - ChatSessionPresenter

    func turnWillStart(_ request: ChatTurnRequest) async {
        openTurnRequest = request
        liveAssistantText = ""
        liveThought = ""
        await activePresenter.turnWillStart(request)
    }

    func presentStatus(_ status: String) async {
        await activePresenter.presentStatus(status)
    }

    func presentDiagnostic(_ diagnostic: String) async {
        await activePresenter.presentDiagnostic(diagnostic)
    }

    func presentThought(_ thought: String) async {
        liveThought.append(thought)
        await activePresenter.presentThought(thought)
    }

    func presentAssistantContent(_ content: String) async {
        liveAssistantText.append(content)
        await activePresenter.presentAssistantContent(content)
    }

    func presentModelLoaded(_ modelID: String) async {
        await activePresenter.presentModelLoaded(modelID)
    }

    func presentMetrics(_ metrics: DirectAgentGenerationMetrics) async {
        await activePresenter.presentMetrics(metrics)
    }

    func presentContextWindow(_ status: DirectAgentContextWindowStatus) async {
        await activePresenter.presentContextWindow(status)
    }

    func presentSubscriptionUsage(_ status: DirectAgentSubscriptionUsageStatus) async {
        await activePresenter.presentSubscriptionUsage(status)
    }

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        // The tool call closes the block that preceded it, as the transcript
        // and the reducer close it.
        liveAssistantText = ""
        liveThought = ""
        await activePresenter.presentToolCallStarted(toolCall)
    }

    func presentToolCallCompleted(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        await activePresenter.presentToolCallCompleted(toolCall, result: result)
    }

    func presentToolCallSettled(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        await activePresenter.presentToolCallSettled(toolCall, result: result)
    }

    func presentLiveFileArtifacts(_ turns: [SessionFileArtifactHistory.Turn], agentID: String?) async {
        await activePresenter.presentLiveFileArtifacts(turns, agentID: agentID)
    }

    func presentSealedFileArtifacts(_ turn: SessionFileArtifactHistory.Turn) async {
        await activePresenter.presentSealedFileArtifacts(turn)
    }

    func presentFileChangeSummary(_ summary: TurnFileChangeSummary) async {
        await activePresenter.presentFileChangeSummary(summary)
    }

    func modelTurnDidReturn() async {
        await activePresenter.modelTurnDidReturn()
    }

    func presentFinalResponse(_ response: DirectAgentResponse) async {
        await activePresenter.presentFinalResponse(response)
    }

    func turnWillContinueAutomatically() async {
        liveAssistantText = ""
        liveThought = ""
        await activePresenter.turnWillContinueAutomatically()
    }

    func turnWillFinish() async {
        openTurnRequest = nil
        liveAssistantText = ""
        liveThought = ""
        await activePresenter.turnWillFinish()
    }

    func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async {
        await activePresenter.presentWorkflowNotice(notice)
    }

    func presentTurnEnded(_ outcome: DirectAgentTurnOutcome) async {
        await activePresenter.presentTurnEnded(outcome)
    }

    func presentSessionNotice(_ notice: ChatSessionNotice) async {
        await activePresenter.presentSessionNotice(notice)
    }

    func presentSessionStateChanged(_ state: ChatSessionState) async {
        // The saved-session name is the title the shell shows.
        slot?.shellFactsDidChange?()
        await activePresenter.presentSessionStateChanged(state)
    }

    func sessionDidChange(sessionID: String) async {
        await activePresenter.sessionDidChange(sessionID: sessionID)
    }

    func presentRestoredLog(_ entries: [ChatTurnEntry.Kind]) async {
        await activePresenter.presentRestoredLog(entries)
    }

    func presentSubmittedCommand(_ line: String) async {
        await activePresenter.presentSubmittedCommand(line)
    }

    func reserveTaskGraphOverviewPublication() async -> ChatOverviewPublication? {
        await activePresenter.reserveTaskGraphOverviewPublication()
    }

    func presentTaskGraphOverview(
        _ overview: ChatTaskGraphOverview?,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        await activePresenter.presentTaskGraphOverview(overview, origin: origin, publication: publication)
    }

    func reserveSubAgentOverviewPublication() async -> ChatOverviewPublication? {
        await activePresenter.reserveSubAgentOverviewPublication()
    }

    func presentSubAgentOverview(
        _ overview: ChatSubAgentOverview,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        await activePresenter.presentSubAgentOverview(overview, origin: origin, publication: publication)
    }
}
