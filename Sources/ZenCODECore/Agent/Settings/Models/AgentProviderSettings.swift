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
