//
//  RemoteGenerationMetricsTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 31/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

@Suite
struct RemoteGenerationMetricsTests {
    @Test
    func generationMetricsUsesLatestRoundCountsAndKeepsSummaryAggregated() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let stats = [
            RemoteGenerationStats(
                usage: RemoteGenerationUsage(
                    promptTokens: 6_000,
                    completionTokens: 50,
                    totalTokens: 6_050,
                    contextTokens: 6_050,
                    processedPromptTokens: 6_000,
                    cachedPromptTokens: 0,
                ),
                requestStartedAt: startedAt,
                firstDeltaAt: nil,
                finishedAt: startedAt,
                generatedCharacterCount: 0
            ),
            RemoteGenerationStats(
                usage: RemoteGenerationUsage(
                    promptTokens: 4_300,
                    completionTokens: 25,
                    totalTokens: 4_325,
                    contextTokens: 4_325,
                    processedPromptTokens: 200,
                    cachedPromptTokens: 4_100,
                ),
                requestStartedAt: startedAt,
                firstDeltaAt: nil,
                finishedAt: startedAt,
                generatedCharacterCount: 0
            )
        ]

        let metrics = RemoteGenerationClient.generationMetrics(stats)
        let summary = RemoteGenerationClient.generationSummary(stats)

        #expect(metrics?.promptTokenCount == 200)
        #expect(metrics?.cachedPromptTokenCount == 4_100)
        #expect(metrics?.completionTokenCount == 25)
        #expect(metrics?.contextTokenCount == 4_325)
        #expect(metrics?.clearsPromptMetrics == true)
        #expect(metrics?.replacesPreviousMetrics == true)
        #expect(
            metrics.flatMap(TerminalStatusBar.generationTokenCountsFragment) == "c:4.1k p:200 g:25"
        )
        #expect(summary?.contains("Rounds: 2") == true)
        #expect(summary?.contains("Output: 75 tokens") == true)
    }

    @Test
    func generationMetricsDoesNotReusePromptCountsWhenLatestRoundHasNoUsage() throws {
        let startedAt = Date(timeIntervalSince1970: 100)
        let metrics = try #require(
            RemoteGenerationClient.generationMetrics([
                RemoteGenerationStats(
                    usage: RemoteGenerationUsage(
                        promptTokens: 1_000,
                        completionTokens: 10,
                        totalTokens: 1_010,
                        contextTokens: 1_010,
                        processedPromptTokens: 200,
                        cachedPromptTokens: 800,
                    ),
                    requestStartedAt: startedAt,
                    firstDeltaAt: nil,
                    finishedAt: startedAt,
                    generatedCharacterCount: 0
                ),
                RemoteGenerationStats(
                    usage: nil,
                    requestStartedAt: startedAt,
                    firstDeltaAt: nil,
                    finishedAt: startedAt,
                    generatedCharacterCount: 0
                )
            ])
        )
        let mergedMetrics = TerminalStatusBar(isEnabled: false).mergedMetrics(
            current: DirectAgentGenerationMetrics(
                promptTokenCount: 300,
                cachedPromptTokenCount: 700,
                completionTokenCount: 5,
                contextTokenCount: 1_005
            ),
            update: metrics
        )

        #expect(metrics.promptTokenCount == nil)
        #expect(metrics.cachedPromptTokenCount == nil)
        #expect(metrics.contextTokenCount == nil)
        #expect(metrics.completionTokenCount == nil)
        #expect(metrics.clearsPromptMetrics)
        #expect(metrics.replacesPreviousMetrics)
        #expect(mergedMetrics.promptTokenCount == nil)
        #expect(mergedMetrics.cachedPromptTokenCount == nil)
        #expect(mergedMetrics.completionTokenCount == nil)
        #expect(mergedMetrics.contextTokenCount == nil)
    }

    @Test
    func responsesUsageSeparatesCachedAndFreshPromptTokens() throws {
        let usage = try #require(
            RemoteGenerationClient.parsedUsage(
                from: [
                    "input_tokens": 25_000,
                    "input_tokens_details": ["cached_tokens": 20_000],
                    "output_tokens": 3_000,
                    "total_tokens": 28_000
                ]
            )
        )
        let metrics = try #require(
            RemoteGenerationClient.generationMetrics([
                RemoteGenerationStats(
                    usage: usage,
                    requestStartedAt: Date(timeIntervalSince1970: 100),
                    firstDeltaAt: nil,
                    finishedAt: Date(timeIntervalSince1970: 101),
                    generatedCharacterCount: 0
                )
            ])
        )

        #expect(usage.promptTokens == 25_000)
        #expect(usage.processedPromptTokens == 5_000)
        #expect(usage.cachedPromptTokens == 20_000)
        #expect(metrics.promptTokenCount == 5_000)
        #expect(metrics.cachedPromptTokenCount == 20_000)
        #expect(metrics.completionTokenCount == 3_000)
        #expect(
            TerminalStatusBar.generationTokenCountsFragment(metrics)
                == "c:20k p:5.0k g:3.0k"
        )
    }

    @Test
    func anthropicSubscriptionContextEstimateIncludesSystemAndTools() throws {
        let messages = [
            [
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": "Summarize the current workspace."
                    ]
                ]
            ] as [String: Any]
        ]
        let system = [
            [
                "type": "text",
                "text": String(repeating: "Follow the coding instructions. ", count: 40)
            ]
        ]
        let tools = [
            [
                "name": "tool_local_exec",
                "description": "Run a shell command.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string"]
                    ],
                    "required": ["command"]
                ]
            ] as [String: Any]
        ]

        let messageOnlyEstimate = try #require(
            AnthropicSubscriptionRequestBuilder.estimatedContextTokenCount(
                system: [],
                messages: messages,
                tools: []
            )
        )
        let withSystemEstimate = try #require(
            AnthropicSubscriptionRequestBuilder.estimatedContextTokenCount(
                system: system,
                messages: messages,
                tools: []
            )
        )
        let withToolsEstimate = try #require(
            AnthropicSubscriptionRequestBuilder.estimatedContextTokenCount(
                system: system,
                messages: messages,
                tools: tools
            )
        )

        #expect(withSystemEstimate > messageOnlyEstimate)
        #expect(withToolsEstimate > withSystemEstimate)
    }

    @Test
    func anthropicSubscriptionPreflightCompactsWhenEstimatedPayloadExceedsUsableContext() throws {
        let maxTokens = 30_000
        let maxOutputTokens = 4_000
        let messages = anthropicPreflightCompactionMessages()
        let normalResult = AnthropicSubscriptionGenerationClient.compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens
        )
        let toolCatalog = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "tool_large_context",
                    description: String(repeating: "large tool description ", count: 3_000),
                    inputSchema: #"{"type":"object","properties":{"query":{"type":"string"}}}"#
                )
            ]
        )
        // The estimate must describe the very messages that are compacted,
        // otherwise the decomposition measures one request and the policy
        // rewrites another.
        let anthropicPayload = AnthropicSubscriptionGenerationClient.anthropicMessagesPayload(
            from: toolCatalog.wireMessages(from: messages),
            includeThinkingBlocks: false
        )
        let anthropicTools = AnthropicSubscriptionGenerationClient.anthropicTools(
            from: toolCatalog.bindings
        )
        let estimatedContextTokens = try #require(
            AnthropicSubscriptionRequestBuilder.estimatedContextTokenCount(
                system: AnthropicSubscriptionGenerationClient.subscriptionSystemBlocks(
                    userSystemPrompt: anthropicPayload.system
                ),
                messages: AnthropicSubscriptionGenerationClient.addingCacheControlBreakpoints(
                    anthropicPayload.messages
                ),
                tools: anthropicTools
            )
        )
        let policyMaxTokens = try #require(
            AnthropicSubscriptionGenerationClient.compactionPolicyMaxTokens(
                for: maxTokens,
                maxOutputTokens: maxOutputTokens
            )
        )
        let requestEstimate = AnthropicSubscriptionGenerationClient.requestEstimate(
            estimatedContextTokens: estimatedContextTokens,
            tools: anthropicTools
        )
        let overhead = SubscriptionCompactionSupport.requestOverhead(
            estimate: requestEstimate,
            messages: messages
        )
        let preflightResult = try #require(
            AnthropicSubscriptionGenerationClient.compactedMessagesForEstimatedContextIfNeeded(
                messages,
                estimate: requestEstimate,
                maxTokens: maxTokens,
                maxOutputTokens: maxOutputTokens
            )
        )
        let compactedMessages = RemoteGenerationClient.remoteMessages(
            compactionResult: preflightResult,
            preservingRecentFrom: messages
        )

        #expect(normalResult.wasCompacted == false)
        // The policy budget is now the tokens the conversation may actually
        // occupy, so it equals the window minus the reserved output.
        #expect(policyMaxTokens == maxTokens - maxOutputTokens)
        #expect(estimatedContextTokens > AgentConversationCompactionPolicy.triggerTokenCount(for: policyMaxTokens))
        #expect(preflightResult.wasCompacted)
        #expect(preflightResult.estimatedTokenCount < preflightResult.originalEstimatedTokenCount)
        #expect(compactedMessages.count < messages.count)
        #expect(
            Int(
                Double(preflightResult.estimatedTokenCount)
                    * overhead.conversationInflationFactor
            )
                + overhead.staticOverheadTokens
                + maxOutputTokens <= maxTokens
        )
    }

    @Test
    func anthropicSubscriptionContextLimitRetryRemovesASubstantialPartOfTheHistory() throws {
        let maxTokens = 200_000
        let maxOutputTokens = 32_000
        let messages = anthropicPreflightCompactionMessages()
        let rawTokenCount = AgentConversationCompactionSupport.estimatedTokenCount(
            for: RemoteGenerationClient.agentRuntimeMessages(from: messages)
        )
        // The conversation is far below the window, so an ordinary manual
        // force retains at most floor(raw * 0.9). The provider-rejected retry
        // must still make the more aggressive 50% cut.
        let forced = AnthropicSubscriptionGenerationClient.compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            force: true
        )
        let retry = AnthropicSubscriptionGenerationClient.compactedMessagesForContextLimitRetry(
            messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            overhead: SubscriptionCompactionSupport.RequestOverhead(
                staticOverheadTokens: 40_000,
                conversationInflationFactor: 1.0
            )
        )

        #expect(forced.wasCompacted)
        #expect(
            forced.estimatedTokenCount
                <= Int((Double(rawTokenCount) * 0.9).rounded(.down))
        )
        #expect(retry.wasCompacted)
        #expect(
            Double(retry.estimatedTokenCount)
                <= Double(rawTokenCount)
                    * AgentConversationCompactionPolicy.contextLimitRetryRetentionFraction
        )
        #expect(retry.estimatedTokenCount < forced.estimatedTokenCount)
        #expect(retry.keptRecentMessageCount < forced.keptRecentMessageCount)
        #expect(
            retry.keptRecentMessageCount
                >= AgentConversationCompactionPolicy.minimumRecentMessageCount
        )
        #expect(retry.messages.first?.role == .system)
        #expect(retry.maxTokens == maxTokens)
    }

    @Test
    func anthropicSubscriptionContextLimitRetryStillShrinksWithoutAKnownWindow() {
        let messages = anthropicPreflightCompactionMessages()
        let rawTokenCount = AgentConversationCompactionSupport.estimatedTokenCount(
            for: RemoteGenerationClient.agentRuntimeMessages(from: messages)
        )
        let retry = AnthropicSubscriptionGenerationClient.compactedMessagesForContextLimitRetry(
            messages,
            maxTokens: nil
        )

        // Without a declared context window the ordinary policy cannot compact
        // at all; the single retry after an explicit provider rejection still
        // has to make room.
        #expect(
            AnthropicSubscriptionGenerationClient.compactedMessagesIfNeeded(
                messages,
                maxTokens: nil,
                force: true
            ).wasCompacted == false
        )
        #expect(retry.wasCompacted)
        #expect(
            Double(retry.estimatedTokenCount)
                <= Double(rawTokenCount)
                    * AgentConversationCompactionPolicy.contextLimitRetryRetentionFraction
        )
    }

    @Test
    func anthropicSubscriptionPayloadSanitizerPreservesValidEmojiAndEncodesJSON() throws {
        let emoji = "Valid emoji: 😀 👩‍💻"
        let payload: [String: Any] = [
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": emoji
                        ]
                    ]
                ] as [String: Any]
            ]
        ]

        let sanitized = AnthropicSubscriptionRequestBuilder.sanitizedPayload(payload)
        let data = try JSONValue(jsonObject: sanitized).jsonData(
            outputFormatting: [.withoutEscapingSlashes]
        )
        let encoded = try #require(String(data: data, encoding: .utf8))

        #expect(encoded.contains("😀"))
        #expect(encoded.contains("👩‍💻"))
    }

    @Test
    func anthropicSubscriptionPayloadSanitizerReplacesUnpairedSurrogates() throws {
        var rawUnits: [unichar] = [0xD800, 0x0061, 0xDC00]
        var rawKeyUnits: [unichar] = [0x0062, 0x0061, 0x0064, 0xD800, 0x006B, 0x0065, 0x0079]
        let bridgedString = NSString(characters: &rawUnits, length: rawUnits.count) as String
        let bridgedKey = NSString(characters: &rawKeyUnits, length: rawKeyUnits.count) as String
        let payload: [String: Any] = [
            bridgedKey: [
                "text": bridgedString
            ]
        ]

        let sanitized = AnthropicSubscriptionRequestBuilder.sanitizedPayload(payload)
        let data = try JSONValue(jsonObject: sanitized).jsonData(
            outputFormatting: [.withoutEscapingSlashes]
        )
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        let decodedObject = try #require(decoded.objectValue)
        let decodedKey = try #require(decodedObject.keys.first)
        let decodedNestedObject = try #require(decodedObject[decodedKey]?.objectValue)
        let decodedText = try #require(decodedNestedObject["text"]?.stringValue)

        #expect(String(data: data, encoding: .utf8) != nil)
        #expect(!containsUTF16Surrogate(decodedKey))
        #expect(!containsUTF16Surrogate(decodedText))
        #expect(decodedText.contains("�"))
    }

    @Test
    func anthropicSubscriptionUsageSeparatesCachedAndFreshInputTokens() throws {
        let usage = try #require(
            AnthropicSubscriptionRequestBuilder.usage(
                from: [
                    "input_tokens": 120,
                    "cache_read_input_tokens": 800,
                    "cache_creation_input_tokens": 40,
                    "output_tokens": 2
                ]
            )
        )

        #expect(usage.promptTokens == 960)
        #expect(usage.processedPromptTokens == 160)
        #expect(usage.cachedPromptTokens == 800)
        #expect(usage.completionTokens == 2)
        #expect(usage.totalTokens == 962)
        #expect(usage.contextTokens == 962)

        let updatedUsage = try #require(
            AnthropicSubscriptionRequestBuilder.usage(
                from: [
                    "output_tokens": 32
                ],
                previous: usage
            )
        )

        #expect(updatedUsage.promptTokens == 960)
        #expect(updatedUsage.processedPromptTokens == 160)
        #expect(updatedUsage.cachedPromptTokens == 800)
        #expect(updatedUsage.completionTokens == 32)
        #expect(updatedUsage.totalTokens == 992)
        #expect(updatedUsage.contextTokens == 992)

        let creationOnlyUsage = try #require(
            AnthropicSubscriptionRequestBuilder.usage(
                from: [
                    "input_tokens": 120,
                    "cache_creation_input_tokens": 40,
                    "output_tokens": 2
                ]
            )
        )
        #expect(creationOnlyUsage.promptTokens == 160)
        #expect(creationOnlyUsage.processedPromptTokens == 160)
        #expect(creationOnlyUsage.cachedPromptTokens == nil)

        let readOnlyUsage = try #require(
            AnthropicSubscriptionRequestBuilder.usage(
                from: [
                    "input_tokens": 120,
                    "cache_read_input_tokens": 800,
                    "output_tokens": 2
                ]
            )
        )
        #expect(readOnlyUsage.promptTokens == 920)
        #expect(readOnlyUsage.processedPromptTokens == 120)
        #expect(readOnlyUsage.cachedPromptTokens == 800)
    }

    @Test
    func anthropicSubscriptionVisibleMetricsPreservesPromptMetricsAndClearsPreviousValues() {
        let visibleMetrics = AnthropicSubscriptionGenerationClient
            .anthropicSubscriptionVisibleMetrics(
                DirectAgentGenerationMetrics(
                    promptTokenCount: 160,
                    cachedPromptTokenCount: 800,
                    completionTokenCount: 32,
                    responseDurationSeconds: 4,
                    contextTokenCount: 992
                )
            )

        #expect(visibleMetrics.promptTokenCount == 160)
        #expect(visibleMetrics.cachedPromptTokenCount == 800)
        #expect(visibleMetrics.completionTokenCount == 32)
        #expect(visibleMetrics.responseDurationSeconds == 4)
        #expect(visibleMetrics.contextTokenCount == 992)
        #expect(visibleMetrics.clearsPromptMetrics)
        #expect(visibleMetrics.replacesPreviousMetrics)
    }

    @Test
    func chatGPTSubscriptionVisibleMetricsPreservesPromptMetricsAndClearsPreviousValues() {
        let visibleMetrics = ChatGPTSubscriptionGenerationClient
            .chatGPTSubscriptionVisibleMetrics(
                DirectAgentGenerationMetrics(
                    promptTokenCount: 120,
                    cachedPromptTokenCount: 800,
                    completionTokenCount: 32,
                    responseDurationSeconds: 4,
                    contextTokenCount: 992
                )
            )

        #expect(visibleMetrics.promptTokenCount == 120)
        #expect(visibleMetrics.cachedPromptTokenCount == 800)
        #expect(visibleMetrics.completionTokenCount == 32)
        #expect(visibleMetrics.responseDurationSeconds == 4)
        #expect(visibleMetrics.contextTokenCount == 992)
        #expect(visibleMetrics.clearsPromptMetrics)
        #expect(visibleMetrics.replacesPreviousMetrics)
    }

    @Test
    func promptCacheWarningRequiresContinuationAndReportedCacheMiss() {
        let usage = RemoteGenerationUsage(
            promptTokens: 4_000,
            completionTokens: 10,
            totalTokens: 4_010,
            processedPromptTokens: 4_000,
            cachedPromptTokens: 0,
        )

        #expect(
            RemoteGenerationClient.promptCacheWarning(
                provider: "Unit",
                usage: usage,
                expectsCacheRead: false
            ) == nil
        )

        let warning = RemoteGenerationClient.promptCacheWarning(
            provider: "Unit",
            usage: usage,
            expectsCacheRead: true
        )
        #expect(warning?.contains("Cache warning: Unit") == true)
        #expect(warning?.contains("cached=0") == true)
    }

    @Test
    func promptCacheWarningIgnoresShortPromptsAndHealthyHitRates() {
        let shortUsage = RemoteGenerationUsage(
            promptTokens: 800,
            completionTokens: 10,
            totalTokens: 810,
            processedPromptTokens: 800,
            cachedPromptTokens: 0,
        )
        let healthyUsage = RemoteGenerationUsage(
            promptTokens: 4_000,
            completionTokens: 10,
            totalTokens: 4_010,
            processedPromptTokens: 500,
            cachedPromptTokens: 3_500,
        )

        #expect(
            RemoteGenerationClient.promptCacheWarning(
                provider: "Unit",
                usage: shortUsage,
                expectsCacheRead: true
            ) == nil
        )
        #expect(
            RemoteGenerationClient.promptCacheWarning(
                provider: "Unit",
                usage: healthyUsage,
                expectsCacheRead: true
            ) == nil
        )
    }

    @Test
    func messagesExpectPromptCacheAfterAssistantOrToolHistory() {
        #expect(
            !RemoteGenerationClient.messagesExpectPromptCache([
                ["role": "system", "content": "System"],
                ["role": "user", "content": "First prompt"]
            ])
        )
        #expect(
            RemoteGenerationClient.messagesExpectPromptCache([
                ["role": "system", "content": "System"],
                ["role": "user", "content": "First prompt"],
                ["role": "assistant", "content": "Answer"],
                ["role": "user", "content": "Second prompt"]
            ])
        )
        #expect(
            RemoteGenerationClient.messagesExpectPromptCache([
                ["role": "user", "content": "Prompt"],
                ["role": "tool", "content": "Tool result"]
            ])
        )
    }

}

private func anthropicPreflightCompactionMessages() -> [[String: Any]] {
    var messages: [[String: Any]] = [
        [
            "role": "system",
            "content": "System prompt"
        ]
    ]
    for index in 0..<120 {
        let role = index.isMultiple(of: 2) ? "user" : "assistant"
        messages.append(
            RemoteGenerationClient.remoteMessage(
                role: role,
                content: "brief message \(index) " + String(repeating: "detail ", count: 30),
                attachments: []
            )
        )
    }
    return messages
}

private func containsUTF16Surrogate(_ string: String) -> Bool {
    string.utf16.contains { (0xD800...0xDFFF).contains($0) }
}
