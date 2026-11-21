//
//  RemoteSessionStreamingTests+Responses.swift
//  ZenCODE
//
//  Responses API streaming tests: output item text after reasoning, reasoning
//  capture and replay, generic endpoint metadata, multipart deduplication
//  (also when the completed text differs from the deltas only by whitespace),
//  incomplete responses and tool outputs without a call ID.
//  Tests of this serialized suite run in file-name order: keep the name.
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
    func streamResponsesEmitsOutputItemMessageTextAfterReasoning() async throws {
        let response = """
        data: {"type":"response.reasoning_text.delta","delta":"thinking"}

        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","content":[{"type":"output_text","text":"Visible answer"}]}}

        data: {"type":"response.completed","response":{"output":[]}}

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
                name: "OpenAI",
                baseURL: "https://api.openai.com/v1",
                modelID: "unit-model",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )
        let capturedEvents = CapturedDirectAgentEvents()

        let result = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-output-item-message",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { event in
                capturedEvents.append(event)
            }
        )

        #expect(result.text == "Visible answer")
        #expect(capturedEvents.thoughtText() == "thinking")
        #expect(capturedEvents.contentText() == "Visible answer")
    }

    @Test
    func streamResponsesCapturesReasoningItemsForReplay() async throws {
        let response = """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"old-encrypted"}}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","content":[{"type":"output_text","text":"Visible answer"}]}}

        data: {"type":"response.completed","response":{"output":[{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"summary"}],"encrypted_content":"new-encrypted"}]}}

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
                name: "OpenAI",
                baseURL: "https://api.openai.com/v1",
                modelID: "unit-model",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )

        let result = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-reasoning-items",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { _ in }
        )

        let request = try #require(fixture.capturedRequests().first)
        let body = try request.jsonObject()
        let include = try #require(body["include"] as? [String])
        #expect(include.contains("reasoning.encrypted_content"))
        #expect(body["store"] as? Bool == false)
        #expect(body["prompt_cache_key"] as? String == "session-reasoning-items")
        #expect(body["stream_options"] == nil)

        let storedItems = RemoteGenerationClient.responsesReasoningItems(
            from: result.reasoningItemsJSON
        )
        #expect(storedItems.count == 1)
        #expect(storedItems.first?["id"] as? String == "rs_1")
        #expect(storedItems.first?["encrypted_content"] as? String == "new-encrypted")

        var messages: [[String: Any]] = []
        client.appendAssistantMessage(streamResult: result, to: &messages)
        #expect(messages.count == 1)
        #expect(messages.first?["reasoning_items"] as? String == result.reasoningItemsJSON)

        let replayPayload = RemoteGenerationClient.responsesInputPayload(from: messages)
        let replayedReasoningItem = try #require(replayPayload.input.first as? [String: Any])
        #expect(replayedReasoningItem["type"] as? String == "reasoning")
        #expect(replayedReasoningItem["encrypted_content"] as? String == "new-encrypted")
    }

    @Test
    func streamResponsesOmitsOpenAIReplayMetadataForGenericEndpointAndSendsStructuredOutput() async throws {
        let response = """
        data: {"type":"response.output_text.delta","delta":"{\\"ok\\":true}"}

        data: {"type":"response.completed","response":{"output":[]}}

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
                        "required": ["ok"],
                        "additionalProperties": false
                    ]),
                    strict: false
                )
            )
        )
        let client = RemoteGenerationClient(
            configuration: configuration,
            provider: AgentRemoteProvider(
                name: "Generic Responses",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )

        let result = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-generic-responses",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { _ in }
        )
        let request = try #require(fixture.capturedRequests().first)
        let body = try request.jsonObject()
        let text = try #require(body["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])

        #expect(result.text == "{\"ok\":true}")
        #expect(request.request.url?.path == "/v1/responses")
        #expect(body["store"] == nil)
        #expect(body["include"] == nil)
        #expect(body["prompt_cache_key"] == nil)
        #expect(body["session_id"] == nil)
        #expect(format["type"] as? String == "json_schema")
        #expect(format["name"] as? String == "unit_result")
        #expect(format["strict"] as? Bool == false)
        #expect(schema["type"] as? String == "object")
    }

    @Test
    func streamResponsesDoesNotDuplicateCompletedMultipartMessagesAfterDeltas() async throws {
        let response = """
        data: {"type":"response.output_text.delta","delta":"A"}

        data: {"type":"response.output_text.delta","delta":"B"}

        data: {"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"A"}]},{"type":"message","content":[{"type":"output_text","text":"B"}]}]}}

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
                chatEndpoint: .responses
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )
        let capturedEvents = CapturedDirectAgentEvents()

        let result = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-completed-multipart-dedup",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { event in
                capturedEvents.append(event)
            }
        )

        #expect(result.text == "AB")
        #expect(capturedEvents.contentText() == "AB")
    }

    @Test
    func streamResponsesDoesNotDuplicateCompletedTextThatDiffersOnlyByTrailingWhitespace() async throws {
        let response = """
        data: {"type":"response.output_text.delta","delta":"Hai ragione.\\n"}

        data: {"type":"response.output_text.done","text":"Hai ragione."}

        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","content":[{"type":"output_text","text":"Hai ragione."}]}}

        data: {"type":"response.completed","response":{"output_text":"Hai ragione.","output":[]}}

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
                chatEndpoint: .responses
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )
        let capturedEvents = CapturedDirectAgentEvents()

        let result = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-completed-whitespace-dedup",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { event in
                capturedEvents.append(event)
            }
        )

        #expect(result.text == "Hai ragione.\n")
        #expect(capturedEvents.contentText() == "Hai ragione.\n")
    }

    @Test
    func streamResponsesDoesNotDuplicateCompletedMultipartMessagesWithWhitespaceBetweenDeltas() async throws {
        let response = """
        data: {"type":"response.output_text.delta","delta":"A\\n"}

        data: {"type":"response.output_text.delta","delta":"B"}

        data: {"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"A"}]},{"type":"message","content":[{"type":"output_text","text":"B"}]}]}}

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
                chatEndpoint: .responses
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )
        let capturedEvents = CapturedDirectAgentEvents()

        let result = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-completed-multipart-whitespace-dedup",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { event in
                capturedEvents.append(event)
            }
        )

        #expect(result.text == "A\nB")
        #expect(capturedEvents.contentText() == "A\nB")
    }

    @Test
    func streamResponsesIncompleteReturnsPartialOutput() async throws {
        let response = """
        data: {"type":"response.output_text.delta","delta":"Partial answer"}

        data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5}}}

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
                chatEndpoint: .responses
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )

        let result = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-incomplete-partial",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { _ in }
        )

        #expect(result.text == "Partial answer")
        #expect(result.stopReason == "max_output_tokens")
        #expect(result.stats.usage?.totalTokens == 5)
    }

    @Test
    func streamResponsesIncompleteDiscardsPartialToolCalls() async throws {
        let response = """
        data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"local_exec","arguments":""}}

        data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","call_id":"call_1","delta":"{\"command\":"}

        data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}

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
                chatEndpoint: .responses
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )

        let result = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-incomplete-tool-call",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { _ in }
        )

        #expect(result.toolCalls.isEmpty)
        #expect(result.stopReason == "max_output_tokens")
    }

    @Test
    func streamResponsesRejectsToolOutputWithoutCallID() async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data("".utf8)
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
                chatEndpoint: .responses
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )

        do {
            _ = try await client.streamResponses(
                messages: [["role": "tool", "content": "orphan output"]],
                sessionID: "session-orphan-tool-output",
                allowedToolNames: [],
                thinkingSelection: nil,
                onEvent: { _ in }
            )
            Issue.record("Expected invalidRequestPayload for orphan tool output.")
        } catch let error as RemoteGenerationClientError {
            guard case let .invalidRequestPayload(message) = error else {
                Issue.record("Unexpected RemoteGenerationClientError: \(error)")
                return
            }
            #expect(message.contains("tool_call_id"))
        }
    }

    @Test
    func streamResponsesReplaysReasoningTextWhenEncryptedItemIsUnavailable() async throws {
        let response = """
        data: {"type":"response.reasoning_text.delta","delta":"hidden "}

        data: {"type":"response.reasoning_text.delta","delta":"thought"}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","content":[{"type":"output_text","text":"Visible answer"}]}}

        data: {"type":"response.completed","response":{"output":[]}}

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
                chatEndpoint: .responses
            ),
            apiKey: nil,
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )

        let result = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-reasoning-text",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { _ in }
        )

        #expect(result.text == "Visible answer")
        #expect(result.reasoningText == "hidden thought")
        #expect(result.reasoningItemsJSON == nil)

        var messages: [[String: Any]] = []
        client.appendAssistantMessage(streamResult: result, to: &messages)
        #expect(messages.first?["reasoning_content"] as? String == "hidden thought")

        let replayPayload = RemoteGenerationClient.responsesInputPayload(from: messages)
        let replayedReasoningItem = try #require(replayPayload.input.first as? [String: Any])
        #expect(replayedReasoningItem["type"] as? String == "reasoning")
        let content = try #require(replayedReasoningItem["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "reasoning_text")
        #expect(content.first?["text"] as? String == "hidden thought")
    }
}
