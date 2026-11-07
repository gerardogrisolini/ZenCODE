//
//  AgentConversationCompactionRemediationTests.swift
//  ZenCODE
//
//  Regression coverage for the compaction review findings: end-to-end token
//  budgeting (context window vs. reserved output vs. provider overhead),
//  guaranteed progress, a search that scales to thousands of short messages,
//  prior-memory budget reallocation, and legacy `Prior memory:` normalisation.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct AgentConversationCompactionRemediationTests {

    // MARK: - Finding 1: budget coordinated with maxOutputTokens

    @Test
    func promptBudgetSubtractsReservedOutputAndProviderOverhead() {
        let budget = AgentConversationCompactionBudget(
            contextWindowTokens: 100_000,
            maxOutputTokens: 32_000,
            reservedOverheadTokens: 8_000
        )

        #expect(budget.promptTokenBudget == 60_000)
        #expect(AgentConversationCompactionPolicy.targetTokenCount(for: budget.promptTokenBudget ?? 0) == 30_000)
        #expect(
            AgentConversationCompactionBudget(contextWindowTokens: 100_000).promptTokenBudget
                == 100_000
        )
        #expect(AgentConversationCompactionBudget(contextWindowTokens: nil).promptTokenBudget == nil)
        #expect(AgentConversationCompactionBudget(contextWindowTokens: 0).promptTokenBudget == nil)
    }

    @Test
    func anUnsatisfiableBudgetStopsCompactionInsteadOfLooping() {
        let messages = shortConversation(count: 200, payloadRepeats: 20)
        let budget = AgentConversationCompactionBudget(
            contextWindowTokens: 8_000,
            maxOutputTokens: 8_000,
            reservedOverheadTokens: 4_000
        )

        var current = messages
        var rounds = 0
        while rounds < 8 {
            let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
                current,
                budget: budget,
                force: true
            )
            guard result.wasCompacted else {
                break
            }
            current = result.messages
            rounds += 1
        }

        // No progress is claimed at all, so a provider preflight terminates on
        // its first pass instead of shaving messages towards an unreachable
        // target.
        #expect(rounds == 0)
        #expect(current.count == messages.count)
    }

    @Test(arguments: [1, 2, 3])
    func compactSummaryTextHonoursEveryTinyPositiveLimit(limit: Int) {
        let compacted = AgentConversationCompactionSupport.compactSummaryText(
            "abcdef",
            limit: limit
        )

        #expect(compacted.count == limit)
        #expect(compacted == String("abcdef".prefix(limit)))
    }

    // MARK: - Context-limit retry

    @Test
    func contextLimitRetryRemovesASubstantialPartInsteadOfOneToken() {
        let messages = shortConversation(count: 300, payloadRepeats: 20)
        let rawTokenCount = AgentConversationCompactionSupport.estimatedTokenCount(for: messages)
        // A window far larger than the history: the ordinary forced target
        // retains at most floor(raw * 0.9), whereas a context-limit retry must
        // still make the more aggressive 50% cut the provider needs.
        let budget = AgentConversationCompactionBudget(
            contextWindowTokens: 400_000,
            maxOutputTokens: 32_000
        )
        let forced = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            budget: budget,
            force: true
        )
        let retry = AgentConversationCompactionSupport.compactedMessagesForContextLimitRetry(
            messages,
            budget: budget
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
        #expect(retry.messages.last?.content == messages.last?.content)
        #expect(retry.estimatedTokenCount < forced.estimatedTokenCount)
        #expect(
            retry.keptRecentMessageCount
                >= AgentConversationCompactionPolicy.minimumRecentMessageCount
        )
    }

    // MARK: - Finding 2: provider overhead and preflight termination

    @Test
    func subscriptionBudgetAccountsForToolAndStaticOverhead() {
        let wireMessages = wireConversation(count: 400, payloadRepeats: 40)
        let contextWindowTokens = 32_000
        let maxOutputTokens = 4_000
        let toolAndStaticOverhead = 9_000
        let estimate = SubscriptionCompactionSupport.RequestEstimate(
            totalTokens: AgentConversationCompactionSupport.estimatedTokenCount(
                for: RemoteGenerationClient.agentRuntimeMessages(from: wireMessages)
            ) + toolAndStaticOverhead,
            staticOverheadTokens: toolAndStaticOverhead
        )

        let overhead = SubscriptionCompactionSupport.requestOverhead(
            estimate: estimate,
            messages: wireMessages
        )
        #expect(overhead.staticOverheadTokens == toolAndStaticOverhead)
        // The conversation is charged exactly what the estimator says here, so
        // no inflation is invented on top of the static reservation.
        #expect(overhead.conversationInflationFactor == 1.0)

        let result = SubscriptionCompactionSupport.compactedMessagesForEstimatedContextIfNeeded(
            wireMessages,
            estimate: estimate,
            maxTokens: contextWindowTokens,
            maxOutputTokens: maxOutputTokens,
            reserveTokenCount: 0
        )

        let compacted = try! #require(result)
        #expect(compacted.wasCompacted)
        // End-to-end invariant: messages + overhead + reserved output all fit.
        #expect(
            compacted.estimatedTokenCount + toolAndStaticOverhead + maxOutputTokens
                <= contextWindowTokens
        )
    }

    @Test
    func subscriptionPreflightConvergesWithinTheAttemptCap() {
        var wireMessages = wireConversation(count: 500, payloadRepeats: 40)
        let contextWindowTokens = 24_000
        let maxOutputTokens = 4_000
        let toolAndStaticOverhead = 6_000

        func estimatedContext(
            for messages: [[String: Any]]
        ) -> SubscriptionCompactionSupport.RequestEstimate {
            SubscriptionCompactionSupport.RequestEstimate(
                totalTokens: AgentConversationCompactionSupport.estimatedTokenCount(
                    for: RemoteGenerationClient.agentRuntimeMessages(from: messages)
                ) + toolAndStaticOverhead,
                staticOverheadTokens: toolAndStaticOverhead
            )
        }

        var attempts = 0
        while attempts < 32 {
            guard let result = SubscriptionCompactionSupport
                .compactedMessagesForEstimatedContextIfNeeded(
                    wireMessages,
                    estimate: estimatedContext(for: wireMessages),
                    maxTokens: contextWindowTokens,
                    maxOutputTokens: maxOutputTokens,
                    reserveTokenCount: 0
                ) else {
                break
            }
            // Every accepted compaction has to make progress, otherwise the
            // provider preflight would resend the identical prompt forever.
            #expect(result.estimatedTokenCount < result.originalEstimatedTokenCount)
            wireMessages = self.wireMessages(from: result.messages)
            attempts += 1
        }

        #expect(attempts >= 1)
        #expect(attempts <= AgentConversationCompactionPolicy.maximumPreflightCompactionAttempts)
        #expect(
            estimatedContext(for: wireMessages).totalTokens + maxOutputTokens <= contextWindowTokens
        )
    }

    // MARK: - Finding 3: a successful compaction never grows the prompt

    @Test
    func policyOverflowMayUseAMaterialFallbackWhenNoCandidateFitsItsTarget() {
        // This is a genuine policy overflow, not an already-in-budget manual
        // force. Four recent messages alone cannot fit this very small target,
        // so keeping the smallest material fallback is safer than giving up.
        let messages = shortConversation(count: 6, payloadRepeats: 20)
        let maxTokens = 16
        let rawTokenCount = AgentConversationCompactionSupport.estimatedTokenCount(for: messages)
        let policyTargetTokenCount = AgentConversationCompactionPolicy.targetTokenCount(
            for: maxTokens
        )
        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens
        )

        #expect(rawTokenCount > policyTargetTokenCount)
        #expect(result.wasCompacted)
        #expect(result.estimatedTokenCount > policyTargetTokenCount)
        #expect(result.estimatedTokenCount < rawTokenCount)
        #expect(
            AgentConversationCompactionPolicy.materiallyReducesPrompt(
                originalTokens: rawTokenCount,
                candidateTokens: result.estimatedTokenCount
            )
        )
    }

    @Test
    func repeatedForcedCompactionAlwaysShrinksAndThenStops() {
        var messages = shortConversation(count: 120, payloadRepeats: 30)
        var previousTokens = AgentConversationCompactionSupport.estimatedTokenCount(for: messages)
        var rounds = 0
        let roundLimit = messages.count * 2

        while rounds < roundLimit {
            let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
                messages,
                maxTokens: 16_000,
                force: true
            )
            guard result.wasCompacted else {
                break
            }
            #expect(result.estimatedTokenCount < previousTokens)
            previousTokens = result.estimatedTokenCount
            messages = result.messages
            rounds += 1
        }

        // Every round strictly shrinks, so forced re-compaction terminates
        // instead of oscillating on an unchanged prompt.
        #expect(rounds >= 1)
        #expect(rounds < roundLimit)
    }

    // MARK: - Finding 4: the search scales to thousands of short messages

    @Test
    func retentionStaysNearMaximalAcrossContextOutputAndOverheadConfigurations() {
        var messages = [AgentRuntimeMessage(role: .system, content: "System prompt")]
        for index in 0..<3_000 {
            messages.append(
                AgentRuntimeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "Short turn \(index) detail"
                )
            )
        }

        let configurations: [(context: Int, output: Int, overhead: Int)] = [
            (32_000, 0, 0),
            (32_000, 8_000, 0),
            (32_000, 8_000, 4_000),
            (128_000, 32_000, 12_000),
            (200_000, 64_000, 20_000)
        ]

        var keptCounts: [Int] = []
        for configuration in configurations {
            let budget = AgentConversationCompactionBudget(
                contextWindowTokens: configuration.context,
                maxOutputTokens: configuration.output,
                reservedOverheadTokens: configuration.overhead
            )
            let promptBudget = try! #require(budget.promptTokenBudget)
            let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
                messages,
                budget: budget,
                force: true
            )

            #expect(result.wasCompacted)
            #expect(result.maxTokens == configuration.context)
            #expect(result.estimatedTokenCount < result.originalEstimatedTokenCount)
            #expect(
                result.estimatedTokenCount
                    <= AgentConversationCompactionPolicy.targetTokenCount(for: promptBudget)
            )
            #expect(
                result.estimatedTokenCount + configuration.output + configuration.overhead
                    <= configuration.context
            )
            #expect(
                result.keptRecentMessageCount
                    >= AgentConversationCompactionPolicy.minimumRecentMessageCount
            )
            #expect(result.messages.last?.content == messages.last?.content)
            keptCounts.append(result.keptRecentMessageCount)
        }

        // A larger effective prompt budget must never retain fewer messages.
        #expect(keptCounts[0] >= keptCounts[1])
        #expect(keptCounts[1] >= keptCounts[2])
        #expect(keptCounts[3] > keptCounts[2])
        #expect(keptCounts[4] >= keptCounts[3])
    }

    // MARK: - Finding 5: unused budget flows back to prior memory

    @Test
    func priorMemoryReclaimsTheBudgetTheNewFactsDoNotUse() {
        let priorFactCount = 200
        let priorSummary = inheritedSummary(factCount: priorFactCount)
        let maxCharacters = 6_000

        let withTinyNewFacts = AgentConversationCompactionSupport.conversationMemorySummary(
            priorSummary: priorSummary,
            olderMessages: [AgentRuntimeMessage(role: .user, content: "One small new fact.")],
            maxCharacters: maxCharacters
        )
        let withLargeNewFacts = AgentConversationCompactionSupport.conversationMemorySummary(
            priorSummary: priorSummary,
            olderMessages: (0..<40).map { index in
                AgentRuntimeMessage(
                    role: .user,
                    content: "NEW-FACT-\(index) " + String(repeating: "context ", count: 60)
                )
            },
            maxCharacters: maxCharacters
        )

        let retainedWithTinyNewFacts = retainedPriorFactCount(
            in: withTinyNewFacts,
            of: priorFactCount
        )
        let retainedWithLargeNewFacts = retainedPriorFactCount(
            in: withLargeNewFacts,
            of: priorFactCount
        )
        // Substring matching inflates the count because `PRIOR-FACT-1` is a
        // prefix of `PRIOR-FACT-10`; the exact token count must be no larger.
        let substringCount = (0..<priorFactCount).reduce(into: 0) { count, index in
            if withTinyNewFacts.contains("PRIOR-FACT-\(index)") {
                count += 1
            }
        }

        // With almost no new facts the inherited memory should reclaim the
        // leftover instead of being capped at its nominal share.
        #expect(retainedWithTinyNewFacts > retainedWithLargeNewFacts)
        #expect(retainedWithTinyNewFacts >= 100)
        #expect(retainedWithTinyNewFacts <= substringCount)
        #expect(retainedWithTinyNewFacts <= priorFactCount)
        #expect(withTinyNewFacts.contains("PRIOR-FACT-0 durable rule number 0."))
        #expect(withTinyNewFacts.contains("PRIOR-FACT-\(priorFactCount - 1)"))
        #expect(withTinyNewFacts.contains("One small new fact."))
        // The large-new-facts case must still keep a meaningful share of the
        // inherited memory and record the new material.
        #expect(retainedWithLargeNewFacts >= 30)
        #expect(retainedNewFactCount(in: withLargeNewFacts, of: 40) >= 1)
        #expect(withLargeNewFacts.contains("NEW-FACT-0"))
        #expect(withTinyNewFacts.count <= maxCharacters)
        #expect(withLargeNewFacts.count <= maxCharacters)
    }

    // MARK: - Finding 6: legacy inline `Prior memory:` normalisation

    @Test
    func legacyInlinePriorMemoryIsNormalisedWithoutNesting() {
        let legacySystemPrompt = """
        System prompt

        \(AgentConversationCompactionSupport.memorySummaryHeader)
        Preserve the facts, decisions, files, code directions, and unresolved requests below as continuing context.
        Prior memory: LEGACY-FACT durable rule from an older build.
        User request: earlier question about caching.
        """

        var messages = [AgentRuntimeMessage(role: .system, content: legacySystemPrompt)]
        for index in 0..<40 {
            messages.append(
                AgentRuntimeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "Turn \(index) " + String(repeating: "context ", count: 60)
                )
            )
        }

        var current = messages
        for _ in 0..<3 {
            let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
                current,
                maxTokens: 6_000,
                force: true
            )
            #expect(result.wasCompacted)
            current = result.messages
            current.append(contentsOf: (0..<20).map { index in
                AgentRuntimeMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "Follow-up \(index) " + String(repeating: "context ", count: 60)
                )
            })
        }

        let systemPrompt = current.first?.content ?? ""
        #expect(systemPrompt.contains("LEGACY-FACT"))
        #expect(systemPrompt.contains("Prior memory: Prior memory:") == false)
        #expect(systemPrompt.contains("Prior memory:\nPrior memory:") == false)
        // Exactly one label survives, whatever the inherited format was.
        #expect(systemPrompt.components(separatedBy: "Prior memory:").count <= 2)
    }

    // MARK: - Helpers

    private func shortConversation(
        count: Int,
        payloadRepeats: Int
    ) -> [AgentRuntimeMessage] {
        var messages = [AgentRuntimeMessage(role: .system, content: "System prompt")]
        for index in 0..<count {
            messages.append(
                AgentRuntimeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "Turn \(index) " + String(repeating: "payload ", count: payloadRepeats)
                )
            )
        }
        return messages
    }

    private func wireConversation(
        count: Int,
        payloadRepeats: Int
    ) -> [[String: Any]] {
        wireMessages(from: shortConversation(count: count, payloadRepeats: payloadRepeats))
    }

    private func wireMessages(
        from messages: [AgentRuntimeMessage]
    ) -> [[String: Any]] {
        messages.map { message in
            ["role": message.role.rawValue, "content": message.content]
        }
    }

    private func inheritedSummary(factCount: Int) -> String {
        var lines = [AgentConversationCompactionSupport.memorySummaryHeader]
        lines.append(
            "Preserve the facts, decisions, files, code directions, and unresolved requests below as continuing context."
        )
        lines.append("Prior memory:")
        for index in 0..<factCount {
            lines.append("PRIOR-FACT-\(index) durable rule number \(index).")
        }
        return lines.joined(separator: "\n")
    }

    /// Counts inherited facts by exact whitespace/newline token, so
    /// `PRIOR-FACT-1` is never satisfied by `PRIOR-FACT-10`.
    private func retainedPriorFactCount(in summary: String, of factCount: Int) -> Int {
        let markers = Set(
            summary
                .split(whereSeparator: { $0 == " " || $0.isNewline })
                .map(String.init)
        )
        return (0..<factCount).reduce(into: 0) { count, index in
            if markers.contains("PRIOR-FACT-\(index)") {
                count += 1
            }
        }
    }

    /// Same exact-token rule for the facts produced by the current turn.
    private func retainedNewFactCount(in summary: String, of factCount: Int) -> Int {
        let markers = Set(
            summary
                .split(whereSeparator: { $0 == " " || $0.isNewline })
                .map(String.init)
        )
        return (0..<factCount).reduce(into: 0) { count, index in
            if markers.contains("NEW-FACT-\(index)") {
                count += 1
            }
        }
    }
}
