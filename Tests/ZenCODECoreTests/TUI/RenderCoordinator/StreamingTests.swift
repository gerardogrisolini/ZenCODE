import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {
    @Test
    func thoughtFragmentsAreBufferedUntilTheStreamIsFlushed() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await renderer.writeThought("Planning")
        await renderer.writeThought(" safely")

        #expect(await renderer.capturedWriteEvents().isEmpty)

        await renderer.finishStreamingOutput()
        let events = await renderer.capturedWriteEvents()
        let combined = events.renderedText()

        #expect(events.count == 1)
        #expect(combined.contains("Planning safely"))
    }

    @Test(arguments: [7, 80, 120], [false, true])
    func subsequentSubmittedPromptsReceiveOneDimTurnRuleWithRightMargin(
        terminalColumns: Int,
        stdinIsTerminal: Bool
    ) async {
        let inset = stdinIsTerminal ? TerminalChatTextFormatting.chatLineInsetPrefix : ""
        let rule = String(
            repeating: "─",
            count: terminalColumns - TerminalChat.displayWidth(inset) - 1
        )
        let renderer = makeRenderer(
            stdinIsTerminal: stdinIsTerminal,
            standardErrorIsTerminal: true,
            columnWidthProvider: { terminalColumns }
        )

        await renderer.writeSubmittedPrompt("first turn")
        let firstTurn = await renderer.capturedText(on: .standardError)
        await renderer.writeSubmittedPrompt("second turn")
        await renderer.writeSubmittedPrompt("third turn")

        let stderr = await renderer.capturedText(on: .standardError)
        let visibleRows = TerminalANSIText.stripANSI(stderr)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let ruleRows = visibleRows.filter { row in
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "─" }
        }

        #expect(!TerminalANSIText.stripANSI(firstTurn).contains("─"))
        #expect(ruleRows == ["\(inset)\(rule)", "\(inset)\(rule)"])
        #expect(ruleRows.allSatisfy {
            TerminalChat.displayWidth($0) == terminalColumns - 1
        })
        #expect(stderr.components(separatedBy: "\u{1B}[90m\(rule)\u{1B}[0m").count - 1 == 2)
        #expect(stderr.components(separatedBy: "> first turn").count - 1 == 1)
        #expect(stderr.components(separatedBy: "> second turn").count - 1 == 1)
        #expect(stderr.components(separatedBy: "> third turn").count - 1 == 1)
    }

    @Test(arguments: [false, true])
    func submittedPromptTurnRulePreservesRightMarginAfterResize(stdinIsTerminal: Bool) async {
        let widths = [80, 120, 40]
        let widthBox = ColumnWidthBox(widths[0])
        let renderer = makeRenderer(
            stdinIsTerminal: stdinIsTerminal,
            standardErrorIsTerminal: true,
            columnWidthProvider: { widthBox.width }
        )

        await renderer.writeSubmittedPrompt("first turn")
        for width in widths {
            widthBox.width = width
            await renderer.writeSubmittedPrompt("turn at \(width) columns")
        }

        let stderr = await renderer.capturedPlainText(on: .standardError)
        let ruleRows = stderr.split(separator: "\n").filter { row in
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "─" }
        }

        #expect(ruleRows.map { TerminalChat.displayWidth(String($0)) } == widths.map { $0 - 1 })
    }

    @Test(arguments: [0, 1, 2, 3], [false, true])
    func submittedPromptTurnRuleClampsToAtLeastOneCharacter(
        terminalColumns: Int,
        stdinIsTerminal: Bool
    ) async {
        let inset = stdinIsTerminal ? TerminalChatTextFormatting.chatLineInsetPrefix : ""
        let renderer = makeRenderer(
            stdinIsTerminal: stdinIsTerminal,
            standardErrorIsTerminal: true,
            columnWidthProvider: { terminalColumns }
        )

        await renderer.writeSubmittedPrompt("first turn")
        await renderer.writeSubmittedPrompt("second turn")

        let stderr = await renderer.capturedPlainText(on: .standardError)
        let ruleRows = stderr.split(separator: "\n").map(String.init).filter { row in
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "─" }
        }
        let ruleWidth = max(1, terminalColumns - TerminalChat.displayWidth(inset) - 1)

        #expect(ruleRows == [inset + String(repeating: "─", count: ruleWidth)])
    }

    @Test
    func terminalThinkingShowsAllLinesAcrossDeltas() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true
        )

        await renderer.writeThought("first\nsecond\n")
        await renderer.writeThought("third\n")
        await renderer.writeThought("fourth\n")
        await renderer.finishThoughtOutput()

        let stderr = await renderer.capturedPlainText(on: .standardError)

        #expect(stderr.contains("first"))
        #expect(stderr.contains("second"))
        #expect(stderr.contains("third"))
        #expect(stderr.contains("fourth"))
        #expect(!stderr.contains("thinking lines omitted"))
    }

    @Test
    func terminalThinkingStaysContiguousAcrossDeltasAtNarrowWidth() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 8 }
        )

        // The coordinator no longer hard-wraps thinking; a narrow width must not
        // inject synthetic newlines. Send the thought across multiple deltas so
        // the streaming state is exercised, then assert the captured text is the
        // contiguous source content (plus only the coordinator's framing
        // newlines), not split by a computed column boundary.
        await renderer.writeThought("abcdefghij")
        await renderer.writeThought("klmnopqrst")
        await renderer.finishThoughtOutput()

        let stderr = await renderer.capturedPlainText(on: .standardError)

        // The whole thought survives unbroken across the narrow width.
        #expect(stderr.contains("abcdefghijklmnopqrst"))
        #expect(!stderr.contains("abcdefg\nhijklmn\n"))
        #expect(!stderr.contains("thinking lines omitted"))
    }

    @Test
    func terminalThinkingCodeBlockDoesNotAddWidthBasedContinuationMarkers() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let longLine = "let explanation = \"a deliberately long value that must remain one logical line\""

        await renderer.writeThought("```swift\n\(longLine)\n```\n")
        await renderer.finishThoughtOutput()

        let stderr = await renderer.capturedPlainText(on: .standardError)

        #expect(stderr.contains(longLine))
        #expect(!stderr.contains("↳"))
    }

    @Test
    func terminalThinkingShowsUnterminatedTail() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true
        )

        await renderer.writeThought("visible\n")
        await renderer.writeThought("hidden tail without newline")
        await renderer.finishThoughtOutput()

        let stderr = await renderer.capturedPlainText(on: .standardError)

        #expect(stderr.contains("visible"))
        #expect(stderr.contains("hidden tail without newline"))
        #expect(!stderr.contains("thinking lines omitted"))
    }

    @Test
    func nonTerminalThinkingPassesThroughUnchanged() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: false
        )

        await renderer.writeThought("first\nsecond\n")
        await renderer.writeThought("third\n")
        await renderer.finishThoughtOutput()

        let stderr = await renderer.capturedText(on: .standardError)

        #expect(stderr.contains("first\nsecond\nthird"))
        #expect(!stderr.contains("thinking lines omitted"))
    }

    @Test
    func terminalThinkingShowsAllContentAcrossStreams() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true
        )

        await renderer.writeThought("first visible\nfirst hidden\n")
        await renderer.finishThoughtOutput()
        await renderer.writeThought("second visible\nsecond hidden\n")
        await renderer.finishThoughtOutput()

        let stderr = await renderer.capturedPlainText(on: .standardError)

        #expect(stderr.contains("first visible"))
        #expect(stderr.contains("second visible"))
        #expect(stderr.contains("first hidden"))
        #expect(stderr.contains("second hidden"))
        #expect(!stderr.contains("thinking lines omitted"))
    }

    @Test
    func terminalThinkingShowsAllContentAcrossInterleavingWithoutLosingAssistantContent() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            standardOutputIsTerminal: true
        )
        let toolCall = presentedToolCall(
            id: "thought-interleave",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeThought("first visible\nfirst hidden\n")
        // Starting a tool completes the first thought stream before the tool
        // owns the terminal rows.
        await renderer.writeToolCallStarted(toolCall)
        await renderer.writeAssistantContent("Assistant answer survives")
        await renderer.finishAssistantContent()
        await renderer.writeThought("second visible\nsecond hidden\n")
        await renderer.finishStreamingOutput()

        let events = await renderer.capturedWriteEvents()
        let stderr = events.plainText(on: .standardError)
        let stdout = events.plainText(on: .standardOutput)

        #expect(stderr.contains("🛠️  agent.wait"))
        #expect(stderr.contains("Agent ⏳"))
        #expect(!stderr.contains("thinking lines omitted"))
        #expect(stderr.contains("first hidden"))
        #expect(stderr.contains("second hidden"))
        #expect(stdout.contains("Assistant answer survives"))
    }

    @Test
    func finishingNonTerminalAssistantDoesNotAppendANewline() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await renderer.writeAssistantContent("Answer*")
        await renderer.finishStreamingOutput()

        let stdout = await renderer.capturedText(on: .standardOutput)
        #expect(stdout == "💬 Answer*")
    }

    @Test
    func assistantBubblePrefixesMarkdownFirstEmittedAtFinish() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            standardOutputIsTerminal: true
        )

        await renderer.writeAssistantContent("**Answer**")
        await renderer.finishStreamingOutput()

        let stdout = await renderer.capturedText(on: .standardOutput)
        #expect(TerminalANSIText.stripANSI(stdout) == "💬 Answer\n")
    }

    @Test
    func assistantContentWithNarrowWidthStaysContiguousAfterBubblePrefix() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            standardOutputIsTerminal: true,
            columnWidthProvider: { 10 }
        )

        // The `💬 ` prefix shares the first output row. A narrow width must not
        // make the formatter inject synthetic line breaks before or after the
        // terminal's own auto-wrap: only the source newline survives.
        await renderer.writeAssistantContent("one two three four five six seven\n")
        await renderer.finishStreamingOutput()

        let stdout = await renderer.capturedText(on: .standardOutput)
        let visible = TerminalANSIText.stripANSI(stdout)

        // The bubble prefix is present and the content is contiguous.
        #expect(visible.hasPrefix("💬 "))
        #expect(visible.contains("one two three four five six seven"))
        // No synthetic line break between the prefix and the content.
        let afterPrefix = String(visible.dropFirst("💬 ".count))
        #expect(afterPrefix.hasSuffix("\n"))
        #expect(!String(afterPrefix.dropLast()).contains("\n"))
    }

    @Test
    func scheduledFlushKeepsAQuietStreamResponsive() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            streamingFlushDelay: .milliseconds(5)
        )

        await renderer.writeThought("Planning")
        await renderer.waitForScheduledStreamingFlush()

        let events = await renderer.capturedWriteEvents()
        #expect(!events.isEmpty)
        #expect(events.renderedText().contains("Planning"))

        await renderer.finishStreamingOutput()
    }

    @Test
    func firstStreamingChunkIsFlushedImmediatelyWithoutDelay() async {
        let clock = StreamingClock()
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            streamingFlushDelay: .milliseconds(32),
            streamingNow: { clock.now }
        )

        await renderer.writeAssistantContent("Answer")
        // Leading-edge: the very first chunk must already be visible
        // without waiting for the 32 ms trailing-edge timer.
        let events = await renderer.capturedWriteEvents()
        #expect(!events.isEmpty)
        #expect(events.renderedText().contains("Answer"))
    }

    @Test
    func subsequentStreamingChunksAreCoalescedAfterLeadingEdgeFlush() async {
        let clock = StreamingClock()
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            streamingFlushDelay: .seconds(5),
            streamingNow: { clock.now }
        )

        await renderer.writeAssistantContent("Answer")
        let firstCount = await renderer.capturedWriteEvents().count
        #expect(firstCount == 1)

        // Still inside the idle window: the next chunk must NOT be
        // emitted immediately — it is coalesced for the trailing-edge timer.
        // The large flush delay guarantees the real Task.sleep timer cannot
        // fire between the write and the assertion on a slow CI: the clock
        // controls the leading-edge idle check, but the timer sleeps in wall
        // time, so only an oversized delay eliminates the race.
        clock.advance(by: .milliseconds(1))
        await renderer.writeAssistantContent(" continues")
        let secondCount = await renderer.capturedWriteEvents().count
        #expect(secondCount == 1)

        // Flush the coalesced remainder deterministically. finishStreamingOutput
        // cancels the pending trailing-edge timer and emits the buffered chunk.
        await renderer.finishStreamingOutput()
        let events = await renderer.capturedWriteEvents()
        #expect(events.count == 2)
        #expect(events.renderedText().contains("Answer continues"))
    }

    @Test
    func leadingEdgeReArmsAfterIdleWindowElapses() async {
        let clock = StreamingClock()
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            streamingFlushDelay: .milliseconds(32),
            streamingNow: { clock.now }
        )

        await renderer.writeAssistantContent("First")
        let firstEvents = await renderer.capturedWriteEvents()
        #expect(firstEvents.count == 1)

        // Advance past the idle window so the leading edge re-arms.
        clock.advance(by: .milliseconds(40))
        await renderer.writeAssistantContent("Second")
        let secondEvents = await renderer.capturedWriteEvents()
        #expect(secondEvents.count == 2)
    }

    @Test
    func leadingEdgeFlushPreservesWriteEventOrder() async {
        let clock = StreamingClock()
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            streamingFlushDelay: .milliseconds(32),
            streamingNow: { clock.now }
        )

        await renderer.writeAssistantContent("alpha")
        clock.advance(by: .milliseconds(1))
        await renderer.writeAssistantContent("beta")
        await renderer.waitForScheduledStreamingFlush()

        let events = await renderer.capturedWriteEvents()
        #expect(events.count == 2)
        #expect(events.map(\.sequence) == [0, 1])
        #expect(events[0].text.contains("alpha"))
        #expect(events[1].text.contains("beta"))
    }

    @Test
    func leadingEdgeFlushPreservesCrossChannelWriteEventOrder() async {
        let clock = StreamingClock()
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            streamingFlushDelay: .seconds(5),
            streamingNow: { clock.now }
        )

        // Thought on stderr: the thinking title is the very first chunk of a
        // burst and is leading-edge flushed immediately so the user sees it
        // without waiting for the trailing-edge timer.
        await renderer.writeThought("Planning")
        let afterThought = await renderer.capturedWriteEvents()
        #expect(afterThought.allSatisfy { $0.channel == .standardError })
        #expect(afterThought.renderedText().contains("🤔"))

        // Cross-channel switch to assistant on stdout. writeAssistantContent
        // first finishes the pending thought (flushing the coalesced body and
        // trailing newlines to stderr), then buffers the assistant chunk.
        // The large flush delay guarantees the real timer cannot fire during
        // the assertions below.
        clock.advance(by: .milliseconds(1))
        await renderer.writeAssistantContent("Answer")
        let afterSwitch = await renderer.capturedWriteEvents()

        // The thought body was flushed to stderr by the finish.
        #expect(afterSwitch.renderedText(on: .standardError).contains("Planning"))
        // The assistant chunk on stdout is still coalesced behind the timer
        // (not yet flushed) because the thought-finish reset the idle window.
        #expect(afterSwitch.filter { $0.channel == .standardOutput }.isEmpty)

        // Flush the coalesced assistant remainder and cancel the timer.
        await renderer.finishStreamingOutput()
        let events = await renderer.capturedWriteEvents()

        // Sequence numbers are strictly monotonic across both channels.
        #expect(events.map(\.sequence) == Array(0..<UInt64(events.count)))

        // Every stderr (thought) event precedes every stdout (assistant) event.
        if let lastStderr = events.lastIndex(where: { $0.channel == .standardError }),
           let firstStdout = events.firstIndex(where: { $0.channel == .standardOutput }) {
            #expect(lastStderr < firstStdout)
        }

        // The assistant content is present on stdout after the flush.
        #expect(events.renderedText(on: .standardOutput).contains("Answer"))
    }

    @Test
    func thoughtAndAssistantDeltasShareOneOrderedStreamingState() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await renderer.writeThought("Planning")
        await renderer.writeThought(" safely")
        await renderer.writeAssistantContent("Answer")
        await renderer.finishStreamingOutput()

        let events = await renderer.capturedWriteEvents()
        let combined = events.renderedText()

        #expect(combined.components(separatedBy: "🤔 thinking…").count == 2)
        #expect(combined.contains("Planning safely"))
        #expect(combined.contains("Answer"))
        #expect(!combined.contains("\n\n\n"))
        if let thought = combined.firstRange(of: "Planning safely")?.lowerBound,
           let answer = combined.firstRange(of: "Answer")?.lowerBound {
            #expect(thought < answer)
        }
    }

    @Test
    func separateTerminalTopologyClosesAssistantOutputUsingStdoutCursor() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            standardOutputIsTerminal: true,
            cursorTopology: .separate
        )

        await renderer.writeAssistantContent("Answer")
        // stderr ends a row on its own terminal, not on stdout's terminal.
        await renderer.writeError("\n")
        await renderer.finishAssistantContent()

        let stdout = await renderer.capturedText(on: .standardOutput)
        #expect(TerminalANSIText.stripANSI(stdout) == "💬 Answer\n")
    }

    @Test
    func sharedTerminalTopologyReusesTheErrorCursorForAssistantCompletion() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            standardOutputIsTerminal: true,
            cursorTopology: .shared
        )

        await renderer.writeAssistantContent("Answer")
        await renderer.writeError("\n")
        await renderer.finishAssistantContent()

        let stdout = await renderer.capturedText(on: .standardOutput)
        // The shared stderr newline already closed the physical row, so stdout
        // must not add a duplicate line boundary.
        #expect(TerminalANSIText.stripANSI(stdout) == "💬 Answer")
    }

    @Test
    func aLoneThoughtAsteriskIsFlushedAtEndOfStream() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await renderer.writeThought("*")
        await renderer.finishThoughtOutput()

        let stderr = await renderer.capturedText(on: .standardError)
        #expect(stderr.contains("🤔 thinking…"))
        #expect(stderr.contains("*"))
    }
}
