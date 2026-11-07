//
//  ProviderThinkingAdapterTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct ProviderThinkingAdapterTests {
    struct ThinkingPayloadCase: Sendable {
        let provider: AgentProviderProfileID
        let protocolProfile: AgentProtocolProfileID
        var model = "unlisted"
        var thinkingOptions: [AgentThinkingSelection] = AgentThinkingSelection.allCases
        let selection: AgentThinkingSelection?
        /// `nil` uses the protocol's own endpoint.
        var endpoint: AgentRemoteChatEndpoint?
        let expected: String
    }

    private static let deepSeekEnabled = #"{"reasoning_effort":"high","thinking":{"type":"enabled"}}"#
    private static let deepSeekToggleOnly = #"{"thinking":{"type":"enabled"}}"#

    /// Every provider dialect, plus the manifest-authorization rules: the
    /// manifest levels are the only authorization, `.enabled` maps to the
    /// closest declared effort, DeepSeek efforts and its default stay distinct,
    /// legacy DeepSeek efforts keep only the toggle, and fallback models with
    /// empty options still send the payload (52428e3 gate).
    static let thinkingPayloadCases: [ThinkingPayloadCase] = {
        var cases: [ThinkingPayloadCase] = [
            .init(provider: .openRouter, protocolProfile: .openAIChatCompletions, selection: .off, expected: #"{"reasoning":{"effort":"none","exclude":false}}"#),
            .init(provider: .openAI, protocolProfile: .openAIResponses, selection: .high, expected: #"{"reasoning":{"effort":"high","summary":"auto"}}"#),
            .init(provider: .zAI, protocolProfile: .zaiCodingPlan, selection: .off, expected: #"{"reasoning_effort":"none"}"#),
            .init(provider: .googleGemini, protocolProfile: .openAIChatCompletions, selection: .medium, expected: #"{"reasoning_effort":"medium"}"#),
            .init(provider: .moonshot, protocolProfile: .openAIChatCompletions, selection: .enabled, expected: #"{"reasoning_effort":"enabled"}"#),
            .init(provider: .deepSeek, protocolProfile: .openAIChatCompletions, selection: .enabled, expected: deepSeekEnabled),
            .init(provider: .nvidia, protocolProfile: .openAIChatCompletions, selection: .high, expected: #"{"chat_template_kwargs":{"enable_thinking":true,"reasoning_effort":"high","thinking":true}}"#),
            .init(provider: .modal, protocolProfile: .openAIChatCompletions, selection: .off, expected: #"{"chat_template_kwargs":{"enable_thinking":false,"thinking":false}}"#),
            .init(provider: .custom, protocolProfile: .openAIChatCompletions, selection: .high, expected: "{}"),
            // Manifest levels are the only thinking authorization.
            .init(provider: .openAI, protocolProfile: .openAIResponses, thinkingOptions: [.off, .low], selection: .low, endpoint: .responses, expected: #"{"reasoning":{"effort":"low","summary":"auto"}}"#),
            .init(provider: .openAI, protocolProfile: .openAIResponses, thinkingOptions: [.off, .low], selection: .high, endpoint: .responses, expected: "{}"),
            // `.enabled` maps to the closest allowed effort when options are known.
            .init(provider: .openAI, protocolProfile: .openAIResponses, model: "gpt-fallback", thinkingOptions: [.off, .low, .medium, .high], selection: .enabled, endpoint: .responses, expected: #"{"reasoning":{"effort":"medium","summary":"auto"}}"#),
            .init(provider: .zAI, protocolProfile: .openAIChatCompletions, model: "glm", thinkingOptions: [.off, .low], selection: .enabled, endpoint: .chatCompletions, expected: #"{"reasoning_effort":"low"}"#),
            // Fallback models without thinking options still send the payload.
            .init(provider: .moonshot, protocolProfile: .openAIChatCompletions, model: "fallback-kimi", thinkingOptions: [], selection: .enabled, endpoint: .chatCompletions, expected: #"{"reasoning_effort":"enabled"}"#),
            .init(provider: .moonshot, protocolProfile: .openAIChatCompletions, model: "fallback-kimi", thinkingOptions: [], selection: .high, endpoint: .chatCompletions, expected: #"{"reasoning_effort":"high"}"#),
            // Legacy DeepSeek efforts preserve the toggle without inventing aliases.
            .init(provider: .deepSeek, protocolProfile: .openAIChatCompletions, model: "future-model", thinkingOptions: [], selection: .off, endpoint: .chatCompletions, expected: "{}"),
            .init(provider: .deepSeek, protocolProfile: .openAIChatCompletions, model: "future-model", thinkingOptions: [], selection: .low, endpoint: .chatCompletions, expected: #"{"reasoning_effort":"low","thinking":{"type":"enabled"}}"#),
            .init(provider: .openRouter, protocolProfile: .openAIChatCompletions, model: "deepseek/deepseek-flash", selection: .max, endpoint: .chatCompletions, expected: #"{"reasoning":{"effort":"max","exclude":false}}"#)
        ]
        for selection in [AgentThinkingSelection.minimal, .medium, .xhigh, .ultra] {
            cases.append(.init(provider: .deepSeek, protocolProfile: .openAIChatCompletions, model: "deepseek-v4-flash", selection: selection, endpoint: .chatCompletions, expected: deepSeekToggleOnly))
        }
        // DeepSeek effort levels and the default remain distinct.
        let declared: [AgentThinkingSelection] = [.off, .low, .high, .max]
        let effortExpectations: [(AgentThinkingSelection?, String)] = [
            (.low, #"{"reasoning_effort":"low","thinking":{"type":"enabled"}}"#),
            (.high, #"{"reasoning_effort":"high","thinking":{"type":"enabled"}}"#),
            (.max, #"{"reasoning_effort":"max","thinking":{"type":"enabled"}}"#),
            (.enabled, deepSeekEnabled),
            (.off, #"{"thinking":{"type":"disabled"}}"#),
            (nil, "{}"),
            (.medium, "{}"),
            (.xhigh, "{}"),
            (.ultra, "{}")
        ]
        for (selection, expected) in effortExpectations {
            cases.append(.init(provider: .deepSeek, protocolProfile: .openAIChatCompletions, model: "deepseek-flash", thinkingOptions: declared, selection: selection, endpoint: .chatCompletions, expected: expected))
        }
        // DeepSeek `.enabled` respects the declared efforts.
        let declaredEffortExpectations: [([AgentThinkingSelection], String)] = [
            ([.low], #"{"reasoning_effort":"low","thinking":{"type":"enabled"}}"#),
            ([.max], #"{"reasoning_effort":"max","thinking":{"type":"enabled"}}"#),
            ([.off, .low, .high, .max], deepSeekEnabled),
            ([.enabled], deepSeekEnabled),
            ([.enabled, .low], deepSeekEnabled),
            ([], deepSeekEnabled),
            ([.xhigh], deepSeekToggleOnly),
            ([.minimal, .medium, .ultra], deepSeekToggleOnly),
            ([.off], "{}")
        ]
        for (options, expected) in declaredEffortExpectations {
            cases.append(.init(provider: .deepSeek, protocolProfile: .openAIChatCompletions, model: "deepseek-flash", thinkingOptions: options, selection: .enabled, endpoint: .chatCompletions, expected: expected))
            cases.append(.init(provider: .deepSeek, protocolProfile: .openAIChatCompletions, model: "deepseek-flash", thinkingOptions: options, selection: nil, endpoint: .chatCompletions, expected: "{}"))
            if !options.contains(.off) {
                cases.append(.init(provider: .deepSeek, protocolProfile: .openAIChatCompletions, model: "deepseek-flash", thinkingOptions: options, selection: .off, endpoint: .chatCompletions, expected: "{}"))
            }
        }
        return cases
    }()

    @Test(arguments: Self.thinkingPayloadCases)
    func thinkingPayloadSnapshots(_ testCase: ThinkingPayloadCase) async {
        let client = client(
            provider: testCase.provider,
            protocolProfile: testCase.protocolProfile,
            model: testCase.model,
            thinkingOptions: testCase.thinkingOptions
        )
        let endpoint = testCase.endpoint
            ?? testCase.protocolProfile.chatEndpoint
            ?? .chatCompletions
        #expect(await client.thinkingPayloadSnapshot(testCase.selection, endpoint: endpoint) == testCase.expected)
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
        _ selection: AgentThinkingSelection?,
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

    /// Reasoning models use `max_completion_tokens`; the others keep the
    /// legacy `max_tokens`.
    @Test(arguments: [
        ("gpt-5.4", 2048, [AgentThinkingSelection.high], "max_completion_tokens", "max_tokens"),
        ("gpt-4.1", 1024, [AgentThinkingSelection](), "max_tokens", "max_completion_tokens")
    ])
    func openAIChatReasoningModelSendsMaxCompletionTokens(
        model: String,
        maxOutputTokens: Int,
        thinkingOptions: [AgentThinkingSelection],
        sentKey: String,
        omittedKey: String
    ) async throws {
        let body = try await openAIChatCompletionRequestBody(
            model: model,
            maxOutputTokens: maxOutputTokens,
            thinkingOptions: thinkingOptions
        )

        #expect(RemoteGenerationClient.integerValue(body[sentKey]) == maxOutputTokens)
        #expect(body[omittedKey] == nil)
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
