//
//  DirectSubAgentRuntime+Parsing.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

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
        guard let profileReference = payload.profileReference?.nilIfBlank else {
            return nil
        }
        let lookupValue = TextUtilities.normalizedLookupValue(profileReference)
        return agents.first { agent in
            TextUtilities.normalizedLookupValue(agent.id) == lookupValue
                || TextUtilities.normalizedLookupValue(agent.name) == lookupValue
        }
    }

    public static func backendContext(
        for payload: RequestedAgentPayload,
        profile: AgentProfile?
    ) -> BackendContext {
        BackendContext(
            requestedName: payload.name,
            requestedRole: payload.role,
            profile: profile,
            modelBinding: payload.modelBinding,
            modelID: payload.requestedModelID
        )
    }

    /// Resolves a requested model exclusively within the selected profile's
    /// configured bindings. A model reference without a profile is rejected so
    /// delegation cannot bypass a profile's model policy.
    public static func resolvingModelBinding(
        for payload: RequestedAgentPayload,
        profile: AgentProfile
    ) throws -> RequestedAgentPayload {
        guard !profile.modelBindings.isEmpty else {
            if let requestedModelID = payload.requestedModelID {
                throw DirectSubAgentRuntimeError.modelNotAllowedForProfile(
                    modelID: requestedModelID,
                    profile: profile.displayName
                )
            }
            return payload
        }

        guard let binding = profile.modelBinding(matching: payload.requestedModelID) else {
            let requestedModelID = payload.requestedModelID ?? "default"
            throw DirectSubAgentRuntimeError.modelNotAllowedForProfile(
                modelID: requestedModelID,
                profile: profile.displayName
            )
        }
        return payload.applying(modelBinding: binding)
    }

    public static func requestedAgentPayloads(
        from arguments: [String: JSONValue]
    ) throws -> [RequestedAgentPayload] {
        if let values = firstArray(["agents", "items"], in: arguments) {
            return try values.enumerated().map { offset, value in
                try requestedAgentPayload(from: value, fallbackIndex: offset)
            }
        }

        guard !arguments.isEmpty else {
            throw DirectSubAgentRuntimeError.missingArgument("prompt or agents")
        }

        return [
            try requestedAgentPayload(
                from: .object(arguments),
                fallbackIndex: 0
            )
        ]
    }

    public static func requestedAgentPayload(
        from value: JSONValue,
        fallbackIndex: Int
    ) throws -> RequestedAgentPayload {
        let object: [String: JSONValue]
        if case let .object(decodedObject) = value {
            object = decodedObject
        } else {
            object = [:]
        }

        let toolOverrideKeys = [
            "allowedTools", "allowed_tools", "toolNames", "tool_names",
            "toolKinds", "tool_kinds", "tools",
        ]
        if let toolOverrideKey = toolOverrideKeys.first(where: { object[$0] != nil }) {
            throw DirectSubAgentRuntimeError.invalidArgument(
                "\(toolOverrideKey) is not supported by agent.create; "
                    + "delegated tools are configured on the selected agent profile"
            )
        }

        return RequestedAgentPayload(
            name: firstString(["name", "title"], in: object) ?? "sub-agent-\(fallbackIndex + 1)",
            role: firstString(["role"], in: object) ?? "worker",
            profileReference: firstString(
                ["agent", "agentName", "agent_name", "agentID", "agent_id", "profile", "profileName", "profile_name"],
                in: object
            )?.nilIfBlank,
            taskID: firstString(["taskID", "task_id"], in: object)?.nilIfBlank,
            prompt: firstString(["prompt", "message", "initialPrompt", "initial_prompt"], in: object)?.nilIfBlank,
            modelID: firstString(["modelID", "model_id", "model"], in: object)?.nilIfBlank
        )
    }

    public static func normalizedToolRequest(
        for toolCall: DirectAgentToolCall
    ) -> ToolRequest {
        let request = ToolRequest(
            name: toolCall.name,
            arguments: jsonArguments(from: toolCall.argumentsObject)
        )
        return SubAgentToolRequestCompatibility.normalize(request) ?? request
    }

    public static func jsonArguments(
        from object: [String: Any]
    ) -> [String: JSONValue] {
        object.mapValues(jsonValue(from:))
    }

    public static func jsonValue(from value: Any) -> JSONValue {
        JSONValue(jsonObject: value)
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
                    if number.isFinite,
                       number == number.rounded(),
                       let integer = Int64(exactly: number) {
                        return String(integer)
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
                return number.isFinite ? number : nil
            case let .string(string):
                guard let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)),
                      number.isFinite else {
                    continue
                }
                return number
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
