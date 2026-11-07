//
//  TerminalInteractionHostWorkspaceAccessTests.swift
//  ZenCODE
//
//  The terminal's workspace access request and the `/subagent` detail: the
//  detail closes only when the question is really asked. The terminal reads
//  the trust from `UserDefaults.standard`, so the suite is serialized and
//  removes the key it records.
//

import Foundation
import Testing
@testable import ZenCODECore

#if os(macOS)
@ChatSessionActor
@Suite(.serialized, .timeLimit(.minutes(1)))
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

    /// Opens an agent's detail by hand, as `/subagent` does, on a screen that
    /// is never installed.
    private func openDetail(on terminal: TerminalChat) async -> TerminalSubAgentDetailController {
        let session = TerminalModalSession(screen: TerminalPrimaryScreen(output: { _ in }))
        let controller = TerminalSubAgentDetailController(environment: .init(
            snapshotEvents: { nil },
            transcript: { _ in nil },
            viewport: { (rows: 20, columns: 60) },
            present: { _ in },
            isCancelled: { false },
            onClosed: { [weak terminal] reason in
                await terminal?.closeSubAgentDetail(reason: reason)
            },
            standardErrorIsTerminal: false,
            subscribeResize: { _ in {} }
        ))
        terminal.subAgentDetail = TerminalSubAgentDetail(controller: controller, session: session)
        terminal.interactiveReader.setSubAgentDetailMode(
            .detail,
            panelModeOverride: TerminalChat.subAgentDetailPanelOverride
        )
        return controller
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
        #expect(terminal.isSubAgentDetailOpen)
        #expect(!controller.isStopped)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode } == .detail)

        await terminal.closeSubAgentDetail(reason: .dismissed)
        #expect(!terminal.isSubAgentDetailOpen)
    }
}
#endif
