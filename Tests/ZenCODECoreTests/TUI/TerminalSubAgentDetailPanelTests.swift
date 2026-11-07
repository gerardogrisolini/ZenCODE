//
//  TerminalSubAgentDetailPanelTests.swift
//  ZenCODE
//

import Testing
@testable import ZenCODECore

@Suite
struct TerminalSubAgentDetailPanelTests {
    private static let allActions: [TerminalSubAgentDetailAction] = [
        .scrollUp, .scrollDown, .pageUp, .pageDown, .top, .bottom,
        .focusPrevious, .focusNext, .confirm, .close
    ]

    private func numberedRows(_ count: Int, prefix: String = "row") -> [String] {
        (0..<count).map { "\(prefix)-\($0)" }
    }

    private func entries(_ count: Int) -> [TerminalSubAgentDetailPanel.ChoiceEntry] {
        (0..<count).map { .init(agentID: "id-\($0)", title: "agent-\($0)") }
    }

    private func plain(_ lines: [String]) -> [String] {
        lines.map(TerminalANSIText.stripANSI)
    }

    /// The text between `│ ` and ` │`, without the right padding.
    private func content(_ line: String) -> String {
        var text = TerminalANSIText.stripANSI(line)
        guard text.hasPrefix("│ "), text.hasSuffix(" │") else { return text }
        text = String(text.dropFirst(2).dropLast(2))
        while text.last == " " {
            text.removeLast()
        }
        return text
    }

    /// Interior rows of a frame drawn without a header.
    private func bodyContents(_ lines: [String]) -> [String] {
        lines.dropFirst().dropLast().map(content)
    }

    private func focusedIndex(_ panel: TerminalSubAgentDetailPanel) -> Int? {
        guard case let .choosing(_, focusedIndex) = panel.mode else { return nil }
        return focusedIndex
    }

    // MARK: - Follow and scrolling

    @Test func opensFollowingAndKeepsTheLastRowsVisibleWhileTheBodyGrows() {
        var panel = TerminalSubAgentDetailPanel()
        #expect(panel.isFollowing)
        #expect(panel.availability == .loading)

        panel.replace(headerRows: [], bodyRows: numberedRows(5), frameRows: 6)
        #expect(panel.bodyCapacity(frameRows: 6) == 4)
        #expect(panel.scrollOffset == 1)

        panel.replace(headerRows: [], bodyRows: numberedRows(10), frameRows: 6)
        #expect(panel.scrollOffset == 6)
        #expect(panel.isFollowing)
        #expect(bodyContents(panel.frameLines(rows: 6, columns: 30)) == ["row-6", "row-7", "row-8", "row-9"])
        // Drawing re-derives the bottom for another frame height while following.
        #expect(bodyContents(panel.frameLines(rows: 8, columns: 30)) == (4...9).map { "row-\($0)" })
    }

    @Test func scrollingAwayDisablesFollowAndReachingTheBottomRestoresIt() {
        var panel = TerminalSubAgentDetailPanel()
        panel.replace(headerRows: [], bodyRows: numberedRows(10), frameRows: 6)

        panel.apply(.scrollUp, frameRows: 6)
        #expect(panel.scrollOffset == 5)
        #expect(!panel.isFollowing)

        // New rows no longer move the window the operator is reading.
        panel.replace(headerRows: [], bodyRows: numberedRows(12), frameRows: 6)
        #expect(panel.scrollOffset == 5)
        #expect(!panel.isFollowing)
        #expect(bodyContents(panel.frameLines(rows: 6, columns: 30)) == ["row-5", "row-6", "row-7", "row-8"])

        panel.apply(.bottom, frameRows: 6)
        #expect(panel.scrollOffset == 8)
        #expect(panel.isFollowing)

        panel.apply(.top, frameRows: 6)
        #expect(panel.scrollOffset == 0)
        #expect(!panel.isFollowing)
        for _ in 0..<8 {
            panel.apply(.scrollDown, frameRows: 6)
        }
        #expect(panel.scrollOffset == 8)
        #expect(panel.isFollowing)

        panel.replace(headerRows: [], bodyRows: numberedRows(15), frameRows: 6)
        #expect(panel.scrollOffset == 11)
    }

    @Test func scrollingFromFollowStartsAtTheBottomEvenWithAStaleOffset() {
        var panel = TerminalSubAgentDetailPanel(bodyRows: numberedRows(10))
        #expect(panel.scrollOffset == 0)
        panel.apply(.scrollUp, frameRows: 6)
        #expect(panel.scrollOffset == 5)
        #expect(!panel.isFollowing)
    }

    @Test func shrinkingBodyClampsTheOffsetWithoutChangingFollow() {
        var panel = TerminalSubAgentDetailPanel()
        panel.replace(headerRows: [], bodyRows: numberedRows(20), frameRows: 6)
        panel.apply(.top, frameRows: 6)
        panel.apply(.pageDown, frameRows: 6)
        panel.apply(.pageDown, frameRows: 6)
        #expect(panel.scrollOffset == 8)
        #expect(!panel.isFollowing)

        panel.replace(headerRows: [], bodyRows: numberedRows(10), frameRows: 6)
        #expect(panel.scrollOffset == 6)
        #expect(!panel.isFollowing)

        panel.replace(headerRows: [], bodyRows: numberedRows(2), frameRows: 6)
        #expect(panel.scrollOffset == 0)
        #expect(!panel.isFollowing)
        #expect(bodyContents(panel.frameLines(rows: 6, columns: 30)) == ["row-0", "row-1", "", ""])
    }

    @Test func pagingMovesByTheBodyCapacityAndClamps() {
        var panel = TerminalSubAgentDetailPanel()
        panel.replace(headerRows: ["title", "status"], bodyRows: numberedRows(20), frameRows: 11)
        #expect(panel.bodyCapacity(frameRows: 11) == 6)
        #expect(panel.scrollOffset == 14)

        panel.apply(.pageUp, frameRows: 11)
        #expect(panel.scrollOffset == 8)
        #expect(!panel.isFollowing)
        panel.apply(.pageUp, frameRows: 11)
        panel.apply(.pageUp, frameRows: 11)
        #expect(panel.scrollOffset == 0)
        panel.apply(.pageDown, frameRows: 11)
        #expect(panel.scrollOffset == 6)
        panel.apply(.pageDown, frameRows: 11)
        panel.apply(.pageDown, frameRows: 11)
        #expect(panel.scrollOffset == 14)
        #expect(panel.isFollowing)

        // A frame with no body rows still pages by one row.
        panel.apply(.pageUp, frameRows: 2)
        #expect(panel.scrollOffset == 19)
    }

    @Test func nonScrollingActionsLeaveTheShowingPanelUnchanged() {
        var panel = TerminalSubAgentDetailPanel()
        panel.replace(headerRows: [], bodyRows: numberedRows(10), frameRows: 6)
        panel.apply(.scrollUp, frameRows: 6)
        let before = panel
        for action: TerminalSubAgentDetailAction in [.focusPrevious, .focusNext, .confirm, .close] {
            panel.apply(action, frameRows: 6)
        }
        #expect(panel == before)
    }

    @Test func emptyEntriesAndBodyNeverCrash() {
        var showing = TerminalSubAgentDetailPanel()
        var choosing = TerminalSubAgentDetailPanel(mode: .choosing(entries: [], focusedIndex: 0))
        let choosingBefore = choosing
        for frameRows in [0, 1, 2, 3, 10] {
            for action in Self.allActions {
                showing.apply(action, frameRows: frameRows)
                choosing.apply(action, frameRows: frameRows)
            }
            showing.replace(headerRows: [], bodyRows: [], frameRows: frameRows)
        }
        #expect(showing.scrollOffset == 0)
        #expect(showing.isFollowing)
        #expect(choosing == choosingBefore)
        #expect(plain(choosing.frameLines(rows: 4, columns: 10)) == [
            "╭────────╮", "│        │", "│        │", "╰────────╯"
        ])
    }

    // MARK: - Layout

    @Test func headerTakesAtMostHalfOfTheInteriorRows() {
        let panel = TerminalSubAgentDetailPanel(headerRows: numberedRows(10, prefix: "h"))
        #expect(panel.bodyCapacity(frameRows: 0) == 0)
        #expect(panel.bodyCapacity(frameRows: 2) == 0)
        #expect(panel.bodyCapacity(frameRows: 3) == 1)
        #expect(panel.bodyCapacity(frameRows: 5) == 3)
        #expect(panel.bodyCapacity(frameRows: 6) == 2)
        #expect(panel.bodyCapacity(frameRows: 12) == 5)
        #expect(TerminalSubAgentDetailPanel(headerRows: ["a", "b"]).bodyCapacity(frameRows: 12) == 7)
        #expect(TerminalSubAgentDetailPanel().bodyCapacity(frameRows: 12) == 10)

        let lines = plain(panel.frameLines(rows: 12, columns: 20))
        #expect(lines[1...4].map(content) == ["h-0", "h-1", "h-2", "h-3"])
        #expect(lines[5] == "├" + String(repeating: "─", count: 18) + "┤")
        #expect(lines[6...10].allSatisfy { content($0).isEmpty })

        // Without room for a header row the separator is omitted too.
        #expect(!plain(panel.frameLines(rows: 5, columns: 20)).contains { $0.hasPrefix("├") })
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 9, 24], [5, 6, 13, 40, 120])
    func frameLinesFillExactlyTheRequestedRowsAndColumns(rows: Int, columns: Int) {
        let longRow = TerminalStyle.Accent.primary + String(repeating: "wide 👥 text ", count: 20) + TerminalStyle.reset
        var scrolled = TerminalSubAgentDetailPanel(headerRows: numberedRows(4, prefix: "h"))
        scrolled.replace(headerRows: numberedRows(4, prefix: "h"), bodyRows: numberedRows(60) + [longRow], frameRows: rows)
        scrolled.apply(.pageUp, frameRows: rows)
        let panels = [
            TerminalSubAgentDetailPanel(),
            TerminalSubAgentDetailPanel(headerRows: ["header"]),
            TerminalSubAgentDetailPanel(headerRows: [longRow], bodyRows: numberedRows(60) + [longRow]),
            scrolled,
            TerminalSubAgentDetailPanel(mode: .choosing(entries: [], focusedIndex: 0)),
            TerminalSubAgentDetailPanel(
                mode: .choosing(entries: entries(30), focusedIndex: 17),
                headerRows: ["Choose a sub-agent"]
            )
        ]
        for panel in panels {
            let lines = panel.frameLines(rows: rows, columns: columns)
            #expect(lines.count == rows)
            #expect(lines.allSatisfy { TerminalANSIText.visibleWidth($0) == columns })
        }
    }

    @Test func tinyFramesDrawOnlyTheBorders() {
        let panel = TerminalSubAgentDetailPanel(headerRows: ["header"], bodyRows: numberedRows(3))
        #expect(panel.frameLines(rows: 0, columns: 30).isEmpty)
        #expect(plain(panel.frameLines(rows: 1, columns: 30)).map { String($0.prefix(1)) } == ["╭"])
        #expect(plain(panel.frameLines(rows: 2, columns: 30)).map { String($0.prefix(1)) } == ["╭", "╰"])
        let three = plain(panel.frameLines(rows: 3, columns: 30))
        #expect(three.map { String($0.prefix(1)) } == ["╭", "│", "╰"])
        #expect(content(three[1]) == "row-2")
    }

    @Test func topBorderCarriesTheTitleInTheChromeColor() throws {
        let line = try #require(TerminalSubAgentDetailPanel().frameLines(rows: 3, columns: 30).first)
        #expect(line.hasPrefix(TerminalStyle.Chrome.border + "╭─ 👥 Sub-agent ─"))
        #expect(line.hasSuffix("─╮" + TerminalStyle.reset))
        #expect(TerminalANSIText.visibleWidth(line) == 30)
    }

    @Test func bottomBorderShowsTheVisibleRangeOnlyWhenTheBodyOverflows() {
        var panel = TerminalSubAgentDetailPanel()
        panel.replace(headerRows: [], bodyRows: numberedRows(84), frameRows: 21)
        #expect(panel.bodyCapacity(frameRows: 21) == 19)
        #expect(plain(panel.frameLines(rows: 21, columns: 40)).last?.hasPrefix("╰─ rows 66–84/84 ─") == true)

        panel.apply(.top, frameRows: 21)
        #expect(plain(panel.frameLines(rows: 21, columns: 40)).last?.hasPrefix("╰─ rows 1–19/84 ─") == true)
        for _ in 0..<11 {
            panel.apply(.scrollDown, frameRows: 21)
        }
        let bottom = plain(panel.frameLines(rows: 21, columns: 40)).last
        #expect(bottom?.hasPrefix("╰─ rows 12–30/84 ─") == true)
        #expect(bottom?.hasSuffix("─╯") == true)

        panel.replace(headerRows: ["title", "status"], bodyRows: numberedRows(10), frameRows: 11)
        #expect(plain(panel.frameLines(rows: 11, columns: 40)).last?.hasPrefix("╰─ rows 5–10/10 ─") == true)

        panel.replace(headerRows: [], bodyRows: numberedRows(19), frameRows: 21)
        #expect(plain(panel.frameLines(rows: 21, columns: 40)).last == "╰" + String(repeating: "─", count: 38) + "╯")
        panel.replace(headerRows: [], bodyRows: [], frameRows: 21)
        #expect(plain(panel.frameLines(rows: 21, columns: 40)).last == "╰" + String(repeating: "─", count: 38) + "╯")
    }

    @Test func bodyRowsKeepTheirLeadingIndentation() {
        let panel = TerminalSubAgentDetailPanel(bodyRows: ["    let value = 1", "  - nested", "trailing   "])
        let lines = panel.frameLines(rows: 5, columns: 30)
        #expect(bodyContents(lines) == ["    let value = 1", "  - nested", "trailing"])
        #expect(TerminalANSIText.stripANSI(lines[1]).hasPrefix("│     let value = 1"))
    }

    /// The width of `🛠️` (`U+1F6E0 U+FE0F`) depends on the terminal, so every
    /// interior row must place its right border with an absolute column move.
    @Test(arguments: [5, 13, 30, 80])
    func interiorRowsPlaceTheRightBorderAtAnAbsoluteColumn(columns: Int) throws {
        let toolRow = "🛠️ Bash swift test"
        let panel = TerminalSubAgentDetailPanel(
            headerRows: ["🛠️ header", "status"],
            bodyRows: [toolRow, "plain row", "🛠️"]
        )
        let lines = panel.frameLines(rows: 12, columns: columns)
        let border = TerminalStyle.Chrome.border, reset = TerminalStyle.reset
        let anchor = "\u{1B}[K\u{1B}[\(columns)G"
        let closingBorder = anchor + border + "│" + reset

        #expect(lines.count == 12)
        #expect(lines.allSatisfy { TerminalANSIText.visibleWidth($0) == columns })

        let top = try #require(lines.first)
        let bottom = try #require(lines.last)
        let separator = border + "├"
        let interior = lines.dropFirst().dropLast().filter { !$0.hasPrefix(separator) }
        #expect(interior.count == 9)
        for line in interior {
            #expect(line.hasPrefix(border + "│" + reset + " "))
            #expect(line.hasSuffix(closingBorder))
            #expect(line.ranges(of: anchor).count == 1)
            #expect(TerminalANSIText.visibleWidth(line) == columns)
        }

        // Borders and separator are plain rules: no absolute positioning.
        for line in [top, bottom] + lines.filter({ $0.hasPrefix(separator) }) {
            #expect(!line.contains("\u{1B}[K"))
            #expect(!line.contains("\u{1B}[\(columns)G"))
        }
        // The glyph row really is part of the frame once there is room for it.
        if columns >= 30 {
            #expect(interior.contains { $0.contains("🛠️ Bash swift test") })
            #expect(interior.contains { $0.contains("🛠️ header") })
        }
    }

    // MARK: - Agent choice

    @Test func focusMovesCyclicallyAndOtherActionsLeaveTheListUnchanged() {
        var panel = TerminalSubAgentDetailPanel(mode: .choosing(entries: entries(3), focusedIndex: 0))
        panel.apply(.focusPrevious, frameRows: 10)
        #expect(focusedIndex(panel) == 2)
        panel.apply(.focusNext, frameRows: 10)
        #expect(focusedIndex(panel) == 0)
        panel.apply(.focusNext, frameRows: 10)
        #expect(focusedIndex(panel) == 1)

        let before = panel
        for action: TerminalSubAgentDetailAction in [.scrollUp, .scrollDown, .pageUp, .pageDown, .top, .bottom, .confirm, .close] {
            panel.apply(action, frameRows: 10)
        }
        #expect(panel == before)
    }

    @Test func focusedEntryStaysVisibleInAListLongerThanTheWindow() {
        var panel = TerminalSubAgentDetailPanel(mode: .choosing(entries: entries(20), focusedIndex: 0))
        #expect(panel.bodyCapacity(frameRows: 7) == 5)
        for _ in 0..<15 {
            panel.apply(.focusNext, frameRows: 7)
        }
        var lines = panel.frameLines(rows: 7, columns: 30)
        #expect(bodyContents(lines).contains("▸ agent-15"))
        #expect(lines.contains { $0.contains(TerminalStyle.Accent.primary + "▸ agent-15") })
        #expect(TerminalANSIText.stripANSI(lines[6]).hasPrefix("╰─ rows 14–18/20 ─"))

        for _ in 0..<4 {
            panel.apply(.focusNext, frameRows: 7)
        }
        lines = panel.frameLines(rows: 7, columns: 30)
        #expect(bodyContents(lines).last == "▸ agent-19")

        panel.apply(.focusNext, frameRows: 7)
        lines = panel.frameLines(rows: 7, columns: 30)
        #expect(bodyContents(lines).first == "▸ agent-0")
    }

    @Test func focusedAndUnfocusedEntriesStayAligned() {
        let panel = TerminalSubAgentDetailPanel(mode: .choosing(entries: entries(3), focusedIndex: 1))
        let lines = plain(panel.frameLines(rows: 5, columns: 30))
        #expect(lines[1...3].map { String($0.prefix(4)) } == ["│   ", "│ ▸ ", "│   "])
        #expect(bodyContents(lines) == ["  agent-0", "▸ agent-1", "  agent-2"])
    }
}
