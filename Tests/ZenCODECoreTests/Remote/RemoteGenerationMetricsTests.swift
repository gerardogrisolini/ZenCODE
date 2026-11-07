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
