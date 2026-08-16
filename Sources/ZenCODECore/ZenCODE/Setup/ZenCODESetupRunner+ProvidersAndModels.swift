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
                providerInputs.append(try await readProvider())
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
                authPolicy: input.authPolicy
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
                apiKey: manifest.remoteAPIKeysByProviderID[
                    provider.id.uuidString.lowercased()
                ],
                chatGPTSubscriptionCredentials: isChatGPTSubscriptionProvider(provider)
                    ? manifest.chatGPTSubscriptionCredentials
                    : nil,
                anthropicSubscriptionCredentials: isAnthropicSubscriptionProvider(provider)
                    ? manifest.anthropicSubscriptionCredentials
                    : nil
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
            authPolicy: input.authPolicy
        )
    }


    static func readProvider() async throws -> SetupProviderInput {
        switch try promptProviderKind() {
        case let .remoteAPI(preset):
            return try await readRemoteAPIProvider(preset: preset)
        case .chatGPTSubscription:
            return try await readChatGPTSubscriptionProvider()
        case .anthropicSubscription:
            return try await readAnthropicSubscriptionProvider()
        }
    }

    static func readRemoteAPIProvider(
        preset: SetupProviderPreset = .custom,
        existingProvider: AgentSettingsProviderManifest? = nil,
        existingModels: [AgentSettingsModelManifest] = [],
        existingAPIKey: String? = nil
    ) async throws -> SetupProviderInput {
        AgentOutput.standardError.writeString("\n\(preset.title)\(preset.isAdvanced ? " (advanced)" : "")\n")
        let id = existingProvider?.id ?? UUID()
        let name: String
        let baseURL: String
        let chatEndpoint: AgentRemoteChatEndpoint
        let providerProfileID: AgentProviderProfileID
        let protocolProfileID: AgentProtocolProfileID
        let authPolicy: AgentProviderAuthPolicy
        if preset.isAdvanced || existingProvider != nil {
            name = try promptString(
                "Provider name",
                defaultValue: existingProvider?.name ?? preset.title,
                allowEmpty: false
            )
            baseURL = try promptString(
                "Base URL",
                defaultValue: existingProvider?.baseURL ?? preset.baseURL,
                allowEmpty: false,
                help: "Advanced: enter an absolute OpenAI-compatible API root. Unknown servers fail closed unless their protocol and authentication policy are configured here."
            )
            chatEndpoint = try promptEndpoint(
                defaultValue: existingProvider?.chatEndpoint ?? preset.protocolProfileID.chatEndpoint ?? .chatCompletions
            )
            providerProfileID = existingProvider?.providerProfileID ?? preset.providerProfileID
            protocolProfileID = reconciledProtocolProfileID(
                selectedEndpoint: chatEndpoint,
                preferred: existingProvider?.protocolProfileID ?? preset.protocolProfileID,
                previousEndpoint: existingProvider?.chatEndpoint
            )
            authPolicy = existingProvider?.authPolicy ?? preset.authPolicy
        } else {
            name = preset.title
            baseURL = preset.baseURL
            chatEndpoint = preset.protocolProfileID.chatEndpoint ?? .chatCompletions
            providerProfileID = preset.providerProfileID
            protocolProfileID = preset.protocolProfileID
            authPolicy = preset.authPolicy
        }
        let apiKey = try promptAPIKey(
            existingAPIKey: existingAPIKey,
            providerName: name,
            required: authPolicy.requiresAPIKey
        )

        // Suppress a residual persisted key for every setup-time catalog call,
        // while preserving that key in the provider input below.
        let effectiveAPIKey = authPolicy.effectiveAPIKey(apiKey)
        let models: [AgentSettingsModelManifest]
        if existingModels.isEmpty {
            models = try await readModels(
                providerID: id,
                providerName: name,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint,
                apiKey: effectiveAPIKey
            )
        } else {
            models = try await reconfigureModels(
                providerID: id,
                providerName: name,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint,
                apiKey: effectiveAPIKey,
                existingModels: existingModels
            )
        }

        guard !models.isEmpty else {
            throw ZenCODESetupError.noModelsConfigured
        }

        let profiledModels = models.map {
            modelWithProvider(
                $0,
                providerID: id,
                providerName: name,
                baseURL: baseURL,
                chatEndpoint: chatEndpoint,
                providerProfileID: providerProfileID,
                protocolProfileID: protocolProfileID,
                authPolicy: authPolicy
            )
        }
        return SetupProviderInput(
            id: id,
            name: name,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            providerProfileID: providerProfileID,
            protocolProfileID: protocolProfileID,
            authPolicy: authPolicy,
            apiKey: apiKey.nilIfBlank,
            models: profiledModels
        )
    }

    static func readChatGPTSubscriptionProvider(
        existingModels: [AgentSettingsModelManifest] = []
    ) async throws -> SetupProviderInput {
        AgentOutput.standardError.writeString("\nChatGPT Subscription\n")
        let credentials = try await ensureChatGPTSubscriptionCredentials()

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
            models: models,
            chatGPTSubscriptionCredentials: credentials
        )
    }

    static func readAnthropicSubscriptionProvider(
        existingModels: [AgentSettingsModelManifest] = []
    ) async throws -> SetupProviderInput {
        AgentOutput.standardError.writeString("\nClaude Subscription\n")
        let credentials = try await ensureAnthropicSubscriptionCredentials()

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
            models: models,
            anthropicSubscriptionCredentials: credentials
        )
    }

    /// Reconciles the persisted (or preset) protocol profile with the chat
    /// endpoint the operator just chose. Profiles whose native endpoint
    /// disagrees with the selection are remapped to the OpenAI-protocol
    /// profile for that endpoint, because `AgentRemoteProvider` lets the
    /// protocol profile override the persisted `chatEndpoint` at load time:
    /// keeping a stale profile would silently undo the operator's choice.
    /// Endpoint-less profiles (e.g. `anthropic.messages`) are remapped as
    /// well, so a reconfigured provider always dispatches on the endpoint it
    /// was actually reconfigured with.
    static func reconciledProtocolProfileID(
        selectedEndpoint: AgentRemoteChatEndpoint,
        preferred: AgentProtocolProfileID,
        previousEndpoint: AgentRemoteChatEndpoint? = nil
    ) -> AgentProtocolProfileID {
        // Re-entering setup without changing the endpoint is not an explicit
        // protocol change. In particular, native endpoint-less dialects such as
        // anthropic.messages must survive a configuration round trip.
        if previousEndpoint == selectedEndpoint {
            return preferred
        }
        guard preferred.chatEndpoint != selectedEndpoint else {
            return preferred
        }
        return selectedEndpoint == .responses ? .openAIResponses : .openAIChatCompletions
    }

    static func promptAPIKey(
        existingAPIKey: String?,
        providerName: String,
        required: Bool = false
    ) throws -> String {
        guard existingAPIKey?.nilIfBlank != nil else {
            return try promptSecret(
                required ? "API key" : "API key (optional)",
                allowEmpty: !required,
                help: required
                    ? "This hosted provider requires an API key."
                    : "Leave empty only for local providers or servers that do not require authentication."
            )
        }

        guard try promptYesNo(
            "Replace stored API key for \(providerName)?",
            defaultValue: false
        ) else {
            return existingAPIKey ?? ""
        }

        // A provider whose authentication policy requires an API key must
        // never be left with a blank key: `promptSecret` re-prompts until a
        // non-empty value is provided, so an invalid configuration cannot be
        // persisted through this path. Optional keys may still be cleared.
        let prompt = replacementAPIKeyPromptContract(required: required)
        return try promptSecret(
            prompt.label,
            allowEmpty: prompt.allowEmpty,
            help: prompt.help
        )
    }

    /// The terminal contract used when replacing a stored API key, kept pure
    /// so the "required keys cannot be cleared" rule stays regression-tested
    /// without driving the interactive secret prompt.
    static func replacementAPIKeyPromptContract(
        required: Bool
    ) -> (label: String, allowEmpty: Bool, help: String?) {
        required
            ? (
                "New API key",
                false,
                "This hosted provider requires an API key, so the stored key cannot be cleared; enter a replacement value."
            )
            : (
                "New API key (empty clears it)",
                true,
                "Leave empty to clear the stored key."
            )
    }

}
