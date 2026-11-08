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

public enum AgentProviderProfileID: String, CaseIterable, Codable, Hashable, Sendable {
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
    /// The local in-process DS4 runtime. It speaks the OpenAI-compatible Chat
    /// Completions dialect like `custom`, but has its own stable provider key.
    case ds4 = "ds4"
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
        case ds4Runtime
    }

    public static let defaultOpenRouterName = "OpenRouter"
    public static let defaultOpenRouterBaseURL = "https://openrouter.ai/api/v1"
    public static let defaultOpenRouterModelID = "openrouter/auto"
    /// Stable provider key of the ChatGPT subscription. It equals the prefix of
    /// the subscription model ids (`chatgpt:<model>`).
    public static let chatGPTSubscriptionProviderID = "chatgpt"
    public static let chatGPTSubscriptionDisplayTitle = "ChatGPT Subscription"
    public static let anthropicSubscriptionDisplayTitle = "Claude Subscription"
    public static let chatGPTSubscriptionBaseURL = "chatgpt://subscription"
    /// Stable provider key of the Claude subscription. It equals the prefix of
    /// the subscription model ids (`claude:<model>`).
    public static let anthropicSubscriptionProviderID = "claude"
    public static let anthropicSubscriptionBaseURL = "anthropic://subscription"
    /// Stable provider key of the Z.ai Coding Plan, which shares the `zai`
    /// provider profile with the standard Z.ai API.
    public static let zaiCodingPlanProviderID = "zai-coding-plan"
    /// Stable provider key of the local DS4 runtime.
    public static let ds4ProviderID = AgentProviderProfileID.ds4.rawValue

    /// Every stable provider key. A provider is identified by exactly one of
    /// these lowercase keys, so a provider cannot be configured twice.
    public static let knownProviderIDs: Set<String> = Set(
        AgentProviderProfileID.allCases.map(\.rawValue)
    ).union([
        chatGPTSubscriptionProviderID,
        anthropicSubscriptionProviderID,
        zaiCodingPlanProviderID
    ])

    /// The single source of truth of the provider key table: the provider
    /// profile raw value, except the subscriptions (`chatgpt`, `claude`, the
    /// prefixes of their model ids) and the Z.ai Coding Plan
    /// (`zai-coding-plan`), which share a provider profile with an API preset.
    public static func providerKey(
        providerProfileID: AgentProviderProfileID,
        protocolProfileID: AgentProtocolProfileID
    ) -> String {
        switch protocolProfileID {
        case .openAIChatGPTSubscription:
            return chatGPTSubscriptionProviderID
        case .anthropicClaudeSubscription:
            return anthropicSubscriptionProviderID
        case .zaiCodingPlan where providerProfileID == .zAI:
            return zaiCodingPlanProviderID
        default:
            return providerProfileID.rawValue
        }
    }

    /// Normalizes a provider key: trimmed and lowercased. A blank value yields
    /// `nil`, so callers fall back to the derived key.
    public static func normalizedProviderID(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    /// Builds the configured-model identifier of a remote API model:
    /// `<providerKey>:<modelID>`. The model component may itself contain `:`
    /// (for example `deepseek/deepseek-r1:free`), so parsers split on the
    /// first colon only.
    public static func modelManifestID(providerID: String, modelID: String) -> String {
        "\(normalizedProviderID(providerID) ?? providerID):\(modelID)"
    }

    /// Splits `<providerKey>:<modelID>` on the first colon when the prefix is
    /// a known provider key, otherwise returns `nil`.
    public static func providerScopedModelID(
        _ value: String
    ) -> (providerID: String, modelID: String)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: ":") else {
            return nil
        }
        let providerID = trimmed[..<separator].lowercased()
        let modelID = String(trimmed[trimmed.index(after: separator)...])
        guard knownProviderIDs.contains(providerID), !modelID.isEmpty else {
            return nil
        }
        return (providerID, modelID)
    }

    /// Provider keys whose model ids keep a dedicated format and resolution:
    /// the subscriptions (`chatgpt:`, `claude:`) and the local DS4 runtime.
    public static let nonRemoteAPIProviderIDs: Set<String> = [
        chatGPTSubscriptionProviderID,
        anthropicSubscriptionProviderID,
        ds4ProviderID
    ]

    /// Like ``providerScopedModelID(_:)`` but only for remote API provider keys
    /// (every key except ``nonRemoteAPIProviderIDs``): these are the ids that
    /// replaced the pre-v15 `remoteapi:<uuid>:<modelID>` identifiers.
    public static func remoteAPIScopedModelID(
        _ value: String
    ) -> (providerID: String, modelID: String)? {
        guard let scoped = providerScopedModelID(value),
              !nonRemoteAPIProviderIDs.contains(scoped.providerID) else {
            return nil
        }
        return scoped
    }

    /// Stable lowercase provider key (see ``providerKey(providerProfileID:protocolProfileID:)``).
    public let id: String
    public let name: String
    public let baseURL: String
    public let modelID: String
    public let chatEndpoint: AgentRemoteChatEndpoint
    public let providerProfileID: AgentProviderProfileID
    public let protocolProfileID: AgentProtocolProfileID
    public let authPolicy: AgentProviderAuthPolicy
    /// Optional persisted metadata for a local DS4 runtime. The provider's
    /// OpenAI-compatible base URL remains unchanged and is still persisted.
    public let ds4Runtime: AgentDS4RuntimeConfiguration?

    /// Creates a provider. When `id` is nil or blank the provider receives the
    /// stable key derived from its resolved profiles; an id is never generated.
    public init(
        id: String? = nil,
        name: String = Self.defaultOpenRouterName,
        baseURL: String = Self.defaultOpenRouterBaseURL,
        modelID: String = Self.defaultOpenRouterModelID,
        chatEndpoint: AgentRemoteChatEndpoint = .chatCompletions,
        providerProfileID: AgentProviderProfileID? = nil,
        protocolProfileID: AgentProtocolProfileID? = nil,
        authPolicy: AgentProviderAuthPolicy? = nil,
        ds4Runtime: AgentDS4RuntimeConfiguration? = nil
    ) {
        let normalizedID = Self.normalizedProviderID(id)
        self.name = Self.normalizedName(name)
        self.baseURL = Self.normalizedBaseURL(baseURL)
        self.modelID = Self.normalizedModelID(modelID)
        let legacyProfiles = Self.legacyProfiles(id: normalizedID, baseURL: baseURL, chatEndpoint: chatEndpoint)
        // A DS4 runtime (or the `ds4` key) identifies the local DS4 provider,
        // which would otherwise be inferred as a custom OpenAI-compatible one.
        let inferredProviderProfileID: AgentProviderProfileID =
            legacyProfiles.provider == .custom && (ds4Runtime != nil || normalizedID == Self.ds4ProviderID)
                ? .ds4
                : legacyProfiles.provider
        let resolvedProviderProfileID = providerProfileID ?? inferredProviderProfileID
        self.providerProfileID = resolvedProviderProfileID
        let resolvedProtocolProfileID = protocolProfileID ?? legacyProfiles.protocolProfile
        self.protocolProfileID = resolvedProtocolProfileID
        self.authPolicy = authPolicy ?? legacyProfiles.auth
        self.chatEndpoint = resolvedProtocolProfileID.chatEndpoint ?? chatEndpoint
        self.ds4Runtime = ds4Runtime
        self.id = normalizedID ?? Self.providerKey(
            providerProfileID: resolvedProviderProfileID,
            protocolProfileID: resolvedProtocolProfileID
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            baseURL: try container.decode(String.self, forKey: .baseURL),
            modelID: try container.decode(String.self, forKey: .modelID),
            chatEndpoint: try container.decode(AgentRemoteChatEndpoint.self, forKey: .chatEndpoint),
            providerProfileID: try container.decodeIfPresent(AgentProviderProfileID.self, forKey: .providerProfileID),
            protocolProfileID: try container.decodeIfPresent(AgentProtocolProfileID.self, forKey: .protocolProfileID),
            authPolicy: try container.decodeIfPresent(AgentProviderAuthPolicy.self, forKey: .authPolicy),
            ds4Runtime: try container.decodeIfPresent(
                AgentDS4RuntimeConfiguration.self,
                forKey: .ds4Runtime
            )
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
        try container.encodeIfPresent(ds4Runtime, forKey: .ds4Runtime)
    }

    public var runtime: AgentDS4RuntimeConfiguration? {
        ds4Runtime
    }

    /// Rebuilds the provider with a different model while retaining all
    /// protocol, authentication and DS4 metadata.
    public func withModelID(_ modelID: String) -> AgentRemoteProvider {
        AgentRemoteProvider(
            id: id,
            name: name,
            baseURL: baseURL,
            modelID: modelID,
            chatEndpoint: chatEndpoint,
            providerProfileID: providerProfileID,
            protocolProfileID: protocolProfileID,
            authPolicy: authPolicy,
            ds4Runtime: ds4Runtime
        )
    }

    public func withDS4Runtime(
        _ ds4Runtime: AgentDS4RuntimeConfiguration?
    ) -> AgentRemoteProvider {
        AgentRemoteProvider(
            id: id,
            name: name,
            baseURL: baseURL,
            modelID: modelID,
            chatEndpoint: chatEndpoint,
            providerProfileID: providerProfileID,
            protocolProfileID: protocolProfileID,
            authPolicy: authPolicy,
            ds4Runtime: ds4Runtime
        )
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

    /// Infers the profiles of a provider persisted without them: the
    /// subscription keys and base URLs, then the hosted API hosts.
    public static func legacyProfiles(
        id: String?,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint
    ) -> (provider: AgentProviderProfileID, protocolProfile: AgentProtocolProfileID, auth: AgentProviderAuthPolicy) {
        let normalizedID = normalizedProviderID(id)
        if normalizedID == chatGPTSubscriptionProviderID || isChatGPTSubscriptionBaseURL(baseURL) {
            return (.openAI, .openAIChatGPTSubscription, .chatGPTSubscription)
        }
        if normalizedID == anthropicSubscriptionProviderID || isAnthropicSubscriptionBaseURL(baseURL) {
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
    public let ds4Runtime: AgentDS4RuntimeConfiguration?

    public init(
        providerKind: AgentModelProviderKind,
        modelID: String,
        remoteProvider: AgentRemoteProvider?,
        apiKey: String?,
        configuredContextWindowLimit: Int?,
        generationParameterOverrides: AgentGenerationParameterOverrides?,
        thinkingOptions: [AgentThinkingSelection]? = nil,
        thinkingSelection: AgentThinkingSelection?,
        ds4Runtime: AgentDS4RuntimeConfiguration? = nil
    ) {
        self.providerKind = providerKind
        self.modelID = modelID
        self.remoteProvider = remoteProvider
        self.apiKey = apiKey
        self.configuredContextWindowLimit = configuredContextWindowLimit
        self.generationParameterOverrides = generationParameterOverrides
        self.thinkingOptions = thinkingOptions
        self.thinkingSelection = thinkingSelection
        self.ds4Runtime = ds4Runtime ?? remoteProvider?.ds4Runtime
    }

    public var runtime: AgentDS4RuntimeConfiguration? {
        ds4Runtime
    }
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
            return "remote:\(providerID)"
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
