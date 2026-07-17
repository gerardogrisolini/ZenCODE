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

    @Test
    func emptyHistoryProducesEmptyTree() {
        let tree = SessionCheckpointTree.fromLinearHistory([], sessionID: "test")

        #expect(tree.entries.count == 1) // root placeholder
        #expect(tree.activeMessages.count == 1) // the root system message
    }

    // MARK: - Path walking

    @Test
    func pathFromLeafToRootIsChronological() {
        let messages = (0..<5).map { i in
            AgentRuntimeMessage(role: .user, content: "msg-\(i)")
        }
        let tree = SessionCheckpointTree.fromLinearHistory(messages, sessionID: "test")

        let leafID = tree.activeLeafID
        let path = tree.path(from: leafID)

        #expect(path.count == 5)
        #expect(path[0].message?.content == "msg-0")
        #expect(path[4].message?.content == "msg-4")
    }

    // MARK: - Branching

    @Test
    func branchCreatesChildAtAncestor() {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Hello"),
            AgentRuntimeMessage(role: .assistant, content: "Hi!"),
            AgentRuntimeMessage(role: .user, content: "Branch A"),
        ]
        var tree = SessionCheckpointTree.fromLinearHistory(messages, sessionID: "test")

        // Find the entry for the first user message to branch from
        let rootEntry = tree.rootEntry!
        let branchEntry = tree.branch(
            from: rootEntry.id,
            kind: .message(AgentRuntimeMessage(role: .user, content: "Branch B"))
        )

        #expect(branchEntry.parentID == rootEntry.id)
        #expect(tree.activeLeafID == branchEntry.id)

        // Active messages should be root + Branch B (2 messages)
        let active = tree.activeMessages
        #expect(active.count == 2)
        #expect(active[0].content == "Hello")
        #expect(active[1].content == "Branch B")
    }

    @Test
    func multipleBranchesProduceMultipleLeaves() {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Root message"),
        ]
        var tree = SessionCheckpointTree.fromLinearHistory(messages, sessionID: "test")
        let rootID = tree.activeLeafID

        // Branch 1
        _ = tree.branch(from: rootID, kind: .message(
            AgentRuntimeMessage(role: .user, content: "Branch 1")
        ))

        // Branch 2 (also from root)
        _ = tree.branch(from: rootID, kind: .message(
            AgentRuntimeMessage(role: .user, content: "Branch 2")
        ))

        #expect(tree.branches.count == 2)
    }

    // MARK: - Navigation

    @Test
    func navigateChangesActiveLeaf() {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Msg 1"),
            AgentRuntimeMessage(role: .user, content: "Msg 2"),
            AgentRuntimeMessage(role: .user, content: "Msg 3"),
        ]
        var tree = SessionCheckpointTree.fromLinearHistory(messages, sessionID: "test")

        // Navigate back to the first message entry
        let firstEntry = tree.entries[0]
        tree.navigate(to: firstEntry.id)

        #expect(tree.activeLeafID == firstEntry.id)
        #expect(tree.activeMessages.count == 1)
        #expect(tree.activeMessages[0].content == "Msg 1")
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
        #expect(tree.branches.count == 2)
    }

    // MARK: - Checkpoint entries

    @Test
    func checkpointEntryDoesNotParticipateInContext() {
        var tree = SessionCheckpointTree.fromLinearHistory(
            [AgentRuntimeMessage(role: .user, content: "Hello")],
            sessionID: "test"
        )
        let checkpoint = tree.append(.checkpoint(label: "my-checkpoint"))

        #expect(checkpoint.kind == .checkpoint(label: "my-checkpoint"))
        #expect(checkpoint.participatesInContext == false)

        // Messages should not include the checkpoint
        #expect(tree.activeMessages.count == 1)
    }

    // MARK: - Branch summary

    @Test
    func branchSummaryProducesAssistantMessage() {
        var tree = SessionCheckpointTree.fromLinearHistory(
            [AgentRuntimeMessage(role: .user, content: "Root")],
            sessionID: "test"
        )
        let rootID = tree.activeLeafID

        _ = tree.attachBranchSummary(
            at: rootID,
            summary: "We tried approach A but it didn't work.",
            fromEntryID: "old-leaf"
        )

        let active = tree.activeMessages
        #expect(active.count == 2)
        #expect(active[1].role == .assistant)
        #expect(active[1].content == "We tried approach A but it didn't work.")
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

    @Test
    func mergingHistoryIsIdempotent() {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Hello"),
            AgentRuntimeMessage(role: .assistant, content: "Hi!"),
        ]
        let tree = SessionCheckpointTree.fromLinearHistory(messages, sessionID: "test")

        let merged = tree.mergingHistory(messages)

        #expect(merged.entries.count == tree.entries.count)
    }

    // MARK: - Tree visualization

    @Test
    func treeDescriptionContainsEntryLabels() {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Hello world"),
            AgentRuntimeMessage(role: .assistant, content: "Hi there"),
        ]
        let tree = SessionCheckpointTree.fromLinearHistory(messages, sessionID: "test")

        let description = tree.treeDescription()
        #expect(description.contains("[user] Hello world"))
        #expect(description.contains("[assistant] Hi there"))
        #expect(description.contains("← active"))
        // Entry IDs should be visible for restore
        let firstEntry = tree.entries[0]
        #expect(description.contains(firstEntry.id))
    }

    @Test
    func treeDescriptionKeepsLinearChainsFlat() {
        let messages = (0..<20).map { index in
            AgentRuntimeMessage(role: .user, content: "Message \(index)")
        }
        let tree = SessionCheckpointTree.fromLinearHistory(messages, sessionID: "test")

        let lines = tree.treeDescription().components(separatedBy: "\n")
        #expect(lines.count == messages.count)
        // Linear history must not indent: every line starts with the entry ID.
        for line in lines {
            #expect(!line.hasPrefix(" "))
            #expect(!line.contains("└─"))
        }
    }

    @Test
    func treeDescriptionIndentsOnlyAtBranchPoints() {
        var tree = SessionCheckpointTree.fromLinearHistory(
            [AgentRuntimeMessage(role: .user, content: "Root")],
            sessionID: "test"
        )
        let rootID = tree.entries[0].id
        let branchA = tree.branch(
            from: rootID,
            kind: .message(AgentRuntimeMessage(role: .assistant, content: "Branch A"))
        )
        _ = tree.branch(
            from: branchA.id,
            kind: .message(AgentRuntimeMessage(role: .assistant, content: "A follow-up"))
        )
        _ = tree.branch(
            from: rootID,
            kind: .message(AgentRuntimeMessage(role: .assistant, content: "Branch B"))
        )

        let lines = tree.treeDescription().components(separatedBy: "\n")
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix(rootID))
        #expect(lines[1].hasPrefix("├─ "))
        // The follow-up continues branch A at the same indentation level.
        #expect(lines[2].hasPrefix("│  ") && !lines[2].contains("─"))
        #expect(lines[3].hasPrefix("└─ "))
    }

    @Test
    func treeDescriptionCollapsesWhitespaceInPreviews() {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "line one\n\tline\t\ttwo   spaced"),
        ]
        let tree = SessionCheckpointTree.fromLinearHistory(messages, sessionID: "test")

        let description = tree.treeDescription()
        #expect(description.contains("[user] line one line two spaced"))
    }

    // MARK: - Entry ID generation

    @Test
    func entryIDsAreEightHexChars() {
        let id = SessionCheckpointTree.generateEntryID()
        #expect(id.count == 8)
        #expect(id.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Children

    @Test
    func childrenOfEntryReturnsAllDirectChildren() {
        var tree = SessionCheckpointTree.fromLinearHistory(
            [AgentRuntimeMessage(role: .user, content: "Root")],
            sessionID: "test"
        )
        let rootID = tree.activeLeafID

        _ = tree.branch(from: rootID, kind: .message(
            AgentRuntimeMessage(role: .user, content: "Child A")
        ))
        tree.navigate(to: rootID)
        _ = tree.branch(from: rootID, kind: .message(
            AgentRuntimeMessage(role: .user, content: "Child B")
        ))

        let children = tree.children(of: rootID)
        #expect(children.count == 2)
    }

    // MARK: - Codable round-trip

    @Test
    func codableRoundTripPreservesTree() throws {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Hello"),
            AgentRuntimeMessage(role: .assistant, content: "Hi!"),
        ]
        var tree = SessionCheckpointTree.fromLinearHistory(messages, sessionID: "test-123")
        _ = tree.append(.checkpoint(label: "test-checkpoint"))

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
