//
//  ZenCODEACPBridge+Parsing.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

extension ZenCODEACPBridge {
    public struct ACPMCPServerDefinition: Sendable {
        public let name: String
        public let type: String
        public let configuration: MCPServerConfiguration
        public let isXcodeCandidate: Bool

        public init(
            name: String,
            type: String,
            configuration: MCPServerConfiguration,
            isXcodeCandidate: Bool
        ) {
            self.name = name
            self.type = type
            self.configuration = configuration
            self.isXcodeCandidate = isXcodeCandidate
        }
    }

    public func runtimeHistory(from value: Any?) -> [AgentRuntimeMessage] {
        guard let messages = value as? [[String: Any]] else {
            return []
        }

        return messages.compactMap { object in
            let rawRole = (object["role"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let content = RemoteGenerationClient.contentString(from: object["content"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let toolCalls = RemoteGenerationClient.runtimeToolCalls(from: object)
            let reasoningContent = RemoteGenerationClient.stringValue(object["reasoning_content"])?
                .nilIfBlank
            let reasoningItemsJSON = RemoteGenerationClient.stringValue(object["reasoning_items"])?
                .nilIfBlank
            let thinkingBlocksJSON = RemoteGenerationClient.stringValue(object["thinking_blocks"])?
                .nilIfBlank
            guard let role = AgentRuntimeMessage.Role(rawValue: rawRole),
                  !content.isEmpty
                    || reasoningContent != nil
                    || reasoningItemsJSON != nil
                    || thinkingBlocksJSON != nil
                    || !toolCalls.isEmpty else {
                return nil
            }
            return AgentRuntimeMessage(
                role: role,
                content: content,
                reasoningContent: reasoningContent,
                reasoningItemsJSON: reasoningItemsJSON,
                thinkingBlocksJSON: thinkingBlocksJSON,
                providerResponseID: RemoteGenerationClient.stringValue(object["response_id"])?.nilIfBlank
                    ?? RemoteGenerationClient.stringValue(object["provider_response_id"])?.nilIfBlank,
                toolCalls: toolCalls,
                toolCallID: RemoteGenerationClient.stringValue(object["tool_call_id"])?.nilIfBlank,
                toolName: RemoteGenerationClient.stringValue(object["name"])?.nilIfBlank
            )
        }
    }

    public static func workingDirectory(from params: [String: Any]) -> String? {
        stringValue(from: params, keys: [
            "cwd",
            "workingDirectory",
            "working_directory",
            "workspace",
            "workspacePath",
            "workspace_path"
        ])
    }

    public static func mcpServerDefinitions(from params: [String: Any]) -> [ACPMCPServerDefinition] {
        mcpServerEntries(from: params).compactMap { fallbackName, value in
            guard let object = value as? [String: Any] else {
                return nil
            }
            return mcpServerDefinition(from: object, fallbackName: fallbackName)
        }
    }

    public static func mcpServerInputSummary(from params: [String: Any]) -> String {
        guard let value = mcpServerValue(from: params) else {
            return "absent"
        }
        if let values = value as? [Any] {
            return "array(\(values.count))"
        }
        if let object = value as? [String: Any] {
            if mcpServerObjectLooksLikeDefinition(object) {
                return "object(single)"
            }
            let keys = object.keys.sorted().prefix(6).joined(separator: ",")
            let suffix = object.count > 6 ? ",..." : ""
            return "object(\(object.count):\(keys)\(suffix))"
        }
        return "\(type(of: value))"
    }

    public static func mcpServerInputDetails(from params: [String: Any]) -> String {
        guard let value = mcpServerValue(from: params) else {
            return "absent"
        }
        let sanitizedValue = sanitizedMCPServerLogValue(value)
        guard JSONSerialization.isValidJSONObject(sanitizedValue),
              let data = try? JSONSerialization.data(
                  withJSONObject: sanitizedValue,
                  options: [.sortedKeys]
              ),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: sanitizedValue)
        }
        return text
    }

    public static func allowedToolNames(from params: [String: Any]) -> Set<String>? {
        for key in allowedToolParameterKeys {
            if let names = allowedToolNames(from: params[key]) {
                return names
            }
        }

        if let config = params["config"] as? [String: Any],
           let names = allowedToolNames(from: config) {
            return names
        }

        return nil
    }

    public static func allowedToolNames(from value: Any?) -> Set<String>? {
        if let names = value as? [String] {
            return expandedAllowedToolNames(from: names)
        }

        if let values = value as? [Any] {
            return expandedAllowedToolNames(
                from: values.compactMap(allowedToolName)
            )
        }

        if let object = value as? [String: Any] {
            for key in allowedToolParameterKeys + ["names", "enabled", "items"] {
                if let names = allowedToolNames(from: object[key]) {
                    return names
                }
            }
            if let name = allowedToolName(object) {
                return expandedAllowedToolNames(from: [name])
            }
            return nil
        }

        return nil
    }

    public static func memoryToolEnabled(_ allowedToolNames: Set<String>?) -> Bool {
        guard let allowedToolNames else {
            return true
        }
        return allowedToolNames.contains { $0.hasPrefix("memory.") }
    }

    public static func thinkingSelection(from value: Any?) -> AgentThinkingSelection? {
        guard let rawValue = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawValue.isEmpty else {
            return nil
        }
        return AgentThinkingSelection(rawValue: rawValue)
    }

    private static func stringValue(
        from params: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = (params[key] as? String)?.nilIfBlank {
                return value
            }
        }
        return nil
    }

    private static func arrayValue(
        from params: [String: Any],
        keys: [String]
    ) -> [Any]? {
        for key in keys {
            if let value = params[key] as? [Any] {
                return value
            }
        }
        return nil
    }

    private static func mcpServerValue(from params: [String: Any]) -> Any? {
        for key in ["mcpServers", "mcp_servers"] {
            if let value = params[key] {
                return value
            }
        }
        if let config = params["config"] as? [String: Any] {
            for key in ["mcpServers", "mcp_servers"] {
                if let value = config[key] {
                    return value
                }
            }
        }
        return nil
    }

    private static func mcpServerEntries(from params: [String: Any]) -> [(String?, Any)] {
        guard let value = mcpServerValue(from: params) else {
            return []
        }
        if let values = value as? [Any] {
            return values.map { (nil, $0) }
        }
        guard let object = value as? [String: Any] else {
            return []
        }
        if mcpServerObjectLooksLikeDefinition(object) {
            return [(nil, object)]
        }
        return object.keys.sorted().compactMap { key in
            guard let value = object[key] else {
                return nil
            }
            return (key, value)
        }
    }

    private static func mcpServerObjectLooksLikeDefinition(_ object: [String: Any]) -> Bool {
        stringValue(
            from: object,
            keys: [
                "command",
                "executable",
                "executablePath",
                "executable_path",
                "url",
                "endpoint",
                "endpointURL",
                "endpoint_url"
            ]
        ) != nil
    }

    private static func sanitizedMCPServerLogValue(_ value: Any, key: String? = nil) -> Any {
        if let object = value as? [String: Any] {
            let namedValueKey = stringValue(from: object, keys: ["name", "key"])
            return object.keys.sorted().reduce(into: [String: Any]()) { result, childKey in
                guard let childValue = object[childKey] else {
                    return
                }
                let redactionKey = childKey == "value" ? (namedValueKey ?? childKey) : childKey
                result[childKey] = sanitizedMCPServerLogValue(childValue, key: redactionKey)
            }
        }
        if let values = value as? [Any] {
            return values.map { sanitizedMCPServerLogValue($0) }
        }
        if let string = value as? String {
            return shouldRedactMCPServerLogValue(for: key)
                ? "<redacted:\(string.count)>"
                : string
        }
        if value is NSNull || value is Bool || value is NSNumber {
            return value
        }
        return String(describing: value)
    }

    private static func shouldRedactMCPServerLogValue(for key: String?) -> Bool {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return false
        }
        let lowercasedKey = key.lowercased()
        if lowercasedKey.hasPrefix("mcp_xcode") {
            return false
        }
        return [
            "authorization",
            "bearer",
            "cookie",
            "credential",
            "password",
            "secret",
            "token",
            "api_key",
            "apikey"
        ].contains { lowercasedKey.contains($0) }
    }

    private static func stringArrayValue(
        from params: [String: Any],
        keys: [String]
    ) -> [String] {
        for key in keys {
            if let strings = params[key] as? [String] {
                return strings
            }
            if let values = params[key] as? [Any] {
                return values.compactMap { value in
                    (value as? String)?.nilIfBlank
                }
            }
        }
        return []
    }

    private static func mcpServerDefinition(
        from object: [String: Any],
        fallbackName: String? = nil
    ) -> ACPMCPServerDefinition? {
        let rawType = stringValue(from: object, keys: ["type", "transport"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let type = rawType
            ?? (stringValue(from: object, keys: ["url", "endpoint", "endpointURL", "endpoint_url"]) == nil
                ? "stdio"
                : "http")
        let name = stringValue(from: object, keys: ["name", "id", "title"])
            ?? fallbackName?.nilIfBlank
            ?? fallbackMCPServerName(from: object, type: type)
        let protocolVersion = stringValue(
            from: object,
            keys: ["protocolVersion", "protocol_version", "preferredProtocolVersion", "preferred_protocol_version"]
        )

        switch type {
        case "stdio":
            guard let command = stringValue(
                from: object,
                keys: ["command", "executable", "executablePath", "executable_path"]
            ) else {
                return nil
            }
            let arguments = stringArrayValue(from: object, keys: ["args", "arguments"])
            let environment = stringMap(from: object, keys: ["env", "environment"])
            let configuration = MCPServerConfiguration(
                executablePath: command,
                arguments: arguments,
                environment: environment,
                preferredProtocolVersion: protocolVersion ?? "2024-11-05"
            )
            return ACPMCPServerDefinition(
                name: name,
                type: type,
                configuration: configuration,
                isXcodeCandidate: isXcodeMCPServerCandidate(
                    name: name,
                    command: command,
                    arguments: arguments,
                    environment: environment
                )
            )
        case "http":
            guard let rawURL = stringValue(
                from: object,
                keys: ["url", "endpoint", "endpointURL", "endpoint_url"]
            ),
                  let endpointURL = URL(string: rawURL) else {
                return nil
            }
            let configuration = MCPServerConfiguration(
                executablePath: "",
                arguments: [],
                environment: [:],
                endpointURL: endpointURL,
                httpHeaders: stringMap(from: object, keys: ["headers", "httpHeaders", "http_headers"]),
                preferredProtocolVersion: protocolVersion ?? "2025-03-26"
            )
            return ACPMCPServerDefinition(
                name: name,
                type: type,
                configuration: configuration,
                isXcodeCandidate: name.localizedCaseInsensitiveContains("xcode")
            )
        default:
            return nil
        }
    }

    private static func fallbackMCPServerName(
        from object: [String: Any],
        type: String
    ) -> String {
        if let rawURL = stringValue(
            from: object,
            keys: ["url", "endpoint", "endpointURL", "endpoint_url"]
        ),
           let host = URL(string: rawURL)?.host?.nilIfBlank {
            return host
        }
        if let command = stringValue(
            from: object,
            keys: ["command", "executable", "executablePath", "executable_path"]
        ) {
            return URL(fileURLWithPath: command).deletingPathExtension().lastPathComponent
        }
        return type == "http" ? "mcp-http" : "mcp-stdio"
    }

    private static func stringMap(
        from object: [String: Any],
        keys: [String]
    ) -> [String: String] {
        for key in keys {
            if let map = object[key] as? [String: String] {
                return map
            }
            if let map = object[key] as? [String: Any] {
                return map.reduce(into: [String: String]()) { result, pair in
                    if let value = pair.value as? String {
                        result[pair.key] = value
                    }
                }
            }
            if let values = object[key] as? [[String: String]] {
                return values.reduce(into: [String: String]()) { result, item in
                    guard let name = item["name"]?.nilIfBlank ?? item["key"]?.nilIfBlank else {
                        return
                    }
                    result[name] = item["value"] ?? ""
                }
            }
            if let values = object[key] as? [[String: Any]] {
                return values.reduce(into: [String: String]()) { result, item in
                    guard let name = stringValue(from: item, keys: ["name", "key"]) else {
                        return
                    }
                    result[name] = (item["value"] as? String) ?? ""
                }
            }
            if let values = object[key] as? [Any] {
                return values.reduce(into: [String: String]()) { result, value in
                    guard let item = value as? [String: Any],
                          let name = stringValue(from: item, keys: ["name", "key"]) else {
                        return
                    }
                    result[name] = (item["value"] as? String) ?? ""
                }
            }
        }
        return [:]
    }

    private static func isXcodeMCPServerCandidate(
        name: String,
        command: String,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        if name.localizedCaseInsensitiveContains("xcode") {
            return true
        }
        let commandName = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        if commandName == "mcpbridge" {
            return true
        }
        if commandName == "xcrun",
           arguments.contains(where: { $0.lowercased() == "mcpbridge" }) {
            return true
        }
        return environment.keys.contains { $0.hasPrefix("MCP_XCODE") }
    }

    private static let allowedToolParameterKeys = [
        "allowedTools",
        "allowed_tools",
        "toolNames",
        "tool_names",
        "enabledTools",
        "enabled_tools",
        "tools"
    ]

    private static func allowedToolName(_ value: Any) -> String? {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        }

        guard let object = value as? [String: Any] else {
            return nil
        }

        return stringValue(from: object, keys: [
            "name",
            "tool",
            "toolName",
            "tool_name",
            "id",
            "value"
        ])
    }

    private static func expandedAllowedToolNames(from rawNames: [String]) -> Set<String> {
        let names = rawNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else {
            return []
        }

        let items = TerminalToolSelectionCatalog.items(featureStatuses: [])
        var selectedKeys = Set<String>()
        var allowedToolNames = Set<String>()
        for name in names {
            if name.contains(".") {
                allowedToolNames.insert(name)
                continue
            }

            let matchingKeys = TerminalToolSelectionCatalog.selectionKeys(
                for: name,
                items: items
            )
            if matchingKeys.isEmpty {
                allowedToolNames.insert(name)
            } else {
                selectedKeys.formUnion(matchingKeys)
            }
        }

        allowedToolNames.formUnion(
            TerminalToolSelectionCatalog.allowedToolNames(
                for: selectedKeys,
                items: items
            )
        )
        return allowedToolNames
    }

    public func resolvedSystemPrompt(
        providedSystemPrompt: String?,
        cwd: String,
        allowedToolNames: Set<String>?
    ) -> String {
        AgentCoreAppSessionFactory.resolvedSystemPrompt(
            providedSystemPrompt: providedSystemPrompt,
            cwd: cwd,
            selectedAgent: configuration.selectedAgent,
            allowedToolNames: allowedToolNames
        )
    }

    public func selectedAgentSkillSection() -> String? {
        guard let selectedAgent = configuration.selectedAgent,
              !selectedAgent.skills.isEmpty else {
            return nil
        }

        let availableSkills = PromptSkillCatalog.discoverSkills(
            searchRoots: PromptSkillCatalog.appCatalogSearchRoots()
        )
        let selectedSkillIDs = selectedAgent.selectedSkillIDs(
            availableSkills: availableSkills
        )
        let selectedSkills = availableSkills.filter { selectedSkillIDs.contains($0.id) }
        return MLXSystemPromptBuilder.selectedSkillSection(skills: selectedSkills)
    }

}
