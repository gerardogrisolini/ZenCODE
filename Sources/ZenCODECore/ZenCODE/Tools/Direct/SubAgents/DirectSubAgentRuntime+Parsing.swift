//
//  DirectSubAgentRuntime+Parsing.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

private struct RequestedAgentPayloadSignature: Equatable {
    let name: String
    let role: String
    let profileReference: String?
    let taskID: String?
    let prompt: String?
    let modelID: String?

    init(_ payload: DirectSubAgentRuntime.RequestedAgentPayload) {
        name = payload.name
        role = payload.role
        profileReference = payload.profileReference.map(AgentProfileStore.profileReferenceKey)
        taskID = payload.taskID
        prompt = payload.prompt
        modelID = payload.requestedModelID?.lowercased()
    }
}

extension DirectSubAgentRuntime {
    public static func defaultProfileResolver(
        for payload: RequestedAgentPayload
    ) -> AgentProfile? {
        let agents = (try? AgentProfileStore.loadRequired())
            ?? AgentProfileStore.defaultProfiles()
        return agentProfile(matching: payload, in: agents)
    }

    /// Production resolver. Missing or invalid persisted profiles fail closed;
    /// the prompt builder applies the same rule and therefore exposes the same
    /// profile set the runtime accepts.
    public static func liveProfileResolver(
        for payload: RequestedAgentPayload
    ) -> AgentProfile? {
        let agents = (try? AgentProfileStore.loadRequired()) ?? []
        return agentProfile(matching: payload, in: agents)
    }

    public static func agentProfile(
        matching payload: RequestedAgentPayload,
        in agents: [AgentProfile]
    ) -> AgentProfile? {
        guard let profileReference = payload.profileReference?.nilIfBlank else {
            return nil
        }
        return AgentProfileStore.agent(matching: profileReference, in: agents)
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
            modelSelection: payload.modelSelection,
            modelID: payload.requestedModelID,
            swiftFeatureRuntime: nil
        )
    }

    /// Source-compatible entry point that resolves against the authoritative
    /// live snapshot. Production batch creation passes its already captured
    /// snapshot to the overload in `DirectSubAgentRuntime+ModelRouting`.
    public static func resolvingModelBinding(
        for payload: RequestedAgentPayload,
        profile: AgentProfile
    ) throws -> RequestedAgentPayload {
        try resolvingModelBinding(
            for: payload,
            profile: profile,
            snapshot: AgentDelegationCatalog.liveSnapshot()
        )
    }

    public static func requestedAgentPayloads(
        from arguments: [String: JSONValue]
    ) throws -> [RequestedAgentPayload] {
        try rejectToolOverrides(in: arguments)
        if let values = try requestedAgentBatch(from: arguments) {
            if try containsRootAgentArguments(in: arguments) {
                throw DirectSubAgentRuntimeError.invalidArgument(
                    "agent.create cannot mix root agent fields with the agents batch; "
                        + "put every agent field inside agents"
                )
            }
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
        guard case let .object(object) = value else {
            throw DirectSubAgentRuntimeError.invalidArgument(
                "every agent.create agents item must be an object"
            )
        }
        try rejectToolOverrides(in: object)

        return RequestedAgentPayload(
            name: try resolvedAgentString(
                ["name", "title"],
                field: "name",
                in: object
            ) ?? "sub-agent-\(fallbackIndex + 1)",
            role: try resolvedAgentString(
                ["role"],
                field: "role",
                in: object
            ) ?? "worker",
            profileReference: try resolvedAgentString(
                [
                    "profile", "agent", "agentName", "agent_name", "agentID", "agent_id",
                    "profileName", "profile_name",
                ],
                field: "profile",
                in: object,
                comparisonKey: AgentProfileStore.profileReferenceKey
            ),
            taskID: try resolvedAgentString(
                ["taskID", "task_id"],
                field: "taskID",
                in: object
            ),
            prompt: try resolvedAgentString(
                ["prompt", "message", "initialPrompt", "initial_prompt"],
                field: "prompt",
                in: object
            ),
            modelID: try resolvedAgentString(
                ["model", "modelID", "model_id"],
                field: "model",
                in: object,
                comparisonKey: { $0.lowercased() }
            )
        )
    }

    /// Resolves the canonical `agents` batch and its legacy `items` alias
    /// without making dictionary-order-dependent choices. Object values retain
    /// the historical single-item batch compatibility.
    private static func requestedAgentBatch(
        from arguments: [String: JSONValue]
    ) throws -> [JSONValue]? {
        var candidates: [(key: String, values: [JSONValue])] = []
        for key in ["agents", "items"] {
            guard let value = arguments[key] else {
                continue
            }
            guard let values = agentBatchValues(from: value) else {
                throw DirectSubAgentRuntimeError.invalidArgument(
                    "agent.create \(key) must be an array of agent objects"
                )
            }
            candidates.append((key, values))
        }
        guard let selected = candidates.first else {
            return nil
        }
        let selectedSignatures = try agentBatchSignatures(for: selected.values)
        for candidate in candidates.dropFirst() {
            guard try agentBatchSignatures(for: candidate.values) == selectedSignatures else {
                throw DirectSubAgentRuntimeError.invalidArgument(
                    "Conflicting values for agent.create batch aliases: agents, items. "
                        + "Provide one batch or matching aliases."
                )
            }
        }
        return selected.values
    }

    private static func agentBatchSignatures(
        for values: [JSONValue]
    ) throws -> [RequestedAgentPayloadSignature] {
        try values.enumerated().map { offset, value in
            RequestedAgentPayloadSignature(
                try requestedAgentPayload(from: value, fallbackIndex: offset)
            )
        }
    }

    private static func agentBatchValues(from value: JSONValue) -> [JSONValue]? {
        switch value {
        case let .array(values):
            return values
        case let .object(object):
            return [.object(object)]
        default:
            return nil
        }
    }

    private static func containsRootAgentArguments(
        in arguments: [String: JSONValue]
    ) throws -> Bool {
        let rootKeys = [
            "name", "title", "role",
            "profile", "agent", "agentName", "agent_name", "agentID", "agent_id",
            "profileName", "profile_name",
            "taskID", "task_id",
            "prompt", "message", "initialPrompt", "initial_prompt",
            "model", "modelID", "model_id",
        ]
        for key in rootKeys {
            guard let value = arguments[key] else {
                continue
            }
            guard let string = stringValue(from: value) else {
                throw DirectSubAgentRuntimeError.invalidArgument(
                    "agent.create \(key) must be a string-compatible value"
                )
            }
            if string.nilIfBlank != nil {
                return true
            }
        }
        return false
    }

    private static func rejectToolOverrides(
        in arguments: [String: JSONValue]
    ) throws {
        let toolOverrideKeys = [
            "allowedTools", "allowed_tools", "toolNames", "tool_names",
            "toolKinds", "tool_kinds", "tools",
        ]
        if let key = toolOverrideKeys.first(where: { arguments[$0] != nil }) {
            throw DirectSubAgentRuntimeError.invalidArgument(
                "\(key) is not supported by agent.create; delegated tools are "
                    + "configured on the selected agent profile"
            )
        }
    }

    /// Finds a canonical field or one of its wire-compatibility aliases.
    /// Blank values are ignored so they cannot shadow an informative alias.
    /// Multiple nonblank values must have the same semantic comparison key.
    private static func resolvedAgentString(
        _ keys: [String],
        field: String,
        in arguments: [String: JSONValue],
        comparisonKey: (String) -> String = { $0 }
    ) throws -> String? {
        var candidates: [(key: String, value: String)] = []
        for key in keys {
            guard let rawValue = arguments[key] else {
                continue
            }
            guard let rawString = stringValue(from: rawValue) else {
                throw DirectSubAgentRuntimeError.invalidArgument(
                    "agent.create \(key) must be a string-compatible value"
                )
            }
            guard let value = rawString.nilIfBlank else {
                continue
            }
            candidates.append((key, value))
        }
        guard let selected = candidates.first else {
            return nil
        }
        guard candidates.dropFirst().allSatisfy({
            comparisonKey($0.value) == comparisonKey(selected.value)
        }) else {
            throw DirectSubAgentRuntimeError.invalidArgument(
                "Conflicting values for agent.create \(field) aliases: "
                    + candidates.map(\.key).joined(separator: ", ")
                    + ". Provide one value or matching aliases."
            )
        }
        return selected.value
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

    /// Every argument key that can carry an agent identifier. Callers that need
    /// to *retarget* a request (rather than read it) must clear all of them, so
    /// the list lives next to the parser that consumes it and cannot drift.
    public static let agentIdentifierArgumentKeys: [String] = singularAgentIdentifierKeys
        + pluralAgentIdentifierKeys

    static let singularAgentIdentifierKeys = [
        "id", "agentID", "agent_id", "taskID", "task_id", "name", "agent"
    ]
    static let pluralAgentIdentifierKeys = ["ids", "agentIDs", "agent_ids", "names"]

    public static func requestedAgentIdentifiers(
        from arguments: [String: JSONValue]
    ) -> [String] {
        var identifiers: [String] = []
        if let id = firstString(singularAgentIdentifierKeys, in: arguments)?.nilIfBlank {
            identifiers.append(id)
        }
        identifiers.append(contentsOf: firstStringList(pluralAgentIdentifierKeys, in: arguments) ?? [])

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
            if let value = arguments[key],
               let string = stringValue(from: value) {
                return string
            }
        }
        return nil
    }

    private static func stringValue(from value: JSONValue) -> String? {
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
            return nil
        }
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
