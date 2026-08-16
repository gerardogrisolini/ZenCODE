//
//  AgentRemoteBackendFactory.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public enum AgentRemoteBackendFactory {
    public static func makeRemoteBackend(
        configuration: AgentRuntimeConfiguration,
        mcpRuntime: DirectMCPToolRuntime,
        fallbackProvider: AgentRemoteProvider? = nil,
        fallbackAPIKey: String? = nil,
        chatGPTConnectionScopeID: String? = nil,
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil
    ) throws -> any AgentRuntimeBackend {
        try makeRemoteBackend(
            configuration: configuration,
            mcpRuntime: mcpRuntime,
            fallbackProvider: fallbackProvider,
            fallbackAPIKey: fallbackAPIKey,
            resolvedModelSelection: nil,
            chatGPTConnectionScopeID: chatGPTConnectionScopeID,
            swiftFeatureRuntime: swiftFeatureRuntime
        )
    }

    static func makeRemoteBackend(
        configuration: AgentRuntimeConfiguration,
        mcpRuntime: DirectMCPToolRuntime,
        fallbackProvider: AgentRemoteProvider? = nil,
        fallbackAPIKey: String? = nil,
        resolvedModelSelection: AgentModelSelection?,
        chatGPTConnectionScopeID: String? = nil,
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
        sharedChat: AgentSharedChat? = nil,
        sharedChatSenderID: String? = nil,
        sharedChatRootSessionID: String? = nil
    ) throws -> any AgentRuntimeBackend {
        let selection = resolvedModelSelection ?? AgentSettingsStore.defaultSelection(
            explicitModelID: configuration.modelID
        )
        if resolvedModelSelection == nil,
           let modelID = configuration.modelID,
           AgentSettingsStore.isRemoteLLMIDSyntax(modelID),
           selection == nil {
            throw AgentCoreBackendError.missingRemoteProvider
        }

        let provider: AgentRemoteProvider
        let apiKey: String?
        let resolvedConfiguration: AgentRuntimeConfiguration
        if let selection {
            guard let selectedProvider = selection.remoteProvider else {
                throw AgentCoreBackendError.missingRemoteProvider
            }
            provider = selectedProvider
            apiKey = selection.apiKey
            resolvedConfiguration = configuration
                .withModelID(selection.modelID)
                .withModelSettings(
                    configuredContextWindowLimit: selection.configuredContextWindowLimit,
                    generationParameterOverrides: selection.generationParameterOverrides
                )
        } else if let fallbackProvider {
            let modelID = configuration.modelID?.nilIfBlank ?? fallbackProvider.modelID
            provider = AgentRemoteProvider(
                id: fallbackProvider.id,
                name: fallbackProvider.name,
                baseURL: fallbackProvider.baseURL,
                modelID: modelID,
                chatEndpoint: fallbackProvider.chatEndpoint,
                providerProfileID: fallbackProvider.providerProfileID,
                protocolProfileID: fallbackProvider.protocolProfileID,
                authPolicy: fallbackProvider.authPolicy
            )
            apiKey = fallbackAPIKey
            resolvedConfiguration = configuration.withModelID(modelID)
        } else {
            throw AgentCoreBackendError.missingRemoteProvider
        }

        if provider.requiresAPIKey, apiKey?.nilIfBlank == nil {
            throw AgentCoreBackendError.missingRemoteAPIKey(provider.displayTitle)
        }

        if provider.protocolProfileID == .openAIChatGPTSubscription {
            return ChatGPTSubscriptionGenerationClient(
                configuration: resolvedConfiguration,
                mcpRuntime: mcpRuntime,
                connectionScopeID: chatGPTConnectionScopeID,
                swiftFeatureRuntime: swiftFeatureRuntime,
                sharedChat: sharedChat,
                sharedChatSenderID: sharedChatSenderID,
                sharedChatRootSessionID: sharedChatRootSessionID,
                subAgentContextualBackendFactory: remoteSubAgentContextualBackendFactory(
                    configuration: resolvedConfiguration,
                    mcpRuntime: mcpRuntime,
                    fallbackProvider: AgentRemoteProvider(
                        id: AgentRemoteProvider.chatGPTSubscriptionProviderID,
                        name: CodexAgentModel.displayTitle,
                        baseURL: AgentRemoteProvider.chatGPTSubscriptionBaseURL,
                        modelID: resolvedConfiguration.modelID ?? CodexAgentModel.defaultLLMID
                    ),
                    swiftFeatureRuntime: swiftFeatureRuntime
                )
            )
        }

        if provider.protocolProfileID == .anthropicClaudeSubscription {
            return AnthropicSubscriptionGenerationClient(
                configuration: resolvedConfiguration,
                provider: provider,
                mcpRuntime: mcpRuntime,
                swiftFeatureRuntime: swiftFeatureRuntime,
                sharedChat: sharedChat,
                sharedChatSenderID: sharedChatSenderID,
                sharedChatRootSessionID: sharedChatRootSessionID,
                subAgentContextualBackendFactory: remoteSubAgentContextualBackendFactory(
                    configuration: resolvedConfiguration,
                    mcpRuntime: mcpRuntime,
                    fallbackProvider: provider,
                    swiftFeatureRuntime: swiftFeatureRuntime
                )
            )
        }

        switch provider.protocolProfileID {
        case .openAIChatCompletions, .openAIResponses, .zaiCodingPlan, .anthropicMessages:
            break
        case .openAIChatGPTSubscription, .anthropicClaudeSubscription:
            // Native Anthropic API support is intentionally not provided by the
            // subscription client. Unknown/unimplemented adapters fail closed.
            throw AgentCoreBackendError.missingRemoteProvider
        }

        return RemoteGenerationClient(
            configuration: resolvedConfiguration,
            provider: provider,
            apiKey: apiKey,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: swiftFeatureRuntime,
            sharedChat: sharedChat,
            sharedChatSenderID: sharedChatSenderID,
            sharedChatRootSessionID: sharedChatRootSessionID,
            subAgentContextualBackendFactory: remoteSubAgentContextualBackendFactory(
                configuration: resolvedConfiguration,
                mcpRuntime: mcpRuntime,
                fallbackProvider: provider,
                fallbackAPIKey: apiKey,
                swiftFeatureRuntime: swiftFeatureRuntime
            )
        )
    }

    private static func remoteSubAgentContextualBackendFactory(
        configuration: AgentRuntimeConfiguration,
        mcpRuntime: DirectMCPToolRuntime,
        fallbackProvider: AgentRemoteProvider,
        fallbackAPIKey: String? = nil,
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil
    ) -> DirectSubAgentContextualBackendFactory {
        { context in
            let appliedConfiguration = configuration.applyingSubAgentBackendContext(context)
            let inheritedModelID = configuration.modelID?.nilIfBlank
                ?? fallbackProvider.modelID
            let inheritedProvider = AgentRemoteProvider(
                id: fallbackProvider.id,
                name: fallbackProvider.name,
                baseURL: fallbackProvider.baseURL,
                modelID: inheritedModelID,
                chatEndpoint: fallbackProvider.chatEndpoint,
                providerProfileID: fallbackProvider.providerProfileID,
                protocolProfileID: fallbackProvider.protocolProfileID,
                authPolicy: fallbackProvider.authPolicy
            )
            let inheritedSelection = AgentModelSelection(
                providerKind: .remoteAPI,
                modelID: inheritedModelID,
                remoteProvider: inheritedProvider,
                apiKey: fallbackAPIKey,
                configuredContextWindowLimit: configuration.configuredContextWindowLimit,
                generationParameterOverrides: configuration.generationParameterOverrides,
                thinkingSelection: context.thinkingSelection
            )
            let modelSelection = configuration.locksModelToSession
                ? inheritedSelection
                : (context.modelSelection ?? inheritedSelection)

            return try makeRemoteBackend(
                configuration: appliedConfiguration,
                mcpRuntime: mcpRuntime,
                fallbackProvider: fallbackProvider,
                fallbackAPIKey: fallbackAPIKey,
                resolvedModelSelection: modelSelection,
                chatGPTConnectionScopeID: UUID().uuidString,
                swiftFeatureRuntime: context.swiftFeatureRuntime ?? swiftFeatureRuntime,
                sharedChat: context.sharedChat,
                sharedChatSenderID: context.sharedChatSenderID,
                sharedChatRootSessionID: context.sharedChatRoomID
            )
        }
    }
}
