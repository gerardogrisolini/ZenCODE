//
//  TerminalChatRenderingTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 29/05/26.
//

import Foundation
import Markdown
import Testing
@testable import ZenCODECore

@ChatSessionActor
@Suite
struct TerminalChatRenderingTests {

    @Test
    func chatLineInsetIsAppliedOnlyAtLineStarts() {
        var state = TerminalChatTextFormatting.ChatLineInsetState(isAtLineStart: true)
        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "ciao\nmondo",
                prefix: " ",
                state: &state
            ) == " ciao\n mondo"
        )
        #expect(state.isAtLineStart == false)

        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "!",
                prefix: " ",
                state: &state
            ) == "!"
        )
        #expect(state.isAtLineStart == false)

        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "\nOK",
                prefix: " ",
                state: &state
            ) == "\n OK"
        )
    }

    @Test
    func chatSpacingNormalizationLimitsVisibleBlankRowsAcrossWrites() {
        var state = TerminalChatTextFormatting.ChatSpacingState()

        let first = TerminalChatTextFormatting.chatSpacingNormalized(
            "Thinking\n\n",
            state: &state
        )
        let second = TerminalChatTextFormatting.chatSpacingNormalized(
            "\n🛠️  Read\n\n\nNext",
            state: &state
        )

        #expect(first == "Thinking\n\n")
        #expect(second == "🛠️  Read\n\nNext")
        #expect(!("\(first)\(second)".contains("\n\n\n")))
        #expect(state.trailingNewlineCount == 0)
    }

    @Test
    func chatSpacingTreatsCRLFAsOneBoundaryAndCapsBlankRows() {
        var state = TerminalChatTextFormatting.ChatSpacingState()

        let first = TerminalChatTextFormatting.chatSpacingNormalized(
            "Thinking\r\n\r\n",
            state: &state
        )
        let overflow = TerminalChatTextFormatting.chatSpacingNormalized(
            "\r\nNext",
            state: &state
        )

        #expect(first == "Thinking\r\n\r\n")
        #expect(overflow == "Next")
        #expect(!("\(first)\(overflow)".contains("\r\n\r\n\r\n")))
        #expect(state.trailingNewlineCount == 0)
    }

    @Test
    func chatLineInsetRecognizesCRLFAcrossStreamingDeltas() {
        var state = TerminalChatTextFormatting.ChatLineInsetState(
            isAtLineStart: false
        )

        let first = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "before\r",
            prefix: " ",
            state: &state
        )
        let second = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\nafter",
            prefix: " ",
            state: &state
        )

        #expect(first == "before\r")
        #expect(second == "\n after")
        #expect(!state.isAtLineStart)
    }

    @Test
    func chatLineInsetDoesNotStartARowForATrailingEscapeSequence() {
        var state = TerminalChatTextFormatting.ChatLineInsetState()

        // The thought renderer emits its SGR reset after the closing blank
        // line: the reset is zero-width and must not consume the margin.
        let thoughtTail = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\n\n\u{1B}[0m",
            prefix: " ",
            state: &state
        )
        #expect(thoughtTail == "\n\n\u{1B}[0m")
        #expect(state.isAtLineStart)

        let next = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "👥 Sub-Agents:\n",
            prefix: " ",
            state: &state
        )
        #expect(next == " 👥 Sub-Agents:\n")
        #expect(state.isAtLineStart)

        // A sequence followed by a line boundary is emitted without margin.
        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "\u{1B}[0m\n\u{1B}[2K\r\u{1B}[0m\r\nok",
                prefix: " ",
                state: &state
            ) == "\u{1B}[0m\n\u{1B}[2K\r\u{1B}[0m\r\n ok"
        )
        #expect(!state.isAtLineStart)

        // A sequence between the CR and the LF of one boundary keeps its order,
        // within one delta and across two.
        state = TerminalChatTextFormatting.ChatLineInsetState()
        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "\r\u{1B}[0m\nok",
                prefix: " ",
                state: &state
            ) == "\r\u{1B}[0m\n ok"
        )
        state = TerminalChatTextFormatting.ChatLineInsetState()
        let carriageReturn = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\r",
            prefix: " ",
            state: &state
        )
        let lineFeed = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\u{1B}[0m\nok",
            prefix: " ",
            state: &state
        )
        #expect(carriageReturn + lineFeed == "\r\u{1B}[0m\n ok")
        #expect(!state.isAtLineStart)

        // Mid-row sequences pass through unchanged.
        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "\u{1B}[0m!\n",
                prefix: " ",
                state: &state
            ) == "\u{1B}[0m!\n"
        )
        #expect(state.isAtLineStart)
    }

    @Test
    func chatLineInsetKeepsTheMarginOutsideAnEscapeSequenceSplitAcrossDeltas() {
        var state = TerminalChatTextFormatting.ChatLineInsetState()

        let first = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\u{1B}[38;5",
            prefix: " ",
            state: &state
        )
        #expect(first == "\u{1B}[38;5")
        #expect(state.isAtLineStart)

        let second = TerminalChatTextFormatting.chatLineInsetApplied(
            to: ";208mX",
            prefix: " ",
            state: &state
        )
        let combined = first + second
        // The continuation bytes are not visible, and the margin follows the
        // completed sequence instead of being inserted inside the CSI.
        #expect(second == ";208m X")
        #expect(combined == "\u{1B}[38;5;208m X")
        #expect(!combined.contains("\u{1B}[38;5 "))
        #expect(TerminalANSIText.stripANSI(combined) == " X")
        #expect(!state.isAtLineStart)

        // A lone ESC at the end of a delta selects the marker in the next one.
        var escapeState = TerminalChatTextFormatting.ChatLineInsetState()
        let escape = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\u{1B}",
            prefix: " ",
            state: &escapeState
        )
        let continuation = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "[1mY",
            prefix: " ",
            state: &escapeState
        )
        #expect(escape == "\u{1B}")
        #expect(continuation == "[1m Y")
        #expect(!escapeState.isAtLineStart)
    }

    @Test
    func chatLineInsetTreatsOperatingSystemCommandsAsZeroWidth() {
        let openLink = "\u{1B}]8;;https://example.com\u{1B}\\"
        let closeLink = "\u{1B}]8;;\u{1B}\\"
        var state = TerminalChatTextFormatting.ChatLineInsetState()

        // A hyperlink row keeps the margin outside the OSC 8 sequence.
        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "\(openLink)link\(closeLink)\n",
                prefix: " ",
                state: &state
            ) == " \(openLink)link\(closeLink)\n"
        )
        #expect(state.isAtLineStart)

        // OSC sequences alone, terminated by ST or BEL, never start a row.
        #expect(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: "\(closeLink)\u{1B}]0;title\u{07}",
                prefix: " ",
                state: &state
            ) == "\(closeLink)\u{1B}]0;title\u{07}"
        )
        #expect(state.isAtLineStart)

        // The ST of an OSC may be split between deltas.
        let unterminated = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\u{1B}]8;;https://example.com\u{1B}",
            prefix: " ",
            state: &state
        )
        let terminated = TerminalChatTextFormatting.chatLineInsetApplied(
            to: "\\link",
            prefix: " ",
            state: &state
        )
        #expect(unterminated == "\u{1B}]8;;https://example.com\u{1B}")
        #expect(terminated == "\\ link")
        #expect(!state.isAtLineStart)
    }

    @Test
    func toolOutputSpacingLeavesABlankRowAfterUnterminatedAssistantContent() {
        var state = TerminalChatTextFormatting.ChatSpacingState()
        TerminalChatTextFormatting.updateChatSpacingState(
            afterPreserving: "Risposta del modello.",
            state: &state
        )

        let separator = TerminalChatTextFormatting.chatSpacingNormalized(
            "\n\n",
            state: &state
        )

        #expect("Risposta del modello.\(separator)🛠️ tool" == "Risposta del modello.\n\n🛠️ tool")
        #expect(state.trailingNewlineCount == 2)
    }

    @Test
    func boldSectionBreakSeparatesGluedSectionTitleAcrossDeltas() {
        var state = TerminalChatBoldBreakState()

        let chunks = ["Fixed it incorrectly.", "*", "*Identifying bugs** done"]
        var rendered = chunks
            .map { TerminalChatTextFormatting.normalizedBoldSectionBreak($0, state: &state) }
            .joined()
        rendered += TerminalChatTextFormatting.flushBoldSectionBreak(state: &state)

        #expect(rendered == "Fixed it incorrectly.\n**Identifying bugs** done")
    }

    @Test
    func boldSectionBreakLeavesPlainBoldAndOrderedListsIntact() {
        var state = TerminalChatBoldBreakState()

        let plainBold = TerminalChatTextFormatting.normalizedBoldSectionBreak(
            "Use **bold** here",
            state: &state
        ) + TerminalChatTextFormatting.flushBoldSectionBreak(state: &state)
        #expect(plainBold == "Use **bold** here")

        var listState = TerminalChatBoldBreakState()
        let orderedList = TerminalChatTextFormatting.normalizedBoldSectionBreak(
            "1. First. 2. Second",
            state: &listState
        ) + TerminalChatTextFormatting.flushBoldSectionBreak(state: &listState)
        #expect(orderedList == "1. First. 2. Second")
    }

    @Test
    func thoughtNormalizationDoesNotAddBulletsAcrossDeltas() {
        var state = TerminalChatBoldBreakState()
        let chunks = [" Analizzo il bug.", " Verifico i test", ".", " Scrivo la fix"]
        let rendered = chunks
            .map { TerminalChatTextFormatting.normalizedBoldSectionBreak($0, state: &state) }
            .joined()

        #expect(rendered == " Analizzo il bug. Verifico i test. Scrivo la fix")
        #expect(!rendered.contains("•"))
    }

    @Test
    func markdownFormatterCompactsLooseListBlankLines() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )
        let rendered = formatter.consume("1. Primo\n\n2. Secondo\n") + formatter.finish()

        #expect(rendered.contains("Primo"))
        #expect(rendered.contains("Secondo"))
        #expect(!rendered.contains("\n\n"))
    }

    @Test
    func thinkingFormatterRemovesUnbalancedStrongMarkers() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )

        let rendered = formatter.consume("a. **renderListItem handles indentation.\n\n ** If it fails, keep the words.\n")

        #expect(!rendered.contains("**"))
        #expect(rendered.contains("renderListItem handles indentation."))
        #expect(rendered.contains("If it fails, keep the words."))
    }

    @Test
    func thinkingFormatterHidesGPTReasoningSummaryComments() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )

        let rendered = formatter.consume("""
        Improving activePlan whitespace handling

        <!--
        """) + formatter.consume("""
         -->**Planning improved plan approval messaging**

        <!-- -->**Adding plan recording status flag**
        """) + formatter.finish()

        #expect(!rendered.contains("<!-- -->"))
        #expect(rendered.contains("\u{1B}[1mPlanning improved plan approval messaging\u{1B}[0m"))
        #expect(rendered.contains("\u{1B}[1mAdding plan recording status flag\u{1B}[0m"))
    }

    @Test
    func truncatedInlineCountsWideGraphemesInsteadOfDisplayColumns() {
        // `😀` and `界` are each two terminal cells, but each consumes one
        // count-based truncation unit. A width-aware core would return `...`.
        #expect(TerminalChat.truncatedInline("😀界abc", limit: 4) == "😀...")
    }

    @Test
    func truncatedByCountHandlesBudgetsNoLargerThanItsEllipsis() {
        // The count-based family must never pass a negative length to `prefix`.
        // It omits the marker when its three graphemes cannot fit in the budget.
        #expect(InlineTextTruncation.truncatedByCount("abcdef", limit: 3) == "...")
        #expect(InlineTextTruncation.truncatedByCount("abcdef", limit: 2) == "ab")
        #expect(InlineTextTruncation.truncatedByCount("abcdef", limit: 1) == "a")
        #expect(InlineTextTruncation.truncatedByCount("abcdef", limit: 0).isEmpty)
        #expect(InlineTextTruncation.truncatedByCount("abcdef", limit: -1).isEmpty)
    }

    @Test
    func mutedThoughtAccentMapsKnownAccentFamilies() {
        #expect(TerminalChatTextFormatting.mutedThoughtAccent(for: 75) == 109)
        #expect(TerminalChatTextFormatting.mutedThoughtAccent(for: 180) == 144)
        #expect(TerminalChatTextFormatting.mutedThoughtAccent(for: 108) == 108)
        #expect(TerminalChatTextFormatting.mutedThoughtAccent(for: 200) == nil)
    }

    @Test
    func toolAndStatusWidthsUseTerminalCellWidth() {
        #expect(TerminalTextMetrics.displayWidth("🛠️ Tool") == TerminalANSIText.visibleWidth("🛠️ Tool"))
        #expect(TerminalTextMetrics.displayWidth("e\u{301}") == 1)
        #expect(TerminalStatusBar.visibleCharacterCount("🛠️ Tool") == 7)
        #expect(TerminalStatusBar.visibleCharacterCount("你好") == 4)
    }

    @Test
    func inputPanelRowsRespectWideCharacters() {
        let rows = TerminalStatusBar.inputPanelDisplayRows(
            text: "你好世界",
            cursorIndex: 4,
            contentWidth: 6,
            maxRows: 10
        )

        #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) <= 6 })
        #expect(rows.count == 3)
    }

    @Test
    func inlineTextCollapsesNewlinesAndCarriageReturns() {
        #expect(InlineTextTruncation.inlineText("a\nb\r\nc\rd  ") == "a b c d")
        #expect(InlineTextTruncation.inlineText("  hello world  ") == "hello world")
        #expect(InlineTextTruncation.inlineText("line1\r\nline2") == "line1 line2")
    }
}
