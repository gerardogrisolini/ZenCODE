//
//  TerminalStatusBarRenderingTests.swift
//  ZenCODE
//
//  Tests for the status bar render cache and cursor-hide optimisation.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Thread-safe buffer that captures all text written to the injected output sink.
private final class CapturedOutput: Sendable {
    private let items = Mutex<[String]>([])

    func append(_ text: String) {
        items.withLock { $0.append(text) }
    }

    var writes: [String] {
        items.withLock { $0 }
    }

    var combined: String {
        writes.joined()
    }

    var count: Int {
        items.withLock { $0.count }
    }

    func clear() {
        items.withLock { $0.removeAll() }
    }
}

@Suite struct TerminalStatusBarRenderingTests {

    // MARK: - Border appearance

    @Test
    func standaloneStatusBarUsesRoundedBorderCorners() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        await bar.renderStatusOverlay()

        let frame = captured.combined
        #expect(frame.contains("╭"))
        #expect(frame.contains("╮"))
        #expect(frame.contains("╰"))
        #expect(frame.contains("╯"))
        #expect(frame.contains("\(TerminalStyle.Text.secondary)test-model\(TerminalStyle.reset)"))
        #expect(!frame.contains("┌"))
        #expect(!frame.contains("┐"))
        #expect(!frame.contains("└"))
        #expect(!frame.contains("┘"))
    }

    @Test
    func inputPanelUsesRoundedTopBorderCorners() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        await bar.updateInputPanel(
            text: "Prompt",
            cursorIndex: 6,
            modeText: "Prompt",
            helpText: "Enter to send"
        )

        let frame = captured.combined
        #expect(frame.contains("╭"))
        #expect(frame.contains("╮"))
        #expect(frame.contains("╰"))
        #expect(frame.contains("╯"))
        #expect(!frame.contains("┌"))
        #expect(!frame.contains("┐"))
        #expect(!frame.contains("└"))
        #expect(!frame.contains("┘"))
    }

    @Test
    func scrollableOutputCapacityExcludesTheActiveOverlayRows() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        // A standalone status bar reserves its three frame rows.
        #expect(await bar.scrollableOutputRowCapacity() == 21)

        await bar.updateInputPanel(
            text: "Prompt",
            cursorIndex: 6,
            modeText: "Prompt",
            helpText: "Enter to send"
        )

        // The attached input panel adds its three chrome rows, one input row,
        // and the two status rows: 24 - (3 + 1 + 2) = 18.
        #expect(await bar.scrollableOutputRowCapacity() == 18)
    }

    @Test
    func liveSubAgentsWaitChatAndInputShareOneBottomLayout() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")
        await bar.updateInputPanel(
            text: "Prompt",
            cursorIndex: 6,
            modeText: "Prompt",
            helpText: "Enter to send"
        )
        _ = await bar.setSubAgentActivity(
            text: "Sub-Agents\n   1 total\n   ▸ worker",
            revision: 1
        )
        _ = await bar.setPendingTool(id: "wait-1", name: "agent.wait", text: "agent.wait ⏳ worker")
        await bar.setSharedChatReader(
            entries: [],
            unreadCount: 0,
            isExpanded: true
        )

        captured.clear()
        await bar.renderOverlay()
        let frame = TerminalANSIText.stripANSI(captured.combined)
        #expect(frame.contains("Sub-Agents"))
        #expect(frame.contains("agent.wait ⏳ worker"))
        #expect(frame.contains("Chat · 0 messages"))
        #expect(frame.contains("Prompt"))
        #expect((await bar.scrollableOutputRowCapacity() ?? 0) >= TerminalStatusBar.minimumScrollableRows)
    }

    @Test
    func pendingToolRemovalIsIdentitySafeAcrossResize() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 18, columns: 80, modelID: "test-model")
        _ = await bar.setPendingTool(id: "older", name: "local.exec", text: "local.exec ⏳ older")
        _ = await bar.setPendingTool(id: "newer", name: "agent.wait", text: "agent.wait ⏳ newer")

        await bar.removePendingTool(id: "older")
        await bar.configureForTesting(row: 12, columns: 60, modelID: "test-model")
        captured.clear()
        await bar.renderOverlay()

        let frame = TerminalANSIText.stripANSI(captured.combined)
        #expect(!frame.contains("local.exec ⏳ older"))
        #expect(frame.contains("agent.wait ⏳ newer"))
        #expect(await bar.state.liveActivity.pendingToolOrder == ["newer"])
    }

    @Test
    func allPendingToolsShareOverlayAndConcurrentCompletionUsesCallIdentity() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 18, columns: 80)
        _ = await bar.setPendingTool(id: "search", name: "search.grep", text: "search.grep ⏳ needle")
        _ = await bar.setPendingTool(id: "edit", name: "local.editFile", text: "local.editFile ⏳ File.swift")

        await bar.removePendingTool(id: "search")
        captured.clear()
        await bar.renderOverlay()

        let frame = TerminalANSIText.stripANSI(captured.combined)
        #expect(!frame.contains("search.grep ⏳ needle"))
        #expect(frame.contains("local.editFile ⏳ File.swift"))
        #expect(await bar.state.liveActivity.pendingToolOrder == ["edit"])
    }

    @Test
    func standaloneOverlayReservesLiveRowsAndPromotesWaitWhenConstrained() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 6, columns: 80)
        _ = await bar.setPendingTool(id: "first", name: "local.exec", text: "local.exec ⏳ first")
        _ = await bar.setPendingTool(id: "wait", name: "agent.wait", text: "agent.wait ⏳ workers")

        captured.clear()
        await bar.renderOverlay()
        let frame = TerminalANSIText.stripANSI(captured.combined)

        #expect(await bar.reservedRowsForOverlay() == 4)
        #expect(frame.contains("agent.wait ⏳ workers"))
        #expect(!frame.contains("local.exec ⏳ first"))
    }

    @Test
    func fiveRowStandaloneStatusUsesWaitBadgeWithoutTakingTranscriptRows() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 5, columns: 80, modelID: "test-model")
        _ = await bar.setPendingTool(id: "other", name: "local.exec", text: "local.exec ⏳ other")
        _ = await bar.setPendingTool(id: "wait", name: "agent.wait", text: "agent.wait ⏳ workers")

        captured.clear()
        await bar.renderOverlay()
        let frame = TerminalANSIText.stripANSI(captured.combined)

        #expect(await bar.reservedRowsForOverlay() == 3)
        #expect(await bar.scrollableOutputRowCapacity() == 2)
        #expect(frame.contains("agent.wait ⏳ workers"))
        #expect(!frame.contains("local.exec ⏳ other"))
    }

    @Test
    func scheduledResizeDefersPendingToolPhysicalWritesUntilCommit() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 18, columns: 80)

        await bar.scheduleTerminalResize()
        captured.clear()
        _ = await bar.setPendingTool(id: "remove", name: "local.exec", text: "local.exec ⏳ remove")
        _ = await bar.setPendingTool(id: "keep", name: "agent.wait", text: "agent.wait ⏳ keep")
        await bar.removePendingTool(id: "remove")

        #expect(captured.combined.isEmpty)
        #expect(await bar.state.liveActivity.pendingToolOrder == ["keep"])

        // Deterministically model the debounced geometry commit: the next full
        // render must compose the latest logical state, not the removed tool.
        await bar.configureForTesting(row: 12, columns: 60, isResizePending: false)
        await bar.renderOverlay()
        let frame = TerminalANSIText.stripANSI(captured.combined)
        #expect(frame.contains("agent.wait ⏳ keep"))
        #expect(!frame.contains("local.exec ⏳ remove"))
        await bar.stop()
    }

    @Test
    func lifecycleCleanupClearsToolsAndSubAgents() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 18, columns: 80)
        _ = await bar.setPendingTool(id: "tool", name: "local.exec", text: "local.exec ⏳")
        _ = await bar.setSubAgentActivity(text: "Sub-Agents\n   worker", revision: 1)

        await bar.setProcessing(true)
        await bar.setProcessing(false)

        #expect(await bar.state.liveActivity.lines.isEmpty)
        #expect(await bar.scrollableOutputRowCapacity() == 15)
    }

    @Test
    func resetAndStopCannotRetainLiveActivity() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 18, columns: 80)
        _ = await bar.setPendingTool(id: "reset-tool", name: "local.exec", text: "local.exec ⏳")
        _ = await bar.setSubAgentActivity(text: "Sub-Agents\n   current", revision: 5)

        // Revision 6 represents a snapshot reserved before the reset and
        // completing afterward. Cleanup retains its floor but revokes publishability.
        await bar.reserveSubAgentActivity(revision: 6)
        await bar.reset()
        #expect(await bar.state.liveActivity.lines.isEmpty)
        let resetSnapshotHandled = await bar.setSubAgentActivity(
            text: "Sub-Agents\n   stale-after-reset",
            revision: 6
        )
        #expect(resetSnapshotHandled)
        #expect(await bar.state.liveActivity.lines.isEmpty)

        _ = await bar.setPendingTool(id: "stop-tool", name: "search.grep", text: "search.grep ⏳")
        _ = await bar.setSubAgentActivity(text: "Sub-Agents\n   stop-worker", revision: 7)
        await bar.reserveSubAgentActivity(revision: 8)
        await bar.stop()
        #expect(await bar.state.liveActivity.lines.isEmpty)
        let stoppedSnapshotHandled = await bar.setSubAgentActivity(
            text: "Sub-Agents\n   stale-after-stop",
            revision: 8
        )
        #expect(stoppedSnapshotHandled)
        #expect(await bar.state.liveActivity.lines.isEmpty)

        // Restarting the visual owner cannot lower the acceptance floor.
        await bar.configureForTesting(row: 18, columns: 80)
        let restartedSnapshotHandled = await bar.setSubAgentActivity(
            text: "Sub-Agents\n   stale-after-restart",
            revision: 8
        )
        #expect(restartedSnapshotHandled)
        #expect(await bar.state.liveActivity.lines.isEmpty)
    }

    @Test
    func staleSubAgentRevisionCannotReplaceNewerLiveRows() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 16, columns: 80)
        _ = await bar.setSubAgentActivity(text: "Sub-Agents\n   newest", revision: 2)

        let stillPresentedLive = await bar.setSubAgentActivity(
            text: "Sub-Agents\n   stale",
            revision: 1
        )
        captured.clear()
        await bar.renderOverlay()

        let frame = TerminalANSIText.stripANSI(captured.combined)
        #expect(stillPresentedLive)
        #expect(frame.contains("newest"))
        #expect(!frame.contains("stale"))
    }

    // MARK: - Render cache

    @Test
    func identicalStatusRendersAreSuppressedByCache() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        // First status-only render: cache is empty → writes.
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // Second identical render: cache hit → suppressed.
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // A third call is still suppressed.
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)
    }

    @Test
    func changedStatusContentTriggersWrite() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "model-a")

        // Prime the cache.
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // Change model to produce a different visible status.
        await bar.configureForTesting(row: 24, columns: 100, modelID: "model-b")

        await bar.renderStatusOverlay()
        #expect(captured.count == 2) // different content → writes
    }

    @Test
    func changedGeometryTriggersWriteEvenWithSameText() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "same-model")

        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // Different geometry → different positioning codes in the sequence.
        await bar.configureForTesting(row: 40, columns: 120, modelID: "same-model")

        await bar.renderStatusOverlay()
        #expect(captured.count == 2)
    }

    // MARK: - Cache invalidation

    @Test
    func fullRenderUpdatesStatusCache() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        // Prime the status cache with a status-only render.
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // A full render (input panel + status) writes and updates the cache.
        await bar.renderOverlay()
        #expect(captured.count == 2)

        // Subsequent status-only render is a cache hit → suppressed.
        await bar.renderStatusOverlay()
        #expect(captured.count == 2)
    }

    @Test
    func stopClearsStatusRenderCache() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        // Prime and verify cache is populated.
        await bar.renderStatusOverlay()
        #expect(await bar.state.lastStatusRender != nil)

        await bar.stop()

        // stop() must clear the cache so the next render is not suppressed.
        #expect(await bar.state.lastStatusRender == nil)
    }

    // MARK: - Cursor-hide placement

    @Test
    func statusOnlyRenderOmitsCursorHide() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        await bar.renderStatusOverlay()

        // ESC[?25l (cursor hide) must NOT appear in status-only updates.
        let cursorHide = "\u{1B}[?25l"
        #expect(!captured.combined.contains(cursorHide))
    }

    @Test
    func fullRenderEmitsCursorHide() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        await bar.renderOverlay()

        // ESC[?25l (cursor hide) MUST appear in full renders.
        let cursorHide = "\u{1B}[?25l"
        #expect(captured.combined.contains(cursorHide))
    }

    @Test
    func startEmitsCursorHide() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }

        let started = await bar.start()
        #expect(started)

        // start() emits cursor-hide explicitly before the first full render.
        let cursorHide = "\u{1B}[?25l"
        #expect(captured.combined.contains(cursorHide))

        await bar.stop()
    }

    @Test
    func ordinaryStatusUpdateViaPublicAPIOmitsCursorHide() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }

        _ = await bar.start()
        await bar.stop()

        // Re-configure without signal-handler side effects.
        await bar.configureForTesting(row: 24, columns: 100, modelID: "first-model")

        captured.clear()
        // update(modelID:) triggers renderStatusLocked internally.
        _ = await bar.update(modelID: "second-model")

        let cursorHide = "\u{1B}[?25l"
        #expect(!captured.combined.contains(cursorHide))
    }

    // MARK: - Spinner animation

    @Test
    func spinnerTicksContinueToWriteDespiteCache() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(
            row: 24,
            columns: 100,
            modelID: "test-model",
            isProcessing: true
        )

        // First status render includes spinner frame index 0.
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // Each spinner tick advances the frame → different status text →
        // cache miss → write. This guarantees animation is not frozen.
        await bar.advanceSpinner(generation: 0)
        #expect(captured.count == 2)

        await bar.advanceSpinner(generation: 0)
        #expect(captured.count == 3)
    }

    @Test
    func identicalMetricUpdateIsSuppressedByCache() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        // Prime the cache with a status-only render.
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // An identical status-only render is suppressed (no visible change).
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // A full render updates the cache; the subsequent identical status
        // render is still suppressed.
        await bar.renderOverlay()
        let countAfterFullRender = captured.count
        #expect(countAfterFullRender == 2)

        await bar.renderStatusOverlay()
        #expect(captured.count == countAfterFullRender)
    }
}
