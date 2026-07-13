//
//  AgentRemoteBackendFactory.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
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
        let selection = AgentSettingsStore.defaultSelection(
            explicitModelID: configuration.modelID
        )
        if let modelID = configuration.modelID,
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
            apiKey = selection.apiKey ?? configuration.bearerToken
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
            apiKey = fallbackAPIKey ?? configuration.bearerToken
            resolvedConfiguration = configuration.withModelID(modelID)
        } else {
            throw AgentCoreBackendError.missingRemoteProvider
        }

        if provider.requiresAPIKey, apiKey?.nilIfBlank == nil {
            throw AgentCoreBackendError.missingRemoteAPIKey(provider.displayTitle)
        }

        if provider.isChatGPTSubscriptionProvider {
#if os(macOS)
            return ChatGPTSubscriptionGenerationClient(
                configuration: resolvedConfiguration,
                urlSession: urlSession,
                mcpRuntime: mcpRuntime,
                connectionScopeID: chatGPTConnectionScopeID,
                swiftFeatureRuntime: swiftFeatureRuntime,
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
#else
            throw AgentCoreBackendError.missingRemoteProvider
#endif
        }

        if provider.isAnthropicSubscriptionProvider {
#if os(macOS)
            return AnthropicSubscriptionGenerationClient(
                configuration: resolvedConfiguration,
                provider: provider,
                urlSession: urlSession,
                mcpRuntime: mcpRuntime,
                swiftFeatureRuntime: swiftFeatureRuntime,
                subAgentContextualBackendFactory: remoteSubAgentContextualBackendFactory(
                    configuration: resolvedConfiguration,
                    mcpRuntime: mcpRuntime,
                    fallbackProvider: provider,
                    urlSession: urlSession,
                    swiftFeatureRuntime: swiftFeatureRuntime
                )
            )
#else
            throw AgentCoreBackendError.missingRemoteProvider
#endif
        }

        return RemoteGenerationClient(
            configuration: resolvedConfiguration,
            provider: provider,
            apiKey: apiKey,
            urlSession: urlSession,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: swiftFeatureRuntime,
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
            try makeRemoteBackend(
                configuration: configuration.applyingSubAgentBackendContext(context),
                mcpRuntime: mcpRuntime,
                fallbackProvider: fallbackProvider,
                fallbackAPIKey: fallbackAPIKey,
                urlSession: urlSession,
                chatGPTConnectionScopeID: UUID().uuidString,
                swiftFeatureRuntime: context.swiftFeatureRuntime ?? swiftFeatureRuntime
            )
        }
    }
}
