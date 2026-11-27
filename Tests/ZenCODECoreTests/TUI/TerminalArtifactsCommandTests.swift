//
//  TerminalArtifactsCommandTests.swift
//  ZenCODE
//
//  The `/artifacts` command of the terminal: its registry entry, the answers
//  it shares with the shared command (arguments, no artifacts), the history
//  it prints without the interactive layout, and the presenter's hook that
//  refreshes an open `/artifacts` panel instead of writing in the chat.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

@ChatSessionActor
@Suite(.timeLimit(.minutes(1)))
struct TerminalArtifactsCommandTests {
    // MARK: - Fixtures

    private func makeRenderer() -> TerminalChatRenderCoordinator {
        TerminalChatRenderCoordinator(
            stdinIsTerminal: false, standardOutput: nil, standardError: nil,
            standardOutputIsTerminal: false, standardErrorIsTerminal: false,
            cursorTopology: .separate,
            capturesWrites: true, streamingFlushDelay: nil, columnWidthProvider: { 100 }
        )
    }

    private func makeTerminal(_ directory: URL, renderer: TerminalChatRenderCoordinator) throws -> TerminalChat {
        TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "test-model", availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")],
                workingDirectory: directory
            ), stdinIsTerminal: false, sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil),
            telegramTransportFactory: nil, renderCoordinator: renderer
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifacts-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func summary(_ path: String) -> TurnFileChangeSummary {
        TurnFileChangeSummary(entries: [
            .init(path: path, additions: 1, deletions: 0, status: .added,
                  isBinary: false, existedBefore: false, beforeDataBase64: nil,
                  patch: "@@ -0,0 +1,1 @@\n+let value = 1\n"),
        ])
    }

    private func output(_ renderer: TerminalChatRenderCoordinator) async -> String {
        TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
    }

    /// Opens the `/artifacts` panel by hand, as `/artifacts` does, on a
    /// screen that is never installed; `frames` records what it presents.
    private func openArtifacts(
        on terminal: TerminalChat,
        frames: PresentedFrames = PresentedFrames(),
        snapshot: @escaping @ChatSessionActor () async -> ChatFileArtifactSnapshot
    ) -> TerminalArtifactsPanelController {
        let session = TerminalModalSession(screen: TerminalPrimaryScreen(output: { _ in }))
        let controller = TerminalArtifactsPanelController(environment: .init(
            snapshot: snapshot,
            viewport: { (rows: 20, columns: 60) },
            present: { frames.lines = $0 },
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
        terminal.detailPanel = TerminalDetailPanel(content: .artifacts(controller), session: session)
        return controller
    }

    private func changedFile(_ path: String) -> FileChangeArtifact {
        FileChangeArtifact(
            absolutePath: "/repo/\(path)", displayPath: path, status: .modified,
            additions: 1, deletions: 1, oldText: "let value = 1\n", newText: "let value = 2\n"
        )
    }

    private func continuesTheChat(_ action: TerminalSubmittedLineAction) -> Bool {
        if case .continueChat = action { return true }
        return false
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting until \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - Registry

    @Test
    func artifactsIsAKnownCommandThatRunsWhileAPromptIsGenerating() {
        #expect(TerminalChat.isKnownSlashCommand("/artifacts"))
        #expect(TerminalChat.isKnownSlashCommand("/artifacts now"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/artifacts"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "  /artifacts"))
        #expect(TerminalChat.commandRegistry.descriptor(forLine: "/artifacts")?.scope == .channel)
    }

    /// The terminal's controller hands `/artifacts` back to the terminal; the
    /// shared operation answers as before for the other channels.
    @Test
    func theControllerHandsArtifactsToTheTerminalAndTheSharedOperationIsUnchanged() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = try makeTerminal(directory, renderer: makeRenderer())
        #expect(await terminal.chatSession.handleCommandLine("/artifacts", context: [])
            == ChatCommandOutcome(action: .channelCommand))
        #expect(await terminal.chatSession.runArtifactsCommand(line: "/artifacts")
            == ChatCommandOutcome(notices: [.noFileArtifacts]))
        #expect(await terminal.chatSession.runArtifactsCommand(line: "/artifacts now")
            == ChatCommandOutcome(notices: [.artifactsTakeNoArguments]))
        await terminal.chatSession.fileArtifactHistory.append(
            summary: summary("Added.swift"), sessionID: terminal.sessionID, workingDirectory: directory
        )
        let turns = await terminal.chatSession.fileArtifactHistory.snapshot()
        #expect(await terminal.chatSession.runArtifactsCommand(line: "/artifacts")
            == ChatCommandOutcome(notices: [.fileArtifacts(turns)]))
    }

    // MARK: - Answers

    @Test(arguments: ["/artifacts now", "/artifacts  all  "])
    func argumentsAreRefusedAsTheSharedCommandRefusesThem(_ line: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        // Even with artifacts to show.
        await terminal.chatSession.fileArtifactHistory.append(
            summary: summary("Added.swift"), sessionID: terminal.sessionID, workingDirectory: directory
        )
        #expect(continuesTheChat(await terminal.submittedLineAction(line)))
        let text = await output(renderer)
        #expect(text.contains(TerminalANSIText.stripANSI(ChatSessionNoticeText.text(for: .artifactsTakeNoArguments))))
        #expect(!text.contains("Added.swift"))
        #expect(!terminal.isDetailPanelOpen)
    }

    @Test
    func withoutArtifactsItAnswersAsTheSharedCommand() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        #expect(continuesTheChat(await terminal.submittedLineAction("/artifacts")))
        #expect(await output(renderer).contains(ChatSessionNoticeText.text(for: .noFileArtifacts)))
        #expect(!terminal.isDetailPanelOpen)
    }

    /// Without the interactive layout (here, no terminal) the panel cannot
    /// open: the history is printed as the shared command prints it.
    @Test
    func withoutTheInteractiveLayoutItPrintsTheHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        for path in ["Earlier.swift", "Latest.swift"] {
            await terminal.chatSession.fileArtifactHistory.append(
                summary: summary(path), sessionID: terminal.sessionID, workingDirectory: directory
            )
        }
        let turns = await terminal.chatSession.fileArtifactHistory.snapshot()
        #expect(terminal.detailPanelScreen() == nil)
        #expect(continuesTheChat(await terminal.submittedLineAction("/artifacts")))
        let text = await output(renderer)
        #expect(text.contains("🪬 Artifacts"))
        #expect(text.contains("### Turn 1 — 1 file"))
        #expect(text.contains("### Turn 2 — 1 file"))
        #expect(text.contains("**added `Earlier.swift`**  +1 -0"))
        #expect(text.contains("**added `Latest.swift`**  +1 -0"))
        #expect(text.contains(TerminalChat.renderFileArtifacts(turns, includeHistoryHeadings: true).trimmingCharacters(in: .newlines)))
        #expect(!terminal.isDetailPanelOpen)
        #expect(await terminal.chatSession.fileArtifactHistory.snapshot() == turns)
    }

    // MARK: - Panel keys

    /// Esc in the diff of a file picked from the list goes back to the list,
    /// and the help of the panel's bottom border follows each step (so does
    /// the input panel's mode, hidden behind the panel); Esc in the list
    /// closes the panel.
    @Test
    func escInTheDiffGoesBackToTheListAndTheHelpFollows() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = try makeTerminal(directory, renderer: makeRenderer())
        let snapshot = ChatFileArtifactSnapshot(
            turns: [
                .init(number: 1, artifacts: [changedFile("A.swift")]),
                .init(number: 2, artifacts: [changedFile("B.swift")]),
            ],
            activeTurnNumber: nil
        )
        let frames = PresentedFrames()
        let controller = openArtifacts(on: terminal, frames: frames) { snapshot }
        func routing() -> TerminalInteractiveLineReader.SubAgentDetailMode {
            terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode }
        }
        func panelMode() -> TerminalPanelModeOverride? {
            terminal.interactiveReader.withPanelLock { $0.panelOverlayOverride }
        }
        await terminal.setDetailPanelMode(.list, kind: .artifacts)
        controller.open(choosing: snapshot)
        #expect(routing() == .list)
        #expect(panelMode() == TerminalChat.artifactsListPanelOverride)
        #expect(frames.bottomBorder?.hasPrefix("╰─ ↑↓ choose · Enter open · Esc close ─") == true)

        await terminal.handleDetailPanelAction(.confirm)
        #expect(routing() == .detail)
        #expect(panelMode() == TerminalChat.artifactsListDetailPanelOverride)
        #expect(frames.bottomBorder?.hasPrefix("╰─ ↑↓ PgUp PgDn Home End scroll · Esc back ─") == true)
        #expect(controller.entryID == "2:/repo/B.swift")

        await terminal.handleDetailPanelAction(.close)
        #expect(terminal.isDetailPanelOpen)
        #expect(!controller.isStopped)
        #expect(routing() == .list)
        #expect(panelMode() == TerminalChat.artifactsListPanelOverride)
        #expect(controller.entryID == nil)

        // Another round, then Esc in the list closes the panel and gives the
        // keys back.
        await terminal.handleDetailPanelAction(.confirm)
        await terminal.handleDetailPanelAction(.close)
        #expect(terminal.isDetailPanelOpen)
        await terminal.handleDetailPanelAction(.close)
        #expect(!terminal.isDetailPanelOpen)
        #expect(controller.isStopped)
        #expect(routing() == .closed)
        #expect(panelMode() == nil)
    }

    /// The only file opens directly on its diff, whose Esc closes the panel,
    /// as the help in the bottom border says.
    @Test
    func escInTheDiffOfTheOnlyFileClosesThePanel() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = try makeTerminal(directory, renderer: makeRenderer())
        let snapshot = ChatFileArtifactSnapshot(
            turns: [.init(number: 1, artifacts: [changedFile("Only.swift")])],
            activeTurnNumber: nil
        )
        let frames = PresentedFrames()
        let controller = openArtifacts(on: terminal, frames: frames) { snapshot }
        await terminal.setDetailPanelMode(.detail, kind: .artifacts)
        controller.open(entryID: "1:/repo/Only.swift", in: snapshot)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelOverlayOverride }
            == TerminalChat.artifactsDetailPanelOverride)
        #expect(frames.bottomBorder?.hasPrefix("╰─ ↑↓ PgUp PgDn Home End scroll · Esc close ─") == true)

        await terminal.handleDetailPanelAction(.close)
        #expect(!terminal.isDetailPanelOpen)
        #expect(controller.isStopped)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode } == .closed)
    }

    /// The `/artifacts` panel hides the bottom layout as the `/subagent`
    /// detail does, in its list and in a diff, and a consent request that
    /// closes it shows the layout again before saying why.
    @Test
    func theArtifactsPanelHidesTheBottomLayoutUntilAConsentClosesIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        let snapshot = ChatFileArtifactSnapshot(
            turns: [.init(number: 1, artifacts: [changedFile("A.swift"), changedFile("B.swift")])],
            activeTurnNumber: nil
        )
        await terminal.openDetailPanel(
            .artifacts(snapshot, revision: terminal.fileArtifactsRevision),
            on: TerminalPrimaryScreen(output: { _ in })
        )
        #expect(terminal.detailPanel?.kind == .artifacts)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode } == .list)
        #expect(await terminal.statusBar.state.isFooterHidden)
        await terminal.handleDetailPanelAction(.confirm)
        #expect(terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode } == .detail)
        #expect(await terminal.statusBar.state.isFooterHidden)

        await terminal.closeDetailPanel(reason: .consent)
        #expect(!terminal.isDetailPanelOpen)
        #expect(!(await terminal.statusBar.state.isFooterHidden))
        #expect(await output(renderer).contains("Artifacts panel closed: a tool asks for consent."))
    }

    // MARK: - Presenter

    /// The live and sealed artifacts and the end of a turn write nothing in
    /// the chat: they only make an open `/artifacts` panel read again.
    @Test
    func thePresenterRefreshesAnOpenArtifactsPanelInsteadOfWritingInTheChat() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        let presenter = terminal.chatSessionPresenter
        let artifacts = FileChangeArtifactMapper.artifacts(
            from: [OperationFileChange(path: "Live.swift", oldText: "let a = 1\n", newText: "let a = 2\n")],
            workingDirectory: directory
        )
        let turn = SessionFileArtifactHistory.Turn(number: 1, artifacts: artifacts)

        // No panel open: only the revision moves.
        await presenter.presentLiveFileArtifacts([turn], agentID: nil)
        await presenter.presentLiveFileArtifacts([turn], agentID: "worker")
        await presenter.presentSealedFileArtifacts(turn)
        #expect(terminal.fileArtifactsRevision == 3)
        #expect(await renderer.capturedWriteEvents().isEmpty)

        let snapshot = ChatFileArtifactSnapshot(turns: [turn], activeTurnNumber: 1)
        let reads = ReadCounter()
        let controller = openArtifacts(on: terminal) {
            reads.count += 1
            return snapshot
        }
        controller.open(choosing: snapshot)
        await presenter.presentLiveFileArtifacts([turn], agentID: nil)
        await waitUntil("the panel reads again") { reads.count == 1 }
        #expect(controller.snapshotReadCount == 1)
        #expect(terminal.fileArtifactsRevision == 4)
        await presenter.turnWillFinish()
        #expect(terminal.fileArtifactsRevision == 5)
        #expect(await renderer.capturedWriteEvents().isEmpty)
        await terminal.closeDetailPanel(reason: .dismissed)
        #expect(controller.isStopped)
        let readsWhenClosed = reads.count

        // With the `/subagent` detail open instead nothing reads.
        let session = TerminalModalSession(screen: TerminalPrimaryScreen(output: { _ in }))
        let detail = TerminalSubAgentDetailController(environment: .init(
            snapshotEvents: { nil },
            transcript: { _ in nil },
            viewport: { (rows: 20, columns: 60) },
            present: { _ in },
            isCancelled: { false },
            onClosed: { _ in },
            standardErrorIsTerminal: false,
            subscribeResize: { _ in {} }
        ))
        terminal.detailPanel = TerminalDetailPanel(content: .subAgent(detail), session: session)
        await presenter.presentSealedFileArtifacts(turn)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(terminal.fileArtifactsRevision == 6)
        #expect(reads.count == readsWhenClosed)
        #expect(await renderer.capturedWriteEvents().isEmpty)
        await terminal.closeDetailPanel(reason: .dismissed)
        #expect(detail.isStopped)
    }
}

/// Counts the snapshot reads of a hand-opened panel.
@ChatSessionActor
private final class ReadCounter {
    var count = 0
}
