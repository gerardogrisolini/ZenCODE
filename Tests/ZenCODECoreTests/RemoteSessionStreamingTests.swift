//
//  RemoteSessionSnapshotTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import os
@testable import ZenCODECore
import Testing

extension RemoteSessionSnapshotTests {
    @Test
    func streamResponsesEmitsOutputItemMessageTextAfterReasoning() async throws {
        let response = """
        data: {"type":"response.reasoning_text.delta","delta":"thinking"}

        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","content":[{"type":"output_text","text":"Visible answer"}]}}

        data: {"type":"response.completed","response":{"output":[]}}

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            urlSession: urlSession
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
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            urlSession: urlSession
        )

        let result = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-reasoning-items",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { _ in }
        )

        let request = try #require(RemoteRequestCapturingURLProtocol.capturedRequests().first)
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
    func streamResponsesReplaysReasoningTextWhenEncryptedItemIsUnavailable() async throws {
        let response = """
        data: {"type":"response.reasoning_text.delta","delta":"hidden "}

        data: {"type":"response.reasoning_text.delta","delta":"thought"}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","content":[{"type":"output_text","text":"Visible answer"}]}}

        data: {"type":"response.completed","response":{"output":[]}}

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            urlSession: urlSession
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

    @Test
    func streamResponsesKeepsPlainReasoningItemsForReplay() async throws {
        let response = """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_plain","summary":[],"content":[{"type":"reasoning_text","text":"plain thought"}]}}

        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","content":[{"type":"output_text","text":"Visible answer"}]}}

        data: {"type":"response.completed","response":{"output":[]}}

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            urlSession: urlSession
        )

        let result = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-plain-reasoning-item",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { _ in }
        )

        let storedItems = RemoteGenerationClient.responsesReasoningItems(
            from: result.reasoningItemsJSON
        )
        #expect(storedItems.count == 1)
        #expect(storedItems.first?["id"] as? String == "rs_plain")
        let storedContent = try #require(storedItems.first?["content"] as? [[String: Any]])
        #expect(storedContent.first?["text"] as? String == "plain thought")

        var messages: [[String: Any]] = []
        client.appendAssistantMessage(streamResult: result, to: &messages)
        let replayPayload = RemoteGenerationClient.responsesInputPayload(from: messages)
        let replayedReasoningItem = try #require(replayPayload.input.first as? [String: Any])
        let replayedContent = try #require(replayedReasoningItem["content"] as? [[String: Any]])
        #expect(replayedContent.first?["text"] as? String == "plain thought")
    }

    @Test
    func streamChatCompletionsPromotesReasoningContentAfterThinkCloseToContent() async throws {
        let response = """
        data: {"choices":[{"delta":{"reasoning_content":"Analisi.</think>"}}]}

        data: {"choices":[{"delta":{"reasoning_content":"Risposta visibile."},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .chatCompletions
            ),
            apiKey: nil,
            urlSession: urlSession
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

                #expect(result.text == "")
        #expect(capturedEvents.thoughtText() == "Analisi.</think>Risposta visibile.")
        #expect(capturedEvents.contentText() == "")
    }

    @Test
    func streamChatCompletionsDoesNotSendNonStandardSessionID() async throws {
        let response = """
        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Unit Test",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .chatCompletions
            ),
            apiKey: nil,
            urlSession: urlSession
        )

        _ = try await client.streamChatCompletions(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-chat-completions-standard",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { _ in }
        )
        let request = try #require(RemoteRequestCapturingURLProtocol.capturedRequests().first)
        let body = try request.jsonObject()

        #expect(body["session_id"] == nil)
        #expect((body["stream_options"] as? [String: Bool])?["include_usage"] == true)
    }

    @Test
    func streamResponsesSendsOpenRouterSessionIDForStickyCacheRouting() async throws {
        let response = """
        data: {"type":"response.output_text.delta","delta":"ok"}

        data: {"type":"response.completed","response":{"output":[]}}

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "OpenRouter",
                baseURL: "https://openrouter.ai/api/v1",
                modelID: "deepseek/deepseek-v4-flash",
                chatEndpoint: .responses
            ),
            apiKey: nil,
            urlSession: urlSession
        )

        _ = try await client.streamResponses(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-openrouter-cache",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { _ in }
        )
        let request = try #require(RemoteRequestCapturingURLProtocol.capturedRequests().first)
        let body = try request.jsonObject()

        #expect(body["session_id"] as? String == "session-openrouter-cache")
        #expect(body["prompt_cache_key"] as? String == "session-openrouter-cache")
    }

    @Test
    func streamChatCompletionsSendsOpenRouterSessionIDForStickyCacheRouting() async throws {
        let response = """
        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "OpenRouter",
                baseURL: "https://openrouter.ai/api/v1",
                modelID: "deepseek/deepseek-v4-flash",
                chatEndpoint: .chatCompletions
            ),
            apiKey: nil,
            urlSession: urlSession
        )

        _ = try await client.streamChatCompletions(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-openrouter-chat-cache",
            allowedToolNames: [],
            thinkingSelection: nil,
            onEvent: { _ in }
        )
        let request = try #require(RemoteRequestCapturingURLProtocol.capturedRequests().first)
        let body = try request.jsonObject()

        #expect(body["session_id"] as? String == "session-openrouter-chat-cache")
        #expect((body["stream_options"] as? [String: Bool])?["include_usage"] == true)
    }

    @Test
    func chatTemplateThinkingPayloadIncludesReasoningEffort() async throws {
        let response = """
        data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let urlSession = RemoteRequestCapturingURLProtocol.urlSession(
            responseBody: Data(response.utf8)
        )
        let client = RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "NVIDIA",
                baseURL: "https://integrate.api.nvidia.com/v1",
                modelID: "deepseek-ai/deepseek-v4-flash",
                chatEndpoint: .chatCompletions
            ),
            apiKey: nil,
            urlSession: urlSession,
            mcpRuntime: await borrowedXcodeMCPRuntime()
        )

        _ = try await client.streamChatCompletions(
            messages: [["role": "user", "content": "hi"]],
            sessionID: "session-chat-template",
            allowedToolNames: [],
            thinkingSelection: .high,
            onEvent: { _ in }
        )
        let request = try #require(RemoteRequestCapturingURLProtocol.capturedRequests().first)
        let body = try request.jsonObject()
        let chatTemplateKwargs = try #require(body["chat_template_kwargs"] as? [String: Any])

        #expect(chatTemplateKwargs["thinking"] as? Bool == true)
        #expect(chatTemplateKwargs["enable_thinking"] as? Bool == true)
        #expect(chatTemplateKwargs["reasoning_effort"] as? String == "high")
    }
}
