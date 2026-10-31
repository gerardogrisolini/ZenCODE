//
//  ChatTaskGraphObserver.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Publishes the session's task-graph overview while the graph changes.
///
/// The controller owns one observer (``ChatSessionController/taskGraphObserver``)
/// and the channel decides when it runs, through
/// ``ChatSessionController/startTaskGraphObserver()``,
/// ``ChatSessionController/stopTaskGraphObserver()``, and
/// ``ChatSessionController/quiesceTaskGraphObserver()``: the terminal starts it
/// on every session it creates, restores, or resets, quiesces it at every turn
/// boundary, and stops it when its input loop ends. A channel that never
/// starts it (the ACP bridge keeps its own per-prompt observer) pays nothing.
///
/// Every graph event reserves a publication at once (see
/// ``ChatSessionPresenter/reserveTaskGraphOverviewPublication()``), then
/// schedules a debounced publication that replaces the one still waiting:
/// a burst of changes settles for ``debounceInterval`` and the last one
/// publishes, after the publication it replaced has finished. The publication
/// is fenced on the session it observed and on the graph revision it read
/// (see ``ChatSessionController/publishTaskGraphOverviewIfChanged(observedSessionID:)``).
@ChatSessionActor
final class ChatTaskGraphObserver {
    /// How long a burst of graph changes settles before the observer publishes.
    nonisolated static let debounceInterval: Duration = .milliseconds(150)

    /// Waits out the debounce. A test replaces it with a gate it opens itself,
    /// before the observer starts.
    var sleep: @Sendable (Duration) async throws -> Void

    /// The task that consumes the graph events; `nil` while the observer is
    /// stopped.
    private(set) var observerTask: Task<Void, Never>?
    /// The debounced publication the last graph event scheduled, until the
    /// observer stops. Tracked so a stop (and the turn-boundary quiescence)
    /// drains it before returning.
    private(set) var pendingPublication: Task<Void, Never>?

    nonisolated init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = ChatTaskGraphObserver.defaultSleep
    ) {
        self.sleep = sleep
    }

    deinit {
        observerTask?.cancel()
        pendingPublication?.cancel()
    }

    nonisolated static func defaultSleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    /// Stops the running observer, then subscribes to the graph events of the
    /// controller's current session and starts consuming them.
    func start(for controller: ChatSessionController) async {
        await stop()
        let observedSessionID = controller.sessionID
        // Subscribe BEFORE spawning the consumer task and only then return:
        // registering the continuation here closes the snapshot→subscription
        // handoff window (the event stream has no replay), so a graph
        // mutation that lands after this call is seen by the new observer
        // even when a turn-boundary snapshot raced it. Events buffered
        // between registration and the consumer's first await are retained
        // by the stream.
        let stream = await controller.runtime.taskOrchestrator.events(
            sessionID: observedSessionID
        )

        observerTask = Task(name: "ZenCODE.Chat.task-graph-observer") { [weak self, weak controller] in
            for await _ in stream {
                guard !Task.isCancelled,
                      let controller,
                      controller.sessionID == observedSessionID else {
                    break
                }
                let publication = await controller.presenter.reserveTaskGraphOverviewPublication()
                guard let self, !Task.isCancelled else { break }
                let previousPublication = self.pendingPublication
                previousPublication?.cancel()
                let sleep = self.sleep
                self.pendingPublication = Task(
                    name: "ZenCODE.Chat.task-graph-publication"
                ) { [weak controller] in
                    try? await sleep(Self.debounceInterval)
                    await previousPublication?.value
                    guard !Task.isCancelled, let controller else { return }
                    await controller.publishReservedTaskGraphOverview(
                        observedSessionID: observedSessionID,
                        publication: publication
                    )
                }
            }
            if let pendingPublication = self?.pendingPublication {
                pendingPublication.cancel()
                await pendingPublication.value
                self?.pendingPublication = nil
            }
        }
    }

    /// Cancels the observer and its debounced publication and waits for both
    /// to finish.
    func stop() async {
        let observer = observerTask
        observerTask = nil
        observer?.cancel()
        await observer?.value
        if let pendingPublication {
            pendingPublication.cancel()
            await pendingPublication.value
            self.pendingPublication = nil
        }
    }
}

// MARK: - Task-graph observer

extension ChatSessionController {
    /// The task that consumes the graph events of the running observer; `nil`
    /// while it is stopped.
    var taskGraphObserverTask: Task<Void, Never>? {
        taskGraphObserver.observerTask
    }

    /// Binds the task-graph observer to the current session: it stops the
    /// running one and subscribes to the session's graph events before
    /// returning, so a change that lands after this call is published.
    func startTaskGraphObserver() async {
        await taskGraphObserver.start(for: self)
    }

    /// Stops the task-graph observer and drains its debounced publication.
    func stopTaskGraphObserver() async {
        await taskGraphObserver.stop()
    }

    /// Turn-boundary quiescence for the task-graph overview: stops the
    /// observer, drains any in-flight debounced publication, and publishes
    /// the latest known graph state once, so the retiring turn's final
    /// section reaches the channel while the turn is still being closed. The
    /// observer is NOT restarted here: the channel restarts it once it has
    /// closed the turn, so no observer-driven publication can cross that
    /// boundary. A restart should be followed by a fresh
    /// ``publishTaskGraphOverviewIfChanged(observedSessionID:)``, which also
    /// recovers graph mutations that landed between this publication and the
    /// new event subscription (the event stream has no replay).
    func quiesceTaskGraphObserver() async {
        await stopTaskGraphObserver()
        await publishTaskGraphOverviewIfChanged(observedSessionID: sessionID)
    }

    /// Reserves a publication and publishes the current task graph of
    /// `observedSessionID` as an automatic overview, while that session is
    /// still the active one. A session without a graph (or whose graph cannot
    /// be read) presents `nil`. A graph the session changed while it was being
    /// read is not presented: the change publishes it again.
    func publishTaskGraphOverviewIfChanged(observedSessionID: String) async {
        guard sessionID == observedSessionID else { return }
        let publication = await presenter.reserveTaskGraphOverviewPublication()
        await publishTaskGraphOverview(
            observedSessionID: observedSessionID,
            publication: publication
        )
    }

    /// The observer's debounced publication, with the reservation taken when
    /// the graph event arrived.
    func publishReservedTaskGraphOverview(
        observedSessionID: String,
        publication: ChatOverviewPublication?
    ) async {
        guard sessionID == observedSessionID else { return }
        await publishTaskGraphOverview(
            observedSessionID: observedSessionID,
            publication: publication
        )
    }

    private func publishTaskGraphOverview(
        observedSessionID: String,
        publication: ChatOverviewPublication?
    ) async {
        guard !Task.isCancelled else { return }
        guard let graph = try? await runtime.taskGraphSnapshot(
            sessionID: observedSessionID,
            graphID: nil
        ) else {
            guard !Task.isCancelled, sessionID == observedSessionID else { return }
            await presenter.presentTaskGraphOverview(
                nil,
                origin: .automatic,
                publication: publication
            )
            return
        }
        guard !Task.isCancelled, sessionID == observedSessionID else { return }
        guard let tasks = try? await runtime.taskOrchestrator.listTasks(
            sessionID: observedSessionID,
            graphID: graph.id
        ) else {
            return
        }
        guard !Task.isCancelled,
              sessionID == observedSessionID,
              let currentGraph = try? await runtime.taskGraphSnapshot(
                sessionID: observedSessionID,
                graphID: nil
              ),
              currentGraph.id == graph.id,
              currentGraph.revision == graph.revision else {
            return
        }
        guard !Task.isCancelled, sessionID == observedSessionID else { return }
        await presenter.presentTaskGraphOverview(
            ChatTaskGraphOverview(graph: graph, tasks: tasks),
            origin: .automatic,
            publication: publication
        )
    }
}
