//
//  TerminalChat+Tasks.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    // MARK: - Task-graph observer

    /// Binds the shared task-graph observer to the current session (see
    /// ``ChatSessionController/startTaskGraphObserver()``). The terminal's
    /// task section starts over between the stop of the previous observer and
    /// the subscription of the new one.
    func startTaskGraphObserver() async {
        await chatSession.stopTaskGraphObserver()
        await renderCoordinator.resetOverview(.taskGraph)
        await chatSession.startTaskGraphObserver()
    }

    /// See ``ChatSessionController/stopTaskGraphObserver()``.
    func stopTaskGraphObserver() async {
        await chatSession.stopTaskGraphObserver()
    }

    /// Turn-boundary quiescence for the task-graph section (see
    /// ``ChatSessionController/quiesceTaskGraphObserver()``): the latest known
    /// section is published once while the turn's Telegram reporter is still
    /// alive. The caller restarts the observer only after that reporter has
    /// been retired, so no observer-driven render can cross the retirement
    /// boundary and be adopted by the next turn's reporter, and follows the
    /// restart with a fresh ``publishTaskGraphOverviewIfChanged(observedSessionID:)``.
    func quiesceTaskGraphObserverForTurnBoundary() async {
        await chatSession.quiesceTaskGraphObserver()
    }

    /// See ``ChatSessionController/publishTaskGraphOverviewIfChanged(observedSessionID:)``.
    func publishTaskGraphOverviewIfChanged(observedSessionID: String) async {
        await chatSession.publishTaskGraphOverviewIfChanged(
            observedSessionID: observedSessionID
        )
    }

    func shouldPublishDeferredTaskGraphOverview() async -> Bool {
        await renderCoordinator.shouldPublishDeferredOverview(.taskGraph)
    }

    // MARK: - Task-graph section

    /// Reserves the next publication of the task section: its revision fences
    /// every publication reserved before it and drops the section deferred
    /// so far.
    func reserveTaskGraphOverviewPublication() async -> ChatOverviewPublication {
        ChatOverviewPublication(
            revision: await renderCoordinator.beginOverviewPublication(.taskGraph)
        )
    }

    /// Renders an overview the controller presented, with the revision of
    /// its reservation. No graph forgets the section; an automatic graph
    /// below the threshold drops only the deferred section; an explicit
    /// overview (`/tasks`) is always written and leaves the remembered
    /// section alone.
    func renderTaskGraphOverview(
        _ overview: ChatTaskGraphOverview?,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        let revision = publication?.revision
        guard let overview else {
            await renderCoordinator.resetOverview(.taskGraph, revision: revision)
            return
        }
        switch origin {
        case .automatic:
            guard overview.isSignificant else {
                await renderCoordinator.clearDeferredOverview(.taskGraph, revision: revision)
                return
            }
            _ = await renderCoordinator.renderTaskGraphOverview(
                signature: overview.signature,
                markdown: TerminalTaskGraphLayout.markdown(graph: overview.graph, tasks: overview.tasks),
                revision: revision
            )
        case .explicit:
            _ = await renderCoordinator.renderTaskGraphOverview(
                signature: overview.signature,
                markdown: TerminalTaskGraphLayout.markdown(graph: overview.graph, tasks: overview.tasks),
                revision: revision,
                force: true,
                rememberSignature: false,
                origin: .explicit
            )
        }
    }

    nonisolated static func taskGraphOverviewSignature(_ graph: TaskGraphSnapshot) -> String {
        ChatTaskGraphOverview.signature(for: graph)
    }

    // MARK: - /tasks

    /// `/tasks` and its actions, run by the shared controller (see
    /// ``ChatSessionController/runTasksCommand(line:)``).
    func handleTasksCommand(_ command: String) async {
        await writeSessionNotices(await chatSession.runTasksCommand(line: command).notices)
    }

    nonisolated static func taskDetailMarkdown(_ view: TaskRecordView) -> String {
        ChatSessionNoticeText.taskDetailMarkdown(view)
    }
}
