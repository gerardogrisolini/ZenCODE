//
//  AgentConversationCompactionSupportTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 27/05/26.
//

import Foundation
import ZenCODECore
import Testing

@Suite
struct AgentConversationCompactionSupportTests {
    @Test
    func compactionIsSkippedBelowTrigger() {
        let messages = [
            AgentRuntimeMessage(role: .system, content: "System prompt"),
            AgentRuntimeMessage(role: .user, content: "Short request"),
            AgentRuntimeMessage(role: .assistant, content: "Short answer")
        ]

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            budget: AgentConversationCompactionBudget(contextWindowTokens: 8_000)
        )

        #expect(result.wasCompacted == false)
        #expect(result.messages.map(\.content) == messages.map(\.content))
    }

    @Test
    func compactionSummarizesOlderMessagesAndKeepsRecentMessages() {
        var messages = [
            AgentRuntimeMessage(role: .system, content: "System prompt")
        ]
        for index in 0..<20 {
            messages.append(
                AgentRuntimeMessage(
                    role: .user,
                    content: "Older request \(index) " + String(repeating: "details ", count: 80)
                )
            )
            messages.append(
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "Older answer \(index) " + String(repeating: "result ", count: 80)
                )
            )
        }
        messages.append(AgentRuntimeMessage(role: .user, content: "Recent request"))

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            budget: AgentConversationCompactionBudget(contextWindowTokens: 1_000),
            force: true
        )

        #expect(result.wasCompacted)
        #expect(result.messages.first?.role == .system)
        #expect(result.messages.first?.content.contains("System prompt") == true)
        #expect(result.messages.first?.content.contains(AgentConversationCompactionSupport.memorySummaryHeader) == true)
        #expect(result.messages.last?.content == "Recent request")
        #expect(result.messages.count < messages.count)
    }

    @Test
    func compactedConversationCanContinueAndBeRecompacted() {
        var messages = [
            AgentRuntimeMessage(role: .system, content: "System prompt"),
            AgentRuntimeMessage(
                role: .user,
                content: "Important durable decision: keep remote-server cache reuse stable."
                    + String(repeating: " context", count: 160)
            ),
            AgentRuntimeMessage(
                role: .assistant,
                content: "Confirmed: cache reuse stays the priority."
                    + String(repeating: " detail", count: 160)
            )
        ]
        for index in 0..<14 {
            messages.append(
                AgentRuntimeMessage(
                    role: .user,
                    content: "Earlier request \(index) " + String(repeating: "context ", count: 80)
                )
            )
            messages.append(
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "Earlier answer \(index) " + String(repeating: "result ", count: 80)
                )
            )
        }
        messages.append(AgentRuntimeMessage(role: .user, content: "Recent instruction: keep going normally."))

        let firstCompaction = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            budget: AgentConversationCompactionBudget(
                contextWindowTokens: contextWindow(forTargetTokenCount: 600)
            ),
            force: true
        )
        var resumedMessages = firstCompaction.messages
        resumedMessages.append(AgentRuntimeMessage(role: .assistant, content: "Continuing from the compacted memory."))
        resumedMessages.append(AgentRuntimeMessage(role: .user, content: "Next request after compaction."))

        let secondCompaction = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            resumedMessages,
            budget: AgentConversationCompactionBudget(
                contextWindowTokens: contextWindow(forTargetTokenCount: 350)
            ),
            force: true
        )
        let compactedSystemPrompt = secondCompaction.messages.first?.content ?? ""

        #expect(firstCompaction.wasCompacted)
        #expect(secondCompaction.wasCompacted)
        #expect(compactedSystemPrompt.contains("keep remote-server cache reuse stable"))
        #expect(compactedSystemPrompt.components(separatedBy: AgentConversationCompactionSupport.memorySummaryHeader).count == 2)
        #expect(secondCompaction.messages.contains { $0.content == "Continuing from the compacted memory." })
        #expect(secondCompaction.messages.last?.content == "Next request after compaction.")
    }

    @Test
    func diskCacheTokenContractStartsNewReusablePrefixAfterCompaction() {
        var messages = [
            AgentRuntimeMessage(role: .system, content: "System prompt"),
            AgentRuntimeMessage(
                role: .user,
                content: "Durable fact: the disk cache should restart from compacted memory."
                    + String(repeating: " context", count: 160)
            ),
            AgentRuntimeMessage(
                role: .assistant,
                content: "Confirmed durable cache contract."
                    + String(repeating: " detail", count: 160)
            )
        ]
        for index in 0..<16 {
            messages.append(
                AgentRuntimeMessage(
                    role: .user,
                    content: "Long pre-compaction request \(index) " + String(repeating: "context ", count: 80)
                )
            )
            messages.append(
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "Long pre-compaction answer \(index) " + String(repeating: "result ", count: 80)
                )
            )
        }
        messages.append(AgentRuntimeMessage(role: .user, content: "Recent request before compaction."))

        let originalPromptTokens = pseudoPromptTokenIDs(for: messages)
        let compaction = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            budget: AgentConversationCompactionBudget(contextWindowTokens: 1_200),
            force: true
        )
        let compactedPromptTokens = pseudoPromptTokenIDs(for: compaction.messages)

        let oldDiskCacheTokens = originalPromptTokens + pseudoGeneratedTokenIDs("Old long-context answer.")
        let oldReusablePrefix = reusablePromptPrefixTokenCount(
            storedTokenIDs: oldDiskCacheTokens,
            queryTokenIDs: compactedPromptTokens
        )

        let compactedGeneratedTokens = pseudoGeneratedTokenIDs("First answer after compaction.")
        let compactedDiskCacheTokens = compactedPromptTokens + compactedGeneratedTokens
        let continuedCompactedPromptTokens = compactedDiskCacheTokens
            + pseudoPromptTokenIDs(for: [
                AgentRuntimeMessage(role: .user, content: "Next request after compaction.")
            ])
        let compactedReusablePrefix = reusablePromptPrefixTokenCount(
            storedTokenIDs: compactedDiskCacheTokens,
            queryTokenIDs: continuedCompactedPromptTokens
        )

        #expect(compaction.wasCompacted)
        #expect(compactedPromptTokens.count < originalPromptTokens.count)
        #expect(oldReusablePrefix < compactedPromptTokens.count)
        #expect(compactedReusablePrefix == compactedDiskCacheTokens.count)
    }

    @Test
    func compactionFillsMostOfTheTargetBudgetInsteadOfCollapsingHistory() {
        var messages = [AgentRuntimeMessage(role: .system, content: "System prompt")]
        for index in 0..<200 {
            messages.append(
                AgentRuntimeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "Turn \(index) " + String(repeating: "payload ", count: 100)
                )
            )
        }

        let maxTokens = contextWindow(forTargetTokenCount: 10_000)
        let target = AgentConversationCompactionPolicy.targetTokenCount(for: maxTokens)
        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            budget: AgentConversationCompactionBudget(contextWindowTokens: maxTokens)
        )

        #expect(result.wasCompacted)
        #expect(result.estimatedTokenCount <= target)
        #expect(result.estimatedTokenCount >= target / 2)
        #expect(result.keptRecentMessageCount >= 30)
        #expect(result.messages.first?.role == .system)
        #expect(result.messages.last?.content == messages.last?.content)
    }

    @Test
    func targetIsThirtyPercentOfTheBudgetForEveryWindow() {
        #expect(AgentConversationCompactionPolicy.targetFraction == 0.30)
        #expect(AgentConversationCompactionPolicy.targetTokenCount(for: 0) == 0)
        #expect(AgentConversationCompactionPolicy.targetTokenCount(for: 20_000) == 6_000)
        #expect(AgentConversationCompactionPolicy.targetTokenCount(for: 256_000) == 76_800)
        // No absolute ceiling: a 1M-token window keeps the same share.
        #expect(AgentConversationCompactionPolicy.targetTokenCount(for: 1_000_000) == 300_000)
    }

    @Test
    func triggerCompactsFromNinetyFivePercentUpward() {
        let budget = 256_000
        let trigger = AgentConversationCompactionPolicy.triggerTokenCount(for: budget)
        #expect(trigger == 243_200)
        func compacts(_ usedTokens: Int) -> Bool {
            AgentConversationCompactionPolicy.shouldCompactHistory(
                usedTokens: usedTokens,
                maxTokens: budget,
                messageCount: AgentConversationCompactionPolicy.minimumRecentMessageCount + 1
            )
        }
        #expect(!compacts(trigger - 1))
        // Exactly 95% compacts too, and so does every level past it.
        #expect(compacts(trigger))
        #expect(compacts(249_200))
        #expect(compacts(budget))
        #expect(compacts(budget * 2))
    }

    @Test
    func midSizeWindowCompactsDownToThirtyPercentOfItsPromptBudget() throws {
        // A 256k window whose tokenizer charges 1.6 tokens per estimated token (the
        // DS4 path passes the exact count): 160k estimated tokens of prompt budget.
        let budget = AgentConversationCompactionBudget(
            contextWindowTokens: 256_000,
            conversationInflationFactor: 1.6
        )
        let promptBudget = try #require(budget.promptTokenBudget)
        // About 136k estimated tokens, the 85% at which DS4 forces a compaction.
        let messages = toolHeavyConversation(exchanges: 150, payloadRepeats: 100)
        let rawTokenCount = AgentConversationCompactionSupport.estimatedTokenCount(for: messages)

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            budget: budget,
            force: true
        )

        #expect(promptBudget == 160_000)
        #expect(rawTokenCount > promptBudget * 8 / 10)
        #expect(result.wasCompacted)
        #expect(result.estimatedTokenCount <= promptBudget * 30 / 100)
        // The target is filled, not undershot.
        #expect(result.estimatedTokenCount >= promptBudget * 27 / 100)
        // In the model's own tokens that is at most 30% of the window.
        #expect(Double(result.estimatedTokenCount) * 1.6 <= 256_000 * 0.30)
        #expect(result.messages.dropFirst().first?.role != .tool)
        #expect(result.messages.last?.content == messages.last?.content)
    }

    @Test
    func largeContextWindowCompactsDownToThirtyPercentOfItsPromptBudget() throws {
        // About 900k estimated tokens: above the 95% trigger of a 1M window that
        // reserves 128k tokens for the output.
        let messages = toolHeavyConversation(exchanges: 1_000, payloadRepeats: 100)
        let budget = AgentConversationCompactionBudget(
            contextWindowTokens: 1_000_000,
            maxOutputTokens: 128_000
        )
        let promptBudget = try #require(budget.promptTokenBudget)
        let rawTokenCount = AgentConversationCompactionSupport.estimatedTokenCount(for: messages)

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            budget: budget
        )

        #expect(rawTokenCount > AgentConversationCompactionPolicy.triggerTokenCount(for: promptBudget))
        #expect(result.wasCompacted)
        #expect(result.originalEstimatedTokenCount == rawTokenCount)
        #expect(result.estimatedTokenCount <= promptBudget * 30 / 100)
        // The target is filled, not undershot: the recent window stays as large as it allows.
        #expect(result.estimatedTokenCount >= promptBudget * 27 / 100)
        #expect(
            result.keptRecentMessageCount
                >= AgentConversationCompactionPolicy.minimumRecentMessageCount
        )
        #expect(result.messages.first?.role == .system)
        #expect(
            result.messages.first?.content.contains(
                AgentConversationCompactionSupport.memorySummaryHeader
            ) == true
        )
        #expect(result.messages.dropFirst().first?.role != .tool)
        #expect(result.messages.last?.content == messages.last?.content)
    }

    @Test
    func unreachableTargetFallsBackToTheSmallestWindowAndKeepsTheSummary() throws {
        var messages = [AgentRuntimeMessage(role: .system, content: "System prompt")]
        for index in 0..<36 {
            messages.append(
                AgentRuntimeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "Older turn \(index) " + String(repeating: "context ", count: 40)
                )
            )
        }
        // The four most recent messages alone exceed the target.
        for index in 36..<40 {
            messages.append(
                AgentRuntimeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "Recent turn \(index) " + String(repeating: "payload ", count: 400)
                )
            )
        }
        let budget = AgentConversationCompactionBudget(contextWindowTokens: 4_000)
        let promptBudget = try #require(budget.promptTokenBudget)
        let target = AgentConversationCompactionPolicy.targetTokenCount(for: promptBudget)
        let recentTokenCount = AgentConversationCompactionSupport.estimatedTokenCount(
            for: Array(messages.suffix(AgentConversationCompactionPolicy.minimumRecentMessageCount))
        )

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            budget: budget
        )

        #expect(recentTokenCount > target)
        #expect(result.wasCompacted)
        #expect(result.estimatedTokenCount > target)
        #expect(result.estimatedTokenCount < result.originalEstimatedTokenCount)
        #expect(
            result.keptRecentMessageCount
                == AgentConversationCompactionPolicy.minimumRecentMessageCount
        )
        // The fallback keeps the summary of its preferred budget instead of erasing memory.
        #expect(result.messages.first?.content.contains("Older turn 0") == true)
        #expect(result.messages.last?.content == messages.last?.content)
    }

    @Test
    func summaryKeepsHeadAndTailOfLongOlderMessages() {
        var messages = [AgentRuntimeMessage(role: .system, content: "System prompt")]
        for index in 0..<5 {
            messages.append(
                AgentRuntimeMessage(
                    role: .user,
                    content: "HEAD-FACT-\(index) "
                        + String(repeating: "filler ", count: 400)
                        + " TAIL-FACT-\(index)"
                )
            )
        }
        for index in 0..<8 {
            messages.append(
                AgentRuntimeMessage(
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "Recent turn \(index)"
                )
            )
        }

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            budget: AgentConversationCompactionBudget(
                contextWindowTokens: contextWindow(forTargetTokenCount: 1_500)
            ),
            force: true
        )

        let compactedSystemPrompt = result.messages.first?.content ?? ""
        #expect(result.wasCompacted)
        #expect(compactedSystemPrompt.contains("HEAD-FACT-0"))
        #expect(compactedSystemPrompt.contains("TAIL-FACT-0"))
    }

    @Test
    func recentWindowStartsOnUserTurnAndKeepsToolPairsTogether() {
        var messages = [AgentRuntimeMessage(role: .system, content: "System prompt")]
        for index in 0..<30 {
            messages.append(
                AgentRuntimeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "Middle turn \(index) " + String(repeating: "context ", count: 50)
                )
            )
        }
        messages.append(
            AgentRuntimeMessage(
                role: .assistant,
                content: "Very long dump " + String(repeating: "payload ", count: 750)
            )
        )
        for index in 0..<5 {
            messages.append(
                AgentRuntimeMessage(role: .user, content: "Please inspect file \(index).")
            )
            messages.append(
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "Reading it now.",
                    toolCalls: [
                        AgentRuntimeToolCall(
                            id: "call_\(index)",
                            name: "local.readFile",
                            argumentsJSON: "{\"path\":\"a\(index).swift\"}"
                        )
                    ]
                )
            )
            messages.append(
                AgentRuntimeMessage(
                    role: .tool,
                    content: "File contents \(index)",
                    toolCallID: "call_\(index)",
                    toolName: "local.readFile"
                )
            )
            messages.append(
                AgentRuntimeMessage(role: .assistant, content: "File \(index) defines one type.")
            )
        }

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            budget: AgentConversationCompactionBudget(
                contextWindowTokens: contextWindow(forTargetTokenCount: 500)
            ),
            force: true
        )

        let keptMessages = Array(result.messages.dropFirst())
        var openToolCallIDs: Set<String> = []
        var orphanToolResults = 0
        for message in keptMessages {
            for toolCall in message.toolCalls {
                if let id = toolCall.id {
                    openToolCallIDs.insert(id)
                }
            }
            if message.role == .tool, let id = message.toolCallID, !openToolCallIDs.contains(id) {
                orphanToolResults += 1
            }
        }

        #expect(result.wasCompacted)
        #expect(keptMessages.first?.role == .user)
        #expect(result.keptRecentMessageCount >= 20)
        #expect(orphanToolResults == 0)
        #expect(result.messages.last?.content == "File 4 defines one type.")
    }

    /// Smallest context window whose compaction target is `targetTokenCount`, so a
    /// scenario sized in absolute tokens does not depend on the policy fraction.
    private func contextWindow(forTargetTokenCount targetTokenCount: Int) -> Int {
        Int((Double(targetTokenCount) / AgentConversationCompactionPolicy.targetFraction).rounded(.up))
    }

    /// A long agentic session: one user request every 25 exchanges, each exchange
    /// an assistant tool call followed by its (large) tool result.
    private func toolHeavyConversation(
        exchanges: Int,
        payloadRepeats: Int
    ) -> [AgentRuntimeMessage] {
        let payload = String(repeating: "let value = compute(input) // line\n", count: payloadRepeats)
        var messages = [AgentRuntimeMessage(role: .system, content: "System prompt")]
        for index in 0..<exchanges {
            if index.isMultiple(of: 25) {
                messages.append(
                    AgentRuntimeMessage(role: .user, content: "Request \(index): continue the work.")
                )
            }
            messages.append(
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "Reading file \(index).",
                    toolCalls: [
                        AgentRuntimeToolCall(
                            id: "call_\(index)",
                            name: "local.readFile",
                            argumentsJSON: "{\"path\":\"File\(index).swift\"}"
                        )
                    ]
                )
            )
            messages.append(
                AgentRuntimeMessage(
                    role: .tool,
                    content: "File \(index)\n" + payload,
                    toolCallID: "call_\(index)",
                    toolName: "local.readFile"
                )
            )
        }
        return messages
    }
}

private func pseudoPromptTokenIDs(for messages: [AgentRuntimeMessage]) -> [Int] {
    messages.flatMap { message in
        Array("<\(message.role.rawValue)>\(message.content)\n".utf8).map(Int.init)
    }
}

private func pseudoGeneratedTokenIDs(_ text: String) -> [Int] {
    Array("<assistant-generated>\(text)".utf8).map(Int.init)
}

private func reusablePromptPrefixTokenCount(
    storedTokenIDs: [Int],
    queryTokenIDs: [Int]
) -> Int {
    min(storedTokenIDs.commonPrefixCount(with: queryTokenIDs), max(queryTokenIDs.count - 1, 0))
}

private extension Array where Element == Int {
    func commonPrefixCount(with other: [Int]) -> Int {
        let limit = Swift.min(count, other.count)
        var index = 0
        while index < limit, self[index] == other[index] {
            index += 1
        }
        return index
    }
}
