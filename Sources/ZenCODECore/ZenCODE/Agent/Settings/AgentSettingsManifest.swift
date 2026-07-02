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

public struct AgentSettingsManifest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case version
        case providers
        case models
        case selected
        case telegram
        case voice
        case remoteAPIKeysByProviderID
        case localExecAllowedCommands
        case chatGPTSubscriptionCredentials
        case anthropicSubscriptionCredentials
    }

    public static let currentVersion = 10
    public static let minimumSupportedVersion = 4

    public let version: Int
    public let providers: [AgentSettingsProviderManifest]
    public let models: [AgentSettingsModelManifest]
    public let selectedModelID: String?
    public let selectedThinkingSelection: AgentThinkingSelection?
    public let telegram: AgentTelegramSettingsManifest?
    public let voice: AgentVoiceSettingsManifest?
    public let remoteAPIKeysByProviderID: [String: String]
    public let localExecAllowedCommands: [String]
    public let chatGPTSubscriptionCredentials: CodexAgentCredentials?
    public let anthropicSubscriptionCredentials: AnthropicSubscriptionCredentials?

    public init(
        version: Int = Self.currentVersion,
        providers: [AgentSettingsProviderManifest] = [],
        models: [AgentSettingsModelManifest],
        selectedModelID: String? = nil,
        selectedThinkingSelection: AgentThinkingSelection? = nil,
        telegram: AgentTelegramSettingsManifest? = nil,
        voice: AgentVoiceSettingsManifest? = nil,
        remoteAPIKeysByProviderID: [String: String] = [:],
        localExecAllowedCommands: [String] = [],
        chatGPTSubscriptionCredentials: CodexAgentCredentials? = nil,
        anthropicSubscriptionCredentials: AnthropicSubscriptionCredentials? = nil
    ) {
        let normalizedProviders = Self.normalizedProviders(
            providers,
            models: models
        )
        let providersByID = Dictionary(uniqueKeysWithValues: normalizedProviders.map { ($0.id, $0) })
        let normalizedModels = Self.normalizedModels(models, providersByID: providersByID)

        self.version = version
        self.providers = normalizedProviders
        self.models = normalizedModels
        self.selectedModelID = Self.normalizedSelectedModelID(
            selectedModelID,
            models: normalizedModels
        )
        self.selectedThinkingSelection = Self.normalizedSelectedThinkingSelection(
            selectedThinkingSelection,
            selectedModelID: self.selectedModelID,
            models: normalizedModels
        )
        self.telegram = telegram?.isConfigured == true ? telegram : nil
        self.voice = voice?.isConfigured == true ? voice : nil
        self.remoteAPIKeysByProviderID = Self.normalizedRemoteAPIKeys(
            remoteAPIKeysByProviderID,
            models: normalizedModels
        )
        self.localExecAllowedCommands = Self.normalizedLocalExecAllowedCommands(
            localExecAllowedCommands
        )
        self.chatGPTSubscriptionCredentials = chatGPTSubscriptionCredentials
        self.anthropicSubscriptionCredentials = anthropicSubscriptionCredentials
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        let selected = try container.decodeIfPresent(
            AgentSettingsSelectionManifest.self,
            forKey: .selected
        )
        let models = try container.decode([AgentSettingsModelManifest].self, forKey: .models)
        self.init(
            version: version,
            providers: try container.decodeIfPresent(
                [AgentSettingsProviderManifest].self,
                forKey: .providers
            ) ?? [],
            models: models,
            selectedModelID: selected?.modelID,
            selectedThinkingSelection: selected?.thinking,
            telegram: try container.decodeIfPresent(
                AgentTelegramSettingsManifest.self,
                forKey: .telegram
            ),
            voice: try container.decodeIfPresent(
                AgentVoiceSettingsManifest.self,
                forKey: .voice
            ),
            remoteAPIKeysByProviderID: try container.decodeIfPresent(
                [String: String].self,
                forKey: .remoteAPIKeysByProviderID
            ) ?? [:],
            localExecAllowedCommands: try container.decodeIfPresent(
                [String].self,
                forKey: .localExecAllowedCommands
            ) ?? [],
            chatGPTSubscriptionCredentials: try container.decodeIfPresent(
                CodexAgentCredentials.self,
                forKey: .chatGPTSubscriptionCredentials
            ),
            anthropicSubscriptionCredentials: try container.decodeIfPresent(
                AnthropicSubscriptionCredentials.self,
                forKey: .anthropicSubscriptionCredentials
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        if !providers.isEmpty {
            try container.encode(providers, forKey: .providers)
        }
        try container.encode(models, forKey: .models)
        let selection = AgentSettingsSelectionManifest(
            modelID: selectedModelID,
            thinking: selectedThinkingSelection
        )
        if !selection.isEmpty {
            try container.encode(selection, forKey: .selected)
        }
        if let telegram, telegram.isConfigured {
            try container.encode(telegram, forKey: .telegram)
        }
        if let voice, voice.isConfigured {
            try container.encode(voice, forKey: .voice)
        }
        if !remoteAPIKeysByProviderID.isEmpty {
            try container.encode(remoteAPIKeysByProviderID, forKey: .remoteAPIKeysByProviderID)
        }
        if let chatGPTSubscriptionCredentials {
            try container.encode(chatGPTSubscriptionCredentials, forKey: .chatGPTSubscriptionCredentials)
        }
        if let anthropicSubscriptionCredentials {
            try container.encode(anthropicSubscriptionCredentials, forKey: .anthropicSubscriptionCredentials)
        }
    }

    public var isEmpty: Bool {
        providers.isEmpty
            && models.isEmpty
            && selectedModelID == nil
            && selectedThinkingSelection == nil
            && telegram == nil
            && voice == nil
            && remoteAPIKeysByProviderID.isEmpty
            && localExecAllowedCommands.isEmpty
            && chatGPTSubscriptionCredentials == nil
            && anthropicSubscriptionCredentials == nil
    }

    private static func normalizedLocalExecAllowedCommands(_ commands: [String]) -> [String] {
        var seen = Set<String>()
        return commands.compactMap { command in
            let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                return nil
            }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else {
                return nil
            }
            return normalized
        }
    }

    private static func normalizedModels(
        _ models: [AgentSettingsModelManifest],
        providersByID: [UUID: AgentSettingsProviderManifest]
    ) -> [AgentSettingsModelManifest] {
        var seen = Set<String>()
        return models.compactMap { model in
            guard let normalizedModel = model.normalized(providersByID: providersByID),
                  seen.insert(normalizedModel.id.lowercased()).inserted else {
                return nil
            }
            return normalizedModel
        }
    }

    private static func normalizedProviders(
        _ providers: [AgentSettingsProviderManifest],
        models: [AgentSettingsModelManifest]
    ) -> [AgentSettingsProviderManifest] {
        var providersByID: [UUID: AgentSettingsProviderManifest] = [:]
        for model in models {
            if let provider = model.provider {
                providersByID[provider.id] = AgentSettingsProviderManifest(provider: provider)
            }
        }
        for provider in providers {
            providersByID[provider.id] = provider
        }
        return providersByID.values.sorted {
            let comparison = $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle)
            if comparison == .orderedSame {
                return $0.id.uuidString < $1.id.uuidString
            }
            return comparison == .orderedAscending
        }
    }

    private static func normalizedSelectedModelID(
        _ selectedModelID: String?,
        models: [AgentSettingsModelManifest]
    ) -> String? {
        guard let selectedModelID = selectedModelID?.nilIfBlank else {
            return nil
        }
        return models.first { $0.matches(selectedModelID) }?.id
    }

    private static func normalizedSelectedThinkingSelection(
        _ selectedThinkingSelection: AgentThinkingSelection?,
        selectedModelID: String?,
        models: [AgentSettingsModelManifest]
    ) -> AgentThinkingSelection? {
        guard let selectedModelID,
              let model = models.first(where: { $0.matches(selectedModelID) }) else {
            return nil
        }
        return model.thinkingSelection(for: selectedThinkingSelection)
    }

    private static func normalizedRemoteAPIKeys(
        _ values: [String: String],
        models: [AgentSettingsModelManifest]
    ) -> [String: String] {
        var normalized: [String: String] = [:]
        for model in models {
            guard let providerID = model.provider?.id ?? model.providerID,
                  let apiKey = model.apiKey?.nilIfBlank else {
                continue
            }
            normalized[providerID.uuidString.lowercased()] = apiKey
        }
        for (providerID, apiKey) in values {
            guard let providerUUID = UUID(uuidString: providerID),
                  let normalizedAPIKey = apiKey.nilIfBlank else {
                continue
            }
            normalized[providerUUID.uuidString.lowercased()] = normalizedAPIKey
        }
        return normalized
    }
}

