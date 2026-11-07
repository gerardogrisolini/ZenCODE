//
//  ChatSessionHost+SubAgentToolEvents.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/11/26.
//

import Foundation

// MARK: - Delegated tool events

extension ChatSessionHost {
    /// Makes the host's router the runner's handler of the tool events of
    /// the delegated sub-agents, once: from then on every event reaches the
    /// controller of the session its agent belongs to
    /// (``routeSubAgentToolEvent(_:)``), whatever channel drives that
    /// session. The runner hands its handler to the backend it creates and
    /// before every model request, so a controller installs the router
    /// before its turn's request (``ChatSessionController/runTurn(_:)``).
    /// The runner's handler belongs to the host from then on: nothing else
    /// may replace it (see
    /// ``AgentCoreSessionRunner/updateSubAgentToolEventHandler(_:)``), or
    /// the events reach no slot any more. Nothing happens after
    /// ``shutdown(keepingExternalTools:)``.
    func installSubAgentToolEventRoutingIfNeeded() async {
        guard !isShutDown, !isRoutingSubAgentToolEvents else { return }
        isRoutingSubAgentToolEvents = true
        await runner.updateSubAgentToolEventHandler { [weak self] event in
            await self?.routeSubAgentToolEvent(event)
        }
    }

    /// Hands `event` to the controller of every open slot whose session is
    /// the agent's root session (the event's, or the one the runner's
    /// sub-agent snapshots know for the agent), in the order of their
    /// epochs, each while its incarnation is still live and still runs that
    /// session: the check and the hand-over happen with no suspension
    /// between them, so the controller takes the event as its session's
    /// (``ChatSessionController/presentSubAgentToolEvent(_:)``). A slot that
    /// replaced its incarnation or changed its session while an earlier
    /// slot presented the event is skipped. An event of a session no slot
    /// runs, or that reaches a host already shut down, is dropped.
    ///
    /// The delivery is sequential: the slots one after the other, each one
    /// awaited, and the sub-agent's work loop awaits the whole delivery
    /// before it goes on, so an agent's events arrive in order. A slow
    /// presentation slows the agent down without deadlocking it: while the
    /// terminal takes the slot back from Telegram and renders what it
    /// catches up with (``ChatSlotPresenter/holdOutput()``), the event waits
    /// with the rest of the slot's output, and so does the agent.
    func routeSubAgentToolEvent(_ event: DirectSubAgentToolEvent) async {
        guard !isShutDown else { return }
        let rootSessionID: String
        if let eventRootSessionID = event.rootSessionID {
            rootSessionID = eventRootSessionID
        } else {
            let snapshots = await runner.subAgentSnapshots()
            guard let agent = snapshots.first(where: { $0.id == event.agentID }) else { return }
            rootSessionID = agent.rootSessionID
        }
        let targets = slots.values
            .compactMap(\.incarnation)
            .filter { $0.sessionID == rootSessionID }
            .sorted { $0.epoch < $1.epoch }
            .map { (slotID: $0.slotID, epoch: $0.epoch) }
        for target in targets {
            // An earlier delivery may have suspended while the slot moved on.
            guard let incarnation = liveIncarnation(in: target.slotID, epoch: target.epoch),
                  incarnation.sessionID == rootSessionID else { continue }
            await incarnation.controller.presentSubAgentToolEvent(event)
        }
    }
}
