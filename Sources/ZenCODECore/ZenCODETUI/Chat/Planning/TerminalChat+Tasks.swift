//
//  TerminalChat+Tasks.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension TerminalChat {
    func startTaskGraphObserver() async {
        await stopTaskGraphObserver()
        await renderCoordinator.resetOverview(.taskGraph)
        taskGraphDebouncedRender = nil
        let observedSessionID = sessionID
        let runner = sessionRunner
        // Subscribe BEFORE spawning the consumer task and only then return:
        // registering the continuation here closes the snapshot→subscription
        // handoff window (the event stream has no replay), so a graph
        // mutation that lands after this call is seen by the new observer
        // even when a turn-boundary snapshot raced it. Events buffered
        // between registration and the consumer's first await are retained
        // by the stream.
        let stream = await runner.taskOrchestrator.events(
            sessionID: observedSessionID
        )

        taskGraphObserverTask = Task(name: "ZenCODE.TUI.task-graph-observer") { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled,
                      let coordinator = self?.renderCoordinator,
                      self?.sessionID == observedSessionID else {
                    break
                }
                let publicationRevision = await coordinator.beginOverviewPublication(.taskGraph)
                guard let self, !Task.isCancelled else { break }
                let previousRender = self.taskGraphDebouncedRender
                previousRender?.cancel()
                self.taskGraphDebouncedRender = Task(name: "ZenCODE.TUI.task-graph-render") { [weak self] in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    await previousRender?.value
                    guard !Task.isCancelled, let self else { return }
                    await self.publishTaskGraphOverviewIfChanged(
                        observedSessionID: observedSessionID,
                        publicationRevision: publicationRevision
                    )
                }
            }
            if let pendingRender = self?.taskGraphDebouncedRender {
                pendingRender.cancel()
                await pendingRender.value
                self?.taskGraphDebouncedRender = nil
            }
        }
    }

    func stopTaskGraphObserver() async {
        let observer = taskGraphObserverTask
        taskGraphObserverTask = nil
        observer?.cancel()
        await observer?.value
        if let pendingRender = taskGraphDebouncedRender {
            pendingRender.cancel()
            await pendingRender.value
            taskGraphDebouncedRender = nil
        }
    }

    /// Turn-boundary quiescence for the task-graph section: stops the event
    /// observer, drains any in-flight debounced render, and publishes the
    /// latest known graph state once, so the retiring turn's final section is
    /// mirrored while its reporter is still alive. The observer is NOT
    /// restarted here: the caller restarts it only after the turn's Telegram
    /// reporter has been retired, so no observer-driven render can cross the
    /// retirement boundary and be adopted by the next turn's reporter.
    /// Restarts should follow with a fresh
    /// ``publishTaskGraphOverviewIfChanged(observedSessionID:)`` snapshot,
    /// which also recovers graph mutations that landed between this
    /// publication and the new event subscription (the event stream has no
    /// replay).
    func quiesceTaskGraphObserverForTurnBoundary() async {
        await stopTaskGraphObserver()
        await publishTaskGraphOverviewIfChanged(observedSessionID: sessionID)
    }

    func publishTaskGraphOverviewIfChanged(
        observedSessionID: String,
        publicationRevision reservedPublicationRevision: Int? = nil
    ) async {
        guard sessionID == observedSessionID else { return }
        let publicationRevision: Int
        if let reservedPublicationRevision {
            publicationRevision = reservedPublicationRevision
        } else {
            publicationRevision = await renderCoordinator.beginOverviewPublication(.taskGraph)
        }
        guard !Task.isCancelled else { return }
        guard let graph = try? await sessionRunner.taskGraphSnapshot(
            sessionID: observedSessionID
        ) else {
            guard !Task.isCancelled, sessionID == observedSessionID else { return }
            await renderCoordinator.resetOverview(
                .taskGraph,
                revision: publicationRevision
            )
            return
        }
        guard !Task.isCancelled, sessionID == observedSessionID else { return }
        let shouldRender = graph.tasks.count > 1 || graph.tasks.contains { task in
            !task.attempts.isEmpty
                || task.status == .blocked
                || task.status == .failed
                || task.status == .awaitingValidation
        }
        guard shouldRender else {
            await renderCoordinator.clearDeferredOverview(
                .taskGraph,
                revision: publicationRevision
            )
            return
        }
        guard let tasks = try? await sessionRunner.taskOrchestrator.listTasks(
            sessionID: observedSessionID,
            graphID: graph.id
        ) else {
            return
        }
        guard !Task.isCancelled,
              sessionID == observedSessionID,
              let currentGraph = try? await sessionRunner.taskGraphSnapshot(
                sessionID: observedSessionID
              ),
              currentGraph.id == graph.id,
              currentGraph.revision == graph.revision else {
            return
        }
        guard !Task.isCancelled, sessionID == observedSessionID else { return }
        let signature = Self.taskGraphOverviewSignature(graph)
        let markdown = Self.taskGraphMarkdown(graph: graph, tasks: tasks)
        _ = await renderCoordinator.renderTaskGraphOverview(
            signature: signature,
            markdown: markdown,
            revision: publicationRevision
        )
    }

    func shouldPublishDeferredTaskGraphOverview() async -> Bool {
        await renderCoordinator.shouldPublishDeferredOverview(.taskGraph)
    }

    nonisolated static func taskGraphOverviewSignature(_ graph: TaskGraphSnapshot) -> String {
        let tasks = graph.tasks.sorted { $0.id < $1.id }.map { task in
            let attempts = task.attempts.map {
                "\($0.id):\($0.status.rawValue)"
            }.joined(separator: ",")
            return "\(task.id):\(task.revision):\(task.status.rawValue):\(task.activeAttemptID, default: "-"):\(attempts)"
        }.joined(separator: "|")
        return "\(graph.id):\(graph.revision):\(graph.state.rawValue):\(tasks)"
    }

    func handleTasksCommand(_ command: String) async {
        await writeSubmittedPrompt(command)
        let argument = Self.slashCommandArguments(
            from: command,
            commandPrefix: "/tasks"
        )
        let components = argument.split(whereSeparator: \.isWhitespace).map(String.init)
        let action = components.first?.lowercased() ?? "status"

        do {
            switch action {
            case "status", "list", "ls":
                try await renderCurrentTaskGraph()
            case "show", "get":
                guard components.count >= 2 else {
                    throw TerminalTaskCommandError.missingTaskID(action)
                }
                let view = try await sessionRunner.taskOrchestrator.task(
                    sessionID: sessionID,
                    taskID: components[1]
                )
                await writeMarkdownMessage(Self.taskDetailMarkdown(view))
            case "retry":
                guard components.count >= 2 else {
                    throw TerminalTaskCommandError.missingTaskID(action)
                }
                _ = try await sessionRunner.retryTask(
                    id: components[1],
                    sessionID: sessionID
                )
                await writeSystemMessage("Retried task \(components[1]).\n")
                try await renderCurrentTaskGraph()
            case "cancel":
                guard components.count >= 2 else {
                    throw TerminalTaskCommandError.missingTaskID(action)
                }
                let reason = components.dropFirst(2).joined(separator: " ").nilIfBlank
                _ = try await sessionRunner.cancelTask(
                    id: components[1],
                    sessionID: sessionID,
                    reason: reason
                )
                await writeSystemMessage("Cancelled task \(components[1]).\n")
                try await renderCurrentTaskGraph()
            case "clear":
                try await sessionRunner.clearTaskGraphs(sessionID: sessionID)
                await writeSystemMessage("Cleared the session task graphs.\n")
            default:
                throw TerminalTaskCommandError.unknownAction(action)
            }
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    func renderCurrentTaskGraph() async throws {
        let publicationRevision = await renderCoordinator.beginOverviewPublication(.taskGraph)
        guard let graph = try await sessionRunner.taskGraphSnapshot(sessionID: sessionID) else {
            await writeSystemMessage("No task graph for this session.\n")
            return
        }
        let views = try await sessionRunner.taskOrchestrator.listTasks(
            sessionID: sessionID,
            graphID: graph.id
        )
        _ = await renderCoordinator.renderTaskGraphOverview(
            signature: Self.taskGraphOverviewSignature(graph),
            markdown: Self.taskGraphMarkdown(graph: graph, tasks: views),
            revision: publicationRevision,
            force: true,
            rememberSignature: false
        )
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
        let task = view.task
        var lines = [
            "## Task `\(task.id)`",
            "",
            "**Title:** \(escapedTaskMarkdown(task.title))",
            "",
            "**Status:** `\(task.status.rawValue)` · **priority:** `\(task.priority.rawValue)` · **complexity:** `\(task.complexity)/10` · **revision:** \(task.revision)",
            "",
            "**Runnable:** `\(view.isRunnable)`",
        ]
        if let reason = view.blockedReason { lines.append("**Runnable reason:** \(escapedTaskMarkdown(reason))") }
        if let details = task.details { lines.append("\n\(escapedTaskMarkdown(details))") }
        if !task.dependsOn.isEmpty { lines.append("\n**Dependencies:** " + task.dependsOn.map { "`\($0)`" }.joined(separator: ", ")) }
        if !view.dependents.isEmpty { lines.append("\n**Dependents:** " + view.dependents.map { "`\($0)`" }.joined(separator: ", ")) }
        if !task.acceptanceCriteria.isEmpty {
            lines.append("\n### Acceptance criteria")
            lines.append(contentsOf: task.acceptanceCriteria.map { "- \(escapedTaskMarkdown($0))" })
        }
        if !task.attempts.isEmpty {
            lines.append("\n### Attempts")
            for attempt in task.attempts {
                let agent = attempt.agentID.map { " · agent `\($0)`" } ?? ""
                lines.append("- **#\(attempt.ordinal)** `\(attempt.status.rawValue)`\(agent) · `\(attempt.id)`")
                if let output = attempt.output { lines.append("  - output: \(escapedTaskMarkdown(output))") }
                if let error = attempt.error { lines.append("  - error: \(escapedTaskMarkdown(error))") }
            }
        }
        if let result = task.result, !result.evidence.isEmpty {
            lines.append("\n### Evidence")
            lines.append(contentsOf: result.evidence.map { evidence in
                let location = evidence.location.map { " (`\($0)`)" } ?? ""
                return "- `\(evidence.kind)`\(location): \(escapedTaskMarkdown(evidence.summary))"
            })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private nonisolated static func escapedTaskMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

enum TerminalTaskCommandError: LocalizedError {
    case missingTaskID(String)
    case unknownAction(String)

    var errorDescription: String? {
        switch self {
        case let .missingTaskID(action):
            return "/tasks \(action) requires a task id."
        case let .unknownAction(action):
            return "Unknown /tasks action '\(action)'. Use status, show, retry, cancel, or clear."
        }
    }
}
