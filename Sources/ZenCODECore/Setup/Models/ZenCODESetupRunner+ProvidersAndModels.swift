//
//  ZenCODESetupRunner+ProvidersAndModels.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import ToolCore

extension ZenCODESetupRunner {
    static func configureProvidersAndModels(
        existingManifest: AgentSettingsManifest?
    ) async throws -> AgentSettingsManifest {
        var providerInputs = try await reconfigureExistingProviders(existingManifest)
        if providerInputs.isEmpty {
            repeat {
                if let input = try await readProvider(
                    configuredProviderIDs: Set(providerInputs.map(\.id))
                ) {
                    providerInputs.append(input)
                }
            } while try promptYesNo("Add another provider?", defaultValue: false)
        }


        let providers = providerInputs.map { input in
            AgentSettingsProviderManifest(
                id: input.id,
                name: input.name,
                baseURL: input.baseURL,
                chatEndpoint: input.chatEndpoint,
                providerProfileID: input.providerProfileID,
                protocolProfileID: input.protocolProfileID,
                authPolicy: input.authPolicy,
                ds4Runtime: input.ds4Runtime
            )
        }
        let models = providerInputs.flatMap(\.models)
        guard !models.isEmpty else {
            throw ZenCODESetupError.noModelsConfigured
        }

        let selectedModelID = preservedOrFirstSelectedModelID(
            from: models,
            existingSelectedModelID: existingManifest?.selectedModelID
        )
        let selectedThinkingSelection = setupDefaultThinkingSelection(
            for: models.first { $0.matches(selectedModelID) },
            existingSelection: existingManifest?.selectedThinkingSelection
        )
        let apiKeysByProviderID: [String: String] = Dictionary(
            providerInputs.compactMap { input -> (String, String)? in
                guard let apiKey = input.apiKey else {
                    return nil
                }
                return (input.id, apiKey)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let latestCredentials = latestSubscriptionCredentials(fallback: existingManifest)
        let subscriptionCredentials = subscriptionCredentials(
            from: providerInputs,
            fallback: latestCredentials
        )

        return AgentSettingsManifest(
            version: existingManifest?.version ?? AgentSettingsManifest.currentVersion,
            providers: providers,
            models: models,
            selectedModelID: selectedModelID,
            selectedThinkingSelection: selectedThinkingSelection,
            telegram: existingManifest?.telegram,
            voice: existingManifest?.voice,
            remoteAPIKeysByProviderID: apiKeysByProviderID,
            localExecAllowedCommands: existingManifest?.localExecAllowedCommands ?? [],
            chatGPTSubscriptionCredentials: subscriptionCredentials.chatGPT,
            anthropicSubscriptionCredentials: subscriptionCredentials.anthropic,
            responseLanguage: existingManifest?.responseLanguage,
            memoryEmbedding: existingManifest?.memoryEmbedding
        )
    }

    static func latestSubscriptionCredentials(
        fallback manifest: AgentSettingsManifest?
    ) -> (
        chatGPT: CodexAgentCredentials?,
        anthropic: AnthropicSubscriptionCredentials?
    ) {
        let latestManifest = AgentSettingsManifestStore.load()
        return (
            manifest?.chatGPTSubscriptionCredentials ?? latestManifest?.chatGPTSubscriptionCredentials,
            manifest?.anthropicSubscriptionCredentials ?? latestManifest?.anthropicSubscriptionCredentials
        )
    }

    static func subscriptionCredentials(
        from providerInputs: [SetupProviderInput],
        fallback: (
            chatGPT: CodexAgentCredentials?,
            anthropic: AnthropicSubscriptionCredentials?
        )
    ) -> (
        chatGPT: CodexAgentCredentials?,
        anthropic: AnthropicSubscriptionCredentials?
    ) {
        (
            chatGPT: providerInputs.compactMap(\.chatGPTSubscriptionCredentials).first
                ?? fallback.chatGPT,
            anthropic: providerInputs.compactMap(\.anthropicSubscriptionCredentials).first
                ?? fallback.anthropic
        )
    }

    static func preservedOrFirstSelectedModelID(
        from models: [AgentSettingsModelManifest],
        existingSelectedModelID: String?
    ) -> String {
        if let existingSelectedModelID,
           let model = models.first(where: { $0.matches(existingSelectedModelID) }) {
            return model.id
        }
        return models[0].id
    }

    static func reconfigureExistingProviders(
        _ manifest: AgentSettingsManifest?
    ) async throws -> [SetupProviderInput] {
        guard let manifest,
              !manifest.providers.isEmpty else {
            return []
        }

        printProviders(
            title: "Configured providers",
            providers: manifest.providers,
            allModels: manifest.models
        )

        var providerInputs = manifest.providers.map { provider in
            preserveProviderInput(
                provider: provider,
                models: models(for: provider, in: manifest.models),
                apiKey: manifest.apiKey(providerID: provider.id),
                chatGPTSubscriptionCredentials: isChatGPTSubscriptionProvider(provider)
                    ? manifest.chatGPTSubscriptionCredentials
                    : nil,
                anthropicSubscriptionCredentials: isAnthropicSubscriptionProvider(provider)
                    ? manifest.anthropicSubscriptionCredentials
                    : nil
            )
        }

        while try promptYesNo("Add another provider?", defaultValue: false) {
            if let input = try await readProvider(
                configuredProviderIDs: Set(providerInputs.map(\.id))
            ) {
                providerInputs.append(input)
            }
        }

        let selectedProviderIndexes = try promptProviderInputIndexes(
            title: "Reconfigure providers",
            providers: providerInputs
        )
        for index in selectedProviderIndexes.sorted() where providerInputs.indices.contains(index) {
            let providerInput = providerInputs[index]
            let provider = providerManifest(from: providerInput)
            if provider.ds4Runtime != nil {
                // DS4 is never running during setup: models come from the
                // GGUF files in the DS4 folder, never from `/models`.
                let reservedModelIDs = Set(
                    providerInputs.enumerated()
                        .filter { $0.offset != index }
                        .flatMap { $0.element.models.map(\.id) }
                )
                providerInputs[index] = await reconfigureDS4ProviderInput(
                    providerInput,
                    reservedModelIDs: reservedModelIDs
                )
            } else if isChatGPTSubscriptionProvider(provider) {
                providerInputs[index] = try await readChatGPTSubscriptionProvider(
                    existingModels: providerInput.models
                )
            } else if isAnthropicSubscriptionProvider(provider) {
                providerInputs[index] = try await readAnthropicSubscriptionProvider(
                    existingModels: providerInput.models
                )
            } else {
                providerInputs[index] = try await readRemoteAPIProvider(
                    existingProvider: provider,
                    existingModels: providerInput.models,
                    existingAPIKey: providerInput.apiKey
                )
            }
        }

        let deletedProviderIndexes = try promptProviderInputIndexes(
            title: "Delete configured providers",
            providers: providerInputs
        )
        if !deletedProviderIndexes.isEmpty {
            providerInputs = providerInputs.enumerated()
                .filter { !deletedProviderIndexes.contains($0.offset) }
                .map(\.element)
        }

        return providerInputs
    }


    static func printProviders(
        title: String,
        providers: [AgentSettingsProviderManifest],
        allModels: [AgentSettingsModelManifest]
    ) {
        AgentOutput.standardError.writeString("\(title):\n")
        for (index, provider) in providers.enumerated() {
            let providerModels = models(for: provider, in: allModels)
            AgentOutput.standardError.writeString(
                "  \(index + 1). \(provider.displayTitle) (\(providerModels.count) models)\n"
            )
        }
        AgentOutput.standardError.writeString("\n")
    }

    static func promptProviderInputIndexes(
        title: String,
        providers: [SetupProviderInput]
    ) throws -> Set<Int> {
        let items = providers.enumerated().map { index, provider in
            TerminalCheckboxMenuItem(
                value: index,
                title: provider.name,
                detail: "\(provider.models.count) models"
            )
        }
        return try promptSelectionIndexes(title: title, items: items)
    }


    /// Presents an interactive multi-select menu, with nothing checked, and
    /// returns the chosen item indexes. Enter with nothing checked means
    /// "nothing selected"; Esc throws `ZenCODESetupError.cancelled`, so the
    /// step that asked is cancelled instead of going on as if nothing had
    /// been chosen.
    static func promptSelectionIndexes(
        title: String,
        items: [TerminalCheckboxMenuItem<Int>],
        select: (String, [TerminalCheckboxMenuItem<Int>], Set<Int>) -> Set<Int>? = {
            TerminalCheckboxMenu.select(title: $0, items: $1, selected: $2)
        }
    ) throws -> Set<Int> {
        guard !items.isEmpty else {
            return []
        }
        return try promptMenuSelection(
            title: title,
            items: items,
            selected: [],
            select: select
        )
    }

    static func models(
        for provider: AgentSettingsProviderManifest,
        in models: [AgentSettingsModelManifest]
    ) -> [AgentSettingsModelManifest] {
        models.filter { model in
            (model.providerID ?? model.provider?.id) == provider.id
        }
    }

    static func preserveProviderInput(
        provider: AgentSettingsProviderManifest,
        models: [AgentSettingsModelManifest],
        apiKey: String?,
        chatGPTSubscriptionCredentials: CodexAgentCredentials? = nil,
        anthropicSubscriptionCredentials: AnthropicSubscriptionCredentials? = nil
    ) -> SetupProviderInput {
        SetupProviderInput(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            chatEndpoint: provider.chatEndpoint,
            providerProfileID: provider.providerProfileID,
            protocolProfileID: provider.protocolProfileID,
            authPolicy: provider.authPolicy,
            ds4Runtime: provider.ds4Runtime,
            apiKey: apiKey,
            models: models,
            chatGPTSubscriptionCredentials: chatGPTSubscriptionCredentials,
            anthropicSubscriptionCredentials: anthropicSubscriptionCredentials
        )
    }

    static func providerManifest(from input: SetupProviderInput) -> AgentSettingsProviderManifest {
        AgentSettingsProviderManifest(
            id: input.id,
            name: input.name,
            baseURL: input.baseURL,
            chatEndpoint: input.chatEndpoint,
            providerProfileID: input.providerProfileID,
            protocolProfileID: input.protocolProfileID,
            authPolicy: input.authPolicy,
            ds4Runtime: input.ds4Runtime
        )
    }
}
