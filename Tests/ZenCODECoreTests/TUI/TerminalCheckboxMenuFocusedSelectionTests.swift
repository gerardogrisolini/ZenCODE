//
//  TerminalCheckboxMenuFocusedSelectionTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

/// Drives `TerminalCheckboxMenu.selectWithFocus` with scripted key bytes read
/// from a pipe, on a captured primary screen.
@Suite(TerminalBlockingTestScope())
struct TerminalCheckboxMenuFocusedSelectionTests {
    private static let items: [TerminalCheckboxMenuItem<String>] = [
        .init(value: "alpha", title: "Alpha", detail: nil),
        .init(value: "beta", title: "Beta *", detail: "second"),
        .init(value: "gamma", title: "Gamma", detail: nil),
    ]
    // Single-byte keys only: an escape sequence or a lone Esc is sensitive to
    // the process-wide resize generation that unrelated tests bump concurrently.
    private static let down = "j"
    private static let up = "k"

    private func footer(rows: Int) -> String {
        ["PROMPT| draft", "draft second line", "DOCK| 2 unread", "STATUS| ready"].enumerated().map {
            "\u{1B}[\(rows - 3 + $0.offset);1H\u{1B}[2K" + $0.element
        }.joined()
    }

    private func run(
        keys: String,
        selected: Set<String>,
        focused: String?,
        helpLines: [String]? = nil,
        capture: PrimaryScreenCapture = PrimaryScreenCapture()
    ) -> (selected: Set<String>, focused: String)? {
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
        return TerminalCheckboxMenu.selectWithFocus(
            title: "Agent profiles",
            items: Self.items,
            selected: selected,
            focused: focused,
            helpLines: helpLines,
            reservedBottomRows: 4,
            shouldCancel: nil,
            rawInput: raw,
            screen: screen
        )
    }

    @Test
    func returnsTheTickedSetAndTheHighlightedItemOnEnter() throws {
        // Down to "beta", down to "gamma", toggle it on, confirm.
        let result = try #require(run(
            keys: Self.down + Self.down + " \r",
            selected: ["alpha"],
            focused: nil
        ))
        #expect(result.selected == ["alpha", "gamma"])
        #expect(result.focused == "gamma")
    }

    @Test
    func cursorStartsOnTheFocusedItemSoEnterAloneKeepsIt() throws {
        let result = try #require(run(
            keys: "\r",
            selected: ["alpha", "beta", "gamma"],
            focused: "beta"
        ))
        #expect(result.selected == ["alpha", "beta", "gamma"])
        #expect(result.focused == "beta")
    }

    @Test
    func missingOrUnknownFocusStartsOnTheFirstRow() throws {
        let withoutFocus = try #require(run(keys: "\r", selected: [], focused: nil))
        #expect(withoutFocus.focused == "alpha")
        let unknownFocus = try #require(run(keys: "\r", selected: [], focused: "missing"))
        #expect(unknownFocus.focused == "alpha")
    }

    @Test
    func spaceAndXToggleWithoutMovingTheCursor() throws {
        let result = try #require(run(
            keys: "x" + " " + "X" + "\r",
            selected: [],
            focused: "gamma"
        ))
        // Three toggles on the same row leave it ticked.
        #expect(result.selected == ["gamma"])
        #expect(result.focused == "gamma")
    }

    @Test
    func allAndNoneKeysReplaceTheSelectionWithoutMovingTheCursor() throws {
        let all = try #require(run(keys: "a\r", selected: [], focused: "beta"))
        #expect(all.selected == ["alpha", "beta", "gamma"])
        #expect(all.focused == "beta")

        let none = try #require(run(keys: "N\r", selected: ["alpha", "beta"], focused: "gamma"))
        #expect(none.selected.isEmpty)
        #expect(none.focused == "gamma")
    }

    @Test
    func arrowKeysStayWithinTheItemList() throws {
        let top = try #require(run(keys: Self.up + Self.up + "\r", selected: [], focused: "beta"))
        #expect(top.focused == "alpha")
        let bottom = try #require(run(
            keys: Self.down + Self.down + Self.down + Self.down + "\r",
            selected: [],
            focused: "alpha"
        ))
        #expect(bottom.focused == "gamma")
    }

    @Test
    func cancelKeysReturnNothing() {
        #expect(run(keys: " q", selected: ["alpha"], focused: "beta") == nil)
        #expect(run(keys: "xQ", selected: ["alpha"], focused: "beta") == nil)
    }

    @Test
    func customHelpReplacesTheDefaultHelpLine() throws {
        let help = "↑/↓ move · Space/X toggle project · A all · N none · Enter use agent · Esc/Q cancel"
        let capture = PrimaryScreenCapture()
        _ = try #require(run(
            keys: "\r",
            selected: ["alpha"],
            focused: "alpha",
            helpLines: [help],
            capture: capture
        ))
        let rendered = capture.bytes
        #expect(rendered.contains("Enter use agent"))
        #expect(!rendered.contains("Enter confirm"))
    }

    @Test
    func defaultHelpIsKeptWhenNoOverrideIsGiven() throws {
        let capture = PrimaryScreenCapture()
        _ = try #require(run(keys: "\r", selected: ["alpha"], focused: nil, capture: capture))
        #expect(capture.bytes.contains("Enter confirm"))
    }

    @Test
    func emptyItemListReturnsNothing() {
        let result = TerminalCheckboxMenu.selectWithFocus(
            title: "Empty",
            items: [TerminalCheckboxMenuItem<String>](),
            selected: [],
            focused: nil,
            helpLines: nil,
            reservedBottomRows: 0,
            shouldCancel: nil
        )
        #expect(result == nil)
    }

    @Test
    func existingMenuModesKeepTheirOwnHelpAndResult() throws {
        let capture = PrimaryScreenCapture()
        let screen = capture.screen()
        screen.commitFooter(
            geometry: .init(rows: 24, columns: 100),
            reservedRows: 4,
            sequence: footer(rows: 24),
            rebuild: false
        )
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(" \r".utf8))
        let raw = TerminalRawInput(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            cursorReports: capture.reports
        )
        let state = TerminalCheckboxMenu.selectMenu(
            title: "Legacy",
            items: Self.items,
            initialState: .multiple(Set<String>()),
            focusedIndex: 1,
            reservedBottomRows: 4,
            shouldCancel: nil,
            rawInput: raw,
            screen: screen
        )
        guard case let .multiple(values)? = state else {
            Issue.record("Expected a multiple-selection result.")
            return
        }
        #expect(values == ["beta"])
        #expect(capture.bytes.contains("Enter confirm"))
    }
}
