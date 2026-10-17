// TerminalPrimaryScreenTests.swift
import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

final class PrimaryScreenCapture: Sendable {
    let terminal: Mutex<PrimaryScreenTerminalModel>
    let writes = Mutex<[String]>([])
    let reports = TerminalCursorReport()
    let generation = Mutex<UInt64>(0)
    init(rows: Int = 24, columns: Int = 100) {
        terminal = Mutex(PrimaryScreenTerminalModel(rows: rows, columns: columns))
    }
    func write(_ text: String) {
        writes.withLock { $0.append(text) }
        terminal.withLock { $0.write(text) }
    }
    func screen() -> TerminalPrimaryScreen {
        TerminalPrimaryScreen(reports: reports, resizeGeneration: { self.generation.withLock { $0 } }, output: write)
    }
    var visible: String { terminal.withLock { $0.visibleText } }
    var history: String { terminal.withLock { $0.historyText } }
    var bytes: String { writes.withLock { $0.joined() } }
    func resize(rows: Int, columns: Int) {
        terminal.withLock { $0.resize(rows: rows, columns: columns) }
        generation.withLock { $0 &+= 1 }
    }
    func answerReport() async throws {
        let response = terminal.withLock { $0.cursorReport }
        for byte in response.utf8 { _ = reports.consume(byte) }
        try await terminalWaitForCursorReport(reports)
    }
}

@Suite(TerminalBlockingTestScope()) struct TerminalPrimaryScreenTests {
    private func footer(rows: Int, columns: Int) -> String {
        ["PROMPT| draft 界🙂", "draft second line", "DOCK| 2 unread", "STATUS| ready"].enumerated().map {
            "\u{1B}[\(rows - 3 + $0.offset);1H\u{1B}[2K" + $0.element
        }.joined()
    }
    private func install(_ screen: TerminalPrimaryScreen, rows: Int = 24, columns: Int = 100, rebuild: Bool = false) {
        screen.commitFooter(geometry: .init(rows: rows, columns: columns), reservedRows: 4,
                            sequence: footer(rows: rows, columns: columns), rebuild: rebuild)
    }

    @Test func dedicatedMenuNeverPushesChromeInsteadOfTranscriptIntoHistory() {
        let capture = PrimaryScreenCapture()
        let screen = capture.screen() // never registers a global writer
        install(screen)
        for index in 0..<25 { screen.append("line \(index)|\n") }
        let menu = screen.beginModal()
        screen.updateModal(menu, value: .init(title: "MENU_ONLY", help: ["Enter"],
            lines: [.init(text: "> [x] SELECTED", itemIndex: 7)], focusedIndex: 7))
        for index in 25..<65 { screen.append("line \(index)|\n") }
        #expect(capture.visible.contains("SELECTED"))
        #expect(!capture.history.contains("MENU_ONLY"))
        #expect(!capture.history.contains("PROMPT|"))
        #expect(!capture.history.contains("STATUS|"))
        screen.endModal(menu)
        let all = capture.history + "\n" + capture.visible
        for index in 0..<65 { #expect(all.components(separatedBy: "line \(index)|").count == 2) }
        #expect(!capture.bytes.contains("?1049"))
        #expect(!capture.bytes.contains("\u{1B}[2J"))
        #expect(!capture.bytes.contains("\u{1B}[3J"))
    }

    @Test func modalHeaderRendersInsideFrameAboveItems() throws {
        let capture = PrimaryScreenCapture()
        let screen = capture.screen()
        install(screen)
        let menu = screen.beginModal()
        screen.updateModal(menu, value: .init(title: "BINDINGS", help: ["Enter"],
            lines: [.init(text: "> (x) DONE_ITEM", itemIndex: 0)], focusedIndex: 0,
            header: ["TABLE_ROW_1", "TABLE_ROW_2"]))
        let visible = capture.visible
        let row1 = try #require(visible.range(of: "TABLE_ROW_1"))
        let row2 = try #require(visible.range(of: "TABLE_ROW_2"))
        let item = try #require(visible.range(of: "DONE_ITEM"))
        #expect(row1.lowerBound < row2.lowerBound)
        #expect(row2.lowerBound < item.lowerBound)
        screen.endModal(menu)
    }

    @Test func modalHeaderYieldsRowsToItemsWhenSpaceIsTight() {
        #expect(TerminalCheckboxMenu.visibleHeaderLines(["a", "b"], capacity: 5) == ["a", "b", ""])
        #expect(TerminalCheckboxMenu.visibleHeaderLines(["a", "b", "c", "d"], capacity: 4) == ["a", "b", "…", ""])
        #expect(TerminalCheckboxMenu.visibleHeaderLines(["a", "b"], capacity: 2) == [])
        #expect(TerminalCheckboxMenu.visibleHeaderLines(["a"], capacity: 2) == ["a", ""])
        #expect(TerminalCheckboxMenu.visibleHeaderLines([], capacity: 10) == [])

        let capture = PrimaryScreenCapture()
        let screen = capture.screen()
        install(screen)
        let menu = screen.beginModal()
        let items = (0..<14).map { (index: Int) in
            TerminalCheckboxMenu.RenderedMenuLine(text: "ITEM_\(index)", itemIndex: index)
        }
        screen.updateModal(menu, value: .init(title: "BINDINGS", help: [],
            lines: items, focusedIndex: 0,
            header: (0..<30).map { "HEADER_\($0)" }))
        let visible = capture.visible
        for index in 0..<14 { #expect(visible.contains("ITEM_\(index)")) }
        #expect(!visible.contains("HEADER_29"))
        screen.endModal(menu)
    }

    @Test func sameEndpointResizeQueriesBeforeAnyMoveAndQueuesOutput() async throws {
        let capture = PrimaryScreenCapture(), screen = capture.screen()
        install(screen)
        for index in 0..<60 { screen.append("payload-\(index)|\n") }
        capture.resize(rows: 24, columns: 45)
        capture.resize(rows: 24, columns: 100)
        let offset = capture.bytes.count
        screen.append("queued-once\n")
        install(screen, rebuild: true)
        #expect(String(capture.bytes.dropFirst(offset)) == "\u{1B}[6n")
        try await capture.answerReport()
        #expect(!screen.isAppendOnly)
        let all = capture.history + "\n" + capture.visible
        for index in 0..<60 { #expect(all.components(separatedBy: "payload-\(index)|").count == 2) }
        #expect(all.components(separatedBy: "queued-once").count == 2)
        #expect(capture.visible.components(separatedBy: "STATUS|").count == 2)
        #expect(!capture.bytes.contains("\u{1B}[2J"))
    }

    @Test func partialUnicodeAndEscapesContinueAcrossReflowWithoutLineBuffering() async throws {
        let capture = PrimaryScreenCapture(), screen = capture.screen()
        install(screen)
        screen.append("PARTIAL|" + String(repeating: "a", count: 35) + "e")
        #expect(capture.visible.contains("PARTIAL|")) // not buffered until LF
        screen.append("\u{301}👩")
        screen.append("\u{200D}💻")
        screen.append("\u{1B}[3")
        screen.append("1mRED\u{1B}[0m")
        capture.resize(rows: 24, columns: 45)
        install(screen, rows: 24, columns: 45, rebuild: true)
        screen.append("|TAIL\n")
        try await capture.answerReport()
        let all = (capture.history + capture.visible).replacingOccurrences(of: "\n", with: "")
        #expect(all.components(separatedBy: "PARTIAL|").count == 2)
        #expect(all.contains("e\u{301}👩‍💻RED|TAIL"))
        #expect(!all.contains("[31m"))
        #expect(!screen.isAppendOnly)
    }

    @Test func ownedReceiptCannotCaptureAnInterleavedDiagnostic() {
        let capture = PrimaryScreenCapture(), screen = capture.screen()
        install(screen)
        screen.append("stable\n")
        let receipt = screen.append("old A\nold B\n")
        #expect(screen.removeOwnedTail(rows: 2, expectedAnchor: receipt))
        #expect(!capture.visible.contains("old A"))
        let next = screen.append("new\n")
        screen.append("diagnostic must survive\n")
        #expect(!screen.removeOwnedTail(rows: 1, expectedAnchor: next))
        #expect(capture.visible.contains("diagnostic must survive"))
        #expect(!screen.removeOwnedTail(rows: 1, expectedAnchor: nil))
    }

    @Test func secondResizeDuringCPRFencesWithoutAnotherQuery() async throws {
        let capture = PrimaryScreenCapture(), screen = capture.screen()
        install(screen)
        capture.resize(rows: 24, columns: 45)
        install(screen, columns: 45, rebuild: true)
        capture.resize(rows: 24, columns: 100)
        install(screen, rebuild: true)
        #expect(screen.isAppendOnly)
        #expect(capture.bytes.components(separatedBy: "\u{1B}[6n").count == 2)
        try await capture.answerReport()
        install(screen, rebuild: true)
        #expect(capture.bytes.components(separatedBy: "\u{1B}[6n").count == 2)
    }

    @Test func fragmentedPasteBeforeResizeCannotAuthorizeErasure() {
        let capture = PrimaryScreenCapture(), screen = capture.screen()
        install(screen)
        let prefix = "\u{1B}[20"
        for byte in prefix.utf8 { #expect(capture.reports.consume(byte).isEmpty) }
        capture.resize(rows: 24, columns: 45)
        let offset = capture.bytes.count
        install(screen, columns: 45, rebuild: true)
        #expect(screen.isAppendOnly)
        let suffix = "0~literal \u{1B}[10;1R\u{1B}[201~"
        let input = suffix.utf8.flatMap { capture.reports.consume($0) }
        #expect(String(decoding: input, as: UTF8.self) == prefix + suffix)
        let emitted = String(capture.bytes.dropFirst(offset))
        #expect(!emitted.contains("\u{1B}[6n"))
        #expect(!emitted.contains("\u{1B}[0J"))
        #expect(!emitted.contains("\u{1B}[2J"))
        #expect(!emitted.contains("\u{1B}[3J"))
    }

    @Test func unsupportedNarrowerTallerResizeAppendsBelowCurrentPhysicalBottom() async {
        let capture = PrimaryScreenCapture(rows: 24, columns: 80)
        let bar = TerminalStatusBar(isEnabled: true, cursorReports: capture.reports,
            resizeGeneration: { capture.generation.withLock { $0 } }, outputSink: capture.write)
        await bar.configureForTesting(row: 24, columns: 80)
        let screen = await bar.primaryScreen
        for index in 0..<12 { screen.append("ROW-\(index)|" + String(repeating: "x", count: 38) + "\n") }
        capture.resize(rows: 48, columns: 20)
        let before = capture.terminal.withLock { $0.history.map(\.text) + $0.viewport.map(\.text) }
        #expect(capture.terminal.withLock { $0.viewport.dropFirst(24).contains { !$0.text.isEmpty } })
        let offset = capture.bytes.count
        // The status bar rejects width 20 WITHOUT updating screen.geometry.
        await bar.handleTerminalResizeForTesting(rows: 48, columns: 20)
        #expect(screen.isAppendOnly)
        let after = capture.terminal.withLock { $0.history.map(\.text) + $0.viewport.map(\.text) }
        #expect(Array(after.prefix(before.count)) == before)
        let emitted = String(capture.bytes.dropFirst(offset))
        #expect(emitted.hasPrefix("\u{1B}[?6l\u{1B}[r"))
        #expect(emitted.contains("\u{1B}[999999;1H\r\n"))
        #expect(!emitted.contains("\u{1B}[24;1H"))
        #expect(!emitted.contains("\u{1B}[0J"))
        #expect(!emitted.contains("\u{1B}[2J"))
        await bar.stop()
    }

    private func expectQueuedChunksDrained(restartDirectly: Bool, armQuery: Bool) {
        let capture = PrimaryScreenCapture(), screen = capture.screen()
        install(screen)
        capture.resize(rows: 48, columns: 45)
        let before = capture.terminal.withLock { $0.history.map(\.text) + $0.viewport.map(\.text) }
        let offset = capture.bytes.count
        let chunks = ["queued-A|", "queued-B|\r\n", "queued-C|\r\n"]
        for chunk in chunks { #expect(screen.append(chunk) == nil) }
        if armQuery { install(screen, rows: 48, columns: 45, rebuild: true) }
        #expect(!capture.bytes.contains("queued-A|"))
        if restartDirectly { screen.prepareSession() } else { screen.stop() }
        screen.prepareSession() // resetting again must neither drop nor replay
        let emitted = String(capture.bytes.dropFirst(offset))
        #expect(emitted.contains(chunks.joined()))
        for chunk in chunks { #expect(emitted.components(separatedBy: chunk).count == 2) }
        #expect(!emitted.contains("\u{1B}[0J"))
        #expect(!emitted.contains("\u{1B}[2J"))
        #expect(!emitted.contains("\u{1B}[3J"))
        #expect(!emitted.contains("Terminal layout disabled")) // cancellation cannot re-enter rendering
        #expect(!capture.reports.isHoldingInput)
        let after = capture.terminal.withLock { $0.history.map(\.text) + $0.viewport.map(\.text) }
        #expect(Array(after.prefix(before.count)) == before)
    }

    @Test(arguments: [false, true])
    func stopDuringResizeDrainsChunksOnceInOrder(armQuery: Bool) {
        expectQueuedChunksDrained(restartDirectly: false, armQuery: armQuery)
    }

    @Test(arguments: [false, true])
    func prepareSessionDuringResizeDrainsChunksOnceInOrder(armQuery: Bool) {
        expectQueuedChunksDrained(restartDirectly: true, armQuery: armQuery)
    }

    @Test func fallbackCancelsSelectionAndDefaultWithoutCommitting() {
        let capture = PrimaryScreenCapture(), screen = capture.screen()
        install(screen)
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(" \r".utf8))
        let raw = TerminalRawInput(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, cursorReports: capture.reports)
        let selection = TerminalCheckboxMenu.selectMenu(title: "Menu",
            items: [.init(value: "first", title: "First", detail: nil)],
            initialState: .multiple(Set<String>()), focusedIndex: 0, reservedBottomRows: 4,
            shouldCancel: { screen.enterAppendOnly(reason: "cursor report timeout fixture"); return false },
            rawInput: raw, screen: screen)
        #expect(selection == nil)
        let answer = TerminalCheckboxMenu.readPromptLine(title: "Consent", prompt: "Allow?", defaultValue: "yes",
            allowEmpty: true, help: nil, reservedBottomRows: 4, screen: screen) { .submitted("") }
        #expect(answer == nil)
    }

    @Test func fallbackPreservesDraftAndActualRawInputStillSubmitsVisibleText() async throws {
        let capture = PrimaryScreenCapture()
        let bar = TerminalStatusBar(isEnabled: true, cursorReports: capture.reports, outputSink: capture.write)
        await bar.configureForTesting()
        let pipe = Pipe()
        let reader = TerminalInteractiveLineReader(rawInput: TerminalRawInput(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor, cursorReports: capture.reports))
        reader.withPanelLock { state in
            state.panelStatusBar = bar
            state.panelBuffer = Array("draft 界")
            state.panelCursorIndex = state.panelBuffer.count
        }
        await reader.renderPanel()
        let screen = await bar.primaryScreen
        screen.enterAppendOnly(reason: "cursor report timeout fixture")
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "draft 界")
        #expect(capture.bytes.contains("> draft 界▏"))
        let submitted = Mutex<[String]>([])
        pipe.fileHandleForWriting.write(Data("!\r".utf8))
        for _ in 0..<2 {
            guard case let .key(key) = reader.readKeyResult(pollTimeoutMilliseconds: 50) else {
                Issue.record("raw text input unavailable after fallback"); return
            }
            await reader.handlePanelKey(key) { event in
                if case let .submitted(value) = event { submitted.withLock { $0.append(value) } }
            }
            await reader.renderPanel()
        }
        #expect(submitted.withLock { $0 } == ["draft 界!"])
        #expect(capture.bytes.contains("> draft 界!▏"))
        let count = capture.bytes.count
        await bar.renderOverlay()
        #expect(capture.bytes.count == count) // no invisible fixed panel resurrected
        await bar.stop()
    }

    @Test func actualStatusDraftDockAndModalSurviveResize() async throws {
        let capture = PrimaryScreenCapture()
        let bar = TerminalStatusBar(isEnabled: true, cursorReports: capture.reports,
            resizeGeneration: { capture.generation.withLock { $0 } }, outputSink: capture.write)
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model", isProcessing: true)
        let draft = "draft 界🙂\nsecond line"
        await bar.updateInputPanel(text: draft, cursorIndex: draft.count, modeText: "Prompt", helpText: "Enter")
        await bar.setSharedChatReader(entries: [], unreadCount: 0, isExpanded: true)
        let screen = await bar.primaryScreen
        let modal = screen.beginModal()
        screen.updateModal(modal, value: .init(title: "Consent", help: [],
            lines: [.init(text: "r / a / c", itemIndex: 0)], focusedIndex: 0))
        for (rows, columns) in [(18, 45), (24, 100)] {
            capture.resize(rows: rows, columns: columns)
            await bar.handleTerminalResizeForTesting(rows: rows, columns: columns)
            try await capture.answerReport()
            #expect(await bar.state.inputPanelState?.text == draft)
            #expect(capture.visible.contains("test-model"))
            #expect(capture.visible.contains("r / a / c"))
        }
        screen.endModal(modal)
        #expect(capture.visible.contains("second line"))
        #expect(capture.visible.contains("Chat"))
        await bar.stop()
    }
}
