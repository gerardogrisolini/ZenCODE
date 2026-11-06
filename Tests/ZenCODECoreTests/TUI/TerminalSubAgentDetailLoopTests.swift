//
//  TerminalSubAgentDetailLoopTests.swift
//  ZenCODE
//
//  The `/subagent` detail in the production panel FIFO and around it: the
//  keys the loop hands to it, the closings the loop's end and the session
//  swaps owe it, and the overview suspension a command leaves to it. The
//  detail is opened by hand, as `/subagent` opens it, on a screen that is
//  never installed: nothing here touches a model or a terminal.
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

    @ChatSessionActor
    private final class Harness {
        let terminal: TerminalChat
        let queue = TerminalChatEventQueue()
        let prompts = SubAgentDetailLoopPromptRecorder()
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
            terminal.onGenerateResponseForTesting = { attempt in
                prompts.record(attempt.prompt)
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
        /// first, then the controller, whose `onClosed` closes the detail,
        /// and the modal session, on a screen that is never installed.
        @discardableResult
        func openDetail() async -> TerminalSubAgentDetailController {
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
                standardErrorIsTerminal: false,
                subscribeResize: { _ in {} }
            ))
            terminal.subAgentDetail = TerminalSubAgentDetail(controller: controller, session: session)
            terminal.interactiveReader.setSubAgentDetailOpen(true)
            return controller
        }

        /// Whether the panel routes its keys to the detail.
        var readerRoutesKeysToDetail: Bool {
            terminal.interactiveReader.withPanelLock { $0.panelSubAgentDetailIsOpen }
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

        func detailClosed(timeout: Duration = .seconds(10)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while terminal.isSubAgentDetailOpen, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return !terminal.isSubAgentDetailOpen
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
    private let state = Mutex([String]())

    func record(_ prompt: String) {
        state.withLock { $0.append(prompt) }
    }

    var prompts: [String] {
        state.withLock { $0 }
    }
}

extension TerminalChatRenderCoordinator {
    /// Whether overview publication is suspended, by a command or by an
    /// external-writer phase.
    fileprivate var isOverviewPublishingSuspendedForTesting: Bool {
        overviewState.isSuspended
    }
}
