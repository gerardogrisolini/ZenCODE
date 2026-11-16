//
//  RemoteSessionSnapshotTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ZenCODECore
import Testing
import ToolCore

extension RemoteSessionSnapshotTests {
    @Test
    func streamChatCompletionsPromotesReasoningContentAfterThinkCloseToContent() async throws {
        let response = """
        data: {"choices":[{"delta":{"reasoning_content":"Analisi.</thi"}}]}

        data: {"choices":[{"delta":{"reasoning_content":"nk>Risposta visibile."},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data(response.utf8)
        )
        defer {
            fixture.beginShutdown()
        }
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .chatCompletions
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )
        let capturedEvents = CapturedDirectAgentEvents()

        let result = try await client.streamChatCompletions(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-reasoning-content-boundary",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { event in
                capturedEvents.append(event)
            }
        )

        #expect(result.text == "Risposta visibile.")
        #expect(capturedEvents.thoughtText() == "Analisi.</think>")
        #expect(capturedEvents.contentText() == "Risposta visibile.")
    }

    @Test
    func remoteStreamAccumulatorRecognizesEveryClosingMarkerAcrossEverySplit() async throws {
        let markers = ["</think>", "</thinking>", "<channel|>"]

        for marker in markers {
            for splitOffset in 0...marker.count {
                let splitIndex = marker.index(
                    marker.startIndex,
                    offsetBy: splitOffset
                )
                let firstDelta = "pensiero🙂" + String(marker[..<splitIndex])
                let secondDelta = String(marker[splitIndex...]) + "risposta✅"
                var accumulator = RemoteStreamAccumulator()

                try await accumulator.ingest(.reasoning(firstDelta)) { _ in }
                try await accumulator.ingest(.reasoning(secondDelta)) { _ in }

                let result = try accumulator.result(requestStartedAt: Date())
                #expect(result.reasoningText == "pensiero🙂" + marker)
                #expect(result.text == "risposta✅")
                #expect(
                    accumulator.reasoningClosingMarkerLookbehindByteCount
                        <= RemoteStreamAccumulator
                            .maximumReasoningClosingMarkerLookbehindByteCount
                )
            }
        }
    }

    @Test
    func streamChatCompletionsSendsStructuredOutputResponseFormat() async throws {
        let response = """
        data: {"choices":[{"delta":{"content":"{\\"ok\\":true}"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data(response.utf8)
        )
        defer {
            fixture.beginShutdown()
        }
        var configuration = remoteStreamingConfiguration()
        configuration = configuration.withModelSettings(
            configuredContextWindowLimit: nil,
            generationParameterOverrides: AgentGenerationParameterOverrides(
                structuredOutput: AgentStructuredOutputFormat(
                    name: "unit_result",
                    schema: JSONValue(jsonObject: [
                        "type": "object",
                        "properties": [
                            "ok": ["type": "boolean"]
                        ],
                        "required": ["ok"]
                    ]),
                    strict: false
                )
            )
        )
        let client = RemoteGenerationClient(
            configuration: configuration,
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .chatCompletions
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )

        _ = try await client.streamChatCompletions(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-chat-structured-output",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { _ in }
        )
        let request = try #require(fixture.capturedRequests().first)
        let body = try request.jsonObject()
        let responseFormat = try #require(body["response_format"] as? [String: Any])
        let jsonSchema = try #require(responseFormat["json_schema"] as? [String: Any])
        let schema = try #require(jsonSchema["schema"] as? [String: Any])

        #expect(request.request.url?.path == "/v1/chat/completions")
        #expect(responseFormat["type"] as? String == "json_schema")
        #expect(jsonSchema["name"] as? String == "unit_result")
        #expect(jsonSchema["strict"] as? Bool == false)
        #expect(schema["type"] as? String == "object")
    }

    @Test
    func parseChatCompletionsDoesNotDuplicateIdenticalReasoningFields() {
        let events = ChatCompletionsStreamParser.parse([
            "choices": [
                [
                    "delta": [
                        "reasoning": "same thought",
                        "reasoning_content": "same thought"
                    ]
                ]
            ]
        ])
        let reasoningEvents = events.compactMap { event -> String? in
            guard case let .reasoning(delta) = event else {
                return nil
            }
            return delta
        }

        #expect(reasoningEvents == ["same thought"])
    }

    @Test
    func streamChatCompletionsRetriesTransientOpeningFailureBeforeHead() async throws {
        let response = """
        data: {"choices":[{"delta":{"content":"recovered"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data(response.utf8),
            failuresBeforeHead: 1
        )
        defer {
            fixture.beginShutdown()
        }
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Generic Provider",
                baseURL: "https://provider.example/v1",
                modelID: "unit-model",
                chatEndpoint: .chatCompletions
            ),
            apiKey: "test-key",
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )
        let capturedEvents = CapturedDirectAgentEvents()

        let result = try await client.streamChatCompletions(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-tls-retry",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { event in
                capturedEvents.append(event)
            }
        )
        let requests = fixture.capturedRequests()

        #expect(result.text == "recovered")
        #expect(capturedEvents.contentText() == "recovered")
        #expect(requests.count == 2)
        #expect(requests.first?.body == requests.last?.body)
    }

    @Test
    func streamChatCompletionsDoesNotRetryFailureAfterResponseHead() async throws {
        // Keep the event separator explicit: a multiline Swift literal drops
        // its final blank line, which would turn this into an incomplete SSE
        // event rather than the post-head truncation we need to regress.
        let response = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n"
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data(response.utf8),
            closeAfterHead: true
        )
        defer {
            fixture.beginShutdown()
        }
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Generic Provider",
                baseURL: "https://provider.example/v1",
                modelID: "unit-model",
                chatEndpoint: .chatCompletions
            ),
            apiKey: "test-key",
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )
        let capturedEvents = CapturedDirectAgentEvents()

        do {
            _ = try await client.streamChatCompletions(
                messages: [["role": "user", "content": "hi"]],
                sessionID: "session-tls-no-replay",
                allowedToolNames: [],
                thinkingSelection: nil,
                onEvent: { event in
                    capturedEvents.append(event)
                }
            )
            Issue.record("Expected the post-head stream failure to propagate")
        } catch {
            #expect(error is RemoteTransportError)
        }

        #expect(fixture.capturedRequests().count == 1)
        #expect(capturedEvents.contentText() == "partial")
    }

    @Test(arguments: [AgentRemoteChatEndpoint.responses, .chatCompletions])
    func streamResponsesSendsOpenRouterSessionIDForStickyCacheRouting(
        endpoint: AgentRemoteChatEndpoint
    ) async throws {
        let response = endpoint == .responses
            ? """
            data: {"type":"response.output_text.delta","delta":"ok"}

            data: {"type":"response.completed","response":{"output":[]}}

            """
            : """
            data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

            data: [DONE]

            """
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data(response.utf8)
        )
        defer {
            fixture.beginShutdown()
        }
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "OpenRouter",
                baseURL: "https://openrouter.ai/api/v1",
                modelID: "deepseek/deepseek-v4-flash",
                chatEndpoint: endpoint
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )
        let sessionID = endpoint == .responses
            ? "session-openrouter-cache"
            : "session-openrouter-chat-cache"

        if endpoint == .responses {
            _ = try await client.streamResponses(
                messages: [["role": "user", "content": "hi"]],
                sessionID: sessionID,
                allowedToolNames: [],
                thinkingSelection: nil,
                onEvent: { _ in }
            )
        } else {
            _ = try await client.streamChatCompletions(
                messages: [["role": "user", "content": "hi"]],
                sessionID: sessionID,
                allowedToolNames: [],
                thinkingSelection: nil,
                onEvent: { _ in }
            )
        }
        let request = try #require(fixture.capturedRequests().first)
        let body = try request.jsonObject()

        #expect(body["session_id"] as? String == sessionID)
        if endpoint == .responses {
            #expect(body["prompt_cache_key"] as? String == sessionID)
        } else {
            #expect((body["stream_options"] as? [String: Bool])?["include_usage"] == true)
        }
    }
}


extension RemoteSessionSnapshotTests {
    @Test
    func streamChatCompletionsSurfacesNIONon2xxErrorBodyWithoutReplay() async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data(#"{"error":{"message":"capacity exhausted"}}"#.utf8),
            responseStatus: 429,
            responseHeaders: [
                RemoteHTTPHeader(name: "content-type", value: "application/json"),
                RemoteHTTPHeader(name: "x-request-id", value: "req_openai_nio")
            ]
        )
        defer {
            fixture.beginShutdown()
        }
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "OpenAI",
                baseURL: "https://api.openai.com/v1",
                modelID: "unit-model",
                chatEndpoint: .chatCompletions
            ),
            apiKey: "test-key",
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )

        do {
            _ = try await client.streamChatCompletions(
                messages: [["role": "user", "content": "hi"]],
                sessionID: "session-nio-429",
                allowedToolNames: [],
                thinkingSelection: nil,
                onEvent: { _ in }
            )
            Issue.record("Expected the OpenAI-compatible 429 response to fail.")
        } catch let error as RemoteGenerationClientError {
            guard case let .remoteFailure(message) = error else {
                Issue.record("Unexpected provider error: \(error)")
                return
            }
            #expect(message == "capacity exhausted")
        }

        #expect(fixture.capturedRequests().count == 1)
    }
}
