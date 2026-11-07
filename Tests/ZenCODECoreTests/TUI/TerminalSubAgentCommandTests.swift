//
//  TerminalSubAgentCommandTests.swift
//  ZenCODE
//
//  The `/subagent` command of the terminal: its registry entry, its `/help`
//  line, the sub-agent its argument names, and the layout it requires.
//

import Foundation
import Testing
@testable import ZenCODECore

private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

@ChatSessionActor
@Suite
struct TerminalSubAgentCommandTests {
    // MARK: - Fixtures

    private func agent(_ id: String, name: String) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: id,
            name: name,
            role: "Reviews the change",
            status: .running,
            pending: true,
            latestOutput: nil,
            latestError: nil,
            createdAt: referenceDate,
            updatedAt: referenceDate
        )
    }

    /// The id of the agent `match` opens, or `nil` when it failed.
    private func matchedID(_ match: TerminalChat.SubAgentMatch) -> String? {
        guard case let .matched(snapshot) = match else { return nil }
        return snapshot.id
    }

    /// The message of a failed match, or `nil` when it matched.
    private func failureMessage(_ match: TerminalChat.SubAgentMatch) -> String? {
        guard case let .failed(message) = match else { return nil }
        return message
    }

    // MARK: - Registry

    @Test
    func subAgentIsAKnownCommandWithOrWithoutArguments() {
        #expect(TerminalChat.isKnownSlashCommand("/subagent"))
        #expect(TerminalChat.isKnownSlashCommand("/subagent foo"))
    }

    @Test
    func subAgentRunsWhileAPromptIsGenerating() {
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/subagent"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/subagent x"))
    }

    // MARK: - Matching

    @Test
    func anIDMatchesItsAgent() {
        let agents = [agent("agent-1", name: "worker"), agent("agent-2", name: "reviewer")]
        #expect(matchedID(TerminalChat.matchSubAgent(argument: "agent-2", in: agents)) == "agent-2")
        #expect(matchedID(TerminalChat.matchSubAgent(argument: "AGENT-1", in: agents)) == "agent-1")
    }

    @Test
    func aNameMatchesItsAgentIgnoringCase() {
        let agents = [agent("agent-1", name: "worker"), agent("agent-2", name: "Reviewer")]
        #expect(matchedID(TerminalChat.matchSubAgent(argument: "reviewer", in: agents)) == "agent-2")
        #expect(matchedID(TerminalChat.matchSubAgent(argument: "WORKER", in: agents)) == "agent-1")
    }

    @Test
    func anIDWinsOverAnEqualName() {
        let agents = [agent("agent-1", name: "worker"), agent("worker", name: "reviewer")]
        #expect(matchedID(TerminalChat.matchSubAgent(argument: "Worker", in: agents)) == "worker")
    }

    @Test
    func anAmbiguousNameListsTheAgentsAndAsksForTheID() {
        let agents = [
            agent("agent-1", name: "worker"),
            agent("agent-2", name: "reviewer"),
            agent("agent-3", name: "Worker"),
        ]
        let match = TerminalChat.matchSubAgent(argument: "worker", in: agents)
        #expect(matchedID(match) == nil)
        #expect(
            failureMessage(match)
                == "ZenCODE: more than one sub-agent in progress is named 'worker': worker (agent-1), Worker (agent-3). Use /subagent <id>.\n"
        )
    }
}
