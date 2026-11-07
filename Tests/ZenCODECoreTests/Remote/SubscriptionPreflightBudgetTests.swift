//
//  SubscriptionPreflightBudgetTests.swift
//  ZenCODECoreTests
//
//  Exercises the real provider preflight paths: the ChatGPT and Anthropic
//  request builders produce the estimate, the shared preflight derives the
//  overhead from it, and the outcome must be a bounded, budget-respecting
//  decision rather than a loop.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct SubscriptionPreflightBudgetTests {
    @Test
    func chatGPTPreflightCompactsUntilTheEstimatedRequestFitsAndThenStops() throws {
        let contextWindowTokens = 50_000
        let reserveTokenCount = ChatGPTSubscriptionGenerationClient.compactionReserveTokenCount
        var messages = wireConversation()
        let originalCount = messages.count

        var compactions = 0
        var lastOutcome = SubscriptionCompactionSupport.PreflightOutcome.notNeeded
        while compactions <= AgentConversationCompactionPolicy.maximumPreflightCompactionAttempts {
            let estimate = try chatGPTEstimate(for: messages, toolDescriptionRepeats: 4_000)
            let outcome = SubscriptionCompactionSupport.preflightCompaction(
                messages,
                estimate: estimate,
                maxTokens: contextWindowTokens,
                maxOutputTokens: 1_000,
                reserveTokenCount: reserveTokenCount
            )
            lastOutcome = outcome
            guard case let .compacted(result) = outcome else {
                break
            }
            // Every accepted pass has to make progress, otherwise the provider
            // would resend an identical prompt forever.
            #expect(result.estimatedTokenCount < result.originalEstimatedTokenCount)
            messages = RemoteGenerationClient.remoteMessages(
                compactionResult: result,
                preservingRecentFrom: messages
            )
            compactions += 1
        }

        let finalEstimate = try chatGPTEstimate(for: messages, toolDescriptionRepeats: 4_000)
        #expect(compactions == 1)
        #expect(compactions <= AgentConversationCompactionPolicy.maximumPreflightCompactionAttempts)
        #expect(messages.count < originalCount)
        #expect(finalEstimate.totalTokens + reserveTokenCount <= contextWindowTokens)
        if case .compacted = lastOutcome {
            Issue.record("The preflight did not converge: it still wants to compact.")
        }
    }

    @Test
    func anthropicPreflightCompactsUntilTheEstimatedRequestFitsAndThenStops() throws {
        let contextWindowTokens = 30_000
        let maxOutputTokens = 4_000
        var messages = wireConversation()
        let originalCount = messages.count

        var compactions = 0
        var lastOutcome = SubscriptionCompactionSupport.PreflightOutcome.notNeeded
        while compactions <= AgentConversationCompactionPolicy.maximumPreflightCompactionAttempts {
            let estimate = try anthropicEstimate(for: messages, toolDescriptionRepeats: 3_000)
            let outcome = SubscriptionCompactionSupport.preflightCompaction(
                messages,
                estimate: estimate,
                maxTokens: contextWindowTokens,
                maxOutputTokens: maxOutputTokens,
                reserveTokenCount: AnthropicSubscriptionGenerationClient.compactionReserveTokenCount
            )
            lastOutcome = outcome
            guard case let .compacted(result) = outcome else {
                break
            }
            #expect(result.estimatedTokenCount < result.originalEstimatedTokenCount)
            messages = RemoteGenerationClient.remoteMessages(
                compactionResult: result,
                preservingRecentFrom: messages
            )
            compactions += 1
        }

        let finalEstimate = try anthropicEstimate(for: messages, toolDescriptionRepeats: 3_000)
        #expect(compactions == 1)
        #expect(messages.count < originalCount)
        #expect(finalEstimate.totalTokens + maxOutputTokens <= contextWindowTokens)
        if case .compacted = lastOutcome {
            Issue.record("The preflight did not converge: it still wants to compact.")
        }
    }

    @Test
    func anthropicPreflightStopsExplicitlyWhenNoConversationCanFit() throws {
        let messages = wireConversation()
        // A tool catalogue larger than the window itself: no conversation fits,
        // so the preflight must say so once instead of compacting towards an
        // unreachable target.
        let estimate = try anthropicEstimate(for: messages, toolDescriptionRepeats: 6_000)
        let outcome = SubscriptionCompactionSupport.preflightCompaction(
            messages,
            estimate: estimate,
            maxTokens: 30_000,
            maxOutputTokens: 4_000,
            reserveTokenCount: AnthropicSubscriptionGenerationClient.compactionReserveTokenCount
        )

        guard case let .unsatisfiableBudget(
            contextWindowTokens,
            reservedOutputTokens,
            overheadTokens
        ) = outcome else {
            Issue.record("Expected an unsatisfiable preflight budget, got \(outcome).")
            return
        }
        #expect(contextWindowTokens == 30_000)
        #expect(reservedOutputTokens == 4_000)
        #expect(reservedOutputTokens + overheadTokens >= contextWindowTokens)
        #expect(
            AnthropicSubscriptionGenerationClient.compactedMessagesForEstimatedContextIfNeeded(
                messages,
                estimate: estimate,
                maxTokens: 30_000,
                maxOutputTokens: 4_000
            ) == nil
        )
        #expect(
            AnthropicSubscriptionGenerationClient.unsatisfiableBudgetDiagnostic(
                contextWindowTokens: contextWindowTokens,
                maxOutputTokens: reservedOutputTokens,
                overheadTokens: overheadTokens
            ).contains("Anthropic Subscription")
        )
    }

    @Test
    func highUnicodeInflationIsNotCappedAndTheRebuiltAnthropicPayloadFits() throws {
        // One visible grapheme can encode many UTF-8 bytes. This mixes a ZWJ
        // sequence, a skin-tone modifier, a combining mark and escaped JSON
        // characters so the provider-wire estimate is well beyond the former
        // arbitrary factor-eight clamp.
        let messages = highInflationConversation(count: 180)
        let originalEstimate = try anthropicEstimate(
            for: messages,
            toolDescriptionRepeats: 20
        )
        let runtimeTokens = AgentConversationCompactionSupport.estimatedTokenCount(
            for: RemoteGenerationClient.agentRuntimeMessages(from: messages)
        )
        let overhead = SubscriptionCompactionSupport.requestOverhead(
            estimate: originalEstimate,
            runtimeConversationTokens: runtimeTokens
        )
        let maxOutputTokens = 1_000
        let contextWindowTokens = maxOutputTokens
            + originalEstimate.staticOverheadTokens
            + max(originalEstimate.conversationTokens / 2, 1)

        #expect(overhead.conversationInflationFactor > 8.0)

        let outcome = SubscriptionCompactionSupport.preflightCompaction(
            messages,
            estimate: originalEstimate,
            maxTokens: contextWindowTokens,
            maxOutputTokens: maxOutputTokens,
            reserveTokenCount: 0
        )
        guard case let .compacted(result) = outcome else {
            Issue.record("Expected a high-inflation conversation to compact, got \(outcome).")
            return
        }

        let rebuiltMessages = RemoteGenerationClient.remoteMessages(
            compactionResult: result,
            preservingRecentFrom: messages
        )
        let rebuiltEstimate = try anthropicEstimate(
            for: rebuiltMessages,
            toolDescriptionRepeats: 20
        )

        // The acceptance check is the provider estimator rebuilt from the
        // actual compacted wire payload, not merely the shared approximation.
        #expect(result.estimatedTokenCount < result.originalEstimatedTokenCount)
        #expect(rebuiltEstimate.totalTokens + maxOutputTokens <= contextWindowTokens)
    }

    // MARK: - Helpers

    private func chatGPTEstimate(
        for messages: [[String: Any]],
        toolDescriptionRepeats: Int
    ) throws -> SubscriptionCompactionSupport.RequestEstimate {
        let requestPayload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: messages,
            continuation: nil
        )
        let toolPayloads = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "local.exec",
                    description: String(
                        repeating: "large tool description ",
                        count: toolDescriptionRepeats
                    ),
                    inputSchema: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#
                )
            ]
        ).responsesToolPayloads
        let estimate = ChatGPTSubscriptionGenerationClient.requestEstimate(
            instructions: requestPayload.instructions,
            fullHistoryInput: requestPayload.input,
            toolPayloads: toolPayloads
        )
        #expect(estimate.isMeasured)
        return estimate
    }

    private func anthropicEstimate(
        for messages: [[String: Any]],
        toolDescriptionRepeats: Int
    ) throws -> SubscriptionCompactionSupport.RequestEstimate {
        let catalog = RemoteToolWireCatalog(
            descriptors: [
                DirectToolDescriptor(
                    name: "custom.large",
                    description: String(
                        repeating: "large tool description ",
                        count: toolDescriptionRepeats
                    ),
                    inputSchema: #"{"type":"object","properties":{"query":{"type":"string"}}}"#
                )
            ]
        )
        let payload = AnthropicSubscriptionGenerationClient.anthropicMessagesPayload(
            from: catalog.wireMessages(from: messages),
            includeThinkingBlocks: false
        )
        let tools = AnthropicSubscriptionGenerationClient.anthropicTools(from: catalog.bindings)
        let estimate = AnthropicSubscriptionGenerationClient.requestEstimate(
            estimatedContextTokens: AnthropicSubscriptionRequestBuilder.estimatedContextTokenCount(
                system: AnthropicSubscriptionGenerationClient.subscriptionSystemBlocks(
                    userSystemPrompt: payload.system
                ),
                messages: AnthropicSubscriptionGenerationClient
                    .addingCacheControlBreakpoints(payload.messages),
                tools: tools
            ),
            tools: tools
        )
        #expect(estimate.isMeasured)
        return estimate
    }

    private func wireConversation(count: Int = 120) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": "System prompt"]]
        for index in 0..<count {
            messages.append(
                RemoteGenerationClient.remoteMessage(
                    role: index.isMultiple(of: 2) ? "user" : "assistant",
                    content: "brief message \(index) " + String(repeating: "detail ", count: 30),
                    attachments: []
                )
            )
        }
        return messages
    }

    private func highInflationConversation(count: Int) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": "System prompt"]]
        let payload = String(repeating: "👩🏽‍💻\u{301}", count: 64) + "\\\"\n"
        for index in 0..<count {
            messages.append(
                RemoteGenerationClient.remoteMessage(
                    role: index.isMultiple(of: 2) ? "user" : "assistant",
                    content: "unicode wire turn \(index): \(payload)",
                    attachments: []
                )
            )
        }
        return messages
    }
}
