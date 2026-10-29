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
            id: preset.providerID, name: "Custom NVIDIA-shaped endpoint",
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
        let api = SetupProviderInput(
            id: SetupProviderPreset.openAIAPI.providerID,
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
            id: SetupProviderPreset.kimi.providerID,
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

    // MARK: - Stable provider keys

    @Test
    func everyPresetHasItsStableProviderKey() {
        let expected: [SetupProviderPreset: String] = [
            .openRouter: "openrouter",
            .openAIAPI: "openai",
            .anthropicAPI: "anthropic",
            .zaiAPI: "zai",
            .zaiCodingPlan: "zai-coding-plan",
            .gemini: "google.gemini",
            .deepSeek: "deepseek",
            .kimi: "moonshot",
            .nvidiaAPI: "nvidia",
            .modal: "modal",
            .custom: "custom"
        ]
        #expect(Set(expected.keys) == Set(SetupProviderPreset.allCases))
        for preset in SetupProviderPreset.allCases {
            #expect(preset.providerID == expected[preset])
            #expect(SetupProviderKind.remoteAPI(preset).providerID == expected[preset])
            #expect(AgentRemoteProvider.knownProviderIDs.contains(preset.providerID))
        }
        #expect(SetupProviderKind.chatGPTSubscription.providerID == "chatgpt")
        #expect(SetupProviderKind.anthropicSubscription.providerID == "claude")
        #expect(ZenCODESetupRunner.ds4SetupProviderID == "ds4")
        // Every key is unique and lowercase.
        let keys = SetupProviderPreset.allCases.map(\.providerID) + ["chatgpt", "claude", "ds4"]
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0 == $0.lowercased() })
        #expect(Set(keys) == AgentRemoteProvider.knownProviderIDs)
    }

    @Test
    func providerKeyDerivationIsTheSingleKeyTable() {
        #expect(AgentRemoteProvider.providerKey(providerProfileID: .openAI, protocolProfileID: .openAIChatGPTSubscription) == "chatgpt")
        #expect(AgentRemoteProvider.providerKey(providerProfileID: .anthropic, protocolProfileID: .anthropicClaudeSubscription) == "claude")
        #expect(AgentRemoteProvider.providerKey(providerProfileID: .zAI, protocolProfileID: .zaiCodingPlan) == "zai-coding-plan")
        #expect(AgentRemoteProvider.providerKey(providerProfileID: .zAI, protocolProfileID: .openAIChatCompletions) == "zai")
        #expect(AgentRemoteProvider.providerKey(providerProfileID: .ds4, protocolProfileID: .openAIChatCompletions) == "ds4")
        #expect(AgentRemoteProvider.providerKey(providerProfileID: .custom, protocolProfileID: .openAIResponses) == "custom")

        // A provider without an explicit id receives the derived key, never a
        // generated one; an explicit id is trimmed and lowercased.
        #expect(AgentRemoteProvider().id == "openrouter")
        #expect(AgentRemoteProvider(baseURL: "https://api.openai.com/v1").id == "openai")
        #expect(AgentRemoteProvider(baseURL: AgentRemoteProvider.chatGPTSubscriptionBaseURL).id == "chatgpt")
        #expect(AgentRemoteProvider(baseURL: "https://api.z.ai/api/coding/paas/v4").id == "zai-coding-plan")
        #expect(AgentRemoteProvider(baseURL: "http://127.0.0.1:9/v1").id == "custom")
        #expect(AgentRemoteProvider(id: "  OpenRouter ", baseURL: "https://example.test").id == "openrouter")
        #expect(AgentRemoteProvider(id: " ", baseURL: "https://api.deepseek.com/v1").id == "deepseek")
    }

    @Test
    func remoteAPIModelIDsUseTheProviderKey() {
        let model = AgentSettingsModelManifestFactory.remoteAPIModel(
            title: nil,
            modelID: "deepseek/deepseek-r1:free",
            providerID: "openrouter",
            providerName: "OpenRouter",
            baseURL: SetupProviderPreset.openRouter.baseURL,
            chatEndpoint: .chatCompletions,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingSupport: nil
        )
        #expect(model.id == "openrouter:deepseek/deepseek-r1:free")
        #expect(model.llmID == model.id)
        #expect(model.providerID == "openrouter")
        #expect(model.provider?.id == "openrouter")
        let scoped = AgentRemoteProvider.providerScopedModelID(model.id)
        #expect(scoped?.providerID == "openrouter")
        #expect(scoped?.modelID == "deepseek/deepseek-r1:free")
        #expect(AgentSettingsStore.isRemoteLLMIDSyntax(model.id))
        #expect(!AgentSettingsStore.isRemoteLLMIDSyntax("chatgpt:gpt-5"))
        #expect(!AgentSettingsStore.isRemoteLLMIDSyntax("ds4:deepseek-v4-flash"))
        #expect(!AgentSettingsStore.isRemoteLLMIDSyntax("deepseek-r1:free"))
    }

    @Test
    func alreadyConfiguredProvidersCannotBeAddedAgain() throws {
        let configured: Set<String> = ["openrouter", "chatgpt", "custom"]

        #expect(ZenCODESetupRunner.alreadyConfiguredProviderMessage(for: .remoteAPI(.openAIAPI), configuredProviderIDs: configured) == nil)
        #expect(ZenCODESetupRunner.alreadyConfiguredProviderMessage(for: .anthropicSubscription, configuredProviderIDs: configured) == nil)
        #expect(ZenCODESetupRunner.alreadyConfiguredProviderMessage(for: .remoteAPI(.zaiCodingPlan), configuredProviderIDs: ["zai"]) == nil)

        let openRouter = try #require(
            ZenCODESetupRunner.alreadyConfiguredProviderMessage(for: .remoteAPI(.openRouter), configuredProviderIDs: configured)
        )
        #expect(openRouter.contains("OpenRouter is already configured"))
        #expect(openRouter.contains("'openrouter'"))
        #expect(openRouter.contains("reconfigure it"))
        // Custom exists at most once, and so do the subscriptions.
        #expect(ZenCODESetupRunner.alreadyConfiguredProviderMessage(for: .remoteAPI(.custom), configuredProviderIDs: configured) != nil)
        let subscription = try #require(
            ZenCODESetupRunner.alreadyConfiguredProviderMessage(for: .chatGPTSubscription, configuredProviderIDs: configured)
        )
        #expect(subscription.contains("ChatGPT Subscription is already configured"))
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
            id: "anthropic", name: "Anthropic API", baseURL: "https://api.anthropic.com/v1",
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

    @Test
    func subscriptionCandidateDefaultsMatchExactlyOrFallBack() {
        let candidates = ["fixture-one", "fixture-two"].map { modelID in
            ZenCODESetupRunner.SubscriptionModelCandidate(
                manifestID: "chatgpt:\(modelID)", modelID: modelID, title: modelID,
                detail: "fixture", contextWindowTokenLimit: nil, thinkingSupport: nil
            )
        }
        let cases: [(String, String, Set<Int>)] = [("other", candidates[1].modelID, [1]), (candidates[1].manifestID, "other", [1]), ("other", candidates[1].modelID.uppercased(), [0])]
        for (id, modelID, expected) in cases {
            #expect(ZenCODESetupRunner.subscriptionModelSelectionDefaultIndexes(candidates: candidates, defaultModels: [subscriptionDefaultModel(id: id, modelID: modelID)]) == expected)
        }
        #expect(ZenCODESetupRunner.subscriptionModelSelectionDefaultIndexes(candidates: [], defaultModels: []).isEmpty)
    }

    private func subscriptionDefaultModel(id: String, modelID: String) -> AgentSettingsModelManifest {
        let provider = AgentRemoteProvider(name: "Test", baseURL: "https://example.test", modelID: modelID)
        return AgentSettingsModelManifest(id: id, kind: .remoteAPI, title: nil, llmID: id, modelID: modelID, providerID: provider.id, provider: provider, configuredContextWindowLimit: nil, generationParameterOverrides: nil, thinkingOptions: nil, defaultThinkingSelection: nil)
    }

}
