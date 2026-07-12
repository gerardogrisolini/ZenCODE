//
//  TerminalChat+Tasks.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    func startTaskGraphObserver() {
        taskGraphObserverTask?.cancel()
        taskGraphObserverTask = nil
        lastRenderedTaskGraphOverviewSignature = nil
        let observedSessionID = sessionID
        let runner = sessionRunner

        taskGraphObserverTask = Task { [weak self] in
            let orchestrator = runner.taskOrchestrator
            let stream = await orchestrator.events(sessionID: observedSessionID)
            var pendingRender: Task<Void, Never>?
            for await _ in stream {
                pendingRender?.cancel()
                pendingRender = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled, let self else { return }
                    await self.publishTaskGraphOverviewIfChanged(
                        observedSessionID: observedSessionID
                    )
                }
            }
            pendingRender?.cancel()
        }
    }

    func publishTaskGraphOverviewIfChanged(
        observedSessionID: String
    ) async {
        guard sessionID == observedSessionID else { return }
        guard let graph = try? await sessionRunner.taskGraphSnapshot(
            sessionID: observedSessionID
        ) else {
            lastRenderedTaskGraphOverviewSignature = nil
            return
        }
        let shouldRender = graph.tasks.count > 1 || graph.tasks.contains { task in
            !task.attempts.isEmpty
                || task.status == .blocked
                || task.status == .failed
                || task.status == .awaitingValidation
        }
        guard shouldRender,
              let tasks = try? await sessionRunner.taskOrchestrator.listTasks(
                  sessionID: observedSessionID
              ) else {
            return
        }
        let signature = Self.taskGraphOverviewSignature(graph)
        guard signature != lastRenderedTaskGraphOverviewSignature else {
            return
        }
        lastRenderedTaskGraphOverviewSignature = signature
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        writeMarkdownMessage(Self.taskGraphMarkdown(graph: graph, tasks: tasks))
    }

    static func taskGraphOverviewSignature(_ graph: TaskGraphSnapshot) -> String {
        let tasks = graph.tasks.sorted { $0.id < $1.id }.map { task in
            let attempts = task.attempts.map {
                "\($0.id):\($0.status.rawValue)"
            }.joined(separator: ",")
            return "\(task.id):\(task.revision):\(task.status.rawValue):\(task.activeAttemptID ?? "-"):\(attempts)"
        }.joined(separator: "|")
        return "\(graph.id):\(graph.revision):\(graph.state.rawValue):\(tasks)"
    }

    func handleTasksCommand(_ command: String) async {
        writeSubmittedPrompt(command)
        let argument = String(command.dropFirst("/tasks".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
                writeMarkdownMessage(Self.taskDetailMarkdown(view))
            case "retry":
                guard components.count >= 2 else {
                    throw TerminalTaskCommandError.missingTaskID(action)
                }
                _ = try await sessionRunner.retryTask(
                    id: components[1],
                    sessionID: sessionID
                )
                writeSystemMessage("Retried task \(components[1]).\n")
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
                writeSystemMessage("Cancelled task \(components[1]).\n")
                try await renderCurrentTaskGraph()
            case "clear":
                try await sessionRunner.clearTaskGraphs(sessionID: sessionID)
                writeSystemMessage("Cleared the session task graphs.\n")
            default:
                throw TerminalTaskCommandError.unknownAction(action)
            }
        } catch {
            writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    func renderCurrentTaskGraph() async throws {
        guard let graph = try await sessionRunner.taskGraphSnapshot(sessionID: sessionID) else {
            writeSystemMessage("No task graph for this session.\n")
            return
        }
        let views = try await sessionRunner.taskOrchestrator.listTasks(sessionID: sessionID)
        writeMarkdownMessage(Self.taskGraphMarkdown(graph: graph, tasks: views))
    }

    static func taskGraphMarkdown(
        graph: TaskGraphSnapshot,
        tasks: [TaskRecordView]
    ) -> String {
        let completed = tasks.filter { $0.task.status == .completed }.count
        let running = tasks.filter { $0.task.status == .inProgress }.count
        let validating = tasks.filter { $0.task.status == .awaitingValidation }.count
        let waiting = tasks.filter { $0.task.status == .pending }.count
        let blocked = tasks.filter { $0.task.status == .blocked }.count
        let failed = tasks.filter { $0.task.status == .failed }.count

        var summary = ["\(tasks.count) task", "\(completed) completed"]
        if running > 0 { summary.append("\(running) running") }
        if validating > 0 { summary.append("\(validating) awaiting validation") }
        if waiting > 0 { summary.append("\(waiting) waiting") }
        if blocked > 0 { summary.append("\(blocked) blocked") }
        if failed > 0 { summary.append("\(failed) failed") }

        var lines = [
            "## Task graph",
            "",
            "**Graph:** `\(graph.id)` · **state:** `\(graph.state.rawValue)` · **revision:** \(graph.revision)",
            "",
            summary.joined(separator: " · "),
            "",
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
            if let agentID = view.task.assigneeAgentID {
                suffix.append(agentID)
            }
            if !view.blockedBy.isEmpty {
                suffix.append("waits for: \(view.blockedBy.joined(separator: ", "))")
            } else if let reason = view.blockedReason,
                      !view.isRunnable,
                      view.task.status != .completed {
                suffix.append(reason)
            }
            let metadata = suffix.isEmpty ? "" : " — " + suffix.joined(separator: " · ")
            lines.append("\(marker) `\(view.task.id)`  \(escapedTaskMarkdown(view.task.title))\(metadata)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func taskDetailMarkdown(_ view: TaskRecordView) -> String {
        let task = view.task
        var lines = [
            "## Task `\(task.id)`",
            "",
            "**Title:** \(escapedTaskMarkdown(task.title))",
            "",
            "**Status:** `\(task.status.rawValue)` · **priority:** `\(task.priority.rawValue)` · **revision:** \(task.revision)",
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

    private static func escapedTaskMarkdown(_ text: String) -> String {
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
