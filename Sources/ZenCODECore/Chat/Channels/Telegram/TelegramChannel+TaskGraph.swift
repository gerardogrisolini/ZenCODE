//
//  TelegramChannel+TaskGraph.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/11/26.
//

import Foundation

/// The task-graph observer of an ACP session's slot while the channel drives
/// it.
///
/// The terminal runs the controller's observer (``ChatTaskGraphObserver``)
/// on every session it has, and its publications reach the chat through the
/// slot's presenter while Telegram drives the slot: on the terminal's slot
/// the channel starts nothing, so no second observer runs. The ACP bridge
/// never starts it: the editor's prompts publish the graph through their own
/// per-prompt observer, which does not run while Telegram drives the slot.
/// So on an ACP slot the channel observes the graph from the moment it
/// starts driving the slot (``startDriving()``, which sets
/// ``observesTaskGraph``, also when the slot runs no session yet), binds the
/// controller's observer to the session the slot runs and again to the
/// controller of every later incarnation, and stops it when it stops driving
/// (``stopDriving(shuttingDown:)``, and so `/telegram off`, ``detach()``, and
/// ``shutdown()``).
///
/// At the end of every turn it presents (``finishTurn(ending:)``) it
/// quiesces the observer as the terminal does at its turn boundaries: before
/// the turn's reporter retires the observer stops, its debounced publication
/// is drained, and the latest graph is published once to the turn that ends,
/// before its outcome (the card is deduplicated within a turn only, so, as on
/// the terminal's slot, every boundary publishes the current graph); once the
/// turn's reporting ended the observer runs again, followed by a fresh
/// publication that recovers a change of the handoff window (the event
/// stream has no replay) and, with no turn reported, sends nothing; only
/// then the next queued prompt starts. No observer-driven publication crosses
/// the boundary into the next turn.
///
/// Every binding, quiescence, and restart runs in order, each after the one
/// queued before it (``taskGraphObservationTask``), and
/// ``stopTaskGraphObservation()`` awaits them all before it stops the
/// observer, so none starts an observer after the stop. Its publications go
/// through the slot's presenter: to the channel's presenter while the
/// channel drives the slot, to the editor's silent presenter otherwise,
/// which presents nothing, so the editor never receives them. A publication
/// that arrives outside a turn, or after the turn's reporter retired, sends
/// nothing (see ``enqueueOverview(_:taskGraphSignature:)``).
extension TelegramChannel {
    /// Whether the channel runs the controller's task-graph observer while it
    /// drives the slot: only on the slot of an ACP session.
    var runsTaskGraphObserver: Bool {
        guard case .acpSession = host?.slotIdentity(slotID) else { return false }
        return true
    }

    /// Starts observing the graph when the channel runs the observer: from
    /// now on the observer is bound to the session the slot runs, now when
    /// it runs one, otherwise with the next incarnation.
    func startTaskGraphObservationIfNeeded() {
        guard runsTaskGraphObserver else { return }
        observesTaskGraph = true
        bindTaskGraphObserverIfNeeded()
    }

    /// Follows the slot's incarnation while the channel drives the slot and
    /// observes the graph: the observer moves to the new controller.
    func rebindTaskGraphObservationIfNeeded() {
        guard drivesSlot, observesTaskGraph else { return }
        bindTaskGraphObserverIfNeeded()
    }

    /// Binds the controller's observer to the session the slot runs now,
    /// unless it is bound to that controller already: the observer of the
    /// previous controller, if any, is stopped first.
    private func bindTaskGraphObserverIfNeeded() {
        guard let controller, taskGraphObservedController !== controller else { return }
        let previousController = taskGraphObservedController
        taskGraphObservedController = controller
        enqueueTaskGraphObservationWork {
            // The previous observer stops even when the observation was
            // stopped meanwhile: the stop only knows the latest controller.
            if let previousController, previousController !== controller {
                await previousController.stopTaskGraphObserver()
            }
            guard !Task.isCancelled else { return }
            await controller.startTaskGraphObserver()
        }
    }

    /// The turn-boundary quiescence of ``finishTurn(ending:)``, before the
    /// turn's reporter retires (see
    /// ``ChatSessionController/quiesceTaskGraphObserver()``): after the work
    /// queued before it, the observer stops, its debounced publication is
    /// drained, and the latest graph is published once, to the turn that
    /// ends. Returns the controller to restart once the turn's reporting
    /// ended, or `nil` when the channel observes no graph, or no longer that
    /// controller's.
    func quiesceTaskGraphObservationForTurnBoundary() async -> ChatSessionController? {
        guard observesTaskGraph, let controller = taskGraphObservedController else { return nil }
        await enqueueTaskGraphObservationWork {
            await controller.quiesceTaskGraphObserver()
        }.value
        guard observesTaskGraph, taskGraphObservedController === controller else { return nil }
        return controller
    }

    /// Runs the observer of `controller` again after the turn boundary, once
    /// the turn's reporting ended, as the terminal does: it subscribes again
    /// and publishes the graph once more, which recovers a change that
    /// landed between the quiescence and the new subscription; with no turn
    /// reported, that publication sends nothing. Waits for both, so the next
    /// turn starts after them. Nothing happens once the channel stopped
    /// observing the graph, or observes another controller's.
    func restartTaskGraphObservationAfterTurnBoundary(_ controller: ChatSessionController) async {
        guard observesTaskGraph, taskGraphObservedController === controller else { return }
        await enqueueTaskGraphObservationWork {
            guard !Task.isCancelled else { return }
            await controller.startTaskGraphObserver()
            guard !Task.isCancelled else { return }
            await controller.publishTaskGraphOverviewIfChanged(observedSessionID: controller.sessionID)
        }.value
    }

    /// Stops observing the graph: the work queued on the observer is
    /// cancelled and awaited, then the observer the channel bound is stopped,
    /// which waits for its debounced publication. Nothing happens when the
    /// channel observes no graph.
    func stopTaskGraphObservation() async {
        observesTaskGraph = false
        let task = taskGraphObservationTask
        taskGraphObservationTask = nil
        task?.cancel()
        await task?.value
        let controller = taskGraphObservedController
        taskGraphObservedController = nil
        await controller?.stopTaskGraphObserver()
    }

    /// Queues `work` on the observer after the work queued before it, as
    /// ``taskGraphObservationTask``, and returns its task.
    @discardableResult
    private func enqueueTaskGraphObservationWork(
        _ work: @escaping @ChatSessionActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = taskGraphObservationTask
        let task = Task(name: "ZenCODE.Telegram.task-graph-observation") { @ChatSessionActor in
            await previous?.value
            await work()
        }
        taskGraphObservationTask = task
        return task
    }
}
