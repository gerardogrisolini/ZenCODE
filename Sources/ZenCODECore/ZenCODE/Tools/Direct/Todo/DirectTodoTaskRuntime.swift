//
//  DirectTodoTaskRuntime.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

/// Compatibility name retained for callers compiled against the former combined
/// todo/task runtime. Task state now lives in `SessionTaskOrchestrator` and is
/// reached through `DirectTaskToolAdapter`.
public typealias DirectTodoTaskRuntime = DirectTodoRuntime

public actor DirectTodoRuntime {
    public enum TodoStatus: String {
        case pending
        case inProgress = "in_progress"
        case completed
        case blocked

        public init(rawValue: String?) {
            switch Self.normalized(rawValue) {
            case "in_progress", "inprogress", "active", "running": self = .inProgress
            case "completed", "complete", "done": self = .completed
            case "blocked", "blocker": self = .blocked
            default: self = .pending
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

    public enum TodoWriteMode: String {
        case replace
        case append
        case upsert

        public init(rawValue: String?) {
            switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "append": self = .append
            case "upsert", "update": self = .upsert
            default: self = .replace
            }
        }
    }

    public struct Todo {
        public let id: String
        public var content: String
        public var status: TodoStatus
        public var dependsOn: [String]? = nil
    }

    public struct SessionState {
        public var todos: [Todo] = []
    }

    public var sessions: [String: SessionState] = [:]

    public static func isTodoToolName(_ rawName: String) -> Bool {
        SubAgentToolRequestCompatibility.canonicalToolName(for: rawName)?.hasPrefix("todo.") == true
    }

    public static func isTodoOrTaskToolName(_ rawName: String) -> Bool {
        guard let canonicalName = SubAgentToolRequestCompatibility.canonicalToolName(for: rawName) else {
            return false
        }
        return canonicalName.hasPrefix("todo.") || canonicalName.hasPrefix("tasks.")
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
        default:
            throw DirectTodoTaskRuntimeError.unknownTool(toolCall.name)
        }

        sessions[sessionID] = state
        return output
    }
}
