//
//  SessionCheckpointTreeTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct SessionCheckpointTreeTests {

    // MARK: - Linear history migration

    @Test
    func buildsLinearTreeFromMessages() {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Hello"),
            AgentRuntimeMessage(role: .assistant, content: "Hi there!"),
            AgentRuntimeMessage(role: .user, content: "How are you?"),
        ]
        let tree = SessionCheckpointTree.fromLinearHistory(messages, sessionID: "test")

        #expect(tree.entries.count == 3)
        #expect(tree.activeMessages.count == 3)
        #expect(tree.activeMessages[0].content == "Hello")
        #expect(tree.activeMessages[2].content == "How are you?")
    }

    // MARK: - Selective restore (checkpointEntryID)

    @Test
    func messagesFromCheckpointEntryRebuildsPartialHistory() {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Msg 1"),
            AgentRuntimeMessage(role: .assistant, content: "Reply 1"),
            AgentRuntimeMessage(role: .user, content: "Msg 2"),
            AgentRuntimeMessage(role: .assistant, content: "Reply 2"),
        ]
        let tree = SessionCheckpointTree.fromLinearHistory(messages, sessionID: "test")

        // Select the entry for "Reply 1" (index 1)
        let targetEntry = tree.entries[1]
        let partialMessages = tree.messages(from: targetEntry.id)

        // Should include Msg 1 + Reply 1 (path from root to target)
        #expect(partialMessages.count == 2)
        #expect(partialMessages[0].content == "Msg 1")
        #expect(partialMessages[1].content == "Reply 1")
    }

    @Test
    func navigateThenAppendCreatesBranch() {
        var tree = SessionCheckpointTree.fromLinearHistory(
            [
                AgentRuntimeMessage(role: .user, content: "Original"),
                AgentRuntimeMessage(role: .user, content: "Second"),
            ],
            sessionID: "test"
        )

        // Navigate back to "Original"
        let rootID = tree.entries[0].id
        tree.navigate(to: rootID)

        // Append a new message — it should branch from root
        _ = tree.append(.message(AgentRuntimeMessage(role: .user, content: "Alternate path")))

        // Active path should be Original + Alternate path (not Second)
        let active = tree.activeMessages
        #expect(active.count == 2)
        #expect(active[0].content == "Original")
        #expect(active[1].content == "Alternate path")

        // The old "Second" entry should still exist as a separate branch
        #expect(tree.entries.filter { $0.parentID == rootID }.count == 2)
    }

    // MARK: - Branch summary and model change

    @Test
    func branchSummaryProducesAssistantMessage() {
        var tree = SessionCheckpointTree.fromLinearHistory(
            [AgentRuntimeMessage(role: .user, content: "Root")],
            sessionID: "test"
        )

        tree.append(.branchSummary(
            summary: "We tried approach A but it didn't work.",
            fromEntryID: "old-leaf"
        ))

        let active = tree.activeMessages
        #expect(active.count == 2)
        #expect(active[1].role == .assistant)
        #expect(active[1].content == "We tried approach A but it didn't work.")
    }

    @Test
    func modelChangeEntriesAreSkippedFromMessages() {
        var tree = SessionCheckpointTree.fromLinearHistory(
            [AgentRuntimeMessage(role: .user, content: "Root")],
            sessionID: "test"
        )

        tree.append(.modelChange(modelID: "other-model"))

        #expect(tree.activePath.count == 2)
        #expect(tree.activeMessages.map(\.content) == ["Root"])
    }

    // MARK: - History merge

    @Test
    func mergingHistoryAppendsNewMessages() {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Hello"),
        ]
        let tree = SessionCheckpointTree.fromLinearHistory(messages, sessionID: "test")

        let updated = [
            AgentRuntimeMessage(role: .user, content: "Hello"),
            AgentRuntimeMessage(role: .assistant, content: "Hi!"),
            AgentRuntimeMessage(role: .user, content: "How are you?"),
        ]
        let merged = tree.mergingHistory(updated)

        #expect(merged.activeMessages.count == 3)
        #expect(merged.activeMessages[2].content == "How are you?")
    }

    // MARK: - Codable round-trip

    @Test
    func codableRoundTripPreservesTree() throws {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Hello"),
            AgentRuntimeMessage(role: .assistant, content: "Hi!"),
        ]
        let tree = SessionCheckpointTree.fromLinearHistory(messages, sessionID: "test-123")

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(tree)

        let decoder = PropertyListDecoder()
        let decoded = try decoder.decode(SessionCheckpointTree.self, from: data)

        #expect(decoded.sessionID == "test-123")
        #expect(decoded.entries.count == tree.entries.count)
        #expect(decoded.activeLeafID == tree.activeLeafID)
        #expect(decoded.activeMessages.count == 2)
    }
}
