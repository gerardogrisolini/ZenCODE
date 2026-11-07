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
