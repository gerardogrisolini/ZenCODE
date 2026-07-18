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

import Testing
@testable import ZenCODECore

@Suite("TerminalANSIText Unicode width & truncation")
struct TerminalANSITextWidthTests {

    // MARK: - Wide emoji symbols (East Asian Width = W, default emoji)

    @Test
    func pendingHourglassIsWide() {
        // ⏳ U+23F3 is the standard pending status icon used across the TUI.
        #expect(TerminalANSIText.visibleWidth("⏳") == 2)
    }

    @Test
    func wideSymbolRangeIsDoubleWidth() {
        // ⌚ ⌛ ⏩ ⏰ ⬛ ⬜ ⭐ 🔵 — all East Asian Width = W, default emoji.
        #expect(TerminalANSIText.visibleWidth("⌚") == 2)
        #expect(TerminalANSIText.visibleWidth("⌛") == 2)
        #expect(TerminalANSIText.visibleWidth("⏩") == 2)
        #expect(TerminalANSIText.visibleWidth("⏰") == 2)
        #expect(TerminalANSIText.visibleWidth("⬛") == 2)
        #expect(TerminalANSIText.visibleWidth("⬜") == 2)
        #expect(TerminalANSIText.visibleWidth("⭐") == 2)
        #expect(TerminalANSIText.visibleWidth("🔵") == 2)
    }

    @Test
    func checkmarkAndDenseEmojiAreWide() {
        // ✅ U+2705 sits in the 0x2600–0x27BF block; 🎉 in the emoji block.
        #expect(TerminalANSIText.visibleWidth("✅") == 2)
        #expect(TerminalANSIText.visibleWidth("🎉") == 2)
    }

    @Test
    func symbolPresentationSelectorsControlWidthWithoutChangingDefaultEmoji() {
        // U+2702 is emoji-capable but text-presentation by default. It becomes
        // wide only with VS16. Conversely, the default-emoji hourglass becomes
        // narrow when VS15 explicitly requests text presentation.
        #expect(TerminalANSIText.visibleWidth("✂") == 1)
        #expect(TerminalANSIText.visibleWidth("✂\u{FE0F}") == 2)
        #expect(TerminalANSIText.visibleWidth("⏳") == 2)
        #expect(TerminalANSIText.visibleWidth("⏳\u{FE0E}") == 1)
    }

    @Test
    func wideSymbolsCombineWithAsciiCorrectly() {
        // "Read ⏳" = 4 (Read) + 1 (space) + 2 (⏳) = 7.
        #expect(TerminalANSIText.visibleWidth("Read ⏳") == 7)
    }

    // MARK: - CJK / fullwidth

    @Test
    func cjkCharactersAreDoubleWidth() {
        #expect(TerminalANSIText.visibleWidth("中") == 2)
        #expect(TerminalANSIText.visibleWidth("こんにちは") == 10)
        // Fullwidth Latin "Ａ" U+FF21.
        #expect(TerminalANSIText.visibleWidth("Ａ") == 2)
    }

    // MARK: - Combining marks

    @Test
    func combiningMarkDoesNotAddWidth() {
        // Build a decomposed grapheme at runtime so Swift does not NFC-fold it.
        let decomposed = String(String.UnicodeScalarView([
            Unicode.Scalar(0x0061)!,  // 'a'
            Unicode.Scalar(0x0301)!   // combining acute accent
        ]))
        #expect(TerminalANSIText.visibleWidth(decomposed) == 1)
    }

    // MARK: - Emoji with skin-tone modifier

    @Test
    func skinToneEmojiCountsAsOneWideGrapheme() {
        // 👍🏽 = thumbs up + medium skin tone: one grapheme, width 2.
        #expect(TerminalANSIText.visibleWidth("👍🏽") == 2)
        // The skin-tone modifier must never be counted on its own.
        #expect(TerminalANSIText.visibleWidth("ok 👍🏽!") == 6)  // o,k,space,emoji,!
    }

    // MARK: - Regional flag pairs

    @Test
    func regionalFlagIsOneWideGrapheme() {
        #expect(TerminalANSIText.visibleWidth("🇮🇹") == 2)
        #expect(TerminalANSIText.visibleWidth("Flag 🇮🇹") == 7)  // F,l,a,g,space,flag
    }

    // MARK: - Keycap sequences

    @Test
    func keycapIsOneWideGrapheme() {
        // 1️⃣ = '1' + VS16 + combining enclosing keycap: one grapheme, width 2.
        #expect(TerminalANSIText.visibleWidth("1️⃣") == 2)
        #expect(TerminalANSIText.visibleWidth("x2️⃣y") == 4)
    }

    // MARK: - ZWJ family sequence

    @Test
    func zwjFamilyIsOneWideGrapheme() {
        // 👨‍👩‍👧 (man, ZWJ, woman, ZWJ, girl): one grapheme, width 2 — never split.
        #expect(TerminalANSIText.visibleWidth("👨‍👩‍👧") == 2)
    }

    // MARK: - ANSI escapes are ignored

    @Test
    func ansiEscapeSequencesDoNotCountAsWidth() {
        let styled = "\u{1B}[31mError\u{1B}[0m"
        #expect(TerminalANSIText.visibleWidth(styled) == 5)
        // ANSI around a wide emoji still measures the emoji only.
        let emojiStyled = "\u{1B}[1m⏳\u{1B}[0m"
        #expect(TerminalANSIText.visibleWidth(emojiStyled) == 2)
    }

    // MARK: - Grapheme-safe truncation

    @Test
    func truncateKeepsGraphemeBeforeTheCut() {
        // "A👨‍👩‍👧BCDE" widths: 1 + 2 + 1 + 1 + 1 + 1 = 7.
        let text = "A👨‍👩‍👧BCDE"
        // Width 6: cut after the family + B (maxContent 5): "A👨‍👩‍👧BC…".
        let kept = TerminalANSIText.truncate(text, to: 6)
        #expect(kept == "A👨‍👩‍👧BC…")
        #expect(TerminalANSIText.visibleWidth(kept) == 6)
    }

    @Test
    func truncateDropsGraphemeThatStartsBeforeTheBoundary() {
        // Width 4: maxContent 3 → A (1) + family (2) = 3 fits, B would exceed.
        let text = "A👨‍👩‍👧BCDE"
        let result = TerminalANSIText.truncate(text, to: 4)
        #expect(result == "A👨‍👩‍👧…")
        #expect(TerminalANSIText.visibleWidth(result) == 4)
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
    func truncateDoesNotLeaveDanglingSkinTone() {
        // Boundary falls inside the skin-tone emoji: the whole 👍🏽 must be kept
        // or dropped, never a bare modifier.
        let text = "ok 👍🏽 done"
        // Width 6: maxContent 5 → o,k,space,👍🏽(2) = 5.
        let result = TerminalANSIText.truncate(text, to: 6)
        #expect(result == "ok 👍🏽…")
        #expect(TerminalANSIText.visibleWidth(result) == 6)
    }

    @Test
    func truncateKeepsFlagIntact() {
        let text = "Flag 🇮🇹 here"
        // Width 8: maxContent 7 → F,l,a,g,space,flag(2) = 7.
        let result = TerminalANSIText.truncate(text, to: 8)
        #expect(result == "Flag 🇮🇹…")
        #expect(TerminalANSIText.visibleWidth(result) == 8)
    }

    @Test
    func truncateReturnsTextUnchangedWhenItFits() {
        let text = "⏳ ⌚ ⭐"
        #expect(TerminalANSIText.truncate(text, to: 100) == text)
    }

    @Test
    func truncateOfShortWidthCollapsesToEllipsis() {
        #expect(TerminalANSIText.truncate("abc", to: 1) == "…")
        #expect(TerminalANSIText.truncate("abc", to: 0) == "…")
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
