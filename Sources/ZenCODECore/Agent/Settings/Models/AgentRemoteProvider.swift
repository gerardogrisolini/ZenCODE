//
//  AgentRemoteProvider.swift
//  ZenCODE
//
//  A configured remote model provider: its persisted fields, the well-known
//  provider identifiers, model ID scoping, and base URL classification.
//

import Foundation
import ToolCore

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
    /// Stable provider key of Kimi Code, which shares the `moonshot` provider
    /// profile with the standard Kimi API.
    public static let kimiCodeProviderID = "kimi-code"
    /// Stable provider key of the Qwen Token Plan, which shares the `qwen`
    /// provider profile with the standard Qwen API.
    public static let qwenTokenPlanProviderID = "qwen-token-plan"
    /// Stable provider key of the local DS4 runtime.
    public static let ds4ProviderID = AgentProviderProfileID.ds4.rawValue

    /// Every stable provider key. A provider is identified by exactly one of
    /// these lowercase keys, so a provider cannot be configured twice.
    public static let knownProviderIDs: Set<String> = Set(
        AgentProviderProfileID.allCases.map(\.rawValue)
    ).union([
        chatGPTSubscriptionProviderID,
        anthropicSubscriptionProviderID,
        zaiCodingPlanProviderID,
        kimiCodeProviderID,
        qwenTokenPlanProviderID
    ])

    /// The single source of truth of the provider key table: the provider
    /// profile raw value, except the subscriptions (`chatgpt`, `claude`, the
    /// prefixes of their model ids) and the plans that share a provider profile
    /// with an API preset: the Z.ai Coding Plan (`zai-coding-plan`), Kimi Code
    /// (`kimi-code`) and the Qwen Token Plan (`qwen-token-plan`).
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
        case .kimiCode where providerProfileID == .moonshot:
            return kimiCodeProviderID
        case .qwenTokenPlan where providerProfileID == .qwen:
            return qwenTokenPlanProviderID
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
        case .kimiCode:
            return providerProfileID == .moonshot && authPolicy == .apiKeyRequired
        case .qwenTokenPlan:
            return providerProfileID == .qwen && authPolicy == .apiKeyRequired
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
