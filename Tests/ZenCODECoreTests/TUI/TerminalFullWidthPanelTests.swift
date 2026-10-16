// TerminalFullWidthPanelTests.swift
import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite(TerminalBlockingTestScope())
struct TerminalFullWidthPanelTests {
    private func entry(text: String) -> TerminalSharedChatReaderEntry {
        .init(id: UUID(), route: "Worker [18:05:09] → Coordinator", text: text)
    }

    private func expectFullWidthFooter(
        _ capture: PrimaryScreenCapture,
        bar: TerminalStatusBar,
        columns: Int
    ) async {
        let reserved = await bar.reservedRowsForOverlay()
        let footer = capture.terminal.withLock { Array($0.viewport.suffix(reserved)) }
        #expect(!footer.isEmpty)
        #expect(footer.allSatisfy { row in
            ["╭", "│", "├", "╰"].contains(row.cells.first ?? "")
                && ["╮", "│", "┤", "╯"].contains(row.cells.last ?? "")
                && TerminalANSIText.visibleWidth(row.text) == columns
                && !row.softWrapped
        })
        let rows = capture.terminal.withLock { $0.rows }
        #expect(capture.terminal.withLock { $0.cursorReport } == "\u{1B}[\(rows - reserved + 1);1R")
    }

    @Test(arguments: [20, 40, 80, 160], [false, true])
    func promptAndChatUseTheLastCellWithoutChangingPadding(columns: Int, expanded: Bool) async {
        let capture = PrimaryScreenCapture(rows: 32, columns: columns)
        let bar = TerminalStatusBar(isEnabled: true, cursorReports: capture.reports, outputSink: capture.write)
        await bar.configureForTesting(row: 32, columns: columns, modelID: "test-model")
        await bar.updateInputPanel(
            text: "界🙂e\u{301}", cursorIndex: 3, modeText: "Prompt", helpText: "Enter",
            suggestionLines: [String(repeating: "界🙂e\u{301} ", count: columns)],
        )
        await bar.setSharedChatReader(
            entries: [entry(text: String(repeating: "界🙂e\u{301} ", count: columns))],
            unreadCount: 1, isExpanded: expanded,
        )
        await expectFullWidthFooter(capture, bar: bar, columns: columns)
        #expect(capture.visible.contains("│ > 界🙂e\u{301}▌"))
        #expect(capture.visible.contains("╭─ Chat"))
        // The first allocation may scroll blank rows, but repainting owned
        // chrome must neither scroll again nor turn a border into a wrap row.
        let originalHistory = capture.history
        let originalViewport = capture.visible
        for _ in 0..<3 {
            await bar.renderOverlay()
            await bar.renderStatusOverlay()
            await expectFullWidthFooter(capture, bar: bar, columns: columns)
            #expect(capture.history == originalHistory)
            #expect(capture.visible == originalViewport)
        }
        #expect(capture.bytes.contains("\u{1B}[?7l"))
        #expect(capture.bytes.contains("\u{1B}[?7h"))
        await bar.stop()
    }

    @Test(arguments: [20, 40, 80, 160])
    func cursorAtTheNewContentBoundaryDoesNotAddAPhysicalRow(columns: Int) async {
        let capture = PrimaryScreenCapture(rows: 32, columns: columns)
        let bar = TerminalStatusBar(isEnabled: true, cursorReports: capture.reports, outputSink: capture.write)
        await bar.configureForTesting(row: 32, columns: columns)
        // Four cells of border/padding, two of prompt prefix and one of cursor.
        // This fills the new content budget exactly, including wide/combining
        // graphemes; the old columns-1 contract requires a second editor row.
        let text = String(repeating: "a", count: columns - 12) + "界🙂e\u{301}"
        for cursor in [0, text.count - 1, text.count] {
            await bar.updateInputPanel(text: text, cursorIndex: cursor, modeText: "Prompt", helpText: "Enter")
            var state = await bar.state
            #expect(await bar.inputPanelDisplayLineCountLocked(state: &state, text: text, cursorIndex: cursor) == 1)
            #expect(await bar.reservedRowsForOverlay() == 6)
            #expect(capture.visible.filter { $0 == "▌" }.count == 1)
            await expectFullWidthFooter(capture, bar: bar, columns: columns)
        }
        await bar.updateInputPanel(text: text + "x", cursorIndex: text.count + 1, modeText: "Prompt", helpText: "Enter")
        #expect(await bar.reservedRowsForOverlay() == 7)
        await expectFullWidthFooter(capture, bar: bar, columns: columns)
        // Shrinking the editor must erase the old final-column cells as well.
        await bar.updateInputPanel(text: "", cursorIndex: 0, modeText: "Prompt", helpText: "Enter")
        #expect(await bar.reservedRowsForOverlay() == 6)
        #expect(!capture.visible.contains("界"))
        #expect(capture.visible.filter { $0 == "▌" }.count == 1)
        await expectFullWidthFooter(capture, bar: bar, columns: columns)
        await bar.stop()
    }

    @Test(arguments: [40, 80, 160])
    func fullWidthRepaintRestoresTranscriptDelayedWrap(columns: Int) async {
        let capture = PrimaryScreenCapture(rows: 24, columns: columns)
        let bar = TerminalStatusBar(isEnabled: true, cursorReports: capture.reports, outputSink: capture.write)
        await bar.configureForTesting(row: 24, columns: columns)
        await bar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "Prompt", helpText: "Enter")
        let screen = await bar.primaryScreen
        screen.append(String(repeating: "a", count: columns))
        await bar.renderOverlay() // CUP and border painting clear pending wrap.
        screen.append("Z")
        let transcript = capture.terminal.withLock { terminal in
            terminal.history + Array(terminal.viewport.dropLast(6))
        }
        #expect(transcript.contains { $0.text == String(repeating: "a", count: columns) && $0.softWrapped })
        #expect(transcript.contains { $0.text == "Z" })
        await expectFullWidthFooter(capture, bar: bar, columns: columns)
        await bar.stop()
    }

    @Test
    func resizeRebuildsTheLastColumnForPromptAndChatWithoutReplayingTranscript() async throws {
        let capture = PrimaryScreenCapture(rows: 32, columns: 100)
        let bar = TerminalStatusBar(
            isEnabled: true, cursorReports: capture.reports,
            resizeGeneration: { capture.generation.withLock { $0 } }, outputSink: capture.write,
        )
        await bar.configureForTesting(row: 32, columns: 100, modelID: "test-model")
        let draft = String(repeating: "界🙂e\u{301}", count: 15)
        await bar.updateInputPanel(text: draft, cursorIndex: draft.count, modeText: "Prompt", helpText: "Enter")
        await bar.setSharedChatReader(
            entries: [entry(text: String(repeating: "Chat body 界🙂e\u{301} ", count: 30))],
            unreadCount: 1, isExpanded: true,
        )
        let screen = await bar.primaryScreen
        screen.append("TRANSCRIPT_ONCE|\n")
        for columns in [40, 160, 40, 100] {
            capture.resize(rows: 32, columns: columns)
            let beforeResize = capture.bytes.count
            await bar.handleTerminalResizeForTesting(rows: 32, columns: columns)
            #expect(String(capture.bytes.dropFirst(beforeResize)) == "\u{1B}[6n")
            try await capture.answerReport()
            #expect(!screen.isAppendOnly)
            #expect(await bar.state.inputPanelState?.text == draft)
            await expectFullWidthFooter(capture, bar: bar, columns: columns)
            let history = capture.history
            await bar.renderOverlay()
            #expect(capture.history == history)
        }
        let all = capture.history + "\n" + capture.visible
        #expect(all.components(separatedBy: "TRANSCRIPT_ONCE|").count == 2)
        #expect(!capture.history.contains("Chat body"))
        #expect(!capture.bytes.contains("\u{1B}[2J"))
        await bar.stop()
    }
}
