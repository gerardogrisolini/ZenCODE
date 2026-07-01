//
//  AnthropicThinkingBlockTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//
import Foundation
@testable import ZenCODECore
import Testing

#if os(macOS)
struct AnthropicThinkingBlockTests {
    @Test
    func accumulatorCapturesSignedThinkingBlock() {
        var accumulator = AnthropicThinkingBlockAccumulator()
        accumulator.ingestContentBlockStart([
            "index": 0,
            "content_block": ["type": "thinking", "thinking": ""]
        ])
        accumulator.ingestDelta(
            index: 0,
            delta: ["type": "thinking_delta", "thinking": "Let me reason "]
        )
        accumulator.ingestDelta(
            index: 0,
            delta: ["type": "thinking_delta", "thinking": "about this."]
        )
        accumulator.ingestDelta(
            index: 0,
            delta: ["type": "signature_delta", "signature": "sig-123"]
        )

        let blocks = accumulator.finalize()
        #expect(blocks.count == 1)
        #expect(blocks.first?["type"] as? String == "thinking")
        #expect(blocks.first?["thinking"] as? String == "Let me reason about this.")
        #expect(blocks.first?["signature"] as? String == "sig-123")
    }

    @Test
    func accumulatorDropsThinkingBlockWithoutSignature() {
        var accumulator = AnthropicThinkingBlockAccumulator()
        accumulator.ingestContentBlockStart([
            "index": 0,
            "content_block": ["type": "thinking", "thinking": ""]
        ])
        accumulator.ingestDelta(
            index: 0,
            delta: ["type": "thinking_delta", "thinking": "Unsigned thought."]
        )

        #expect(accumulator.finalize().isEmpty)
    }

    @Test
    func accumulatorCapturesRedactedThinkingBlock() {
        var accumulator = AnthropicThinkingBlockAccumulator()
        accumulator.ingestContentBlockStart([
            "index": 0,
            "content_block": ["type": "redacted_thinking", "data": "encrypted-data"]
        ])

        let blocks = accumulator.finalize()
        #expect(blocks.count == 1)
        #expect(blocks.first?["type"] as? String == "redacted_thinking")
        #expect(blocks.first?["data"] as? String == "encrypted-data")
    }

    @Test
    func assistantBlocksReplayThinkingBeforeTextAndToolUse() {
        let message: [String: Any] = [
            "role": "assistant",
            "content": "Final answer.",
            "thinking_blocks": "[{\"type\":\"thinking\",\"thinking\":\"step\",\"signature\":\"sig\"}]",
            "tool_calls": [
                [
                    "id": "toolu_1",
                    "type": "function",
                    "function": ["name": "tool_local_ls", "arguments": "{}"]
                ]
            ]
        ]

        let blocks = AnthropicSubscriptionGenerationClient.assistantContentBlocks(
            from: message,
            includeThinkingBlocks: true
        )
        #expect(blocks.first?["type"] as? String == "thinking")
        #expect(blocks.contains { $0["type"] as? String == "text" })
        #expect(blocks.contains { $0["type"] as? String == "tool_use" })
    }

    @Test
    func assistantBlocksOmitThinkingWhenThinkingDisabled() {
        let message: [String: Any] = [
            "role": "assistant",
            "content": "Final answer.",
            "thinking_blocks": "[{\"type\":\"thinking\",\"thinking\":\"step\",\"signature\":\"sig\"}]"
        ]

        let blocks = AnthropicSubscriptionGenerationClient.assistantContentBlocks(
            from: message,
            includeThinkingBlocks: false
        )
        #expect(blocks.allSatisfy { $0["type"] as? String != "thinking" })
        #expect(blocks.contains { $0["type"] as? String == "text" })
    }

    @Test
    func messagesPayloadReplaysThinkingBlocksWhenEnabled() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "System."],
            ["role": "user", "content": "Hello"],
            [
                "role": "assistant",
                "content": "Working on it.",
                "thinking_blocks": "[{\"type\":\"thinking\",\"thinking\":\"step\",\"signature\":\"sig\"}]"
            ]
        ]

        let enabled = AnthropicSubscriptionGenerationClient.anthropicMessagesPayload(
            from: messages,
            includeThinkingBlocks: true
        )
        let assistant = enabled.messages.first { ($0["role"] as? String) == "assistant" }
        let assistantBlocks = assistant?["content"] as? [[String: Any]]
        #expect(assistantBlocks?.first?["type"] as? String == "thinking")

        let disabled = AnthropicSubscriptionGenerationClient.anthropicMessagesPayload(
            from: messages,
            includeThinkingBlocks: false
        )
        let assistantDisabled = disabled.messages.first { ($0["role"] as? String) == "assistant" }
        let disabledBlocks = assistantDisabled?["content"] as? [[String: Any]]
        #expect(disabledBlocks?.allSatisfy { $0["type"] as? String != "thinking" } == true)
    }

    @Test
    func savedSessionRoundTripPreservesThinkingBlocksForResumeReplay() {
        let thinkingBlocksJSON = #"[{"type":"thinking","thinking":"step","signature":"sig"}]"#
        let history = [
            AgentRuntimeMessage(role: .user, content: "Hello"),
            AgentRuntimeMessage(
                role: .assistant,
                content: "Working on it.",
                thinkingBlocksJSON: thinkingBlocksJSON
            )
        ]
        let messages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: "System.",
            history: history,
            allowedToolNames: []
        )
        let snapshot = RemoteGenerationClient.snapshotMessages(from: messages)
        let restoredMessages = RemoteGenerationClient.initialMessages(
            cwd: "/tmp/project",
            systemPrompt: snapshot.systemPrompt,
            history: snapshot.history,
            allowedToolNames: []
        )
        let payload = AnthropicSubscriptionGenerationClient.anthropicMessagesPayload(
            from: restoredMessages,
            includeThinkingBlocks: true
        )
        let assistant = payload.messages.first { ($0["role"] as? String) == "assistant" }
        let assistantBlocks = assistant?["content"] as? [[String: Any]]

        #expect(snapshot.history.last?.thinkingBlocksJSON == thinkingBlocksJSON)
        #expect(assistantBlocks?.first?["type"] as? String == "thinking")
        #expect(assistantBlocks?.first?["signature"] as? String == "sig")
    }

    @Test
    func anthropicCacheControlUsesOneHourTTLForSavedSessionResume() {
        let cacheControl = AnthropicSubscriptionGenerationClient.cacheControl()

        #expect(cacheControl["type"] as? String == "ephemeral")
        #expect(cacheControl["ttl"] as? String == "1h")
        #expect(
            AnthropicSubscriptionGenerationClient.oauthBetaHeader(
                forModelID: "claude-sonnet-4-20250514"
            ).contains("extended-cache-ttl")
        )
    }

    @Test
    func cacheUsageDiagnosticReportsHitRate() {
        let usage = RemoteGenerationUsage(
            promptTokens: 1_000,
            completionTokens: 200,
            totalTokens: 1_200,
            cachedPromptTokens: 800,
            promptTokensPerSecond: nil,
            completionTokensPerSecond: nil
        )
        let diagnostic = RemoteGenerationClient.cacheUsageDiagnostic(
            provider: "Anthropic",
            usage: usage
        )
        #expect(diagnostic?.contains("cached=800") == true)
        #expect(diagnostic?.contains("new=200") == true)
        #expect(diagnostic?.contains("cache_hit=80%") == true)
    }
}
#endif
