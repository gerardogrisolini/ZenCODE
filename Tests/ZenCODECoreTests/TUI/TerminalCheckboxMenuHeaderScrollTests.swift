//
//  TerminalCheckboxMenuHeaderScrollTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// A header table taller than its share of the menu frame scrolls: Tab moves
/// control between the list and the table, and the arrows act on the part in
/// control.
@Suite(TerminalBlockingTestScope())
struct TerminalCheckboxMenuHeaderScrollTests {
    // MARK: Pure layout

    private static func rows(_ count: Int) -> [String] { (0..<count).map { "H\($0)" } }

    private func layout(
        _ header: [String],
        offset: Int = 0,
        items: Int,
        capacity: Int
    ) -> TerminalCheckboxMenu.HeaderLayout {
        TerminalCheckboxMenu.headerLayout(
            header, offset: offset, itemLineCount: items, itemCapacity: capacity
        )
    }

    @Test
    func headerThatFitsIsShownWholeAndDoesNotScroll() {
        // 3 rows + separator + 4 item rows = 8, exactly the capacity.
        let whole = layout(Self.rows(3), items: 4, capacity: 8)
        #expect(whole == .init(lines: ["H0", "H1", "H2", ""], scrollLimit: 0))
        // The offset is irrelevant when nothing scrolls.
        #expect(layout(Self.rows(3), offset: 5, items: 4, capacity: 8) == whole)
        // One row less and it scrolls.
        #expect(layout(Self.rows(3), items: 4, capacity: 7).scrollLimit > 0)
    }

    @Test
    func emptyHeaderHasNoRowsAndNoLimit() {
        #expect(layout([], items: 3, capacity: 10) == .init(lines: [], scrollLimit: 0))
        #expect(layout([], offset: 4, items: 30, capacity: 2) == .init(lines: [], scrollLimit: 0))
    }

    @Test
    func scrollableHeaderShowsTheWindowAtTheOffsetWithMoreMarkers() {
        // 10 item rows leave 4 free of 14, so the header takes half: 7 rows,
        // separator included, hence a viewport of 6.
        let top = layout(Self.rows(20), items: 10, capacity: 14)
        #expect(top.lines == ["H0", "H1", "H2", "H3", "H4", "↓ more", ""])
        #expect(top.scrollLimit == 14)

        let middle = layout(Self.rows(20), offset: 5, items: 10, capacity: 14)
        #expect(middle.lines == ["↑ more", "H6", "H7", "H8", "H9", "↓ more", ""])
        #expect(middle.scrollLimit == 14)

        // At the limit the last row is shown, so only the "↑ more" marker is left.
        let bottom = layout(Self.rows(20), offset: 14, items: 10, capacity: 14)
        #expect(bottom.lines == ["↑ more", "H15", "H16", "H17", "H18", "H19", ""])
    }

    @Test
    func offsetIsClampedToTheValidRange() {
        let bottom = layout(Self.rows(20), offset: 14, items: 10, capacity: 14)
        #expect(layout(Self.rows(20), offset: 15, items: 10, capacity: 14) == bottom)
        #expect(layout(Self.rows(20), offset: 9_999, items: 10, capacity: 14) == bottom)
        let top = layout(Self.rows(20), items: 10, capacity: 14)
        #expect(layout(Self.rows(20), offset: -1, items: 10, capacity: 14) == top)
        #expect(layout(Self.rows(20), offset: Int.min, items: 10, capacity: 14) == top)
    }

    @Test
    func headerTakesTheRowsTheItemsLeaveFree() {
        // Only 3 item rows: the header gets the other 11 (10 plus separator).
        let result = layout(Self.rows(20), items: 3, capacity: 14)
        #expect(result.lines.count == 11)
        #expect(result.scrollLimit == 10)
    }

    @Test
    func shortHeaderStaysWholeWhileTheItemsScroll() {
        // 2 rows fit in the half reserved, so the header needs no scrolling
        // even though the items overflow.
        let result = layout(Self.rows(2), items: 30, capacity: 14)
        #expect(result == .init(lines: ["H0", "H1", ""], scrollLimit: 0))
    }

    @Test
    func markersNeedAViewportOfThreeRows() {
        // Viewport of 2: no markers, a plain window.
        let two = layout(Self.rows(10), offset: 4, items: 30, capacity: 6)
        #expect(two.lines == ["H4", "H5", ""])
        #expect(two.scrollLimit == 8)
        // Viewport of 1.
        let one = layout(Self.rows(10), offset: 3, items: 30, capacity: 5)
        #expect(one.lines == ["H3", ""])
        #expect(one.scrollLimit == 9)
        // Viewport of exactly 3: first and last rows become markers.
        #expect(layout(Self.rows(10), items: 30, capacity: 8).lines == ["H0", "H1", "↓ more", ""])
        #expect(layout(Self.rows(10), offset: 3, items: 30, capacity: 8).lines == ["↑ more", "H4", "↓ more", ""])
        #expect(layout(Self.rows(10), offset: 7, items: 30, capacity: 8).lines == ["↑ more", "H8", "H9", ""])
    }

    @Test
    func headerIsOmittedWhenNoRowRemainsForIt() {
        // Reserved rows = max(0, capacity / 2): a viewport below 1 hides it.
        #expect(layout(Self.rows(10), items: 30, capacity: 2) == .init(lines: [], scrollLimit: 0))
        #expect(layout(Self.rows(10), items: 30, capacity: 1) == .init(lines: [], scrollLimit: 0))
        #expect(layout(Self.rows(10), offset: 3, items: 30, capacity: 0) == .init(lines: [], scrollLimit: 0))
    }

    // MARK: Help

    @Test
    func helpMentionsTabOnlyOnTheFirstLineAndKeepsTheLineCount() {
        let single = ["↑/↓ move · Enter select · Esc/Q cancel"]
        #expect(TerminalCheckboxMenu.scrollableHeaderHelpLines(single, tableFocused: false)
            == ["↑/↓ move · Tab table · Enter select · Esc/Q cancel"])
        #expect(TerminalCheckboxMenu.scrollableHeaderHelpLines(single, tableFocused: true)
            == ["↑/↓ scroll table · Tab list · Enter select · Esc/Q cancel"])

        let custom = ["Enter use agent", "second line"]
        #expect(TerminalCheckboxMenu.scrollableHeaderHelpLines(custom, tableFocused: false)
            == ["Enter use agent · Tab table", "second line"])
        #expect(TerminalCheckboxMenu.scrollableHeaderHelpLines(custom, tableFocused: true)
            == ["Enter use agent · Tab list", "second line"])
        #expect(TerminalCheckboxMenu.scrollableHeaderHelpLines([], tableFocused: true).isEmpty)
    }

    // MARK: ANSI handling

    @Test
    func dimmedItemLinesKeepTheirWidthAndAnsi() {
        let dimmed = TerminalStyle.Text.muted + "(x) Done" + TerminalStyle.reset
        let fitted = TerminalCheckboxMenu.fitLine(dimmed, width: 30)
        #expect(fitted == dimmed)
        #expect(TerminalANSIText.visibleWidth(TerminalCheckboxMenu.padded(fitted, width: 30)) == 30)
        // Too narrow: it is cut by visible columns, and the style is closed.
        let cut = TerminalCheckboxMenu.fitLine(dimmed, width: 6)
        #expect(TerminalANSIText.visibleWidth(cut) <= 6)
        #expect(cut.hasPrefix(TerminalStyle.Text.muted))
        #expect(cut.contains(TerminalStyle.reset))
    }

    // MARK: Keys

    @Test
    func readKeyMapsTheTabByte() {
        let capture = PrimaryScreenCapture()
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("\tjk".utf8))
        let raw = TerminalRawInput(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            cursorReports: capture.reports
        )
        #expect(TerminalCheckboxMenu.readKey(rawInput: raw) == .tab)
        #expect(TerminalCheckboxMenu.readKey(rawInput: raw) == .down)
        #expect(TerminalCheckboxMenu.readKey(rawInput: raw) == .up)
    }

    @Test
    func tabDoesNotChangeTheSelectionState() {
        let items = [
            TerminalCheckboxMenuItem(value: 0, title: "Zero", detail: nil),
            TerminalCheckboxMenuItem(value: 1, title: "One", detail: nil),
        ]
        var state = TerminalCheckboxMenu.SelectionState<Int>.single(1)
        var focused = 1
        let action = TerminalCheckboxMenu.apply(key: .tab, items: items, state: &state, focusedIndex: &focused)
        #expect(action == .continue)
        #expect(focused == 1)
        guard case .single(.some(1)) = state else {
            Issue.record("Tab changed the selection")
            return
        }
    }

    // MARK: End to end

    private static let items: [TerminalCheckboxMenuItem<Int>] = [
        .init(value: 0, title: "Done", detail: "save and exit"),
        .init(value: 1, title: "Alpha", detail: nil, groupTitle: "Configure"),
        .init(value: 2, title: "Beta", detail: nil, groupTitle: "Configure"),
        .init(value: 3, title: "Gamma", detail: nil, groupTitle: "Configure"),
    ]

    private static func tableRows(_ count: Int) -> [String] {
        (0..<count).map { "ROW_" + String(format: "%02d", $0) }
    }

    private func footer(rows: Int) -> String {
        ["PROMPT| draft", "draft second line", "DOCK| 2 unread", "STATUS| ready"].enumerated().map {
            "\u{1B}[\(rows - 3 + $0.offset);1H\u{1B}[2K" + $0.element
        }.joined()
    }

    /// Runs `selectMenu` on a 24x100 captured screen, feeding `keys` from a pipe.
    /// Returns the chosen value, or `nil` when the menu was cancelled.
    private func run(
        keys: String,
        selected: Int = 1,
        header: [String],
        capture: PrimaryScreenCapture
    ) -> Int? {
        let screen = capture.screen()
        screen.commitFooter(
            geometry: .init(rows: 24, columns: 100),
            reservedRows: 4,
            sequence: footer(rows: 24),
            rebuild: false
        )
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(keys.utf8))
        let raw = TerminalRawInput(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            cursorReports: capture.reports
        )
        let focusedIndex = Self.items.firstIndex { $0.value == selected } ?? 0
        guard case let .single(value)? = TerminalCheckboxMenu.selectMenu(
            title: "Agent model bindings",
            items: Self.items,
            initialState: .single(selected),
            focusedIndex: focusedIndex,
            header: header,
            reservedBottomRows: 4,
            shouldCancel: nil,
            rawInput: raw,
            screen: screen
        ) else { return nil }
        return value
    }

    @Test
    func tabMovesTheArrowsToTheTableAndScrollsItWithoutMovingTheList() throws {
        let header = Self.tableRows(40)

        // Control run: nothing scrolls, so the late rows are never drawn and the
        // list keeps the cursor and the help of a menu with a scrollable table.
        let control = PrimaryScreenCapture()
        #expect(run(keys: "\r", header: header, capture: control) == 1)
        #expect(control.bytes.contains("ROW_00"))
        #expect(!control.bytes.contains("ROW_09"))
        #expect(control.bytes.contains("Tab table"))
        #expect(!control.bytes.contains("Tab list"))

        // Tab, five downs, Enter: the table scrolls, the list stays on Alpha.
        let capture = PrimaryScreenCapture()
        #expect(run(keys: "\tjjjjj\r", header: header, capture: capture) == 1)
        let bytes = capture.bytes
        #expect(bytes.contains("ROW_09"))
        #expect(bytes.contains("Tab list"))
        #expect(bytes.contains("scroll table"))

        // While the table has control the last frame drew the list without its
        // cursor and dimmed, and the table moved on.
        let lastTableFrame = try #require(
            capture.writes.withLock { $0 }.last { $0.contains("Tab list") }
        )
        #expect(lastTableFrame.contains("ROW_09"))
        #expect(!lastTableFrame.contains("ROW_00"))
        #expect(lastTableFrame.contains("↑ more"))
        #expect(!lastTableFrame.contains("> (x)"))
        #expect(!lastTableFrame.contains("> ( )"))
        #expect(lastTableFrame.contains(TerminalStyle.Text.muted + "(x) Alpha"))
        #expect(lastTableFrame.contains(TerminalStyle.Text.muted + "( ) Done"))

        // The first frame is the list in control, with its cursor.
        let firstFrame = try #require(capture.writes.withLock { $0 }.first { $0.contains("Agent model bindings") })
        #expect(firstFrame.contains("> (x) Alpha"))
    }

    @Test
    func upAndDownAreClampedAtBothEndsOfTheTable() {
        let header = Self.tableRows(40)
        let capture = PrimaryScreenCapture()
        // Up at the top does nothing; many downs stop at the last row.
        let keys = "\tk" + String(repeating: "j", count: 80) + "\r"
        #expect(run(keys: keys, header: header, capture: capture) == 1)
        let lastFrame = capture.writes.withLock { $0 }.last { $0.contains("Tab list") }
        #expect(lastFrame?.contains("ROW_39") == true)
        #expect(lastFrame?.contains("↓ more") == false)
        #expect(lastFrame?.contains("↑ more") == true)
    }

    @Test
    func tabAgainReturnsTheArrowsToTheList() {
        let header = Self.tableRows(40)
        let capture = PrimaryScreenCapture()
        // Down scrolls the table, Tab goes back, Down then moves the list to Beta.
        #expect(run(keys: "\tj\tj\r", header: header, capture: capture) == 2)
        // The list is in control again: it is drawn with a cursor once more.
        let frames = capture.writes.withLock { $0 }.filter { $0.contains("Agent model bindings") }
        #expect(frames.last?.contains("> (x) Beta") == true)
    }

    @Test
    func otherKeysStillReachTheMenuWhileTheTableHasControl() {
        let header = Self.tableRows(40)
        // Esc/Q cancels, Enter confirms, Space picks the focused row.
        #expect(run(keys: "\tq", header: header, capture: PrimaryScreenCapture()) == nil)
        #expect(run(keys: "\tjj\r", header: header, capture: PrimaryScreenCapture()) == 1)
        #expect(run(keys: "\tjj ", selected: 2, header: header, capture: PrimaryScreenCapture()) == 2)
    }

    @Test
    func tabIsIgnoredWhenTheHeaderFits() {
        let header = Self.tableRows(2)
        let capture = PrimaryScreenCapture()
        // Tab does nothing, so the following "j" still moves the list to Beta.
        #expect(run(keys: "\tj\r", header: header, capture: capture) == 2)
        #expect(!capture.bytes.contains("Tab"))
        #expect(capture.bytes.contains("ROW_01"))
        #expect(capture.bytes.contains("↑/↓ move · Enter select"))
    }

    @Test
    func menuWithoutHeaderIgnoresTabAndKeepsItsHelp() {
        let capture = PrimaryScreenCapture()
        #expect(run(keys: "\tj\r", header: [], capture: capture) == 2)
        #expect(!capture.bytes.contains("Tab"))
        #expect(capture.bytes.contains("↑/↓ move · Enter select · Esc/Q cancel"))
    }
}
