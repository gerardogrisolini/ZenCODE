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
    /// Nothing happens after ``shutdown(keepingExternalTools:)``.
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
    /// epochs, each while its incarnation is still live; see
    /// ``ChatSessionController/presentSubAgentToolEvent(_:sessionID:history:)``.
    /// An event of a session no slot runs, or that reaches a host already
    /// shut down, is dropped.
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
