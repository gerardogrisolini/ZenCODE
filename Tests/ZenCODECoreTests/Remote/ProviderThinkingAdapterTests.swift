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
    func dialectResolutionIsExplicitAndModelAware() async {
        let cases: [DialectCase] = [
            .init(provider: .openRouter, protocolProfile: .openAIChatCompletions, model: "vendor/model", expected: .openRouterReasoning),
            .init(provider: .openAI, protocolProfile: .openAIResponses, model: "gpt-5.4", expected: .openAIResponsesReasoning(allowed: [.off, .low, .medium, .high, .xhigh])),
            .init(provider: .openAI, protocolProfile: .openAIResponses, model: "gpt-5.6-terra", expected: .openAIResponsesReasoning(allowed: [.off, .low, .medium, .high, .xhigh, .max, .ultra])),
            .init(provider: .openAI, protocolProfile: .openAIResponses, model: "gpt-5.6-luna", expected: .openAIResponsesReasoning(allowed: [.off, .low, .medium, .high, .xhigh, .max])),
            .init(provider: .openAI, protocolProfile: .openAIResponses, model: "o3-mini", expected: .openAIResponsesReasoning(allowed: [.off, .low, .medium, .high])),
            .init(provider: .openAI, protocolProfile: .openAIResponses, model: "gpt-4.1", expected: .none),
            .init(provider: .openAI, protocolProfile: .openAIResponses, model: "o1-preview", expected: .openAIResponsesReasoning(allowed: [.off, .low, .medium, .high])),
            .init(provider: .openAI, protocolProfile: .openAIChatCompletions, model: "gpt-5.4", expected: .reasoningEffort(allowed: [.off, .minimal, .low, .medium, .high, .xhigh])),
            .init(provider: .openAI, protocolProfile: .openAIChatCompletions, model: "gpt-4.1", expected: .none),
            .init(provider: .zAI, protocolProfile: .openAIChatCompletions, model: "glm-4.7", expected: .thinkingObject(supportsDisable: true, keepAll: false)),
            .init(provider: .zAI, protocolProfile: .openAIChatCompletions, model: "glm-5", expected: .reasoningEffort(allowed: [.low, .medium, .high])),
            .init(provider: .zAI, protocolProfile: .zaiCodingPlan, model: "glm-4.7", expected: .thinkingObject(supportsDisable: true, keepAll: false)),
            .init(provider: .zAI, protocolProfile: .zaiCodingPlan, model: "glm-5-air", expected: .reasoningEffort(allowed: [.low, .medium, .high])),
            .init(provider: .googleGemini, protocolProfile: .openAIChatCompletions, model: "gemini-3-pro-preview", expected: .reasoningEffort(allowed: [.low, .medium, .high])),
            .init(provider: .deepSeek, protocolProfile: .openAIChatCompletions, model: "deepseek-reasoner", expected: .alwaysOn),
            .init(provider: .moonshot, protocolProfile: .openAIChatCompletions, model: "kimi-k3", expected: .reasoningEffort(allowed: [.low, .high, .max])),
            .init(provider: .moonshot, protocolProfile: .openAIChatCompletions, model: "kimi-k2.7-code", expected: .alwaysOn),
            .init(provider: .moonshot, protocolProfile: .openAIChatCompletions, model: "kimi-k2.6", expected: .thinkingObject(supportsDisable: true, keepAll: true)),
            .init(provider: .nvidia, protocolProfile: .openAIChatCompletions, model: "nvidia/model", expected: .chatTemplateKwargs),
            .init(provider: .modal, protocolProfile: .openAIChatCompletions, model: "vendor/model", expected: .chatTemplateKwargs),
            .init(provider: .custom, protocolProfile: .openAIChatCompletions, model: "kimi-k3", expected: .none),
            .init(provider: .moonshot, protocolProfile: .openAIChatCompletions, model: "unknown", expected: .none)
        ]

        for testCase in cases {
            let client = client(
                provider: testCase.provider,
                protocolProfile: testCase.protocolProfile,
                model: testCase.model
            )
            #expect(await client.thinkingPayloadStyle == testCase.expected)
        }
    }

    @Test
    func thinkingPayloadSnapshots() async {
        let cases: [(AgentProviderProfileID, AgentProtocolProfileID, String, AgentThinkingSelection, String)] = [
            (.openRouter, .openAIChatCompletions, "vendor/model", .high, #"{"reasoning":{"effort":"high","exclude":false}}"#),
            (.openAI, .openAIResponses, "gpt-5.4", .high, #"{"reasoning":{"effort":"high","summary":"auto"}}"#),
            (.openAI, .openAIResponses, "gpt-5.4", .off, #"{"reasoning":{"effort":"none"}}"#),
            (.openAI, .openAIResponses, "gpt-5.6-luna", .ultra, "{}"),
            (.openAI, .openAIResponses, "gpt-5.4", .ultra, "{}"),
            (.openAI, .openAIResponses, "o3-mini", .xhigh, "{}"),
            (.openAI, .openAIResponses, "gpt-4.1", .high, "{}"),
            (.openAI, .openAIChatCompletions, "gpt-5.4", .high, #"{"reasoning_effort":"high"}"#),
            (.zAI, .openAIChatCompletions, "glm-4.7", .off, #"{"thinking":{"type":"disabled"}}"#),
            (.zAI, .zaiCodingPlan, "glm-4.7", .off, #"{"thinking":{"type":"disabled"}}"#),
            (.googleGemini, .openAIChatCompletions, "gemini-3-pro-preview", .medium, #"{"reasoning_effort":"medium"}"#),
            (.deepSeek, .openAIChatCompletions, "deepseek-chat", .enabled, #"{"thinking":{"type":"enabled"}}"#),
            (.moonshot, .openAIChatCompletions, "kimi-k3", .enabled, #"{"reasoning_effort":"max"}"#),
            (.moonshot, .openAIChatCompletions, "kimi-k2.7-code", .high, "{}"),
            (.moonshot, .openAIChatCompletions, "kimi-k2.6", .enabled, #"{"thinking":{"keep":"all","type":"enabled"}}"#),
            (.nvidia, .openAIChatCompletions, "nvidia/model", .high, #"{"chat_template_kwargs":{"enable_thinking":true,"reasoning_effort":"high","thinking":true}}"#),
            (.modal, .openAIChatCompletions, "vendor/model", .off, #"{"chat_template_kwargs":{"enable_thinking":false,"thinking":false}}"#),
            (.custom, .openAIChatCompletions, "vendor/model", .high, "{}")
        ]

        for (provider, protocolProfile, model, selection, expected) in cases {
            let client = client(provider: provider, protocolProfile: protocolProfile, model: model)
            let body = await client.thinkingPayloadSnapshot(selection, endpoint: protocolProfile.chatEndpoint ?? .chatCompletions)
            #expect(body == expected)
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
    func responsesReasoningAllowedSelectionsFollowTheModelRegistry() throws {
        let terra = RemoteGenerationClient.openAIResponsesReasoningAllowedSelections(for: "gpt-5.6-terra")
        #expect(terra == [.off, .low, .medium, .high, .xhigh, .max, .ultra])

        let luna = RemoteGenerationClient.openAIResponsesReasoningAllowedSelections(for: "gpt-5.6-luna")
        #expect(luna == [.off, .low, .medium, .high, .xhigh, .max])

        let oSeries = RemoteGenerationClient.openAIResponsesReasoningAllowedSelections(for: "o4-mini")
        #expect(oSeries == [.off, .low, .medium, .high])

        let unknownGPT5 = RemoteGenerationClient.openAIResponsesReasoningAllowedSelections(for: "gpt-5.9")
        #expect(unknownGPT5 == [.off, .low, .medium, .high, .xhigh])

        // The registry itself stays the source of truth for advertised levels.
        let registryOption = try #require(
            CodexAgentModel.availableModels.first { $0.modelID == "gpt-5.5" }
        )
        let registryLevels = Set(
            registryOption.thinkingSupport.availableSelections
                .compactMap { AgentThinkingSelection(rawValue: $0.rawValue) }
        )
        let gpt55 = RemoteGenerationClient.openAIResponsesReasoningAllowedSelections(for: "gpt-5.5")
        #expect(gpt55 == registryLevels)
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
        model: String
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
            apiKey: nil
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
        let thinking = try #require(body["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        #expect(thinking["keep"] as? String == "all")
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
        maxOutputTokens: Int?
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
            maxOutputTokens: 2048
        )

        #expect(RemoteGenerationClient.integerValue(body["max_completion_tokens"]) == 2048)
        #expect(body["max_tokens"] == nil)
    }

    @Test
    func openAIChatNonReasoningModelKeepsLegacyMaxTokens() async throws {
        let body = try await openAIChatCompletionRequestBody(
            model: "gpt-4.1",
            maxOutputTokens: 1024
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
