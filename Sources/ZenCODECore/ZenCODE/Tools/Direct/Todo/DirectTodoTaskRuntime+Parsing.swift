//
//  DirectTodoTaskRuntime+Parsing.swift
//  ZenCODE
//

import Foundation

extension DirectTodoTaskRuntime {
    public static func normalizedToolRequest(
        for toolCall: DirectAgentToolCall
    ) -> ToolRequest {
        let request = ToolRequest(
            name: toolCall.name,
            arguments: jsonValueArguments(from: toolCall.argumentsObject)
        )
        return SubAgentToolRequestCompatibility.normalize(request) ?? request
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

        throw DirectTodoTaskRuntimeError.missingArgument("todos")
    }

    public static func decodeTodo(_ value: JSONValue) throws -> Todo {
        guard case let .object(object) = value else {
            throw DirectTodoTaskRuntimeError.invalidArgument("todos")
        }
        guard let content = firstString(["content", "title"], in: object)?.nilIfBlank else {
            throw DirectTodoTaskRuntimeError.missingArgument("content")
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
            throw DirectTodoTaskRuntimeError.invalidArgument("task")
        }
        let title = firstString(["title", "name"], in: object)?.nilIfBlank
        if requireTitle, title == nil {
            throw DirectTodoTaskRuntimeError.missingArgument("title")
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

    public static func requiredString(
        _ keys: [String],
        in arguments: [String: JSONValue]
    ) throws -> String {
        guard let value = firstString(keys, in: arguments)?.nilIfBlank else {
            throw DirectTodoTaskRuntimeError.missingArgument(keys.first ?? "value")
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
