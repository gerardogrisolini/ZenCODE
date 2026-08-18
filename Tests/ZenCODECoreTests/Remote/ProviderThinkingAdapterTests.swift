//
//  ProviderThinkingAdapterTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct ProviderThinkingAdapterTests {
    private struct DialectCase: Sendable {
        let provider: AgentProviderProfileID
        let protocolProfile: AgentProtocolProfileID
        let model: String
        let expected: AgentThinkingPayloadStyle
    }

    @Test
    func dialectResolutionUsesProviderAndProtocolOnly() async {
        let cases: [DialectCase] = [
            .init(provider: .openRouter, protocolProfile: .openAIChatCompletions, model: "unlisted", expected: .openRouterReasoning),
            .init(provider: .openAI, protocolProfile: .openAIResponses, model: "unlisted", expected: .openAIResponsesReasoning),
            .init(provider: .zAI, protocolProfile: .zaiCodingPlan, model: "unlisted", expected: .reasoningEffort),
            .init(provider: .googleGemini, protocolProfile: .openAIChatCompletions, model: "unlisted", expected: .reasoningEffort),
            .init(provider: .moonshot, protocolProfile: .openAIChatCompletions, model: "unlisted", expected: .reasoningEffort),
            .init(provider: .deepSeek, protocolProfile: .openAIChatCompletions, model: "unlisted", expected: .thinkingObject(supportsDisable: true, keepAll: false)),
            .init(provider: .nvidia, protocolProfile: .openAIChatCompletions, model: "unlisted", expected: .chatTemplateKwargs),
            .init(provider: .modal, protocolProfile: .openAIChatCompletions, model: "unlisted", expected: .chatTemplateKwargs),
            .init(provider: .custom, protocolProfile: .openAIChatCompletions, model: "unlisted", expected: .none)
        ]
        for testCase in cases {
            let client = client(provider: testCase.provider, protocolProfile: testCase.protocolProfile, model: testCase.model)
            #expect(await client.thinkingPayloadStyle == testCase.expected)
        }
    }

    @Test
    func thinkingPayloadSnapshots() async {
        let cases: [(AgentProviderProfileID, AgentProtocolProfileID, AgentThinkingSelection, String)] = [
            (.openRouter, .openAIChatCompletions, .off, #"{"reasoning":{"effort":"none","exclude":false}}"#),
            (.openAI, .openAIResponses, .high, #"{"reasoning":{"effort":"high","summary":"auto"}}"#),
            (.zAI, .zaiCodingPlan, .off, #"{"reasoning_effort":"none"}"#),
            (.googleGemini, .openAIChatCompletions, .medium, #"{"reasoning_effort":"medium"}"#),
            (.moonshot, .openAIChatCompletions, .enabled, #"{"reasoning_effort":"enabled"}"#),
            (.deepSeek, .openAIChatCompletions, .enabled, #"{"thinking":{"type":"enabled"}}"#),
            (.nvidia, .openAIChatCompletions, .high, #"{"chat_template_kwargs":{"enable_thinking":true,"reasoning_effort":"high","thinking":true}}"#),
            (.modal, .openAIChatCompletions, .off, #"{"chat_template_kwargs":{"enable_thinking":false,"thinking":false}}"#),
            (.custom, .openAIChatCompletions, .high, "{}")
        ]
        for (provider, protocolProfile, selection, expected) in cases {
            let client = client(provider: provider, protocolProfile: protocolProfile, model: "unlisted")
            #expect(await client.thinkingPayloadSnapshot(selection, endpoint: protocolProfile.chatEndpoint ?? .chatCompletions) == expected)
        }
    }

    @Test
    func legacyNVIDIAAndModalProvidersMigrateToExplicitChatTemplateProfiles() throws {
        func decode(baseURL: String) throws -> AgentRemoteProvider {
            let json: [String: Any] = [
                "id": UUID().uuidString,
                "name": "Legacy hosted provider",
                "baseURL": baseURL,
                "modelID": "vendor/model",
                "chatEndpoint": "chat_completions"
            ]
            return try JSONDecoder().decode(
                AgentRemoteProvider.self,
                from: JSONSerialization.data(withJSONObject: json)
            )
        }

        let nvidia = try decode(baseURL: "https://integrate.api.nvidia.com/v1")
        let modal = try decode(baseURL: "https://api.us-west-2.modal.direct/v1")
        #expect(nvidia.providerProfileID == .nvidia)
        #expect(modal.providerProfileID == .modal)
        #expect(nvidia.protocolProfileID == .openAIChatCompletions)
        #expect(modal.protocolProfileID == .openAIChatCompletions)
        #expect(nvidia.authPolicy == .apiKeyRequired)
        #expect(modal.authPolicy == .apiKeyRequired)
    }

    @Test
    func manifestLevelsAreTheOnlyThinkingAuthorization() async {
        let client = client(provider: .openAI, protocolProfile: .openAIResponses, model: "unlisted", thinkingOptions: [.off, .low])
        #expect(await client.thinkingPayloadSnapshot(.low, endpoint: .responses) == #"{"reasoning":{"effort":"low","summary":"auto"}}"#)
        #expect(await client.thinkingPayloadSnapshot(.high, endpoint: .responses) == "{}")
    }

    @Test
    func deepSeekDoesNotSerializeOffUnlessManifestAllowsIt() async {
        let alwaysOn = client(
            provider: .deepSeek,
            protocolProfile: .openAIChatCompletions,
            model: "deepseek-reasoner",
            thinkingOptions: [.enabled]
        )
        #expect(await alwaysOn.thinkingPayloadStyle == .thinkingObject(
            supportsDisable: false,
            keepAll: false
        ))
        #expect(await alwaysOn.thinkingPayloadSnapshot(.off, endpoint: .chatCompletions) == "{}")

        let configurable = client(
            provider: .deepSeek,
            protocolProfile: .openAIChatCompletions,
            model: "deepseek-chat",
            thinkingOptions: [.off, .enabled]
        )
        #expect(await configurable.thinkingPayloadSnapshot(.off, endpoint: .chatCompletions)
            == #"{"thinking":{"type":"disabled"}}"#)
    }

    @Test
    func genericEnabledIsSerializedWithoutInferringAnEffortLevel() async {
        let client = client(
            provider: .moonshot,
            protocolProfile: .openAIChatCompletions,
            model: "kimi",
            thinkingOptions: [.enabled, .low, .max]
        )
        #expect(await client.thinkingPayloadSnapshot(.enabled, endpoint: .chatCompletions)
            == #"{"reasoning_effort":"enabled"}"#)
    }

    // MARK: - Regression: empty or `.enabled`-less manifest options must not
    // silently drop the thinking payload (52428e3 gate).

    @Test
    func fallbackModelsWithoutThinkingOptionsStillSendTheThinkingPayload() async {
        let client = client(
            provider: .moonshot,
            protocolProfile: .openAIChatCompletions,
            model: "fallback-kimi",
            thinkingOptions: []
        )
        #expect(await client.thinkingPayloadSnapshot(.enabled, endpoint: .chatCompletions)
            == #"{"reasoning_effort":"enabled"}"#)
        #expect(await client.thinkingPayloadSnapshot(.high, endpoint: .chatCompletions)
            == #"{"reasoning_effort":"high"}"#)
    }

    @Test
    func enabledSelectionMapsToClosestAllowedEffortWhenOptionsAreKnown() async {
        let preferred = client(
            provider: .openAI,
            protocolProfile: .openAIResponses,
            model: "gpt-fallback",
            thinkingOptions: [.off, .low, .medium, .high]
        )
        #expect(await preferred.thinkingPayloadSnapshot(.enabled, endpoint: .responses)
            == #"{"reasoning":{"effort":"medium","summary":"auto"}}"#)

        let declaredOrder = client(
            provider: .zAI,
            protocolProfile: .openAIChatCompletions,
            model: "glm",
            thinkingOptions: [.off, .low]
        )
        #expect(await declaredOrder.thinkingPayloadSnapshot(.enabled, endpoint: .chatCompletions)
            == #"{"reasoning_effort":"low"}"#)
    }

    @Test
    func explicitlyUnsupportedSelectionsRemainDroppedWhenOptionsAreKnown() async {
        let restricted = client(
            provider: .openAI,
            protocolProfile: .openAIResponses,
            model: "gpt-restricted",
            thinkingOptions: [.off, .low]
        )
        #expect(await restricted.thinkingPayloadSnapshot(.ultra, endpoint: .responses) == "{}")

        let offOnly = client(
            provider: .deepSeek,
            protocolProfile: .openAIChatCompletions,
            model: "deepseek-reasoner",
            thinkingOptions: [.off]
        )
        #expect(await offOnly.thinkingPayloadSnapshot(.enabled, endpoint: .chatCompletions) == "{}")
    }

    @Test
    func providersWithoutThinkingDialectStillDropSilently() async {
        let client = client(
            provider: .custom,
            protocolProfile: .openAIChatCompletions,
            model: "legacy",
            thinkingOptions: [.enabled]
        )
        #expect(await client.thinkingPayloadSnapshot(.enabled, endpoint: .chatCompletions) == "{}")
    }

    @Test
    func kimiReplayPreservesEveryAssistantReasoningMessage() {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "first"],
            ["role": "assistant", "content": "answer", "reasoning_content": "old reasoning"],
            ["role": "user", "content": "second"]
        ]

        let replay = RemoteGenerationClient.chatCompletionsWireHistoryMessages(
            from: messages,
            replayPolicy: .preserveAllAssistantReasoning
        )
        #expect(replay[1]["reasoning_content"] as? String == "old reasoning")

        let failClosed = RemoteGenerationClient.chatCompletionsWireHistoryMessages(
            from: messages,
            replayPolicy: .stripReasoning
        )
        #expect(failClosed[1]["reasoning_content"] == nil)
    }

    @Test
    func kimiChoiceUsageAndCachedTokensAreParsed() throws {
        let events = ChatCompletionsStreamParser.parse([
            "choices": [[
                "delta": ["reasoning_content": "thought"],
                "usage": [
                    "prompt_tokens": 100,
                    "completion_tokens": 20,
                    "cached_tokens": 70
                ]
            ]]
        ])

        let usage = try #require(events.compactMap { event -> RemoteGenerationUsage? in
            if case let .usage(value) = event { return value }
            return nil
        }.first)
        #expect(usage.promptTokens == 100)
        #expect(usage.completionTokens == 20)
        #expect(usage.cachedPromptTokens == 70)
        #expect(events.contains { event in
            if case let .reasoning(text) = event { return text == "thought" }
            return false
        })
    }

    private func client(
        provider: AgentProviderProfileID,
        protocolProfile: AgentProtocolProfileID,
        model: String,
        thinkingOptions: [AgentThinkingSelection] = AgentThinkingSelection.allCases
    ) -> RemoteGenerationClient {
        RemoteGenerationClient(
            configuration: AgentRuntimeConfiguration(
                modelID: model,
                workingDirectory: URL(fileURLWithPath: "/tmp/provider-adapter-tests", isDirectory: true),
                maxToolRounds: 1,
                verboseLogging: false,
                toolAuthorizationHandler: nil
            ),
            provider: AgentRemoteProvider(
                name: "Adapter test",
                baseURL: "https://unit.test/v1",
                modelID: model,
                chatEndpoint: protocolProfile.chatEndpoint ?? .chatCompletions,
                providerProfileID: provider,
                protocolProfileID: protocolProfile,
                authPolicy: protocolProfile == .zaiCodingPlan ? .apiKeyRequired : .apiKeyOptional
            ),
            apiKey: nil,
            thinkingOptions: thinkingOptions
        )
    }
}

private extension RemoteGenerationClient {
    func thinkingPayloadSnapshot(
        _ selection: AgentThinkingSelection,
        endpoint: AgentRemoteChatEndpoint
    ) -> String {
        var body: [String: Any] = [:]
        applyThinkingSelection(selection, endpoint: endpoint, to: &body)
        let data = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}


extension RemoteSessionSnapshotTests {
    @Test
    func kimiK26RequestUsesDocumentedCacheTokenAndThinkingFields() async throws {        let response = """
        data: {"choices":[{"delta":{"reasoning_content":"thought"}}]}

        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let fixture = try await RemoteNIOStreamingFixture.start(responseBody: Data(response.utf8))
        defer { fixture.beginShutdown() }
        let configuration = AgentRuntimeConfiguration(
            modelID: "kimi-k2.6",
            workingDirectory: URL(fileURLWithPath: "/tmp/provider-adapter-tests", isDirectory: true),
            maxToolRounds: 1,
            maxOutputTokens: 2048,
            verboseLogging: false,
            toolAuthorizationHandler: nil
        )
        let client = RemoteGenerationClient(
            configuration: configuration,
            provider: AgentRemoteProvider(
                name: "Kimi API",
                baseURL: "https://api.moonshot.ai/v1",
                modelID: "kimi-k2.6",
                chatEndpoint: .chatCompletions,
                providerProfileID: .moonshot,
                protocolProfileID: .openAIChatCompletions,
                authPolicy: .apiKeyRequired
            ),
            apiKey: "test-key",
            thinkingOptions: [.enabled],
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )

        _ = try await client.streamChatCompletions(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "kimi-session",
            allowedToolNames: [],
            thinkingSelection: .enabled,
            onEvent: { _ in }
        )
        let request = try #require(fixture.capturedRequests().first)
        let body = try request.jsonObject()
        #expect(body["reasoning_effort"] as? String == "enabled")
        #expect(body["prompt_cache_key"] as? String == "kimi-session")
        #expect(RemoteGenerationClient.integerValue(body["max_completion_tokens"]) == 2048)
        #expect(body["max_tokens"] == nil)
        #expect(body["session_id"] == nil)
    }

    @Test
    func kimiRequiresDoneMarker() async throws {
        let response = """
        data: {"choices":[{"delta":{"content":"partial"}}]}

        """
        let fixture = try await RemoteNIOStreamingFixture.start(responseBody: Data(response.utf8))
        defer { fixture.beginShutdown() }
        let client = RemoteGenerationClient(
            configuration: AgentRuntimeConfiguration(
                modelID: "kimi-k3",
                workingDirectory: URL(fileURLWithPath: "/tmp/provider-adapter-tests", isDirectory: true),
                maxToolRounds: 1,
                verboseLogging: false,
                toolAuthorizationHandler: nil
            ),
            provider: AgentRemoteProvider(
                name: "Kimi API",
                baseURL: "https://api.moonshot.ai/v1",
                modelID: "kimi-k3",
                chatEndpoint: .chatCompletions,
                providerProfileID: .moonshot,
                protocolProfileID: .openAIChatCompletions,
                authPolicy: .apiKeyRequired
            ),
            apiKey: "test-key",
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )

        await #expect(throws: RemoteGenerationClientError.self) {
            _ = try await client.streamChatCompletions(
                messages: [["role": "user", "content": "hi"]],
                sessionID: "kimi-incomplete",
                allowedToolNames: [],
                thinkingSelection: .high,
                onEvent: { _ in }
            )
        }
    }

    // MARK: - Regression: OpenAI Chat reasoning models use max_completion_tokens

    private func openAIChatCompletionRequestBody(
        model: String,
        maxOutputTokens: Int?,
        thinkingOptions: [AgentThinkingSelection]
    ) async throws -> [String: Any] {
        let response = """
        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let fixture = try await RemoteNIOStreamingFixture.start(responseBody: Data(response.utf8))
        defer { fixture.beginShutdown() }
        let client = RemoteGenerationClient(
            configuration: AgentRuntimeConfiguration(
                modelID: model,
                workingDirectory: URL(fileURLWithPath: "/tmp/provider-adapter-tests", isDirectory: true),
                maxToolRounds: 1,
                maxOutputTokens: maxOutputTokens,
                verboseLogging: false,
                toolAuthorizationHandler: nil
            ),
            provider: AgentRemoteProvider(
                name: "OpenAI API",
                baseURL: "https://api.openai.com/v1",
                modelID: model,
                chatEndpoint: .chatCompletions,
                providerProfileID: .openAI,
                protocolProfileID: .openAIChatCompletions,
                authPolicy: .apiKeyRequired
            ),
            apiKey: "test-key",
            thinkingOptions: thinkingOptions,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )

        _ = try await client.streamChatCompletions(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "openai-session",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { _ in }
        )
        let request = try #require(fixture.capturedRequests().first)
        return try request.jsonObject()
    }

    @Test
    func openAIChatReasoningModelSendsMaxCompletionTokens() async throws {
        let body = try await openAIChatCompletionRequestBody(
            model: "gpt-5.4",
            maxOutputTokens: 2048,
            thinkingOptions: [.high]
        )

        #expect(RemoteGenerationClient.integerValue(body["max_completion_tokens"]) == 2048)
        #expect(body["max_tokens"] == nil)
    }

    @Test
    func openAIChatNonReasoningModelKeepsLegacyMaxTokens() async throws {
        let body = try await openAIChatCompletionRequestBody(
            model: "gpt-4.1",
            maxOutputTokens: 1024,
            thinkingOptions: []
        )

        #expect(RemoteGenerationClient.integerValue(body["max_tokens"]) == 1024)
        #expect(body["max_completion_tokens"] == nil)
    }

    // MARK: - Regression: noAuthentication suppresses any residual bearer key

    @Test
    func noAuthenticationPolicySuppressesResidualBearerWithoutTouchingStoredData() async throws {
        let response = """
        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let fixture = try await RemoteNIOStreamingFixture.start(responseBody: Data(response.utf8))
        defer { fixture.beginShutdown() }
        let residualKey = "stale-key-still-persisted"
        let client = RemoteGenerationClient(
            configuration: AgentRuntimeConfiguration(
                modelID: "local-model",
                workingDirectory: URL(fileURLWithPath: "/tmp/provider-adapter-tests", isDirectory: true),
                maxToolRounds: 1,
                verboseLogging: false,
                toolAuthorizationHandler: nil
            ),
            provider: AgentRemoteProvider(
                name: "Local server",
                baseURL: "http://localhost:8080/v1",
                modelID: "local-model",
                chatEndpoint: .chatCompletions,
                providerProfileID: .custom,
                protocolProfileID: .openAIChatCompletions,
                authPolicy: .noAuthentication
            ),
            apiKey: residualKey,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )

        _ = try await client.streamChatCompletions(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "noauth-session",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { _ in }
        )
        let request = try #require(fixture.capturedRequests().first)
        #expect(!request.headerEntries.contains { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame })

        // Control: optional-key providers still send their bearer, and the
        // suppressed key object itself is never mutated or cleared.
        let controlFixture = try await RemoteNIOStreamingFixture.start(responseBody: Data(response.utf8))
        defer { controlFixture.beginShutdown() }
        let controlClient = RemoteGenerationClient(
            configuration: AgentRuntimeConfiguration(
                modelID: "optional-model",
                workingDirectory: URL(fileURLWithPath: "/tmp/provider-adapter-tests", isDirectory: true),
                maxToolRounds: 1,
                verboseLogging: false,
                toolAuthorizationHandler: nil
            ),
            provider: AgentRemoteProvider(
                name: "Optional server",
                baseURL: "http://localhost:8080/v1",
                modelID: "optional-model",
                chatEndpoint: .chatCompletions,
                providerProfileID: .custom,
                protocolProfileID: .openAIChatCompletions,
                authPolicy: .apiKeyOptional
            ),
            apiKey: "optional-key",
            transport: controlFixture.transport,
            streamEndpointBaseURLOverride: controlFixture.baseURL
        )
        _ = try await controlClient.streamChatCompletions(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "optional-session",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { _ in }
        )
        let controlRequest = try #require(controlFixture.capturedRequests().first)
        #expect(controlRequest.headerEntries.contains {
            $0.name.caseInsensitiveCompare("Authorization") == .orderedSame
                && $0.value == "Bearer optional-key"
        })
        #expect(residualKey == "stale-key-still-persisted")
    }
}
