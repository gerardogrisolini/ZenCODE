//
//  ChatSessionHost+SubAgentToolEvents.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/11/26.
//

import Foundation

// MARK: - Delegated tool events

extension ChatSessionHost {
    /// Makes the host's router the handler of the tool events of the
    /// delegated sub-agents of the host's ``runner``, once: from then on
    /// every event of that runner reaches the controller of the session its
    /// agent belongs to, among the slots that run on it
    /// (``routeSubAgentToolEvent(_:)``), whatever channel drives that
    /// session. The runner hands its handler to the backend it creates and
    /// before every model request, so a controller installs the router
    /// before its turn's request (``ChatSessionController/runTurn(_:)``, see
    /// ``installSubAgentToolEventRoutingIfNeeded(in:)``).
    /// The runner's handler belongs to the host from then on: nothing else
    /// may replace it (see
    /// ``AgentCoreSessionRunner/updateSubAgentToolEventHandler(_:)``), or
    /// the events reach no slot any more. Nothing happens after
    /// ``shutdown()``.
    func installSubAgentToolEventRoutingIfNeeded() async {
        guard !isShutDown, !isRoutingSubAgentToolEvents else { return }
        isRoutingSubAgentToolEvents = true
        await installSubAgentToolEventRouter(on: runner)
    }

    /// ``installSubAgentToolEventRoutingIfNeeded()`` for the runner of
    /// `slotID` (``runner(in:)``): the slot's dedicated runner, once for that
    /// runner, or the host's runner. Nothing happens for a slot that is not
    /// open, a dedicated runner already shut down, or after ``shutdown()``.
    func installSubAgentToolEventRoutingIfNeeded(in slotID: ChatSlotID) async {
        guard !isShutDown, let slot = slots[slotID] else { return }
        guard slot.usesDedicatedRunner else {
            await installSubAgentToolEventRoutingIfNeeded()
            return
        }
        guard dedicatedRunners[slotID] === slot.runner,
              subAgentToolEventRoutingSlots.insert(slotID).inserted else { return }
        await installSubAgentToolEventRouter(on: slot.runner)
    }

    /// Makes the host's router the handler of `runner`'s delegated tool
    /// events, routing each among the slots that run on `runner`. The runner
    /// is held weakly by its own handler.
    private func installSubAgentToolEventRouter(on runner: AgentCoreSessionRunner) async {
        await runner.updateSubAgentToolEventHandler { [weak self, weak runner] event in
            guard let runner else { return }
            await self?.routeSubAgentToolEvent(event, from: runner)
        }
    }

    /// ``routeSubAgentToolEvent(_:from:)`` for an event of the host's
    /// ``runner``.
    func routeSubAgentToolEvent(_ event: DirectSubAgentToolEvent) async {
        await routeSubAgentToolEvent(event, from: runner)
    }

    /// Hands `event`, a delegated tool event of `runner`, to the controller
    /// of every open slot on `runner` whose session is the agent's root
    /// session (the event's, or the one `runner`'s sub-agent snapshots know
    /// for the agent), in the order of their epochs, each while its
    /// incarnation is still live and still runs that session: the check and
    /// the hand-over happen with no suspension between them, so the
    /// controller takes the event as its session's
    /// (``ChatSessionController/presentSubAgentToolEvent(_:)``). A slot that
    /// replaced its incarnation or changed its session while an earlier
    /// slot presented the event is skipped. An event of a session no slot on
    /// `runner` runs, or that reaches a host already shut down, is dropped:
    /// a slot on another runner never sees it, even with the same session id.
    ///
    /// The delivery is sequential: the slots one after the other, each one
    /// awaited, and the sub-agent's work loop awaits the whole delivery
    /// before it goes on, so an agent's events arrive in order. A slow
    /// presentation slows the agent down without deadlocking it: while the
    /// terminal takes the slot back from Telegram and renders what it
    /// catches up with (``ChatSlotPresenter/holdOutput()``), the event waits
    /// with the rest of the slot's output, and so does the agent.
    func routeSubAgentToolEvent(
        _ event: DirectSubAgentToolEvent,
        from runner: AgentCoreSessionRunner
    ) async {
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
            .filter { $0.runner === runner }
            .compactMap(\.incarnation)
            .filter { $0.sessionID == rootSessionID }
            .sorted { $0.epoch < $1.epoch }
            .map { (slotID: $0.slotID, epoch: $0.epoch) }
        for target in targets {
            // An earlier delivery may have suspended while the slot moved on.
            guard let incarnation = liveIncarnation(in: target.slotID, epoch: target.epoch),
                  incarnation.sessionID == rootSessionID,
                  incarnation.runner === runner else { continue }
            await incarnation.controller.presentSubAgentToolEvent(event)
        }
    }
}
