//
//  TerminalChatRenderingBaselineTests.swift
//  ZenCODETests
//
//  Equivalence / regression baseline for the terminal chat rendering stack.
//
//  This file is a *baseline*: it pins the observable behaviour of the incremental
//  markdown streaming formatter and the end-to-end render coordinator so future
//  refactors (planned in the same work package) can be validated against a stable
//  reference. It is test-only and touches no production file.
//
//  It has three parts:
//  (a) Equivalence: streaming a long document (>= 20k characters) in tiny 1–3
//      character deltas must produce the same *visible* output as consuming the
//      whole document in a single block followed by `finish()`. Streaming emits a
//      safe prose prefix immediately (unwrapped) while the block path reflows to
//      the render width, so the comparison is made on ANSI-stripped, whitespace-
//      collapsed text. Covered constructs: plain prose, inline markers, list,
//      GFM table, fenced code.
//  (b) Golden transcript: a mixed end-to-end sequence (prompt -> thought ->
//      compact tool started/completed -> assistant content -> sub-agent overview)
//      rendered through `TerminalChatRenderCoordinator(capturesWrites: true)` with
//      an injected clock and column width. The captured `WriteEvent`s are
//      serialized deterministically and asserted for channel routing, ordering,
//      contiguous sequence numbers, in-place tool rewrite, and visible content.
//  (c) Volume smoke: many single-character deltas driven through the real
//      coordinator streaming path. No timing assertions — it exists as a harness
//      for manual measurement and to guard against pathological buffering.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Terminal chat rendering baseline")
struct TerminalChatRenderingBaselineTests {

    // MARK: - Shared deterministic helpers

    /// Splits `text` into deterministic 1–3 character deltas. The size cycles
    /// 1, 2, 3, 1, 2, 3 … so the chunking is reproducible on every run and on
    /// every platform (no RNG, no clock).
    private func deterministicSmallDeltas(_ text: String) -> [String] {
        let characters = Array(text)
        var deltas: [String] = []
        deltas.reserveCapacity(characters.count)
        var index = 0
        var size = 1
        while index < characters.count {
            let end = min(index + size, characters.count)
            deltas.append(String(characters[index..<end]))
            index = end
            size = (size % 3) + 1
        }
        return deltas
    }

    /// The visible text of a rendered fragment: ANSI escape sequences removed and
    /// every run of horizontal/vertical whitespace collapsed to a single space,
    /// trimmed. Streaming emits an unwrapped safe prefix while the block path
    /// reflows to the render width; collapsing whitespace makes the two directly
    /// comparable while still detecting any lost or reordered visible glyphs.
    private func visibleNormalized(_ text: String) -> String {
        let stripped = TerminalANSIText.stripANSI(text)
        let pieces = stripped.split(
            whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        )
        return pieces.joined(separator: " ")
    }

    /// A fixed-width, hyperlink-free formatter so the block path reflows
    /// deterministically regardless of the host terminal.
    private func makeEquivalenceFormatter() -> TerminalMarkdownStreamFormatter {
        TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )
    }

    /// Renders `text` by feeding the whole string in one `consume` call followed
    /// by `finish()`.
    private func renderInSingleBlock(_ text: String) -> String {
        var formatter = makeEquivalenceFormatter()
        var output = formatter.consume(text)
        output += formatter.finish()
        return output
    }

    /// Renders `text` by streaming it in deterministic 1–3 character deltas
    /// followed by `finish()`.
    private func renderStreamedInSmallDeltas(_ text: String) -> String {
        var formatter = makeEquivalenceFormatter()
        var output = ""
        for delta in deterministicSmallDeltas(text) {
            output += formatter.consume(delta)
        }
        output += formatter.finish()
        return output
    }

    /// Asserts that streaming and single-block rendering of `text` yield the same
    /// visible output.
    private func expectStreamingEquivalence(
        _ text: String,
        _ label: Comment
    ) {
        let streamed = renderStreamedInSmallDeltas(text)
        let block = renderInSingleBlock(text)
        #expect(
            visibleNormalized(streamed) == visibleNormalized(block),
            label
        )
    }

    // MARK: - Deterministic content builders

    private static let proseParagraph = """
    The rendering pipeline turns model output into terminal text without losing \
    any visible content along the way. Prose flows continuously and wraps at the \
    configured render width so long paragraphs stay readable inside the viewport.
    """

    private static let inlineMarkerLine =
        "This line mixes **bold**, _emphasis_, `inline code`, and a [link](https://example.com) marker."

    private static let listBlock = """
    - First bullet describing an item
    - Second bullet with a bit more text
      - Nested bullet under the second item
    - Third bullet closing the list
    """

    private static let tableBlock = """
    | Column A | Column B | Column C |
    | --- | --- | --- |
    | alpha | beta | gamma |
    | delta | epsilon | zeta |
    """

    private static let codeFenceBlock = """
    ```swift
    func greet(_ name: String) -> String {
        return "Hello, \\(name)!"
    }
    ```
    """

    /// A mixed markdown document repeated until it exceeds the 20k-character
    /// threshold required by the baseline. Sections are separated by blank lines
    /// so each construct is parsed as its own block.
    private func makeLongMixedCorpus(minimumLength: Int = 20_000) -> String {
        let section = [
            Self.proseParagraph,
            Self.inlineMarkerLine,
            Self.listBlock,
            Self.tableBlock,
            Self.codeFenceBlock
        ].joined(separator: "\n\n")

        var corpus = ""
        var iteration = 0
        while corpus.count < minimumLength {
            corpus += "## Section \(iteration)\n\n"
            corpus += section
            corpus += "\n\n"
            iteration += 1
        }
        return corpus
    }

    // MARK: - (a) Streaming vs single-block equivalence

    @Test("Simple prose: streaming matches single-block rendering")
    func plainProseStreamingEquivalence() {
        // Repeat the paragraph so the streamed line crosses the incremental
        // flush thresholds while still being reflowed as prose in the block path.
        let text = Array(repeating: Self.proseParagraph, count: 100)
            .joined(separator: "\n\n") + "\n"
        #expect(text.count >= 20_000)
        expectStreamingEquivalence(text, "plain prose")
    }

    @Test("Inline markers: streaming matches single-block rendering")
    func inlineMarkerStreamingEquivalence() {
        let text = Array(repeating: Self.inlineMarkerLine, count: 220)
            .joined(separator: "\n\n") + "\n"
        #expect(text.count >= 20_000)
        expectStreamingEquivalence(text, "inline markers")
    }

    @Test("Lists: streaming matches single-block rendering")
    func listStreamingEquivalence() {
        let text = Array(repeating: Self.listBlock, count: 180)
            .joined(separator: "\n\n") + "\n"
        #expect(text.count >= 20_000)
        expectStreamingEquivalence(text, "list")
    }

    @Test("Tables: streaming matches single-block rendering")
    func tableStreamingEquivalence() {
        let text = Array(repeating: Self.tableBlock, count: 200)
            .joined(separator: "\n\n") + "\n"
        #expect(text.count >= 20_000)
        expectStreamingEquivalence(text, "table")
    }

    @Test("Fenced code: streaming matches single-block rendering")
    func codeFenceStreamingEquivalence() {
        let text = Array(repeating: Self.codeFenceBlock, count: 260)
            .joined(separator: "\n\n") + "\n"
        #expect(text.count >= 20_000)
        expectStreamingEquivalence(text, "fenced code")
    }

    @Test("Long mixed corpus (>= 20k chars): streaming matches single-block")
    func longMixedCorpusStreamingEquivalence() {
        let corpus = makeLongMixedCorpus()
        #expect(corpus.count >= 20_000)
        expectStreamingEquivalence(corpus, "long mixed corpus")
    }

    @Test("Short simple prose is byte-identical when streamed or blocked")
    func shortProseIsByteIdentical() {
        // For a single short prose line the streamed safe prefix plus the
        // completing newline reproduce the block output exactly (no wrapping,
        // no inline markers), so equivalence holds at the byte level too.
        let text = "Hello streaming world, this is a plain sentence.\n"
        #expect(renderStreamedInSmallDeltas(text) == renderInSingleBlock(text))
    }

    // MARK: - (b) End-to-end golden transcript

    private func makeGoldenCoordinator() -> TerminalChatRenderCoordinator {
        // Both channels are terminals so the markdown/thought formatters are
        // enabled. The injected clock is constant (irrelevant with a nil flush
        // delay) and the column-width provider is fixed so compact tool blocks
        // lay out deterministically. Content is kept short enough that it never
        // wraps, so the transcript does not depend on the host terminal width.
        let fixedInstant = ContinuousClock().now
        return TerminalChatRenderCoordinator(
            stdinIsTerminal: false,
            standardOutput: nil,
            standardError: nil,
            standardOutputIsTerminal: true,
            standardErrorIsTerminal: true,
            cursorTopology: .shared,
            capturesWrites: true,
            streamingFlushDelay: nil,
            streamingNow: { fixedInstant },
            columnWidthProvider: { 80 }
        )
    }

    /// Serializes captured write events into a deterministic, human-readable
    /// transcript with control characters rendered as visible markers. Used as the
    /// regression artifact for literal comparison and manual diffing.
    private func serializeTranscript(
        _ events: [TerminalChatRenderCoordinator.WriteEvent]
    ) -> String {
        events.map { event in
            let channel: String
            switch event.channel {
            case .standardOutput:
                channel = "out"
            case .standardError:
                channel = "err"
            }
            let escaped = event.text
                .replacingOccurrences(of: "\u{1B}", with: "<ESC>")
                .replacingOccurrences(of: "\r", with: "<CR>")
                .replacingOccurrences(of: "\n", with: "<LF>")
            return "\(event.sequence) [\(channel)] \(escaped)"
        }
        .joined(separator: "\n")
    }

    private static let expectedGoldenTranscript = """
    0 [err] <LF><ESC>[48;5;236m> Ask something useful<ESC>[K<ESC>[0m<LF><LF>
    1 [err] <ESC>[90m🤔 Thinking:<ESC>[0m<LF><ESC>[90mReasoning about the request.<LF><ESC>[0m<LF>
    2 [err] <CR><ESC>[2K<ESC>[38;5;208m🛠️  tasks.list ⏳<ESC>[0m<LF>
    3 [err] <ESC>[1A<CR><ESC>[2K
    4 [err] <CR><ESC>[2K<ESC>[38;5;208m🛠️  tasks.list ✅<ESC>[0m<LF><LF>
    5 [out] Here is the <ESC>[1manswer<ESC>[0m: 42.<LF>
    6 [err] Sub-agents: 1 completed.<LF><LF>
    """

    @Test("Golden transcript: mixed prompt/thought/tool/content/overview sequence")
    func mixedSequenceGoldenTranscript() async {
        let renderer = makeGoldenCoordinator()
        let toolCall = DirectAgentToolCall(
            id: "tool-baseline-1",
            name: "tasks.list",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeSubmittedPrompt("Ask something useful")
        await renderer.writeThought("Reasoning about the request.\n")
        await renderer.writeToolCallStarted(toolCall)
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )
        await renderer.writeAssistantContent("Here is the **answer**: 42.\n")
        await renderer.finishAssistantContent()
        _ = await renderer.renderSubAgentOverview(
            signature: "agents:baseline",
            text: "Sub-agents: 1 completed.\n\n",
            force: false,
            rememberSignature: true
        )
        await renderer.finishStreamingOutput()

        let events = await renderer.capturedWriteEvents()
        let transcript = serializeTranscript(events)

        // Non-empty transcript captured.
        #expect(!events.isEmpty)
        #expect(transcript == Self.expectedGoldenTranscript)

        // Sequence numbers are contiguous and gap-free.
        #expect(events.map(\.sequence) == Array(0..<UInt64(events.count)))

        // Visible content per channel.
        let stdoutVisible = visibleNormalized(
            events.filter { $0.channel == .standardOutput }.map(\.text).joined()
        )
        let stderrVisible = visibleNormalized(
            events.filter { $0.channel == .standardError }.map(\.text).joined()
        )

        // Assistant content is routed to stdout with inline bold markdown rendered.
        #expect(stdoutVisible.contains("Here is the answer: 42."))
        #expect(!stdoutVisible.contains("**answer**"))

        // Prompt, thought, tool lifecycle, and overview are routed to stderr.
        #expect(stderrVisible.contains("Ask something useful"))
        #expect(stderrVisible.contains("Thinking:"))
        #expect(stderrVisible.contains("Reasoning about the request."))
        #expect(stderrVisible.contains("tasks.list"))
        #expect(stderrVisible.contains("Sub-agents: 1 completed."))

        let stderrCombined = events
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()

        // The compact tool block starts pending (⏳) and is rewritten in place to
        // the success icon (✅) via a cursor-up + erase-line sequence.
        #expect(stderrCombined.contains("⏳"))
        #expect(stderrCombined.contains("✅"))
        #expect(stderrCombined.contains("\u{1B}[2K"))

        // Ordering: prompt precedes thought precedes tool precedes overview.
        let promptIndex = stderrVisible.range(of: "Ask something useful")
        let thoughtIndex = stderrVisible.range(of: "Reasoning about the request.")
        let toolIndex = stderrVisible.range(of: "tasks.list")
        let overviewIndex = stderrVisible.range(of: "Sub-agents: 1 completed.")
        if let promptIndex, let thoughtIndex, let toolIndex, let overviewIndex {
            #expect(promptIndex.lowerBound < thoughtIndex.lowerBound)
            #expect(thoughtIndex.lowerBound < toolIndex.lowerBound)
            #expect(toolIndex.lowerBound < overviewIndex.lowerBound)
        } else {
            Issue.record("expected all transcript markers to be present in order")
        }
    }

    @Test("Golden transcript is stable across identical runs")
    func mixedSequenceTranscriptIsStable() async {
        func runOnce() async -> String {
            let renderer = makeGoldenCoordinator()
            let toolCall = DirectAgentToolCall(
                id: "tool-baseline-1",
                name: "tasks.list",
                argumentsObject: [:],
                argumentsJSON: "{}"
            )
            await renderer.writeSubmittedPrompt("Ask something useful")
            await renderer.writeThought("Reasoning about the request.\n")
            await renderer.writeToolCallStarted(toolCall)
            await renderer.writeToolCallCompleted(
                toolCall,
                result: DirectAgentToolResult(output: "Done", summary: "Done")
            )
            await renderer.writeAssistantContent("Here is the **answer**: 42.\n")
            await renderer.finishAssistantContent()
            _ = await renderer.renderSubAgentOverview(
                signature: "agents:baseline",
                text: "Sub-agents: 1 completed.\n\n",
                force: false,
                rememberSignature: true
            )
            await renderer.finishStreamingOutput()
            return serializeTranscript(await renderer.capturedWriteEvents())
        }

        let first = await runOnce()
        let second = await runOnce()
        #expect(first == second)
    }

    // MARK: - (c) Volume smoke (no timing assertions)

    @Test("Volume smoke: many single-character deltas render without loss")
    func volumeSmokeManySmallDeltas() async {
        // Harness for manual measurement. Streams a long document one character
        // at a time through the real coordinator path. No timing is asserted;
        // the test only guards against dropped output and pathological buffering.
        let renderer = makeGoldenCoordinator()
        let document = makeLongMixedCorpus(minimumLength: 20_000)
        let characters = Array(document)
        #expect(characters.count >= 20_000)

        for character in characters {
            await renderer.writeAssistantContent(String(character))
        }
        await renderer.finishStreamingOutput()

        let events = await renderer.capturedWriteEvents()
        let stdoutVisible = visibleNormalized(
            events.filter { $0.channel == .standardOutput }.map(\.text).joined()
        )

        // Sanity: a representative slice of the source prose survives streaming.
        #expect(!events.isEmpty)
        #expect(stdoutVisible.contains("The rendering pipeline turns model output"))
        #expect(events.map(\.sequence) == Array(0..<UInt64(events.count)))
    }

    @Test("Volume smoke: formatter tolerates single-character delta storm")
    func volumeSmokeFormatterDeltaStorm() {
        // Direct formatter harness: feed one character per `consume` call and
        // ensure every visible glyph is preserved end to end.
        let corpus = makeLongMixedCorpus(minimumLength: 20_000)
        var formatter = makeEquivalenceFormatter()
        var streamed = ""
        for character in corpus {
            streamed += formatter.consume(String(character))
        }
        streamed += formatter.finish()

        #expect(!streamed.isEmpty)
        #expect(
            visibleNormalized(streamed) == visibleNormalized(renderInSingleBlock(corpus))
        )
    }
}
