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
        sharedChatRootSessionID: String? = nil,
        ds4Environment: DS4LocalGeneration.Environment = .production
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
        let thinkingOptions: [AgentThinkingSelection]?
        let resolvedConfiguration: AgentRuntimeConfiguration
        if let selection {
            guard let selectedProvider = selection.remoteProvider else {
                throw AgentCoreBackendError.missingRemoteProvider
            }
            provider = selectedProvider
            apiKey = selection.apiKey
            thinkingOptions = selection.thinkingOptions
            resolvedConfiguration = configuration
                .withModelID(selection.modelID)
                .withModelSettings(
                    configuredContextWindowLimit: selection.configuredContextWindowLimit,
                    generationParameterOverrides: selection.generationParameterOverrides
                )
        } else if let fallbackProvider {
            let modelID = configuration.modelID?.nilIfBlank ?? fallbackProvider.modelID
            provider = fallbackProvider.withModelID(modelID)
            apiKey = fallbackAPIKey
            thinkingOptions = nil
            resolvedConfiguration = configuration.withModelID(modelID)
        } else {
            throw AgentCoreBackendError.missingRemoteProvider
        }

        if provider.isChatGPTSubscriptionProvider || provider.isAnthropicSubscriptionProvider {
            let prefix = provider.isChatGPTSubscriptionProvider ? "chatgpt" : "claude"
            guard !RemoteSubscriptionModelID.modelID(fromLLMID: resolvedConfiguration.modelID, prefix: prefix).isEmpty else {
                throw AgentCoreBackendError.missingRemoteProvider
            }
        }

        let resolvedDS4Runtime = selection?.ds4Runtime ?? provider.ds4Runtime
        let ds4WireModelID: String?
        if resolvedDS4Runtime != nil {
            let candidateModelID = resolvedConfiguration.modelID?.nilIfBlank ?? provider.modelID
            ds4WireModelID = DS4ModelCatalog.canonicalAPIModelID(forCatalogID: candidateModelID)
        } else {
            ds4WireModelID = nil
        }
        let effectiveConfiguration = Self.ds4AlignedConfiguration(
            ds4WireModelID.map { resolvedConfiguration.withModelID($0) } ?? resolvedConfiguration,
            runtime: resolvedDS4Runtime
        )
        let effectiveProvider = ds4WireModelID.map {
            provider.withModelID($0)
        } ?? provider
        if provider.requiresAPIKey, apiKey?.nilIfBlank == nil, resolvedDS4Runtime == nil {
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
                        name: AgentRemoteProvider.chatGPTSubscriptionDisplayTitle,
                        baseURL: AgentRemoteProvider.chatGPTSubscriptionBaseURL,
                        modelID: resolvedConfiguration.modelID ?? provider.modelID
                    ),
                    fallbackThinkingOptions: thinkingOptions,
                    swiftFeatureRuntime: swiftFeatureRuntime,
                    ds4Environment: ds4Environment
                )
            )
        }

        if provider.protocolProfileID == .anthropicClaudeSubscription {
            return AnthropicSubscriptionGenerationClient(
                configuration: resolvedConfiguration,
                provider: provider,
                thinkingOptions: thinkingOptions,
                mcpRuntime: mcpRuntime,
                swiftFeatureRuntime: swiftFeatureRuntime,
                sharedChat: sharedChat,
                sharedChatSenderID: sharedChatSenderID,
                sharedChatRootSessionID: sharedChatRootSessionID,
                subAgentContextualBackendFactory: remoteSubAgentContextualBackendFactory(
                    configuration: resolvedConfiguration,
                    mcpRuntime: mcpRuntime,
                    fallbackProvider: provider,
                    fallbackThinkingOptions: thinkingOptions,
                    swiftFeatureRuntime: swiftFeatureRuntime,
                    ds4Environment: ds4Environment
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
            configuration: effectiveConfiguration,
            provider: effectiveProvider,
            apiKey: apiKey,
            thinkingOptions: thinkingOptions,
            ds4Generation: resolvedDS4Runtime.map { DS4LocalGeneration(manifest: $0, environment: ds4Environment) },
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: swiftFeatureRuntime,
            sharedChat: sharedChat,
            sharedChatSenderID: sharedChatSenderID,
            sharedChatRootSessionID: sharedChatRootSessionID,
            subAgentContextualBackendFactory: remoteSubAgentContextualBackendFactory(
                configuration: effectiveConfiguration,
                mcpRuntime: mcpRuntime,
                fallbackProvider: effectiveProvider,
                fallbackAPIKey: apiKey,
                fallbackThinkingOptions: thinkingOptions,
                fallbackDS4Runtime: resolvedDS4Runtime,
                swiftFeatureRuntime: swiftFeatureRuntime,
                ds4Environment: ds4Environment
            )
        )
    }

    /// A DS4 model's context window is the manifest's `contextWindow` (the
    /// engine session size): the generic compaction budget and the context
    /// status use it even when the model settings carry another limit.
    static func ds4AlignedConfiguration(
        _ configuration: AgentRuntimeConfiguration,
        runtime: AgentDS4RuntimeConfiguration?
    ) -> AgentRuntimeConfiguration {
        guard let runtime, configuration.configuredContextWindowLimit != runtime.contextWindow else {
            return configuration
        }
        return configuration.withModelSettings(
            configuredContextWindowLimit: runtime.contextWindow,
            generationParameterOverrides: configuration.generationParameterOverrides
        )
    }

    private static func remoteSubAgentContextualBackendFactory(
        configuration: AgentRuntimeConfiguration,
        mcpRuntime: DirectMCPToolRuntime,
        fallbackProvider: AgentRemoteProvider,
        fallbackAPIKey: String? = nil,
        fallbackThinkingOptions: [AgentThinkingSelection]? = nil,
        fallbackDS4Runtime: AgentDS4RuntimeConfiguration? = nil,
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
        ds4Environment: DS4LocalGeneration.Environment = .production
    ) -> DirectSubAgentContextualBackendFactory {
        { context in
            let appliedConfiguration = configuration.applyingSubAgentBackendContext(context)
            let inheritedModelID = configuration.modelID?.nilIfBlank
                ?? fallbackProvider.modelID
            let inheritedProvider = fallbackProvider.withModelID(inheritedModelID)
            let inheritedSelection = AgentModelSelection(
                providerKind: .remoteAPI,
                modelID: inheritedModelID,
                remoteProvider: inheritedProvider,
                apiKey: fallbackAPIKey,
                configuredContextWindowLimit: configuration.configuredContextWindowLimit,
                generationParameterOverrides: configuration.generationParameterOverrides,
                thinkingOptions: fallbackThinkingOptions,
                thinkingSelection: context.thinkingSelection,
                ds4Runtime: fallbackDS4Runtime ?? fallbackProvider.ds4Runtime
            )
            let modelSelection = configuration.locksModelToSession
                ? inheritedSelection
                : (context.modelSelection ?? inheritedSelection)

            // A child on a DS4 selection (the inherited model or another DS4
            // model) gets the same DS4 environment, hence the same engine
            // registry and FIFO lock; any other provider stays an ordinary
            // remote client.
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
                sharedChatRootSessionID: context.sharedChatRoomID,
                ds4Environment: ds4Environment
            )
        }
    }
}
