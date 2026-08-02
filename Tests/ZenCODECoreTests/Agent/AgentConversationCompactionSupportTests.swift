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
    func compactionTriggerIsNearFullContextWindow() {
        #expect(AgentConversationCompactionPolicy.triggerTokenCount(for: 100_000) == 95_000)
    }

    @Test
    func compactionTargetUsesMostOfContextWindowWhileLeavingHeadroom() {
        #expect(AgentConversationCompactionPolicy.targetTokenCount(for: 100_000) == 75_000)
        #expect(
            AgentConversationCompactionPolicy.targetTokenCount(for: 100_000)
                < AgentConversationCompactionPolicy.triggerTokenCount(for: 100_000)
        )
    }

    @Test
    func summaryBudgetScalesWithTargetAndStaysBounded() {
        #expect(
            AgentConversationCompactionPolicy.summaryCharacterBudget(forTargetTokenCount: 100)
                == 120
        )
        #expect(
            AgentConversationCompactionPolicy.summaryCharacterBudget(forTargetTokenCount: 30_000)
                > AgentConversationCompactionPolicy.summaryCharacterBudget(forTargetTokenCount: 3_000)
        )
        #expect(
            AgentConversationCompactionPolicy.summaryCharacterBudget(forTargetTokenCount: 1_000_000)
                == AgentConversationCompactionPolicy.maximumSummaryCharacters
        )
    }

    @Test
    func compactionIsSkippedBelowTrigger() {
        let messages = [
            AgentRuntimeMessage(role: .system, content: "System prompt"),
            AgentRuntimeMessage(role: .user, content: "Short request"),
            AgentRuntimeMessage(role: .assistant, content: "Short answer")
        ]

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            maxTokens: 8_000
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
            maxTokens: 1_000,
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
    func recompactionPreservesPriorMemorySummaryOnce() {
        let systemPrompt = """
        System prompt

        Conversation memory summary from earlier turns.
        Preserve the facts, decisions, files, code directions, and unresolved requests below as continuing context.
        Prior decision: keep the server fast.
        """
        let messages = [
            AgentRuntimeMessage(role: .system, content: systemPrompt),
            AgentRuntimeMessage(role: .user, content: "Old request " + String(repeating: "context ", count: 200)),
            AgentRuntimeMessage(role: .assistant, content: "Old answer " + String(repeating: "details ", count: 200)),
            AgentRuntimeMessage(role: .user, content: "Recent request"),
            AgentRuntimeMessage(role: .assistant, content: "Recent answer"),
            AgentRuntimeMessage(role: .user, content: "Newest request")
        ]

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            maxTokens: 500,
            force: true
        )

        let compactedSystemPrompt = result.messages.first?.content ?? ""
        let target = AgentConversationCompactionPolicy.targetTokenCount(for: 500)
        #expect(result.wasCompacted)
        // None of the provider-safe four-message suffixes can meet this target,
        // but the smallest one still removes a substantial part of the prompt.
        #expect(result.estimatedTokenCount > target)
        #expect(result.estimatedTokenCount < result.originalEstimatedTokenCount)
        #expect(
            AgentConversationCompactionPolicy.materiallyReducesPrompt(
                originalTokens: result.originalEstimatedTokenCount,
                candidateTokens: result.estimatedTokenCount
            )
        )
        #expect(compactedSystemPrompt.contains("System prompt"))
        #expect(compactedSystemPrompt.contains("Prior decision: keep the server fast."))
        #expect(
            compactedSystemPrompt.components(
                separatedBy: AgentConversationCompactionSupport.memorySummaryHeader
            ).count == 2
        )
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
            maxTokens: 1_200,
            force: true
        )
        var resumedMessages = firstCompaction.messages
        resumedMessages.append(AgentRuntimeMessage(role: .assistant, content: "Continuing from the compacted memory."))
        resumedMessages.append(AgentRuntimeMessage(role: .user, content: "Next request after compaction."))

        let secondCompaction = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            resumedMessages,
            maxTokens: 700,
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
            maxTokens: 1_200,
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
    func recentWindowExpandsToAvoidStartingWithToolResult() {
        var messages = [
            AgentRuntimeMessage(role: .system, content: "System prompt"),
            AgentRuntimeMessage(role: .user, content: "Old request " + String(repeating: "context ", count: 160))
        ]
        for index in 0..<8 {
            messages.append(AgentRuntimeMessage(role: .assistant, content: "Tool call \(index)"))
            messages.append(AgentRuntimeMessage(role: .tool, content: "Tool result \(index)"))
        }
        messages.append(AgentRuntimeMessage(role: .user, content: "Newest request"))

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            maxTokens: 500,
            force: true
        )

        #expect(result.wasCompacted)
        #expect(result.messages.dropFirst().first?.role != .tool)
    }

    @Test
    func compactionKeepsFarMoreRecentMessagesThanTheFixedWindowWhenBudgetAllows() {
        var messages = [AgentRuntimeMessage(role: .system, content: "System prompt")]
        for index in 0..<60 {
            messages.append(
                AgentRuntimeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "Short turn \(index)"
                )
            )
        }

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            maxTokens: 8_000,
            force: true
        )

        #expect(result.wasCompacted)
        #expect(result.keptRecentMessageCount > AgentConversationCompactionPolicy.defaultRecentMessageCount)
        #expect(result.keptRecentMessageCount >= 40)
        #expect(result.messages.count == result.keptRecentMessageCount + 1)
        #expect(
            result.estimatedTokenCount
                <= AgentConversationCompactionPolicy.targetTokenCount(for: 8_000)
        )
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

        let maxTokens = 20_000
        let target = AgentConversationCompactionPolicy.targetTokenCount(for: maxTokens)
        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens
        )

        #expect(result.wasCompacted)
        #expect(result.estimatedTokenCount <= target)
        #expect(result.estimatedTokenCount >= target / 2)
        #expect(result.keptRecentMessageCount >= 30)
        #expect(result.messages.first?.role == .system)
        #expect(result.messages.last?.content == messages.last?.content)
    }

    @Test
    func memorySummaryCoversEarliestAndMostRecentOlderTurns() {
        var messages = [AgentRuntimeMessage(role: .system, content: "System prompt")]
        for index in 0..<80 {
            messages.append(
                AgentRuntimeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "FACT-\(index)-MARK " + String(repeating: "context ", count: 70)
                )
            )
        }

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            maxTokens: 4_000,
            force: true
        )

        let compactedSystemPrompt = result.messages.first?.content ?? ""
        let olderCount = messages.count - 1 - result.keptRecentMessageCount

        #expect(result.wasCompacted)
        #expect(olderCount > 20)
        #expect(compactedSystemPrompt.contains("FACT-0-MARK"))
        #expect(compactedSystemPrompt.contains("FACT-\(olderCount - 1)-MARK"))
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
            maxTokens: 3_000,
            force: true
        )

        let compactedSystemPrompt = result.messages.first?.content ?? ""
        #expect(result.wasCompacted)
        #expect(compactedSystemPrompt.contains("HEAD-FACT-0"))
        #expect(compactedSystemPrompt.contains("TAIL-FACT-0"))
    }

    @Test
    func repeatedCompactionKeepsEarlierMemoryAndRecordsNewFacts() {
        let maxTokens = 4_000

        func history(generation: Int, count: Int) -> [AgentRuntimeMessage] {
            (0..<count).map { index in
                AgentRuntimeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: index == 0
                        ? "GEN\(generation)-DECISION durable rule for generation \(generation)."
                            + String(repeating: " context", count: 90)
                        : "Generation \(generation) turn \(index) "
                            + String(repeating: "context ", count: 90)
                )
            }
        }

        var messages = [AgentRuntimeMessage(role: .system, content: "System prompt")]
        messages.append(contentsOf: history(generation: 1, count: 40))
        let first = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens,
            force: true
        )

        var resumed = first.messages
        resumed.append(contentsOf: history(generation: 2, count: 40))
        let second = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            resumed,
            maxTokens: maxTokens,
            force: true
        )

        var resumedAgain = second.messages
        resumedAgain.append(contentsOf: history(generation: 3, count: 40))
        let third = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            resumedAgain,
            maxTokens: maxTokens,
            force: true
        )

        let compactedSystemPrompt = third.messages.first?.content ?? ""
        let secondMemory = memorySummarySection(of: second.messages.first?.content ?? "")
        let thirdMemory = memorySummarySection(of: compactedSystemPrompt)
        #expect(first.wasCompacted)
        #expect(second.wasCompacted)
        #expect(third.wasCompacted)
        #expect(compactedSystemPrompt.contains("System prompt"))
        #expect(compactedSystemPrompt.contains("GEN1-DECISION"))
        #expect(compactedSystemPrompt.contains("Generation 2 turn"))
        #expect(compactedSystemPrompt.contains("Generation 3 turn"))
        #expect(
            compactedSystemPrompt.components(
                separatedBy: AgentConversationCompactionSupport.memorySummaryHeader
            ).count == 2
        )
        #expect(compactedSystemPrompt.contains("Prior memory:\nPrior memory:") == false)
        #expect(thirdMemory.count >= (secondMemory.count * 4) / 5)
        #expect(
            third.estimatedTokenCount
                <= AgentConversationCompactionPolicy.targetTokenCount(for: maxTokens)
        )
        #expect(third.keptRecentMessageCount >= first.keptRecentMessageCount)
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
            maxTokens: 1_000,
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

    @Test
    func compactionRetentionGrowsWithTheContextWindow() {
        var messages = [AgentRuntimeMessage(role: .system, content: "System prompt")]
        for index in 0..<120 {
            messages.append(
                AgentRuntimeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "Turn \(index) " + String(repeating: "context ", count: 70)
                )
            )
        }

        var keptCounts: [Int] = []
        for maxTokens in [1_000, 8_000, 64_000] {
            let target = AgentConversationCompactionPolicy.targetTokenCount(for: maxTokens)
            let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
                messages,
                maxTokens: maxTokens,
                force: true
            )

            #expect(result.wasCompacted)
            #expect(result.messages.first?.role == .system)
            #expect(result.messages.first?.content.contains("System prompt") == true)
            #expect(
                result.messages.first?.content
                    .contains(AgentConversationCompactionSupport.memorySummaryHeader) == true
            )
            #expect(result.messages.last?.content == messages.last?.content)
            #expect(result.estimatedTokenCount < result.originalEstimatedTokenCount)
            #expect(
                result.keptRecentMessageCount
                    >= AgentConversationCompactionPolicy.minimumRecentMessageCount
            )
            #expect(
                result.estimatedTokenCount <= target
                    || result.keptRecentMessageCount
                        == AgentConversationCompactionPolicy.minimumRecentMessageCount
            )
            keptCounts.append(result.keptRecentMessageCount)
        }

        #expect(keptCounts[1] > keptCounts[0])
        #expect(keptCounts[2] > keptCounts[1])
    }
}

private func memorySummarySection(of systemPrompt: String) -> String {
    guard let range = systemPrompt.range(
        of: AgentConversationCompactionSupport.memorySummaryHeader
    ) else {
        return ""
    }
    return String(systemPrompt[range.lowerBound...])
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
