//
//  DirectTaskToolAdapter.swift
//  ZenCODE
//

import Foundation

public actor DirectTaskToolAdapter {
    private var orchestrator: SessionTaskOrchestrator

    public init(orchestrator: SessionTaskOrchestrator = SessionTaskOrchestrator()) {
        self.orchestrator = orchestrator
    }

    public static func isTaskToolName(_ rawName: String) -> Bool {
        SubAgentToolRequestCompatibility.canonicalToolName(for: rawName)?.hasPrefix("tasks.") == true
    }

    public func installTaskOrchestrator(_ orchestrator: SessionTaskOrchestrator) {
        self.orchestrator = orchestrator
    }

    public func execute(
        sessionID: String?,
        toolCall: DirectAgentToolCall
    ) async throws -> String {
        let sessionID = sessionID?.nilIfBlank ?? "default"
        let request = DirectTodoRuntime.normalizedToolRequest(for: toolCall)

        switch request.name {
        case "tasks.create":
            let definitions = try Self.requestedTaskDefinitions(from: request.arguments)
            if Self.containsAssignee(in: request.arguments) {
                throw SessionTaskOrchestratorError.permissionDenied(
                    "Tasks are assigned atomically through agent.create(taskID:), not tasks.create."
                )
            }
            let graph = try await orchestrator.createTasks(
                sessionID: sessionID,
                graphID: DirectTodoRuntime.firstString(
                    ["graphID", "graph_id"],
                    in: request.arguments
                ),
                tasks: definitions
            )
            return try await Self.renderGraph(
                graph,
                orchestrator: orchestrator,
                sessionID: sessionID,
                detailedTaskID: nil
            )

        case "tasks.list":
            let graphID = DirectTodoRuntime.firstString(
                ["graphID", "graph_id"],
                in: request.arguments
            )?.nilIfBlank
            let status = try Self.optionalTaskStatus(
                DirectTodoRuntime.firstString(["status"], in: request.arguments)
            )
            let views = try await orchestrator.listTasks(
                sessionID: sessionID,
                graphID: graphID,
                status: status,
                assigneeAgentID: DirectTodoRuntime.firstString(
                    ["assigneeAgentID", "assignee_agent_id", "agentID", "agent_id"],
                    in: request.arguments
                )?.nilIfBlank,
                runnableOnly: DirectTodoRuntime.firstBool(
                    ["runnableOnly", "runnable_only"],
                    in: request.arguments
                ) ?? false,
                includeTerminal: DirectTodoRuntime.firstBool(
                    ["includeTerminal", "include_terminal"],
                    in: request.arguments
                ) ?? true,
                limit: DirectTodoRuntime.firstInt(["limit"], in: request.arguments) ?? 256
            )
            let snapshot = try await orchestrator.graphSnapshot(
                sessionID: sessionID,
                graphID: graphID
            )
            return Self.renderList(views, graph: snapshot)

        case "tasks.get":
            let taskID = try DirectTodoRuntime.requiredString(["id"], in: request.arguments)
            let view = try await orchestrator.task(
                sessionID: sessionID,
                taskID: taskID,
                graphID: DirectTodoRuntime.firstString(
                    ["graphID", "graph_id"],
                    in: request.arguments
                )
            )
            return Self.renderTask(view, detailed: true)

        case "tasks.update":
            let taskID = try DirectTodoRuntime.requiredString(["id"], in: request.arguments)
            if Self.containsAssignee(in: request.arguments) {
                throw SessionTaskOrchestratorError.permissionDenied(
                    "Tasks are assigned atomically through agent.create(taskID:), not tasks.update."
                )
            }
            let update = try Self.taskUpdate(from: request.arguments)
            let view = try await orchestrator.updateTask(
                sessionID: sessionID,
                taskID: taskID,
                graphID: DirectTodoRuntime.firstString(
                    ["graphID", "graph_id"],
                    in: request.arguments
                ),
                update: update
            )
            return Self.renderTask(view, detailed: true)

        case "tasks.retry":
            let taskID = try DirectTodoRuntime.requiredString(["id"], in: request.arguments)
            let view = try await orchestrator.retryTask(
                sessionID: sessionID,
                taskID: taskID,
                graphID: DirectTodoRuntime.firstString(
                    ["graphID", "graph_id"],
                    in: request.arguments
                ),
                expectedRevision: DirectTodoRuntime.firstInt(
                    ["expectedRevision", "expected_revision"],
                    in: request.arguments
                )
            )
            var rendered = Self.renderTask(view, detailed: true)
            let unsuccessfulAttempts = view.task.attempts.filter {
                $0.status == .failed || $0.status == .interrupted
            }
            if !unsuccessfulAttempts.isEmpty {
                let noun = unsuccessfulAttempts.count == 1 ? "attempt" : "attempts"
                rendered += "\nHint: \(unsuccessfulAttempts.count) previous \(noun) on this "
                    + "task (complexity \(view.task.complexity)) did not succeed. Re-evaluate "
                    + "the task type and required tools, then retry with a role-compatible "
                    + "profile and its lowest-capability authorized model binding that meets "
                    + "the task complexity. If none exists, use that profile's highest-capability "
                    + "binding and "
                    + "report the capability gap."
            }
            return rendered

        case "tasks.cancel":
            let taskID = try DirectTodoRuntime.requiredString(["id"], in: request.arguments)
            _ = try await orchestrator.cancelTask(
                sessionID: sessionID,
                taskID: taskID,
                graphID: DirectTodoRuntime.firstString(
                    ["graphID", "graph_id"],
                    in: request.arguments
                ),
                reason: DirectTodoRuntime.firstString(
                    ["reason", "message"],
                    in: request.arguments
                )
            )
            let view = try await orchestrator.task(
                sessionID: sessionID,
                taskID: taskID,
                graphID: DirectTodoRuntime.firstString(
                    ["graphID", "graph_id"],
                    in: request.arguments
                )
            )
            return Self.renderTask(view, detailed: true)

        default:
            throw DirectTodoTaskRuntimeError.unknownTool(toolCall.name)
        }
    }
}

extension DirectTaskToolAdapter {
    static func requestedTaskDefinitions(
        from arguments: [String: JSONValue]
    ) throws -> [TaskDefinition] {
        if let values = DirectTodoRuntime.firstArray(["tasks", "items"], in: arguments) {
            guard !values.isEmpty else {
                throw DirectTodoTaskRuntimeError.invalidArgument("tasks")
            }
            return try values.enumerated().map { offset, value in
                try taskDefinition(from: value, fallbackOrder: offset + 1)
            }
        }
        return [try taskDefinition(from: .object(arguments), fallbackOrder: 1)]
    }

    static func taskDefinition(
        from value: JSONValue,
        fallbackOrder: Int
    ) throws -> TaskDefinition {
        guard case let .object(object) = value else {
            throw DirectTodoTaskRuntimeError.invalidArgument("task")
        }
        guard let title = DirectTodoRuntime.firstString(
            ["title", "name"],
            in: object
        )?.nilIfBlank else {
            throw DirectTodoTaskRuntimeError.missingArgument("title")
        }

        let executionObject: [String: JSONValue]
        if case let .object(nested)? = object["execution"] {
            executionObject = nested
        } else {
            executionObject = object
        }
        let executor: TaskExecutorKind
        switch DirectTodoRuntime.firstString(["executor"], in: executionObject)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") {
        case "sub_agent", "subagent", "agent": executor = .subAgent
        default: executor = .coordinator
        }

        return TaskDefinition(
            id: DirectTodoRuntime.firstString(["id", "taskID", "task_id"], in: object),
            title: title,
            details: DirectTodoRuntime.firstString(["details", "description"], in: object),
            order: DirectTodoRuntime.firstInt(["order", "index"], in: object) ?? fallbackOrder,
            status: try optionalTaskStatus(
                DirectTodoRuntime.firstString(["status"], in: object)
            ) ?? .pending,
            priority: TaskPriority(normalizing: DirectTodoRuntime.firstString(["priority"], in: object)),
            dependsOn: DirectTodoRuntime.firstStringList(
                ["dependsOn", "depends_on"],
                in: object
            ) ?? [],
            execution: TaskExecutionSpec(
                executor: executor,
                profile: DirectTodoRuntime.firstString(
                    ["profile", "profileName", "profile_name"],
                    in: executionObject
                ),
                role: DirectTodoRuntime.firstString(["role"], in: executionObject),
                toolNames: DirectTodoRuntime.firstStringList(
                    ["toolNames", "tool_names", "tools"],
                    in: executionObject
                ) ?? [],
                fileScopes: DirectTodoRuntime.firstStringList(
                    ["fileScopes", "file_scopes"],
                    in: executionObject
                ) ?? []
            ),
            acceptanceCriteria: DirectTodoRuntime.firstStringList(
                ["acceptanceCriteria", "acceptance_criteria"],
                in: object
            ) ?? [],
            output: DirectTodoRuntime.firstString(["output"], in: object),
            complexity: DirectTodoRuntime.firstInt(["complexity"], in: object)
        )
    }

    static func taskUpdate(from arguments: [String: JSONValue]) throws -> TaskUpdate {
        TaskUpdate(
            title: DirectTodoRuntime.firstString(["title", "name"], in: arguments),
            details: DirectTodoRuntime.firstString(["details", "description"], in: arguments),
            clearsDetails: ["details", "description"].contains { key in
                if case .null? = arguments[key] { return true }
                return false
            },
            priority: DirectTodoRuntime.hasAnyValue(["priority"], in: arguments)
                ? TaskPriority(normalizing: DirectTodoRuntime.firstString(["priority"], in: arguments))
                : nil,
            dependsOn: DirectTodoRuntime.hasAnyValue(["dependsOn", "depends_on"], in: arguments)
                ? (DirectTodoRuntime.firstStringList(["dependsOn", "depends_on"], in: arguments) ?? [])
                : nil,
            status: try optionalTaskStatus(
                DirectTodoRuntime.firstString(["status"], in: arguments)
            ),
            statusReason: DirectTodoRuntime.firstString(
                ["statusReason", "status_reason", "reason"],
                in: arguments
            ),
            output: DirectTodoRuntime.firstString(["output", "progress"], in: arguments),
            error: DirectTodoRuntime.firstString(["error"], in: arguments),
            evidence: try evidence(from: arguments),
            expectedRevision: DirectTodoRuntime.firstInt(
                ["expectedRevision", "expected_revision"],
                in: arguments
            ),
            complexity: DirectTodoRuntime.firstInt(["complexity"], in: arguments)
        )
    }

    static func evidence(from arguments: [String: JSONValue]) throws -> [TaskEvidence] {
        guard let values = DirectTodoRuntime.firstArray(["evidence"], in: arguments) else {
            return []
        }
        return try values.map { value in
            switch value {
            case let .string(summary):
                return TaskEvidence(kind: "note", summary: summary)
            case let .object(object):
                guard let summary = DirectTodoRuntime.firstString(
                    ["summary", "description", "value"],
                    in: object
                )?.nilIfBlank else {
                    throw DirectTodoTaskRuntimeError.invalidArgument("evidence")
                }
                return TaskEvidence(
                    id: DirectTodoRuntime.firstString(["id"], in: object)
                        ?? "evidence_\(UUID().uuidString.lowercased())",
                    kind: DirectTodoRuntime.firstString(["kind", "type"], in: object)
                        ?? "note",
                    summary: summary,
                    location: DirectTodoRuntime.firstString(
                        ["location", "path", "file"],
                        in: object
                    )
                )
            default:
                throw DirectTodoTaskRuntimeError.invalidArgument("evidence")
            }
        }
    }

    static func optionalTaskStatus(_ rawValue: String?) throws -> TaskStatus? {
        guard let rawValue = rawValue?.nilIfBlank else { return nil }
        let normalized = rawValue.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "pending", "todo", "waiting": return .pending
        case "in_progress", "inprogress", "active", "running": return .inProgress
        case "awaiting_validation", "awaitingvalidation", "validation", "needs_validation": return .awaitingValidation
        case "completed", "complete", "done", "success", "succeeded": return .completed
        case "blocked", "blocker": return .blocked
        case "failed", "failure", "error": return .failed
        case "cancelled", "canceled", "cancel": return .cancelled
        default:
            throw DirectTodoTaskRuntimeError.invalidArgument("status")
        }
    }

    static func containsAssignee(in arguments: [String: JSONValue]) -> Bool {
        if DirectTodoRuntime.hasAnyValue(
            ["assigneeAgentID", "assignee_agent_id", "agentID", "agent_id"],
            in: arguments
        ) {
            return true
        }
        return DirectTodoRuntime.firstArray(["tasks", "items"], in: arguments)?.contains { value in
            guard case let .object(object) = value else { return false }
            return DirectTodoRuntime.hasAnyValue(
                ["assigneeAgentID", "assignee_agent_id", "agentID", "agent_id"],
                in: object
            )
        } ?? false
    }
}

extension DirectTaskToolAdapter {
    static func renderGraph(
        _ graph: TaskGraphSnapshot,
        orchestrator: SessionTaskOrchestrator,
        sessionID: String,
        detailedTaskID: String?
    ) async throws -> String {
        if let detailedTaskID {
            return renderTask(
                try await orchestrator.task(
                    sessionID: sessionID,
                    taskID: detailedTaskID,
                    graphID: graph.id
                ),
                detailed: true
            )
        }
        let views = try await orchestrator.listTasks(
            sessionID: sessionID,
            graphID: graph.id
        )
        return renderList(views, graph: graph)
    }

    static func renderList(
        _ views: [TaskRecordView],
        graph: TaskGraphSnapshot?
    ) -> String {
        guard let graph else { return "No tasks." }
        var lines = [
            "Task graph \(graph.id) state=\(graph.state.rawValue) revision=\(graph.revision)",
        ]
        guard !views.isEmpty else {
            lines.append("No matching tasks.")
            return lines.joined(separator: "\n")
        }
        lines.append(contentsOf: views.map { renderTask($0, detailed: false) })
        return lines.joined(separator: "\n")
    }

    static func renderTask(_ view: TaskRecordView, detailed: Bool) -> String {
        let task = view.task
        var fragments = [
            "[\(task.status.rawValue)] \(task.id): \(task.title)",
            "priority=\(task.priority.rawValue)",
            "complexity=\(task.complexity)",
            "runnable=\(view.isRunnable)",
            "revision=\(task.revision)",
            "attempts=\(task.attempts.count)",
        ]
        if let assignee = task.assigneeAgentID { fragments.append("assignee=\(assignee)") }
        if !task.dependsOn.isEmpty { fragments.append("depends_on=\(task.dependsOn.joined(separator: ","))") }
        if !view.blockedBy.isEmpty { fragments.append("blocked_by=\(view.blockedBy.joined(separator: ","))") }
        if let reason = view.blockedReason { fragments.append("reason=\(reason)") }
        guard detailed else { return fragments.joined(separator: " | ") }

        var lines = [fragments.joined(separator: " | ")]
        if let details = task.details { lines.append("details: \(details)") }
        if !view.dependents.isEmpty { lines.append("dependents: \(view.dependents.joined(separator: ", "))") }
        if !task.acceptanceCriteria.isEmpty {
            lines.append("acceptance_criteria:")
            lines.append(contentsOf: task.acceptanceCriteria.map { "- \($0)" })
        }
        if !task.attempts.isEmpty {
            lines.append("attempts:")
            for attempt in task.attempts {
                var summary = "- \(attempt.id) ordinal=\(attempt.ordinal) status=\(attempt.status.rawValue) executor=\(attempt.executor.rawValue)"
                if let agentID = attempt.agentID { summary += " agent=\(agentID)" }
                lines.append(summary)
                if let output = attempt.output { lines.append("  output: \(output)") }
                if let error = attempt.error { lines.append("  error: \(error)") }
            }
        }
        if let result = task.result {
            if let output = result.output { lines.append("result_output: \(output)") }
            if let error = result.error { lines.append("result_error: \(error)") }
            if !result.evidence.isEmpty {
                lines.append("evidence:")
                lines.append(contentsOf: result.evidence.map { evidence in
                    let location = evidence.location.map { " location=\($0)" } ?? ""
                    return "- kind=\(evidence.kind)\(location): \(evidence.summary)"
                })
            }
        }
        return lines.joined(separator: "\n")
    }
}
