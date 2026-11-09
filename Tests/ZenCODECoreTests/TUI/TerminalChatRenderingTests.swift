//
//  TerminalChatRenderingTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 29/05/26.
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

@ChatSessionActor
@Suite
struct TerminalChatRenderingTests {

    @Test
    func chatLineInsetIsAppliedOnlyAtLineStarts() {
        var isAtLineStart = true
        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "ciao\nmondo",
                prefix: " ",
                isAtLineStart: &isAtLineStart
            ) == " ciao\n mondo"
        )
        #expect(isAtLineStart == false)

        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "!",
                prefix: " ",
                isAtLineStart: &isAtLineStart
            ) == "!"
        )
        #expect(isAtLineStart == false)

        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "\nOK",
                prefix: " ",
                isAtLineStart: &isAtLineStart
            ) == "\n OK"
        )
    }

    @Test
    func chatSpacingNormalizationLimitsVisibleBlankRowsAcrossWrites() {
        var trailingNewlineCount = 0

        let first = TerminalChatTextFormatting.chatSpacingNormalized(
            "Thinking\n\n",
            trailingNewlineCount: &trailingNewlineCount
        )
        let second = TerminalChatTextFormatting.chatSpacingNormalized(
            "\n🛠️  Read\n\n\nNext",
            trailingNewlineCount: &trailingNewlineCount
        )

        #expect(first == "Thinking\n\n")
        #expect(second == "🛠️  Read\n\nNext")
        #expect(!("\(first)\(second)".contains("\n\n\n")))
        #expect(trailingNewlineCount == 0)
    }

    @Test
    func chatSpacingTreatsCRLFAsOneBoundaryAndCapsBlankRows() {
        var state = TerminalChatTextFormatting.ChatSpacingState()

        let first = TerminalChatTextFormatting.chatSpacingNormalized(
            "Thinking\r\n\r\n",
            state: &state
        )
        let overflow = TerminalChatTextFormatting.chatSpacingNormalized(
            "\r\nNext",
            state: &state
        )

        #expect(first == "Thinking\r\n\r\n")
        #expect(overflow == "Next")
        #expect(!("\(first)\(overflow)".contains("\r\n\r\n\r\n")))
        #expect(state.trailingNewlineCount == 0)
    }

    @Test
    func chatLineInsetRecognizesCRLFAcrossStreamingDeltas() {
        var state = TerminalChatTextFormatting.ChatLineInsetState(
            isAtLineStart: false
        )

        let first = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "before\r",
            prefix: " ",
            state: &state
        )
        let second = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\nafter",
            prefix: " ",
            state: &state
        )

        #expect(first == "before\r")
        #expect(second == "\n after")
        #expect(!state.isAtLineStart)
    }

    @Test
    func chatLineInsetDoesNotStartARowForATrailingEscapeSequence() {
        var state = TerminalChatTextFormatting.ChatLineInsetState()

        // The thought renderer emits its SGR reset after the closing blank
        // line: the reset is zero-width and must not consume the margin.
        let thoughtTail = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\n\n\u{1B}[0m",
            prefix: " ",
            state: &state
        )
        #expect(thoughtTail == "\n\n\u{1B}[0m")
        #expect(state.isAtLineStart)

        let next = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "👥 Sub-Agents:\n",
            prefix: " ",
            state: &state
        )
        #expect(next == " 👥 Sub-Agents:\n")
        #expect(state.isAtLineStart)

        // A sequence followed by a line boundary is emitted without margin.
        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "\u{1B}[0m\n\u{1B}[2K\r\u{1B}[0m\r\nok",
                prefix: " ",
                state: &state
            ) == "\u{1B}[0m\n\u{1B}[2K\r\u{1B}[0m\r\n ok"
        )
        #expect(!state.isAtLineStart)

        // A sequence between the CR and the LF of one boundary keeps its order,
        // within one delta and across two.
        state = TerminalChatTextFormatting.ChatLineInsetState()
        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "\r\u{1B}[0m\nok",
                prefix: " ",
                state: &state
            ) == "\r\u{1B}[0m\n ok"
        )
        state = TerminalChatTextFormatting.ChatLineInsetState()
        let carriageReturn = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\r",
            prefix: " ",
            state: &state
        )
        let lineFeed = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\u{1B}[0m\nok",
            prefix: " ",
            state: &state
        )
        #expect(carriageReturn + lineFeed == "\r\u{1B}[0m\n ok")
        #expect(!state.isAtLineStart)

        // Mid-row sequences pass through unchanged.
        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "\u{1B}[0m!\n",
                prefix: " ",
                state: &state
            ) == "\u{1B}[0m!\n"
        )
        #expect(state.isAtLineStart)
    }

    @Test
    func chatLineInsetKeepsTheMarginOutsideAnEscapeSequenceSplitAcrossDeltas() {
        var state = TerminalChatTextFormatting.ChatLineInsetState()

        let first = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\u{1B}[38;5",
            prefix: " ",
            state: &state
        )
        #expect(first == "\u{1B}[38;5")
        #expect(state.isAtLineStart)

        let second = TerminalChatTextFormatting.chatLineInsetApplied(
            to: ";208mX",
            prefix: " ",
            state: &state
        )
        let combined = first + second
        // The continuation bytes are not visible, and the margin follows the
        // completed sequence instead of being inserted inside the CSI.
        #expect(second == ";208m X")
        #expect(combined == "\u{1B}[38;5;208m X")
        #expect(!combined.contains("\u{1B}[38;5 "))
        #expect(TerminalANSIText.stripANSI(combined) == " X")
        #expect(!state.isAtLineStart)

        // A lone ESC at the end of a delta selects the marker in the next one.
        var escapeState = TerminalChatTextFormatting.ChatLineInsetState()
        let escape = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\u{1B}",
            prefix: " ",
            state: &escapeState
        )
        let continuation = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "[1mY",
            prefix: " ",
            state: &escapeState
        )
        #expect(escape == "\u{1B}")
        #expect(continuation == "[1m Y")
        #expect(!escapeState.isAtLineStart)
    }

    @Test
    func chatLineInsetTreatsOperatingSystemCommandsAsZeroWidth() {
        let openLink = "\u{1B}]8;;https://example.com\u{1B}\\"
        let closeLink = "\u{1B}]8;;\u{1B}\\"
        var state = TerminalChatTextFormatting.ChatLineInsetState()

        // A hyperlink row keeps the margin outside the OSC 8 sequence.
        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "\(openLink)link\(closeLink)\n",
                prefix: " ",
                state: &state
            ) == " \(openLink)link\(closeLink)\n"
        )
        #expect(state.isAtLineStart)

        // OSC sequences alone, terminated by ST or BEL, never start a row.
        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "\(closeLink)\u{1B}]0;title\u{07}",
                prefix: " ",
                state: &state
            ) == "\(closeLink)\u{1B}]0;title\u{07}"
        )
        #expect(state.isAtLineStart)

        // The ST of an OSC may be split between deltas.
        let unterminated = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\u{1B}]8;;https://example.com\u{1B}",
            prefix: " ",
            state: &state
        )
        let terminated = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\\link",
            prefix: " ",
            state: &state
        )
        #expect(unterminated == "\u{1B}]8;;https://example.com\u{1B}")
        #expect(terminated == "\\ link")
        #expect(!state.isAtLineStart)
    }

    @Test
    func toolOutputSpacingLeavesABlankRowAfterUnterminatedAssistantContent() {
        var trailingNewlineCount = 0
        TerminalChatTextFormatting.updateTrailingNewlineCount(
            afterPreserving: "Risposta del modello.",
            trailingNewlineCount: &trailingNewlineCount
        )

        let separator = TerminalChatTextFormatting.chatSpacingNormalized(
            "\n\n",
            trailingNewlineCount: &trailingNewlineCount
        )

        #expect("Risposta del modello.\(separator)🛠️ tool" == "Risposta del modello.\n\n🛠️ tool")
        #expect(trailingNewlineCount == 2)
    }

    @Test
    func boldSectionBreakSeparatesGluedSectionTitleAcrossDeltas() {
        var state = TerminalChatBoldBreakState()

        let chunks = ["Fixed it incorrectly.", "*", "*Identifying bugs** done"]
        var rendered = chunks
            .map { TerminalChatTextFormatting.normalizedBoldSectionBreak($0, state: &state) }
            .joined()
        rendered += TerminalChatTextFormatting.flushBoldSectionBreak(state: &state)

        #expect(rendered == "Fixed it incorrectly.\n**Identifying bugs** done")
    }

    @Test
    func boldSectionBreakLeavesPlainBoldAndOrderedListsIntact() {
        var state = TerminalChatBoldBreakState()

        let plainBold = TerminalChatTextFormatting.normalizedBoldSectionBreak(
            "Use **bold** here",
            state: &state
        ) + TerminalChatTextFormatting.flushBoldSectionBreak(state: &state)
        #expect(plainBold == "Use **bold** here")

        var listState = TerminalChatBoldBreakState()
        let orderedList = TerminalChatTextFormatting.normalizedBoldSectionBreak(
            "1. First. 2. Second",
            state: &listState
        ) + TerminalChatTextFormatting.flushBoldSectionBreak(state: &listState)
        #expect(orderedList == "1. First. 2. Second")
    }

    @Test
    func thoughtNormalizationDoesNotAddBulletsAcrossDeltas() {
        var state = TerminalChatBoldBreakState()
        let chunks = [" Analizzo il bug.", " Verifico i test", ".", " Scrivo la fix"]
        let rendered = chunks
            .map { TerminalChatTextFormatting.normalizedBoldSectionBreak($0, state: &state) }
            .joined()

        #expect(rendered == " Analizzo il bug. Verifico i test. Scrivo la fix")
        #expect(!rendered.contains("•"))
    }

    @Test
    func markdownFormatterCompactsLooseListBlankLines() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )
        let rendered = formatter.consume("1. Primo\n\n2. Secondo\n") + formatter.finish()

        #expect(rendered.contains("Primo"))
        #expect(rendered.contains("Secondo"))
        #expect(!rendered.contains("\n\n"))
    }

    @Test
    func thinkingFormatterRemovesUnbalancedStrongMarkers() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )

        let rendered = formatter.consume("a. **renderListItem handles indentation.\n\n ** If it fails, keep the words.\n")

        #expect(!rendered.contains("**"))
        #expect(rendered.contains("renderListItem handles indentation."))
        #expect(rendered.contains("If it fails, keep the words."))
    }

    @Test
    func thinkingFormatterHidesGPTReasoningSummaryComments() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )

        let rendered = formatter.consume("""
        Improving activePlan whitespace handling

        <!--
        """) + formatter.consume("""
         -->**Planning improved plan approval messaging**

        <!-- -->**Adding plan recording status flag**
        """) + formatter.finish()

        #expect(!rendered.contains("<!-- -->"))
        #expect(rendered.contains("\u{1B}[1mPlanning improved plan approval messaging\u{1B}[0m"))
        #expect(rendered.contains("\u{1B}[1mAdding plan recording status flag\u{1B}[0m"))
    }

    @Test
    func truncatedInlineCountsWideGraphemesInsteadOfDisplayColumns() {
        // `😀` and `界` are each two terminal cells, but each consumes one
        // count-based truncation unit. A width-aware core would return `...`.
        #expect(TerminalChat.truncatedInline("😀界abc", limit: 4) == "😀...")
    }

    @Test
    func truncatedByCountHandlesBudgetsNoLargerThanItsEllipsis() {
        // The count-based family must never pass a negative length to `prefix`.
        // It omits the marker when its three graphemes cannot fit in the budget.
        #expect(InlineTextTruncation.truncatedByCount("abcdef", limit: 3) == "...")
        #expect(InlineTextTruncation.truncatedByCount("abcdef", limit: 2) == "ab")
        #expect(InlineTextTruncation.truncatedByCount("abcdef", limit: 1) == "a")
        #expect(InlineTextTruncation.truncatedByCount("abcdef", limit: 0).isEmpty)
        #expect(InlineTextTruncation.truncatedByCount("abcdef", limit: -1).isEmpty)
    }

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
        #expect(terminal.subAgentOverviewRefreshTask == nil)

        // Start refresh (simulating .toolCallStarted for agent.wait).
        terminal.startSubAgentOverviewRefreshIfNeeded()
        #expect(terminal.subAgentOverviewRefreshTask != nil)

        // Idempotent: a second start must not replace or cancel the running
        // task (guard prevents creating a duplicate).
        terminal.startSubAgentOverviewRefreshIfNeeded()
        #expect(terminal.subAgentOverviewRefreshTask != nil)

        // Stop refresh (simulating .toolCallCompleted).
        await terminal.stopSubAgentOverviewRefresh()
        #expect(terminal.subAgentOverviewRefreshTask == nil)

        // Idempotent: stopping when already stopped is a safe no-op.
        await terminal.stopSubAgentOverviewRefresh()
        #expect(terminal.subAgentOverviewRefreshTask == nil)
    }

    @Test
    func subAgentOverviewRefreshDrainsInFlightTickBeforeReturning() async throws {
        let terminal = try makeTerminalForToolInterleavingTest()
        terminal.subAgentOverviewRefreshInterval = .milliseconds(1)

        // A gate that suspends the first tick inside the hook, deterministically
        // simulating an in-flight tick (suspended in subAgentSnapshots or the
        // coordinator actor) without relying on sleep timing.
        let gate = TickGate()
        terminal.onSubAgentOverviewTick = { await gate.wait() }

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
        #expect(terminal.subAgentOverviewRefreshTask == nil)
    }

    @Test
    func statusBarRejectsStaleGitRefreshResults() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        let staleGeneration = await statusBar.beginGitStatusRefresh()
        let currentGeneration = await statusBar.beginGitStatusRefresh()
        let stale = TerminalGitStatusSummary(
            changedFileCount: 1,
            additions: 1,
            deletions: 0
        )
        let current = TerminalGitStatusSummary(
            changedFileCount: 2,
            additions: 4,
            deletions: 1
        )

        _ = await statusBar.update(
            gitStatusSummary: current,
            refreshGeneration: currentGeneration
        )
        _ = await statusBar.update(
            gitStatusSummary: stale,
            refreshGeneration: staleGeneration
        )
        #expect(await statusBar.state.latestGitStatusSummary == current)
    }

    @Test
    func completedSubAgentFileMutationRequestsGitStatusRefresh() {
        let mutation = DirectAgentToolCall(
            id: "mutation",
            name: "local.editFile",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        let read = DirectAgentToolCall(
            id: "read",
            name: "local.readFile",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        let result = DirectAgentToolResult(output: "Updated", summary: "Updated")

        #expect(!TerminalChat.shouldRefreshGitStatus(for: DirectSubAgentToolEvent(
            agentID: "worker",
            agentName: "worker",
            toolCall: mutation,
            lifecycle: .started
        )))
        #expect(TerminalChat.shouldRefreshGitStatus(for: DirectSubAgentToolEvent(
            agentID: "worker",
            agentName: "worker",
            toolCall: mutation,
            lifecycle: .completed(result)
        )))
        #expect(!TerminalChat.shouldRefreshGitStatus(for: DirectSubAgentToolEvent(
            agentID: "worker",
            agentName: "worker",
            toolCall: read,
            lifecycle: .completed(result)
        )))
    }

    @Test
    func statusBarRendersSubscriptionPrefillAndGenerationTokenCounts() {
        let metrics = ChatGPTSubscriptionGenerationClient
            .chatGPTSubscriptionVisibleMetrics(
                DirectAgentGenerationMetrics(
                    promptTokenCount: 120,
                    cachedPromptTokenCount: 800,
                    completionTokenCount: 32,
                )
            )

        #expect(
            TerminalStatusBar.generationTokenCountsFragment(metrics) == "c:800 p:120 g:32"
        )
    }

    @Test
    func statusBarKeepsLatestAnalyticsAfterCompletionAndCancellation() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        let metrics = DirectAgentGenerationMetrics(
            promptTokenCount: 120,
            cachedPromptTokenCount: 800,
            completionTokenCount: 32,
            responseDurationSeconds: 4
        )
        let contextWindow = DirectAgentContextWindowStatus(
            usedTokens: 952,
            maxTokens: 10_000,
            modelID: "test-model",
            isApproximate: true
        )

        await statusBar.beginRequest()
        await statusBar.setProcessing(true)
        _ = await statusBar.update(metrics: metrics)
        _ = await statusBar.update(contextWindow: contextWindow)
        await statusBar.setProcessing(false)

        var state = await statusBar.state
        #expect(state.latestMetrics?.promptTokenCount == 120)
        #expect(state.latestMetrics?.completionTokenCount == 32)
        #expect(state.latestMetrics?.responseDurationSeconds == 4)
        #expect(state.latestContextWindow?.usedTokens == 952)
        #expect(state.latestContextWindow?.maxTokens == 10_000)

        await statusBar.beginRequest()
        await statusBar.setProcessing(true)
        // Esc stops the request without requiring another metrics update.
        await statusBar.setProcessing(false)

        state = await statusBar.state
        #expect(state.latestMetrics?.promptTokenCount == 120)
        #expect(state.latestMetrics?.completionTokenCount == 32)
        #expect(state.latestMetrics?.responseDurationSeconds == 4)
        #expect(state.latestContextWindow?.usedTokens == 952)
        #expect(state.latestContextWindow?.maxTokens == 10_000)
    }

    @Test
    func statusBarFirstMetricsOfNewRequestReplacePreviousAnalytics() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: 120,
                cachedPromptTokenCount: 800,
                completionTokenCount: 32,
                responseDurationSeconds: 4
            )
        )

        await statusBar.beginRequest()

        #expect(await statusBar.state.latestMetrics?.promptTokenCount == 120)
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: nil,
                completionTokenCount: 5,
            )
        )

        let state = await statusBar.state
        #expect(state.latestMetrics?.promptTokenCount == nil)
        #expect(state.latestMetrics?.cachedPromptTokenCount == nil)
        #expect(state.latestMetrics?.completionTokenCount == 5)
        #expect(state.latestMetrics?.responseDurationSeconds == nil)
    }

    // MARK: - DS4 throughput label

    @Test
    func throughputFragmentShowsPrefillProgressWithAndWithoutRate() {
        func metrics(
            processed: Int,
            target: Int,
            rate: Double?
        ) -> DirectAgentGenerationMetrics {
            DirectAgentGenerationMetrics(
                promptTokenCount: nil,
                completionTokenCount: nil,
                throughput: DirectAgentGenerationThroughput(
                    phase: .prefill,
                    prefillTokensPerSecond: rate,
                    processedTokens: processed,
                    targetTokens: target
                )
            )
        }

        #expect(
            TerminalStatusBar.generationThroughputFragment(
                metrics(processed: 1_200, target: 8_000, rate: 512)
            ) == "p:1.2k/8.0k 512.0 tok/s"
        )
        #expect(
            TerminalStatusBar.generationThroughputFragment(
                metrics(processed: 0, target: 8_000, rate: nil)
            ) == "p:0/8.0k"
        )
        #expect(
            TerminalStatusBar.generationThroughputFragment(
                metrics(processed: 800, target: 25_000, rate: 64.26)
            ) == "p:800/25k 64.3 tok/s"
        )
        // An unusable rate is dropped, the progress stays.
        #expect(
            TerminalStatusBar.generationThroughputFragment(
                metrics(processed: 10, target: 100, rate: .infinity)
            ) == "p:10/100"
        )
        #expect(
            TerminalStatusBar.generationThroughputFragment(
                metrics(processed: 10, target: 100, rate: -3)
            ) == "p:10/100"
        )
    }

    @Test
    func statusBarLiveThroughputKeepsPreviousCountersUntilTheFinalSnapshot() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        let previousThroughput = DirectAgentGenerationThroughput(phase: .generation, generationTokensPerSecond: 30)
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: 120,
                cachedPromptTokenCount: 800,
                completionTokenCount: 32,
                responseDurationSeconds: 4,
                contextTokenCount: 952,
                clearsPromptMetrics: true,
                replacesPreviousMetrics: true,
                throughput: previousThroughput
            )
        )

        await statusBar.beginRequest()
        let prefill = DirectAgentGenerationThroughput(
            phase: .prefill, processedTokens: 0, targetTokens: 8_000
        )
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: nil,
                completionTokenCount: nil,
                throughput: prefill,
                isLiveProgress: true
            )
        )

        // The live event neither wipes the previous counters nor uses up the
        // replacement reserved for the first metrics event of the request.
        var state = await statusBar.state
        #expect(state.shouldReplaceMetricsOnNextUpdate)
        #expect(state.latestMetrics?.promptTokenCount == 120)
        #expect(state.latestMetrics?.cachedPromptTokenCount == 800)
        #expect(state.latestMetrics?.completionTokenCount == 32)
        #expect(state.latestMetrics?.responseDurationSeconds == 4)
        #expect(state.latestMetrics?.throughput == prefill)

        let generation = DirectAgentGenerationThroughput(phase: .generation, generationTokensPerSecond: 41.2)
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: nil,
                completionTokenCount: nil,
                throughput: generation,
                isLiveProgress: true
            )
        )
        state = await statusBar.state
        #expect(state.shouldReplaceMetricsOnNextUpdate)
        #expect(state.latestMetrics?.promptTokenCount == 120)
        #expect(state.latestMetrics?.throughput == generation)

        // The round's final snapshot replaces the counters and the throughput.
        let finalThroughput = DirectAgentGenerationThroughput(
            phase: .generation, prefillTokensPerSecond: 512, generationTokensPerSecond: 39.9
        )
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: 5_000,
                cachedPromptTokenCount: 4_000,
                completionTokenCount: 77,
                responseDurationSeconds: 9,
                contextTokenCount: 9_077,
                clearsPromptMetrics: true,
                replacesPreviousMetrics: true,
                throughput: finalThroughput
            )
        )
        state = await statusBar.state
        #expect(!state.shouldReplaceMetricsOnNextUpdate)
        #expect(state.latestMetrics?.promptTokenCount == 5_000)
        #expect(state.latestMetrics?.cachedPromptTokenCount == 4_000)
        #expect(state.latestMetrics?.completionTokenCount == 77)
        #expect(state.latestMetrics?.responseDurationSeconds == 9)
        #expect(state.latestMetrics?.throughput == finalThroughput)
        #expect(state.latestMetrics?.isLiveProgress == false)
    }

    @Test
    func statusBarFinalSnapshotWithoutThroughputClearsTheLabel() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: nil,
                completionTokenCount: nil,
                throughput: DirectAgentGenerationThroughput(phase: .generation, generationTokensPerSecond: 41.2),
                isLiveProgress: true
            )
        )
        #expect(await statusBar.state.latestMetrics?.throughput != nil)

        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: 10,
                completionTokenCount: 5,
                clearsPromptMetrics: true,
                replacesPreviousMetrics: true
            )
        )

        #expect(await statusBar.state.latestMetrics?.throughput == nil)
    }

    @Test
    func gitNumstatSummaryCountsFilesAdditionsAndDeletions() {
        let output = """
        10	2	Sources/App.swift
        -	-	Assets/Icon.png
        1	0	Tests/AppTests.swift
        """

        #expect(
            TerminalChat.gitNumstatSummary(from: output) == TerminalGitStatusSummary(
                changedFileCount: 3,
                additions: 11,
                deletions: 2
            )
        )
    }

    @Test
    func markdownFormatterStylesHeadingsAndInlineCode() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            palette: .dark
        )

        let rendered = formatter.consume("## Titolo con `codice`\n")

        #expect(rendered.contains("\u{1B}[1;38;5;75mTitolo con"))
        #expect(!TerminalANSIText.stripANSI(rendered).contains("##"))
        #expect(rendered.contains("\u{1B}[48;5;236m\u{1B}[38;5;180mcodice\u{1B}[0m"))
        #expect(rendered.hasSuffix("\n"))
    }

    @Test
    func markdownFormatterStreamsLongPlainLinesWithoutParsing() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)
        let plain = String(repeating: "a", count: 241)

        #expect(formatter.consume(plain) == plain)
        #expect(formatter.finish() == "")
    }

    @Test
    func markdownFormatterKeepsPotentialMarkdownBufferedUntilNewline() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            palette: .dark
        )
        let partial = "## " + String(repeating: "a", count: 241)

        #expect(formatter.consume(partial) == "")
        #expect(formatter.consume("\n").contains("\u{1B}[1;38;5;75m"))
    }

    @Test
    func markdownFormatterDoesNotBufferInlinePipelineAsTableCandidate() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)

        let rendered = formatter.consume("Use `cat file | grep foo | sort` now.\n")

        #expect(!rendered.isEmpty)
        #expect(rendered.contains("cat file"))
        #expect(formatter.finish() == "")
    }

    @Test
    func markdownFormatterRendersPipeTableAfterDelimiter() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)

        let header = formatter.consume("| A | B |\n")
        let rendered = formatter.consume("| --- | --- |\n| 1 | 2 |\n") + formatter.finish()

        #expect(header == "")
        #expect(rendered.contains("┌"))
        #expect(rendered.contains("A"))
        #expect(rendered.contains("1"))
    }

    @Test
    func markdownFormatterFlushesLongListsDuringStreaming() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)
        let list = (1...81)
            .map { "- item \($0)" }
            .joined(separator: "\n") + "\n"

        let rendered = formatter.consume(list)

        #expect(!rendered.isEmpty)
        #expect(rendered.contains("item 1"))
        #expect(rendered.contains("item 80"))
    }

    @Test
    func markdownFormatterRendersFencedCodeBlockWithSyntaxHighlighting() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            palette: .dark
        )

        let rendered = formatter.consume("```swift\nlet x = 1\n```\n") + formatter.finish()

        // Fences become a readable header and never leak raw Markdown.
        #expect(rendered.contains("Code · Swift"))
        #expect(!rendered.contains("```"))
        // Body is routed through the code renderer: `let` is a keyword.
        #expect(rendered.contains("\u{1B}[38;5;141mlet\u{1B}[0m"))
        #expect(rendered.contains("x = "))
    }

    @Test
    func markdownFormatterDoesNotParseMarkdownInsideCodeFence() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        let rendered = formatter.consume("```\n- not a list\n**not bold**\n```\n")
            + formatter.finish()

        // Content inside the fence keeps its literal markers instead of being
        // converted to a bullet or bold run.
        #expect(rendered.contains("- not a list"))
        #expect(rendered.contains("**not bold**"))
        #expect(!rendered.contains("•"))
    }

    @Test
    func markdownFormatterDoesNotWrapTableBoxDrawing() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 12,
            supportsHyperlinks: false
        )

        _ = formatter.consume("| Column A | Column B |\n")
        let rendered = formatter.consume("| --- | --- |\n| value 1 | value 2 |\n")
            + formatter.finish()

        // Box-drawing rows are emitted intact even though they exceed the narrow
        // render width; wrapping them would corrupt the table layout.
        #expect(rendered.contains("┌"))
        #expect(rendered.contains("│"))
        let boxRows = rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains("│") || $0.contains("─") }
        #expect(!boxRows.isEmpty)
        // Every box-drawing row exceeds the render width, proving the
        // structured-surface renderer left the table untouched instead of
        // breaking it across lines.
        #expect(boxRows.allSatisfy { TerminalANSIText.visibleWidth($0) > 12 })
    }

    @Test
    func markdownFormatterRendersMultiLineBlockQuote() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        let rendered = formatter.consume("> first line\n> second line\n")
            + formatter.finish()

        // Blockquote lines stream incrementally (one rendered as the next
        // arrives), yet produce the same visual result as a single block.
        #expect(rendered.contains("first line"))
        #expect(rendered.contains("second line"))
        // Literal blockquote markers are consumed by the renderer.
        #expect(!rendered.contains("> first line"))
    }

    @Test
    func markdownFormatterStreamsListItemByItem() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // The first item is complete as soon as the second top-level marker
        // arrives, so it is rendered before finish() is ever called.
        let streamed = formatter.consume("- alpha\n- beta\n")
        #expect(streamed.contains("alpha"))
        #expect(streamed.contains("•"))
        // The last item stays buffered until the stream ends.
        #expect(!streamed.contains("beta"))

        let tail = formatter.finish()
        #expect(tail.contains("beta"))
    }

    @Test
    func markdownFormatterStreamsLazyOrderedListWithAscendingNumbers() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // The common lazy "1./1./1." convention must render as 1./2./3. even
        // though each item is flushed as a standalone document while streaming.
        let streamed = formatter.consume("1. alpha\n1. beta\n1. gamma\n") + formatter.finish()
        let plain = TerminalANSIText.stripANSI(streamed)

        #expect(plain.contains("1. alpha"))
        #expect(plain.contains("2. beta"))
        #expect(plain.contains("3. gamma"))
        // The lazy source markers must not leak through unchanged.
        #expect(!plain.contains("1. beta"))
        #expect(!plain.contains("1. gamma"))
    }

    @Test
    func markdownFormatterStreamsNestedListMatchingWholeBlock() {
        var streaming = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        let source = "- top\n  - nested\n- top two\n"

        // Feed the nested list one line per delta.
        var streamed = ""
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            streamed += streaming.consume(line + "\n")
        }
        streamed += streaming.finish()

        // Independent oracle: render the whole block directly through the
        // markdown renderer, bypassing the stream formatter entirely. Using a
        // second copy of the (modified) formatter would not be independent.
        var expectedRenderer = TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: false,
            renderWidth: 79
        )
        let expected = expectedRenderer.visit(Document(parsing: source)) + "\n"

        // Streaming line by line produces the same rendering as parsing the
        // whole block at once: nested structure and indentation are preserved.
        #expect(streamed == expected)
        #expect(streamed.contains("•"))
        #expect(streamed.contains("◦"))
    }

    @Test
    func markdownFormatterStreamsBulletToOrderedTransitionRenumbered() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // A bullet item followed (with a blank line, still inside the list
        // block) by lazy "1./1." ordered items. The ordered segment must
        // restart numbering from 1 and ascend to 2, not stay "1./1.".
        let streamed = formatter.consume("- bullet\n\n1. first\n1. second\n") + formatter.finish()
        let plain = TerminalANSIText.stripANSI(streamed)

        #expect(plain.contains("1. first"))
        #expect(plain.contains("2. second"))
        #expect(!plain.contains("1. second"))
        // A blank line separates the two list-type blocks (matching the document
        // renderer) rather than concatenating them directly.
        #expect(plain.contains("\n\n1. first"))
    }

    @Test
    func markdownFormatterUnbalancedBlockQuoteFlushesWithinHardCap() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )

        // A blockquote with an opener `**` that is never closed. It must keep
        // buffering past the soft cap but eventually flush at the hard cap
        // (80 lines) instead of buffering indefinitely.
        var source = "> **unclosed bold\n"
        for line in 1...85 {
            source += "> filler line \(line)\n"
        }

        // consume() alone must produce output (the hard cap forced a flush)
        // rather than buffering everything indefinitely.
        let partial = formatter.consume(source)
        #expect(!partial.isEmpty)
        #expect(partial.contains("unclosed bold"))

        // finish() drains the remainder, so the whole quote is rendered.
        let rendered = partial + formatter.finish()
        #expect(rendered.contains("filler line 85"))
    }

    @Test
    func markdownFormatterHandlesIntMaxOrderedMarkerWithoutCrash() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // A pathological ordered marker at Int.max (19 digits) must not crash
        // the renumbering arithmetic (overflow would trap). It renders verbatim.
        let streamed = formatter.consume(
            "9223372036854775807. item\n9223372036854775807. item\n"
        ) + formatter.finish()

        // No crash: the items rendered and the huge number is preserved verbatim
        // (renumbering is skipped for out-of-range values).
        #expect(streamed.contains("9223372036854775807"))
        #expect(streamed.contains("item"))
    }

    @Test
    func markdownFormatterLeavesTenDigitOrderedMarkerVerbatimWithoutCrash() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // 10 digits exceed the markdown limit (9). Renumbering is skipped, the
        // marker renders verbatim, and no overflow crash occurs.
        let streamed = formatter.consume(
            "1000000000. item\n1000000000. item\n"
        ) + formatter.finish()
        let plain = TerminalANSIText.stripANSI(streamed)

        // Both items render verbatim with the original number.
        #expect(plain.contains("1000000000. item"))
        // No incremented number appears.
        #expect(!plain.contains("1000000001"))
    }

    @Test
    func markdownFormatterStreamsTableIntactUntilComplete() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)

        // The header stays buffered while the table is still only a candidate.
        let header = formatter.consume("| A | B |\n")
        #expect(header == "")

        let rendered = formatter.consume("| --- | --- |\n| 1 | 2 |\n") + formatter.finish()
        // Once complete, the full table (with box drawing) is rendered intact.
        #expect(rendered.contains("┌"))
        #expect(rendered.contains("A"))
        #expect(rendered.contains("1"))
    }

    @Test
    func mutedThoughtAccentMapsKnownAccentFamilies() {
        #expect(TerminalChatTextFormatting.mutedThoughtAccent(for: 75) == 109)
        #expect(TerminalChatTextFormatting.mutedThoughtAccent(for: 180) == 144)
        #expect(TerminalChatTextFormatting.mutedThoughtAccent(for: 108) == 108)
        #expect(TerminalChatTextFormatting.mutedThoughtAccent(for: 200) == nil)
    }

    @Test
    func toolAndStatusWidthsUseTerminalCellWidth() {
        #expect(TerminalTextMetrics.displayWidth("🛠️ Tool") == TerminalANSIText.visibleWidth("🛠️ Tool"))
        #expect(TerminalTextMetrics.displayWidth("e\u{301}") == 1)
        #expect(TerminalStatusBar.visibleCharacterCount("🛠️ Tool") == 7)
        #expect(TerminalStatusBar.visibleCharacterCount("你好") == 4)
    }

    @Test
    func inputPanelRowsRespectWideCharacters() {
        let rows = TerminalStatusBar.inputPanelDisplayRows(
            text: "你好世界",
            cursorIndex: 4,
            contentWidth: 6,
            maxRows: 10
        )

        #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) <= 6 })
        #expect(rows.count == 3)
    }

    @Test
    func subAgentOverviewRendersPlainWrappedStatusWithoutBoxDrawing() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_1",
            name: "swift-scan",
            role: "swift-scan",
            status: .closed,
            pending: false,
            latestOutput: "Trovati 3 file `.swift`: 1. `./Tests/ZenCODECoreTests/AgentCoreSessionRunnerTests.swift` 2. `./Tests/ZenCODECoreTests/MemoryServiceTests.swift` 3. `./Tests/ZenCODECoreTests/VeryLongFileNameThatShouldWrapInsideTheBox.swift`",
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = TerminalChat.renderSubAgentOverview([snapshot])
        let visibleLines = rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { ansiStripped(String($0)) }

        #expect(visibleLines[1] == "👥 Sub-Agents:")
        #expect(rendered.hasPrefix("\n"))
        #expect(rendered.hasSuffix("\n"))
        #expect(!rendered.contains("┌"))
        #expect(!rendered.contains("│"))
        #expect(!rendered.contains("└"))
        #expect(visibleLines.allSatisfy { $0.count <= 122 })
    }

    @Test
    func subAgentOverviewKeepsMultipleSnapshotsCompactAcrossBoundaries() {
        let now = Date(timeIntervalSince1970: 0)
        let snapshots = [
            DirectSubAgentRuntime.AgentSnapshot(
                id: "agent-first",
                name: "first-agent",
                role: "",
                status: .closed,
                pending: false,
                latestOutput: nil,
                latestError: nil,
                createdAt: now,
                updatedAt: now
            ),
            DirectSubAgentRuntime.AgentSnapshot(
                id: "agent-second",
                name: "second-agent",
                role: "",
                status: .closed,
                pending: false,
                latestOutput: nil,
                latestError: nil,
                createdAt: now,
                updatedAt: now
            ),
            DirectSubAgentRuntime.AgentSnapshot(
                id: "agent-third",
                name: "third-agent",
                role: "",
                status: .closed,
                pending: false,
                latestOutput: nil,
                latestError: nil,
                createdAt: now,
                updatedAt: now
            )
        ]

        let visibleLines = ansiStripped(TerminalChat.renderSubAgentOverview(snapshots))
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let summaryIndex = visibleLines.firstIndex { $0.contains("3 total") }
        let firstHeaderIndex = visibleLines.firstIndex { $0.contains("first-agent") }
        let firstIDIndex = visibleLines.firstIndex { $0.contains("id: agent-first") }
        let secondHeaderIndex = visibleLines.firstIndex { $0.contains("second-agent") }
        let secondIDIndex = visibleLines.firstIndex { $0.contains("id: agent-second") }
        let thirdHeaderIndex = visibleLines.firstIndex { $0.contains("third-agent") }

        let contentLines = Array(visibleLines.dropFirst().dropLast())
        #expect(contentLines.allSatisfy { !$0.isEmpty })
        #expect(summaryIndex != nil)
        #expect(firstHeaderIndex != nil)
        #expect(firstIDIndex != nil)
        #expect(secondHeaderIndex != nil)
        #expect(secondIDIndex != nil)
        #expect(thirdHeaderIndex != nil)

        if let summaryIndex, let firstHeaderIndex,
           let firstIDIndex, let secondHeaderIndex,
           let secondIDIndex, let thirdHeaderIndex {
            // Each agent block is intentionally preceded by one visually blank
            // separator line.
            #expect(firstHeaderIndex == summaryIndex + 2)
            #expect(secondHeaderIndex == firstIDIndex + 2)
            #expect(thirdHeaderIndex == secondIDIndex + 2)
        }
    }

    @Test
    func subAgentOverviewRendersModelAndCurrentActivity() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_2",
            name: "planner",
            role: "Planner",
            status: .running,
            pending: true,
            modelID: "gpt-5",
            currentActivity: "reading project files",
            currentToolName: "search.grep",
            currentToolTarget: "needle",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalChat.renderSubAgentOverview([snapshot]))

        #expect(rendered.contains("model: gpt-5"))
        #expect(rendered.contains("💬 reading project files"))
        #expect(rendered.contains("🛠️  search.grep needle"))
        #expect(!rendered.contains("activity:"))
        #expect(!rendered.contains("tool:"))
    }

    @Test
    func subAgentOverviewRendersAgentProfileLineWhenProfileNamePresent() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_profile",
            name: "builder",
            role: "Builder",
            profileID: "developer-profile",
            profileName: "Developer",
            status: .running,
            pending: true,
            modelID: "gpt-5",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalChat.renderSubAgentOverview([snapshot]))
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(rendered.contains("agent: Developer"))

        // The "agent:" line must appear after the "role:" line.
        let roleIndex = lines.firstIndex { $0.contains("role: Builder") }
        let agentIndex = lines.firstIndex { $0.contains("agent: Developer") }
        #expect(roleIndex != nil)
        #expect(agentIndex != nil)
        if let roleIndex, let agentIndex {
            #expect(agentIndex > roleIndex)
        }
    }

    @Test
    func subAgentOverviewSignatureTracksGenerationMetrics() {
        func snapshot(
            metrics: DirectAgentGenerationMetrics?
        ) -> DirectSubAgentRuntime.AgentSnapshot {
            DirectSubAgentRuntime.AgentSnapshot(
                id: "agent_signature",
                name: "planner",
                role: "Planner",
                status: .running,
                pending: true,
                modelID: "gpt-5",
                latestMetrics: metrics,
                latestOutput: nil,
                latestError: nil,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        }

        let none = ChatSubAgentOverview.signature(for: [snapshot(metrics: nil)])
        let first = ChatSubAgentOverview.signature(for: [
            snapshot(
                metrics: DirectAgentGenerationMetrics(
                    promptTokenCount: 1_200,
                    cachedPromptTokenCount: 800,
                    completionTokenCount: nil,
                )
            )
        ])
        let second = ChatSubAgentOverview.signature(for: [
            snapshot(
                metrics: DirectAgentGenerationMetrics(
                    promptTokenCount: 1_200,
                    cachedPromptTokenCount: 800,
                    completionTokenCount: 42,
                )
            )
        ])
        // Rates are not rendered, so they must not force a republish.
        let sameCounts = ChatSubAgentOverview.signature(for: [
            snapshot(
                metrics: DirectAgentGenerationMetrics(
                    promptTokenCount: 1_200,
                    cachedPromptTokenCount: 800,
                    completionTokenCount: 42,
                )
            )
        ])

        #expect(none != first)
        #expect(first != second)
        #expect(second == sameCounts)
    }

    @Test
    func subAgentOverviewResolvesFriendlyModelTitleViaResolver() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_resolved",
            name: "planner",
            role: "Planner",
            status: .running,
            pending: true,
            modelID: "gpt-5",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let resolver: (String) -> String = { id in
            id == "gpt-5" ? "GPT-5 Turbo" : id
        }
        let rendered = ansiStripped(
            TerminalChat.renderSubAgentOverview([snapshot], modelTitleResolver: resolver)
        )

        #expect(rendered.contains("model: GPT-5 Turbo"))
        #expect(!rendered.contains("model: gpt-5"))
    }

    @Test
    func subAgentOverviewKeepsConfiguredModelTitleAfterBackendReportsGenericID() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_configured_model",
            name: "developer",
            role: "Developer",
            status: .running,
            pending: true,
            configuredModelID: "binding:chatgpt:gpt-5.6-terra",
            modelID: "gpt-5.6",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let resolver: (String) -> String = { id in
            switch id {
            case "binding:chatgpt:gpt-5.6-terra": "GPT-5.6 Terra"
            case "gpt-5.6": "GPT-5.6"
            default: id
            }
        }
        let rendered = ansiStripped(
            TerminalChat.renderSubAgentOverview([snapshot], modelTitleResolver: resolver)
        )

        #expect(rendered.contains("model: GPT-5.6 Terra"))
        #expect(!rendered.contains("model: GPT-5.6\n"))
    }

    @Test
    func subAgentOverviewStripsRemoteAPIProviderKeyForUnresolvableModel() {
        let rawModelID = "zai:glm-5.2"
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_remote",
            name: "worker",
            role: "Worker",
            status: .running,
            pending: true,
            modelID: rawModelID,
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let resolver: (String) -> String = {
            TerminalChat.resolvedSubAgentModelTitle(for: $0)
        }
        let rendered = ansiStripped(
            TerminalChat.renderSubAgentOverview([snapshot], modelTitleResolver: resolver)
        )

        #expect(rendered.contains("model: glm-5.2"))
        #expect(!rendered.contains("zai:"))
    }

    @Test
    func subAgentModelNameStrippingRemoteAPIPrefixHandlesEdgeCases() {
        #expect(ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix("zai:glm-5.2") == "glm-5.2")
        #expect(ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix("gpt-5") == nil)
        // An unknown provider key must not be stripped.
        #expect(
            ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix("remoteapi:openrouter:anthropic/claude")
                == nil
        )
        // Missing model name segment.
        #expect(ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix("openrouter:") == nil)
    }

    @Test
    func subAgentOverviewShowsOnlyOneStableThinkingLabel() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_thinking",
            name: "researcher",
            role: "researcher",
            status: .running,
            pending: true,
            currentActivity: nil,
            currentActivityKind: .thinking,
            latestContentPreview: "private reasoning delta that must stay hidden",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalChat.renderSubAgentOverview([snapshot]))

        #expect(rendered.components(separatedBy: "🤔 thinking…").count - 1 == 1)
        #expect(!rendered.contains("private reasoning delta"))
        #expect(!rendered.contains("💬"))
    }

    @Test
    func subAgentOverviewUsesTheCompactToolNameAndTarget() {
        let toolCall = presentedToolCall(
            id: "grep-call",
            name: "search.grep",
            argumentsObject: ["pattern": "needle"],
            argumentsJSON: #"{"pattern":"needle"}"#
        )
        let target = ToolCallPresentation.displayToolTarget(for: toolCall)
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_tool",
            name: "researcher",
            role: "researcher",
            status: .running,
            pending: true,
            currentToolName: toolCall.name,
            currentToolTarget: target,
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalChat.renderSubAgentOverview([snapshot]))

        #expect(target == "needle")
        #expect(rendered.contains("🛠️  \(toolCall.name) needle"))
        #expect(!rendered.contains("🤔 thinking…"))
    }

    @Test
    func subAgentOverviewCondensedDensityKeepsAgentRowsWithoutSeparators() {
        let now = Date(timeIntervalSince1970: 0)
        let agentCount = 8
        let snapshots = (1...agentCount).map { index in
            DirectSubAgentRuntime.AgentSnapshot(
                id: "a\(index)",
                name: "scout-\(index)",
                role: "",
                profileID: "dev",
                profileName: "Dev",
                status: .running,
                pending: true,
                configuredModelID: "m1",
                currentToolName: "search.grep",
                currentToolTarget: "needle",
                latestOutput: nil,
                latestError: nil,
                createdAt: now,
                updatedAt: now
            )
        }

        // `render` frames the section with a leading and a trailing newline,
        // so the physical rows are the ones between them.
        func visibleRows(rowBudget: Int) -> [String] {
            ansiStripped(
                TerminalSubAgentOverviewLayout.render(
                    snapshots,
                    modelTitleResolver: { $0 },
                    includesFinalResponses: false,
                    toolPresentationsByAgentID: [:],
                    rowBudget: rowBudget
                )
            )
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst()
            .dropLast()
            .map(String.init)
        }
        func isBlank(_ row: String) -> Bool {
            row.trimmingCharacters(in: .whitespaces).isEmpty
        }

        // Title and summary, then per agent: separator + header + agent/model
        // + tool (compact), header + agent/model + tool (condensed), or
        // header + tool (dense).
        let sectionRows = 2
        let compactRows = sectionRows + agentCount * 4
        let condensedRows = sectionRows + agentCount * 3
        let denseRows = sectionRows + agentCount * 2

        // The budget fits compact: separators and agent rows are kept.
        let compact = visibleRows(rowBudget: compactRows)
        #expect(compact.count == compactRows)
        #expect(compact.filter(isBlank).count == agentCount)
        #expect(compact.filter { $0.contains("agent: Dev") }.count == agentCount)

        // One row short of compact: condensed keeps every agent row and drops
        // only the blank separators.
        let condensed = visibleRows(rowBudget: compactRows - 1)
        #expect(condensed.count == condensedRows)
        #expect(condensed.filter(isBlank).isEmpty)
        #expect(condensed.filter { $0.contains("agent: Dev") }.count == agentCount)
        for index in 0..<agentCount {
            let first = sectionRows + index * 3
            #expect(condensed[first].contains("scout-\(index + 1)"))
            #expect(condensed[first + 1].contains("agent: Dev"))
            #expect(condensed[first + 1].contains("model: m1"))
            #expect(condensed[first + 2].contains("search.grep needle"))
        }

        // One row short of condensed: only dense fits, with no agent rows.
        let dense = visibleRows(rowBudget: condensedRows - 1)
        #expect(dense.count == denseRows)
        #expect(dense.filter(isBlank).isEmpty)
        #expect(dense.filter { $0.contains("agent:") }.isEmpty)
        for index in 0..<agentCount {
            let first = sectionRows + index * 2
            #expect(dense[first].contains("scout-\(index + 1)"))
            #expect(dense[first + 1].contains("search.grep needle"))
        }
    }

    @Test
    func subAgentOverviewPrintsOnlyTheCompleteFinalContentBlock() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_final",
            name: "researcher",
            role: "researcher",
            status: .idle,
            pending: false,
            latestContentPreview: "Final answer in one complete block.",
            latestOutput: "Earlier tool commentary. Final answer in one complete block.",
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalChat.renderSubAgentOverview([snapshot]))

        #expect(rendered.contains("✅ Final answer in one complete block."))
        #expect(!rendered.contains("Earlier tool commentary"))
    }

    @Test
    func subAgentResponseIdentityTracksCompletionRatherThanMetadataUpdates() throws {
        let createdAt = Date(timeIntervalSince1970: 10)
        let firstCompletion = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-response-token",
            name: "reviewer",
            role: "reviewer",
            status: .idle,
            pending: false,
            latestOutput: "**Done**",
            latestOutputRevision: 1,
            latestError: nil,
            createdAt: createdAt,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let closedAfterCompletion = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-response-token",
            name: "reviewer",
            role: "reviewer",
            status: .closed,
            pending: false,
            latestOutput: "**Done**",
            latestOutputRevision: 1,
            latestError: nil,
            createdAt: createdAt,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let repeatedContentInNewCompletion = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-response-token",
            name: "reviewer",
            role: "reviewer",
            status: .idle,
            pending: false,
            latestOutput: "**Done**",
            latestOutputRevision: 2,
            latestError: nil,
            createdAt: createdAt,
            updatedAt: Date(timeIntervalSince1970: 40)
        )

        let first = try #require(
            TerminalSubAgentOverviewLayout.markdownResponses([firstCompletion]).first
        )
        let closed = try #require(
            TerminalSubAgentOverviewLayout.markdownResponses([closedAfterCompletion]).first
        )
        let repeated = try #require(
            TerminalSubAgentOverviewLayout.markdownResponses([repeatedContentInNewCompletion]).first
        )

        #expect(first.markdown == "**Done**")
        #expect(first.token == closed.token)
        #expect(first.token != repeated.token)
    }

    @Test
    func inlineTextCollapsesNewlinesAndCarriageReturns() {
        #expect(InlineTextTruncation.inlineText("a\nb\r\nc\rd  ") == "a b c d")
        #expect(InlineTextTruncation.inlineText("  hello world  ") == "hello world")
        #expect(InlineTextTruncation.inlineText("line1\r\nline2") == "line1 line2")
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
            sessionRunner: sessionRunner
        )
    }
}
