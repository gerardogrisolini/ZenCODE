//
//  DirectOrchestrationRuntime.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public actor DirectOrchestrationRuntime {
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

    public var sessions: [String: SessionState] = [:]

    public static func isTodoOrTaskToolName(_ rawName: String) -> Bool {
        guard let canonicalName = OrchestrationToolRequestCompatibility.canonicalToolName(for: rawName) else {
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
                throw DirectOrchestrationRuntimeError.taskNotFound(taskID)
            }
            output = Self.renderTasks([task])
        case "task.update":
            let taskID = try Self.requiredString(["id"], in: request.arguments)
            guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else {
                throw DirectOrchestrationRuntimeError.taskNotFound(taskID)
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
            throw DirectOrchestrationRuntimeError.unknownTool(toolCall.name)
        }

        sessions[sessionID] = state
        return output
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

    public static func normalizedToolRequest(
        for toolCall: DirectAgentToolCall
    ) -> ToolRequest {
        let request = ToolRequest(
            name: toolCall.name,
            arguments: jsonValueArguments(from: toolCall.argumentsObject)
        )
        return OrchestrationToolRequestCompatibility.normalize(request) ?? request
    }

    public static func requestedTodos(from arguments: [String: JSONValue]) throws -> [Todo] {
        if let todoArray = firstArray(["todos", "items"], in: arguments) {
            return try todoArray.map(decodeTodo)
        }

        if let content = firstString(["content", "title"], in: arguments)?.nilIfBlank {
            return [
                Todo(
                    id: firstString(["id"], in: arguments)?.nilIfBlank ?? "todo_\(UUID().uuidString.lowercased())",
                    content: content,
                    status: TodoStatus(rawValue: firstString(["status"], in: arguments))
                )
            ]
        }

        throw DirectOrchestrationRuntimeError.missingArgument("todos")
    }

    public static func decodeTodo(_ value: JSONValue) throws -> Todo {
        guard case let .object(object) = value else {
            throw DirectOrchestrationRuntimeError.invalidArgument("todos")
        }
        guard let content = firstString(["content", "title"], in: object)?.nilIfBlank else {
            throw DirectOrchestrationRuntimeError.missingArgument("content")
        }
        return Todo(
            id: firstString(["id"], in: object)?.nilIfBlank ?? "todo_\(UUID().uuidString.lowercased())",
            content: content,
            status: TodoStatus(rawValue: firstString(["status"], in: object))
        )
    }

    public static func requestedTaskPayloads(
        from arguments: [String: JSONValue],
        requireTitle: Bool
    ) throws -> [TaskPayload] {
        if let taskArray = firstArray(["tasks", "items"], in: arguments) {
            return try taskArray.map {
                try decodeTaskPayload(from: $0, requireTitle: requireTitle)
            }
        }
        return [
            try decodeTaskPayload(
                from: .object(arguments),
                requireTitle: requireTitle
            )
        ]
    }

    public static func decodeTaskPayload(
        from value: JSONValue,
        requireTitle: Bool
    ) throws -> TaskPayload {
        guard case let .object(object) = value else {
            throw DirectOrchestrationRuntimeError.invalidArgument("task")
        }
        let title = firstString(["title", "name"], in: object)?.nilIfBlank
        if requireTitle, title == nil {
            throw DirectOrchestrationRuntimeError.missingArgument("title")
        }
        return TaskPayload(
            id: firstString(["id"], in: object)?.nilIfBlank,
            title: title,
            details: firstString(["details", "description"], in: object)?.nilIfBlank,
            status: hasAnyValue(["status"], in: object)
                ? TaskStatus(rawValue: firstString(["status"], in: object))
                : nil,
            priority: hasAnyValue(["priority"], in: object)
                ? TaskPriority(rawValue: firstString(["priority"], in: object))
                : nil,
            dependsOn: firstStringList(["dependsOn", "depends_on"], in: object),
            assigneeAgentID: firstString(
                ["assigneeAgentID", "assignee_agent_id", "agentID", "agent_id"],
                in: object
            )?.nilIfBlank,
            output: firstString(["output"], in: object)?.nilIfBlank
        )
    }

    public static func renderTodos(_ todos: [Todo]) -> String {
        guard !todos.isEmpty else {
            return "No orchestration todos."
        }
        return todos.map { todo in
            "[\(todo.status.rawValue)] \(todo.id): \(todo.content)"
        }.joined(separator: "\n")
    }

    public static func renderTasks(_ tasks: [TaskItem]) -> String {
        guard !tasks.isEmpty else {
            return "No orchestration tasks."
        }
        return tasks.map { task in
            var fragments = [
                "[\(task.status.rawValue)] \(task.id): \(task.title)",
                "priority=\(task.priority.rawValue)"
            ]
            if let assigneeAgentID = task.assigneeAgentID {
                fragments.append("assignee=\(assigneeAgentID)")
            }
            if !task.dependsOn.isEmpty {
                fragments.append("depends_on=\(task.dependsOn.joined(separator: ","))")
            }
            if let details = task.details {
                fragments.append("details=\(details)")
            }
            if let output = task.output {
                fragments.append("output=\(output)")
            }
            return fragments.joined(separator: " | ")
        }.joined(separator: "\n")
    }

    public static func orderedValues<T>(
        from valuesByID: [String: T],
        preserving identifiers: [String]
    ) -> [T] {
        var values: [T] = []
        var seenIdentifiers = Set<String>()
        for identifier in identifiers where seenIdentifiers.insert(identifier).inserted {
            if let value = valuesByID[identifier] {
                values.append(value)
            }
        }
        return values
    }

    public static func requiredString(
        _ keys: [String],
        in arguments: [String: JSONValue]
    ) throws -> String {
        guard let value = firstString(keys, in: arguments)?.nilIfBlank else {
            throw DirectOrchestrationRuntimeError.missingArgument(keys.first ?? "value")
        }
        return value
    }

    public static func firstArray(
        _ keys: [String],
        in arguments: [String: JSONValue]
    ) -> [JSONValue]? {
        for key in keys {
            guard let value = arguments[key] else {
                continue
            }
            switch value {
            case let .array(values):
                return values
            case let .object(object):
                return [.object(object)]
            default:
                continue
            }
        }
        return nil
    }

    public static func firstString(
        _ keys: [String],
        in arguments: [String: JSONValue]
    ) -> String? {
        for key in keys {
            guard let value = arguments[key] else {
                continue
            }
            switch value {
            case let .string(string):
                return string
            case let .number(number):
                if floor(number) == number {
                    return String(Int(number))
                }
                return String(number)
            case let .bool(bool):
                return bool ? "true" : "false"
            default:
                continue
            }
        }
        return nil
    }

    public static func firstStringList(
        _ keys: [String],
        in arguments: [String: JSONValue]
    ) -> [String]? {
        for key in keys {
            guard let value = arguments[key] else {
                continue
            }
            switch value {
            case let .array(values):
                return values.compactMap { value in
                    switch value {
                    case let .string(string):
                        return string
                    case let .number(number):
                        return String(number)
                    default:
                        return nil
                    }
                }
            case let .string(string):
                return [string]
            default:
                continue
            }
        }
        return nil
    }

    public static func hasAnyValue(
        _ keys: [String],
        in arguments: [String: JSONValue]
    ) -> Bool {
        keys.contains { arguments[$0] != nil }
    }

    public static func jsonValueArguments(from object: [String: Any]) -> [String: JSONValue] {
        guard case let .object(arguments) = JSONValue(jsonObject: object) else {
            return [:]
        }
        return arguments
    }
}

public enum DirectOrchestrationRuntimeError: LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case invalidArgument(String)
    case taskNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownTool(name):
            return "Unknown orchestration tool: \(name)"
        case let .missingArgument(argument):
            return "Missing required argument: \(argument)"
        case let .invalidArgument(argument):
            return "Invalid argument: \(argument)"
        case let .taskNotFound(identifier):
            return "No orchestration task matched '\(identifier)'."
        }
    }
}

public enum DirectToolError: LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownTool(name):
            return "Unknown tool: \(name)"
        case let .missingArgument(name):
            return "Missing required argument: \(name)"
        case let .permissionDenied(message):
            return message
        }
    }
}
