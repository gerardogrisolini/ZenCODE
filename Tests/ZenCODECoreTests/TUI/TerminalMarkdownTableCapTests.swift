//
//  TerminalMarkdownTableCapTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 29/05/26.
//

import Testing
@testable import ZenCODECore

/// Coverage for the dedicated table buffering cap in
/// `TerminalMarkdownStreamFormatter`. Tables buffer fully because their column
/// layout can only be computed once the whole block is known; without a cap a
/// pathological (never-terminating) table would accumulate unbounded memory and
/// emit nothing until the block ends. These tests pin the explicit-degradation
/// contract: under the cap a table renders integrally, over the cap it is
/// rendered with the rows accumulated so far plus a dim truncation marker, the
/// discarded rows never reappear, and any text following the block is preserved.
@Suite
struct TerminalMarkdownTableCapTests {
    /// Marker string emitted by `flushTruncatedTable`. Only the visible text is
    /// asserted so the test is independent of the surrounding ANSI dim/reset.
    private static let truncationMarker = "… table truncated"

    // The line cap is 64 (header + delimiter + body rows). The body-row count
    // that first trips it is therefore 62 (1 header + 1 delimiter + 62 = 64).
    private static let capBodyRowsRendered = 62

    private func makeFormatter() -> TerminalMarkdownStreamFormatter {
        TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )
    }

    /// Builds a markdown pipe table with the given number of body rows. Each row
    /// carries a unique zero-padded cell (`r001`, `r002`, …) so presence/absence
    /// can be asserted without substring ambiguity.
    private func tableMarkdown(bodyRows: Int) -> String {
        var lines = ["| A | B |", "| --- | --- |"]
        for index in 1...bodyRows {
            let value = String(format: "r%03d", index)
            lines.append("| \(value) | v\(value) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @Test
    func tableUnderCapRendersIntegrallyWithoutTruncationMarker() {
        var formatter = makeFormatter()

        // 50 body rows = 52 buffered lines, comfortably under the 64-line cap
        // and under the 8_000-character cap. The render path is unchanged for
        // tables under the cap, so output is identical to the pre-cap behavior.
        let rendered = formatter.consume(tableMarkdown(bodyRows: 50)) + formatter.finish()

        #expect(rendered.contains("┌"))                       // table box drawn
        #expect(rendered.contains("r001"))                    // first body row
        #expect(rendered.contains("r050"))                    // last body row
        #expect(!rendered.contains(Self.truncationMarker))    // no degradation
    }

    @Test
    func tableOverLineCapDegradesExplicitlyWithMarker() {
        var formatter = makeFormatter()

        // 100 body rows exceed the 64-line cap; only the rows that fit (the
        // first 62 body rows) render, followed by the truncation marker.
        let rendered = formatter.consume(tableMarkdown(bodyRows: 100)) + formatter.finish()

        #expect(rendered.contains("┌"))
        #expect(rendered.contains(Self.truncationMarker))
        // Rows up to the cap are preserved.
        #expect(rendered.contains("r001"))
        let lastRendered = String(format: "r%03d", Self.capBodyRowsRendered)
        #expect(rendered.contains(lastRendered))
        // Rows beyond the cap are discarded, never rendered.
        let firstDiscarded = String(format: "r%03d", Self.capBodyRowsRendered + 1)
        #expect(!rendered.contains(firstDiscarded))
        #expect(!rendered.contains("r100"))
    }

    @Test
    func tableOverCharacterCapWithSingleHugeCellDegrades() {
        var formatter = makeFormatter()

        // One body row whose single cell alone exceeds the 8_000-character cap.
        let huge = String(repeating: "z", count: 8_500)
        let source = "| A | B |\n| --- | --- |\n| \(huge) | x |\n"

        let rendered = formatter.consume(source) + formatter.finish()

        // The character cap triggers explicit degradation rather than buffering
        // the pathological row indefinitely.
        #expect(rendered.contains(Self.truncationMarker))
        #expect(rendered.contains("┌"))
        // The buffered row (with the huge cell) was still rendered as part of
        // the table before the marker was appended.
        #expect(rendered.contains("z"))
    }

    @Test
    func oversizedTableCandidateHeaderIsFlushedBeforeConfirmation() {
        var formatter = makeFormatter()
        let hugeHeader = String(repeating: "h", count: 8_500)

        // A candidate is not yet a confirmed table, but it still must not keep
        // an arbitrarily large header buffered while waiting for a delimiter.
        // It degrades to the ordinary-line path immediately rather than holding
        // the input until finish().
        let rendered = formatter.consume("| \(hugeHeader) | B |\n")

        #expect(!rendered.isEmpty)
        #expect(rendered.contains("h"))
        #expect(!rendered.contains(Self.truncationMarker))
    }

    @Test
    func oversizedDelimiterTripsTableCapImmediately() {
        var formatter = makeFormatter()
        let hugeDelimiter = String(repeating: "-", count: 8_500)

        // Confirmation itself can cross the character cap: header plus a huge
        // delimiter must emit the explicit degradation in that same consume,
        // not wait for a subsequent body row or finish().
        let rendered = formatter.consume(
            "| A | B |\n| \(hugeDelimiter) | --- |\n"
        )

        #expect(rendered.contains("┌"))
        #expect(rendered.contains(Self.truncationMarker))
    }

    @Test
    func streamingPastCapEmitsBeforeFinishAndStaysBounded() {
        var formatter = makeFormatter()
        var streamed = ""

        // Header + delimiter are buffered, producing no output yet.
        streamed += formatter.consume("| A | B |\n| --- | --- |\n")
        #expect(streamed == "")

        // Feed body rows well past the cap. Truncation must fire *during*
        // streaming, so output is emitted before finish() is ever called.
        for index in 1...100 {
            streamed += formatter.consume("| \(String(format: "r%03d", index)) | v |\n")
        }
        #expect(!streamed.isEmpty)
        #expect(streamed.contains(Self.truncationMarker))

        // Once truncated, the block discards further rows: feeding many more
        // rows must not accumulate them (bounded memory) nor emit anything new.
        let beforeFurtherRows = streamed
        for index in 101...400 {
            streamed += formatter.consume("| \(String(format: "r%03d", index)) | v |\n")
        }
        #expect(streamed == beforeFurtherRows)
        #expect(!streamed.contains("r400"))

        // The block was already flushed at the cap; finish() has nothing left.
        #expect(formatter.finish() == "")
    }

    @Test
    func nonTableTextAfterTruncatedTableIsPreserved() {
        var formatter = makeFormatter()

        var rendered = formatter.consume(tableMarkdown(bodyRows: 100))
        // A non-table line ends the (already truncated) block and must render as
        // normal prose — it is never swallowed by the truncation.
        rendered += formatter.consume("Text after the table.\n")
        rendered += formatter.finish()

        #expect(rendered.contains(Self.truncationMarker))
        #expect(rendered.contains("Text after the table."))
        // Truncated rows are gone, but the trailing paragraph is intact.
        #expect(!rendered.contains("r100"))
    }
}
