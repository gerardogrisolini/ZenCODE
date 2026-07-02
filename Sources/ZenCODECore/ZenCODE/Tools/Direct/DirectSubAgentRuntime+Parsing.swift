//
//  DirectSubAgentRuntime+Parsing.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

extension DirectSubAgentRuntime {
    public static func defaultProfileResolver(
        for payload: RequestedAgentPayload
    ) -> AgentProfile? {
        let agents = (try? AgentProfileStore.loadRequired())
            ?? AgentProfileStore.defaultProfiles()
        return agentProfile(matching: payload, in: agents)
    }

    public static func agentProfile(
        matching payload: RequestedAgentPayload,
        in agents: [AgentProfile]
    ) -> AgentProfile? {
        let rawCandidates: [String?] = [payload.profileReference, payload.name, payload.role]
        let candidates = rawCandidates.compactMap { $0?.nilIfBlank }

        for candidate in candidates {
            let lookupValue = normalizedAgentLookupValue(candidate)
            guard !lookupValue.isEmpty else {
                continue
            }
            if let agent = agents.first(where: { agent in
                normalizedAgentLookupValue(agent.id) == lookupValue
                    || normalizedAgentLookupValue(agent.name) == lookupValue
            }) {
                return agent
            }
        }

        return nil
    }

    public static func backendContext(
        for payload: RequestedAgentPayload,
        profile: AgentProfile?
    ) -> BackendContext {
        BackendContext(
            requestedName: payload.name,
            requestedRole: payload.role,
            isolationMode: payload.isolationMode,
            profile: profile
        )
    }

    public static func requestedAgentPayloads(
        from arguments: [String: JSONValue]
    ) throws -> [RequestedAgentPayload] {
        if let values = firstArray(["agents", "items"], in: arguments) {
            return values.enumerated().map { offset, value in
                requestedAgentPayload(from: value, fallbackIndex: offset)
            }
        }

        guard !arguments.isEmpty else {
            throw DirectSubAgentRuntimeError.missingArgument("prompt or agents")
        }

        return [
            requestedAgentPayload(
                from: .object(arguments),
                fallbackIndex: 0
            )
        ]
    }

    public static func requestedAgentPayload(
        from value: JSONValue,
        fallbackIndex: Int
    ) -> RequestedAgentPayload {
        let object: [String: JSONValue]
        if case let .object(decodedObject) = value {
            object = decodedObject
        } else {
            object = [:]
        }

        return RequestedAgentPayload(
            name: firstString(["name", "title"], in: object) ?? "sub-agent-\(fallbackIndex + 1)",
            role: firstString(["role"], in: object) ?? "worker",
            profileReference: firstString(
                ["agent", "agentName", "agent_name", "agentID", "agent_id", "profile", "profileName", "profile_name"],
                in: object
            )?.nilIfBlank,
            prompt: firstString(["prompt", "message", "initialPrompt", "initial_prompt"], in: object)?.nilIfBlank,
            isolationMode: IsolationMode(
                rawValue: firstString(["isolationMode", "isolation_mode", "mode"], in: object)
            ),
            allowedToolNames: explicitAllowedToolNames(from: object)
        )
    }

    public static func explicitAllowedToolNames(
        from arguments: [String: JSONValue]
    ) -> Set<String>? {
        let rawToolNames =
            firstStringList(["allowedTools", "allowed_tools", "toolNames", "tool_names"], in: arguments)
            ?? firstStringList(["toolKinds", "tool_kinds", "tools"], in: arguments)
            ?? []
        let toolNames = rawToolNames.compactMap { rawValue -> String? in
            let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else {
                return nil
            }
            if let canonicalSubAgentToolName = canonicalSubAgentToolName(for: trimmedValue) {
                return canonicalSubAgentToolName
            }
            guard trimmedValue.contains(".") else {
                return nil
            }
            return trimmedValue
        }
        return toolNames.isEmpty ? nil : Set(toolNames)
    }

    public static func resolvedAllowedToolNames(
        requestedToolNames: Set<String>?,
        parentAllowedToolNames: Set<String>?
    ) -> Set<String>? {
        guard let parentAllowedToolNames else {
            return requestedToolNames
        }

        guard let requestedToolNames else {
            return parentAllowedToolNames
        }

        return requestedToolNames.filter {
            DirectToolExecutor.isAllowed(
                $0,
                allowedToolNames: parentAllowedToolNames
            )
        }
    }

    public static func normalizedToolRequest(
        for toolCall: DirectAgentToolCall
    ) -> ToolRequest {
        let request = ToolRequest(
            name: toolCall.name,
            arguments: jsonArguments(from: toolCall.argumentsObject)
        )
        return OrchestrationToolRequestCompatibility.normalize(request) ?? request
    }

    public static func jsonArguments(
        from object: [String: Any]
    ) -> [String: JSONValue] {
        object.mapValues(jsonValue(from:))
    }

    public static func jsonValue(from value: Any) -> JSONValue {
        JSONValue(jsonObject: value)
    }

    private static func normalizedAgentLookupValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    public static func requestedAgentIdentifiers(
        from arguments: [String: JSONValue]
    ) -> [String] {
        var identifiers: [String] = []
        if let id = firstString(["id", "agentID", "agent_id", "taskID", "task_id", "name", "agent"], in: arguments)?.nilIfBlank {
            identifiers.append(id)
        }
        identifiers.append(contentsOf: firstStringList(["ids", "agentIDs", "agent_ids", "names"], in: arguments) ?? [])

        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedIdentifier.isEmpty,
                  seen.insert(trimmedIdentifier).inserted else {
                return nil
            }
            return trimmedIdentifier
        }
    }

    public static func firstString(
        _ keys: [String],
        in arguments: [String: JSONValue]
    ) -> String? {
        for key in keys {
            if let value = arguments[key] {
                switch value {
                case let .string(string):
                    return string
                case let .number(number):
                    // Render whole numbers without a trailing ".0" so an id like
                    // 3 becomes "3" instead of "3.0".
                    if number == number.rounded(), abs(number) < 9_007_199_254_740_992 {
                        return String(Int64(number))
                    }
                    return String(number)
                case let .bool(bool):
                    return bool ? "true" : "false"
                default:
                    continue
                }
            }
        }
        return nil
    }

    public static func firstNumber(
        _ keys: [String],
        in arguments: [String: JSONValue]
    ) -> Double? {
        for key in keys {
            guard let value = arguments[key] else {
                continue
            }
            switch value {
            case let .number(number):
                return number
            case let .string(string):
                return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            default:
                continue
            }
        }
        return nil
    }

    public static func firstArray(
        _ keys: [String],
        in arguments: [String: JSONValue]
    ) -> [JSONValue]? {
        for key in keys {
            guard let value = arguments[key] else {
                continue
            }
            if case let .array(values) = value {
                return values
            }
            if case let .object(object) = value {
                return [.object(object)]
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
                    if case let .string(string) = value {
                        return string
                    }
                    return nil
                }
            case let .string(string):
                return [string]
            default:
                continue
            }
        }
        return nil
    }
}
