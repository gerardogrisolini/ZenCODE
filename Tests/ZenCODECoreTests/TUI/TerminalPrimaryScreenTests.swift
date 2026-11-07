// TerminalPrimaryScreenTests.swift
import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Counts finished CPR callbacks through the test-only diagnostic sink. A
/// superseded reply keeps input held, so it cannot be awaited by released input.
final class CursorReportDeliveries: Sendable {
    private let count = Mutex(0)
    var completed: Int { count.withLock { $0 } }
    func makeReports() -> TerminalCursorReport {
        TerminalCursorReport(diagnostic: { [self] event in
            if event.hasPrefix("report.delivery.end") { count.withLock { $0 += 1 } }
        })
    }
}

final class PrimaryScreenCapture: Sendable {
    let terminal: Mutex<PrimaryScreenTerminalModel>
    let writes = Mutex<[String]>([])
    let reports: TerminalCursorReport
    let generation = Mutex<UInt64>(0)
    init(rows: Int = 24, columns: Int = 100, reports: TerminalCursorReport = TerminalCursorReport()) {
        terminal = Mutex(PrimaryScreenTerminalModel(rows: rows, columns: columns))
        self.reports = reports
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
    /// Returns the bytes `consume` hands back, as the raw reader receives them.
    /// If the dispatched delivery releases input before the reply's last byte
    /// returns, that byte carries the deferred keys instead of leaving them deferred.
    @discardableResult
    func answerReport() async throws -> [UInt8] {
        let response = terminal.withLock { $0.cursorReport }
        var released: [UInt8] = []
        for byte in response.utf8 { released += reports.consume(byte) }
        try await terminalWaitForCursorReport(reports)
        return released
    }
    /// Answers a query superseded by a physical resize. Its callback discards
    /// the reply and keeps input held, so wait for the callback itself.
    func answerSupersededReport(_ deliveries: CursorReportDeliveries) async throws {
        let before = deliveries.completed
        let response = terminal.withLock { $0.cursorReport }
        for byte in response.utf8 { _ = reports.consume(byte) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while deliveries.completed == before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(deliveries.completed > before, "Superseded cursor report was not delivered")
    }
    var queries: Int { bytes.components(separatedBy: "\u{1B}[6n").count - 1 }
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

    @Test func modalHeaderKeepsHalfTheRowsAndScrollsWhenSpaceIsTight() {
        func layout(_ header: [String], items: Int, capacity: Int) -> TerminalCheckboxMenu.HeaderLayout {
            TerminalCheckboxMenu.headerLayout(header, offset: 0, itemLineCount: items, itemCapacity: capacity)
        }
        // A header that fits beside the items is shown whole and does not scroll.
        #expect(layout(["a", "b"], items: 2, capacity: 5) == .init(lines: ["a", "b", ""], scrollLimit: 0))
        #expect(layout(["a"], items: 0, capacity: 2) == .init(lines: ["a", ""], scrollLimit: 0))
        #expect(layout([], items: 3, capacity: 10) == .init(lines: [], scrollLimit: 0))
        // One that does not fit keeps at least half the rows and scrolls.
        let tight = layout((0..<30).map { "HEADER_\($0)" }, items: 14, capacity: 14)
        #expect(tight.lines.count == 7)
        #expect(tight.lines.last == "")
        #expect(tight.lines.contains("↓ more"))
        #expect(tight.scrollLimit == 24)

        let capture = PrimaryScreenCapture()
        let screen = capture.screen()
        install(screen)
        let menu = screen.beginModal()
        let items = (0..<14).map { (index: Int) in
            TerminalCheckboxMenu.RenderedMenuLine(text: "ITEM_\(index)", itemIndex: index)
        }
        let modal = TerminalPrimaryScreen.Modal(title: "BINDINGS", help: [],
            lines: items, focusedIndex: 0,
            header: (0..<30).map { "HEADER_\($0)" })
        screen.updateModal(menu, value: modal)
        let visible = capture.visible
        // The header owns half the rows and the items scroll in the rest.
        for index in 0..<5 { #expect(visible.contains("HEADER_\(index)")) }
        #expect(!visible.contains("HEADER_5"))
        #expect(!visible.contains("HEADER_29"))
        for index in 0..<6 { #expect(visible.contains("ITEM_\(index)")) }
        #expect(!visible.contains("ITEM_6"))
        #expect(!visible.contains("ITEM_13"))
        #expect(visible.components(separatedBy: "↓ more").count - 1 == 2)
        #expect(screen.menuHeaderScrollLimit(for: modal) == 24)
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

    @Test func secondResizeDuringCPRRequeriesAfterTheStaleReply() async throws {
        let deliveries = CursorReportDeliveries()
        let capture = PrimaryScreenCapture(reports: deliveries.makeReports()), screen = capture.screen()
        install(screen)
        capture.resize(rows: 24, columns: 45)
        install(screen, columns: 45, rebuild: true)
        #expect(capture.queries == 1)
        capture.resize(rows: 24, columns: 100)
        install(screen, rebuild: true)
        #expect(!screen.isAppendOnly)
        #expect(capture.queries == 1) // never a second query while one is in flight
        try await capture.answerSupersededReport(deliveries)
        #expect(!screen.isAppendOnly)
        #expect(capture.queries == 2) // the committed geometry is queried at once
        #expect(screen.validReceipt == nil)
        try await capture.answerReport()
        #expect(!screen.isAppendOnly)
        #expect(screen.validReceipt != nil)
        install(screen)
        #expect(capture.queries == 2)
        #expect(capture.visible.components(separatedBy: "STATUS|").count == 2)
        #expect(!capture.bytes.contains("\u{1B}[2J"))
        #expect(!capture.bytes.contains("Terminal layout disabled"))
    }

    @Test(arguments: [false, true])
    func severalResizesDuringCPRRequeryExactlyOnce(replyBeforeCommit: Bool) async throws {
        let deliveries = CursorReportDeliveries()
        let capture = PrimaryScreenCapture(reports: deliveries.makeReports()), screen = capture.screen()
        install(screen)
        capture.resize(rows: 24, columns: 45)
        install(screen, columns: 45, rebuild: true)
        capture.resize(rows: 24, columns: 80)
        if replyBeforeCommit { try await capture.answerSupersededReport(deliveries) }
        capture.resize(rows: 24, columns: 60)
        capture.resize(rows: 24, columns: 100)
        install(screen, rebuild: true)
        if !replyBeforeCommit { try await capture.answerSupersededReport(deliveries) }
        #expect(!screen.isAppendOnly)
        #expect(capture.queries == 2)
        install(screen, rebuild: true)
        try await capture.answerReport()
        #expect(!screen.isAppendOnly)
        #expect(capture.queries == 2)
        #expect(capture.visible.components(separatedBy: "STATUS|").count == 2)
        #expect(!capture.bytes.contains("\u{1B}[2J"))
    }

    @Test func supersededQueryFailureStillFencesWithoutAnotherQuery() async throws {
        let capture = PrimaryScreenCapture(), screen = capture.screen()
        install(screen)
        capture.resize(rows: 24, columns: 45)
        install(screen, columns: 45, rebuild: true)
        capture.resize(rows: 24, columns: 100)
        install(screen, rebuild: true)
        // Same failure path as a timeout: no reply was read, so never retry.
        capture.reports.cancel()
        #expect(screen.isAppendOnly)
        #expect(capture.bytes.contains("Terminal layout disabled (cursor report failed or stale)"))
        #expect(capture.reports.isFenced)
        try await capture.answerReport() // the late reply is drained, not delivered
        install(screen, rebuild: true)
        #expect(capture.queries == 1)
        #expect(!capture.bytes.contains("\u{1B}[2J"))
    }

    @Test(arguments: [false, true])
    func outputAndKeysAcrossSupersededCPRAreReleasedOnceInOrder(replyBeforeCommit: Bool) async throws {
        let deliveries = CursorReportDeliveries()
        let capture = PrimaryScreenCapture(reports: deliveries.makeReports()), screen = capture.screen()
        install(screen)
        let markers = ["held-A|", "held-B|", "held-C|", "held-D|"]
        let keys = Array("abcd".utf8)
        func hold(_ index: Int) {
            #expect(screen.append(markers[index] + "\n") == nil)
            #expect(capture.reports.consume(keys[index]).isEmpty)
        }
        capture.resize(rows: 24, columns: 45)
        hold(0) // before the first query
        install(screen, columns: 45, rebuild: true)
        hold(1) // during the superseded query
        capture.resize(rows: 24, columns: 100)
        if replyBeforeCommit {
            try await capture.answerSupersededReport(deliveries)
            hold(2) // between the two queries
            install(screen, rebuild: true)
        } else {
            install(screen, rebuild: true)
            try await capture.answerSupersededReport(deliveries)
            hold(2)
        }
        hold(3) // during the second query
        #expect(capture.queries == 2)
        #expect(capture.reports.takeDeferredKeys().isEmpty)
        for marker in markers { #expect(!capture.bytes.contains(marker)) }
        // Like the raw reader: bytes released by consume, then the deferred rest.
        let released = try await capture.answerReport()
        #expect(!screen.isAppendOnly)
        #expect(released + capture.reports.takeDeferredKeys() == keys)
        #expect(capture.reports.takeDeferredKeys().isEmpty)
        for marker in markers { #expect(capture.bytes.components(separatedBy: marker).count == 2) }
        let all = capture.history + "\n" + capture.visible
        let positions = markers.compactMap { all.range(of: $0)?.lowerBound }
        #expect(positions.count == markers.count)
        #expect(positions == positions.sorted())
        #expect(capture.visible.components(separatedBy: "STATUS|").count == 2)
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

    @Test func dialogViewportIsTheRowBudgetLeftByTheCommittedGeometryAndFooter() {
        let capture = PrimaryScreenCapture(rows: 20, columns: 60)
        let screen = capture.screen()
        install(screen, rows: 20, columns: 60)
        func size(_ viewport: (rows: Int, columns: Int)) -> [Int] { [viewport.rows, viewport.columns] }
        // 20 rows minus the 4-row footer and the two rows kept for the transcript.
        #expect(size(screen.dialogViewport()) == [14, 60])
        let modal = TerminalModalSession(screen: screen)
        #expect(size(modal.dialogViewport()) == [14, 60])
        modal.close()

        // A taller footer, committed on the same geometry, shrinks it.
        screen.commitFooter(geometry: .init(rows: 20, columns: 60), reservedRows: 6,
                            sequence: footer(rows: 20, columns: 60))
        #expect(size(screen.dialogViewport()) == [12, 60])
    }
}
