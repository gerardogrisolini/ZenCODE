//
//  TerminalSubAgentDetailLoopTests.swift
//  ZenCODE
//
//  The `/subagent` detail in the production panel FIFO and around it: the
//  keys the loop hands to it and the prompts typed below it, the closings
//  the loop's end, the session swaps and the menus owe it, and the overview
//  suspension a command leaves to it. The detail is opened by hand, as
//  `/subagent` opens it, on a screen that is never installed: nothing here
//  touches a model or a terminal.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@ChatSessionActor
@Suite(.timeLimit(.minutes(1)))
struct TerminalSubAgentDetailLoopTests {
    private static let layoutMessage = "ZenCODE: /subagent requires the interactive terminal layout.\n"
    private static let consentNotice = "Sub-agent detail closed: a tool asks for consent.\n"

    /// How the interactive panel loop ends.
    enum LoopExit: CaseIterable, Sendable {
        case endOfInput
        case exitCommand
    }

    /// The session swaps the detail does not survive.
    enum SessionSwap: CaseIterable, Sendable {
        case newSession
        case savedSessionLoad

        var change: ChatIncarnationChange {
            switch self {
            case .newSession: .newSessionWillStart
            case .savedSessionLoad: .savedSessionWillLoad
            }
        }
    }

    /// The menus and line prompts that close an open detail before they
    /// open: the interactions of the terminal's host (the shared commands'
    /// menus) and the terminal's own (`/feature`, the attachment picker).
    enum ModalInput: CaseIterable, Sendable {
        case chooseOne
        case chooseMany
        case chooseManyWithFocus
        case readLine
        case pickAttachment
        case featureLine
        case featureYesNo
        case featureWizard

        /// Asks for the input. The caller's task is cancelled, so the
        /// blocking read gives up at once and nothing reads the terminal.
        @ChatSessionActor
        func ask(on terminal: TerminalChat, directory: URL) async {
            let host = terminal.interactionHost
            let items = [ChatChoiceItem(id: "one", title: "One")]
            switch self {
            case .chooseOne:
                _ = await host.chooseOne(title: "Model", items: items, selectedID: nil)
            case .chooseMany:
                _ = await host.chooseMany(title: "Tools", items: items, selectedIDs: [])
            case .chooseManyWithFocus:
                _ = await host.chooseManyWithFocus(
                    title: "Skills",
                    items: items,
                    selectedIDs: [],
                    focusedID: nil,
                    toggleLabel: "skill",
                    confirmLabel: "apply"
                )
            case .readLine:
                _ = await host.readLine(prompt: "Name: ")
            case .pickAttachment:
                _ = await host.pickAttachment(startingAt: directory)
            case .featureLine:
                _ = await terminal.promptFeatureLine("Feature id", required: true)
            case .featureYesNo:
                _ = await terminal.promptFeatureYesNo("Delete it?", defaultValue: false)
            case .featureWizard:
                _ = await terminal.runFeatureWizard()
            }
        }
    }

    private static let referenceDate = Date(timeIntervalSince1970: 1_000_000)

    private static func agent(_ id: String, name: String) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: id,
            name: name,
            role: "Reviews the change",
            status: .running,
            pending: true,
            currentActivity: nil,
            currentActivityKind: nil,
            latestEventAt: referenceDate,
            latestOutput: nil,
            executionRevision: 1,
            latestError: nil,
            createdAt: referenceDate,
            updatedAt: referenceDate
        )
    }

    @ChatSessionActor
    private final class Harness {
        let terminal: TerminalChat
        let queue = TerminalChatEventQueue()
        let prompts = SubAgentDetailLoopPromptRecorder()
        /// Holds the generations while closed (see
        /// ``SubAgentDetailLoopGenerationGate``); open by default.
        let generationGate = SubAgentDetailLoopGenerationGate()
        /// The reasons the open detail's controller reported through
        /// `onClosed`.
        private(set) var controllerCloseReasons: [TerminalSubAgentDetailController.CloseReason] = []

        init() throws {
            terminal = TerminalChat(
                configuration: try AgentConfiguration(
                    hostedModelID: "remote-community/test",
                    availableAgents: AgentProfileStore.defaultProfiles(),
                    workingDirectory: URL(
                        fileURLWithPath: "/tmp/ZenCODE-subagent-loop-\(UUID().uuidString)",
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
            terminal.interactiveRuntimeEventQueueForTesting = queue
            terminal.bypassInteractivePanelInputForTesting = true
            terminal.capturedCommandOutputForTesting = []
            let prompts = prompts
            terminal.onSharedChatPublicationForTesting = {
                prompts.recordPublication()
                return true
            }
            let gate = generationGate
            terminal.onGenerateResponseForTesting = { attempt in
                prompts.record(attempt.prompt)
                await gate.pass()
                // A generation the panel cancelled would see it here.
                prompts.recordGenerationEnd(cancelled: Task.isCancelled)
                return TerminalChatGenerationSuccess(
                    response: DirectAgentResponse(text: "Risposta.", stopReason: "stop", modelID: "test"),
                    origin: attempt.origin,
                    fileChangeSummary: nil,
                    automaticallyCompletedPlan: nil,
                    finalAssistantContent: "Risposta."
                )
            }
        }

        // MARK: Detail

        /// Opens a detail as `/subagent` does: the external-writer phase
        /// first, then the controller, whose `onClosed` closes the detail and
        /// whose `modeDidChange` reaches the terminal, and the modal session,
        /// on a screen that is never installed. With `choosing` the detail
        /// lists those agents, otherwise it shows an agent.
        @discardableResult
        func openDetail(
            choosing snapshots: [DirectSubAgentRuntime.AgentSnapshot]? = nil
        ) async -> TerminalSubAgentDetailController {
            let terminal = terminal
            await terminal.renderCoordinator.beginExternalTerminalPrompt()
            let session = TerminalModalSession(screen: TerminalPrimaryScreen(output: { _ in }))
            let controller = TerminalSubAgentDetailController(environment: .init(
                snapshotEvents: { nil },
                transcript: { _ in nil },
                viewport: { (rows: 20, columns: 60) },
                present: { _ in },
                isCancelled: { false },
                onClosed: { [weak self, weak terminal] reason in
                    self?.controllerCloseReasons.append(reason)
                    await terminal?.closeSubAgentDetail(reason: reason)
                },
                modeDidChange: { [weak terminal] isChoosing in
                    await terminal?.subAgentDetailModeDidChange(isChoosing: isChoosing, session: session)
                },
                standardErrorIsTerminal: false,
                subscribeResize: { _ in {} }
            ))
            terminal.subAgentDetail = TerminalSubAgentDetail(controller: controller, session: session)
            if let snapshots {
                terminal.interactiveReader.setSubAgentDetailMode(
                    .list,
                    panelModeOverride: TerminalChat.subAgentListPanelOverride
                )
                await terminal.interactiveReader.refreshPanel()
                controller.open(choosing: snapshots)
            } else {
                terminal.interactiveReader.setSubAgentDetailMode(
                    .detail,
                    panelModeOverride: TerminalChat.subAgentDetailPanelOverride
                )
                await terminal.interactiveReader.refreshPanel()
            }
            return controller
        }

        /// How the panel routes its keys to the detail.
        var readerDetailMode: TerminalInteractiveLineReader.SubAgentDetailMode {
            terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailMode }
        }

        /// Whether the panel routes keys to the detail.
        var readerRoutesKeysToDetail: Bool {
            readerDetailMode != .closed
        }

        var panelDraft: String {
            terminal.interactiveReader.withPanelLock { String($0.panelBuffer) }
        }

        var panelOverride: TerminalPanelModeOverride? {
            terminal.interactiveReader.withPanelLock { $0.panelOverlayOverride }
        }

        var queuedPromptCount: Int {
            terminal.interactiveReader.withPanelLock { $0.panelQueuedPromptCount }
        }

        var externalTerminalPromptDepth: Int {
            get async { await terminal.renderCoordinator.externalTerminalPromptDepth }
        }

        var isOverviewPublishingSuspended: Bool {
            get async { await terminal.renderCoordinator.isOverviewPublishingSuspendedForTesting }
        }

        /// Whether the detail is closed and gave the terminal back: the keys,
        /// the external-writer phase, and the overviews.
        func detailGaveTheTerminalBack() async -> Bool {
            let depth = await externalTerminalPromptDepth
            let isSuspended = await isOverviewPublishingSuspended
            return !terminal.isSubAgentDetailOpen
                && !readerRoutesKeysToDetail
                && depth == 0
                && !isSuspended
        }

        // MARK: Loop

        func send(_ event: TerminalPromptInputEvent) {
            queue.send(.input(event))
        }

        /// Reads `keys` through the panel's key handling, which hands its
        /// events to the loop as the live panel does.
        func press(_ keys: TerminalInteractiveLineReader.Key...) async {
            let queue = queue
            for key in keys {
                await terminal.interactiveReader.handlePanelKey(key) { event in
                    _ = await queue.sendWithBackpressure(.input(event))
                }
            }
        }

        /// Types `text` into the panel, one character per key.
        func type(_ text: String) async {
            for character in text {
                await press(.character(String(character)))
            }
        }

        /// Waits until `condition` holds, or the timeout elapses.
        func eventually(
            timeout: Duration = .seconds(10),
            _ condition: () async -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return await condition()
        }

        func run() async -> Task<Void, Error> {
            let terminal = terminal
            let loop = Task { try await terminal.runInteractivePanelLoop() }
            while terminal.voiceEventQueue !== queue {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return loop
        }

        func end(_ loop: Task<Void, Error>, by exit: LoopExit = .endOfInput) async throws {
            switch exit {
            case .endOfInput:
                send(.endOfInput)
            case .exitCommand:
                send(.submitted("/exit"))
            }
            try await loop.value
        }

        func promptsReached(_ expected: [String], timeout: Duration = .seconds(10)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while prompts.prompts != expected, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return prompts.prompts == expected
        }

        /// Waits until the detail is closed and its teardown has finished.
        /// `closeSubAgentDetail(reason:)` takes the detail before its first
        /// suspension and gives the panel mode, the external-writer phase,
        /// and the overviews back afterwards, so the detail alone reads closed
        /// before the terminal is given back.
        func detailClosed(timeout: Duration = .seconds(10)) async -> Bool {
            await eventually(timeout: timeout) { await detailGaveTheTerminalBack() }
        }

        var capturedOutput: [String] {
            terminal.capturedCommandOutputForTesting ?? []
        }
    }

    // MARK: - Keys

    @Test
    func aDetailKeyWithNoDetailOpenDoesNothingAndTheLoopGoesOn() async throws {
        let harness = try Harness()
        let loop = await harness.run()

        harness.send(.subAgentDetail(.close))
        harness.send(.subAgentDetail(.scrollDown))
        harness.send(.submitted("ciao"))

        let ran = await harness.promptsReached(["ciao"])
        #expect(ran)
        #expect(!harness.terminal.isSubAgentDetailOpen)
        #expect(await harness.externalTerminalPromptDepth == 0)
        try await harness.end(loop)
        #expect(!harness.capturedOutput.contains(Self.consentNotice))
    }

    @Test
    func escapeInTheOpenDetailClosesItThroughItsController() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        let controller = await harness.openDetail()

        harness.send(.subAgentDetail(.close))

        let closed = await harness.detailClosed()
        #expect(closed)
        #expect(harness.controllerCloseReasons == [.dismissed])
        #expect(controller.isStopped)
        #expect(await harness.detailGaveTheTerminalBack())
        try await harness.end(loop)
        #expect(!harness.capturedOutput.contains(Self.consentNotice))
    }

    // MARK: - The prompt below an agent's detail

    /// Below an agent's detail the operator types and sends prompts: they
    /// run, a prompt sent while one runs is queued and runs next, and the
    /// detail stays open throughout, keeping the main transcript's output
    /// in its external-writer phase until `Esc` closes it.
    @Test
    func promptsTypedBelowAnAgentsDetailRunAndQueueWithTheDetailOpen() async throws {
        let harness = try Harness()
        await harness.generationGate.hold()
        let loop = await harness.run()
        await harness.openDetail()

        await harness.type("uno")
        await harness.press(.enter)
        let started = await harness.promptsReached(["uno"])
        #expect(started)

        // `q` closes only the agent list: here it is the text of a prompt,
        // which waits in the queue while the first one runs.
        await harness.type("q")
        await harness.press(.enter)
        let queued = await harness.eventually { harness.queuedPromptCount == 1 }
        #expect(queued)
        #expect(harness.terminal.isSubAgentDetailOpen)
        #expect(harness.readerDetailMode == .detail)
        #expect(await harness.externalTerminalPromptDepth == 1)

        await harness.generationGate.release()
        let ran = await harness.promptsReached(["uno", "q"])
        #expect(ran)
        let drained = await harness.eventually {
            harness.prompts.generationEnds.count == 2 && harness.queuedPromptCount == 0
        }
        #expect(drained)
        #expect(harness.prompts.generationEnds == [false, false])
        #expect(harness.terminal.isSubAgentDetailOpen)
        #expect(await harness.externalTerminalPromptDepth == 1)
        #expect(harness.panelDraft.isEmpty)

        await harness.press(.cancel)
        let closed = await harness.detailClosed()
        #expect(closed)
        #expect(harness.controllerCloseReasons == [.dismissed])
        #expect(await harness.detailGaveTheTerminalBack())
        try await harness.end(loop)
    }

    /// `Esc` below an agent's detail closes the detail, never the
    /// generation: the turn that runs meanwhile ends as it would.
    @Test
    func escapeBelowAnAgentsDetailClosesItAndTheGenerationGoesOn() async throws {
        let harness = try Harness()
        await harness.generationGate.hold()
        let loop = await harness.run()
        await harness.openDetail()

        await harness.type("uno")
        await harness.press(.enter)
        let started = await harness.promptsReached(["uno"])
        #expect(started)

        await harness.press(.cancel)
        let closed = await harness.detailClosed()
        #expect(closed)
        #expect(harness.controllerCloseReasons == [.dismissed])

        await harness.generationGate.release()
        let ended = await harness.eventually { harness.prompts.generationEnds.count == 1 }
        #expect(ended)
        #expect(harness.prompts.generationEnds == [false])
        try await harness.end(loop)
    }

    /// A live `@` mention typed below an agent's detail is sent, not run as
    /// a prompt, and the detail stays open.
    @Test
    func aMentionTypedBelowAnAgentsDetailIsSentWithTheDetailOpen() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        await harness.openDetail()

        await harness.type("@coordinator ciao")
        await harness.press(.enter)

        let sent = await harness.eventually { harness.prompts.publications == 1 }
        #expect(sent)
        #expect(harness.prompts.prompts.isEmpty)
        #expect(harness.terminal.isSubAgentDetailOpen)
        #expect(harness.readerDetailMode == .detail)
        #expect(harness.panelDraft.isEmpty)
        try await harness.end(loop)
    }

    /// The agent list owns every key: typed text is swallowed and `Enter`
    /// opens the focused agent, whose detail then leaves the text keys to
    /// the prompt and shows its own panel mode.
    @Test
    func theAgentListOwnsTheKeysUntilAnAgentIsOpened() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        let controller = await harness.openDetail(
            choosing: [Self.agent("agent-1", name: "alpha"), Self.agent("agent-2", name: "beta")]
        )
        #expect(harness.readerDetailMode == .list)

        await harness.type("x")
        #expect(harness.panelDraft.isEmpty)

        await harness.press(.enter)
        let opened = await harness.eventually { harness.readerDetailMode == .detail }
        #expect(opened)
        #expect(controller.agentID == "agent-1")
        #expect(harness.panelOverride == TerminalChat.subAgentDetailPanelOverride)

        await harness.type("q")
        #expect(harness.panelDraft == "q")
        #expect(harness.terminal.isSubAgentDetailOpen)

        await harness.press(.cancel)
        let closed = await harness.detailClosed()
        #expect(closed)
        #expect(await harness.detailGaveTheTerminalBack())
        #expect(harness.panelOverride == nil)
        try await harness.end(loop)
    }

    /// `q` closes the agent list.
    @Test
    func qClosesTheAgentList() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        let controller = await harness.openDetail(
            choosing: [Self.agent("agent-1", name: "alpha"), Self.agent("agent-2", name: "beta")]
        )

        await harness.press(.character("q"))

        let closed = await harness.detailClosed()
        #expect(closed)
        #expect(harness.controllerCloseReasons == [.dismissed])
        #expect(controller.isStopped)
        #expect(harness.panelDraft.isEmpty)
        #expect(await harness.detailGaveTheTerminalBack())
        try await harness.end(loop)
    }

    // MARK: - Menus

    /// A menu or a line prompt closes the open detail before it opens, as
    /// another panel taking its place: the keys, the external-writer phase
    /// and the overviews come back first, and nothing says why.
    @Test(arguments: ModalInput.allCases)
    func aMenuOrALinePromptClosesTheOpenDetailFirst(_ input: ModalInput) async throws {
        let harness = try Harness()
        let controller = await harness.openDetail()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-subagent-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminal = harness.terminal

        // Cancelled before it starts: the detail closes, then the blocking
        // read gives up without touching the terminal.
        let asking = Task { @ChatSessionActor in
            await input.ask(on: terminal, directory: directory)
        }
        asking.cancel()
        await asking.value

        #expect(controller.isStopped)
        #expect(await harness.detailGaveTheTerminalBack())
        #expect(harness.controllerCloseReasons.isEmpty)
        #expect(!harness.capturedOutput.contains(Self.consentNotice))
    }

    /// A command that opens no menu leaves the detail open.
    @Test
    func aCommandThatOpensNoMenuLeavesTheDetailOpen() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        let controller = await harness.openDetail()

        harness.send(.submitted("/help"))
        harness.send(.submitted("ciao"))

        let ran = await harness.promptsReached(["ciao"])
        #expect(ran)
        #expect(!controller.isStopped)
        #expect(harness.terminal.isSubAgentDetailOpen)
        #expect(harness.readerDetailMode == .detail)
        #expect(await harness.externalTerminalPromptDepth == 1)
        try await harness.end(loop)
    }

    // MARK: - Closings

    @Test
    func closingWithNoDetailOpenDoesNothing() async throws {
        let harness = try Harness()
        // Another external-writer phase is under way: a closing with no
        // detail open must not end it.
        await harness.terminal.renderCoordinator.beginExternalTerminalPrompt()

        for reason: TerminalSubAgentDetailController.CloseReason in [
            .dismissed, .consent, .sessionEnded, .replaced, .layoutUnavailable,
        ] {
            await harness.terminal.closeSubAgentDetail(reason: reason)
        }

        #expect(await harness.externalTerminalPromptDepth == 1)
        #expect(await harness.isOverviewPublishingSuspended)
        #expect(harness.capturedOutput.isEmpty)
        #expect(!harness.terminal.isSubAgentDetailOpen)
        #expect(!harness.readerRoutesKeysToDetail)
        await harness.terminal.renderCoordinator.endExternalTerminalPrompt()
    }

    @Test(arguments: LoopExit.allCases)
    func theLoopEndingClosesAnOpenDetail(_ exit: LoopExit) async throws {
        let harness = try Harness()
        let loop = await harness.run()
        let controller = await harness.openDetail()

        try await harness.end(loop, by: exit)

        #expect(controller.isStopped)
        #expect(await harness.detailGaveTheTerminalBack())
        // The terminal tears the detail down itself: the controller reports
        // nothing, and only a consent request writes why it closed.
        #expect(harness.controllerCloseReasons.isEmpty)
        #expect(!harness.capturedOutput.contains(Self.consentNotice))
    }

    @Test(arguments: SessionSwap.allCases)
    func aSessionSwapClosesAnOpenDetail(_ swap: SessionSwap) async throws {
        let harness = try Harness()
        let controller = await harness.openDetail()

        await harness.terminal.incarnationDidChange(reason: swap.change)

        #expect(controller.isStopped)
        #expect(await harness.detailGaveTheTerminalBack())
        #expect(harness.controllerCloseReasons.isEmpty)
        #expect(!harness.capturedOutput.contains(Self.consentNotice))
    }

    // MARK: - Overview suspension

    @Test
    func aSubAgentCommandThatOpensNothingResumesTheOverviews() async throws {
        let harness = try Harness()
        let loop = await harness.run()

        harness.send(.submitted("/subagent"))
        // The prompt runs once the command is done with.
        harness.send(.submitted("ciao"))

        let ran = await harness.promptsReached(["ciao"])
        #expect(ran)
        #expect(harness.capturedOutput.contains(Self.layoutMessage))
        #expect(!harness.terminal.isSubAgentDetailOpen)
        #expect(!(await harness.isOverviewPublishingSuspended))
        try await harness.end(loop)
    }

    @Test
    func aCommandThatLeavesTheDetailOpenLeavesTheOverviewsToIt() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        await harness.openDetail()

        // Without the interactive layout `/subagent` opens nothing and leaves
        // the open detail as it is.
        harness.send(.submitted("/subagent"))
        harness.send(.submitted("ciao"))

        let ran = await harness.promptsReached(["ciao"])
        #expect(ran)
        #expect(harness.capturedOutput.contains(Self.layoutMessage))
        #expect(harness.terminal.isSubAgentDetailOpen)
        #expect(await harness.isOverviewPublishingSuspended)

        harness.send(.subAgentDetail(.close))
        let closed = await harness.detailClosed()
        #expect(closed)
        #expect(await harness.detailGaveTheTerminalBack())
        try await harness.end(loop)
    }
}

private final class SubAgentDetailLoopPromptRecorder: Sendable {
    private struct State {
        var prompts: [String] = []
        var generationEnds: [Bool] = []
        var publications = 0
    }

    private let state = Mutex(State())

    func record(_ prompt: String) {
        state.withLock { $0.prompts.append(prompt) }
    }

    /// A generation ended; `cancelled` says whether its task was cancelled.
    func recordGenerationEnd(cancelled: Bool) {
        state.withLock { $0.generationEnds.append(cancelled) }
    }

    func recordPublication() {
        state.withLock { $0.publications += 1 }
    }

    var prompts: [String] {
        state.withLock { $0.prompts }
    }

    /// Whether each ended generation saw its task cancelled, in order.
    var generationEnds: [Bool] {
        state.withLock { $0.generationEnds }
    }

    var publications: Int {
        state.withLock { $0.publications }
    }
}

/// Holds the generations that reach it between ``hold()`` and
/// ``release()``; open otherwise.
private actor SubAgentDetailLoopGenerationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() {
        isHeld = true
    }

    func pass() async {
        guard isHeld else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isHeld = false
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

extension TerminalChatRenderCoordinator {
    /// Whether overview publication is suspended, by a command or by an
    /// external-writer phase.
    fileprivate var isOverviewPublishingSuspendedForTesting: Bool {
        overviewState.isSuspended
    }
}
