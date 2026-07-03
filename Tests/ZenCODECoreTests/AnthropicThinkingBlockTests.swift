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

    @Test
    func subscriptionSystemBlocksMarkOnlyLastBlockForCaching() {
        let withUserPrompt = AnthropicSubscriptionGenerationClient.subscriptionSystemBlocks(
            userSystemPrompt: "Project instructions"
        )
        let spineOnly = AnthropicSubscriptionGenerationClient.subscriptionSystemBlocks(
            userSystemPrompt: nil
        )

        #expect(withUserPrompt.count == 2)
        #expect(withUserPrompt[0]["cache_control"] == nil)
        #expect(withUserPrompt[1]["cache_control"] != nil)
        #expect(spineOnly.count == 1)
        #expect(spineOnly[0]["cache_control"] != nil)
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
    func cacheControlBreakpointsMarkLastThreeMessagesSkippingThinkingBlocks() throws {
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

        // Last three messages carry a breakpoint; earlier ones do not.
        #expect(try anyMarked(0) == false)
        #expect(try anyMarked(1) == false)
        #expect(try lastBlock(2)["cache_control"] != nil)
        #expect(try lastBlock(4)["cache_control"] != nil)

        // On the assistant tool-use turn the breakpoint lands on the
        // tool_use block, never on the thinking block.
        let assistantContent = try #require(marked[3]["content"] as? [[String: Any]])
        #expect(assistantContent[0]["cache_control"] == nil)
        #expect(assistantContent[1]["cache_control"] != nil)
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
}
#endif
