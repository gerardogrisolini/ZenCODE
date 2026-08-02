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
    func preflightStaticOverheadTracksOnlyTheToolCatalogue() throws {
        let short = wireConversation()
        let long = wireConversation(count: 480)
        let shortMessageTokens = AgentConversationCompactionSupport.estimatedTokenCount(
            for: RemoteGenerationClient.agentRuntimeMessages(from: short)
        )
        let longMessageTokens = AgentConversationCompactionSupport.estimatedTokenCount(
            for: RemoteGenerationClient.agentRuntimeMessages(from: long)
        )
        #expect(longMessageTokens > shortMessageTokens * 3)

        let small = try anthropicEstimate(for: short, toolDescriptionRepeats: 1_000)
        let large = try anthropicEstimate(for: short, toolDescriptionRepeats: 3_000)
        let longHistory = try anthropicEstimate(for: long, toolDescriptionRepeats: 1_000)

        // The catalogue is what moves the static reservation...
        #expect(small.staticOverheadTokens > 0)
        #expect(large.staticOverheadTokens > small.staticOverheadTokens)
        // ...and the conversation never does, no matter how long it grows.
        #expect(longHistory.staticOverheadTokens == small.staticOverheadTokens)
        #expect(longHistory.conversationTokens > small.conversationTokens * 3)

        // The wire cost per estimator token is a rate, so it stays put while
        // the same kind of history scales up: the old difference-based overhead
        // grew instead, and eventually swallowed the whole window.
        let shortOverhead = SubscriptionCompactionSupport.requestOverhead(
            estimate: small,
            messages: short
        )
        let longOverhead = SubscriptionCompactionSupport.requestOverhead(
            estimate: longHistory,
            messages: long
        )
        #expect(shortOverhead.staticOverheadTokens == longOverhead.staticOverheadTokens)
        #expect(
            abs(
                shortOverhead.conversationInflationFactor
                    - longOverhead.conversationInflationFactor
            ) < 0.25
        )
        #expect(
            SubscriptionCompactionSupport.requestOverhead(
                estimate: .unmeasured,
                messages: short
            ) == .none
        )
    }

    @Test
    func escapedUnicodeHistoryScalesAsConversationInsteadOfStaticOverhead() throws {
        // This is deliberately expensive on the wire but compact in Swift's
        // character count: JSON escaping, multi-byte emoji and combining marks
        // used to be folded into a difference-based "static" overhead. Growing
        // this history would then make a feasible request look impossible.
        let short = unicodeEscapedConversation(count: 24)
        let long = unicodeEscapedConversation(count: 240)
        let shortEstimate = try chatGPTEstimate(for: short, toolDescriptionRepeats: 20)
        let longEstimate = try chatGPTEstimate(for: long, toolDescriptionRepeats: 20)
        let longMessageTokens = AgentConversationCompactionSupport.estimatedTokenCount(
            for: RemoteGenerationClient.agentRuntimeMessages(from: long)
        )
        let longOverhead = SubscriptionCompactionSupport.requestOverhead(
            estimate: longEstimate,
            messages: long
        )

        // Running the same provider estimator without history makes the static
        // component invariant. The legacy heterogeneous difference grows with
        // the history and would be a false reservation.
        #expect(longEstimate.staticOverheadTokens == shortEstimate.staticOverheadTokens)
        #expect(longEstimate.conversationTokens > shortEstimate.conversationTokens * 5)
        let legacyDifferenceOverhead = longEstimate.totalTokens - longMessageTokens
        #expect(legacyDifferenceOverhead > longEstimate.staticOverheadTokens)
        #expect(longOverhead.conversationInflationFactor > 1.0)

        let reservedOutputTokens = 1_000
        let contextWindowTokens = reservedOutputTokens
            + longEstimate.staticOverheadTokens
            + max(longMessageTokens / 2, 1)
        #expect(legacyDifferenceOverhead + reservedOutputTokens >= contextWindowTokens)

        let outcome = SubscriptionCompactionSupport.preflightCompaction(
            long,
            estimate: longEstimate,
            maxTokens: contextWindowTokens,
            maxOutputTokens: reservedOutputTokens,
            reserveTokenCount: 0
        )
        guard case let .compacted(result) = outcome else {
            Issue.record("Unicode/escaping history was incorrectly treated as an unsatisfiable static reservation: \(outcome).")
            return
        }
        #expect(result.estimatedTokenCount < result.originalEstimatedTokenCount)
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

    @Test
    func preflightReportsMinimumUnsatisfiableBudgetBeforeMessageCountGuards() {
        // Four messages are below the normal compaction-count guard. The output
        // reservation alone still makes the request impossible and must produce
        // the explicit outcome before that guard can say "not needed".
        let messages: [[String: Any]] = (0..<4).map { index in
            RemoteGenerationClient.remoteMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "tiny \(index)",
                attachments: []
            )
        }
        let outcome = SubscriptionCompactionSupport.preflightCompaction(
            messages,
            estimate: SubscriptionCompactionSupport.RequestEstimate(
                totalTokens: 4,
                staticOverheadTokens: 0
            ),
            maxTokens: 128,
            maxOutputTokens: 128,
            reserveTokenCount: 0
        )

        guard case let .unsatisfiableBudget(
            contextWindowTokens,
            reservedOutputTokens,
            overheadTokens
        ) = outcome else {
            Issue.record("Expected the minimum impossible budget to be reported, got \(outcome).")
            return
        }
        #expect(contextWindowTokens == 128)
        #expect(reservedOutputTokens == 128)
        #expect(overheadTokens == 0)
        #expect(
            SubscriptionCompactionSupport.unsatisfiableBudgetDiagnostic(
                provider: "test",
                contextWindowTokens: contextWindowTokens,
                maxOutputTokens: reservedOutputTokens,
                overheadTokens: overheadTokens
            ).contains("leave no room")
        )
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

    private func unicodeEscapedConversation(count: Int) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": "System prompt"]]
        let payload = String(repeating: "\\\"🙂 e\u{301}\n", count: 48)
        for index in 0..<count {
            messages.append(
                RemoteGenerationClient.remoteMessage(
                    role: index.isMultiple(of: 2) ? "user" : "assistant",
                    content: "unicode turn \(index): \(payload)",
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
