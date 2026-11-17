//
//  TerminalSubAgentCommandTests.swift
//  ZenCODE
//
//  The `/subagent` command of the terminal: its registry entry, its `/help`
//  line, the sub-agent its argument names, and the layout it requires.
//

import Foundation
import Testing
import ToolCore
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

    private func makeRenderer() -> TerminalChatRenderCoordinator {
        TerminalChatRenderCoordinator(
            stdinIsTerminal: false, standardOutput: nil, standardError: nil,
            standardOutputIsTerminal: false, standardErrorIsTerminal: false,
            cursorTopology: .separate,
            capturesWrites: true, streamingFlushDelay: nil, columnWidthProvider: { 100 }
        )
    }

    private func makeTerminal(_ directory: URL) throws -> TerminalChat {
        TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "test-model", availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")],
                workingDirectory: directory
            ), stdinIsTerminal: false, sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil),
            telegramTransportFactory: nil, renderCoordinator: makeRenderer()
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("subagent-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Opens the `/subagent` panel by hand, as `/subagent` does, on a screen
    /// that is never installed and a session that has no sub-agent to follow.
    private func openSubAgentPanel(on terminal: TerminalChat) -> TerminalSubAgentDetailController {
        let session = TerminalModalSession(screen: TerminalPrimaryScreen(output: { _ in }))
        let controller = TerminalSubAgentDetailController(environment: .init(
            snapshotEvents: { nil },
            transcript: { _ in nil },
            viewport: { (rows: 20, columns: 60) },
            present: { _ in },
            isCancelled: { false },
            onClosed: { [weak terminal] reason in
                await terminal?.closeDetailPanel(reason: reason)
            },
            modeDidChange: { [weak terminal] isChoosing in
                await terminal?.detailPanelModeDidChange(isChoosing: isChoosing, session: session)
            },
            standardErrorIsTerminal: false,
            subscribeResize: { _ in {} }
        ))
        terminal.detailPanel = TerminalDetailPanel(content: .subAgent(controller), session: session)
        return controller
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

// MARK: - Panel keys

extension TerminalSubAgentCommandTests {
    /// Esc in the detail of an agent picked from the list goes back to the
    /// list, and the input panel's mode and help follow each step; Esc in the
    /// list closes the panel.
    @Test
    func escInTheDetailGoesBackToTheListAndTheInputPanelFollows() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = try makeTerminal(directory)
        let agents = [agent("agent-1", name: "worker"), agent("agent-2", name: "reviewer")]
        let controller = openSubAgentPanel(on: terminal)
        func routing() -> TerminalInteractiveLineReader.SubAgentDetailMode {
            terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode }
        }
        func panelMode() -> TerminalPanelModeOverride? {
            terminal.interactiveReader.withPanelLock { $0.panelOverlayOverride }
        }
        await terminal.setDetailPanelMode(.list, kind: .subAgent)
        controller.open(choosing: agents)
        #expect(routing() == .list)
        #expect(panelMode() == TerminalChat.subAgentListPanelOverride)

        await terminal.handleDetailPanelAction(.confirm)
        #expect(routing() == .detail)
        #expect(panelMode() == TerminalChat.subAgentListDetailPanelOverride)
        #expect(panelMode()?.helpText.hasSuffix("Esc back") == true)
        #expect(controller.agentID == "agent-1")

        await terminal.handleDetailPanelAction(.close)
        #expect(terminal.isDetailPanelOpen)
        #expect(!controller.isStopped)
        #expect(routing() == .list)
        #expect(panelMode() == TerminalChat.subAgentListPanelOverride)
        #expect(controller.agentID == nil)

        // Another round, then Esc in the list closes the panel and gives the
        // keys back.
        await terminal.handleDetailPanelAction(.focusNext)
        await terminal.handleDetailPanelAction(.confirm)
        #expect(controller.agentID == "agent-2")
        #expect(panelMode() == TerminalChat.subAgentListDetailPanelOverride)
        await terminal.handleDetailPanelAction(.close)
        #expect(terminal.isDetailPanelOpen)
        await terminal.handleDetailPanelAction(.close)
        #expect(!terminal.isDetailPanelOpen)
        #expect(controller.isStopped)
        #expect(routing() == .closed)
        #expect(panelMode() == nil)
    }

    /// An agent that opens directly (named in the command, or the only one in
    /// progress) has no list to go back to: its Esc closes the panel, as the
    /// help says.
    @Test
    func escInTheDetailOpenedDirectlyClosesThePanel() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = try makeTerminal(directory)
        let controller = openSubAgentPanel(on: terminal)
        await terminal.setDetailPanelMode(.detail, kind: .subAgent)
        controller.open(agentID: "agent-1", snapshot: agent("agent-1", name: "worker"))
        #expect(terminal.interactiveReader.withPanelLock { $0.panelOverlayOverride }
            == TerminalChat.subAgentDetailPanelOverride)

        await terminal.handleDetailPanelAction(.close)
        #expect(!terminal.isDetailPanelOpen)
        #expect(controller.isStopped)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode } == .closed)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelOverlayOverride } == nil)
    }
}
