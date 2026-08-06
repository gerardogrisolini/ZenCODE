//
//  AgentRemoteBackendFactory.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AgentRemoteBackendFactory {
    public static func makeRemoteBackend(
        configuration: AgentRuntimeConfiguration,
        mcpRuntime: DirectMCPToolRuntime,
        fallbackProvider: AgentRemoteProvider? = nil,
        fallbackAPIKey: String? = nil,
        urlSession: URLSession? = nil,
        chatGPTConnectionScopeID: String? = nil,
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil
    ) throws -> any AgentRuntimeBackend {
        try makeRemoteBackend(
            configuration: configuration,
            mcpRuntime: mcpRuntime,
            fallbackProvider: fallbackProvider,
            fallbackAPIKey: fallbackAPIKey,
            resolvedModelSelection: nil,
            urlSession: urlSession,
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
        urlSession: URLSession? = nil,
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
                chatEndpoint: fallbackProvider.chatEndpoint
            )
            apiKey = fallbackAPIKey
            resolvedConfiguration = configuration.withModelID(modelID)
        } else {
            throw AgentCoreBackendError.missingRemoteProvider
        }

        if provider.requiresAPIKey, apiKey?.nilIfBlank == nil {
            throw AgentCoreBackendError.missingRemoteAPIKey(provider.displayTitle)
        }

        if provider.isChatGPTSubscriptionProvider {
            return ChatGPTSubscriptionGenerationClient(
                configuration: resolvedConfiguration,
                urlSession: urlSession,
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
                    urlSession: urlSession,
                    swiftFeatureRuntime: swiftFeatureRuntime
                )
            )
        }

        if provider.isAnthropicSubscriptionProvider {
            return AnthropicSubscriptionGenerationClient(
                configuration: resolvedConfiguration,
                provider: provider,
                urlSession: urlSession,
                mcpRuntime: mcpRuntime,
                swiftFeatureRuntime: swiftFeatureRuntime,
                sharedChat: sharedChat,
                sharedChatSenderID: sharedChatSenderID,
                sharedChatRootSessionID: sharedChatRootSessionID,
                subAgentContextualBackendFactory: remoteSubAgentContextualBackendFactory(
                    configuration: resolvedConfiguration,
                    mcpRuntime: mcpRuntime,
                    fallbackProvider: provider,
                    urlSession: urlSession,
                    swiftFeatureRuntime: swiftFeatureRuntime
                )
            )
        }

        return RemoteGenerationClient(
            configuration: resolvedConfiguration,
            provider: provider,
            apiKey: apiKey,
            urlSession: urlSession,
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
                urlSession: urlSession,
                swiftFeatureRuntime: swiftFeatureRuntime
            )
        )
    }

    private static func remoteSubAgentContextualBackendFactory(
        configuration: AgentRuntimeConfiguration,
        mcpRuntime: DirectMCPToolRuntime,
        fallbackProvider: AgentRemoteProvider,
        fallbackAPIKey: String? = nil,
        urlSession: URLSession? = nil,
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
                chatEndpoint: fallbackProvider.chatEndpoint
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
                urlSession: urlSession,
                chatGPTConnectionScopeID: UUID().uuidString,
                swiftFeatureRuntime: context.swiftFeatureRuntime ?? swiftFeatureRuntime,
                sharedChat: context.sharedChat,
                sharedChatSenderID: context.sharedChatSenderID,
                sharedChatRootSessionID: context.sharedChatRoomID
            )
        }
    }
}
