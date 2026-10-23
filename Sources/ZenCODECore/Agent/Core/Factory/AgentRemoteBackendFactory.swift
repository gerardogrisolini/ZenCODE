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
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
        ds4Supervisor: DS4ServerSupervisor? = nil,
        ds4Endpoint: DS4ServerEndpoint? = nil,
        ownsDS4Supervisor: Bool = true
    ) throws -> any AgentRuntimeBackend {
        try makeRemoteBackend(
            configuration: configuration,
            mcpRuntime: mcpRuntime,
            fallbackProvider: fallbackProvider,
            fallbackAPIKey: fallbackAPIKey,
            resolvedModelSelection: nil,
            chatGPTConnectionScopeID: chatGPTConnectionScopeID,
            swiftFeatureRuntime: swiftFeatureRuntime,
            ds4Supervisor: ds4Supervisor,
            ds4Endpoint: ds4Endpoint,
            ownsDS4Supervisor: ownsDS4Supervisor
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
        ds4Supervisor: DS4ServerSupervisor? = nil,
        ds4Endpoint: DS4ServerEndpoint? = nil,
        ownsDS4Supervisor: Bool = true,
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
        let effectiveConfiguration = ds4WireModelID.map {
            resolvedConfiguration.withModelID($0)
        } ?? resolvedConfiguration
        let effectiveProvider = ds4WireModelID.map {
            provider.withModelID($0)
        } ?? provider
        let hasLocalDS4Endpoint = resolvedDS4Runtime != nil
            || ds4Supervisor != nil
            || ds4Endpoint != nil
        if provider.requiresAPIKey, apiKey?.nilIfBlank == nil, !hasLocalDS4Endpoint {
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
                    swiftFeatureRuntime: swiftFeatureRuntime
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
                    swiftFeatureRuntime: swiftFeatureRuntime
                )
            )
        }

        // Realtime voice models are recognised by model ID on the OpenAI
        // provider profile. They only drive the macOS interactive terminal and
        // never back a delegated agent.
        if OpenAIRealtimeModel.matches(
            provider: effectiveProvider,
            modelID: effectiveProvider.modelID
        ) {
            #if os(macOS)
            if sharedChatSenderID != nil {
                throw AgentCoreBackendError.realtimeModelUnsupportedForDelegation(
                    effectiveProvider.modelID
                )
            }
            return RealtimeGenerationClient(
                configuration: effectiveConfiguration,
                provider: effectiveProvider,
                apiKey: apiKey,
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
                    swiftFeatureRuntime: swiftFeatureRuntime
                )
            )
            #else
            throw AgentCoreBackendError.realtimeModelRequiresMacOS(effectiveProvider.modelID)
            #endif
        }

        switch provider.protocolProfileID {
        case .openAIChatCompletions, .openAIResponses, .zaiCodingPlan, .anthropicMessages:
            break
        case .openAIChatGPTSubscription, .anthropicClaudeSubscription:
            // Native Anthropic API support is intentionally not provided by the
            // subscription client. Unknown/unimplemented adapters fail closed.
            throw AgentCoreBackendError.missingRemoteProvider
        }

        let resolvedDS4Supervisor: DS4ServerSupervisor?
        let resolvedDS4SupervisorOwnership: Bool
        if let ds4Supervisor {
            resolvedDS4Supervisor = ds4Supervisor
            resolvedDS4SupervisorOwnership = ownsDS4Supervisor
        } else if let resolvedDS4Runtime {
            resolvedDS4Supervisor = DS4ServerSupervisor(
                manifest: resolvedDS4Runtime,
                modelAlias: effectiveConfiguration.modelID?.nilIfBlank ?? effectiveProvider.modelID,
                adoptionPort: ds4AdoptionPort(from: effectiveProvider.baseURL)
            )
            // This ownership bit belongs to the supervisor actor lifecycle,
            // not to the process behind its endpoint. The supervisor marks an
            // adopted endpoint as external and will only stop a child it
            // launched itself. A factory-created owner is tied to this backend
            // incarnation; reset shuts it down before replacement.
            resolvedDS4SupervisorOwnership = true
        } else {
            resolvedDS4Supervisor = nil
            resolvedDS4SupervisorOwnership = false
        }

        return RemoteGenerationClient(
            configuration: effectiveConfiguration,
            provider: effectiveProvider,
            apiKey: apiKey,
            thinkingOptions: thinkingOptions,
            ds4Supervisor: resolvedDS4Supervisor,
            ds4Endpoint: ds4Endpoint,
            ownsDS4Supervisor: resolvedDS4SupervisorOwnership,
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
                swiftFeatureRuntime: swiftFeatureRuntime,
                ds4Supervisor: resolvedDS4Supervisor,
                ds4Endpoint: ds4Endpoint
            )
        )
    }

    private static func remoteSubAgentContextualBackendFactory(
        configuration: AgentRuntimeConfiguration,
        mcpRuntime: DirectMCPToolRuntime,
        fallbackProvider: AgentRemoteProvider,
        fallbackAPIKey: String? = nil,
        fallbackThinkingOptions: [AgentThinkingSelection]? = nil,
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
        ds4Supervisor: DS4ServerSupervisor? = nil,
        ds4Endpoint: DS4ServerEndpoint? = nil
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
                ds4Runtime: fallbackProvider.ds4Runtime
            )
            let modelSelection = configuration.locksModelToSession
                ? inheritedSelection
                : (context.modelSelection ?? inheritedSelection)

            // A contextual child may borrow the root's DS4 owner only when it
            // is still using the inherited root selection (or explicitly picks
            // that same DS4 provider/runtime). A different provider must remain
            // an ordinary remote client; forwarding the root endpoint would
            // silently route its requests into the local server.
            let canBorrowRootDS4 = if ds4Supervisor != nil || ds4Endpoint != nil {
                if context.modelSelection == nil || configuration.locksModelToSession {
                    true
                } else {
                    modelSelection.ds4Runtime != nil
                        && modelSelection.ds4Runtime == fallbackProvider.ds4Runtime
                        && modelSelection.remoteProvider?.id == fallbackProvider.id
                }
            } else {
                false
            }
            let childDS4Supervisor = canBorrowRootDS4 ? ds4Supervisor : nil
            let childDS4Endpoint = canBorrowRootDS4 ? ds4Endpoint : nil

            return try makeRemoteBackend(
                configuration: appliedConfiguration,
                mcpRuntime: mcpRuntime,
                fallbackProvider: fallbackProvider,
                fallbackAPIKey: fallbackAPIKey,
                resolvedModelSelection: modelSelection,
                chatGPTConnectionScopeID: UUID().uuidString,
                swiftFeatureRuntime: context.swiftFeatureRuntime ?? swiftFeatureRuntime,
                ds4Supervisor: childDS4Supervisor,
                ds4Endpoint: childDS4Endpoint,
                ownsDS4Supervisor: false,
                sharedChat: context.sharedChat,
                sharedChatSenderID: context.sharedChatSenderID,
                sharedChatRootSessionID: context.sharedChatRoomID
            )
        }
    }

    /// The persisted DS4 provider URL is an explicit 127.0.0.1 adoption hint.
    /// A missing port retains the upstream conventional `8000` candidate;
    /// malformed, non-HTTP, or non-127.0.0.1 URLs disable adoption rather than
    /// silently probing a different host.
    private static func ds4AdoptionPort(from baseURL: String) -> Int? {
        guard let url = URL(string: baseURL),
              url.scheme?.lowercased() == "http",
              url.host?.lowercased() == DS4ServerSupervisor.defaultHost else {
            return nil
        }
        guard let port = url.port else {
            return DS4ServerSupervisor.defaultConventionalPort
        }
        return (1...65_535).contains(port) ? port : nil
    }
}
