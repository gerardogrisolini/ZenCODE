//
//  ZenCODESetupRunner+ProvidersAndModels.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//
import Foundation
import ZenCODECore

extension ZenCODESetupRunner {
    static func configureProvidersAndModels(
        existingManifest: AgentSettingsManifest?
    ) async throws -> AgentSettingsManifest {
        var providerInputs = try await reconfigureExistingProviders(existingManifest)
        if providerInputs.isEmpty {
            repeat {
                providerInputs.append(try await readProvider())
            } while try promptYesNo("Add another provider?", defaultValue: false)
        }


        let providers = providerInputs.map { input in
            AgentSettingsProviderManifest(
                id: input.id,
                name: input.name,
                baseURL: input.baseURL,
                chatEndpoint: input.chatEndpoint
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
            uniqueKeysWithValues: providerInputs.compactMap { input -> (String, String)? in
                guard let apiKey = input.apiKey else {
                    return nil
                }
                return (input.id.uuidString.lowercased(), apiKey)
            }
        )
        let subscriptionCredentials = latestSubscriptionCredentials(fallback: existingManifest)

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
            anthropicSubscriptionCredentials: subscriptionCredentials.anthropic
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
            latestManifest?.chatGPTSubscriptionCredentials ?? manifest?.chatGPTSubscriptionCredentials,
            latestManifest?.anthropicSubscriptionCredentials ?? manifest?.anthropicSubscriptionCredentials
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
                apiKey: manifest.remoteAPIKeysByProviderID[
                    provider.id.uuidString.lowercased()
                ]
            )
        }

        while try promptYesNo("Add another provider?", defaultValue: false) {
            providerInputs.append(try await readProvider())
        }

        let selectedProviderIndexes = promptProviderInputIndexes(
            title: "Reconfigure providers",
            providers: providerInputs
        )
        for index in selectedProviderIndexes.sorted() where providerInputs.indices.contains(index) {
            let providerInput = providerInputs[index]
            let provider = providerManifest(from: providerInput)
            if isChatGPTSubscriptionProvider(provider) {
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

        let deletedProviderIndexes = promptProviderInputIndexes(
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
    ) -> Set<Int> {
        let items = providers.enumerated().map { index, provider in
            TerminalCheckboxMenuItem(
                value: index,
                title: provider.name,
                detail: "\(provider.models.count) models"
            )
        }
        return promptSelectionIndexes(title: title, items: items)
    }


    /// Presents an interactive multi-select menu and returns the chosen item
    /// indexes. An empty selection (or cancel) means "nothing selected".
    static func promptSelectionIndexes(
        title: String,
        items: [TerminalCheckboxMenuItem<Int>]
    ) -> Set<Int> {
        guard !items.isEmpty else {
            return []
        }
        return TerminalCheckboxMenu.select(
            title: title,
            items: items,
            selected: []
        ) ?? []
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
        apiKey: String?
    ) -> SetupProviderInput {
        SetupProviderInput(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            chatEndpoint: provider.chatEndpoint,
            apiKey: apiKey,
            models: models
        )
    }

    static func providerManifest(from input: SetupProviderInput) -> AgentSettingsProviderManifest {
        AgentSettingsProviderManifest(
            id: input.id,
            name: input.name,
            baseURL: input.baseURL,
            chatEndpoint: input.chatEndpoint
        )
    }


    static func readProvider() async throws -> SetupProviderInput {
        switch try promptProviderKind() {
        case .remoteAPI:
            return try await readRemoteAPIProvider()
        case .chatGPTSubscription:
            return try await readChatGPTSubscriptionProvider()
        case .anthropicSubscription:
            return try await readAnthropicSubscriptionProvider()
        }
    }

    static func readRemoteAPIProvider(
        existingProvider: AgentSettingsProviderManifest? = nil,
        existingModels: [AgentSettingsModelManifest] = [],
        existingAPIKey: String? = nil
    ) async throws -> SetupProviderInput {
        AgentOutput.standardError.writeString("\nProvider OpenAI-compatible\n")
        let id = existingProvider?.id ?? UUID()
        let name = try promptString(
            "Provider name",
            defaultValue: existingProvider?.name ?? AgentRemoteProvider.defaultOpenRouterName,
            allowEmpty: false
        )
        let baseURL = try promptString(
            "Base URL",
            defaultValue: existingProvider?.baseURL ?? AgentRemoteProvider.defaultOpenRouterBaseURL,
            allowEmpty: false,
            help: "The root API URL for your provider. Examples: https://openrouter.ai/api/v1 or http://127.0.0.1:8080/v1 for a local server."
        )
        let chatEndpoint = try promptEndpoint(
            defaultValue: existingProvider?.chatEndpoint ?? .chatCompletions
        )
        let apiKey = try promptAPIKey(existingAPIKey: existingAPIKey, providerName: name)

        let models: [AgentSettingsModelManifest]
        if existingModels.isEmpty {
            models = try await readModels(
                providerID: id,
                providerName: name,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint,
                apiKey: apiKey.nilIfBlank
            )
        } else {
            models = try await reconfigureModels(
                providerID: id,
                providerName: name,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint,
                apiKey: apiKey.nilIfBlank,
                existingModels: existingModels
            )
        }

        guard !models.isEmpty else {
            throw ZenCODESetupError.noModelsConfigured
        }

        return SetupProviderInput(
            id: id,
            name: name,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            apiKey: apiKey.nilIfBlank,
            models: models
        )
    }

    static func readChatGPTSubscriptionProvider(
        existingModels: [AgentSettingsModelManifest] = []
    ) async throws -> SetupProviderInput {
        AgentOutput.standardError.writeString("\nChatGPT Subscription\n")
        try await ensureChatGPTSubscriptionCredentials()

        let id = AgentRemoteProvider.chatGPTSubscriptionProviderID
        let name = CodexAgentModel.displayTitle
        let baseURL = AgentRemoteProvider.chatGPTSubscriptionBaseURL
        let chatEndpoint = AgentRemoteChatEndpoint.responses
        let models = try selectChatGPTSubscriptionModels(
            defaultModels: existingModels
        ).map { option in
            chatGPTSubscriptionModelManifest(
                option: option,
                providerID: id,
                providerName: name,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint
            )
        }

        guard !models.isEmpty else {
            throw ZenCODESetupError.noModelsConfigured
        }

        return SetupProviderInput(
            id: id,
            name: name,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            apiKey: nil,
            models: models
        )
    }

    static func readAnthropicSubscriptionProvider(
        existingModels: [AgentSettingsModelManifest] = []
    ) async throws -> SetupProviderInput {
        AgentOutput.standardError.writeString("\nClaude Subscription\n")
        try await ensureAnthropicSubscriptionCredentials()

        let id = AgentRemoteProvider.anthropicSubscriptionProviderID
        let name = AnthropicSubscriptionModel.displayTitle
        let baseURL = AgentRemoteProvider.anthropicSubscriptionBaseURL
        let chatEndpoint = AgentRemoteChatEndpoint.responses
        let models = try selectAnthropicSubscriptionModels(
            defaultModels: existingModels
        ).map { option in
            anthropicSubscriptionModelManifest(
                option: option,
                providerID: id,
                providerName: name,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint
            )
        }

        guard !models.isEmpty else {
            throw ZenCODESetupError.noModelsConfigured
        }

        return SetupProviderInput(
            id: id,
            name: name,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            apiKey: nil,
            models: models
        )
    }

    static func promptAPIKey(
        existingAPIKey: String?,
        providerName: String
    ) throws -> String {
        guard existingAPIKey?.nilIfBlank != nil else {
            return try promptString(
                "API key (optional)",
                defaultValue: nil,
                allowEmpty: true,
                help: "Leave empty only for local providers or servers that do not require authentication. Hosted providers usually require an API key."
            )
        }

        guard try promptYesNo(
            "Replace stored API key for \(providerName)?",
            defaultValue: false
        ) else {
            return existingAPIKey ?? ""
        }

        return try promptString(
            "New API key (empty clears it)",
            defaultValue: nil,
            allowEmpty: true
        )
    }

}
