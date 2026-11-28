//
//  TerminalStatusBarHiddenFooterTests.swift
//  ZenCODE
//
//  The bottom layout hidden behind a `/subagent` or `/artifacts` panel: it
//  reserves no row and draws nothing while every update still lands in the
//  state, and it comes back whole, for the geometry of that moment, a resize
//  meanwhile included.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite(TerminalBlockingTestScope(), .timeLimit(.minutes(1)))
struct TerminalStatusBarHiddenFooterTests {
    /// A started status bar writing into a terminal model as large as the
    /// geometry the bar measures at its start, with a draft in its input
    /// panel and a model in its status.
    private func startedBar() async throws -> (bar: TerminalStatusBar, capture: PrimaryScreenCapture) {
        let measured = TerminalStatusBar.currentTerminalGeometry(fileDescriptor: 1) ?? (rows: 24, columns: 100)
        let capture = PrimaryScreenCapture(rows: measured.rows, columns: measured.columns)
        let bar = TerminalStatusBar(
            isEnabled: true,
            cursorReports: capture.reports,
            resizeGeneration: { capture.generation.withLock { $0 } },
            outputSink: { capture.write($0) }
        )
        try #require(await bar.start())
        await bar.update(modelID: "model-one")
        await bar.updateInputPanel(text: "draft-text", cursorIndex: 10, modeText: "mode-text", helpText: "help-text")
        try #require(capture.visible.contains("draft-text"))
        return (bar, capture)
    }

    private func entry(_ number: Int) -> TerminalSharedChatReaderEntry {
        TerminalSharedChatReaderEntry(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
            route: "Agent \(number) → Coordinator",
            text: "shared message \(number)"
        )
    }

    private func writeCount(_ capture: PrimaryScreenCapture) -> Int {
        capture.writes.withLock { $0.count }
    }

    /// The bottom row of the terminal model.
    private func bottomRow(_ capture: PrimaryScreenCapture) -> String {
        capture.terminal.withLock { $0.viewport.last?.text ?? "" }
    }

    /// Hidden, the layout reserves no row and its rows leave the screen;
    /// the draft, the status, the dock, the spinner and git still update the
    /// state without a byte written, and showing the layout again draws it
    /// whole from that state, after which status-only renders draw again.
    @Test
    func theHiddenLayoutDrawsNothingWhileItsStateFollowsAndComesBackWhole() async throws {
        let (bar, capture) = try await startedBar()
        let rows = await bar.state.row
        let visibleReservedRows = await bar.reservedRowsForOverlay()
        #expect(visibleReservedRows > 0)
        #expect(await bar.scrollableOutputRowCapacity() == rows - visibleReservedRows)

        await bar.setFooterHidden(true)
        #expect(await bar.state.isFooterHidden)
        #expect(await bar.reservedRowsForOverlay() == 0)
        // The primary screen keeps its last row out of the scrolling region.
        #expect(await bar.scrollableOutputRowCapacity() == rows - 1)
        // The empty footer was committed: nothing of the layout is left.
        #expect(!capture.visible.contains("draft-text"))
        #expect(!capture.visible.contains("model-one"))
        #expect(!capture.visible.contains("╰"))
        #expect(await bar.state.lastStatusRender == nil)

        let writes = writeCount(capture)
        let observation = UUID()
        await bar.updateInputPanel(
            text: "draft-two", cursorIndex: 9, modeText: "mode-text", helpText: "help-text",
            suggestionLines: ["/subagent", "/artifacts"]
        )
        await bar.update(agentName: "Agent-Hidden")
        await bar.update(modelID: "model-two")
        await bar.update(gitStatusSummary: TerminalGitStatusSummary(changedFileCount: 3, additions: 4, deletions: 5))
        await bar.update(localExecAccessMode: .fullAccess)
        await bar.setSharedChatReader(entries: [entry(1)], unreadCount: 1, isExpanded: false, observationID: observation)
        // No expanded reader is committed where nothing of it can be seen.
        #expect(!(await bar.expandSharedChatReader(entries: [entry(1)], unreadCount: 1, observationID: observation)))
        await bar.setProcessing(true)
        let spinnerGeneration = await bar.state.spinnerGeneration
        for _ in 0..<3 {
            await bar.advanceSpinner(generation: spinnerGeneration)
        }
        // The spinner's own ticks, every 120 ms, write nothing either.
        try await Task.sleep(for: .milliseconds(400))
        #expect(writeCount(capture) == writes)

        #expect(await bar.state.inputPanelState?.text == "draft-two")
        #expect(await bar.state.latestAgentName == "Agent-Hidden")
        #expect(await bar.state.latestModelID == "model-two")
        #expect(await bar.state.latestGitStatusSummary?.additions == 4)
        #expect(await bar.state.sharedChatReaderDock?.unreadCount == 1)
        #expect(await bar.state.sharedChatReaderDock?.isExpanded == false)
        #expect(await bar.state.isProcessing)
        #expect(await bar.state.lastStatusRender == nil)

        await bar.setFooterHidden(false)
        #expect(!(await bar.state.isFooterHidden))
        #expect(writeCount(capture) > writes)
        #expect(await bar.reservedRowsForOverlay() > visibleReservedRows)
        let visible = capture.visible
        #expect(visible.contains("draft-two"))
        #expect(!visible.contains("draft-text"))
        #expect(visible.contains("/artifacts"))
        #expect(visible.contains("Chat · 1 message · 1 new"))
        #expect(visible.contains("Agent-Hidden"))
        #expect(visible.contains("model-two"))
        #expect(visible.contains("3 files +4 -5"))
        #expect(bottomRow(capture).hasPrefix("╰"))
        #expect(await bar.state.lastStatusRender != nil)

        // Status-only renders draw again: a spinner tick repaints the status.
        let shown = writeCount(capture)
        await bar.advanceSpinner(generation: await bar.state.spinnerGeneration)
        #expect(writeCount(capture) > shown)

        await bar.setProcessing(false)
        await bar.stop()
    }

    /// Hiding and showing are idempotent: a second hide commits nothing more,
    /// a second show draws nothing more.
    @Test
    func hidingOrShowingTwiceWritesOnce() async throws {
        let (bar, capture) = try await startedBar()
        await bar.setFooterHidden(true)
        let hidden = writeCount(capture)
        await bar.setFooterHidden(true)
        #expect(writeCount(capture) == hidden)

        await bar.setFooterHidden(false)
        let shown = writeCount(capture)
        #expect(shown > hidden)
        await bar.setFooterHidden(false)
        #expect(writeCount(capture) == shown)
        await bar.stop()
    }

    /// A resize while the layout is hidden commits only the new geometry
    /// (the panel drawn over the screen needs it) without drawing anything
    /// of the layout; showing the layout again draws it for that geometry.
    @Test
    func aResizeWhileHiddenIsDrawnWhenTheLayoutComesBack() async throws {
        let (bar, capture) = try await startedBar()
        let columns = await bar.state.columns
        let rows = await bar.state.row
        let resizedRows = rows == 30 ? 31 : 30
        await bar.setFooterHidden(true)
        let writes = writeCount(capture)

        capture.resize(rows: resizedRows, columns: columns)
        await bar.handleTerminalResize(
            generation: await bar.state.resizeGeneration,
            geometry: (rows: resizedRows, columns: columns)
        )
        // Only the cursor query of the new geometry was written.
        #expect(capture.writes.withLock { Array($0.dropFirst(writes)) }.joined() == "\u{1B}[6n")
        try await capture.answerReport()
        #expect(await bar.state.row == resizedRows)
        #expect(await bar.reservedRowsForOverlay() == 0)
        #expect(!capture.visible.contains("draft-text"))
        #expect(!capture.visible.contains("╰"))

        // A later render of the hidden layout writes nothing.
        let afterResize = writeCount(capture)
        await bar.updateInputPanel(text: "draft-resized", cursorIndex: 13, modeText: "mode-text", helpText: "help-text")
        #expect(writeCount(capture) == afterResize)

        await bar.setFooterHidden(false)
        #expect(capture.visible.contains("draft-resized"))
        #expect(capture.visible.contains("model-one"))
        #expect(capture.terminal.withLock { $0.viewport.count } == resizedRows)
        #expect(bottomRow(capture).hasPrefix("╰"))
        #expect(await bar.scrollableOutputRowCapacity() == resizedRows - (await bar.reservedRowsForOverlay()))
        await bar.stop()
    }

    /// An expanded reader that a resize while hidden left without a payload
    /// row collapses when the layout comes back, keeping its messages, and
    /// the collapse is notified as a visible resize would notify it; without
    /// a resize it stays expanded.
    @Test
    func showingTheLayoutAfterAResizeCollapsesAnExpandedReaderThatNoLongerFits() async throws {
        let (bar, capture) = try await startedBar()
        let columns = await bar.state.columns
        let observation = UUID()
        let collapsed = CollapsedObservations()
        await bar.setSharedChatReaderCollapseHandler { id in collapsed.ids.withLock { $0.append(id) } }
        #expect(await bar.expandSharedChatReader(entries: [entry(1)], unreadCount: 0, observationID: observation))

        // Hidden and shown without a resize, the reader stays as it was.
        await bar.setFooterHidden(true)
        await bar.setFooterHidden(false)
        #expect(await bar.state.sharedChatReaderDock?.isExpanded == true)
        #expect(collapsed.ids.withLock { $0 }.isEmpty)

        // The smallest geometry with an input panel has no row for its payload.
        await bar.setFooterHidden(true)
        capture.resize(rows: 8, columns: columns)
        await bar.handleTerminalResize(generation: await bar.state.resizeGeneration, geometry: (rows: 8, columns: columns))
        try await capture.answerReport()
        // Nothing of the reader is on screen: it waits for the layout.
        #expect(await bar.state.sharedChatReaderDock?.isExpanded == true)
        #expect(collapsed.ids.withLock { $0 }.isEmpty)

        await bar.setFooterHidden(false)
        #expect(await bar.state.sharedChatReaderDock?.isExpanded == false)
        #expect(await bar.state.sharedChatReaderDock?.entries == [entry(1)])
        #expect(collapsed.ids.withLock { $0 } == [observation])
        #expect(capture.visible.contains("draft-text"))
        await bar.stop()
    }
}

/// The observations whose reader a collapse handler was told about.
private final class CollapsedObservations: Sendable {
    let ids = Mutex<[UUID?]>([])
}
