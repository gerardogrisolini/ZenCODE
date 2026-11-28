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
            .xaiAPI: (
                "Grok API (xAI)",
                "https://api.x.ai/v1",
                .xAI,
                .openAIChatCompletions
            ),
            .kimiCode: (
                "Kimi Code",
                "https://api.kimi.ai/coding/v1",
                .moonshot,
                .kimiCode
            ),
            .qwenAPI: (
                "Qwen API (QwenCloud)",
                "https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1",
                .qwen,
                .openAIChatCompletions
            ),
            .qwenTokenPlan: (
                "Qwen Token Plan",
                "https://token-plan.maas.qwencloudapi.com/compatible-mode/v1",
                .qwen,
                .qwenTokenPlan
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
            .xaiAPI: "xai",
            .kimi: "moonshot",
            .kimiCode: "kimi-code",
            .zaiAPI: "zai",
            .zaiCodingPlan: "zai-coding-plan",
            .qwenAPI: "qwen",
            .qwenTokenPlan: "qwen-token-plan",
            .gemini: "google.gemini",
            .deepSeek: "deepseek",
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
        #expect(AgentRemoteProvider.providerKey(providerProfileID: .moonshot, protocolProfileID: .kimiCode) == "kimi-code")
        #expect(AgentRemoteProvider.providerKey(providerProfileID: .moonshot, protocolProfileID: .openAIChatCompletions) == "moonshot")
        #expect(AgentRemoteProvider.providerKey(providerProfileID: .qwen, protocolProfileID: .qwenTokenPlan) == "qwen-token-plan")
        #expect(AgentRemoteProvider.providerKey(providerProfileID: .qwen, protocolProfileID: .openAIChatCompletions) == "qwen")
        #expect(AgentRemoteProvider.providerKey(providerProfileID: .xAI, protocolProfileID: .openAIChatCompletions) == "xai")
        #expect(AgentRemoteProvider.kimiCodeProviderID == "kimi-code")
        #expect(AgentRemoteProvider.qwenTokenPlanProviderID == "qwen-token-plan")
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
    func anthropicDirectAPIHasNativeMessagesPresetDistinctFromSubscription() {
        #expect(SetupProviderKind.remoteAPI(.anthropicAPI) != .anthropicSubscription)
        let preset = SetupProviderPreset.anthropicAPI
        #expect(SetupProviderPreset.allCases.contains(preset))
        #expect(preset.title == "Anthropic API")
        #expect(preset.baseURL == "https://api.anthropic.com/v1")
        #expect(preset.providerProfileID == .anthropic)
        #expect(preset.protocolProfileID == .anthropicMessages)
        #expect(preset.authPolicy == .apiKeyRequired)
    }

    // MARK: - Provider menu structure

    private struct MenuRow<Value: Hashable>: Equatable {
        let value: Value
        let title: String
        let detail: String?
    }

    private static func rows<Value: Hashable>(
        _ items: [TerminalCheckboxMenuItem<Value>]
    ) -> [MenuRow<Value>] {
        items.map { MenuRow(value: $0.value, title: $0.title, detail: $0.detail) }
    }

    @Test
    func providerFamilyPageListsSubscriptionFamiliesThenOtherAPIProviders() {
        #expect(SetupProviderFamily.allCases == [.openAI, .anthropic, .kimi, .zAI, .qwen, .otherAPI])
        let items = ZenCODESetupRunner.providerFamilyMenuItems()
        #expect(Self.rows(items) == [
            MenuRow(value: .openAI, title: "OpenAI", detail: "OpenAI API or ChatGPT Subscription"),
            MenuRow(value: .anthropic, title: "Anthropic", detail: "Anthropic API status or Claude Subscription"),
            MenuRow(value: .kimi, title: "Kimi", detail: "Kimi API (Moonshot AI) or Kimi Code membership"),
            MenuRow(value: .zAI, title: "Z.ai", detail: "Z.ai API or Z.ai Coding Plan"),
            MenuRow(value: .qwen, title: "Qwen", detail: "Qwen API (QwenCloud) or Qwen Token Plan"),
            MenuRow(value: .otherAPI, title: "Other API providers", detail: "hosted presets and advanced Custom setup")
        ])
    }

    @Test
    func providerFamilySubmenusListTheirChoicesInOrder() {
        let hosted = "hosted API preset; API key required"
        let browser = "browser sign-in; separate credentials and provider key"
        let expected: [SetupProviderFamily: (title: String, rows: [MenuRow<SetupProviderKind>])] = [
            .openAI: ("OpenAI", [
                MenuRow(value: .remoteAPI(.openAIAPI), title: "OpenAI API", detail: "API key; OpenAI Responses protocol"),
                MenuRow(value: .chatGPTSubscription, title: "ChatGPT Subscription", detail: browser)
            ]),
            .anthropic: ("Anthropic", [
                MenuRow(value: .remoteAPI(.anthropicAPI), title: "Anthropic API", detail: "API key; native Messages protocol"),
                MenuRow(value: .anthropicSubscription, title: "Claude Subscription", detail: browser)
            ]),
            .kimi: ("Kimi", [
                MenuRow(value: .remoteAPI(.kimi), title: "Kimi API (Moonshot AI)", detail: "pay-as-you-go API key from the Kimi platform"),
                MenuRow(value: .remoteAPI(.kimiCode), title: "Kimi Code", detail: "Kimi membership; API key from the Kimi Code console")
            ]),
            .zAI: ("Z.ai", [
                MenuRow(value: .remoteAPI(.zaiAPI), title: "Z.ai API", detail: "pay-as-you-go API key"),
                MenuRow(value: .remoteAPI(.zaiCodingPlan), title: "Z.ai Coding Plan", detail: "Coding Plan subscription; plan API key")
            ]),
            .qwen: ("Qwen", [
                MenuRow(value: .remoteAPI(.qwenAPI), title: "Qwen API (QwenCloud)", detail: "pay-as-you-go API key; Singapore region"),
                MenuRow(value: .remoteAPI(.qwenTokenPlan), title: "Qwen Token Plan", detail: "Token Plan subscription; plan API key (sk-sp-)")
            ]),
            .otherAPI: ("API provider preset", [
                MenuRow(value: .remoteAPI(.openRouter), title: "OpenRouter", detail: hosted),
                MenuRow(value: .remoteAPI(.xaiAPI), title: "Grok API (xAI)", detail: "API key; pay-as-you-go xAI API"),
                MenuRow(value: .remoteAPI(.gemini), title: "Gemini", detail: hosted),
                MenuRow(value: .remoteAPI(.deepSeek), title: "DeepSeek", detail: hosted),
                MenuRow(value: .remoteAPI(.nvidiaAPI), title: "NVIDIA API", detail: hosted),
                MenuRow(value: .remoteAPI(.modal), title: "Modal", detail: hosted),
                MenuRow(
                    value: .remoteAPI(.custom),
                    title: "Custom",
                    detail: "advanced OpenAI-compatible setup; optional auth, fail-closed protocol selection"
                )
            ])
        ]
        #expect(Set(expected.keys) == Set(SetupProviderFamily.allCases))
        for family in SetupProviderFamily.allCases {
            let items = ZenCODESetupRunner.providerKindMenuItems(for: family, configuredProviderIDs: [])
            #expect(family.submenuTitle == expected[family]?.title)
            #expect(Self.rows(items) == expected[family]?.rows)
            #expect(items.map(\.value) == family.kinds)
            #expect(
                ZenCODESetupRunner.preferredProviderKind(in: family, configuredProviderIDs: [])
                    == family.kinds.first
            )
        }
    }

    @Test
    func everyProviderChoiceBelongsToExactlyOneFamily() {
        let allKinds = SetupProviderFamily.allCases.flatMap(\.kinds)
        #expect(allKinds.count == Set(allKinds).count)
        for preset in SetupProviderPreset.allCases {
            let families = SetupProviderFamily.allCases.filter { $0.kinds.contains(.remoteAPI(preset)) }
            #expect(families == [preset.family])
        }
        #expect(allKinds.count == SetupProviderPreset.allCases.count + 2)
        #expect(SetupProviderFamily.allCases.filter { $0.kinds.contains(.chatGPTSubscription) } == [.openAI])
        #expect(SetupProviderFamily.allCases.filter { $0.kinds.contains(.anthropicSubscription) } == [.anthropic])
        #expect(SetupProviderFamily.otherAPI.kinds == SetupProviderPreset.allCases
            .filter { $0.family == .otherAPI }
            .map(SetupProviderKind.remoteAPI))
    }

    @Test
    func configuredProviderChoicesAreMarkedInTheirSubmenu() {
        let configured: Set<String> = ["openai", "xai", "kimi-code", "zai", "qwen", "qwen-token-plan", "openrouter"]
        let alreadyConfigured = ZenCODESetupRunner.alreadyConfiguredProviderDetail

        // Page 1 keeps the family details: every family opens a submenu.
        for item in ZenCODESetupRunner.providerFamilyMenuItems() {
            #expect(item.detail == item.value.detail)
        }

        // Page 2 marks every configured choice and preselects the first
        // choice that is not configured, otherwise the first one.
        for family in SetupProviderFamily.allCases {
            let items = ZenCODESetupRunner.providerKindMenuItems(for: family, configuredProviderIDs: configured)
            for item in items {
                #expect(item.detail == (configured.contains(item.value.providerID) ? alreadyConfigured : item.value.menuDetail))
            }
        }
        let preferred: [SetupProviderFamily: SetupProviderKind] = [
            .openAI: .chatGPTSubscription,
            .anthropic: .remoteAPI(.anthropicAPI),
            .kimi: .remoteAPI(.kimi),
            .zAI: .remoteAPI(.zaiCodingPlan),
            .qwen: .remoteAPI(.qwenAPI),
            .otherAPI: .remoteAPI(.gemini)
        ]
        for family in SetupProviderFamily.allCases {
            #expect(
                ZenCODESetupRunner.preferredProviderKind(in: family, configuredProviderIDs: configured)
                    == preferred[family]
            )
        }
    }

    @Test
    func grokIsChosenFromTheAPIProviderPresetSubmenu() throws {
        var presentedTitles: [String] = []
        var presentedRows: [MenuRow<SetupProviderFamily>] = []
        var preselections: [SetupProviderFamily] = []
        var openedFamilies: [SetupProviderFamily] = []
        let kind = try ZenCODESetupRunner.promptProviderKind(
            configuredProviderIDs: ["openai"],
            selectFamily: { title, items, selected in
                presentedTitles.append(title)
                presentedRows = Self.rows(items)
                preselections.append(selected)
                return .otherAPI
            },
            promptKind: { family in
                openedFamilies.append(family)
                #expect(family.kinds.contains(.remoteAPI(.xaiAPI)))
                return .remoteAPI(.xaiAPI)
            }
        )
        #expect(kind == .remoteAPI(.xaiAPI))
        #expect(presentedTitles == ["Provider family"])
        #expect(preselections == [.openAI])
        #expect(openedFamilies == [.otherAPI])
        #expect(presentedRows == Self.rows(ZenCODESetupRunner.providerFamilyMenuItems()))
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
}
