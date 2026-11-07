//
//  ChatSessionController+SubAgentToolEvents.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/11/26.
//

import Foundation

// MARK: - Delegated tool events

extension ChatSessionController {
    /// Presents a tool call of a delegated sub-agent of the session, which
    /// the host's router hands to the controller of the session the agent
    /// belongs to (see ``ChatSessionHost/installSubAgentToolEventRoutingIfNeeded()``),
    /// the same way for every channel: the baseline of the files a started
    /// call touches is captured for the turn's file changes, the channel
    /// renders the event (``ChatSessionPresenter/presentSubAgentToolEvent(_:)``,
    /// on the presenter of the turn running now), a completed call's file
    /// changes are recorded and presented as live artifacts of the turn,
    /// attributed to the agent, and the sub-agent overview is published.
    ///
    /// Nothing happens unless the controller still runs `expectedSessionID`
    /// with the artifact history `expectedHistory` (by default, the ones it
    /// runs now); the baseline and the artifacts need a recording turn.
    public func presentSubAgentToolEvent(
        _ event: DirectSubAgentToolEvent,
        sessionID expectedSessionID: String? = nil,
        history expectedHistory: SessionFileArtifactHistory? = nil
    ) async {
        let observedSessionID = expectedSessionID ?? sessionID
        let history = expectedHistory ?? fileArtifactHistory
        guard sessionID == observedSessionID, fileArtifactHistory === history else { return }
        let artifactTurn = activeFileArtifactTurn
        if case .started = event.lifecycle {
            await artifactTurn?.coordinator?.captureBaselineIfNeeded(forAgentToolCall: event.toolCall)
        }
        await subAgentToolEventPresenter().presentSubAgentToolEvent(event)
        if case let .completed(result) = event.lifecycle {
            await publishLiveFileArtifacts(
                result, callID: event.toolCall.id, agentID: event.agentID,
                context: artifactTurn
            )
        }
        await publishSubAgentOverviewIfChanged()
    }

    /// The presenter a delegated tool event is presented on: the presenter
    /// of the turn running now while that turn is current (a channel that
    /// binds a presenter to its turn, as ACP does, renders the event on it),
    /// and the controller's otherwise.
    func subAgentToolEventPresenter() -> any ChatSessionPresenter {
        if let runningTurnPresenter,
           isCurrentTurn(runningTurnPresenter.token, sessionID: runningTurnPresenter.sessionID) {
            return runningTurnPresenter.presenter
        }
        return effectivePresenter(for: nil)
    }
}
