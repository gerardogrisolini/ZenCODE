//
//  OrchestrationToolRequestCompatibility.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public nonisolated enum OrchestrationToolRequestCompatibility {
    private static let aliases: [String: String] = [
        "todo.read": "todo.read",
        "todo_read": "todo.read",
        "todo.list": "todo.read",
        "todo_list": "todo.read",
        "todo.write": "todo.write",
        "todo_write": "todo.write",
        "todo.update": "todo.write",
        "todo_update": "todo.write",
        "task.create": "task.create",
        "task_create": "task.create",
        "task.list": "task.list",
        "task_list": "task.list",
        "tasks": "task.list",
        "task.get": "task.get",
        "task_get": "task.get",
        "task.status": "task.get",
        "task_status": "task.get",
        "task.update": "task.update",
        "task_update": "task.update",
        "agent.create": "agent.create",
        "agent.spawn": "agent.create",
        "agent_spawn": "agent.create",
        "spawn_agent": "agent.create",
        "subagent.create": "agent.create",
        "subagent_create": "agent.create",
        "agent.list": "agent.list",
        "agent_list": "agent.list",
        "agents": "agent.list",
        "subagent.list": "agent.list",
        "subagent_list": "agent.list",
        "agent.get": "agent.get",
        "agent_get": "agent.get",
        "agent.status": "agent.get",
        "agent_status": "agent.get",
        "subagent.get": "agent.get",
        "subagent_get": "agent.get",
        "agent.message": "agent.message",
        "agent.send": "agent.message",
        "agent_send": "agent.message",
        "agent_message": "agent.message",
        "send_input": "agent.message",
        "subagent.message": "agent.message",
        "subagent_message": "agent.message",
        "agent.wait": "agent.wait",
        "agent_wait": "agent.wait",
        "wait_agent": "agent.wait",
        "subagent.wait": "agent.wait",
        "subagent_wait": "agent.wait",
        "agent.close": "agent.close",
        "agent_close": "agent.close",
        "close_agent": "agent.close",
        "subagent.close": "agent.close",
        "subagent_close": "agent.close"
    ]

    public static func normalize(_ request: ToolRequest) -> ToolRequest? {
        guard let canonicalName = canonicalToolName(for: request.name) else {
            return nil
        }

        return ToolRequest(
            name: canonicalName,
            arguments: normalizedArguments(request.arguments, for: canonicalName)
        )
    }

    public static func canonicalToolName(for rawName: String) -> String? {
        if let aliasedName = aliases[rawName.lowercased()] {
            return aliasedName
        }

        let tokens = normalizedNameTokens(from: rawName)
        guard let domain = primaryDomain(in: tokens),
              let action = canonicalAction(in: tokens, domain: domain) else {
            return nil
        }

        switch (domain, action) {
        case (.todo, .read):
            return "todo.read"
        case (.todo, .write):
            return "todo.write"
        case (.task, .create):
            return "task.create"
        case (.task, .list):
            return "task.list"
        case (.task, .get):
            return "task.get"
        case (.task, .update):
            return "task.update"
        case (.agent, .create):
            return "agent.create"
        case (.agent, .list):
            return "agent.list"
        case (.agent, .get):
            return "agent.get"
        case (.agent, .message):
            return "agent.message"
        case (.agent, .wait):
            return "agent.wait"
        case (.agent, .close):
            return "agent.close"
        default:
            return nil
        }
    }

    private enum ToolDomain {
        case todo
        case task
        case agent
    }

    private enum CanonicalAction {
        case read
        case write
        case create
        case list
        case get
        case update
        case message
        case wait
        case close
    }

    private static func normalizedNameTokens(from rawName: String) -> [String] {
        let foldedName = rawName.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let separatedName = foldedName.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: " ",
            options: .regularExpression
        )
        var tokens = separatedName.split(whereSeparator: \.isWhitespace).map(String.init)

        if tokens.first == "tool" {
            tokens.removeFirst()
        }

        while let lastToken = tokens.last,
              lastToken.allSatisfy(\.isNumber) {
            tokens.removeLast()
        }

        return tokens
    }

    private static func primaryDomain(in tokens: [String]) -> ToolDomain? {
        for token in tokens {
            switch token {
            case "todo", "todos":
                return .todo
            case "task", "tasks":
                return .task
            case "agent", "agents", "subagent", "subagents":
                return .agent
            default:
                continue
            }
        }

        return nil
    }

    private static func canonicalAction(
        in tokens: [String],
        domain: ToolDomain
    ) -> CanonicalAction? {
        for token in tokens.reversed() {
            switch domain {
            case .todo:
                switch token {
                case "read", "list":
                    return .read
                case "write", "update", "upsert", "append", "replace":
                    return .write
                default:
                    continue
                }
            case .task:
                switch token {
                case "create", "add", "new":
                    return .create
                case "list":
                    return .list
                case "get", "status", "show", "inspect", "read":
                    return .get
                case "update", "write", "set":
                    return .update
                default:
                    continue
                }
            case .agent:
                switch token {
                case "create", "spawn", "new":
                    return .create
                case "list":
                    return .list
                case "get", "status", "show", "inspect", "read":
                    return .get
                case "message", "send", "input":
                    return .message
                case "wait", "join":
                    return .wait
                case "close", "stop", "cancel":
                    return .close
                default:
                    continue
                }
            }
        }

        return nil
    }

    private static func normalizedArguments(
        _ arguments: [String: JSONValue],
        for toolName: String
    ) -> [String: JSONValue] {
        var normalized: [String: JSONValue] = [:]

        switch toolName {
        case "todo.write":
            assignTodoItems(["todos", "items"], from: arguments, to: "todos", in: &normalized)
            assignString(["mode"], from: arguments, to: "mode", in: &normalized)
            assignString(["id"], from: arguments, to: "id", in: &normalized)
            assignString(["content", "title"], from: arguments, to: "content", in: &normalized)
            assignString(["status"], from: arguments, to: "status", in: &normalized)
        case "task.create":
            assignStructuredJSON(["tasks", "items"], from: arguments, to: "tasks", in: &normalized)
            assignString(["id"], from: arguments, to: "id", in: &normalized)
            assignString(["title", "name"], from: arguments, to: "title", in: &normalized)
            assignString(["details", "description"], from: arguments, to: "details", in: &normalized)
            assignString(["status"], from: arguments, to: "status", in: &normalized)
            assignString(["priority"], from: arguments, to: "priority", in: &normalized)
            assignStringArray(["dependsOn", "depends_on"], from: arguments, to: "dependsOn", in: &normalized)
            assignString(["assigneeAgentID", "assignee_agent_id", "agentID", "agent_id"], from: arguments, to: "assigneeAgentID", in: &normalized)
            assignString(["output"], from: arguments, to: "output", in: &normalized)
        case "task.list":
            assignString(["status"], from: arguments, to: "status", in: &normalized)
            assignString(["assigneeAgentID", "assignee_agent_id", "agentID", "agent_id"], from: arguments, to: "assigneeAgentID", in: &normalized)
        case "task.get":
            assignString(["id", "taskID", "task_id", "agentID", "agent_id"], from: arguments, to: "id", in: &normalized)
        case "agent.get", "agent.close":
            assignString(["id", "taskID", "task_id", "agentID", "agent_id", "name", "agent"], from: arguments, to: "id", in: &normalized)
            assignStringArray(["ids", "agentIDs", "agent_ids", "names"], from: arguments, to: "ids", in: &normalized)
        case "task.update":
            assignString(["id", "taskID", "task_id"], from: arguments, to: "id", in: &normalized)
            assignString(["title", "name"], from: arguments, to: "title", in: &normalized)
            assignString(["details", "description"], from: arguments, to: "details", in: &normalized)
            assignString(["status"], from: arguments, to: "status", in: &normalized)
            assignString(["priority"], from: arguments, to: "priority", in: &normalized)
            assignStringArray(["dependsOn", "depends_on"], from: arguments, to: "dependsOn", in: &normalized)
            assignString(["assigneeAgentID", "assignee_agent_id", "agentID", "agent_id"], from: arguments, to: "assigneeAgentID", in: &normalized)
            assignString(["output"], from: arguments, to: "output", in: &normalized)
        case "agent.create":
            assignStructuredJSON(["agents", "items"], from: arguments, to: "agents", in: &normalized)
            assignString(["name"], from: arguments, to: "name", in: &normalized)
            assignString(["role"], from: arguments, to: "role", in: &normalized)
            assignString(["prompt", "message", "initialPrompt", "initial_prompt"], from: arguments, to: "prompt", in: &normalized)
            assignString(["isolationMode", "isolation_mode", "mode"], from: arguments, to: "isolationMode", in: &normalized)
            assignStringArray(
                ["allowedTools", "allowed_tools", "toolNames", "tool_names", "toolKinds", "tool_kinds", "tools"],
                from: arguments,
                to: "toolKinds",
                in: &normalized
            )
        case "agent.list":
            assignString(["status"], from: arguments, to: "status", in: &normalized)
        case "agent.message":
            assignString(["id", "agentID", "agent_id", "taskID", "task_id", "name", "agent"], from: arguments, to: "id", in: &normalized)
            assignStringArray(["ids", "agentIDs", "agent_ids", "names"], from: arguments, to: "ids", in: &normalized)
            assignString(["message", "prompt", "input"], from: arguments, to: "message", in: &normalized)
        case "agent.wait":
            assignString(["id", "agentID", "agent_id", "taskID", "task_id", "name", "agent"], from: arguments, to: "id", in: &normalized)
            assignStringArray(["ids", "agentIDs", "agent_ids", "names"], from: arguments, to: "ids", in: &normalized)
            assignNumber(["timeoutSeconds", "timeout_seconds", "timeout"], from: arguments, to: "timeoutSeconds", in: &normalized)
            assignNumber(["pollIntervalSeconds", "poll_interval_seconds", "pollInterval"], from: arguments, to: "pollIntervalSeconds", in: &normalized)
        default:
            normalized = arguments
        }

        return normalized
    }

    private static func assignTodoItems(
        _ sourceKeys: [String],
        from arguments: [String: JSONValue],
        to destinationKey: String,
        in normalized: inout [String: JSONValue]
    ) {
        guard let value = firstJSONValue(sourceKeys, in: arguments) else {
            return
        }

        let decodedValue: JSONValue
        if let stringValue = value.stringValue,
           let structuredValue = decodedStructuredJSONValue(from: stringValue) {
            decodedValue = structuredValue
        } else {
            decodedValue = value
        }

        normalized[destinationKey] = normalizedTodoItems(decodedValue)
    }

    private static func normalizedTodoItems(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .array(items):
            return .array(items.map(normalizedTodoItem))
        case let .object(object):
            return .array([normalizedTodoItem(.object(object))])
        default:
            return value
        }
    }

    private static func normalizedTodoItem(_ value: JSONValue) -> JSONValue {
        guard case var .object(object) = value else {
            return value
        }

        if object["content"] == nil, let title = object["title"] {
            object["content"] = title
        }
        return .object(object)
    }

    private static func assignStructuredJSON(
        _ sourceKeys: [String],
        from arguments: [String: JSONValue],
        to destinationKey: String,
        in normalized: inout [String: JSONValue]
    ) {
        guard let value = firstJSONValue(sourceKeys, in: arguments) else {
            return
        }

        if let stringValue = value.stringValue,
           let decodedValue = decodedStructuredJSONValue(from: stringValue) {
            normalized[destinationKey] = decodedValue
            return
        }

        normalized[destinationKey] = value
    }

    private static func decodedStructuredJSONValue(
        from rawValue: String
    ) -> JSONValue? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstCharacter = trimmedValue.first,
              firstCharacter == "[" || firstCharacter == "{",
              let data = trimmedValue.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
