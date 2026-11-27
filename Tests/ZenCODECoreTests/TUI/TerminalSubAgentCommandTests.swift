//
//  TerminalSubAgentCommandTests.swift
//  ZenCODE
//
//  The `/subagent` command of the terminal: its registry entry, its `/help`
//  line, the sub-agent its argument names, and the layout it requires.
//

import Foundation
import Synchronization
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
    /// that is never installed and a session that has no sub-agent to follow;
    /// `frames` records what it presents.
    private func openSubAgentPanel(
        on terminal: TerminalChat,
        frames: PresentedFrames = PresentedFrames()
    ) -> TerminalSubAgentDetailController {
        let session = TerminalModalSession(screen: TerminalPrimaryScreen(output: { _ in }))
        let controller = TerminalSubAgentDetailController(environment: .init(
            snapshotEvents: { nil },
            transcript: { _ in nil },
            viewport: { (rows: 20, columns: 60) },
            present: { frames.lines = $0 },
            isCancelled: { false },
            onClosed: { [weak terminal] reason in
                await terminal?.closeDetailPanel(reason: reason)
            },
            modeDidChange: { [weak terminal] isChoosing in
                await terminal?.detailPanelModeDidChange(isChoosing: isChoosing, session: session)
            },
            sharedChatUnreadCount: { [weak terminal] in terminal?.sharedChatUnreadCount ?? 0 },
            standardErrorIsTerminal: false,
            subscribeResize: { _ in {} }
        ))
        terminal.detailPanel = TerminalDetailPanel(content: .subAgent(controller), session: session)
        return controller
    }

    /// Whether the terminal's bottom layout is hidden behind a panel.
    private func isFooterHidden(_ terminal: TerminalChat) async -> Bool {
        await terminal.statusBar.state.isFooterHidden
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
    /// list, and the help of the panel's bottom border follows each step (so
    /// does the input panel's mode, hidden behind the panel); Esc in the list
    /// closes the panel.
    @Test
    func escInTheDetailGoesBackToTheListAndTheHelpFollows() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = try makeTerminal(directory)
        let agents = [agent("agent-1", name: "worker"), agent("agent-2", name: "reviewer")]
        let frames = PresentedFrames()
        let controller = openSubAgentPanel(on: terminal, frames: frames)
        func routing() -> TerminalInteractiveLineReader.SubAgentDetailMode {
            terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode }
        }
        func panelMode() -> TerminalPanelModeOverride? {
            terminal.interactiveReader.withPanelLock { $0.panelOverlayOverride }
        }
        let listHelp = "╰─ " + TerminalChat.subAgentListPanelOverride.helpText + " ─"
        let backHelp = "╰─ " + TerminalChat.subAgentListDetailPanelOverride.helpText + " ─"
        await terminal.setDetailPanelMode(.list, kind: .subAgent)
        controller.open(choosing: agents)
        #expect(routing() == .list)
        #expect(panelMode() == TerminalChat.subAgentListPanelOverride)
        #expect(frames.bottomBorder?.hasPrefix(listHelp) == true)

        await terminal.handleDetailPanelAction(.confirm)
        #expect(routing() == .detail)
        #expect(panelMode() == TerminalChat.subAgentListDetailPanelOverride)
        #expect(frames.bottomBorder?.hasPrefix(backHelp) == true)
        #expect(frames.bottomBorder?.contains("Esc back") == true)
        #expect(controller.agentID == "agent-1")

        await terminal.handleDetailPanelAction(.close)
        #expect(terminal.isDetailPanelOpen)
        #expect(!controller.isStopped)
        #expect(routing() == .list)
        #expect(panelMode() == TerminalChat.subAgentListPanelOverride)
        #expect(frames.bottomBorder?.hasPrefix(listHelp) == true)
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
    /// help in the bottom border says.
    @Test
    func escInTheDetailOpenedDirectlyClosesThePanel() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = try makeTerminal(directory)
        let frames = PresentedFrames()
        let controller = openSubAgentPanel(on: terminal, frames: frames)
        await terminal.setDetailPanelMode(.detail, kind: .subAgent)
        controller.open(agentID: "agent-1", snapshot: agent("agent-1", name: "worker"))
        #expect(terminal.interactiveReader.withPanelLock { $0.panelOverlayOverride }
            == TerminalChat.subAgentDetailPanelOverride)
        #expect(frames.bottomBorder?.hasPrefix("╰─ ↑↓ PgUp PgDn Home End scroll · Esc close ─") == true)

        await terminal.handleDetailPanelAction(.close)
        #expect(!terminal.isDetailPanelOpen)
        #expect(controller.isStopped)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode } == .closed)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelOverlayOverride } == nil)
    }
}

// MARK: - Bottom layout

/// How a test closes an open panel.
enum TerminalPanelCloseRoute: CaseIterable, Sendable {
    /// `Esc` in the detail the panel opened on.
    case escape
    /// A tool consent request.
    case consent
    /// A menu or a line prompt (``TerminalChat/closeDetailPanelForModalInput()``).
    case modalInput
    /// The chat session ending.
    case sessionEnded
}

extension TerminalSubAgentCommandTests {
    /// Opening a panel hides the bottom layout (the dock, the input panel and
    /// the status bar) and every way it closes shows it again, with the keys
    /// back to the draft and the external-writer phase given back.
    @Test(arguments: TerminalPanelCloseRoute.allCases)
    func openingHidesTheBottomLayoutAndEveryCloseShowsItAgain(_ route: TerminalPanelCloseRoute) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = try makeTerminal(directory)
        #expect(!(await isFooterHidden(terminal)))

        await terminal.openDetailPanel(
            .subAgent(.agent(agent("agent-1", name: "worker"))),
            on: TerminalPrimaryScreen(output: { _ in })
        )
        #expect(terminal.detailPanel?.kind == .subAgent)
        #expect(await isFooterHidden(terminal))
        #expect(terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode } == .detail)
        #expect(await terminal.renderCoordinator.externalTerminalPromptDepth == 1)

        switch route {
        case .escape:
            await terminal.handleDetailPanelAction(.close)
        case .consent:
            await terminal.closeDetailPanel(reason: .consent)
        case .modalInput:
            await terminal.closeDetailPanelForModalInput()
        case .sessionEnded:
            await terminal.closeDetailPanel(reason: .sessionEnded)
        }
        #expect(!terminal.isDetailPanelOpen)
        #expect(!(await isFooterHidden(terminal)))
        #expect(terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode } == .closed)
        #expect(await terminal.renderCoordinator.externalTerminalPromptDepth == 0)
    }

    /// A panel that replaces another keeps the bottom layout hidden from one
    /// frame to the next instead of showing it for a moment, and the new
    /// panel's close shows it again.
    @Test
    func aPanelReplacingAnotherKeepsTheBottomLayoutHidden() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = try makeTerminal(directory)
        let screen = TerminalPrimaryScreen(output: { _ in })
        await terminal.openDetailPanel(.subAgent(.agent(agent("agent-1", name: "worker"))), on: screen)
        #expect(await isFooterHidden(terminal))

        // What `/subagent` and `/artifacts` do before opening their panel.
        await terminal.closeDetailPanel(reason: .replaced, keepsFooterHidden: true)
        #expect(!terminal.isDetailPanelOpen)
        #expect(await isFooterHidden(terminal))
        let snapshot = ChatFileArtifactSnapshot(
            turns: [.init(number: 1, artifacts: [
                FileChangeArtifact(
                    absolutePath: "/repo/Only.swift", displayPath: "Only.swift", status: .modified,
                    additions: 1, deletions: 1, oldText: "let value = 1\n", newText: "let value = 2\n"
                ),
            ])],
            activeTurnNumber: nil
        )
        await terminal.openDetailPanel(.artifacts(snapshot, revision: terminal.fileArtifactsRevision), on: screen)
        #expect(terminal.detailPanel?.kind == .artifacts)
        #expect(await isFooterHidden(terminal))

        await terminal.handleDetailPanelAction(.close)
        #expect(!terminal.isDetailPanelOpen)
        #expect(!(await isFooterHidden(terminal)))
        #expect(await terminal.renderCoordinator.externalTerminalPromptDepth == 0)
    }

    /// A close requested while the panel opens, before it exists (here a
    /// consent request), cancels the opening: nothing opens, and the bottom
    /// layout and the external-writer phase are given back.
    @Test
    func aCancelledOpeningShowsTheBottomLayoutAgain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = try makeTerminal(directory)
        let opening = Task {
            await terminal.openDetailPanel(
                .subAgent(.agent(agent("agent-1", name: "worker"))),
                on: TerminalPrimaryScreen(output: { _ in })
            )
        }
        while !terminal.isOpeningDetailPanel {
            await Task.yield()
        }
        // The opening is suspended before the panel exists: the close only
        // asks it to give everything back.
        #expect(terminal.detailPanel == nil)
        await terminal.closeDetailPanel(reason: .consent)
        await opening.value

        #expect(!terminal.isDetailPanelOpen)
        #expect(!terminal.isOpeningDetailPanel)
        #expect(!(await isFooterHidden(terminal)))
        #expect(terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode } == .closed)
        #expect(await terminal.renderCoordinator.externalTerminalPromptDepth == 0)
    }

    /// The bottom border of the open panel says how many shared-chat
    /// messages are unread, live: a change redraws it without any new data
    /// of the panel, and the badge goes at zero.
    @Test
    func theBottomBorderShowsTheUnreadSharedChatMessagesLive() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = try makeTerminal(directory)
        let unread = UnreadSharedChatMessages()
        terminal.sharedChatUnreadCountReader = { unread.count }
        let capture = PrimaryScreenCapture()
        await terminal.openDetailPanel(.subAgent(.agent(agent("agent-1", name: "worker"))), on: capture.screen())
        func bottomRow() -> String {
            capture.terminal.withLock { $0.viewport.last?.text ?? "" }
        }
        #expect(bottomRow().hasPrefix("╰─ ↑↓ PgUp PgDn Home End scroll · Esc close ─"))

        unread.count = 3
        terminal.sharedChatUnreadCountDidChange()
        #expect(bottomRow().hasPrefix("╰─ Chat: 3 new · ↑↓ PgUp PgDn Home End scroll · Esc close ─"))
        unread.count = 1
        terminal.sharedChatUnreadCountDidChange()
        #expect(bottomRow().hasPrefix("╰─ Chat: 1 new · ↑↓"))
        unread.count = 0
        terminal.sharedChatUnreadCountDidChange()
        #expect(bottomRow().hasPrefix("╰─ ↑↓ PgUp PgDn Home End scroll · Esc close ─"))
        #expect(!capture.visible.contains("Chat:"))

        await terminal.closeDetailPanel(reason: .dismissed)
        // Without a panel nothing is drawn.
        unread.count = 5
        terminal.sharedChatUnreadCountDidChange()
        #expect(!capture.visible.contains("Chat: 5 new"))
    }
}

/// The last frame a hand-opened panel presented.
@ChatSessionActor
final class PresentedFrames {
    var lines: [String] = []

    /// The bottom border of the last frame, without styling.
    var bottomBorder: String? {
        lines.last.map(TerminalANSIText.stripANSI)
    }
}

/// The unread shared-chat messages a test hands to an open panel.
@ChatSessionActor
private final class UnreadSharedChatMessages {
    var count = 0
}
