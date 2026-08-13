//
//  DirectTodoTaskRuntime+Parsing.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension DirectTodoRuntime {
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
                    id: firstString(["id"], in: arguments)?.nilIfBlank
                        ?? "todo_\(UUID().uuidString.lowercased())",
                    content: content,
                    status: TodoStatus(rawValue: firstString(["status"], in: arguments)),
                    dependsOn: hasAnyValue(["dependsOn", "depends_on"], in: arguments)
                        ? (firstStringList(["dependsOn", "depends_on"], in: arguments) ?? [])
                        : nil
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
            id: firstString(["id"], in: object)?.nilIfBlank
                ?? "todo_\(UUID().uuidString.lowercased())",
            content: content,
            status: TodoStatus(rawValue: firstString(["status"], in: object)),
            dependsOn: hasAnyValue(["dependsOn", "depends_on"], in: object)
                ? (firstStringList(["dependsOn", "depends_on"], in: object) ?? [])
                : nil
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
        DirectArgumentValues.firstArray(keys, in: arguments)
    }

    public static func firstString(
        _ keys: [String],
        in arguments: [String: JSONValue]
    ) -> String? {
        DirectArgumentValues.firstString(keys, in: arguments) { value in
            switch value {
            case let .string(string): return string
            case let .number(number):
                if number.isFinite,
                   floor(number) == number,
                   let integer = Int(exactly: number) {
                    return String(integer)
                }
                return String(number)
            case let .bool(bool): return bool ? "true" : "false"
            default: return nil
            }
        }
    }

    public static func firstStringList(
        _ keys: [String],
        in arguments: [String: JSONValue]
    ) -> [String]? {
        DirectArgumentValues.firstStringList(keys, in: arguments) { value in
            switch value {
            case let .string(string): return string
            case let .number(number): return String(number)
            default: return nil
            }
        }
    }

    public static func firstBool(
        _ keys: [String],
        in arguments: [String: JSONValue]
    ) -> Bool? {
        for key in keys {
            guard let value = arguments[key] else { continue }
            switch value {
            case let .bool(bool): return bool
            case let .string(string):
                switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1", "yes": return true
                case "false", "0", "no": return false
                default: continue
                }
            case let .number(number): return number != 0
            default: continue
            }
        }
        return nil
    }

    public static func firstInt(
        _ keys: [String],
        in arguments: [String: JSONValue]
    ) -> Int? {
        for key in keys {
            guard let value = arguments[key] else { continue }
            switch value {
            case let .number(number):
                guard number.isFinite else { continue }
                return Int(exactly: number)
            case let .string(string): return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
            default: continue
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
