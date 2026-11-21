//
//  ZenCODESetupRunner+ProviderReading.swift
//  ZenCODE
//
//  Reading of one new provider during setup: remote API and subscription
//  providers, protocol profile reconciliation and API key prompts.
//

import Foundation
import ToolCore
import ZenCODERuntime

extension ZenCODESetupRunner {
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
