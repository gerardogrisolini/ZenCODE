//
//  DirectTodoTaskRuntime.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public actor DirectTodoTaskRuntime {
    public enum TodoStatus: String {
        case pending
        case inProgress = "in_progress"
        case completed
        case blocked

        public init(rawValue: String?) {
            switch Self.normalized(rawValue) {
            case "in_progress", "inprogress", "active", "running":
                self = .inProgress
            case "completed", "complete", "done":
                self = .completed
            case "blocked", "blocker":
                self = .blocked
            default:
                self = .pending
            }
        }

        private static func normalized(_ rawValue: String?) -> String {
            (rawValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
        }
    }

    public enum TaskStatus: String {
        case pending
        case inProgress = "in_progress"
        case completed
        case blocked
        case cancelled

        public init(rawValue: String?) {
            switch Self.normalized(rawValue) {
            case "in_progress", "inprogress", "active", "running":
                self = .inProgress
            case "completed", "complete", "done":
                self = .completed
            case "blocked", "blocker":
                self = .blocked
            case "cancelled", "canceled", "cancel":
                self = .cancelled
            default:
                self = .pending
            }
        }

        private static func normalized(_ rawValue: String?) -> String {
            (rawValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
        }
    }

    public enum TaskPriority: String {
        case low
        case normal
        case high

        public init(rawValue: String?) {
            switch rawValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() {
            case "low":
                self = .low
            case "high", "urgent":
                self = .high
            default:
                self = .normal
            }
        }
    }

    public enum TodoWriteMode: String {
        case replace
        case append
        case upsert

        public init(rawValue: String?) {
            switch rawValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() {
            case "append":
                self = .append
            case "upsert", "update":
                self = .upsert
            default:
                self = .replace
            }
        }
    }

    public struct Todo {
        public let id: String
        public var content: String
        public var status: TodoStatus
    }

    public struct TaskItem {
        public let id: String
        public var title: String
        public var details: String?
        public var status: TaskStatus
        public var priority: TaskPriority
        public var dependsOn: [String]
        public var assigneeAgentID: String?
        public var output: String?
        public let createdAt: Date
        public var updatedAt: Date
    }

    public struct SessionState {
        public var todos: [Todo] = []
        public var tasks: [TaskItem] = []
    }

    public struct TaskPayload {
        public let id: String?
        public let title: String?
        public let details: String?
        public let status: TaskStatus?
        public let priority: TaskPriority?
        public let dependsOn: [String]?
        public let assigneeAgentID: String?
        public let output: String?
    }

    public var sessions: [String: SessionState] = [:]

    public static func isTodoOrTaskToolName(_ rawName: String) -> Bool {
        guard let canonicalName = SubAgentToolRequestCompatibility.canonicalToolName(for: rawName) else {
            return false
        }
        return canonicalName.hasPrefix("todo.") || canonicalName.hasPrefix("task.")
    }

    public func execute(
        sessionID: String?,
        toolCall: DirectAgentToolCall
    ) throws -> String {
        let sessionID = sessionID?.nilIfBlank ?? "default"
        let request = Self.normalizedToolRequest(for: toolCall)
        var state = sessions[sessionID] ?? SessionState()
        let output: String

        switch request.name {
        case "todo.read":
            output = Self.renderTodos(state.todos)
        case "todo.write":
            let todos = try Self.requestedTodos(from: request.arguments)
            let mode = TodoWriteMode(rawValue: Self.firstString(["mode"], in: request.arguments))
            switch mode {
            case .replace:
                state.todos = todos
            case .append:
                state.todos.append(contentsOf: todos)
            case .upsert:
                var todosByID = Dictionary(
                    state.todos.map { ($0.id, $0) },
                    uniquingKeysWith: { current, _ in current }
                )
                for todo in todos {
                    todosByID[todo.id] = todo
                }
                state.todos = Self.orderedValues(
                    from: todosByID,
                    preserving: state.todos.map(\.id) + todos.map(\.id)
                )
            }
            output = Self.renderTodos(state.todos)
        case "task.create":
            let payloads = try Self.requestedTaskPayloads(
                from: request.arguments,
                requireTitle: true
            )
            let now = Date()
            let createdTasks = payloads.map { payload in
                TaskItem(
                    id: payload.id ?? "task_\(UUID().uuidString.lowercased())",
                    title: payload.title ?? "",
                    details: payload.details,
                    status: payload.status ?? .pending,
                    priority: payload.priority ?? .normal,
                    dependsOn: payload.dependsOn ?? [],
                    assigneeAgentID: payload.assigneeAgentID,
                    output: payload.output,
                    createdAt: now,
                    updatedAt: now
                )
            }
            state.tasks.append(contentsOf: createdTasks)
            output = Self.renderTasks(createdTasks)
        case "task.list":
            let statusFilter = Self.firstString(["status"], in: request.arguments)
                .map(TaskStatus.init(rawValue:))
            let assigneeFilter = Self.firstString(
                ["assigneeAgentID", "assignee_agent_id", "agentID", "agent_id"],
                in: request.arguments
            )?.nilIfBlank
            let tasks = state.tasks.filter { task in
                if let statusFilter, task.status != statusFilter {
                    return false
                }
                if let assigneeFilter, task.assigneeAgentID != assigneeFilter {
                    return false
                }
                return true
            }
            output = Self.renderTasks(tasks)
        case "task.get":
            let taskID = try Self.requiredString(["id"], in: request.arguments)
            guard let task = state.tasks.first(where: { $0.id == taskID }) else {
                throw DirectTodoTaskRuntimeError.taskNotFound(taskID)
            }
            output = Self.renderTasks([task])
        case "task.update":
            let taskID = try Self.requiredString(["id"], in: request.arguments)
            guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else {
                throw DirectTodoTaskRuntimeError.taskNotFound(taskID)
            }
            var task = state.tasks[index]
            if let title = Self.firstString(["title", "name"], in: request.arguments)?.nilIfBlank {
                task.title = title
            }
            if Self.hasAnyValue(["details", "description"], in: request.arguments) {
                task.details = Self.firstString(["details", "description"], in: request.arguments)?.nilIfBlank
            }
            if Self.hasAnyValue(["status"], in: request.arguments) {
                task.status = TaskStatus(rawValue: Self.firstString(["status"], in: request.arguments))
            }
            if Self.hasAnyValue(["priority"], in: request.arguments) {
                task.priority = TaskPriority(rawValue: Self.firstString(["priority"], in: request.arguments))
            }
            if Self.hasAnyValue(["dependsOn", "depends_on"], in: request.arguments) {
                task.dependsOn = Self.firstStringList(["dependsOn", "depends_on"], in: request.arguments) ?? []
            }
            if Self.hasAnyValue(["assigneeAgentID", "assignee_agent_id", "agentID", "agent_id"], in: request.arguments) {
                task.assigneeAgentID = Self.firstString(
                    ["assigneeAgentID", "assignee_agent_id", "agentID", "agent_id"],
                    in: request.arguments
                )?.nilIfBlank
            }
            if Self.hasAnyValue(["output"], in: request.arguments) {
                task.output = Self.firstString(["output"], in: request.arguments)?.nilIfBlank
            }
            task.updatedAt = .now
            state.tasks[index] = task
            output = Self.renderTasks([task])
        default:
            throw DirectTodoTaskRuntimeError.unknownTool(toolCall.name)
        }

        sessions[sessionID] = state
        return output
    }
}
