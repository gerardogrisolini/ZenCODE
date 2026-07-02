//
//  AgentProviderSettings.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public enum AgentModelProviderKind: Codable, Sendable {
    case remoteAPI

    public var displayTitle: String {
        "remote"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "remoteAPI":
            self = .remoteAPI
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported provider kind '\(rawValue)'."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode("remoteAPI")
    }
}

public enum AgentRemoteChatEndpoint: String, Codable, Sendable {
    case chatCompletions = "chat_completions"
    case responses = "responses"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .responses
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var path: String {
        switch self {
        case .chatCompletions:
            return "chat/completions"
        case .responses:
            return "responses"
        }
    }

    public var usesSessionID: Bool {
        switch self {
        case .chatCompletions:
            return false
        case .responses:
            return false
        }
    }
}

public struct AgentRemoteProvider: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case modelID
        case chatEndpoint
    }

    public static let defaultOpenRouterName = "OpenRouter"
    public static let defaultOpenRouterBaseURL = "https://openrouter.ai/api/v1"
    public static let defaultOpenRouterModelID = "openrouter/auto"
    public static let chatGPTSubscriptionProviderID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    public static let chatGPTSubscriptionBaseURL = "chatgpt://subscription"
    public static let anthropicSubscriptionProviderID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    public static let anthropicSubscriptionBaseURL = "anthropic://subscription"

    public let id: UUID
    public let name: String
    public let baseURL: String
    public let modelID: String
    public let chatEndpoint: AgentRemoteChatEndpoint

    public init(
        id: UUID = UUID(),
        name: String = Self.defaultOpenRouterName,
        baseURL: String = Self.defaultOpenRouterBaseURL,
        modelID: String = Self.defaultOpenRouterModelID,
        chatEndpoint: AgentRemoteChatEndpoint = .chatCompletions
    ) {
        self.id = id
        self.name = Self.normalizedName(name)
        self.baseURL = Self.normalizedBaseURL(baseURL)
        self.modelID = Self.normalizedModelID(modelID)
        self.chatEndpoint = chatEndpoint
    }

    public var displayTitle: String {
        Self.normalizedName(name)
    }

    public var displayTitleWithModelID: String {
        let normalizedModelID = Self.normalizedModelID(modelID)
        guard !normalizedModelID.isEmpty else {
            return displayTitle
        }
        return "\(displayTitle) - \(normalizedModelID)"
    }

    public var requiresAPIKey: Bool {
        guard !isChatGPTSubscriptionProvider,
              !isAnthropicSubscriptionProvider else {
            return false
        }
        return Self.isOpenRouterBaseURL(baseURL)
            || Self.isNVIDIABaseURL(baseURL)
            || Self.isModalDirectBaseURL(baseURL)
    }

    public var isChatGPTSubscriptionProvider: Bool {
        id == Self.chatGPTSubscriptionProviderID
            || Self.isChatGPTSubscriptionBaseURL(baseURL)
    }

    public var isAnthropicSubscriptionProvider: Bool {
        id == Self.anthropicSubscriptionProviderID
            || Self.isAnthropicSubscriptionBaseURL(baseURL)
    }

    public static func normalizedName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultOpenRouterName : trimmed
    }

    public static func normalizedBaseURL(_ value: String) -> String {
        var sanitized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while sanitized.hasSuffix("/") {
            sanitized.removeLast()
        }
        if sanitized.isEmpty {
            return defaultOpenRouterBaseURL
        }
        return sanitized
    }

    public static func normalizedModelID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isOpenRouterBaseURL(_ value: String) -> Bool {
        let normalizedValue = normalizedBaseURL(value)
        if let host = URL(string: normalizedValue)?.host?.lowercased() {
            return host == "openrouter.ai" || host.hasSuffix(".openrouter.ai")
        }
        return normalizedValue.lowercased().contains("openrouter.ai")
    }

    public static func isNVIDIABaseURL(_ value: String) -> Bool {
        let normalizedValue = normalizedBaseURL(value)
        if let host = URL(string: normalizedValue)?.host?.lowercased() {
            return host == "integrate.api.nvidia.com"
        }
        return normalizedValue.lowercased().contains("integrate.api.nvidia.com")
    }

    public static func isModalDirectBaseURL(_ value: String) -> Bool {
        let normalizedValue = normalizedBaseURL(value)
        if let host = URL(string: normalizedValue)?.host?.lowercased() {
            return host == "modal.direct" || host.hasSuffix(".modal.direct")
        }
        return normalizedValue.lowercased().contains("modal.direct")
    }

    public static func isChatGPTSubscriptionBaseURL(_ value: String) -> Bool {
        normalizedBaseURL(value).lowercased() == chatGPTSubscriptionBaseURL
    }

    public static func isAnthropicSubscriptionBaseURL(_ value: String) -> Bool {
        normalizedBaseURL(value).lowercased() == anthropicSubscriptionBaseURL
    }

}

public struct AgentModelSelection: Sendable {
    public let providerKind: AgentModelProviderKind
    public let modelID: String
    public let remoteProvider: AgentRemoteProvider?
    public let apiKey: String?
    public let configuredContextWindowLimit: Int?
    public let generationParameterOverrides: AgentGenerationParameterOverrides?
    public let thinkingSelection: AgentThinkingSelection?
}

public struct AgentModelProviderGroup: Hashable, Sendable {
    public let id: String
    public let title: String
    public var models: [AgentSettingsModelManifest]
}

public enum AgentModelCatalogPresentation {
    public static func sorted(
        _ models: [AgentSettingsModelManifest]
    ) -> [AgentSettingsModelManifest] {
        models.sorted { lhs, rhs in
            let titleComparison = lhs.displayTitle.localizedCaseInsensitiveCompare(
                rhs.displayTitle
            )
            if titleComparison != .orderedSame {
                return titleComparison == .orderedAscending
            }

            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }

    public static func groupedByProvider(
        _ models: [AgentSettingsModelManifest]
    ) -> [AgentModelProviderGroup] {
        var groups: [AgentModelProviderGroup] = []
        for model in sorted(models) {
            let groupID = providerGroupID(for: model)
            if let existingIndex = groups.firstIndex(where: { $0.id == groupID }) {
                groups[existingIndex].models.append(model)
            } else {
                groups.append(
                    AgentModelProviderGroup(
                        id: groupID,
                        title: providerGroupTitle(for: model),
                        models: [model]
                    )
                )
            }
        }

        return groups.sorted { lhs, rhs in
            let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleComparison != .orderedSame {
                return titleComparison == .orderedAscending
            }

            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }

    public static func providerGroupTitle(
        for model: AgentSettingsModelManifest
    ) -> String {
        if let provider = model.provider {
            return provider.displayTitle
        }

        return "RemoteAPI"
    }

    public static func modelTitle(
        for model: AgentSettingsModelManifest,
        in group: AgentModelProviderGroup
    ) -> String {
        modelTitle(for: model, providerGroupTitle: group.title)
    }

    public static func modelTitle(
        for model: AgentSettingsModelManifest
    ) -> String {
        modelTitle(
            for: model,
            providerGroupTitle: providerGroupTitle(for: model)
        )
    }

    public static func modelTitle(
        for model: AgentSettingsModelManifest,
        providerGroupTitle: String?
    ) -> String {
        guard model.title == nil,
              let providerTitle = model.provider?.displayTitle.nilIfBlank,
              let providerGroupTitle = providerGroupTitle?.nilIfBlank,
              providerTitle.foldedProviderGroupKey == providerGroupTitle.foldedProviderGroupKey,
              let modelID = model.modelID.nilIfBlank else {
            return model.displayTitle
        }

        return modelID
    }

    private static func providerGroupID(
        for model: AgentSettingsModelManifest
    ) -> String {
        if let providerID = model.provider?.id ?? model.providerID {
            return "remote:\(providerID.uuidString.lowercased())"
        }

        return "remote:\(providerGroupTitle(for: model).foldedProviderGroupKey)"
    }
}

private extension String {
    var foldedProviderGroupKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

public enum AgentSettingsStore {
    public static func resolvedEffectiveModelID(
        explicitModelID: String?,
        agentModelID: String?,
        manifest: AgentSettingsManifest? = AgentSettingsManifestStore.load()
    ) -> String? {
        if let explicitModelID = explicitModelID?.nilIfBlank {
            return explicitModelID
        }

        if let agentModelID = agentModelID?.nilIfBlank,
           manifest?.models.contains(where: { $0.matches(agentModelID) }) == true {
            return agentModelID
        }

        guard let manifest else {
            return nil
        }

        if let selectedModelID = manifest.selectedModelID?.nilIfBlank,
           let model = manifest.models.first(where: { $0.matches(selectedModelID) }) {
            return model.id
        }

        if manifest.models.count == 1 {
            return manifest.models.first?.id
        }

        return nil
    }

    public static func defaultSelection(explicitModelID: String?) -> AgentModelSelection? {
        if let explicitModelID = explicitModelID?.nilIfBlank {
            return modelSelection(forLLMID: explicitModelID)
        }

        guard let manifest = AgentSettingsManifestStore.load() else {
            return nil
        }

        if let selectedModelID = manifest.selectedModelID?.nilIfBlank,
           let model = manifest.models.first(where: { $0.matches(selectedModelID) }) {
            return selection(for: model, thinkingSelection: manifest.selectedThinkingSelection)
        }

        if manifest.models.count == 1,
           let model = manifest.models.first {
            return selection(for: model, thinkingSelection: manifest.selectedThinkingSelection)
        }

        return nil
    }

    public static func availableModels() -> [AgentSettingsModelManifest] {
        AgentSettingsManifestStore.load()?.models ?? []
    }

    public static func selectedModelID() -> String? {
        guard let manifest = AgentSettingsManifestStore.load(),
              let selectedModelID = manifest.selectedModelID?.nilIfBlank,
              let model = manifest.models.first(where: { $0.matches(selectedModelID) }) else {
            return nil
        }
        return model.id
    }

    public static func selectedThinkingSelection() -> AgentThinkingSelection? {
        guard let manifest = AgentSettingsManifestStore.load(),
              let selectedModelID = manifest.selectedModelID?.nilIfBlank,
              let model = manifest.models.first(where: { $0.matches(selectedModelID) }) else {
            return nil
        }
        return model.thinkingSelection(for: manifest.selectedThinkingSelection)
    }

    public static func thinkingSelection(
        requestedSelection: AgentThinkingSelection?,
        explicitModelID: String?,
        agentModelID: String?,
        agentThinkingSelection: AgentThinkingSelection? = nil,
        manifest: AgentSettingsManifest? = AgentSettingsManifestStore.load()
    ) -> AgentThinkingSelection? {
        let preferredSelection = requestedSelection ?? agentThinkingSelection
        if let explicitModelID = explicitModelID?.nilIfBlank {
            guard let model = manifest?.models.first(where: {
                manifestModel($0, matches: explicitModelID)
            }) else {
                return preferredSelection
            }
            return model.thinkingSelection(for: preferredSelection)
        }

        if let agentModelID = agentModelID?.nilIfBlank,
           let model = manifest?.models.first(where: {
               manifestModel($0, matches: agentModelID)
           }) {
            return model.thinkingSelection(for: preferredSelection)
        }

        guard let manifest else {
            return preferredSelection
        }

        if let selectedModelID = manifest.selectedModelID?.nilIfBlank,
           let model = manifest.models.first(where: { $0.matches(selectedModelID) }) {
            return model.thinkingSelection(
                for: preferredSelection ?? manifest.selectedThinkingSelection
            )
        }

        if manifest.models.count == 1,
           let model = manifest.models.first {
            return model.thinkingSelection(
                for: preferredSelection ?? manifest.selectedThinkingSelection
            )
        }

        return preferredSelection
    }

    public static func generationParameterOverrides(
        forModelID modelID: String?
    ) -> AgentGenerationParameterOverrides? {
        if let modelID = modelID?.nilIfBlank {
            return modelSelection(forLLMID: modelID)?
                .generationParameterOverrides?
                .normalized()
                .nilIfEmpty
        }

        return defaultSelection(explicitModelID: nil)?
            .generationParameterOverrides?
            .normalized()
            .nilIfEmpty
    }

    public static func apiKey(providerID: UUID) -> String? {
        guard let manifest = AgentSettingsManifestStore.load() else {
            return nil
        }
        if let apiKey = manifest.remoteAPIKeysByProviderID[
            providerID.uuidString.lowercased()
        ]?.nilIfBlank {
            return apiKey
        }
        return nil
    }

    public static func modelSelection(forLLMID llmID: String) -> AgentModelSelection? {
        let normalizedLLMID = llmID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLLMID.isEmpty else {
            return nil
        }

        if let model = manifestModel(matching: normalizedLLMID) {
            return selection(for: model)
        }

        if isRemoteLLMIDSyntax(normalizedLLMID) {
            return nil
        }

        return nil
    }

    private static func manifestModel(matching llmID: String) -> AgentSettingsModelManifest? {
        guard let manifest = AgentSettingsManifestStore.load() else {
            return nil
        }
        return manifest.models.first { manifestModel($0, matches: llmID) }
    }

    private static func selection(
        for model: AgentSettingsModelManifest,
        thinkingSelection: AgentThinkingSelection? = nil
    ) -> AgentModelSelection? {
        let resolvedThinkingSelection = model.thinkingSelection(for: thinkingSelection)
        switch model.kind {
        case .remoteAPI:
            guard let provider = model.provider,
                  let modelID = model.modelID.nilIfBlank else {
                return nil
            }
            let resolvedProvider = AgentRemoteProvider(
                id: provider.id,
                name: provider.name,
                baseURL: provider.baseURL,
                modelID: modelID,
                chatEndpoint: provider.chatEndpoint
            )
            return AgentModelSelection(
                providerKind: .remoteAPI,
                modelID: modelID,
                remoteProvider: resolvedProvider,
                apiKey: apiKey(providerID: provider.id),
                                configuredContextWindowLimit: resolvedConfiguredContextWindowLimit(
                    for: model,
                    provider: resolvedProvider
                ),
                generationParameterOverrides: model.generationParameterOverrides,
                thinkingSelection: resolvedThinkingSelection
            )
        }
    }

        private static func resolvedConfiguredContextWindowLimit(
        for model: AgentSettingsModelManifest,
        provider: AgentRemoteProvider
    ) -> Int? {
        let configuredLimit = model.configuredContextWindowLimit
        guard provider.isChatGPTSubscriptionProvider,
              configuredLimit == CodexAgentModel.legacyContextWindowTokenLimit else {
            return configuredLimit
        }
        return CodexAgentModel.contextWindowTokenLimit(forLLMID: model.id)
    }

    private static func manifestModel(
        _ model: AgentSettingsModelManifest,
        matches llmID: String
    ) -> Bool {
        let normalizedLLMID = llmID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLLMID.isEmpty else {
            return false
        }
        if model.matches(normalizedLLMID) {
            return true
        }
        return false
    }

    public static func defaultLocalModelID() -> String? {
        nil
    }

    public static func isRemoteLLMIDSyntax(_ llmID: String) -> Bool {
        let trimmed = llmID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("remoteapi:")
            || trimmed.hasPrefix("remoteapimodel:")
    }

}
