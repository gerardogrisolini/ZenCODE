//
//  AgentProviderSettings.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

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

public enum AgentProviderProfileID: String, Codable, Hashable, Sendable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case openRouter = "openrouter"
    case zAI = "zai"
    case googleGemini = "google.gemini"
    case deepSeek = "deepseek"
    case moonshot = "moonshot"
    case nvidia = "nvidia"
    case modal = "modal"
    case custom = "custom"
}

public enum AgentProtocolProfileID: String, Codable, Hashable, Sendable {
    case openAIChatCompletions = "openai.chat-completions"
    case openAIResponses = "openai.responses"
    case openAIChatGPTSubscription = "openai.chatgpt-subscription"
    case anthropicMessages = "anthropic.messages"
    case anthropicClaudeSubscription = "anthropic.claude-subscription"
    case zaiCodingPlan = "zai.coding-plan"

    public var chatEndpoint: AgentRemoteChatEndpoint? {
        switch self {
        case .openAIChatCompletions:
            return .chatCompletions
        case .openAIResponses, .openAIChatGPTSubscription:
            return .responses
        case .anthropicMessages, .anthropicClaudeSubscription:
            return nil
        case .zaiCodingPlan:
            return .chatCompletions
        }
    }
}

public enum AgentProviderAuthPolicy: String, Codable, Hashable, Sendable {
    case noAuthentication = "none"
    case apiKeyOptional = "api_key_optional"
    case apiKeyRequired = "api_key_required"
    case chatGPTSubscription = "chatgpt_subscription"
    case anthropicSubscription = "anthropic_subscription"

    public var requiresAPIKey: Bool { self == .apiKeyRequired }

    /// The credential that may cross a network boundary under this policy.
    /// This leaves the persisted secret untouched; callers use the returned
    /// value only while constructing an outbound request.
    public func effectiveAPIKey(_ apiKey: String?) -> String? {
        guard self != .noAuthentication else { return nil }
        return apiKey?.nilIfBlank
    }
}

public struct AgentRemoteProvider: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case modelID
        case chatEndpoint
        case providerProfileID
        case protocolProfileID
        case authPolicy
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
    public let providerProfileID: AgentProviderProfileID
    public let protocolProfileID: AgentProtocolProfileID
    public let authPolicy: AgentProviderAuthPolicy

    public init(
        id: UUID = UUID(),
        name: String = Self.defaultOpenRouterName,
        baseURL: String = Self.defaultOpenRouterBaseURL,
        modelID: String = Self.defaultOpenRouterModelID,
        chatEndpoint: AgentRemoteChatEndpoint = .chatCompletions,
        providerProfileID: AgentProviderProfileID? = nil,
        protocolProfileID: AgentProtocolProfileID? = nil,
        authPolicy: AgentProviderAuthPolicy? = nil
    ) {
        self.id = id
        self.name = Self.normalizedName(name)
        self.baseURL = Self.normalizedBaseURL(baseURL)
        self.modelID = Self.normalizedModelID(modelID)
        let legacyProfiles = Self.legacyProfiles(id: id, baseURL: baseURL, chatEndpoint: chatEndpoint)
        self.providerProfileID = providerProfileID ?? legacyProfiles.provider
        let resolvedProtocolProfileID = protocolProfileID ?? legacyProfiles.protocolProfile
        self.protocolProfileID = resolvedProtocolProfileID
        self.authPolicy = authPolicy ?? legacyProfiles.auth
        self.chatEndpoint = resolvedProtocolProfileID.chatEndpoint ?? chatEndpoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            baseURL: try container.decode(String.self, forKey: .baseURL),
            modelID: try container.decode(String.self, forKey: .modelID),
            chatEndpoint: try container.decode(AgentRemoteChatEndpoint.self, forKey: .chatEndpoint),
            providerProfileID: try container.decodeIfPresent(AgentProviderProfileID.self, forKey: .providerProfileID),
            protocolProfileID: try container.decodeIfPresent(AgentProtocolProfileID.self, forKey: .protocolProfileID),
            authPolicy: try container.decodeIfPresent(AgentProviderAuthPolicy.self, forKey: .authPolicy)
        )
        guard hasCompatibleProfiles else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolProfileID,
                in: container,
                debugDescription: "The provider, protocol and authentication profiles are incompatible."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(chatEndpoint, forKey: .chatEndpoint)
        try container.encode(providerProfileID, forKey: .providerProfileID)
        try container.encode(protocolProfileID, forKey: .protocolProfileID)
        try container.encode(authPolicy, forKey: .authPolicy)
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
        authPolicy.requiresAPIKey
    }

    public var isChatGPTSubscriptionProvider: Bool {
        protocolProfileID == .openAIChatGPTSubscription
    }

    public var isAnthropicSubscriptionProvider: Bool {
        protocolProfileID == .anthropicClaudeSubscription
    }

    public var hasCompatibleProfiles: Bool {
        switch protocolProfileID {
        case .openAIChatGPTSubscription:
            return providerProfileID == .openAI && authPolicy == .chatGPTSubscription
        case .anthropicClaudeSubscription:
            return providerProfileID == .anthropic && authPolicy == .anthropicSubscription
        case .anthropicMessages:
            return providerProfileID == .anthropic && authPolicy == .apiKeyRequired
        case .zaiCodingPlan:
            return providerProfileID == .zAI && authPolicy == .apiKeyRequired
        case .openAIChatCompletions, .openAIResponses:
            return authPolicy != .chatGPTSubscription && authPolicy != .anthropicSubscription
        }
    }

    public static func legacyProfiles(
        id: UUID,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint
    ) -> (provider: AgentProviderProfileID, protocolProfile: AgentProtocolProfileID, auth: AgentProviderAuthPolicy) {
        if id == chatGPTSubscriptionProviderID || isChatGPTSubscriptionBaseURL(baseURL) {
            return (.openAI, .openAIChatGPTSubscription, .chatGPTSubscription)
        }
        if id == anthropicSubscriptionProviderID || isAnthropicSubscriptionBaseURL(baseURL) {
            return (.anthropic, .anthropicClaudeSubscription, .anthropicSubscription)
        }

        let hostedAPIProvider: AgentProviderProfileID?
        let hostedProtocolProfile: AgentProtocolProfileID?
        if isZAIBaseURL(baseURL) {
            hostedAPIProvider = .zAI
            hostedProtocolProfile = isZAICodingPlanBaseURL(baseURL) ? .zaiCodingPlan : nil
        } else if isGeminiOpenAIBaseURL(baseURL) {
            hostedAPIProvider = .googleGemini
            hostedProtocolProfile = nil
        } else if isDeepSeekBaseURL(baseURL) {
            hostedAPIProvider = .deepSeek
            hostedProtocolProfile = nil
        } else if isMoonshotBaseURL(baseURL) {
            hostedAPIProvider = .moonshot
            hostedProtocolProfile = nil
        } else if isNVIDIABaseURL(baseURL) {
            hostedAPIProvider = .nvidia
            hostedProtocolProfile = nil
        } else if isModalDirectBaseURL(baseURL) {
            hostedAPIProvider = .modal
            hostedProtocolProfile = nil
        } else {
            hostedAPIProvider = nil
            hostedProtocolProfile = nil
        }

        let provider: AgentProviderProfileID
        if let hostedAPIProvider {
            provider = hostedAPIProvider
        } else if isOpenRouterBaseURL(baseURL) {
            provider = .openRouter
        } else if isOpenAIBaseURL(baseURL) {
            provider = .openAI
        } else {
            provider = .custom
        }
        let protocolProfile: AgentProtocolProfileID = hostedProtocolProfile
            ?? (chatEndpoint == .responses ? .openAIResponses : .openAIChatCompletions)
        let requiresKey = hostedAPIProvider != nil
            || isOpenRouterBaseURL(baseURL)
            || isOpenAIBaseURL(baseURL)
            || isNVIDIABaseURL(baseURL)
            || isModalDirectBaseURL(baseURL)
        return (provider, protocolProfile, requiresKey ? .apiKeyRequired : .apiKeyOptional)
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

    public static func isOpenAIBaseURL(_ value: String) -> Bool {
        let normalizedValue = normalizedBaseURL(value)
        if let host = URL(string: normalizedValue)?.host?.lowercased() {
            return host == "api.openai.com" || host.hasSuffix(".openai.com")
        }
        let hostCandidate = normalizedValue
            .lowercased()
            .split(separator: "/", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let hostWithoutPort = hostCandidate
            .split(separator: ":", maxSplits: 1)
            .first
            .map(String.init) ?? hostCandidate
        return hostWithoutPort == "api.openai.com" || hostWithoutPort.hasSuffix(".openai.com")
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

    public static func isZAIBaseURL(_ value: String) -> Bool {
        let normalizedValue = normalizedBaseURL(value)
        if let host = URL(string: normalizedValue)?.host?.lowercased() {
            return host == "api.z.ai" || host.hasSuffix(".api.z.ai")
        }
        return normalizedValue.lowercased().contains("api.z.ai")
    }

    /// The Coding Plan shares the `api.z.ai` host with the standard API, so the
    /// legacy inference needs the `/api/coding` path to tell them apart.
    public static func isZAICodingPlanBaseURL(_ value: String) -> Bool {
        let normalizedValue = normalizedBaseURL(value)
        if let url = URL(string: normalizedValue) {
            return url.path.lowercased().hasPrefix("/api/coding")
        }
        return normalizedValue.lowercased().contains("api.z.ai/api/coding")
    }

    public static func isGeminiOpenAIBaseURL(_ value: String) -> Bool {
        let normalizedValue = normalizedBaseURL(value)
        if let host = URL(string: normalizedValue)?.host?.lowercased() {
            return host == "generativelanguage.googleapis.com"
                || host.hasSuffix(".generativelanguage.googleapis.com")
        }
        return normalizedValue.lowercased().contains("generativelanguage.googleapis.com")
    }

    public static func isDeepSeekBaseURL(_ value: String) -> Bool {
        let normalizedValue = normalizedBaseURL(value)
        if let host = URL(string: normalizedValue)?.host?.lowercased() {
            return host == "api.deepseek.com" || host.hasSuffix(".api.deepseek.com")
        }
        return normalizedValue.lowercased().contains("api.deepseek.com")
    }

    public static func isMoonshotBaseURL(_ value: String) -> Bool {
        let normalizedValue = normalizedBaseURL(value)
        if let host = URL(string: normalizedValue)?.host?.lowercased() {
            return host == "api.moonshot.ai" || host.hasSuffix(".api.moonshot.ai")
                || host == "api.moonshot.cn" || host.hasSuffix(".api.moonshot.cn")
        }
        return normalizedValue.lowercased().contains("api.moonshot.ai")
            || normalizedValue.lowercased().contains("api.moonshot.cn")
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
    public let thinkingOptions: [AgentThinkingSelection]?
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
                $0.matches(explicitModelID)
            }) else {
                return preferredSelection
            }
            return model.thinkingSelection(for: preferredSelection)
        }

        if let agentModelID = agentModelID?.nilIfBlank,
           let model = manifest?.models.first(where: {
               $0.matches(agentModelID)
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

        return nil
    }

    private static func manifestModel(matching llmID: String) -> AgentSettingsModelManifest? {
        guard let manifest = AgentSettingsManifestStore.load() else {
            return nil
        }
        return manifest.models.first { $0.matches(llmID) }
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
                chatEndpoint: provider.chatEndpoint,
                providerProfileID: provider.providerProfileID,
                protocolProfileID: provider.protocolProfileID,
                authPolicy: provider.authPolicy
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
                thinkingOptions: model.thinkingOptions,
                thinkingSelection: resolvedThinkingSelection
            )
        }
    }

        private static func resolvedConfiguredContextWindowLimit(
        for model: AgentSettingsModelManifest,
        provider: AgentRemoteProvider
    ) -> Int? {
        guard provider.isChatGPTSubscriptionProvider else {
            return model.configuredContextWindowLimit
        }
        return CodexAgentModel.contextWindowTokenLimit(forLLMID: model.id)
    }

    public static func isRemoteLLMIDSyntax(_ llmID: String) -> Bool {
        let trimmed = llmID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("remoteapi:")
            || trimmed.hasPrefix("remoteapimodel:")
    }

}
