import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

struct AnthropicMessagesDirectTests {
    private let provider = AgentRemoteProvider(
        name: "Anthropic API",
        baseURL: "https://api.anthropic.com/v1",
        modelID: "claude-sonnet-4-5",
        chatEndpoint: .chatCompletions,
        providerProfileID: .anthropic,
        protocolProfileID: .anthropicMessages,
        authPolicy: .apiKeyRequired
    )

    @Test func directEffortDoesNotUseBearerSubscriptionOrBetaHeaders() throws {
        let body: [String: Any] = [
            "model": "claude-sonnet-4-5", "messages": [], "stream": true,
            "output_config": ["effort": "medium"]
        ]
        let request = try RemoteStreamTransport.buildHTTPStreamingRequest(
            path: "/messages", body: body, provider: provider, apiKey: "test-key"
        )
        let headers = RemoteHTTPHeaders(request.headers)
        #expect(headers.firstValue(for: "x-api-key") == "test-key")
        #expect(headers.firstValue(for: "anthropic-version") == "2023-06-01")
        #expect(headers.firstValue(for: "authorization") == nil)
        #expect(headers.firstValue(for: "anthropic-beta") == nil) // Official Effort docs: no beta header required.
        #expect(request.url.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test func betaIsConditionalForManual45ThinkingWithTools() throws {
        let body: [String: Any] = [
            "model": "claude-sonnet-4-5", "messages": [], "stream": true,
            "thinking": ["type": "enabled", "budget_tokens": 4096],
            "tools": [["name": "lookup", "input_schema": ["type": "object"]]]
        ]
        let request = try RemoteStreamTransport.buildHTTPStreamingRequest(
            path: "/messages", body: body, provider: provider, apiKey: "test-key"
        )
        #expect(RemoteHTTPHeaders(request.headers).firstValue(for: "anthropic-beta") == "interleaved-thinking-2025-05-14")
    }

    @Test func codecPreservesOrderedSignedAndRedactedBlocks() throws {
        let exact = #"[{"type":"thinking","thinking":"","signature":"sig"},{"type":"tool_use","id":"toolu_1","name":"lookup","input":{"q":"x"}},{"type":"redacted_thinking","data":"cipher"},{"type":"text","text":"done"}]"#
        let converted = AnthropicMessagesWireCodec.payload(from: [[
            "role": "assistant", "content": "done", "anthropic_content_blocks": exact
        ]])
        let blocks = try #require(converted.messages.first?["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["thinking", "tool_use", "redacted_thinking", "text"])
        #expect(blocks[0]["thinking"] as? String == "")
        #expect(blocks[0]["signature"] as? String == "sig")
    }

    @Test func nonAnthropicWireStripsAnthropicReplayMetadataFromACPToolFailureHistory() throws {
        let history = ZenCODEACPBridge.runtimeHistory(from: [
            ["role": "assistant", "content": "done", "anthropic_content_blocks": #"[{"type":"text","text":"done"}]"#],
            ["role": "tool", "content": "failed", "tool_call_id": "toolu_1", "is_error": true]
        ])
        let replay = history.compactMap(RemoteGenerationClient.remoteMessage(from:))
        #expect(replay.last?["is_error"] as? Bool == true)

        let wire = RemoteGenerationClient.chatCompletionsWireHistoryMessages(from: replay)
        #expect(wire.count == 2)
        #expect(wire[0]["anthropic_content_blocks"] == nil)
        #expect(wire[1]["is_error"] == nil)

        let responses = try RemoteGenerationClient.validatedResponsesInputPayload(from: replay)
        let serialized = try JSONSerialization.data(withJSONObject: responses.input)
        let json = String(decoding: serialized, as: UTF8.self)
        #expect(!json.contains("anthropic_content_blocks"))
        #expect(!json.contains("is_error"))
    }

    @Test func citationsAndAdditionalRawFieldsSurviveSSESnapshotACPAndReplay() async throws {
        var accumulator = AnthropicMessagesStreamAccumulator()
        let sink: @Sendable (DirectAgentEvent) async -> Void = { _ in }
        try await accumulator.ingest([
            "type": "content_block_start", "index": 0,
            "content_block": ["type": "text", "text": "answer", "vendor_extension": ["stable": true]]
        ], onEvent: sink)
        let citation: [String: Any] = [
            "type": "char_location", "cited_text": "source", "document_index": 0,
            "document_title": "Title", "start_char_index": 1, "end_char_index": 7
        ]
        try await accumulator.ingest([
            "type": "content_block_delta", "index": 0,
            "delta": ["type": "citations_delta", "citation": citation]
        ], onEvent: sink)
        try await accumulator.ingest([
            "type": "content_block_start", "index": 1,
            "content_block": ["type": "thinking", "thinking": "", "signature": "sig", "extra": "kept"]
        ], onEvent: sink)
        try await accumulator.ingest(["type": "message_stop"], onEvent: sink)

        let result = try accumulator.result(requestStartedAt: Date())
        let exact = try #require(result.anthropicContentBlocksJSON)
        let snapshot = AgentRuntimeMessage(role: .assistant, content: "answer", anthropicContentBlocksJSON: exact)
        let restored = try JSONDecoder().decode(AgentRuntimeMessage.self, from: JSONEncoder().encode(snapshot))
        let restoredBlocks = try #require(restored.anthropicContentBlocksJSON)
        let acp = ZenCODEACPBridge.runtimeHistory(from: [[
            "role": "assistant", "content": "answer", "anthropic_content_blocks": restoredBlocks
        ]])
        let payload = try #require(acp.first.flatMap(RemoteGenerationClient.remoteMessage(from:)))
        let blocks = AnthropicMessagesWireCodec.assistantBlocks(from: payload)

        #expect(blocks.map { $0["type"] as? String } == ["text", "thinking"])
        #expect((blocks[0]["vendor_extension"] as? [String: Any])?["stable"] as? Bool == true)
        #expect((blocks[0]["citations"] as? [[String: Any]])?.first?["cited_text"] as? String == "source")
        #expect(blocks[1]["extra"] as? String == "kept")
    }

    @Test func requestMapsSystemImageToolResultAndMaxTokens() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "Be concise."],
            ["role": "user", "content": [[
                "type": "image_url",
                "image_url": ["url": "data:image/png;base64,AAAA"]
            ]]],
            ["role": "tool", "tool_call_id": "toolu_1", "content": "failed", "is_error": true]
        ]
        let body = try RemoteGenerationClient.anthropicMessagesRequestBody(
            modelID: "claude-sonnet-5", messages: messages,
            toolCatalog: RemoteToolWireCatalog(descriptors: []), maxTokens: 8192,
            thinkingSelection: .high
        )
        #expect(body["system"] as? String == "Be concise.")
        #expect(body["max_tokens"] as? Int == 8192)
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "high")
        let wire = try #require(body["messages"] as? [[String: Any]])
        let userBlocks = try #require(wire.first?["content"] as? [[String: Any]])
        #expect(userBlocks.first?["type"] as? String == "image")
        #expect(userBlocks.last?["type"] as? String == "tool_result")
        #expect(userBlocks.last?["is_error"] as? Bool == true)
    }

    @Test(arguments: [
        ("claude-sonnet-5", AgentThinkingSelection.enabled, 64_000),
        ("claude-sonnet-5", AgentThinkingSelection.xhigh, 64_000),
        ("claude-haiku-4-5", AgentThinkingSelection.medium, 12_000),
        ("claude-haiku-4-5", AgentThinkingSelection.off, 12_000)
    ])
    func directThinkingPayloadMatchesSubscriptionPolicy(
        modelID: String,
        selection: AgentThinkingSelection,
        maxTokens: Int
    ) throws {
        let direct = try RemoteGenerationClient.anthropicMessagesRequestBody(
            modelID: modelID,
            messages: [["role": "user", "content": "hello"]],
            toolCatalog: RemoteToolWireCatalog(descriptors: []),
            maxTokens: maxTokens,
            thinkingSelection: selection
        )
        let subscription = AnthropicSubscriptionGenerationClient.thinkingPayload(
            for: selection,
            modelID: modelID,
            maxTokens: maxTokens
        )

        let directThinking = direct["thinking"].map { JSONValue(jsonObject: $0) }
        let subscriptionThinking = subscription.thinking.map { JSONValue(jsonObject: $0) }
        let directOutputConfig = direct["output_config"].map { JSONValue(jsonObject: $0) }
        let subscriptionOutputConfig = subscription.outputConfig.map { JSONValue(jsonObject: $0) }
        #expect(directThinking == subscriptionThinking)
        #expect(directOutputConfig == subscriptionOutputConfig)
    }

    @Test func streamAccumulatesUsageToolsAndRequiresMessageStop() async throws {
        var accumulator = AnthropicMessagesStreamAccumulator()
        let sink: @Sendable (DirectAgentEvent) async -> Void = { _ in }
        try await accumulator.ingest(["type": "message_start", "message": ["usage": [
            "input_tokens": 10, "cache_creation_input_tokens": 2, "cache_read_input_tokens": 3
        ]]], onEvent: sink)
        try await accumulator.ingest(["type": "content_block_start", "index": 0,
            "content_block": ["type": "thinking", "thinking": ""]], onEvent: sink)
        try await accumulator.ingest(["type": "content_block_delta", "index": 0,
            "delta": ["type": "signature_delta", "signature": "sig"]], onEvent: sink)
        try await accumulator.ingest(["type": "content_block_start", "index": 1,
            "content_block": ["type": "tool_use", "id": "toolu_1", "name": "lookup", "input": [:]]], onEvent: sink)
        try await accumulator.ingest(["type": "content_block_delta", "index": 1,
            "delta": ["type": "input_json_delta", "partial_json": "{\"q\":\"x\"}"]], onEvent: sink)
        try await accumulator.ingest(["type": "message_delta", "delta": ["stop_reason": "tool_use"],
            "usage": ["output_tokens": 7]], onEvent: sink)
        try await accumulator.ingest(["type": "message_stop"], onEvent: sink)
        let result = try accumulator.result(requestStartedAt: Date())
        #expect(result.toolCalls.count == 1)
        #expect(result.stats.usage?.promptTokens == 15)
        #expect(result.stats.usage?.processedPromptTokens == 12)
        #expect(result.stats.usage?.cachedPromptTokens == 3)
        #expect(result.stats.usage?.completionTokens == 7)
        #expect(result.anthropicContentBlocksJSON?.contains("\"thinking\":\"\"") == true)
    }

    @Test func optionalCodableFieldIsBackwardCompatible() throws {
        let old = #"{"role":"assistant","content":"hello","attachments":[],"toolCalls":[]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AgentRuntimeMessage.self, from: old)
        #expect(decoded.anthropicContentBlocksJSON == nil)
        let exact = #"[{"type":"thinking","thinking":"","signature":"sig"}]"#
        let encoded = try JSONEncoder().encode(AgentRuntimeMessage(
            role: .assistant, content: "", anthropicContentBlocksJSON: exact
        ))
        #expect(try JSONDecoder().decode(AgentRuntimeMessage.self, from: encoded).anthropicContentBlocksJSON == exact)
    }

    @Test func toolResultErrorSurvivesSnapshotAndWireRoundTrip() throws {
        let old = #"{"role":"tool","content":"ok","attachments":[],"toolCalls":[],"toolCallID":"toolu_old"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(AgentRuntimeMessage.self, from: old).toolResultIsError == nil)

        let original = AgentRuntimeMessage(
            role: .tool, content: "failed", toolCallID: "toolu_1",
            toolName: "lookup", toolResultIsError: true
        )
        let restored = try JSONDecoder().decode(
            AgentRuntimeMessage.self,
            from: JSONEncoder().encode(original)
        )
        #expect(restored.toolResultIsError == true)
        let payload = try #require(RemoteGenerationClient.remoteMessage(from: restored))
        let block = try #require(AnthropicMessagesWireCodec.toolResultBlock(from: payload))
        #expect(block["is_error"] as? Bool == true)
    }

    @Test func acpImportsAnthropicBlocksWithoutTextAndPreservesOrder() throws {
        let exact = #"[{"type":"thinking","thinking":"","signature":"sig"},{"type":"tool_use","id":"toolu_1","name":"lookup","input":{} }]"#
        let nativeBlocks: [[String: Any]] = [
            ["type": "thinking", "thinking": "", "signature": "sig"],
            ["type": "tool_use", "id": "toolu_1", "name": "lookup", "input": [:]]
        ]
        let history = ZenCODEACPBridge.runtimeHistory(from: [[
            "role": "assistant", "content": "", "anthropic_content_blocks": nativeBlocks
        ]])
        let imported = try #require(history.first)
        #expect(imported.content.isEmpty)
        #expect(imported.anthropicContentBlocksJSON != nil)
        let payload = try #require(RemoteGenerationClient.remoteMessage(from: imported))
        let blocks = AnthropicMessagesWireCodec.assistantBlocks(from: payload)
        #expect(blocks.map { $0["type"] as? String } == ["thinking", "tool_use"])

        // Serialized snapshot-shaped input is preserved byte-for-byte.
        let serialized = ZenCODEACPBridge.runtimeHistory(from: [[
            "role": "assistant", "content": "", "anthropic_content_blocks": exact
        ]])
        #expect(serialized.first?.anthropicContentBlocksJSON == exact)
    }

    @Test func manualThinkingBudgetMatchesSubscriptionClamping() throws {
        let body = try RemoteGenerationClient.anthropicMessagesRequestBody(
            modelID: "claude-haiku-4-5", messages: [],
            toolCatalog: RemoteToolWireCatalog(descriptors: []), maxTokens: 4_096,
            thinkingSelection: .max
        )
        #expect(body["max_tokens"] as? Int == 4_096)
        #expect((body["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 3_072)

        let constrained = try RemoteGenerationClient.anthropicMessagesRequestBody(
            modelID: "claude-haiku-4-5", messages: [],
            toolCatalog: RemoteToolWireCatalog(descriptors: []), maxTokens: 2_047,
            thinkingSelection: .minimal
        )
        #expect(
            (constrained["thinking"] as? [String: Any])?["budget_tokens"] as? Int
                == 1_024
        )
        #expect(constrained["max_tokens"] as? Int == 2_047)
    }

    @Test func interleavedThinkingCapabilityCoversManualFamiliesOnly() {
        for model in ["claude-opus-4-1-20250805", "claude-sonnet-4-5", "claude-haiku-4-5"] {
            #expect(RemoteStreamTransport.supportsAnthropicInterleavedThinking(modelID: model))
        }
        for model in ["claude-sonnet-4-6", "claude-3-7-sonnet", "vendor-4-5-model"] {
            #expect(!RemoteStreamTransport.supportsAnthropicInterleavedThinking(modelID: model))
        }
    }
}
