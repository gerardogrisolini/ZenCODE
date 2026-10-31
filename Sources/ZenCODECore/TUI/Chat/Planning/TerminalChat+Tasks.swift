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
                markdown: Self.taskGraphMarkdown(graph: overview.graph, tasks: overview.tasks),
                revision: revision
            )
        case .explicit:
            _ = await renderCoordinator.renderTaskGraphOverview(
                signature: overview.signature,
                markdown: Self.taskGraphMarkdown(graph: overview.graph, tasks: overview.tasks),
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

    nonisolated static func taskGraphMarkdown(
        graph: TaskGraphSnapshot,
        tasks: [TaskRecordView],
        ansiEnabled: Bool = AgentOutput.standardErrorIsTerminal
    ) -> String {
        let completed = tasks.filter { $0.task.status == .completed }.count
        let running = tasks.filter { $0.task.status == .inProgress }.count
        let validating = tasks.filter { $0.task.status == .awaitingValidation }.count
        let waiting = tasks.filter { $0.task.status == .pending }.count
        let blocked = tasks.filter { $0.task.status == .blocked }.count
        let failed = tasks.filter { $0.task.status == .failed }.count

        var summary = ["\(tasks.count) total"]
        if running > 0 {
            summary.append(
                taskSummarySegment(
                    "▸ \(running) running",
                    color: TerminalStyle.Status.active,
                    ansiEnabled: ansiEnabled
                )
            )
        }
        if completed > 0 {
            summary.append(
                taskSummarySegment(
                    "✓ \(completed) completed",
                    color: TerminalStyle.Status.success,
                    ansiEnabled: ansiEnabled
                )
            )
        }
        if validating > 0 {
            summary.append(
                taskSummarySegment(
                    "◇ \(validating) awaiting validation",
                    color: TerminalStyle.Status.inactive,
                    ansiEnabled: ansiEnabled
                )
            )
        }
        if waiting > 0 {
            summary.append(
                taskSummarySegment(
                    "◇ \(waiting) waiting",
                    color: TerminalStyle.Status.inactive,
                    ansiEnabled: ansiEnabled
                )
            )
        }
        if blocked > 0 {
            summary.append(
                taskSummarySegment(
                    "⊘ \(blocked) blocked",
                    color: TerminalStyle.Status.queued,
                    ansiEnabled: ansiEnabled
                )
            )
        }
        if failed > 0 {
            summary.append(
                taskSummarySegment(
                    "✗ \(failed) failed",
                    color: TerminalStyle.Status.failure,
                    ansiEnabled: ansiEnabled
                )
            )
        }

        let orange = TerminalStyle.Accent.primary
        let reset = TerminalStyle.reset
        let taskHeader = ansiEnabled ? "\(orange)Tasks:\(reset)" : "Tasks:"
        var lines = [
            "🫧 \(taskHeader)",
            summary.joined(separator: " "),
            "",
            "**Graph:** `\(graph.id)` · **state:** `\(graph.state.rawValue)` · **revision:** `\(graph.revision)`",
        ]
        if tasks.isEmpty {
            lines.append("No tasks.")
            return lines.joined(separator: "\n") + "\n"
        }

        for view in tasks.sorted(by: { lhs, rhs in
            if lhs.task.order != rhs.task.order { return lhs.task.order < rhs.task.order }
            return lhs.task.id < rhs.task.id
        }) {
            let marker: String
            switch view.task.status {
            case .completed: marker = "✓"
            case .inProgress: marker = "▸"
            case .awaitingValidation: marker = "◇"
            case .blocked: marker = "⊘"
            case .failed: marker = "✗"
            case .cancelled: marker = "—"
            case .pending: marker = "○"
            }
            var suffix: [String] = []
            suffix.append("complexity: `\(view.task.complexity)/10`")
            if let agentID = view.task.assigneeAgentID {
                suffix.append(agentID)
            }
            if !view.blockedBy.isEmpty {
                suffix.append("waits: " + view.blockedBy.map { "`\($0)`" }.joined(separator: ", "))
            } else if let reason = view.blockedReason,
                      !view.isRunnable,
                      view.task.status != .completed {
                suffix.append(reason)
            }
            let metadata = suffix.joined(separator: " · ")
            lines.append("\(marker) `\(view.task.id)`  \(escapedTaskMarkdown(view.task.title))")
            lines.append(contentsOf: taskGraphDetailLines(metadata, ansiEnabled: ansiEnabled))
        }
        return lines.joined(separator: "\n   ") + "\n\n"
    }

    /// Renders task metadata as indented detail lines under the task's header
    /// line. Long descriptive content wraps to hanging-indent continuation
    /// lines, so verbose reasons stay readable inside the vertical task block.
    /// Returned rows carry only the detail-relative indent: the section join
    /// adds the shared three-space task indent on top of every row.
    private nonisolated static func taskGraphDetailLines(
        _ metadata: String,
        ansiEnabled: Bool = AgentOutput.standardErrorIsTerminal
    ) -> [String] {
        guard !metadata.isEmpty else {
            return []
        }
        let detailPrefix = taskSummarySegment(
            "· ",
            color: TerminalStyle.Status.inactive,
            ansiEnabled: ansiEnabled
        )
        let wrapWidth = max(40, TerminalChat.terminalColumnCount() - 20)
        // Word-wrapping (`wrap`) collapses repeated internal spaces past the
        // wrap threshold and leaves single tokens wider than `width` intact.
        // Reflow at visible cell boundaries instead: internal spacing and
        // content are preserved exactly, and over-long tokens are split at the
        // column limit so no detail row exceeds the wrap width.
        return TerminalANSIText.wrapPreservingWhitespace(
            detailPrefix + metadata,
            width: wrapWidth,
            hangingIndent: "    "
        )
            .enumerated()
            .map { index, row in index == 0 ? "  " + row : row }
    }

    nonisolated static func taskSummarySegment(
        _ text: String,
        color: String,
        ansiEnabled: Bool
    ) -> String {
        ansiEnabled ? "\(color)\(text)\(TerminalStyle.reset)" : text
    }

    nonisolated static func taskDetailMarkdown(_ view: TaskRecordView) -> String {
        ChatSessionNoticeText.taskDetailMarkdown(view)
    }

    private nonisolated static func escapedTaskMarkdown(_ text: String) -> String {
        ChatSessionNoticeText.escapedTaskMarkdown(text)
    }
}
