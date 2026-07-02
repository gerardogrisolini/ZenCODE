//
//  AgentSettingsManifest.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(os)
import os
#endif

public struct AgentSettingsModelManifest: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case llmID
        case modelID
        case providerID
        case provider
        case context
        case generation
        case thinking
    }

    private struct ContextManifest: Codable, Hashable, Sendable {
        let configuredWindowLimit: Int?

        init(configuredWindowLimit: Int?) {
            self.configuredWindowLimit = configuredWindowLimit.map {
                min(max($0, 1), 1_048_576)
            }
        }

        var isEmpty: Bool {
            configuredWindowLimit == nil
        }
    }

    private struct GenerationManifest: Codable, Hashable, Sendable {
        let overrides: AgentGenerationParameterOverrides?

        init(overrides: AgentGenerationParameterOverrides?) {
            self.overrides = overrides?.normalized().nilIfEmpty
        }

        var isEmpty: Bool {
            overrides == nil
        }
    }

    private struct ThinkingManifest: Codable, Hashable, Sendable {
        private enum CodingKeys: String, CodingKey {
            case options
            case defaultSelection = "default"
        }

        let options: [AgentThinkingSelection]?
        let defaultSelection: AgentThinkingSelection?

        init(
            options: [AgentThinkingSelection]?,
            defaultSelection: AgentThinkingSelection?
        ) {
            let normalizedOptions = AgentSettingsModelManifest.normalizedThinkingOptions(
                options ?? []
            )
            self.options = normalizedOptions.isEmpty ? nil : normalizedOptions
            self.defaultSelection = AgentSettingsModelManifest.normalizedDefaultThinkingSelection(
                defaultSelection,
                options: normalizedOptions
            )
        }

        var isEmpty: Bool {
            options == nil && defaultSelection == nil
        }
    }

    public let id: String
    public let kind: AgentModelProviderKind
    public let title: String?
    public let llmID: String?
    public let modelID: String
    public let providerID: UUID?
    public let provider: AgentRemoteProvider?
    public let configuredContextWindowLimit: Int?
    public let generationParameterOverrides: AgentGenerationParameterOverrides?
    public let apiKey: String?
    public let thinkingOptions: [AgentThinkingSelection]?
    public let defaultThinkingSelection: AgentThinkingSelection?

    public init(
        id: String? = nil,
        kind: AgentModelProviderKind,
        title: String? = nil,
        llmID: String? = nil,
        modelID: String,
        providerID: UUID? = nil,
        provider: AgentRemoteProvider? = nil,
        configuredContextWindowLimit: Int? = nil,
        generationParameterOverrides: AgentGenerationParameterOverrides? = nil,
        apiKey: String? = nil,
        thinkingOptions: [AgentThinkingSelection]? = nil,
        defaultThinkingSelection: AgentThinkingSelection? = nil
    ) {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLLMID = llmID?.nilIfBlank
        let normalizedID = id?.nilIfBlank
            ?? normalizedLLMID
            ?? normalizedModelID
        let normalizedGenerationParameterOverrides = generationParameterOverrides?
            .normalized()
            .nilIfEmpty
        let normalizedThinkingOptions = Self.normalizedThinkingOptions(thinkingOptions ?? [])
        let normalizedDefaultThinkingSelection = Self.normalizedDefaultThinkingSelection(
            defaultThinkingSelection,
            options: normalizedThinkingOptions
        )
        self.id = normalizedID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.title = title?.nilIfBlank
        self.llmID = normalizedLLMID
        self.modelID = normalizedModelID
        self.providerID = kind == .remoteAPI ? (provider?.id ?? providerID) : nil
        self.provider = provider
        self.configuredContextWindowLimit = configuredContextWindowLimit.map {
            min(max($0, 1), 1_048_576)
        }
        self.generationParameterOverrides = normalizedGenerationParameterOverrides
        self.apiKey = apiKey?.nilIfBlank
        self.thinkingOptions = normalizedThinkingOptions.isEmpty ? nil : normalizedThinkingOptions
        self.defaultThinkingSelection = normalizedDefaultThinkingSelection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let context = try container.decodeIfPresent(ContextManifest.self, forKey: .context)
        let generation = try container.decodeIfPresent(
            GenerationManifest.self,
            forKey: .generation
        )
        let thinking = try container.decodeIfPresent(ThinkingManifest.self, forKey: .thinking)
        let provider = try container.decodeIfPresent(AgentRemoteProvider.self, forKey: .provider)
        let providerID = try container.decodeIfPresent(UUID.self, forKey: .providerID)

        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id),
            kind: try container.decode(AgentModelProviderKind.self, forKey: .kind),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            llmID: try container.decodeIfPresent(String.self, forKey: .llmID),
            modelID: try container.decode(String.self, forKey: .modelID),
            providerID: providerID,
            provider: provider,
            configuredContextWindowLimit: context?.configuredWindowLimit,
            generationParameterOverrides: generation?.overrides,
            apiKey: nil,
            thinkingOptions: thinking?.options,
            defaultThinkingSelection: thinking?.defaultSelection
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(llmID, forKey: .llmID)
        try container.encode(modelID, forKey: .modelID)
        if kind == .remoteAPI {
            try container.encodeIfPresent(providerID ?? provider?.id, forKey: .providerID)
        }

        let context = ContextManifest(
            configuredWindowLimit: configuredContextWindowLimit
        )
        if !context.isEmpty {
            try container.encode(context, forKey: .context)
        }

        let generation = GenerationManifest(
            overrides: generationParameterOverrides
        )
        if !generation.isEmpty {
            try container.encode(generation, forKey: .generation)
        }

        let thinking = ThinkingManifest(
            options: thinkingOptions,
            defaultSelection: defaultThinkingSelection
        )
        if !thinking.isEmpty {
            try container.encode(thinking, forKey: .thinking)
        }
    }

    public var displayTitle: String {
        if let title {
            return title
        }
        if let provider {
            return provider.displayTitleWithModelID
        }
        return modelID
    }

    public var availableThinkingSelections: [AgentThinkingSelection] {
        thinkingOptions ?? []
    }

    public var supportsThinking: Bool {
        !availableThinkingSelections.isEmpty
    }

    public var resolvedDefaultThinkingSelection: AgentThinkingSelection? {
        guard supportsThinking else {
            return nil
        }
        if let defaultThinkingSelection,
           availableThinkingSelections.contains(defaultThinkingSelection) {
            return defaultThinkingSelection
        }
        return availableThinkingSelections.first
    }

    public func thinkingSelection(
        for selection: AgentThinkingSelection?
    ) -> AgentThinkingSelection? {
        guard supportsThinking else {
            return nil
        }
        if let selection,
           availableThinkingSelections.contains(selection) {
            return selection
        }
        return resolvedDefaultThinkingSelection
    }

    public func matches(_ value: String) -> Bool {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else {
            return false
        }
        let foldedValue = normalizedValue.lowercased()
        return id.lowercased() == foldedValue
            || llmID?.lowercased() == foldedValue
            || modelID.lowercased() == foldedValue
    }

    public func normalized(
        providersByID: [UUID: AgentSettingsProviderManifest] = [:]
    ) -> AgentSettingsModelManifest? {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let resolvedProvider = provider
            ?? providerID.flatMap { providersByID[$0]?.remoteProvider(modelID: modelID) }
        if kind == .remoteAPI,
           resolvedProvider == nil {
            return nil
        }
        return AgentSettingsModelManifest(
            id: id,
            kind: kind,
            title: title,
            llmID: llmID,
            modelID: modelID,
            providerID: resolvedProvider?.id ?? providerID,
            provider: resolvedProvider,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            apiKey: apiKey,
            thinkingOptions: thinkingOptions,
            defaultThinkingSelection: defaultThinkingSelection
        )
    }

    private static func normalizedThinkingOptions(
        _ options: [AgentThinkingSelection]
    ) -> [AgentThinkingSelection] {
        var seen = Set<AgentThinkingSelection>()
        return options.filter { option in
            seen.insert(option).inserted
        }
    }

    private static func normalizedDefaultThinkingSelection(
        _ selection: AgentThinkingSelection?,
        options: [AgentThinkingSelection]
    ) -> AgentThinkingSelection? {
        guard !options.isEmpty else {
            return nil
        }
        if let selection,
           options.contains(selection) {
            return selection
        }
        return options.first
    }
}

