//
//  OpenRouterToolSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public nonisolated struct OpenRouterToolDefinition: Equatable, Sendable {
    public let name: String
    public let description: String
    public let parametersJSON: String
}

public nonisolated struct OpenRouterToolCall: Equatable, Sendable {
    public let id: String
    public let name: String
    public let arguments: String
}

public nonisolated enum OpenRouterToolCallResolutionError: LocalizedError, Sendable {
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidArguments(toolName):
            return "RemoteAPI emitted invalid JSON arguments for tool '\(toolName)'."
        }
    }
}

public nonisolated struct OpenRouterToolCatalog: Sendable {
    public nonisolated struct Binding: Hashable, Sendable {
        public let descriptor: ToolDescriptor
        public let wireName: String

        public var definition: OpenRouterToolDefinition {
            OpenRouterToolDefinition(
                name: wireName,
                description: descriptor.toolCallDescription(),
                parametersJSON: descriptor.inputSchema
            )
        }
    }

    public let bindings: [Binding]

    /// Lazily built lookup table: wireName / descriptorName / canonicalName → Binding
    private let _nameLookup: [String: Binding]

    public let definitions: [OpenRouterToolDefinition]

    public init(bindings: [Binding]) {
        self.bindings = bindings
        var lookup: [String: Binding] = [:]
        lookup.reserveCapacity(bindings.count * 5)
        for binding in bindings {
            lookup[binding.wireName] = binding
            lookup[binding.descriptor.name] = binding
            let sanitized = sanitizedRemoteToolWireName(for: binding.descriptor.name)
            lookup[sanitized] = binding
            if sanitized.hasPrefix("tool_") {
                let trimmed = String(sanitized.dropFirst("tool_".count))
                if lookup[trimmed] == nil {
                    lookup[trimmed] = binding
                }
            }
            if let canonical = SubAgentToolRequestCompatibility.canonicalToolName(
                for: binding.descriptor.name
            ) {
                lookup[canonical] = binding
            }
            let underscoredName = binding.descriptor.name
                .replacingOccurrences(
                    of: #"[^A-Za-z0-9_]+"#,
                    with: "_",
                    options: .regularExpression
                )
            if lookup[underscoredName] == nil {
                lookup[underscoredName] = binding
            }
            // Pre-populate folded (case + diacritic insensitive) variants
            // to avoid expensive per-lookup folding scans at match time.
            let foldedWireName = binding.wireName.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if lookup[foldedWireName] == nil {
                lookup[foldedWireName] = binding
            }
            let foldedDescriptorName = binding.descriptor.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if lookup[foldedDescriptorName] == nil {
                lookup[foldedDescriptorName] = binding
            }
        }
        self._nameLookup = lookup
        self.definitions = bindings.map(\.definition)
    }

    public func toolRequest(from toolCall: OpenRouterToolCall) throws -> ToolRequest {
        guard let binding = binding(forRemoteToolName: toolCall.name) else {
            throw ToolExecutionError.toolNotAvailable(toolCall.name)
        }

        let normalizedArguments = toolCall.arguments
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? "{}" : toolCall.arguments
        guard let data = normalizedArguments.data(using: .utf8) else {
            throw OpenRouterToolCallResolutionError.invalidArguments(binding.descriptor.name)
        }

        guard let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw OpenRouterToolCallResolutionError.invalidArguments(binding.descriptor.name)
        }

        return ToolRequest(name: binding.descriptor.name, arguments: arguments)
    }

    public func renderedToolCalls(_ toolCalls: [OpenRouterToolCall]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(toolCalls.count)
        for toolCall in toolCalls {
            guard let binding = binding(forRemoteToolName: toolCall.name) else {
                continue
            }

            let normalizedArguments = toolCall.arguments
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? "{}" : toolCall.arguments
            guard let argumentsData = normalizedArguments.data(using: .utf8),
                  let arguments = try? JSONDecoder().decode(JSONValue.self, from: argumentsData),
                  let renderedData = try? JSONValue(jsonObject: [
                      "tool": binding.descriptor.name,
                      "arguments": arguments.jsonObject
                  ]).jsonData(
                      outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                  ),
                  let renderedString = String(data: renderedData, encoding: .utf8) else {
                continue
            }

            parts.append(renderedString)
        }

        return parts.joined(separator: "\n\n")
    }

    public func binding(
        forRemoteToolName remoteToolName: String
    ) -> Binding? {
        if let match = _nameLookup[remoteToolName] {
            return match
        }

        // Try the folded form in the pre-populated lookup before falling back to scan.
        let foldedTarget = remoteToolName.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        if let match = _nameLookup[foldedTarget] {
            return match
        }

        let sanitizedTarget = sanitizedRemoteToolWireName(for: remoteToolName)
        if let match = _nameLookup[sanitizedTarget] {
            return match
        }
        let foldedSanitizedTarget = sanitizedTarget.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        if let match = _nameLookup[foldedSanitizedTarget] {
            return match
        }

        if let canonicalToolName = SubAgentToolRequestCompatibility.canonicalToolName(
            for: remoteToolName
        ),
           let match = _nameLookup[canonicalToolName] {
            return match
        }

        // Last resort: linear scan with folding for any remaining fuzzy matches.
        return bindings.first { binding in
            binding.wireName.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) == foldedTarget
            || binding.descriptor.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) == foldedTarget
        }
    }
}

public nonisolated enum OpenRouterToolCatalogBuilder {
    public static func makeCatalog(from tools: [ToolDescriptor]) -> OpenRouterToolCatalog {
        var usedWireNames: Set<String> = []
        let bindings = tools.map { descriptor in
            let wireName = uniqueWireName(
                for: descriptor.name,
                usedWireNames: &usedWireNames
            )
            return OpenRouterToolCatalog.Binding(
                descriptor: descriptor,
                wireName: wireName
            )
        }
        return OpenRouterToolCatalog(bindings: bindings)
    }

    private static func uniqueWireName(
        for appToolName: String,
        usedWireNames: inout Set<String>
    ) -> String {
        let sanitizedBase = sanitizedRemoteToolWireName(for: appToolName)
        var candidate = sanitizedBase
        var suffix = 2

        while usedWireNames.contains(candidate) {
            candidate = "\(sanitizedBase)_\(suffix)"
            suffix += 1
        }

        usedWireNames.insert(candidate)
        return candidate
    }
}

public nonisolated struct RemoteToolWireCatalog {
    public nonisolated struct Binding {
        public let descriptor: DirectToolDescriptor
        public let wireName: String

        public var chatCompletionToolPayload: [String: Any]? {
            guard let schema = descriptor.schemaObject else {
                return nil
            }
            return [
                "type": "function",
                "function": [
                    "name": wireName,
                    "description": descriptor.description,
                    "parameters": schema
                ]
            ]
        }

        public var responsesToolPayload: [String: Any]? {
            guard let schema = descriptor.schemaObject,
                  let parameters = RemoteToolSchemaCompatibility.responsesFunctionParameters(
                      from: schema
                  ) else {
                return nil
            }
            return [
                "type": "function",
                "name": wireName,
                "description": descriptor.description,
                "parameters": parameters
            ]
        }
    }

    public let bindings: [Binding]
    private let nameLookup: [String: Binding]

    public init(descriptors: [DirectToolDescriptor]) {
        var usedWireNames: Set<String> = []
        let bindings = descriptors.sorted(by: Self.canonicalDescriptorOrder).map { descriptor in
            Binding(
                descriptor: descriptor,
                wireName: Self.uniqueWireName(
                    for: descriptor.name,
                    usedWireNames: &usedWireNames
                )
            )
        }

        var lookup: [String: Binding] = [:]
        lookup.reserveCapacity(bindings.count * 6)
        for binding in bindings {
            Self.insert(binding, for: binding.wireName, into: &lookup, overwrite: true)
            Self.insert(binding, for: binding.descriptor.name, into: &lookup, overwrite: true)

            let sanitized = sanitizedRemoteToolWireName(for: binding.descriptor.name)
            Self.insert(binding, for: sanitized, into: &lookup)
            if sanitized.hasPrefix("tool_") {
                Self.insert(
                    binding,
                    for: String(sanitized.dropFirst("tool_".count)),
                    into: &lookup
                )
            }

            let underscoredName = binding.descriptor.name
                .replacingOccurrences(
                    of: #"[^A-Za-z0-9_]+"#,
                    with: "_",
                    options: .regularExpression
                )
            Self.insert(binding, for: underscoredName, into: &lookup)
        }

        self.bindings = bindings
        self.nameLookup = lookup
    }

    private static func canonicalDescriptorOrder(
        _ lhs: DirectToolDescriptor,
        _ rhs: DirectToolDescriptor
    ) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        if lhs.description != rhs.description {
            return lhs.description < rhs.description
        }
        return lhs.inputSchema < rhs.inputSchema
    }

    public var responsesToolPayloads: [[String: Any]] {
        bindings.compactMap(\.responsesToolPayload)
    }

    public var chatCompletionToolPayloads: [[String: Any]] {
        bindings.compactMap(\.chatCompletionToolPayload)
    }

    public func wireMessages(from messages: [[String: Any]]) -> [[String: Any]] {
        messages.map(wireMessage)
    }

    public func wireMessage(from message: [String: Any]) -> [String: Any] {
        var message = message
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            message["tool_calls"] = toolCalls.map(wireToolCallPayload)
        }
        if remoteToolWireStringValue(message["role"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "tool",
           let toolName = remoteToolWireStringValue(message["name"])?.nilIfBlank {
            message["name"] = wireName(forToolName: toolName)
        }
        return message
    }

    public func wireName(forToolName toolName: String) -> String {
        binding(forToolName: toolName)?.wireName
            ?? sanitizedRemoteToolWireName(for: toolName)
    }

    public func localToolCall(from toolCall: DirectAgentToolCall) -> DirectAgentToolCall {
        guard let binding = binding(forToolName: toolCall.name),
              binding.descriptor.name != toolCall.name else {
            return toolCall
        }

        return DirectAgentToolCall(
            id: toolCall.id,
            name: binding.descriptor.name,
            argumentsObject: toolCall.argumentsObject,
            argumentsJSON: toolCall.argumentsJSON
        )
    }

    public func wireToolCall(from toolCall: DirectAgentToolCall) -> DirectAgentToolCall {
        let wireName = binding(forToolName: toolCall.name)?.wireName
            ?? sanitizedRemoteToolWireName(for: toolCall.name)
        guard wireName != toolCall.name else {
            return toolCall
        }

        return DirectAgentToolCall(
            id: toolCall.id,
            name: wireName,
            argumentsObject: toolCall.argumentsObject,
            argumentsJSON: toolCall.argumentsJSON
        )
    }

    public func binding(forToolName toolName: String) -> Binding? {
        if let binding = nameLookup[toolName] {
            return binding
        }

        let foldedName = foldedToolWireName(toolName)
        if let binding = nameLookup[foldedName] {
            return binding
        }

        let sanitizedName = sanitizedRemoteToolWireName(for: toolName)
        if let binding = nameLookup[sanitizedName] {
            return binding
        }

        return nameLookup[foldedToolWireName(sanitizedName)]
    }

    private static func uniqueWireName(
        for toolName: String,
        usedWireNames: inout Set<String>
    ) -> String {
        let sanitizedBase = sanitizedRemoteToolWireName(for: toolName)
        var candidate = sanitizedBase
        var suffix = 2

        while usedWireNames.contains(candidate) {
            candidate = "\(sanitizedBase)_\(suffix)"
            suffix += 1
        }

        usedWireNames.insert(candidate)
        return candidate
    }

    private static func insert(
        _ binding: Binding,
        for name: String,
        into lookup: inout [String: Binding],
        overwrite: Bool = false
    ) {
        guard !name.isEmpty else {
            return
        }

        if overwrite || lookup[name] == nil {
            lookup[name] = binding
        }

        let foldedName = foldedToolWireName(name)
        if overwrite || lookup[foldedName] == nil {
            lookup[foldedName] = binding
        }
    }

    private func wireToolCallPayload(_ toolCall: [String: Any]) -> [String: Any] {
        guard var function = toolCall["function"] as? [String: Any],
              let toolName = remoteToolWireStringValue(function["name"])?.nilIfBlank else {
            return toolCall
        }

        var toolCall = toolCall
        function["name"] = wireName(forToolName: toolName)
        toolCall["function"] = function
        return toolCall
    }
}

public enum RemoteToolSchemaCompatibility {
    private static let unsupportedTopLevelKeywords: Set<String> = [
        "oneOf",
        "anyOf",
        "allOf",
        "enum",
        "not"
    ]

    public static func responsesFunctionParameters(from schema: Any) -> [String: Any]? {
        guard var object = schema as? [String: Any] else {
            return [
                "type": "object",
                "properties": [:]
            ]
        }

        var properties = object["properties"] as? [String: Any] ?? [:]
        var required = Set(requiredProperties(from: object["required"]))

        mergeTopLevelObjectSchemas(
            from: object["allOf"],
            into: &properties,
            required: &required,
            includeRequired: true
        )
        mergeTopLevelObjectSchemas(
            from: object["oneOf"],
            into: &properties,
            required: &required,
            includeRequired: false
        )
        mergeTopLevelObjectSchemas(
            from: object["anyOf"],
            into: &properties,
            required: &required,
            includeRequired: false
        )

        object["type"] = "object"
        object["properties"] = properties
        if required.isEmpty {
            object.removeValue(forKey: "required")
        } else {
            object["required"] = required.sorted()
        }
        for keyword in unsupportedTopLevelKeywords {
            object.removeValue(forKey: keyword)
        }
        return object
    }

    private static func mergeTopLevelObjectSchemas(
        from value: Any?,
        into properties: inout [String: Any],
        required: inout Set<String>,
        includeRequired: Bool
    ) {
        guard let schemas = value as? [[String: Any]] else {
            return
        }

        for schema in schemas {
            if let schemaProperties = schema["properties"] as? [String: Any] {
                for (key, value) in schemaProperties where properties[key] == nil {
                    properties[key] = value
                }
            }
            if includeRequired {
                required.formUnion(requiredProperties(from: schema["required"]))
            }
        }
    }

    private static func requiredProperties(from value: Any?) -> [String] {
        guard let values = value as? [Any] else {
            return []
        }
        return values.compactMap { value in
            (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        }
    }
}

public nonisolated func sanitizedRemoteToolWireName(
    for appToolName: String
) -> String {
    var body = ""
    var lastCharacterWasSeparator = false

    for scalar in appToolName.unicodeScalars {
        let isAllowed =
            scalar.isASCIILetterOrDigit
            || scalar == "_"
            || scalar == "-"

        if isAllowed {
            body.unicodeScalars.append(scalar)
            lastCharacterWasSeparator = false
        } else if !lastCharacterWasSeparator {
            body.append("_")
            lastCharacterWasSeparator = true
        }
    }

    let trimmedBody = body.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    if trimmedBody.isEmpty {
        return "tool"
    }

    return "tool_\(trimmedBody)"
}

private nonisolated func foldedToolWireName(_ name: String) -> String {
    name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
}

private nonisolated func remoteToolWireStringValue(_ value: Any?) -> String? {
    JSONValue(jsonObject: value).flexibleStringValue
}

private extension UnicodeScalar {
    var isASCIILetterOrDigit: Bool {
        (65...90).contains(value)
            || (97...122).contains(value)
            || (48...57).contains(value)
    }
}
