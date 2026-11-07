//
//  TerminalMarkdownStreamFormatterTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 29/05/26.
//

import Foundation
import Testing
@testable import ZenCODECore

/// Coverage for the incremental prose-streaming feature in
/// `TerminalMarkdownStreamFormatter`. Simple prose should appear immediately
/// (before the newline arrives) while markdown constructs (headings, lists,
/// tables, code fences) and inline markers are never emitted raw. When a line
/// is partially emitted (prefix streamed, tail buffered because of a marker),
/// completing the line must render the tail through the inline markdown
/// renderer so formatting is preserved.
@Suite
struct TerminalMarkdownStreamFormatterTests {

    private func makeFormatter() -> TerminalMarkdownStreamFormatter {
        TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )
    }

    private func makeThoughtFormatter() -> TerminalMarkdownStreamFormatter {
        TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )
    }

    // MARK: (a) Immediate visibility of prose deltas

    @Test
    func proseDeltaWithoutNewlineProducesImmediateOutput() {
        var formatter = makeFormatter()
        let output = formatter.consume("Hello World")

        // Without incremental streaming the output would be empty (buffered
        // until a newline). Now the safe prefix should be visible immediately.
        #expect(!output.isEmpty)
        #expect(output.contains("Hello"))
        #expect(output.contains("World"))
    }

    @Test
    func proseAfterBlockResumesStreamingImmediately() {
        var formatter = makeFormatter()
        // A list line gets buffered as a block.
        _ = formatter.consume("- item\n")
        // A non-list line flushes the block and renders normally.
        _ = formatter.consume("End of list\n")

        // Now blockKind is nil again; subsequent prose should stream.
        let prose = formatter.consume("Plain prose")
        #expect(!prose.isEmpty)
        #expect(prose.contains("Plain"))
    }

    // MARK: (b) Inline markdown remains formatted across deltas

    @Test
    func boldMarkerSplitAcrossDeltas() {
        var formatter = makeFormatter()

        // The first '*' halts incremental emission (it is a streamingStopChar).
        // The second delta completes the bold span. The tail must render bold.
        let first = formatter.consume("Value is *")
        #expect(first == "Value is ")

        let rest = formatter.consume("*bold**.\n")
        let rendered = first + rest

        #expect(rendered.contains("\u{1B}[1mbold\u{1B}[0m"))
        #expect(!rendered.contains("**bold**"))
    }

    @Test
    func linkSplitAcrossDeltas() {
        var formatter = makeFormatter()

        // The '[' halts streaming; the full link text arrives in the next delta.
        let first = formatter.consume("Read [")
        #expect(first == "Read ")

        let rest = formatter.consume("guide](https://example.com).\n")
        let rendered = first + rest

        #expect(rendered.contains("\u{1B}[38;5;75m"))
        #expect(!rendered.contains("](https://example.com)"))
        #expect(rendered.contains("guide"))
    }

    @Test
    func inlineMarkerStopsIncrementalEmission() {
        var formatter = makeFormatter()

        // The backtick halts the safe prefix: "Use " is emitted, the rest is
        // buffered. Nothing raw with a marker leaks out.
        let partial = formatter.consume("Use ")
        #expect(partial == "Use ")

        // Completing the line renders the code span through the inline
        // renderer so it appears formatted, not as raw backtick text.
        let rest = formatter.consume("`code` here.\n")
        let rendered = partial + rest

        #expect(rendered.contains("\u{1B}[38;5;180m"))
        #expect(rendered.contains("code"))
        #expect(!rendered.contains("`code`"))
    }

    // MARK: (c) Thought formatter sanitization on partial lines

    @Test
    func thoughtFormatterSanitizesUnbalancedBoldOnPartialLine() {
        var formatter = makeThoughtFormatter()

        // The thought formatter removes unbalanced ** markers. On a partially
        // streamed line the sanitizer must still run so a stray ** does not
        // appear literally in the output.
        let first = formatter.consume("Thinking ")
        #expect(first == "Thinking ")

        let rest = formatter.consume("**about\n")
        let rendered = first + rest

        // The unbalanced ** is removed; "about" appears as plain text.
        #expect(!rendered.contains("**"))
        #expect(rendered.contains("about"))
    }

    // MARK: (d) finish() on partially emitted lines

    @Test
    func finishRendersPartiallyEmittedTailWithoutNewline() {
        var formatter = makeFormatter()

        let first = formatter.consume("See ")
        #expect(first == "See ")

        // No trailing newline — finish() must render the buffered tail.
        _ = formatter.consume("**important**")
        let rest = formatter.finish()
        let rendered = first + rest

        #expect(rendered.contains("\u{1B}[1mimportant\u{1B}[0m"))
        #expect(!rendered.contains("**important**"))
    }

    @Test
    func finishDoesNotDuplicatePartiallyEmittedContent() {
        var formatter = makeFormatter()

        let streamed = formatter.consume("Hello World")
        #expect(streamed == "Hello World")

        let rest = formatter.finish()
        #expect(rest.isEmpty)
    }

    // MARK: (e) No synthetic wrapping; the terminal owns line breaks

    @Test
    func narrowWidthDoesNotInjectSyntheticNewlines() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 8,
            supportsHyperlinks: false
        )

        // A very narrow injected width must not cause the formatter to insert its
        // own line breaks. The terminal performs the physical auto-wrap; the
        // formatter only preserves the source newline.
        let rendered = formatter.consume("word word word word word\n")
            + formatter.finish()

        let lines = rendered.components(separatedBy: "\n")
        #expect(lines.count == 2) // content line + the empty tail after "\n"
        #expect(lines[0] == "word word word word word")
    }

    // MARK: (f) Unicode boundaries across deltas

    @Test
    func zwjGraphemeSplitAcrossDeltasIsPreservedBeforeInlineTail() {
        var formatter = makeFormatter()

        let rendered = formatter.consume("Pair 👨")
            + formatter.consume("\u{200D}👩 `code`\n")

        #expect(TerminalANSIText.stripANSI(rendered).contains("Pair 👨\u{200D}👩 code"))
        #expect(rendered.contains("\u{1B}[38;5;180mcode\u{1B}[0m"))
    }

    // MARK: (g) Safety flushes retain line context

    @Test
    func markerAfterStreamingSafetyThresholdStaysMidLineProse() {
        var formatter = makeFormatter()
        let prefix = String(repeating: "a", count: 241)

        var rendered = formatter.consume(prefix)
        #expect(rendered == prefix)
        rendered += formatter.consume(" - still prose\n")
        rendered += formatter.finish()

        let visible = TerminalANSIText.stripANSI(rendered)
        #expect(visible.contains(" - still prose"))
        #expect(!visible.contains("•"))
    }

    // MARK: (h) Single emphasis and code-span sanitizer

    @Test
    func singleDelimiterEmphasisIsRenderedWithoutChangingIntrawordUnderscores() {
        var formatter = makeFormatter()

        let emphasized = formatter.consume("Use *italics* and _also italics_.\n")
        #expect(emphasized.contains("\u{1B}[3mitalics\u{1B}[0m"))
        #expect(emphasized.contains("\u{1B}[3malso italics\u{1B}[0m"))

        let identifier = formatter.consume("snake_case remains literal\n")
        #expect(TerminalANSIText.stripANSI(identifier).contains("snake_case"))
        #expect(!identifier.contains("\u{1B}[3m"))
    }

    // MARK: (i) Block markers are not emitted raw

    @Test
    func headingMarkerIsNotEmittedRaw() {
        var formatter = makeFormatter()
        // "#" alone is ambiguous (could become "# Heading").
        let partial = formatter.consume("#")
        #expect(partial.isEmpty)

        // When completed it renders as a heading (with ANSI styling, not as
        // raw plain text with a literal "#").
        let rest = formatter.consume(" Title\n")
        #expect(rest.contains("Title"))
        #expect(rest.contains("\u{1B}["))   // styled, not raw
    }

    @Test
    func orderedMarkerWithoutBodyRemainsVisible() {
        var formatter = makeFormatter()

        let rendered = formatter.consume("1.\n") + formatter.finish()

        #expect(TerminalANSIText.stripANSI(rendered).contains("1."))
    }

    @Test
    func plainTextStartingWithDashIsStreamed() {
        var formatter = makeFormatter()
        // "-x" is not a list marker (no space), so it should stream.
        let output = formatter.consume("-x and more")
        #expect(!output.isEmpty)
        #expect(output.contains("-x"))
    }

    @Test
    func tableHeaderIsNotEmittedRaw() {
        var formatter = makeFormatter()
        // A line with pipes could be a GFM table header; it must buffer.
        let partial = formatter.consume("| A | B |")
        #expect(partial.isEmpty)
    }

    // MARK: Preserved behaviours

    @Test
    func disabledFormatterPassesRawText() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: false)
        let output = formatter.consume("raw **text** without formatting")
        #expect(output == "raw **text** without formatting")
    }

    @Test
    func codeFenceLinesAreNotStreamed() {
        var formatter = makeFormatter()
        // Opening fence — nothing streams as prose.
        _ = formatter.consume("```swift\n")

        // Inside the fence, content goes through the code-block renderer.
        let body = formatter.consume("let x = 1\n")
        #expect(!body.isEmpty)
        // Closing fence.
        _ = formatter.consume("```\n")
    }
}
