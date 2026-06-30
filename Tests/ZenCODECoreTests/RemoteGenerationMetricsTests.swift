//
//  RemoteGenerationMetricsTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 31/05/26.
//
import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct RemoteGenerationMetricsTests {
    @Test
    func generationMetricsCanEstimateMissingStreamingRates() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let firstDeltaAt = startedAt.addingTimeInterval(2)
        let finishedAt = firstDeltaAt.addingTimeInterval(4)
        let stats = [
            RemoteGenerationStats(
                usage: RemoteGenerationUsage(
                    promptTokens: 100,
                    completionTokens: 40,
                    totalTokens: 140,
                    promptTokensPerSecond: nil,
                    completionTokensPerSecond: nil
                ),
                requestStartedAt: startedAt,
                firstDeltaAt: firstDeltaAt,
                finishedAt: finishedAt,
                generatedCharacterCount: 120
            )
        ]

        let metrics = RemoteGenerationClient.generationMetrics(
            stats,
            estimateMissingRates: true
        )

        #expect(metrics?.promptTokensPerSecond == 50)
        #expect(metrics?.completionTokensPerSecond == 10)
        #expect(metrics?.responseDurationSeconds == 6)
    }

    @Test
    func generationMetricsKeepsMissingRatesEmptyUnlessEstimationIsEnabled() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let firstDeltaAt = startedAt.addingTimeInterval(2)
        let finishedAt = firstDeltaAt.addingTimeInterval(4)
        let stats = [
            RemoteGenerationStats(
                usage: RemoteGenerationUsage(
                    promptTokens: 100,
                    completionTokens: 40,
                    totalTokens: 140,
                    promptTokensPerSecond: nil,
                    completionTokensPerSecond: nil
                ),
                requestStartedAt: startedAt,
                firstDeltaAt: firstDeltaAt,
                finishedAt: finishedAt,
                generatedCharacterCount: 120
            )
        ]

        let metrics = RemoteGenerationClient.generationMetrics(stats)

        #expect(metrics?.promptTokensPerSecond == nil)
        #expect(metrics?.completionTokensPerSecond == nil)
        #expect(metrics?.responseDurationSeconds == 6)
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
        let estimatedContextTokens = try #require(
            AnthropicSubscriptionRequestBuilder.estimatedContextTokenCount(
                system: [
                    [
                        "type": "text",
                        "text": "System prompt"
                    ]
                ],
                messages: [
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "text",
                                "text": "Current request"
                            ]
                        ]
                    ] as [String: Any]
                ],
                tools: [
                    [
                        "name": "tool_large_context",
                        "description": String(repeating: "large tool description ", count: 6_000),
                        "input_schema": [
                            "type": "object",
                            "properties": [
                                "query": ["type": "string"]
                            ]
                        ]
                    ] as [String: Any]
                ]
            )
        )
        let policyMaxTokens = try #require(
            AnthropicSubscriptionGenerationClient.compactionPolicyMaxTokens(
                for: maxTokens,
                maxOutputTokens: maxOutputTokens
            )
        )
        let preflightResult = try #require(
            AnthropicSubscriptionGenerationClient.compactedMessagesForEstimatedContextIfNeeded(
                messages,
                estimatedContextTokens: estimatedContextTokens,
                maxTokens: maxTokens,
                maxOutputTokens: maxOutputTokens
            )
        )
        let compactedMessages = RemoteGenerationClient.remoteMessages(
            compactionResult: preflightResult,
            preservingRecentFrom: messages
        )

        #expect(normalResult.wasCompacted == false)
        #expect(AgentConversationCompactionPolicy.triggerTokenCount(for: policyMaxTokens) == maxTokens - maxOutputTokens)
        #expect(estimatedContextTokens > AgentConversationCompactionPolicy.triggerTokenCount(for: policyMaxTokens))
        #expect(preflightResult.wasCompacted)
        #expect(compactedMessages.count < messages.count)
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
        let decodedObject = try #require(decoded.mlxObjectValue)
        let decodedKey = try #require(decodedObject.keys.first)
        let decodedNestedObject = try #require(decodedObject[decodedKey]?.mlxObjectValue)
        let decodedText = try #require(decodedNestedObject["text"]?.stringValue)

        #expect(String(data: data, encoding: .utf8) != nil)
        #expect(!containsUTF16Surrogate(decodedKey))
        #expect(!containsUTF16Surrogate(decodedText))
        #expect(decodedText.contains("�"))
    }

    @Test
    func anthropicSubscriptionUsageIncludesCachedInputTokens() throws {
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
        #expect(usage.processedPromptTokens == 120)
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
        #expect(updatedUsage.processedPromptTokens == 120)
        #expect(updatedUsage.cachedPromptTokens == 800)
        #expect(updatedUsage.completionTokens == 32)
        #expect(updatedUsage.totalTokens == 992)
        #expect(updatedUsage.contextTokens == 992)
    }

    @Test
    func anthropicSubscriptionVisibleMetricsClearsPromptMetrics() {
        let visibleMetrics = AnthropicSubscriptionGenerationClient
            .anthropicSubscriptionVisibleMetrics(
                DirectAgentGenerationMetrics(
                    promptTokenCount: 120,
                    cachedPromptTokenCount: 800,
                    promptTokensPerSecond: 60,
                    completionTokenCount: 32,
                    completionTokensPerSecond: 8,
                    responseDurationSeconds: 4,
                    contextTokenCount: 992
                )
            )

        #expect(visibleMetrics.promptTokenCount == nil)
        #expect(visibleMetrics.cachedPromptTokenCount == nil)
        #expect(visibleMetrics.promptTokensPerSecond == nil)
        #expect(visibleMetrics.completionTokenCount == 32)
        #expect(visibleMetrics.completionTokensPerSecond == 8)
        #expect(visibleMetrics.responseDurationSeconds == 4)
        #expect(visibleMetrics.contextTokenCount == 992)
        #expect(visibleMetrics.clearsPromptMetrics)
    }

    @Test
    func chatGPTSubscriptionVisibleMetricsClearsPromptMetrics() {
        let visibleMetrics = ChatGPTSubscriptionGenerationClient
            .chatGPTSubscriptionVisibleMetrics(
                DirectAgentGenerationMetrics(
                    promptTokenCount: 120,
                    cachedPromptTokenCount: 800,
                    promptTokensPerSecond: 60,
                    completionTokenCount: 32,
                    completionTokensPerSecond: 8,
                    responseDurationSeconds: 4,
                    contextTokenCount: 992
                )
            )

        #expect(visibleMetrics.promptTokenCount == nil)
        #expect(visibleMetrics.cachedPromptTokenCount == nil)
        #expect(visibleMetrics.promptTokensPerSecond == nil)
        #expect(visibleMetrics.completionTokenCount == 32)
        #expect(visibleMetrics.completionTokensPerSecond == 8)
        #expect(visibleMetrics.responseDurationSeconds == 4)
        #expect(visibleMetrics.contextTokenCount == 992)
        #expect(visibleMetrics.clearsPromptMetrics)
    }

    @Test
    func promptCacheWarningRequiresContinuationAndReportedCacheMiss() {
        let usage = RemoteGenerationUsage(
            promptTokens: 4_000,
            completionTokens: 10,
            totalTokens: 4_010,
            processedPromptTokens: 4_000,
            cachedPromptTokens: 0,
            promptTokensPerSecond: nil,
            completionTokensPerSecond: nil
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
            promptTokensPerSecond: nil,
            completionTokensPerSecond: nil
        )
        let healthyUsage = RemoteGenerationUsage(
            promptTokens: 4_000,
            completionTokens: 10,
            totalTokens: 4_010,
            processedPromptTokens: 500,
            cachedPromptTokens: 3_500,
            promptTokensPerSecond: nil,
            completionTokensPerSecond: nil
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
    for index in 0..<6 {
        let role = index.isMultiple(of: 2) ? "user" : "assistant"
        messages.append(
            RemoteGenerationClient.remoteMessage(
                role: role,
                content: "brief message \(index) " + String(repeating: "detail ", count: 20),
                attachments: []
            )
        )
    }
    return messages
}

private func containsUTF16Surrogate(_ string: String) -> Bool {
    string.utf16.contains { (0xD800...0xDFFF).contains($0) }
}
