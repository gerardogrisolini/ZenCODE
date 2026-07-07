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
    func messagesPayloadDropsThinkingOnlyAssistantMessages() {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "Hello"],
            [
                "role": "assistant",
                "thinking_blocks": "[{\"type\":\"thinking\",\"thinking\":\"step\",\"signature\":\"sig\"}]"
            ],
            ["role": "user", "content": "continue"]
        ]

        let payload = AnthropicSubscriptionGenerationClient.anthropicMessagesPayload(
            from: messages,
            includeThinkingBlocks: true
        )

        #expect(payload.messages.map { $0["role"] as? String } == ["user", "user"])
    }

    @Test
    func messagesPayloadDropsInvalidThinkingBlocksBeforeReplay() throws {
        let messages: [[String: Any]] = [
            [
                "role": "assistant",
                "content": "Working on it.",
                "thinking_blocks": """
                [
                  {"type":"thinking","thinking":"unsigned"},
                  {"type":"redacted_thinking"},
                  {"type":"thinking","thinking":"valid","signature":"sig"}
                ]
                """
            ]
        ]

        let payload = AnthropicSubscriptionGenerationClient.anthropicMessagesPayload(
            from: messages,
            includeThinkingBlocks: true
        )
        let assistant = try #require(payload.messages.first)
        let blocks = try #require(assistant["content"] as? [[String: Any]])

        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "thinking")
        #expect(blocks[0]["thinking"] as? String == "valid")
        #expect(blocks[1]["type"] as? String == "text")
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
        let systemCacheControl = AnthropicSubscriptionGenerationClient.systemCacheControl()

        #expect(cacheControl["type"] as? String == "ephemeral")
        #expect(cacheControl["ttl"] as? String == "1h")
        #expect(cacheControl["scope"] == nil)
        #expect(systemCacheControl["type"] as? String == "ephemeral")
        #expect(systemCacheControl["ttl"] as? String == "1h")
        #expect(systemCacheControl["scope"] as? String == "global")
        #expect(
            AnthropicSubscriptionGenerationClient.oauthBetaHeader(
                forModelID: "claude-sonnet-4-20250514"
            ).contains("extended-cache-ttl")
        )
        #expect(
            AnthropicSubscriptionGenerationClient.oauthBetaHeader(
                forModelID: "claude-sonnet-4-20250514"
            ).contains("prompt-caching-scope")
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

    @Test
    func subscriptionSystemBlocksMarkOnlyLastBlockForCaching() throws {
        let withUserPrompt = AnthropicSubscriptionGenerationClient.subscriptionSystemBlocks(
            userSystemPrompt: "Project instructions"
        )
        let spineOnly = AnthropicSubscriptionGenerationClient.subscriptionSystemBlocks(
            userSystemPrompt: nil
        )

        #expect(withUserPrompt.count == 2)
        #expect(withUserPrompt[0]["cache_control"] == nil)
        let withUserCacheControl = try #require(
            withUserPrompt[1]["cache_control"] as? [String: Any]
        )
        #expect(withUserCacheControl["scope"] as? String == "global")
        #expect(spineOnly.count == 1)
        let spineCacheControl = try #require(
            spineOnly[0]["cache_control"] as? [String: Any]
        )
        #expect(spineCacheControl["scope"] as? String == "global")
    }

    @Test
    func anthropicToolsCarryNoCacheBreakpoint() throws {
        let descriptor = DirectToolDescriptor(
            name: "local.exec",
            description: "Runs a command",
            inputSchema: #"{"type":"object","properties":{}}"#
        )
        let tools = AnthropicSubscriptionGenerationClient.anthropicTools(
            from: RemoteToolWireCatalog(descriptors: [descriptor]).bindings
        )

        #expect(tools.count == 1)
        #expect(tools.allSatisfy { $0["cache_control"] == nil })
    }

    @Test
    func cacheControlBreakpointsMarkLastMessageSkippingThinkingBlocks() throws {
        let messages: [[String: Any]] = [
            ["role": "user", "content": [["type": "text", "text": "first"]]],
            ["role": "assistant", "content": [["type": "text", "text": "old answer"]]],
            ["role": "user", "content": [["type": "text", "text": "second"]]],
            [
                "role": "assistant",
                "content": [
                    ["type": "thinking", "thinking": "hidden", "signature": "sig"],
                    ["type": "tool_use", "id": "toolu_1", "name": "local.exec", "input": [:]]
                ]
            ],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"]]]
        ]
        let marked = AnthropicSubscriptionGenerationClient.addingCacheControlBreakpoints(messages)

        func lastBlock(_ index: Int) throws -> [String: Any] {
            let content = try #require(marked[index]["content"] as? [[String: Any]])
            return try #require(content.last)
        }
        func anyMarked(_ index: Int) throws -> Bool {
            let content = try #require(marked[index]["content"] as? [[String: Any]])
            return content.contains { $0["cache_control"] != nil }
        }

        // Claude Code uses one moving message-level breakpoint per request.
        #expect(try anyMarked(0) == false)
        #expect(try anyMarked(1) == false)
        #expect(try anyMarked(2) == false)
        #expect(try anyMarked(3) == false)
        #expect(try lastBlock(4)["cache_control"] != nil)
    }

    @Test
    func cacheControlBreakpointSkipsThinkingBlocks() throws {
        let messages: [[String: Any]] = [
            [
                "role": "assistant",
                "content": [
                    ["type": "thinking", "thinking": "hidden", "signature": "sig"],
                    ["type": "tool_use", "id": "toolu_1", "name": "local.exec", "input": [:]]
                ]
            ]
        ]
        let marked = AnthropicSubscriptionGenerationClient.addingCacheControlBreakpoints(messages)
        let assistantContent = try #require(marked[0]["content"] as? [[String: Any]])

        #expect(assistantContent[0]["cache_control"] == nil)
        let assistantCacheControl = try #require(
            assistantContent[1]["cache_control"] as? [String: Any]
        )
        #expect(assistantCacheControl["ttl"] as? String == "1h")
        #expect(assistantCacheControl["scope"] == nil)
    }

    @Test
    func cacheControlBreakpointsUpgradeStringContent() throws {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "plain text"]
        ]
        let marked = AnthropicSubscriptionGenerationClient.addingCacheControlBreakpoints(messages)
        let content = try #require(marked[0]["content"] as? [[String: Any]])

        #expect(content.first?["type"] as? String == "text")
        #expect(content.first?["text"] as? String == "plain text")
        #expect(content.first?["cache_control"] != nil)
    }

    @Test
    func oauthBetaHeaderMatchesClaudeCodeCachingAndThinkingBetas() {
        let adaptiveHeader = AnthropicSubscriptionGenerationClient.oauthBetaHeader(
            forModelID: "claude-opus-4-8"
        )
        let interleavedHeader = AnthropicSubscriptionGenerationClient.oauthBetaHeader(
            forModelID: "claude-haiku-4-5"
        )

        #expect(adaptiveHeader.contains("claude-code-20250219"))
        #expect(adaptiveHeader.contains("oauth-2025-04-20"))
        #expect(adaptiveHeader.contains("context-management-2025-06-27"))
        #expect(adaptiveHeader.contains("prompt-caching-scope-2026-01-05"))
        #expect(adaptiveHeader.contains("extended-cache-ttl-2025-04-11"))
        #expect(adaptiveHeader.contains("context-1m-2025-08-07"))
        #expect(adaptiveHeader.contains("effort-2025-11-24"))
        #expect(!adaptiveHeader.contains("advanced-tool-use-2025-11-20"))
        #expect(!adaptiveHeader.contains("afk-mode-2026-01-31"))
        #expect(!adaptiveHeader.contains("interleaved-thinking-2025-05-14"))

        #expect(interleavedHeader.contains("interleaved-thinking-2025-05-14"))
        #expect(!interleavedHeader.contains("context-1m-2025-08-07"))
    }

    @Test
    func adaptiveThinkingModelsOmitDisabledThinkingPayload() throws {
        let nilSelection = AnthropicSubscriptionGenerationClient.thinkingPayload(
            for: nil,
            modelID: "claude-fable-5",
            maxTokens: 4096
        )
        let offSelection = AnthropicSubscriptionGenerationClient.thinkingPayload(
            for: .off,
            modelID: "claude-fable-5",
            maxTokens: 4096
        )
        let nonAdaptiveOff = AnthropicSubscriptionGenerationClient.thinkingPayload(
            for: .off,
            modelID: "claude-haiku-4-5",
            maxTokens: 4096
        )

        #expect(nilSelection.thinking == nil)
        #expect(nilSelection.outputConfig == nil)
        #expect(offSelection.thinking == nil)
        #expect(offSelection.outputConfig == nil)
        #expect(nonAdaptiveOff.thinking?["type"] as? String == "disabled")
    }

    @Test
    func adaptiveThinkingModelsUseAdaptiveSummarizedThinking() throws {
        let payload = AnthropicSubscriptionGenerationClient.thinkingPayload(
            for: .high,
            modelID: "claude-fable-5",
            maxTokens: 8192
        )
        let thinking = try #require(payload.thinking)
        let outputConfig = try #require(payload.outputConfig)

        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["budget_tokens"] == nil)
        #expect(thinking["display"] as? String == "summarized")
        #expect(outputConfig["effort"] as? String == "high")
    }

    @Test
    func otherAdaptiveThinkingModelsDoNotForceSummarizedDisplay() throws {
        let payload = AnthropicSubscriptionGenerationClient.thinkingPayload(
            for: .high,
            modelID: "claude-opus-4-8",
            maxTokens: 8192
        )
        let thinking = try #require(payload.thinking)

        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["display"] == nil)
        #expect(payload.outputConfig?["effort"] as? String == "high")
    }

    @Test
    func manualThinkingModelsUseEnabledBudgetWithoutForcedDisplay() throws {
        let payload = AnthropicSubscriptionGenerationClient.thinkingPayload(
            for: .high,
            modelID: "claude-haiku-4-5",
            maxTokens: 8192
        )
        let thinking = try #require(payload.thinking)

        #expect(thinking["type"] as? String == "enabled")
        #expect((thinking["budget_tokens"] as? Int ?? 0) > 0)
        #expect(thinking["display"] == nil)
        #expect(payload.outputConfig == nil)
    }

    @Test
    func thinkingReplayRejectionStripsSavedThinkingBlocks() {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "Hello"],
            [
                "role": "assistant",
                "content": "Working.",
                "thinking_blocks": "[{\"type\":\"thinking\",\"thinking\":\"step\",\"signature\":\"sig\"}]"
            ]
        ]
        let stripped = AnthropicSubscriptionGenerationClient.removingThinkingBlocks(
            from: messages
        )

        #expect(stripped[0]["thinking_blocks"] == nil)
        #expect(stripped[1]["thinking_blocks"] == nil)
        #expect(stripped[1]["content"] as? String == "Working.")
        #expect(
            AnthropicSubscriptionGenerationClient.messageIndicatesThinkingReplayRejected(
                "invalid_thinking_signature: invalid signature in thinking block"
            )
        )
        #expect(
            AnthropicSubscriptionGenerationClient.messageIndicatesThinkingReplayRejected(
                "Thinking blocks cannot be modified between requests."
            )
        )
        #expect(
            !AnthropicSubscriptionGenerationClient.messageIndicatesThinkingReplayRejected(
                "The service is overloaded."
            )
        )
    }
}
#endif
