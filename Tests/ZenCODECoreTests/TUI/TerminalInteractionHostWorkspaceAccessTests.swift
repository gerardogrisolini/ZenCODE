//
//  TerminalInteractionHostWorkspaceAccessTests.swift
//  ZenCODE
//
//  The terminal's workspace access request and the modal panels (the
//  `/subagent` detail and the `/artifacts` panel, which hide the bottom
//  layout): a panel closes only
//  when the question is really asked. The terminal reads
//  the trust from `UserDefaults.standard`: every test records it under the key
//  of its own UUID-named folder and removes it, so the tests share nothing.
//

import Foundation
import Testing
@testable import ZenCODECore

#if os(macOS)
@ChatSessionActor
@Suite(.timeLimit(.minutes(1)))
struct TerminalInteractionHostWorkspaceAccessTests {
    private func makeTerminal() throws -> TerminalChat {
        TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: URL(
                    fileURLWithPath: "/tmp/ZenCODE-workspace-access-\(UUID().uuidString)",
                    isDirectory: true
                )
            ),
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

    /// Opens an agent's detail by hand, as `/subagent` does (the bottom
    /// layout hidden behind it), on a screen that is never installed.
    private func openDetail(on terminal: TerminalChat) async -> TerminalSubAgentDetailController {
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
            standardErrorIsTerminal: false,
            subscribeResize: { _ in {} }
        ))
        terminal.detailPanel = TerminalDetailPanel(content: .subAgent(controller), session: session)
        terminal.interactiveReader.setSubAgentDetailMode(
            .detail,
            panelModeOverride: TerminalChat.subAgentDetailPanelOverride
        )
        await terminal.statusBar.setFooterHidden(true)
        return controller
    }

    /// Opens the `/artifacts` panel on a file's diff by hand, as `/artifacts`
    /// does (the bottom layout hidden behind it), on a screen that is never
    /// installed.
    private func openArtifacts(on terminal: TerminalChat) async -> TerminalArtifactsPanelController {
        let session = TerminalModalSession(screen: TerminalPrimaryScreen(output: { _ in }))
        let empty = ChatFileArtifactSnapshot(turns: [], activeTurnNumber: nil)
        let controller = TerminalArtifactsPanelController(environment: .init(
            snapshot: { empty },
            viewport: { (rows: 20, columns: 60) },
            present: { _ in },
            isCancelled: { false },
            onClosed: { [weak terminal] reason in
                await terminal?.closeDetailPanel(reason: reason)
            },
            standardErrorIsTerminal: false,
            subscribeResize: { _ in {} }
        ))
        terminal.detailPanel = TerminalDetailPanel(content: .artifacts(controller), session: session)
        terminal.interactiveReader.setSubAgentDetailMode(
            .detail,
            panelModeOverride: TerminalChat.artifactsDetailPanelOverride
        )
        await terminal.statusBar.setFooterHidden(true)
        return controller
    }

    /// Whether the terminal's bottom layout is hidden behind a panel.
    private func isFooterHidden(_ terminal: TerminalChat) async -> Bool {
        await terminal.statusBar.state.isFooterHidden
    }

    /// A folder trusted already is granted without a question, so the open
    /// detail stays open.
    @Test
    func aTrustedFolderLeavesTheSubAgentDetailOpen() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-trusted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TerminalWorkspaceToolAccessStore.shared
        let key = await store.terminalConsentKey(for: folder)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        // Required: an untrusted folder would be asked on the terminal.
        try #require(await store.hasAccess(for: folder))

        let terminal = try makeTerminal()
        let controller = await openDetail(on: terminal)
        let host = TerminalInteractionHost(stdinIsTerminal: true, appMode: false)
        host.chat = terminal

        let granted = await host.requestWorkspaceAccess(
            ChatWorkspaceAccessRequest(workspaceURL: folder, toolTitles: ["Files"])
        )

        #expect(granted)
        #expect(terminal.detailPanel?.kind == .subAgent)
        #expect(!controller.isStopped)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode } == .detail)
        #expect(await isFooterHidden(terminal))

        await terminal.closeDetailPanel(reason: .dismissed)
        #expect(terminal.detailPanel?.kind != .subAgent)
        #expect(!terminal.isDetailPanelOpen)
        #expect(!(await isFooterHidden(terminal)))
    }

    /// The `/artifacts` panel closes as the `/subagent` detail does: a
    /// trusted folder leaves it open, the teardown gives the keys back.
    @Test
    func aTrustedFolderLeavesTheArtifactsPanelOpen() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-trusted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TerminalWorkspaceToolAccessStore.shared
        let key = await store.terminalConsentKey(for: folder)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        try #require(await store.hasAccess(for: folder))

        let terminal = try makeTerminal()
        let controller = await openArtifacts(on: terminal)
        let host = TerminalInteractionHost(stdinIsTerminal: true, appMode: false)
        host.chat = terminal

        let granted = await host.requestWorkspaceAccess(
            ChatWorkspaceAccessRequest(workspaceURL: folder, toolTitles: ["Files"])
        )

        #expect(granted)
        #expect(terminal.detailPanel?.kind == .artifacts)
        #expect(terminal.detailPanel?.kind != .subAgent)
        #expect(!controller.isStopped)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode } == .detail)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelOverlayOverride } == TerminalChat.artifactsDetailPanelOverride)
        #expect(await isFooterHidden(terminal))

        // The panel's own close (Esc) runs the one teardown.
        await controller.handle(.close)
        #expect(controller.isStopped)
        #expect(!terminal.isDetailPanelOpen)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode } == .closed)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelOverlayOverride } == nil)
        #expect(!(await isFooterHidden(terminal)))
    }

    /// A modal input (a menu, a line prompt) closes whichever panel is open,
    /// and shows the bottom layout again before the menu draws above it;
    /// opening one panel replaces the other through the same teardown.
    @Test
    func aModalInputClosesEitherPanel() async throws {
        let terminal = try makeTerminal()
        let artifacts = await openArtifacts(on: terminal)
        await terminal.closeDetailPanelForModalInput()
        #expect(artifacts.isStopped)
        #expect(!terminal.isDetailPanelOpen)
        #expect(!(await isFooterHidden(terminal)))

        let detail = await openDetail(on: terminal)
        await terminal.closeDetailPanelForModalInput()
        #expect(detail.isStopped)
        #expect(!terminal.isDetailPanelOpen)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode } == .closed)
        #expect(!(await isFooterHidden(terminal)))

        // The session ending closes the panel too; a second close does nothing.
        let next = await openArtifacts(on: terminal)
        await terminal.closeDetailPanel(reason: .sessionEnded)
        await terminal.closeDetailPanel(reason: .sessionEnded)
        #expect(next.isStopped)
        #expect(!terminal.isDetailPanelOpen)
        #expect(!(await isFooterHidden(terminal)))
    }
}
#endif
