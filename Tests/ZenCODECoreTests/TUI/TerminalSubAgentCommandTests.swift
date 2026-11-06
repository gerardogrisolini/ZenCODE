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
    private static let helpLine = "/subagent opens the live detail of a sub-agent in progress (↑↓ PgUp PgDn Home End scroll, Esc or q closes). /subagent <name|id> opens it directly; without arguments it lists the sub-agents in progress."
    private static let layoutMessage = "ZenCODE: /subagent requires the interactive terminal layout.\n"

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

    /// A chat outside the interactive panel loop (no terminal stdin), whose
    /// writes are captured instead of reaching the terminal.
    private func makeTerminal() throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-subagent-\(UUID().uuidString)",
                isDirectory: true
            )
        )
        return TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil),
            telegramTransportFactory: nil,
            renderCoordinator: TerminalChatRenderCoordinator(
                stdinIsTerminal: false,
                standardOutput: nil,
                standardError: nil,
                standardOutputIsTerminal: false,
                standardErrorIsTerminal: false,
                cursorTopology: .separate,
                capturesWrites: true,
                streamingFlushDelay: nil,
                columnWidthProvider: { 100 }
            )
        )
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

    @Test
    func subAgentIsAChannelCommandRightAfterTasks() throws {
        let descriptors = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false
        )
        let tasks = try #require(descriptors.firstIndex { $0.command == "/tasks" })
        let subAgent = try #require(descriptors.firstIndex { $0.command == "/subagent" })
        #expect(subAgent == tasks + 1)
        #expect(descriptors[subAgent].summary == "open a sub-agent detail")
        #expect(descriptors[subAgent].scope == .channel)
        #expect(!descriptors[subAgent].requiresArgument)
    }

    @Test
    func helpListsSubAgentRightAfterTasks() throws {
        let context = TerminalChat.commandContext(
            builderAgentEnabled: false,
            telegramEnabled: false,
            ds4ModelEnabled: false
        )
        let lines = TerminalChat.commandRegistry.helpLines(in: context)
        let tasks = try #require(lines.firstIndex { $0.hasPrefix("/tasks ") })
        let subAgent = try #require(lines.firstIndex(of: Self.helpLine))
        #expect(subAgent == tasks + 1)
        #expect(ChatSessionNoticeText.text(for: .help(commandHelp: lines)).contains(Self.helpLine))
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
    func theArgumentIsTrimmed() {
        let agents = [agent("agent-1", name: "worker"), agent("agent-2", name: "reviewer")]
        #expect(matchedID(TerminalChat.matchSubAgent(argument: "  reviewer \t", in: agents)) == "agent-2")
        #expect(matchedID(TerminalChat.matchSubAgent(argument: " agent-1 ", in: agents)) == "agent-1")
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

    @Test
    func noMatchListsTheAgentsInProgress() {
        let agents = [agent("agent-1", name: "worker"), agent("agent-2", name: "  ")]
        let match = TerminalChat.matchSubAgent(argument: " nobody ", in: agents)
        #expect(matchedID(match) == nil)
        #expect(
            failureMessage(match)
                == "ZenCODE: no sub-agent in progress matches 'nobody'. In progress: worker, agent-2.\n"
        )
    }

    // MARK: - Layout

    @Test
    func withoutTheInteractiveLayoutNothingOpens() async throws {
        let terminal = try makeTerminal()
        terminal.capturedCommandOutputForTesting = []
        defer { terminal.capturedCommandOutputForTesting = nil }

        await terminal.handleSubAgentCommand("/subagent")
        await terminal.handleSubAgentCommand("/subagent worker")

        #expect(terminal.capturedCommandOutputForTesting == [Self.layoutMessage, Self.layoutMessage])
        #expect(!terminal.isSubAgentDetailOpen)
        #expect(terminal.subAgentDetail == nil)
    }

    @Test
    func subAgentReachesTheHandlerThroughTheDispatcher() async throws {
        let terminal = try makeTerminal()
        terminal.capturedCommandOutputForTesting = []
        defer { terminal.capturedCommandOutputForTesting = nil }

        let action = await terminal.submittedLineAction("/subagent worker")

        guard case .continueChat = action else {
            Issue.record("expected /subagent to continue the chat")
            return
        }
        #expect(terminal.capturedCommandOutputForTesting == [Self.layoutMessage])
        #expect(!terminal.isSubAgentDetailOpen)
    }
}
