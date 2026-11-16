//
//  TerminalChatRenderingTests+StatusBarInterleaving.swift
//  ZenCODE
//
//  Tests for the terminal chat status bar synchronization, compact tool
//  rewrite state and the sub-agent overview refresh lifecycle, with the tick
//  gate they rely on.
//

import Foundation
import Markdown
import Testing
@testable import ZenCODECore

/// Deterministic gate for testing the refresh-tick drain. `wait()` suspends
/// the caller until `release()` is invoked, allowing tests to control exactly
/// when an in-flight tick resumes.
private actor TickGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var stopCompleted = false

    func wait() async {
        entered = true
        await withCheckedContinuation { c in
            continuation = c
        }
    }

    func hasEntered() -> Bool { entered }
    func isStopCompleted() -> Bool { stopCompleted }
    func markStopCompleted() { stopCompleted = true }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

extension TerminalChatRenderingTests {
    @Test
    func statusBarSynchronizesFromCurrentRunnerAccessMode() async throws {
        let runner = AgentCoreSessionRunner()
        #expect(await runner.toggleLocalExecAccessMode() == .fullAccess)
        let terminal = try makeTerminalForToolInterleavingTest(sessionRunner: runner)

        await terminal.synchronizeLocalExecAccessModeStatusBar()

        let accessMode = await terminal.statusBar.state.localExecAccessMode
        #expect(accessMode == .fullAccess)
    }

    @Test
    func statusBarRejectsStaleInputPanelSnapshots() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        await statusBar.updateInputPanel(
            text: "latest",
            cursorIndex: 6,
            modeText: "Prompt",
            helpText: "Help",
            revision: 2
        )
        await statusBar.updateInputPanel(
            text: "stale",
            cursorIndex: 5,
            modeText: "Prompt",
            helpText: "Help",
            revision: 1
        )

        #expect(await statusBar.state.inputPanelState?.text == "latest")

        await statusBar.clearInputPanel(revision: 3)
        await statusBar.updateInputPanel(
            text: "stale after clear",
            cursorIndex: 17,
            modeText: "Prompt",
            helpText: "Help",
            revision: 2
        )
        #expect(await statusBar.state.inputPanelState == nil)
    }

    @Test
    func generationOnlyAllowsCommandsWithConcurrencySafeState() {
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/help"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/tasks"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/tasks list"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/tasks retry task-1"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/telegram"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/telegram on"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/telegram off"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/tools logs"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/TOOLS LOGS"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/tools"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/tools status"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/tools logs extra"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/open"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/changes"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/plan status"))
    }

    @Test
    func interleavedModeMessageClearsCompactToolRewriteState() async throws {
        let terminal = try makeTerminalForToolInterleavingTest()
        let toolCall = presentedToolCall(
            id: "compact-tool",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await terminal.writeToolCallStarted(toolCall)

        await terminal.writeAccessModeChangeMessage(.fullAccess)
        let snapshot = await terminal.renderCoordinator.snapshot()

        #expect(snapshot.activeToolCallID == nil)
        #expect(snapshot.activeToolRenderedRowCount == 0)
    }

    @Test
    func taskOverviewWaitsForCompactToolCompletion() async throws {
        let runner = AgentCoreSessionRunner(taskGraphStore: nil)
        let terminal = try makeTerminalForToolInterleavingTest(sessionRunner: runner)
        let orchestrator = await runner.taskOrchestrator
        _ = try await orchestrator.createGraph(
            sessionID: terminal.sessionID,
            id: "render-interleaving",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(id: "first", title: "First"),
                TaskDefinition(id: "second", title: "Second"),
            ]
        )
        let toolCall = presentedToolCall(
            id: "wait-tool",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await terminal.writeToolCallStarted(toolCall)

        await terminal.publishTaskGraphOverviewIfChanged(
            observedSessionID: terminal.sessionID
        )
        let deferredSnapshot = await terminal.renderCoordinator.snapshot()

        #expect(deferredSnapshot.lastRenderedTaskGraphOverviewSignature == nil)
        #expect(deferredSnapshot.activeToolCallID == toolCall.id)
        #expect(deferredSnapshot.activeToolRenderedRowCount > 0)
        #expect(deferredSnapshot.deferredTaskGraphOverviewRender)
        #expect(!(await terminal.shouldPublishDeferredTaskGraphOverview()))

        await terminal.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )
        #expect(await terminal.shouldPublishDeferredTaskGraphOverview())
        await terminal.publishTaskGraphOverviewIfChanged(
            observedSessionID: terminal.sessionID
        )
        let renderedSnapshot = await terminal.renderCoordinator.snapshot()

        #expect(renderedSnapshot.activeToolCallID == nil)
        #expect(renderedSnapshot.activeToolRenderedRowCount == 0)
        #expect(renderedSnapshot.lastRenderedTaskGraphOverviewSignature != nil)
        #expect(!renderedSnapshot.deferredTaskGraphOverviewRender)
    }

    @Test
    func subAgentOverviewDeferredDuringNonAgentToolBlock() async throws {
        let terminal = try makeTerminalForToolInterleavingTest(
            sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil)
        )
        let toolCall = presentedToolCall(
            id: "exec-tool",
            name: "local.exec",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await terminal.writeToolCallStarted(toolCall)

        await terminal.renderSubAgentOverview(
            ChatSubAgentOverview(snapshots: []),
            origin: .automatic,
            publication: await terminal.reserveSubAgentOverviewPublication(),
            force: true
        )
        let deferredSnapshot = await terminal.renderCoordinator.snapshot()

        // The overview stays deferred because a non-agent tool block must not
        // be interleaved — its in-place rewrite (clearOwnedToolRows) would be
        // corrupted by the interleaved output.
        #expect(deferredSnapshot.lastRenderedSubAgentOverviewSignature == nil)
        #expect(deferredSnapshot.activeToolCallID == toolCall.id)
        #expect(deferredSnapshot.activeToolRenderedRowCount > 0)

        await terminal.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )
        await terminal.renderSubAgentOverview(
            ChatSubAgentOverview(snapshots: []),
            origin: .automatic,
            publication: await terminal.reserveSubAgentOverviewPublication(),
            force: true
        )
        let renderedSnapshot = await terminal.renderCoordinator.snapshot()

        #expect(renderedSnapshot.activeToolCallID == nil)
        #expect(renderedSnapshot.activeToolRenderedRowCount == 0)
        #expect(renderedSnapshot.lastRenderedSubAgentOverviewSignature != nil)
    }

    @Test
    func subAgentOverviewRendersDuringAgentToolBlock() async throws {
        let terminal = try makeTerminalForToolInterleavingTest(
            sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil)
        )
        let toolCall = presentedToolCall(
            id: "wait-tool",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await terminal.writeToolCallStarted(toolCall)

        await terminal.renderSubAgentOverview(
            ChatSubAgentOverview(snapshots: []),
            origin: .automatic,
            publication: await terminal.reserveSubAgentOverviewPublication(),
            force: true
        )
        let renderedSnapshot = await terminal.renderCoordinator.snapshot()

        // The overview is rendered immediately (not deferred) because the
        // active tool block belongs to an agent.* tool call — its in-place
        // presentation is closed first so progress stays visible during the
        // blocking wait.
        #expect(renderedSnapshot.lastRenderedSubAgentOverviewSignature != nil)
        #expect(renderedSnapshot.activeToolCallID == nil)

        // Completion still works correctly: the coordinator sees
        // activeToolBlock == nil and writes the final block without an
        // in-place rewrite.
        await terminal.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )
        let completedSnapshot = await terminal.renderCoordinator.snapshot()

        #expect(completedSnapshot.activeToolCallID == nil)
        #expect(completedSnapshot.activeToolRenderedRowCount == 0)
    }

    /// A reservation the terminal did not take is presented as one without a
    /// reservation: the slot's presenter forwards the reservation and the
    /// presentation to the channel that drives the slot at each moment, so a
    /// switch in between can hand the terminal one that Telegram took
    /// (Telegram's revisions are never positive). The overview is rendered as
    /// it comes and moves no revision: an older reservation of the
    /// terminal's own is still dropped, a later one is still rendered.
    @Test
    func subAgentOverviewWithAForeignReservationRendersAsItComes() async throws {
        let terminal = try makeTerminalForToolInterleavingTest(
            sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil)
        )
        func overview(_ count: Int) -> ChatSubAgentOverview {
            ChatSubAgentOverview(snapshots: (1 ... count).map {
                TelegramTurnActivityFixtures.subAgent(id: "agent-\($0)", status: .running)
            })
        }
        func renderedSignature() async -> String? {
            await terminal.renderCoordinator.snapshot().lastRenderedSubAgentOverviewSignature
        }
        let older = await terminal.reserveSubAgentOverviewPublication()
        let newer = await terminal.reserveSubAgentOverviewPublication()
        await terminal.renderSubAgentOverview(overview(1), origin: .automatic, publication: newer)
        let ownSignature = try #require(await renderedSignature())

        await terminal.renderSubAgentOverview(
            overview(2), origin: .automatic, publication: ChatOverviewPublication(revision: Int.min + 1)
        )
        let foreignSignature = try #require(await renderedSignature())
        #expect(foreignSignature != ownSignature)

        await terminal.renderSubAgentOverview(overview(3), origin: .automatic, publication: older)
        #expect(await renderedSignature() == foreignSignature)

        let latest = await terminal.reserveSubAgentOverviewPublication()
        #expect(latest.revision > newer.revision)
        await terminal.renderSubAgentOverview(overview(4), origin: .automatic, publication: latest)
        let latestSignature = await renderedSignature()
        #expect(latestSignature != foreignSignature)
        #expect(latestSignature != nil)
    }

    @Test
    func subAgentOverviewRefreshTaskLifecycle() async throws {
        let terminal = try makeTerminalForToolInterleavingTest()

        // No refresh running initially.
        #expect(terminal.chatSession.subAgentOverviewRefreshTask == nil)

        // Start refresh (simulating .toolCallStarted for agent.wait).
        terminal.startSubAgentOverviewRefreshIfNeeded()
        #expect(terminal.chatSession.subAgentOverviewRefreshTask != nil)

        // Idempotent: a second start must not replace or cancel the running
        // task (guard prevents creating a duplicate).
        terminal.startSubAgentOverviewRefreshIfNeeded()
        #expect(terminal.chatSession.subAgentOverviewRefreshTask != nil)

        // Stop refresh (simulating .toolCallCompleted).
        await terminal.stopSubAgentOverviewRefresh()
        #expect(terminal.chatSession.subAgentOverviewRefreshTask == nil)

        // Idempotent: stopping when already stopped is a safe no-op.
        await terminal.stopSubAgentOverviewRefresh()
        #expect(terminal.chatSession.subAgentOverviewRefreshTask == nil)
    }

    @Test
    func subAgentOverviewRefreshDrainsInFlightTickBeforeReturning() async throws {
        let terminal = try makeTerminalForToolInterleavingTest()
        terminal.chatSession.subAgentOverviewRefresher.interval = .milliseconds(1)

        // A gate that suspends the first tick inside the hook, deterministically
        // simulating an in-flight tick (suspended in subAgentSnapshots or the
        // coordinator actor) without relying on sleep timing.
        let gate = TickGate()
        terminal.chatSession.subAgentOverviewRefresher.onTick = { await gate.wait() }

        // Start the refresh. The first tick fires after ~1ms and suspends
        // inside gate.wait().
        terminal.startSubAgentOverviewRefreshIfNeeded()

        // Poll until the tick has entered the hook — it is now in-flight.
        while await !gate.hasEntered() {
            try await Task.sleep(for: .milliseconds(2))
        }

        // Start stop() in the background.
        let stopTask = Task {
            await terminal.stopSubAgentOverviewRefresh()
            await gate.markStopCompleted()
        }

        // Brief yield to let stop() reach its drain point (await task.value).
        // The tick is deterministically blocked in gate.wait(), so this sleep
        // only covers cooperative-pool scheduling latency, not timing.
        try await Task.sleep(for: .milliseconds(5))

        // stop() must NOT have completed yet: it is blocked draining the tick.
        // With the old implementation (bare cancel, no await task.value) stop()
        // would have completed immediately — this assertion would fail.
        #expect(await !gate.isStopCompleted())

        // Release the tick. The drain completes, stop() proceeds to its final
        // render, and the stop task finishes.
        await gate.release()
        await stopTask.value
        #expect(await gate.isStopCompleted())
        #expect(terminal.chatSession.subAgentOverviewRefreshTask == nil)
    }

    private func makeTerminalForToolInterleavingTest(
        sessionRunner: AgentCoreSessionRunner? = nil
    ) throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-tool-rendering", isDirectory: true)
        )
        return TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: sessionRunner,
            telegramTransportFactory: nil
        )
    }
}
