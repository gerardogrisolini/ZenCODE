//
//  TerminalChatRenderingTests+MarkdownFormatter.swift
//  ZenCODE
//
//  Tests for the terminal markdown formatter: headings, lists, tables, block
//  quotes and code fences while streaming.
//

import Foundation
import Markdown
import Testing
@testable import ZenCODECore

extension TerminalChatRenderingTests {
    @Test
    func markdownFormatterStylesHeadingsAndInlineCode() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            palette: .dark
        )

        let rendered = formatter.consume("## Titolo con `codice`\n")

        #expect(rendered.contains("\u{1B}[1;38;5;75mTitolo con"))
        #expect(!TerminalANSIText.stripANSI(rendered).contains("##"))
        #expect(rendered.contains("\u{1B}[48;5;236m\u{1B}[38;5;180mcodice\u{1B}[0m"))
        #expect(rendered.hasSuffix("\n"))
    }

    @Test
    func markdownFormatterStreamsLongPlainLinesWithoutParsing() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)
        let plain = String(repeating: "a", count: 241)

        #expect(formatter.consume(plain) == plain)
        #expect(formatter.finish() == "")
    }

    @Test
    func markdownFormatterKeepsPotentialMarkdownBufferedUntilNewline() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            palette: .dark
        )
        let partial = "## " + String(repeating: "a", count: 241)

        #expect(formatter.consume(partial) == "")
        #expect(formatter.consume("\n").contains("\u{1B}[1;38;5;75m"))
    }

    @Test
    func markdownFormatterDoesNotBufferInlinePipelineAsTableCandidate() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)

        let rendered = formatter.consume("Use `cat file | grep foo | sort` now.\n")

        #expect(!rendered.isEmpty)
        #expect(rendered.contains("cat file"))
        #expect(formatter.finish() == "")
    }

    @Test
    func markdownFormatterRendersPipeTableAfterDelimiter() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)

        let header = formatter.consume("| A | B |\n")
        let rendered = formatter.consume("| --- | --- |\n| 1 | 2 |\n") + formatter.finish()

        #expect(header == "")
        #expect(rendered.contains("┌"))
        #expect(rendered.contains("A"))
        #expect(rendered.contains("1"))
    }

    @Test
    func markdownFormatterFlushesLongListsDuringStreaming() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)
        let list = (1...81)
            .map { "- item \($0)" }
            .joined(separator: "\n") + "\n"

        let rendered = formatter.consume(list)

        #expect(!rendered.isEmpty)
        #expect(rendered.contains("item 1"))
        #expect(rendered.contains("item 80"))
    }

    @Test
    func markdownFormatterRendersFencedCodeBlockWithSyntaxHighlighting() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            palette: .dark
        )

        let rendered = formatter.consume("```swift\nlet x = 1\n```\n") + formatter.finish()

        // Fences become a readable header and never leak raw Markdown.
        #expect(rendered.contains("Code · Swift"))
        #expect(!rendered.contains("```"))
        // Body is routed through the code renderer: `let` is a keyword.
        #expect(rendered.contains("\u{1B}[38;5;141mlet\u{1B}[0m"))
        #expect(rendered.contains("x = "))
    }

    @Test
    func markdownFormatterDoesNotParseMarkdownInsideCodeFence() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        let rendered = formatter.consume("```\n- not a list\n**not bold**\n```\n")
            + formatter.finish()

        // Content inside the fence keeps its literal markers instead of being
        // converted to a bullet or bold run.
        #expect(rendered.contains("- not a list"))
        #expect(rendered.contains("**not bold**"))
        #expect(!rendered.contains("•"))
    }

    @Test
    func markdownFormatterDoesNotWrapTableBoxDrawing() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 12,
            supportsHyperlinks: false
        )

        _ = formatter.consume("| Column A | Column B |\n")
        let rendered = formatter.consume("| --- | --- |\n| value 1 | value 2 |\n")
            + formatter.finish()

        // Box-drawing rows are emitted intact even though they exceed the narrow
        // render width; wrapping them would corrupt the table layout.
        #expect(rendered.contains("┌"))
        #expect(rendered.contains("│"))
        let boxRows = rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains("│") || $0.contains("─") }
        #expect(!boxRows.isEmpty)
        // Every box-drawing row exceeds the render width, proving the
        // structured-surface renderer left the table untouched instead of
        // breaking it across lines.
        #expect(boxRows.allSatisfy { TerminalANSIText.visibleWidth($0) > 12 })
    }

    @Test
    func markdownFormatterRendersMultiLineBlockQuote() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        let rendered = formatter.consume("> first line\n> second line\n")
            + formatter.finish()

        // Blockquote lines stream incrementally (one rendered as the next
        // arrives), yet produce the same visual result as a single block.
        #expect(rendered.contains("first line"))
        #expect(rendered.contains("second line"))
        // Literal blockquote markers are consumed by the renderer.
        #expect(!rendered.contains("> first line"))
    }

    @Test
    func markdownFormatterStreamsListItemByItem() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // The first item is complete as soon as the second top-level marker
        // arrives, so it is rendered before finish() is ever called.
        let streamed = formatter.consume("- alpha\n- beta\n")
        #expect(streamed.contains("alpha"))
        #expect(streamed.contains("•"))
        // The last item stays buffered until the stream ends.
        #expect(!streamed.contains("beta"))

        let tail = formatter.finish()
        #expect(tail.contains("beta"))
    }

    @Test
    func markdownFormatterStreamsLazyOrderedListWithAscendingNumbers() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // The common lazy "1./1./1." convention must render as 1./2./3. even
        // though each item is flushed as a standalone document while streaming.
        let streamed = formatter.consume("1. alpha\n1. beta\n1. gamma\n") + formatter.finish()
        let plain = TerminalANSIText.stripANSI(streamed)

        #expect(plain.contains("1. alpha"))
        #expect(plain.contains("2. beta"))
        #expect(plain.contains("3. gamma"))
        // The lazy source markers must not leak through unchanged.
        #expect(!plain.contains("1. beta"))
        #expect(!plain.contains("1. gamma"))
    }

    @Test
    func markdownFormatterStreamsNestedListMatchingWholeBlock() {
        var streaming = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        let source = "- top\n  - nested\n- top two\n"

        // Feed the nested list one line per delta.
        var streamed = ""
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            streamed += streaming.consume(line + "\n")
        }
        streamed += streaming.finish()

        // Independent oracle: render the whole block directly through the
        // markdown renderer, bypassing the stream formatter entirely. Using a
        // second copy of the (modified) formatter would not be independent.
        var expectedRenderer = TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: false,
            renderWidth: 79
        )
        let expected = expectedRenderer.visit(Document(parsing: source)) + "\n"

        // Streaming line by line produces the same rendering as parsing the
        // whole block at once: nested structure and indentation are preserved.
        #expect(streamed == expected)
        #expect(streamed.contains("•"))
        #expect(streamed.contains("◦"))
    }

    @Test
    func markdownFormatterStreamsBulletToOrderedTransitionRenumbered() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // A bullet item followed (with a blank line, still inside the list
        // block) by lazy "1./1." ordered items. The ordered segment must
        // restart numbering from 1 and ascend to 2, not stay "1./1.".
        let streamed = formatter.consume("- bullet\n\n1. first\n1. second\n") + formatter.finish()
        let plain = TerminalANSIText.stripANSI(streamed)

        #expect(plain.contains("1. first"))
        #expect(plain.contains("2. second"))
        #expect(!plain.contains("1. second"))
        // A blank line separates the two list-type blocks (matching the document
        // renderer) rather than concatenating them directly.
        #expect(plain.contains("\n\n1. first"))
    }

    @Test
    func markdownFormatterUnbalancedBlockQuoteFlushesWithinHardCap() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )

        // A blockquote with an opener `**` that is never closed. It must keep
        // buffering past the soft cap but eventually flush at the hard cap
        // (80 lines) instead of buffering indefinitely.
        var source = "> **unclosed bold\n"
        for line in 1...85 {
            source += "> filler line \(line)\n"
        }

        // consume() alone must produce output (the hard cap forced a flush)
        // rather than buffering everything indefinitely.
        let partial = formatter.consume(source)
        #expect(!partial.isEmpty)
        #expect(partial.contains("unclosed bold"))

        // finish() drains the remainder, so the whole quote is rendered.
        let rendered = partial + formatter.finish()
        #expect(rendered.contains("filler line 85"))
    }

    @Test
    func markdownFormatterHandlesIntMaxOrderedMarkerWithoutCrash() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // A pathological ordered marker at Int.max (19 digits) must not crash
        // the renumbering arithmetic (overflow would trap). It renders verbatim.
        let streamed = formatter.consume(
            "9223372036854775807. item\n9223372036854775807. item\n"
        ) + formatter.finish()

        // No crash: the items rendered and the huge number is preserved verbatim
        // (renumbering is skipped for out-of-range values).
        #expect(streamed.contains("9223372036854775807"))
        #expect(streamed.contains("item"))
    }

    @Test
    func markdownFormatterLeavesTenDigitOrderedMarkerVerbatimWithoutCrash() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // 10 digits exceed the markdown limit (9). Renumbering is skipped, the
        // marker renders verbatim, and no overflow crash occurs.
        let streamed = formatter.consume(
            "1000000000. item\n1000000000. item\n"
        ) + formatter.finish()
        let plain = TerminalANSIText.stripANSI(streamed)

        // Both items render verbatim with the original number.
        #expect(plain.contains("1000000000. item"))
        // No incremented number appears.
        #expect(!plain.contains("1000000001"))
    }

    @Test
    func markdownFormatterStreamsTableIntactUntilComplete() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)

        // The header stays buffered while the table is still only a candidate.
        let header = formatter.consume("| A | B |\n")
        #expect(header == "")

        let rendered = formatter.consume("| --- | --- |\n| 1 | 2 |\n") + formatter.finish()
        // Once complete, the full table (with box drawing) is rendered intact.
        #expect(rendered.contains("┌"))
        #expect(rendered.contains("A"))
        #expect(rendered.contains("1"))
    }
}
