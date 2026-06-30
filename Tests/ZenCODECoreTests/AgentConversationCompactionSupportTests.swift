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
    func compactionTargetIsQuarterOfContextWindow() {
        #expect(AgentConversationCompactionPolicy.targetTokenCount(for: 100_000) == 25_000)
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
        #expect(result.wasCompacted)
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
                content: "Important durable decision: keep mlx-server cache reuse stable."
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
        #expect(compactedSystemPrompt.contains("keep mlx-server cache reuse stable"))
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
