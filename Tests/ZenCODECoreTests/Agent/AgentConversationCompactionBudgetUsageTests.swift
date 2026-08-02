//
//  AgentConversationCompactionBudgetUsageTests.swift
//  ZenCODE
//
//  Regression coverage for how much of the target budget the shared compaction
//  policy actually uses, and for the invariant that compacting never grows the
//  prompt.
//

import Foundation
import ZenCODECore
import Testing

@Suite
struct AgentConversationCompactionBudgetUsageTests {
    @Test
    func compactionUsesNearlyAllOfTheTargetBudgetOnConstrainedWindows() {
        let messages = longConversation()

        for maxTokens in [8_000, 20_000] {
            let target = AgentConversationCompactionPolicy.targetTokenCount(for: maxTokens)
            let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
                messages,
                maxTokens: maxTokens,
                force: true
            )

            #expect(result.wasCompacted)
            #expect(result.estimatedTokenCount <= target)
            #expect(Double(result.estimatedTokenCount) >= Double(target) * 0.9)
            #expect(result.keptRecentMessageCount >= 20)
            #expect(result.messages.first?.role == .system)
            #expect(result.messages.last?.content == messages.last?.content)
        }
    }

    @Test
    func compactionNeverGrowsThePromptWhenHistoryAlreadyFitsTheTarget() {
        let messages = longConversation()
        let maxTokens = 128_000
        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens,
            force: true
        )

        #expect(result.wasCompacted)
        #expect(
            result.originalEstimatedTokenCount
                < AgentConversationCompactionPolicy.targetTokenCount(for: maxTokens)
        )
        #expect(result.estimatedTokenCount < result.originalEstimatedTokenCount)
        #expect(result.keptRecentMessageCount >= 150)
        #expect(
            result.messages.first?.content
                .contains(AgentConversationCompactionSupport.memorySummaryHeader) == true
        )
        #expect(result.messages.last?.content == messages.last?.content)
    }

    private func longConversation() -> [AgentRuntimeMessage] {
        var messages = [AgentRuntimeMessage(role: .system, content: "System prompt")]
        for index in 0..<200 {
            messages.append(
                AgentRuntimeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: "Turn \(index) " + String(repeating: "payload ", count: 100)
                )
            )
        }
        return messages
    }
}
