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
    /// the host's router hands to the controller of every slot that runs the
    /// session the agent belongs to (see
    /// ``ChatSessionHost/installSubAgentToolEventRoutingIfNeeded()``), the
    /// same way for every channel: the baseline of the files a started call
    /// touches is captured for the turn's file changes, the channel renders
    /// the event (``ChatSessionPresenter/presentSubAgentToolEvent(_:)``, on
    /// the presenter of the turn running now, the controller's otherwise), a
    /// completed call's file changes are recorded and presented as live
    /// artifacts of the turn, attributed to the agent, and the sub-agent
    /// overview is published on the presenter the event was presented on.
    ///
    /// The event is taken as an event of the session the controller runs now:
    /// routing it is the caller's job (the host's router hands it over only
    /// while the slot runs this controller on the agent's root session, with
    /// no suspension between that check and the call). The baseline and the
    /// artifacts need a recording turn; without one the event is presented
    /// and the overview published, nothing more.
    public func presentSubAgentToolEvent(_ event: DirectSubAgentToolEvent) async {
        let artifactTurn = activeFileArtifactTurn
        if case .started = event.lifecycle {
            await artifactTurn?.coordinator?.captureBaselineIfNeeded(forAgentToolCall: event.toolCall)
        }
        let presenter = subAgentToolEventPresenter()
        await presenter.presentSubAgentToolEvent(event)
        if case let .completed(result) = event.lifecycle {
            await publishLiveFileArtifacts(
                result, callID: event.toolCall.id, toolName: event.toolCall.name,
                agentID: event.agentID, context: artifactTurn
            )
        }
        await publishSubAgentOverviewIfChanged(presenter: presenter)
    }

    /// The presenter a delegated tool event is presented on: the presenter
    /// of the turn running now while that turn is current (a channel that
    /// binds a presenter to its turn, as ACP does, renders the event on it),
    /// and the controller's otherwise.
    private func subAgentToolEventPresenter() -> any ChatSessionPresenter {
        if let runningTurnPresenter,
           isCurrentTurn(runningTurnPresenter.token, sessionID: runningTurnPresenter.sessionID) {
            return runningTurnPresenter.presenter
        }
        return effectivePresenter(for: nil)
    }
}
