//
//  TerminalANSITextWidthTests.swift
//  ZenCODE
//
//  Validates Unicode cell-width measurement and grapheme-safe truncation in
//  TerminalANSIText. Covers wide emoji symbols used by the TUI (⏳ pending
//  icon, ⌚, ⭐, ✅), CJK/fullwidth, combining marks, skin-tone modifiers,
//  regional flag pairs, keycaps and ZWJ family sequences, plus truncation
//  before / inside / after a grapheme cluster.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("TerminalANSIText Unicode width & truncation")
struct TerminalANSITextWidthTests {

    // MARK: - Cell width of grapheme clusters

    /// Wide default emoji (⏳ ⌚ ✅ …), presentation selectors, CJK/fullwidth,
    /// combining marks, skin tones, flags, keycaps, ZWJ sequences and ANSI
    /// escapes, each measured in terminal cells.
    @Test(arguments: [
        ("⏳", 2), ("⌚", 2), ("⌛", 2), ("⏩", 2), ("⏰", 2), ("⬛", 2), ("⬜", 2), ("⭐", 2), ("🔵", 2),
        ("✅", 2), ("🎉", 2),
        ("✂", 1), ("✂\u{FE0F}", 2), ("⏳\u{FE0E}", 1),
        ("Read ⏳", 7),
        ("中", 2), ("こんにちは", 10), ("Ａ", 2),
        (String(String.UnicodeScalarView([Unicode.Scalar(0x0061)!, Unicode.Scalar(0x0301)!])), 1),
        ("👍🏽", 2), ("ok 👍🏽!", 6),
        ("🇮🇹", 2), ("Flag 🇮🇹", 7),
        ("1️⃣", 2), ("x2️⃣y", 4),
        ("👨‍👩‍👧", 2),
        ("\u{1B}[31mError\u{1B}[0m", 5), ("\u{1B}[1m⏳\u{1B}[0m", 2),
    ] as [(String, Int)])
    func visibleWidthMeasuresGraphemeClustersInTerminalCells(text: String, width: Int) {
        #expect(TerminalANSIText.visibleWidth(text) == width)
    }

    /// Printable ASCII takes a one-byte fast path. ASCII controls and clusters
    /// that only start with an ASCII scalar keep the full measurement.
    @Test
    func printableASCIIIsOneCellAndItsNeighboursKeepTheFullMeasurement() {
        for value in UInt8(0x20)...0x7E {
            let character = Character(Unicode.Scalar(value))
            #expect(TerminalANSIText.visibleWidth(of: character) == 1, "U+00\(String(value, radix: 16))")
        }
        let neighbours: [(Character, Int)] = [
            ("\u{0}", 0), ("\u{1F}", 1), ("\u{7F}", 1), ("\r\n", 1),
            ("#\u{FE0F}\u{20E3}", 2), ("e\u{301}", 1), ("\u{80}", 1), ("é", 1),
        ]
        for (character, width) in neighbours {
            #expect(TerminalANSIText.visibleWidth(of: character) == width)
        }
    }

    // MARK: - Grapheme-safe truncation

    /// Truncation keeps or drops whole graphemes (ZWJ family, skin tone, flag),
    /// leaves fitting text unchanged and collapses tiny budgets to the ellipsis.
    @Test(arguments: [
        ("A👨‍👩‍👧BCDE", 6, "A👨‍👩‍👧BC…"),
        ("A👨‍👩‍👧BCDE", 4, "A👨‍👩‍👧…"),
        ("ok 👍🏽 done", 6, "ok 👍🏽…"),
        ("Flag 🇮🇹 here", 8, "Flag 🇮🇹…"),
        ("⏳ ⌚ ⭐", 100, "⏳ ⌚ ⭐"),
        ("abc", 1, "…"),
        ("abc", 0, "…"),
    ] as [(String, Int, String)])
    func truncateKeepsWholeGraphemesWithinTheBudget(text: String, width: Int, expected: String) {
        let result = TerminalANSIText.truncate(text, to: width)
        #expect(result == expected)
        #expect(TerminalANSIText.visibleWidth(result) <= max(width, 1))
    }

    @Test
    func truncateNeverSplitsAGraphemeWhoseSpanStraddlesTheBoundary() {
        // Width 3: maxContent 2. After 'A' (1), the 2-column family would land
        // its second column beyond the budget. It must be dropped WHOLE rather
        // than split — the result must contain no dangling skin tone, ZWJ or
        // lone regional indicator.
        let family = "👨‍👩‍👧"
        let text = "A" + family + "B"
        let result = TerminalANSIText.truncate(text, to: 3)
        #expect(result == "A…")
        #expect(TerminalANSIText.visibleWidth(result) == 2)
        // No partial grapheme leaks: zero-width joiner must never appear alone.
        #expect(!result.contains("\u{200D}"))
    }

    @Test
    func truncatePreservesAnsiStyleAndEmitsReset() {
        let text = "\u{1B}[31m" + "⏳ running long status line" + "\u{1B}[0m"
        let result = TerminalANSIText.truncate(text, to: 8)
        #expect(result.hasPrefix("\u{1B}[31m"))
        #expect(result.hasSuffix("\u{1B}[0m"))
        #expect(result.contains("…"))
        // Measured width honours the budget despite embedded escapes.
        #expect(TerminalANSIText.visibleWidth(result) <= 8)
    }

    @Test
    func truncateClosesOpenOSC8HyperlinkWithSTTerminator() {
        let opener = "\u{1B}]8;;https://example.com\u{1B}\\"
        let closure = "\u{1B}]8;;\u{1B}\\"
        let result = TerminalANSIText.truncate(opener + "abcdef" + closure, to: 4)

        #expect(result == opener + "abc…" + closure)
        #expect(TerminalANSIText.stripANSI(result) == "abc…")
        #expect(TerminalANSIText.visibleWidth(result) == 4)
    }

    @Test
    func truncateClosesOpenOSC8HyperlinkWithBELTerminatorAndRetainsSGRReset() {
        let opener = "\u{1B}]8;;https://example.com\u{07}"
        let closure = "\u{1B}]8;;\u{07}"
        let red = "\u{1B}[31m"
        let reset = "\u{1B}[0m"
        let result = TerminalANSIText.truncate(red + opener + "abcdef" + closure + reset, to: 4)

        #expect(result == red + opener + "abc…" + closure + reset)
        #expect(TerminalANSIText.stripANSI(result) == "abc…")
        #expect(TerminalANSIText.visibleWidth(result) == 4)
    }

    // MARK: - Wrap is not regressed by wide graphemes

    @Test
    func wrapHandlesWideEmojiWithoutCorruption() {
        // A line mixing ASCII and wide emoji must still wrap on spaces and keep
        // every row within the requested width budget.
        let line = "status ⏳ pending review 🇮🇹 done"
        let wrapped = TerminalANSIText.wrap(line, width: 12)
        let rows = wrapped.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        #expect(rows.count > 1)
        #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) <= 12 })
        // Round-trip: the original words survive the reflow.
        #expect(wrapped.contains("pending"))
        #expect(wrapped.contains("review"))
    }

    @Test
    func whitespacePreservingWrapSplitsLongUnbrokenTokens() {
        let source = String(repeating: "x", count: 25)
        let rows = TerminalANSIText.wrapPreservingWhitespace(source, width: 8)

        #expect(rows.count == 4)
        #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) <= 8 })
        #expect(rows.joined() == source)
    }

    @Test
    func truncateWithEmptyEllipsisUsesTheWholeWidthBudget() {
        let result = TerminalANSIText.truncate(
            "漢字abc",
            to: 5,
            ellipsis: "",
            ellipsisWidth: 0
        )

        #expect(result == "漢字a")
        #expect(TerminalANSIText.visibleWidth(result) == 5)
    }

    @Test
    func widthAwareWrapPreservesANSIAndBoundsCJKRows() {
        let styled = "\u{1B}[31m漢字漢字漢字\u{1B}[0m"
        let rows = TerminalANSIText.wrapPreservingWhitespace(
            styled,
            width: 6
        )

        #expect(rows.count == 2)
        #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) <= 6 })
        #expect(TerminalANSIText.stripANSI(rows.joined()) == "漢字漢字漢字")
    }

    @Test
    func whitespacePreservingWrapFitsHangingIndentBeforeWideContinuationGlyph() {
        let rows = TerminalANSIText.wrapPreservingWhitespace(
            "abcde😀x",
            width: 5,
            hangingIndent: "    "
        )

        #expect(rows == ["abcde", "   😀", "    x"])
        #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) <= 5 })
    }
}
