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
        .focusPrevious, .focusNext, .confirm, .close, .closeList
    ]

    private func numberedRows(_ count: Int, prefix: String = "row") -> [String] {
        (0..<count).map { "\(prefix)-\($0)" }
    }

    private func entries(_ count: Int) -> [TerminalSubAgentDetailPanel.ChoiceEntry] {
        (0..<count).map { .init(id: "id-\($0)", title: "agent-\($0)") }
    }

    /// One entry per element of `detailCounts`: `agent-i`, with
    /// `detailCounts[i]` detail rows `detail-i-j`.
    private func blockEntries(_ detailCounts: [Int]) -> [TerminalSubAgentDetailPanel.ChoiceEntry] {
        detailCounts.enumerated().map { index, count in
            .init(
                id: "id-\(index)",
                title: "agent-\(index)",
                details: (0..<count).map { "detail-\(index)-\($0)" }
            )
        }
    }

    /// The plain rows the list draws for `entries[range]`, one block after
    /// the other: the title behind `▸ ` or two spaces, the details behind
    /// `┃   ` or four spaces.
    private func blockRows(
        _ entries: [TerminalSubAgentDetailPanel.ChoiceEntry],
        _ range: ClosedRange<Int>,
        focusedIndex: Int
    ) -> [String] {
        range.flatMap { index in
            let isFocused = index == focusedIndex
            return [(isFocused ? "▸ " : "  ") + entries[index].title]
                + entries[index].details.map { (isFocused ? "┃   " : "    ") + $0 }
        }
    }

    private func plainBottomBorder(columns: Int) -> String {
        "╰" + String(repeating: "─", count: columns - 2) + "╯"
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
        #expect(lines[1...5].allSatisfy { content($0).isEmpty })
        #expect(lines[6] == "├" + String(repeating: "─", count: 18) + "┤")
        #expect(lines[7...10].map(content) == ["h-0", "h-1", "h-2", "h-3"])

        // Without room for a header row the separator is omitted too.
        #expect(!plain(panel.frameLines(rows: 5, columns: 20)).contains { $0.hasPrefix("├") })
    }

    @Test func headerStaysBelowBodyAndPaddingWhileBodyScrolls() {
        let separator = "├" + String(repeating: "─", count: 28) + "┤"
        var panel = TerminalSubAgentDetailPanel(title: "", headerRows: ["header-1", "header-2"], bodyRows: numberedRows(2))
        let short = plain(panel.frameLines(rows: 9, columns: 30))
        #expect(short[0] == "╭" + String(repeating: "─", count: 28) + "╮")
        #expect(short[1...4].map(content) == ["row-0", "row-1", "", ""])
        #expect(short[5] == separator)
        #expect(short[6...7].map(content) == ["header-1", "header-2"])
        #expect(short[8] == plainBottomBorder(columns: 30))

        panel.replace(headerRows: ["header-1", "header-2"], bodyRows: numberedRows(8), frameRows: 9)
        let following = plain(panel.frameLines(rows: 9, columns: 30))
        #expect(following[1...4].map(content) == ["row-4", "row-5", "row-6", "row-7"])
        #expect(following[5...7] == short[5...7])
        #expect(following[8].contains("rows 5–8/8"))

        panel.apply(.top, frameRows: 9)
        let scrolled = plain(panel.frameLines(rows: 9, columns: 30))
        #expect(scrolled[1...4].map(content) == ["row-0", "row-1", "row-2", "row-3"])
        #expect(scrolled[5...7] == short[5...7])
        #expect(scrolled[8].contains("rows 1–4/8"))
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 9, 24], [5, 6, 13, 40, 120])
    func frameLinesFillExactlyTheRequestedRowsAndColumns(rows: Int, columns: Int) {
        let longRow = TerminalStyle.Accent.primary + String(repeating: "wide 👥 text ", count: 20) + TerminalStyle.reset
        let wideEntry = TerminalSubAgentDetailPanel.ChoiceEntry(id: "wide", title: longRow, details: [longRow, longRow])
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
            ),
            TerminalSubAgentDetailPanel(
                mode: .choosing(entries: blockEntries([2, 0, 1, 2, 2, 0, 1]) + [wideEntry], focusedIndex: 7)
            ),
            TerminalSubAgentDetailPanel(mode: .choosing(entries: [wideEntry], focusedIndex: 0))
        ]
        for panel in panels {
            let lines = panel.frameLines(rows: rows, columns: columns)
            #expect(lines.count == rows)
            #expect(lines.allSatisfy { TerminalANSIText.visibleWidth($0) == columns })
            // The badge and the help never change the frame's size.
            for border in [
                TerminalSubAgentDetailPanel.BorderStatus(help: TerminalChat.subAgentDetailPanelOverride.helpText),
                .init(unreadSharedChatCount: 12, help: TerminalChat.subAgentListPanelOverride.helpText),
                .init(unreadSharedChatCount: 1)
            ] {
                let framed = panel.frameLines(rows: rows, columns: columns, border: border)
                #expect(framed.count == rows)
                #expect(framed.allSatisfy { TerminalANSIText.visibleWidth($0) == columns })
                #expect(Array(framed.dropLast()) == Array(lines.dropLast()))
            }
        }
    }

    @Test func theTopBorderCarriesTheTitleOfThePanel() {
        func top(_ title: String, columns: Int) -> String {
            "╭─" + title + String(repeating: "─", count: columns - 3 - TerminalANSIText.visibleWidth(title)) + "╮"
        }
        let subAgent = TerminalSubAgentDetailPanel(bodyRows: numberedRows(1))
        #expect(subAgent.title == TerminalSubAgentDetailPanel.subAgentTitle)
        #expect(plain(subAgent.frameLines(rows: 4, columns: 30)).first == top(" 👥 Sub-agent ", columns: 30))

        let artifacts = TerminalSubAgentDetailPanel(
            mode: .choosing(entries: entries(2), focusedIndex: 0),
            title: " 🪬 Artifacts ",
            bodyRows: numberedRows(1)
        )
        let lines = plain(artifacts.frameLines(rows: 6, columns: 30))
        #expect(lines.first == top(" 🪬 Artifacts ", columns: 30))
        // Only the label changes: the list is drawn as in the sub-agent panel.
        var sameList = artifacts
        sameList.title = TerminalSubAgentDetailPanel.subAgentTitle
        #expect(Array(lines.dropFirst()) == Array(plain(sameList.frameLines(rows: 6, columns: 30)).dropFirst()))
        // A label too wide for the frame leaves the plain rule.
        #expect(plain(artifacts.frameLines(rows: 3, columns: 12)).first == "╭" + String(repeating: "─", count: 10) + "╮")
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

    @Test func bottomBorderShowsTheVisibleRangeOnlyWhenTheBodyOverflows() {
        var panel = TerminalSubAgentDetailPanel()
        panel.replace(headerRows: [], bodyRows: numberedRows(84), frameRows: 21)
        #expect(panel.bodyCapacity(frameRows: 21) == 19)
        #expect(plain(panel.frameLines(rows: 21, columns: 40)).last?.hasSuffix("─ rows 66–84/84 ─╯") == true)

        panel.apply(.top, frameRows: 21)
        #expect(plain(panel.frameLines(rows: 21, columns: 40)).last?.hasSuffix("─ rows 1–19/84 ─╯") == true)
        for _ in 0..<11 {
            panel.apply(.scrollDown, frameRows: 21)
        }
        let bottom = plain(panel.frameLines(rows: 21, columns: 40)).last
        #expect(bottom?.hasSuffix("─ rows 12–30/84 ─╯") == true)
        #expect(bottom?.hasPrefix("╰──") == true)

        panel.replace(headerRows: ["title", "status"], bodyRows: numberedRows(10), frameRows: 11)
        #expect(plain(panel.frameLines(rows: 11, columns: 40)).last?.hasSuffix("─ rows 5–10/10 ─╯") == true)

        panel.replace(headerRows: [], bodyRows: numberedRows(19), frameRows: 21)
        #expect(plain(panel.frameLines(rows: 21, columns: 40)).last == "╰" + String(repeating: "─", count: 38) + "╯")
        panel.replace(headerRows: [], bodyRows: [], frameRows: 21)
        #expect(plain(panel.frameLines(rows: 21, columns: 40)).last == "╰" + String(repeating: "─", count: 38) + "╯")
    }

    // MARK: - Bottom border: help, badge and indicator

    /// The bottom border of `columns` with `text` on its left and
    /// `indicator` on its right, as the panel draws it.
    private func bottomBorder(_ text: String?, indicator: String?, columns: Int) -> String {
        let leading = text.map { "─ " + $0 + " " } ?? ""
        let trailing = indicator.map { $0 + "─" } ?? ""
        let fill = columns - 2 - TerminalANSIText.visibleWidth(leading) - TerminalANSIText.visibleWidth(trailing)
        return "╰" + leading + String(repeating: "─", count: fill) + trailing + "╯"
    }

    /// The help of the mode goes on the left of the bottom border, the
    /// unread badge before it, and the indicator stays on the right.
    @Test func theBottomBorderSaysTheBadgeAndTheHelpLeftOfTheIndicator() {
        let help = TerminalChat.subAgentDetailPanelOverride.helpText
        var panel = TerminalSubAgentDetailPanel()
        panel.replace(headerRows: [], bodyRows: numberedRows(84), frameRows: 21)

        let withHelp = plain(panel.frameLines(rows: 21, columns: 70, border: .init(help: help))).last
        #expect(withHelp == "╰─ ↑↓ PgUp PgDn Home End scroll · Esc close " + String(repeating: "─", count: 9)
            + " rows 66–84/84 ─╯")

        let withBadge = plain(panel.frameLines(
            rows: 21, columns: 90, border: .init(unreadSharedChatCount: 2, help: help)
        )).last
        #expect(withBadge == bottomBorder("Chat: 2 new · " + help, indicator: " rows 66–84/84 ", columns: 90))
        #expect(withBadge?.hasPrefix("╰─ Chat: 2 new · ↑↓ PgUp") == true)

        // No unread message, no badge; nothing to say, the plain border.
        #expect(plain(panel.frameLines(rows: 21, columns: 90, border: .init(unreadSharedChatCount: 0, help: help))).last
            == bottomBorder(help, indicator: " rows 66–84/84 ", columns: 90))
        #expect(plain(panel.frameLines(rows: 21, columns: 90, border: .init())).last
            == plain(panel.frameLines(rows: 21, columns: 90)).last)

        // Without an indicator the text stays on the left of a plain rule.
        panel.replace(headerRows: [], bodyRows: numberedRows(5), frameRows: 21)
        #expect(plain(panel.frameLines(rows: 21, columns: 60, border: .init(unreadSharedChatCount: 1, help: help))).last
            == bottomBorder("Chat: 1 new · " + help, indicator: nil, columns: 60))

        // The list says its own keys, next to its `a–b/n` indicator.
        let list = TerminalSubAgentDetailPanel(mode: .choosing(entries: entries(30), focusedIndex: 0))
        let listHelp = TerminalChat.subAgentListPanelOverride.helpText
        #expect(plain(list.frameLines(rows: 7, columns: 60, border: .init(help: listHelp))).last
            == bottomBorder("↑↓ choose · Enter open · Esc close", indicator: " 1–5/30 ", columns: 60))
    }

    /// The indicator wins the width; the text takes what is left with one
    /// `─` on each side: first the help drops its segments from the left, so
    /// `Esc close` is the last to go, then the help goes, then the badge.
    @Test(arguments: [
        (76, "Chat: 3 new · ↑↓ PgUp PgDn Home End scroll · Esc close"),
        (75, "Chat: 3 new · Esc close"),
        (45, "Chat: 3 new · Esc close"),
        (44, "Chat: 3 new"),
        (33, "Chat: 3 new"),
        (32, "Esc close"),
        (31, "Esc close"),
        (30, nil),
        (19, nil),
    ] as [(Int, String?)])
    func theIndicatorWinsTheWidthAndTheTextShortensByPriority(columns: Int, text: String?) {
        var panel = TerminalSubAgentDetailPanel()
        panel.replace(headerRows: [], bodyRows: numberedRows(84), frameRows: 21)
        let border = TerminalSubAgentDetailPanel.BorderStatus(
            unreadSharedChatCount: 3,
            help: TerminalChat.subAgentDetailPanelOverride.helpText
        )
        let bottom = plain(panel.frameLines(rows: 21, columns: columns, border: border)).last
        #expect(bottom == bottomBorder(text, indicator: " rows 66–84/84 ", columns: columns))
        #expect(bottom.map(TerminalANSIText.visibleWidth) == columns)
    }

    /// Without the indicator (it does not fit, or the body does) the text
    /// has the whole border; the list's help shortens the same way.
    @Test func withoutTheIndicatorTheTextTakesTheWholeBorder() {
        let listHelp = TerminalChat.subAgentListPanelOverride.helpText
        typealias Panel = TerminalSubAgentDetailPanel
        #expect(Panel.borderText(.init(help: listHelp), width: 40) == "↑↓ choose · Enter open · Esc close")
        #expect(Panel.borderText(.init(help: listHelp), width: 33) == "Enter open · Esc close")
        #expect(Panel.borderText(.init(help: listHelp), width: 21) == "Esc close")
        #expect(Panel.borderText(.init(help: listHelp), width: 8) == nil)
        #expect(Panel.borderText(.init(unreadSharedChatCount: 4, help: listHelp), width: 20) == "Chat: 4 new")
        #expect(Panel.borderText(.init(unreadSharedChatCount: 4), width: 11) == "Chat: 4 new")
        #expect(Panel.borderText(.init(unreadSharedChatCount: 4), width: 10) == nil)
        #expect(Panel.borderText(.init(help: "  "), width: 40) == nil)
        #expect(Panel.borderText(.init(), width: 40) == nil)
        #expect(Panel.borderText(.init(help: listHelp), width: 0) == nil)

        // An indicator wider than the frame is dropped, as before, and the
        // badge takes the room.
        var panel = TerminalSubAgentDetailPanel()
        panel.replace(headerRows: [], bodyRows: numberedRows(84), frameRows: 21)
        let border = TerminalSubAgentDetailPanel.BorderStatus(unreadSharedChatCount: 3)
        #expect(plain(panel.frameLines(rows: 21, columns: 18, border: border)).last
            == bottomBorder("Chat: 3 new", indicator: nil, columns: 18))
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
        for action: TerminalSubAgentDetailAction in [
            .scrollUp, .scrollDown, .pageUp, .pageDown, .top, .bottom, .confirm, .close, .closeList
        ] {
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
        #expect(bodyContents(lines) == ["  agent-13", "  agent-14", "▸ agent-15", "  agent-16", "  agent-17"])
        #expect(lines.contains { $0.contains(TerminalStyle.Accent.primary + "▸ agent-15") })
        // The list's indicator counts entries, not rows.
        #expect(TerminalANSIText.stripANSI(lines[6]).hasSuffix("─ 14–18/20 ─╯"))

        for _ in 0..<4 {
            panel.apply(.focusNext, frameRows: 7)
        }
        lines = panel.frameLines(rows: 7, columns: 30)
        #expect(bodyContents(lines).last == "▸ agent-19")

        panel.apply(.focusNext, frameRows: 7)
        lines = panel.frameLines(rows: 7, columns: 30)
        #expect(bodyContents(lines).first == "▸ agent-0")
        #expect(TerminalANSIText.stripANSI(lines[6]).hasSuffix("─ 1–5/20 ─╯"))
    }

    // MARK: - Multi-row entries

    @Test func entriesAreBlocksOneBlankRowApartWhenTheWholeListFits() {
        var panel = TerminalSubAgentDetailPanel(mode: .choosing(entries: blockEntries([2, 1, 0]), focusedIndex: 0))
        // 3 + 2 + 1 rows and the two blank rows between them fill a body of 8.
        #expect(panel.bodyCapacity(frameRows: 10) == 8)
        var lines = panel.frameLines(rows: 10, columns: 40)
        #expect(bodyContents(lines) == [
            "▸ agent-0", "┃   detail-0-0", "┃   detail-0-1", "",
            "  agent-1", "    detail-1-0", "",
            "  agent-2"
        ])
        // The focused block stands out on every row, the others carry no accent.
        let accent = TerminalStyle.Accent.primary, reset = TerminalStyle.reset
        #expect(lines[1].contains(accent + "▸ agent-0" + reset))
        #expect(lines[2].contains(accent + "┃" + reset + "   detail-0-0"))
        #expect(lines[3].contains(accent + "┃" + reset + "   detail-0-1"))
        #expect(lines[4...8].allSatisfy { !$0.contains(accent) })
        // Every entry is shown: no indicator.
        #expect(plain(lines).last == plainBottomBorder(columns: 40))

        panel.apply(.focusNext, frameRows: 10)
        lines = panel.frameLines(rows: 10, columns: 40)
        #expect(bodyContents(lines) == [
            "  agent-0", "    detail-0-0", "    detail-0-1", "",
            "▸ agent-1", "┃   detail-1-0", "",
            "  agent-2"
        ])
        #expect(lines[5].contains(accent + "▸ agent-1" + reset))
        #expect(lines[6].contains(accent + "┃" + reset + "   detail-1-0"))
    }

    @Test func theBlankRowsAreOmittedWhenTheyDoNotFit() {
        let entries = blockEntries([1, 1, 1])
        let panel = TerminalSubAgentDetailPanel(mode: .choosing(entries: entries, focusedIndex: 2))
        // The 6 rows of the entries fit a body of 7, their 2 blank rows do not.
        let lines = panel.frameLines(rows: 9, columns: 40)
        #expect(bodyContents(lines) == blockRows(entries, 0...2, focusedIndex: 2) + [""])
        #expect(plain(lines).last == plainBottomBorder(columns: 40))

        // One more row fits the blank rows too.
        #expect(bodyContents(panel.frameLines(rows: 10, columns: 40)) == [
            "  agent-0", "    detail-0-0", "",
            "  agent-1", "    detail-1-0", "",
            "▸ agent-2", "┃   detail-2-0"
        ])
    }

    @Test func theWindowShowsOnlyWholeEntriesAroundTheFocus() {
        // Blocks of 3, 1, 3, 1 and 3 rows in a body of 7.
        let entries = blockEntries([2, 0, 2, 0, 2])
        var panel = TerminalSubAgentDetailPanel(mode: .choosing(entries: entries, focusedIndex: 2))
        #expect(panel.bodyCapacity(frameRows: 9) == 7)
        var lines = panel.frameLines(rows: 9, columns: 40)
        #expect(bodyContents(lines) == [
            "  agent-1", "▸ agent-2", "┃   detail-2-0", "┃   detail-2-1", "  agent-3", "", ""
        ])
        #expect(plain(lines).last?.hasSuffix("─ 2–4/5 ─╯") == true)

        // Whatever the focus, the window is a run of whole blocks around it,
        // and the indicator names exactly those entries, 1-based.
        let expectedRanges: [ClosedRange<Int>] = [0...2, 0...2, 1...3, 2...4, 2...4]
        for focus in entries.indices {
            panel.mode = .choosing(entries: entries, focusedIndex: focus)
            lines = panel.frameLines(rows: 9, columns: 40)
            let range = expectedRanges[focus]
            let shown = blockRows(entries, range, focusedIndex: focus)
            #expect(bodyContents(lines) == shown + Array(repeating: "", count: 7 - shown.count))
            #expect(plain(lines).last?.hasSuffix("─ \(range.lowerBound + 1)–\(range.upperBound + 1)/5 ─╯") == true)
        }
    }

    @Test func aBodyShorterThanTheFocusedEntryShowsItsFirstRows() {
        let panel = TerminalSubAgentDetailPanel(mode: .choosing(entries: blockEntries([0, 3, 0]), focusedIndex: 1))
        var lines = panel.frameLines(rows: 4, columns: 30)
        #expect(bodyContents(lines) == ["▸ agent-1", "┃   detail-1-0"])
        #expect(plain(lines).last?.hasSuffix("─ 2–2/3 ─╯") == true)
        lines = panel.frameLines(rows: 3, columns: 30)
        #expect(bodyContents(lines) == ["▸ agent-1"])
        // A body exactly as tall as the focused block shows that block alone.
        lines = panel.frameLines(rows: 6, columns: 30)
        #expect(bodyContents(lines) == ["▸ agent-1", "┃   detail-1-0", "┃   detail-1-1", "┃   detail-1-2"])
        #expect(plain(lines).last?.hasSuffix("─ 2–2/3 ─╯") == true)
        // A single entry cut by the body has nothing else to count.
        let single = TerminalSubAgentDetailPanel(mode: .choosing(entries: blockEntries([3]), focusedIndex: 0))
        #expect(plain(single.frameLines(rows: 4, columns: 30)).last == plainBottomBorder(columns: 30))
    }

    @Test(arguments: [5, 8, 12, 20, 40])
    func everyListRowIsTruncatedToTheFrameWidth(columns: Int) {
        let muted = TerminalStyle.Text.muted, reset = TerminalStyle.reset
        let profile = muted + "agent:" + reset + " " + String(repeating: "Reviewer of the change ", count: 6)
        let entries: [TerminalSubAgentDetailPanel.ChoiceEntry] = [
            .init(
                id: "agent-1",
                title: "worker " + muted + "agent-with-a-rather-long-identifier" + reset,
                details: [profile, muted + "model:" + reset + " GPT-5"]
            ),
            .init(id: "agent-2", title: "reviewer", details: [profile])
        ]
        let panel = TerminalSubAgentDetailPanel(mode: .choosing(entries: entries, focusedIndex: 0))
        let lines = panel.frameLines(rows: 12, columns: columns)
        #expect(lines.count == 12)
        #expect(lines.allSatisfy { TerminalANSIText.visibleWidth($0) == columns })
        let rows = bodyContents(lines)
        #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) <= columns - 4 })
        if columns >= 40 {
            // A cut row keeps its marker and its indentation.
            #expect(rows[0].hasPrefix("▸ worker agent-with"))
            #expect(rows[1].hasPrefix("┃   agent: Reviewer of"))
            #expect(rows[1].hasSuffix("..."))
            #expect(rows[2] == "┃   model: GPT-5")
            #expect(rows[5].hasPrefix("    agent: Reviewer of"))
            #expect(rows[5].hasSuffix("..."))
        }
    }
}
