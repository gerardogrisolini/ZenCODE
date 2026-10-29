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

        let selectedProviderIndexes = promptProviderInputIndexes(
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


    /// Reads one new provider. A provider is identified by its stable key and
    /// configured at most once: choosing a provider whose key is already in
    /// `configuredProviderIDs` adds nothing, prints how to reconfigure it and
    /// returns `nil`.
    static func readProvider(
        configuredProviderIDs: Set<String> = []
    ) async throws -> SetupProviderInput? {
        let kind = try promptProviderKind(configuredProviderIDs: configuredProviderIDs)
        if let message = alreadyConfiguredProviderMessage(
            for: kind,
            configuredProviderIDs: configuredProviderIDs
        ) {
            AgentOutput.standardError.writeString("\n\(message)\n")
            return nil
        }
        switch kind {
        case let .remoteAPI(preset):
            return try await readRemoteAPIProvider(preset: preset)
        case .chatGPTSubscription:
            return try await readChatGPTSubscriptionProvider()
        case .anthropicSubscription:
            return try await readAnthropicSubscriptionProvider()
        }
    }

    /// Menu detail of a provider choice that is already configured.
    static let alreadyConfiguredProviderDetail =
        "already configured: reconfigure it instead"

    /// The message shown when the operator picks a provider that is already
    /// configured, or `nil` when `kind` may be added.
    static func alreadyConfiguredProviderMessage(
        for kind: SetupProviderKind,
        configuredProviderIDs: Set<String>
    ) -> String? {
        guard configuredProviderIDs.contains(kind.providerID) else {
            return nil
        }
        return "\(providerKindTitle(kind)) is already configured (provider '\(kind.providerID)'). "
            + "A provider cannot be added twice: reconfigure it from \"Reconfigure providers\" instead."
    }

    static func providerKindTitle(_ kind: SetupProviderKind) -> String {
        switch kind {
        case let .remoteAPI(preset):
            return preset.title
        case .chatGPTSubscription:
            return AgentRemoteProvider.chatGPTSubscriptionDisplayTitle
        case .anthropicSubscription:
            return AgentRemoteProvider.anthropicSubscriptionDisplayTitle
        }
    }

    static func readRemoteAPIProvider(
        preset: SetupProviderPreset = .custom,
        existingProvider: AgentSettingsProviderManifest? = nil,
        existingModels: [AgentSettingsModelManifest] = [],
        existingAPIKey: String? = nil
    ) async throws -> SetupProviderInput {
        AgentOutput.standardError.writeString("\n\(preset.title)\(preset.isAdvanced ? " (advanced)" : "")\n")
        // The key is stable: a reconfigured provider keeps its own, a new one
        // receives its preset key. An id is never generated.
        let id = existingProvider?.id ?? preset.providerID
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
                authPolicy: authPolicy,
                ds4Runtime: existingProvider?.ds4Runtime
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
            ds4Runtime: existingProvider?.ds4Runtime,
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
        let name = AgentRemoteProvider.chatGPTSubscriptionDisplayTitle
        let baseURL = AgentRemoteProvider.chatGPTSubscriptionBaseURL
        let chatEndpoint = AgentRemoteChatEndpoint.responses
        let candidates = try await discoveredSubscriptionCandidates(
            provider: .chatGPT, accessToken: credentials.accessToken,
            accountID: credentials.accountID, existingModels: existingModels
        )
        let models = try selectSubscriptionModelCandidates(
            candidates,
            title: "ChatGPT Subscription models",
            defaultModels: existingModels
        ).map { candidate in
            existingModels.first(where: { $0.modelID == candidate.modelID }) ?? subscriptionModelManifest(
                candidate: candidate,
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
        let name = AgentRemoteProvider.anthropicSubscriptionDisplayTitle
        let baseURL = AgentRemoteProvider.anthropicSubscriptionBaseURL
        let chatEndpoint = AgentRemoteChatEndpoint.responses
        let candidates = try await discoveredSubscriptionCandidates(
            provider: .anthropic, accessToken: credentials.accessToken,
            catalogScopeID: credentials.catalogScopeID,
            existingModels: existingModels
        )
        let models = try selectSubscriptionModelCandidates(
            candidates,
            title: "Claude Subscription models",
            defaultModels: existingModels
        ).map { candidate in
            existingModels.first(where: { $0.modelID == candidate.modelID }) ?? subscriptionModelManifest(
                candidate: candidate,
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
