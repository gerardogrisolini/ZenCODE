//
//  TerminalMarkdownStreamFormatterTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 29/05/26.
//

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
    func proseStreamsIncrementallyAcrossMultipleDeltas() {
        var formatter = makeFormatter()

        let first = formatter.consume("Hello ")
        #expect(first == "Hello ")

        let second = formatter.consume("World")
        #expect(second == "World")

        // Completing the line: only the newline should appear (the text was
        // already streamed).
        let third = formatter.consume("\n")
        #expect(third == "\n")
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
    func boldRemainsFormattedAcrossDeltas() {
        var formatter = makeFormatter()

        // The safe prefix "This is " streams immediately; "**bold**." arrives
        // in the next delta and must be rendered as bold through the inline
        // markdown renderer, not emitted as raw text.
        let first = formatter.consume("This is ")
        #expect(first == "This is ")

        let rest = formatter.consume("**bold**.\n")
        let rendered = first + rest

        #expect(rendered.contains("\u{1B}[1mbold\u{1B}[0m"))
        #expect(!rendered.contains("**bold**"))
    }

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
    func inlineCodeRemainsFormattedAcrossDeltas() {
        var formatter = makeFormatter()

        let first = formatter.consume("Run ")
        #expect(first == "Run ")

        let rest = formatter.consume("`swift test` now.\n")
        let rendered = first + rest

        #expect(rendered.contains("\u{1B}[38;5;180m"))
        #expect(!rendered.contains("`swift test`"))
    }

    @Test
    func inlineCodeSplitAcrossDeltas() {
        var formatter = makeFormatter()

        // The opening backtick arrives in the first delta and halts streaming;
        // the closing backtick arrives later. The code span must be formatted.
        let first = formatter.consume("Use `")
        #expect(first == "Use ")

        let rest = formatter.consume("code` here.\n")
        let rendered = first + rest

        #expect(rendered.contains("\u{1B}[38;5;180m"))
        #expect(!rendered.contains("`code`"))
        #expect(rendered.contains("code"))
    }

    @Test
    func linkRemainsFormattedAcrossDeltas() {
        var formatter = makeFormatter()

        let first = formatter.consume("See ")
        #expect(first == "See ")

        let rest = formatter.consume("[docs](https://example.com).\n")
        let rendered = first + rest

        #expect(rendered.contains("\u{1B}[38;5;75m"))
        #expect(!rendered.contains("](https://example.com)"))
        #expect(rendered.contains("docs"))
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

    @Test
    func thoughtFormatterKeepsBalancedBoldOnPartialLine() {
        var formatter = makeThoughtFormatter()

        let first = formatter.consume("It is ")
        #expect(first == "It is ")

        let rest = formatter.consume("**important** here.\n")
        let rendered = first + rest

        #expect(rendered.contains("\u{1B}[1mimportant\u{1B}[0m"))
        #expect(!rendered.contains("**important**"))
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

    // MARK: (e) Tail wrapping respects prefix column

    @Test
    func tailWrappingRespectsPrefixColumn() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 20,
            supportsHyperlinks: false
        )

        // The prefix "1234567890" (10 cols) streams immediately. The tail
        // must wrap accounting for those 10 columns so the combined first
        // visual line does not overflow width 20.
        let first = formatter.consume("1234567890")
        #expect(first == "1234567890")

        let rest = formatter.consume(" word word word word word\n")
        let rendered = first + rest

        // No single visual line should exceed the terminal width.
        for line in rendered.components(separatedBy: "\n") {
            let width = TerminalANSIText.visibleWidth(line)
            #expect(width <= 20, "Line too wide (\(width)): \(line)")
        }
    }

    // MARK: (f) Block markers are not emitted raw

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
    func unorderedListMarkerIsNotEmittedRaw() {
        var formatter = makeFormatter()
        let partial = formatter.consume("-")
        #expect(partial.isEmpty)

        let rest = formatter.consume(" item\n") + formatter.finish()
        #expect(rest.contains("•"))
        #expect(rest.contains("item"))
    }

    @Test
    func orderedListMarkerIsNotEmittedRaw() {
        var formatter = makeFormatter()
        let partial = formatter.consume("1")
        #expect(partial.isEmpty)

        let more = formatter.consume(".")
        #expect(more.isEmpty)

        let rest = formatter.consume(" First\n") + formatter.finish()
        #expect(rest.contains("First"))
    }

    @Test
    func blockquoteMarkerIsNotEmittedRaw() {
        var formatter = makeFormatter()
        let partial = formatter.consume(">")
        #expect(partial.isEmpty)
    }

    @Test
    func thematicBreakMarkerIsNotEmittedRaw() {
        var formatter = makeFormatter()
        let first = formatter.consume("--")
        #expect(first.isEmpty)
        let second = formatter.consume("-\n") + formatter.finish()
        // A thematic break renders as a horizontal rule, not as "---" text.
        #expect(!second.contains("---"))
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
    func dashRunFollowedByLetterStreamsImmediately() {
        var formatter = makeFormatter()
        // "---option" cannot be a thematic break (rest is not whitespace) nor
        // a list marker (dash run ≥ 3 without a space). It should stream
        // immediately instead of being buffered until the newline.
        let output = formatter.consume("---option is plain")
        #expect(!output.isEmpty)
        #expect(output.contains("---option"))
    }

    @Test
    func tableHeaderIsNotEmittedRaw() {
        var formatter = makeFormatter()
        // A line with pipes could be a GFM table header; it must buffer.
        let partial = formatter.consume("| A | B |")
        #expect(partial.isEmpty)
    }

    // MARK: (g) No duplication on partially-emitted lines

    @Test
    func noDuplicationWhenCompletingPartiallyEmittedLine() {
        var formatter = makeFormatter()

        let first = formatter.consume("Hello ")
        #expect(first == "Hello ")

        let second = formatter.consume("World\n")
        // Only "World\n" — the prefix was already shown.
        #expect(second == "World\n")
        #expect(!second.contains("Hello"))
    }

    @Test
    func multiLineStreamingProducesCorrectConcatenation() {
        var formatter = makeFormatter()
        var output = ""

        output += formatter.consume("First ")
        output += formatter.consume("line\n")
        output += formatter.consume("Second ")
        output += formatter.consume("line\n")
        output += formatter.finish()

        // Both lines should appear exactly once, in order.
        #expect(output.contains("First line"))
        #expect(output.contains("Second line"))
        // No duplication of any word.
        #expect(output.components(separatedBy: "First").count == 2)
        #expect(output.components(separatedBy: "Second").count == 2)
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
