//
//  OpenRouterToolSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public nonisolated struct RemoteToolWireCatalog: Sendable {
    public nonisolated struct Binding: Sendable {
        public let descriptor: DirectToolDescriptor
        public let wireName: String
        fileprivate var compiledPayload: CompiledPayload? = nil

        public var chatCompletionToolPayload: [String: Any]? {
            if let compiledPayload, compiledPayload.dialect == .chatCompletions {
                return compiledPayload.value
            }
            guard let schema = descriptor.schemaObject else {
                return nil
            }
            let sanitized = RemoteToolSchemaCompatibility
                .chatCompletionsFunctionParameters(from: schema)
            return [
                "type": "function",
                "function": [
                    "name": wireName,
                    "description": descriptor.description,
                    "parameters": sanitized
                ]
            ]
        }

        public var responsesToolPayload: [String: Any]? {
            if let compiledPayload, compiledPayload.dialect == .responses {
                return compiledPayload.value
            }
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

        var anthropicMessagesToolPayload: [String: Any]? {
            if let compiledPayload, compiledPayload.dialect == .anthropicMessages {
                return compiledPayload.value
            }
            guard let function = chatCompletionToolPayload?["function"] as? [String: Any],
                  let schema = function["parameters"] else { return nil }
            return [
                "name": wireName,
                "description": descriptor.description,
                "input_schema": schema
            ]
        }

        var anthropicSubscriptionToolPayload: [String: Any]? {
            if let compiledPayload, compiledPayload.dialect == .anthropicSubscription {
                return compiledPayload.value
            }
            guard let schema = descriptor.schemaObject else { return nil }
            // Subscription tools retain the raw schema and eager streaming;
            // the generic Anthropic dialect intentionally does neither.
            return [
                "name": wireName,
                "description": descriptor.description,
                "eager_input_streaming": true,
                "input_schema": schema
            ]
        }

        fileprivate func payload(for dialect: RemoteToolWireDialect) -> [String: Any]? {
            switch dialect {
            case .chatCompletions: chatCompletionToolPayload
            case .responses: responsesToolPayload
            case .anthropicMessages: anthropicMessagesToolPayload
            case .anthropicSubscription: anthropicSubscriptionToolPayload
            }
        }
    }

    /// The only unchecked value is private, immutable JSON produced by
    /// descriptor.schemaObject and our pure schema transforms (Swift value
    /// dictionaries/arrays/scalars and NSNull). No caller-owned Any or mutable
    /// Foundation container enters it. Returned Swift dictionaries are
    /// copy-on-write; the existing provider value types are kept unchanged.
    fileprivate nonisolated final class CompiledPayload: @unchecked Sendable {
        let dialect: RemoteToolWireDialect
        let value: [String: Any]?

        init(binding: Binding, dialect: RemoteToolWireDialect) {
            self.dialect = dialect
            self.value = binding.payload(for: dialect)
        }
    }

    /// Contains only pure wire artifacts, never descriptors or authorization.
    fileprivate nonisolated struct Compilation: Sendable {
        let descriptorOrder: [Int]
        let wireNames: [String]
        let payloads: [CompiledPayload?]
        let localNameLookup: [String: Int]
        let wireNameLookup: [String: Int]
        let compatibilityNameLookup: [String: Int]

        init(descriptors: [DirectToolDescriptor], dialect: RemoteToolWireDialect?) {
            let order = descriptors.indices.sorted {
                RemoteToolWireCatalog.canonicalDescriptorOrder(descriptors[$0], descriptors[$1])
            }
            var usedWireNames: Set<String> = []
            let bindings = order.map { index in
                Binding(
                    descriptor: descriptors[index],
                    wireName: RemoteToolWireCatalog.uniqueWireName(
                        for: descriptors[index].name,
                        usedWireNames: &usedWireNames
                    )
                )
            }
            var localLookup: [String: Int] = [:]
            var wireLookup: [String: Int] = [:]
            var compatibilityLookup: [String: Int] = [:]
            localLookup.reserveCapacity(bindings.count * 2)
            wireLookup.reserveCapacity(bindings.count * 2)
            compatibilityLookup.reserveCapacity(bindings.count * 4)
            for (index, binding) in bindings.enumerated() {
                RemoteToolWireCatalog.insert(index, for: binding.descriptor.name, into: &localLookup, overwrite: true)
                RemoteToolWireCatalog.insert(index, for: binding.wireName, into: &wireLookup, overwrite: true)
                let sanitized = sanitizedRemoteToolWireName(for: binding.descriptor.name)
                RemoteToolWireCatalog.insert(index, for: sanitized, into: &compatibilityLookup)
                if sanitized.hasPrefix("tool_") {
                    RemoteToolWireCatalog.insert(index, for: String(sanitized.dropFirst("tool_".count)), into: &compatibilityLookup)
                }
                let underscoredName = binding.descriptor.name.replacingOccurrences(
                    of: #"[^A-Za-z0-9_]+"#, with: "_", options: .regularExpression
                )
                RemoteToolWireCatalog.insert(index, for: underscoredName, into: &compatibilityLookup)
            }
            descriptorOrder = order
            wireNames = bindings.map(\.wireName)
            payloads = bindings.map { binding in
                dialect.map { CompiledPayload(binding: binding, dialect: $0) }
            }
            localNameLookup = localLookup
            wireNameLookup = wireLookup
            compatibilityNameLookup = compatibilityLookup
        }
    }

    public let bindings: [Binding]
    private let compilation: Compilation

    public init(descriptors: [DirectToolDescriptor]) {
        self.init(descriptors: descriptors, compilation: Compilation(descriptors: descriptors, dialect: nil))
    }

    fileprivate init(descriptors: [DirectToolDescriptor], compilation: Compilation) {
        self.compilation = compilation
        // Rebind on every call, including hits: title/presentation and
        // output schemas belong to the freshly discovered descriptors.
        self.bindings = compilation.descriptorOrder.enumerated().map { offset, index in
            Binding(
                descriptor: descriptors[index],
                wireName: compilation.wireNames[offset],
                compiledPayload: compilation.payloads[offset]
            )
        }
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
        bindingForLocalToolName(toolName)?.wireName
            ?? sanitizedRemoteToolWireName(for: toolName)
    }

    public func localToolCall(from toolCall: DirectAgentToolCall) -> DirectAgentToolCall {
        guard let binding = bindingForIncomingToolName(toolCall.name) else {
            return toolCall
        }

        return DirectAgentToolCall(
            id: toolCall.id,
            name: binding.descriptor.name,
            argumentsObject: toolCall.argumentsObject,
            argumentsJSON: toolCall.argumentsJSON,
            descriptorTitle: binding.descriptor.title,
            presentation: binding.descriptor.presentation
        )
    }

    public func wireToolCall(from toolCall: DirectAgentToolCall) -> DirectAgentToolCall {
        let wireName = bindingForLocalToolName(toolCall.name)?.wireName
            ?? sanitizedRemoteToolWireName(for: toolCall.name)
        guard wireName != toolCall.name else {
            return toolCall
        }

        return DirectAgentToolCall(
            id: toolCall.id,
            name: wireName,
            argumentsObject: toolCall.argumentsObject,
            argumentsJSON: toolCall.argumentsJSON,
            descriptorTitle: toolCall.descriptorTitle,
            presentation: toolCall.presentation
        )
    }

    public func binding(forToolName toolName: String) -> Binding? {
        bindingForLocalToolName(toolName)
            ?? bindingForWireToolName(toolName)
            ?? bindingForCompatibilityName(toolName)
    }

    private func bindingForIncomingToolName(_ toolName: String) -> Binding? {
        // A response name is interpreted in the namespace advertised to the
        // model first. This matters when one tool's canonical name is another
        // tool's generated wire name.
        bindingForWireToolName(toolName)
            ?? bindingForLocalToolName(toolName)
            ?? bindingForCompatibilityName(toolName)
    }

    private func bindingForLocalToolName(_ toolName: String) -> Binding? {
        let index = compilation.localNameLookup[toolName]
            ?? compilation.localNameLookup[foldedToolWireName(toolName)]
        return index.map { bindings[$0] }
    }

    private func bindingForWireToolName(_ toolName: String) -> Binding? {
        let index = compilation.wireNameLookup[toolName]
            ?? compilation.wireNameLookup[foldedToolWireName(toolName)]
        return index.map { bindings[$0] }
    }

    private func bindingForCompatibilityName(_ toolName: String) -> Binding? {
        if let index = compilation.compatibilityNameLookup[toolName]
            ?? compilation.compatibilityNameLookup[foldedToolWireName(toolName)] {
            return bindings[index]
        }

        let sanitizedName = sanitizedRemoteToolWireName(for: toolName)
        let index = compilation.compatibilityNameLookup[sanitizedName]
            ?? compilation.compatibilityNameLookup[foldedToolWireName(sanitizedName)]
        return index.map { bindings[$0] }
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
        _ binding: Int,
        for name: String,
        into lookup: inout [String: Int],
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

/// Dialects are deliberately distinct even where their naming rules coincide.
nonisolated enum RemoteToolWireDialect: Sendable, Equatable {
    case chatCompletions
    case responses
    case anthropicMessages
    case anthropicSubscription
}

/// Actor-owned, single-entry, in-memory cache. Callers must discover descriptors
/// and resolve grants *before* consulting it. It never caches either operation,
/// tool execution, session state, or a permission decision.
nonisolated struct RemoteToolWireCatalogCache: Sendable {
    private struct Input: Sendable {
        let name: String
        let description: String
        let schema: String

        init(_ descriptor: DirectToolDescriptor) {
            name = descriptor.name
            description = descriptor.description
            schema = descriptor.inputSchema
        }

        func matches(_ descriptor: DirectToolDescriptor) -> Bool {
            // String equality is Unicode-canonical, not byte-exact. Do not
            // reuse a payload whose original wire spelling has changed.
            name.utf8.elementsEqual(descriptor.name.utf8)
                && description.utf8.elementsEqual(descriptor.description.utf8)
                && schema.utf8.elementsEqual(descriptor.inputSchema.utf8)
        }
    }

    private struct Entry: Sendable {
        let inputs: [Input]
        let dialect: RemoteToolWireDialect
        let compilation: RemoteToolWireCatalog.Compilation
    }

    private var entry: Entry?
    /// Internal deterministic instrumentation; no clocks or global state.
    private(set) var compilationCount = 0

    mutating func catalog(
        descriptors: [DirectToolDescriptor],
        dialect: RemoteToolWireDialect
    ) -> RemoteToolWireCatalog {
        if let entry,
           entry.dialect == dialect,
           entry.inputs.count == descriptors.count,
           zip(entry.inputs, descriptors).allSatisfy({ pair in pair.0.matches(pair.1) }) {
            return RemoteToolWireCatalog(descriptors: descriptors, compilation: entry.compilation)
        }
        let compilation = RemoteToolWireCatalog.Compilation(descriptors: descriptors, dialect: dialect)
        entry = Entry(inputs: descriptors.map(Input.init), dialect: dialect, compilation: compilation)
        compilationCount += 1
        return RemoteToolWireCatalog(descriptors: descriptors, compilation: compilation)
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

    /// Sanitizes a JSON Schema for `/chat/completions` providers whose strict
    /// Codable decoders reject constructs valid in JSON Schema Draft 7+:
    ///
    /// - Union types (`"type": ["string", "null"]`) are flattened to the first
    ///   non-`null` concrete type.
    /// - Empty schemas (`{}`, valid for "accept anything") default to
    ///   `{"type": "string"}`.
    /// - Object schemas missing `properties` get an empty `properties` map so
    ///   strict decoders can materialize the object.
    ///
    /// These transforms are conservative: they make the schema more specific
    /// without changing the set of JSON values the model can produce.
    public static func chatCompletionsFunctionParameters(from schema: Any) -> Any {
        sanitizeChatCompletionsSchema(schema)
    }

    private static func sanitizeChatCompletionsSchema(_ value: Any) -> Any {
        guard var object = value as? [String: Any] else {
            return value
        }

        // Flatten union type arrays: ["string", "null"] → "string"
        if let typeArray = object["type"] as? [Any] {
            let typeStrings = typeArray.compactMap { $0 as? String }
            let resolved = typeStrings.first(where: { $0 != "null" })
                ?? typeStrings.first
            if let resolved {
                object["type"] = resolved
            }
        }

        // Recurse into nested properties
        if let properties = object["properties"] as? [String: Any] {
            object["properties"] = properties.mapValues {
                sanitizeChatCompletionsSchema($0)
            }
        }

        // Recurse into items (single-schema array form)
        if let items = object["items"] {
            let sanitized = sanitizeChatCompletionsSchema(items)
            if let sanitizedDict = sanitized as? [String: Any],
               sanitizedDict.isEmpty {
                // Empty schema {} is valid JSON Schema (accept anything) but
                // rejected by strict Codable decoders such as Apple Foundation
                // Models. Default to string, which the model can always emit.
                object["items"] = ["type": "string"]
            } else {
                object["items"] = sanitized
            }
        }

        // Fix object schemas missing properties: strict decoders require it
        if object["type"] as? String == "object",
           object["properties"] == nil {
            object["properties"] = [String: Any]()
        }

        return object
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
