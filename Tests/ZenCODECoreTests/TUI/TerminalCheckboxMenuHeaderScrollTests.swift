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
}
