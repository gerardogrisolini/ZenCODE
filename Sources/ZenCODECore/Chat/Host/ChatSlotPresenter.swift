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
/// While the channel that took the slot back renders what it catches up with
/// (``holdOutput()``), every call waits and then goes on, in order, so the
/// rest of the turn follows the catch-up and nothing of it is lost.
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
    /// The calls waiting for ``releaseOutput()``, oldest first; `nil` while
    /// the output is not held.
    private var heldOutputWaiters: [CheckedContinuation<Void, Never>]?

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

    /// Holds every call from now until ``releaseOutput()``, except the move of
    /// the turn (``presentTurnMoveIfNeeded()``): the channel that takes the
    /// slot back renders its catch-up meanwhile, and the turn it adopts goes
    /// on after it. The holder releases it before anything it awaits can wait
    /// for a held call.
    func holdOutput() {
        if heldOutputWaiters == nil {
            heldOutputWaiters = []
        }
    }

    /// Lets the held calls go on, in the order they were made.
    func releaseOutput() {
        let waiters = heldOutputWaiters ?? []
        heldOutputWaiters = nil
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// The presenter of the channel that drives the slot once the output is
    /// no longer held (``holdOutput()``).
    private func releasedActivePresenter() async -> any ChatSessionPresenter {
        while heldOutputWaiters != nil {
            await withCheckedContinuation { continuation in
                if heldOutputWaiters != nil {
                    heldOutputWaiters?.append(continuation)
                } else {
                    continuation.resume()
                }
            }
        }
        return activePresenter
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
        guard let channelPresenter = await releasedActivePresenter() as? any ChatSlotChannelPresenter else {
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
        await releasedActivePresenter().turnWillStart(request)
    }

    func presentStatus(_ status: String) async {
        await releasedActivePresenter().presentStatus(status)
    }

    func presentDiagnostic(_ diagnostic: String) async {
        await releasedActivePresenter().presentDiagnostic(diagnostic)
    }

    func presentThought(_ thought: String) async {
        liveThought.append(thought)
        await releasedActivePresenter().presentThought(thought)
    }

    func presentAssistantContent(_ content: String) async {
        liveAssistantText.append(content)
        await releasedActivePresenter().presentAssistantContent(content)
    }

    func presentModelLoaded(_ modelID: String) async {
        await releasedActivePresenter().presentModelLoaded(modelID)
    }

    func presentMetrics(_ metrics: DirectAgentGenerationMetrics) async {
        await releasedActivePresenter().presentMetrics(metrics)
    }

    func presentContextWindow(_ status: DirectAgentContextWindowStatus) async {
        await releasedActivePresenter().presentContextWindow(status)
    }

    func presentSubscriptionUsage(_ status: DirectAgentSubscriptionUsageStatus) async {
        await releasedActivePresenter().presentSubscriptionUsage(status)
    }

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        // The tool call closes the block that preceded it, as the transcript
        // and the reducer close it.
        liveAssistantText = ""
        liveThought = ""
        await releasedActivePresenter().presentToolCallStarted(toolCall)
    }

    func presentToolCallCompleted(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        await releasedActivePresenter().presentToolCallCompleted(toolCall, result: result)
    }

    func presentToolCallSettled(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        await releasedActivePresenter().presentToolCallSettled(toolCall, result: result)
    }

    func presentLiveFileArtifacts(_ turns: [SessionFileArtifactHistory.Turn], agentID: String?) async {
        await releasedActivePresenter().presentLiveFileArtifacts(turns, agentID: agentID)
    }

    func presentSubAgentToolEvent(_ event: DirectSubAgentToolEvent) async {
        await releasedActivePresenter().presentSubAgentToolEvent(event)
    }

    func presentSealedFileArtifacts(_ turn: SessionFileArtifactHistory.Turn) async {
        await releasedActivePresenter().presentSealedFileArtifacts(turn)
    }

    func presentFileChangeSummary(_ summary: TurnFileChangeSummary) async {
        await releasedActivePresenter().presentFileChangeSummary(summary)
    }

    func modelTurnDidReturn() async {
        await releasedActivePresenter().modelTurnDidReturn()
    }

    func presentFinalResponse(_ response: DirectAgentResponse) async {
        await releasedActivePresenter().presentFinalResponse(response)
    }

    func turnWillContinueAutomatically() async {
        liveAssistantText = ""
        liveThought = ""
        await releasedActivePresenter().turnWillContinueAutomatically()
    }

    func turnWillFinish() async {
        openTurnRequest = nil
        liveAssistantText = ""
        liveThought = ""
        await releasedActivePresenter().turnWillFinish()
    }

    func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async {
        await releasedActivePresenter().presentWorkflowNotice(notice)
    }

    func presentTurnEnded(_ outcome: DirectAgentTurnOutcome) async {
        await releasedActivePresenter().presentTurnEnded(outcome)
    }

    func presentSessionNotice(_ notice: ChatSessionNotice) async {
        await releasedActivePresenter().presentSessionNotice(notice)
    }

    func presentSessionStateChanged(_ state: ChatSessionState) async {
        // The saved-session name is the title the shell shows.
        slot?.shellFactsDidChange?()
        await releasedActivePresenter().presentSessionStateChanged(state)
    }

    func sessionDidChange(sessionID: String) async {
        await releasedActivePresenter().sessionDidChange(sessionID: sessionID)
    }

    func presentRestoredLog(_ entries: [ChatTurnEntry.Kind]) async {
        await releasedActivePresenter().presentRestoredLog(entries)
    }

    func presentSubmittedCommand(_ line: String) async {
        await releasedActivePresenter().presentSubmittedCommand(line)
    }

    func reserveTaskGraphOverviewPublication() async -> ChatOverviewPublication? {
        await releasedActivePresenter().reserveTaskGraphOverviewPublication()
    }

    func presentTaskGraphOverview(
        _ overview: ChatTaskGraphOverview?,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        await releasedActivePresenter().presentTaskGraphOverview(overview, origin: origin, publication: publication)
    }

    // The reservation and the presentation of an overview are forwarded to
    // the channel that drives the slot at each moment, so a channel switch
    // between them hands one channel's reservation to the other. Each
    // channel tells its own reservations apart (the terminal's revisions are
    // positive, Telegram's negative) and presents a foreign one as one
    // without a reservation.
    func reserveSubAgentOverviewPublication() async -> ChatOverviewPublication? {
        await releasedActivePresenter().reserveSubAgentOverviewPublication()
    }

    func presentSubAgentOverview(
        _ overview: ChatSubAgentOverview,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        await releasedActivePresenter().presentSubAgentOverview(overview, origin: origin, publication: publication)
    }
}
