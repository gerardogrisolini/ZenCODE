//
//  ZenCODESetupProviderPresetTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct ZenCODESetupProviderPresetTests {
    @Test
    func setupExposesTheCompleteProviderPresetCatalog() {
        #expect(
            SetupProviderPreset.allCases == [
                .openRouter,
                .openAIAPI,
                .anthropicAPI,
                .zaiAPI,
                .zaiCodingPlan,
                .gemini,
                .deepSeek,
                .kimi,
                .nvidiaAPI,
                .modal,
                .custom
            ]
        )
        #expect(SetupProviderPreset.custom.isAdvanced)
        #expect(!SetupProviderPreset.openRouter.isAdvanced)
    }

    @Test
    func hostedPresetContractsUseExpectedProfilesEndpointsAndAuthentication() {
        let expected: [SetupProviderPreset: (
            title: String,
            baseURL: String,
            provider: AgentProviderProfileID,
            protocolProfile: AgentProtocolProfileID
        )] = [
            .openRouter: (
                "OpenRouter",
                "https://openrouter.ai/api/v1",
                .openRouter,
                .openAIChatCompletions
            ),
            .openAIAPI: (
                "OpenAI API",
                "https://api.openai.com/v1",
                .openAI,
                .openAIResponses
            ),
            .zaiAPI: (
                "Z.ai API",
                "https://api.z.ai/api/paas/v4",
                .zAI,
                .openAIChatCompletions
            ),
            .zaiCodingPlan: (
                "Z.ai Coding Plan",
                "https://api.z.ai/api/coding/paas/v4",
                .zAI,
                .zaiCodingPlan
            ),
            .gemini: (
                "Gemini",
                "https://generativelanguage.googleapis.com/v1beta/openai",
                .googleGemini,
                .openAIChatCompletions
            ),
            .deepSeek: (
                "DeepSeek",
                "https://api.deepseek.com/v1",
                .deepSeek,
                .openAIChatCompletions
            ),
            .kimi: (
                "Kimi API (Moonshot AI)",
                "https://api.moonshot.ai/v1",
                .moonshot,
                .openAIChatCompletions
            ),
            .nvidiaAPI: (
                "NVIDIA API",
                "https://integrate.api.nvidia.com/v1",
                .nvidia,
                .openAIChatCompletions
            ),
            .modal: (
                "Modal",
                "https://api.us-west-2.modal.direct/v1",
                .modal,
                .openAIChatCompletions
            )
        ]

        for (preset, contract) in expected {
            #expect(preset.title == contract.title)
            #expect(preset.baseURL == contract.baseURL)
            #expect(preset.providerProfileID == contract.provider)
            #expect(preset.protocolProfileID == contract.protocolProfile)
            #expect(preset.authPolicy == .apiKeyRequired)
            #expect(preset.protocolProfileID.chatEndpoint != nil)
        }
    }

    @Test
    func customPresetIsAdvancedAndDoesNotClaimHostedAuthentication() {
        let preset = SetupProviderPreset.custom

        #expect(preset.providerProfileID == .custom)
        #expect(preset.protocolProfileID == .openAIChatCompletions)
        #expect(preset.authPolicy == .apiKeyOptional)
        #expect(!preset.authPolicy.requiresAPIKey)

        // Selecting Custom is an explicit identity decision even if the user
        // enters a URL that resembles a hosted preset.
        let input = SetupProviderInput(
            id: UUID(), name: "Custom NVIDIA-shaped endpoint",
            baseURL: SetupProviderPreset.nvidiaAPI.baseURL,
            chatEndpoint: .chatCompletions,
            providerProfileID: preset.providerProfileID,
            protocolProfileID: preset.protocolProfileID,
            authPolicy: preset.authPolicy,
            apiKey: nil, models: []
        )
        #expect(input.providerProfileID == .custom)
        #expect(input.authPolicy == .apiKeyOptional)
    }

    @Test
    func openAIAPIAndChatGPTSubscriptionRemainSeparateProviders() {
        let apiID = UUID()
        let api = SetupProviderInput(
            id: apiID,
            name: SetupProviderPreset.openAIAPI.title,
            baseURL: SetupProviderPreset.openAIAPI.baseURL,
            chatEndpoint: .responses,
            providerProfileID: SetupProviderPreset.openAIAPI.providerProfileID,
            protocolProfileID: SetupProviderPreset.openAIAPI.protocolProfileID,
            authPolicy: SetupProviderPreset.openAIAPI.authPolicy,
            apiKey: "openai-key",
            models: []
        )
        let credentials = CodexAgentCredentials(
            accessToken: "subscription-access",
            refreshToken: "subscription-refresh",
            expiresAt: Date(timeIntervalSince1970: 123),
            accountID: "subscription-account"
        )
        let subscription = SetupProviderInput(
            id: AgentRemoteProvider.chatGPTSubscriptionProviderID,
            name: "ChatGPT Subscription",
            baseURL: AgentRemoteProvider.chatGPTSubscriptionBaseURL,
            chatEndpoint: .responses,
            apiKey: nil,
            models: [],
            chatGPTSubscriptionCredentials: credentials
        )

        #expect(api.id != subscription.id)
        #expect(api.apiKey == "openai-key")
        #expect(api.chatGPTSubscriptionCredentials == nil)
        #expect(subscription.apiKey == nil)
        #expect(subscription.chatGPTSubscriptionCredentials?.accessToken == "subscription-access")
        #expect(api.protocolProfileID == .openAIResponses)
        #expect(subscription.protocolProfileID == .openAIChatGPTSubscription)
    }

    @Test
    func setupProviderConversionPreservesExplicitProfiles() {
        let input = SetupProviderInput(
            id: UUID(),
            name: SetupProviderPreset.kimi.title,
            baseURL: SetupProviderPreset.kimi.baseURL,
            chatEndpoint: .chatCompletions,
            providerProfileID: SetupProviderPreset.kimi.providerProfileID,
            protocolProfileID: SetupProviderPreset.kimi.protocolProfileID,
            authPolicy: SetupProviderPreset.kimi.authPolicy,
            apiKey: "moonshot-key",
            models: []
        )

        let manifest = ZenCODESetupRunner.providerManifest(from: input)
        let preserved = ZenCODESetupRunner.preserveProviderInput(
            provider: manifest,
            models: [],
            apiKey: input.apiKey
        )

        #expect(preserved.id == input.id)
        #expect(preserved.providerProfileID == .moonshot)
        #expect(preserved.protocolProfileID == .openAIChatCompletions)
        #expect(preserved.authPolicy == .apiKeyRequired)
        #expect(preserved.baseURL == "https://api.moonshot.ai/v1")
        #expect(preserved.apiKey == "moonshot-key")
    }

    @Test
    func zaiAPIAndCodingPlanShareTheNominalProviderButKeepDistinctProtocolProfiles() {
        let api = SetupProviderPreset.zaiAPI
        let codingPlan = SetupProviderPreset.zaiCodingPlan

        #expect(api.providerProfileID == .zAI)
        #expect(codingPlan.providerProfileID == .zAI)
        #expect(api.providerProfileID != .custom)
        #expect(codingPlan.providerProfileID != .custom)
        #expect(api.protocolProfileID == .openAIChatCompletions)
        #expect(codingPlan.protocolProfileID == .zaiCodingPlan)
        #expect(api.protocolProfileID != codingPlan.protocolProfileID)
        #expect(api.protocolProfileID.chatEndpoint == .chatCompletions)
        #expect(codingPlan.protocolProfileID.chatEndpoint == .chatCompletions)
        #expect(api.baseURL != codingPlan.baseURL)
    }

    @Test
    func anthropicDirectAPIHasNativeMessagesPresetDistinctFromSubscription() {
        #expect(SetupAnthropicProviderOption.api != .subscription)
        let preset = SetupProviderPreset.anthropicAPI
        #expect(SetupProviderPreset.allCases.contains(preset))
        #expect(preset.title == "Anthropic API")
        #expect(preset.baseURL == "https://api.anthropic.com/v1")
        #expect(preset.providerProfileID == .anthropic)
        #expect(preset.protocolProfileID == .anthropicMessages)
        #expect(preset.authPolicy == .apiKeyRequired)
    }

    // MARK: - Regression: reconfiguration keeps the protocol profile in sync
    // with the selected endpoint

    @Test
    func reconfiguredEndpointUpdatesThePersistedProtocolProfile() {
        let reconcile: (AgentRemoteChatEndpoint, AgentProtocolProfileID) -> AgentProtocolProfileID = {
            ZenCODESetupRunner.reconciledProtocolProfileID(
                selectedEndpoint: $0,
                preferred: $1
            )
        }

        // Switching endpoint remaps the protocol profile instead of keeping a
        // stale one that would override the persisted chatEndpoint on load.
        #expect(reconcile(.responses, .openAIChatCompletions) == .openAIResponses)
        #expect(reconcile(.chatCompletions, .openAIResponses) == .openAIChatCompletions)

        // Keeping the endpoint preserves domain-specific protocol profiles.
        #expect(reconcile(.chatCompletions, .zaiCodingPlan) == .zaiCodingPlan)
        #expect(reconcile(.chatCompletions, .openAIChatCompletions) == .openAIChatCompletions)
        #expect(reconcile(.responses, .openAIResponses) == .openAIResponses)

        // Endpoint-less profiles are remapped too: the reconfigured provider
        // dispatches on the endpoint the operator actually selected.
        #expect(reconcile(.chatCompletions, .anthropicMessages) == .openAIChatCompletions)

        // Merely accepting the existing endpoint preserves the native Messages
        // dialect. Only an endpoint that differs from the previous value is an
        // explicit protocol change.
        #expect(
            ZenCODESetupRunner.reconciledProtocolProfileID(
                selectedEndpoint: .chatCompletions,
                preferred: .anthropicMessages,
                previousEndpoint: .chatCompletions
            ) == .anthropicMessages
        )

        // Why reconciliation matters: the protocol profile owns the persisted
        // endpoint at load time, so a mismatched pair would silently revert it.
        let switched = AgentRemoteProvider(
            name: "Switched",
            baseURL: "https://api.openai.com/v1",
            modelID: "gpt-5.4",
            chatEndpoint: .responses,
            providerProfileID: .openAI,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .apiKeyRequired
        )
        #expect(switched.chatEndpoint == .chatCompletions)
        let reconciled = AgentRemoteProvider(
            name: "Reconciled",
            baseURL: "https://api.openai.com/v1",
            modelID: "gpt-5.4",
            chatEndpoint: .responses,
            providerProfileID: .openAI,
            protocolProfileID: reconcile(.responses, .openAIChatCompletions),
            authPolicy: .apiKeyRequired
        )
        #expect(reconciled.protocolProfileID == .openAIResponses)
        #expect(reconciled.chatEndpoint == .responses)
    }

    @Test
    func anthropicReconfigurationRoundTripPreservesMessagesProfile() throws {
        let provider = AgentSettingsProviderManifest(
            id: UUID(), name: "Anthropic API", baseURL: "https://api.anthropic.com/v1",
            chatEndpoint: .chatCompletions, providerProfileID: .anthropic,
            protocolProfileID: .anthropicMessages, authPolicy: .apiKeyRequired
        )
        let preservedProfile = ZenCODESetupRunner.reconciledProtocolProfileID(
            selectedEndpoint: provider.chatEndpoint,
            preferred: provider.protocolProfileID,
            previousEndpoint: provider.chatEndpoint
        )
        let reconfigured = AgentSettingsProviderManifest(
            id: provider.id, name: provider.name, baseURL: provider.baseURL,
            chatEndpoint: provider.chatEndpoint, providerProfileID: provider.providerProfileID,
            protocolProfileID: preservedProfile, authPolicy: provider.authPolicy
        )
        let restored = try JSONDecoder().decode(
            AgentSettingsProviderManifest.self,
            from: JSONEncoder().encode(reconfigured)
        )
        #expect(restored.protocolProfileID == .anthropicMessages)
        #expect(restored.remoteProvider(modelID: "claude-sonnet-4-5").protocolProfileID == .anthropicMessages)
    }

    // MARK: - Regression: a required API key cannot be cleared

    @Test
    func requiredAPIKeyReplacementPromptRefusesEmptyValues() {
        let required = ZenCODESetupRunner.replacementAPIKeyPromptContract(required: true)
        #expect(!required.allowEmpty)
        #expect(!required.label.contains("empty clears it"))
        #expect(required.help != nil)

        // Optional keys keep the documented clearing flow.
        let optional = ZenCODESetupRunner.replacementAPIKeyPromptContract(required: false)
        #expect(optional.allowEmpty)
        #expect(optional.label == "New API key (empty clears it)")
    }
}
