//
//  DS4TranscriptSplitterTests.swift
//  ZenCODE
//

#if ZENCODE_LOCAL_DS4
import Foundation
import Testing
@testable import zen

private func render(_ parts: [DS4TranscriptSplitter.Part]) -> (content: String, thought: String) {
    var content = ""
    var thought = ""
    for part in parts {
        switch part {
        case .content(let text):
            content += text
        case .thought(let text):
            thought += text
        }
    }
    return (content, thought)
}

@Suite
struct DS4TranscriptSplitterTests {
    @Test
    func plainContentWithoutThinking() {
        var splitter = DS4TranscriptSplitter(startsInThinking: false)
        let result = render(splitter.consume("hello world") + splitter.finish())
        #expect(result.content == "hello world")
        #expect(result.thought.isEmpty)
    }

    @Test
    func extractsThinkBlockFromContent() {
        var splitter = DS4TranscriptSplitter(startsInThinking: false)
        let result = render(
            splitter.consume("before<think>reasoning</think>after") + splitter.finish()
        )
        #expect(result.content == "beforeafter")
        #expect(result.thought == "reasoning")
    }

    @Test
    func startsInThinkingUntilCloseTag() {
        var splitter = DS4TranscriptSplitter(startsInThinking: true)
        let result = render(
            splitter.consume("deep thoughts</think>visible") + splitter.finish()
        )
        #expect(result.thought == "deep thoughts")
        #expect(result.content == "visible")
    }

    @Test
    func unterminatedThinkingFlushesAsThought() {
        var splitter = DS4TranscriptSplitter(startsInThinking: true)
        let result = render(splitter.consume("still thinking") + splitter.finish())
        #expect(result.thought == "still thinking")
        #expect(result.content.isEmpty)
    }

    @Test
    func handlesCloseTagSplitAcrossChunks() {
        var splitter = DS4TranscriptSplitter(startsInThinking: true)
        var parts = splitter.consume("reasoning</th")
        parts += splitter.consume("ink>visible")
        parts += splitter.finish()
        let result = render(parts)
        #expect(result.thought == "reasoning")
        #expect(result.content == "visible")
    }

    @Test
    func handlesOpenTagSplitAcrossChunks() {
        var splitter = DS4TranscriptSplitter(startsInThinking: false)
        var parts = splitter.consume("visible<thi")
        parts += splitter.consume("nk>secret</think>tail")
        parts += splitter.finish()
        let result = render(parts)
        #expect(result.content == "visibletail")
        #expect(result.thought == "secret")
    }

    @Test
    func supportsChannelStyleThoughtTags() {
        var splitter = DS4TranscriptSplitter(startsInThinking: false)
        let result = render(
            splitter.consume("a<|channel>thoughtreasoning<channel|>b") + splitter.finish()
        )
        #expect(result.content == "ab")
        #expect(result.thought == "reasoning")
    }

    // MARK: - Bug 1: leading newlines after thinking boundary

    @Test
    func stripsLeadingNewlinesAfterThinkClose() {
        var splitter = DS4TranscriptSplitter(startsInThinking: true)
        let result = render(
            splitter.consume("reasoning</think>\n\n\nvisible") + splitter.finish()
        )
        #expect(result.thought == "reasoning")
        #expect(result.content == "visible")
    }

    @Test
    func stripsLeadingNewlinesAcrossChunks() {
        var splitter = DS4TranscriptSplitter(startsInThinking: true)
        var parts = splitter.consume("reasoning</think>")
        parts += splitter.consume("\n\n")
        parts += splitter.consume("\nvisible")
        parts += splitter.finish()
        let result = render(parts)
        #expect(result.thought == "reasoning")
        #expect(result.content == "visible")
    }

    @Test
    func preservesNewlinesWithinContent() {
        var splitter = DS4TranscriptSplitter(startsInThinking: true)
        let result = render(
            splitter.consume("reasoning</think>line1\n\nline2") + splitter.finish()
        )
        #expect(result.content == "line1\n\nline2")
    }

    // MARK: - Bug 2: stray close tags in visible content

    @Test
    func stripsStrayCloseTagInContent() {
        var splitter = DS4TranscriptSplitter(startsInThinking: false)
        let result = render(
            splitter.consume("hello</think>world") + splitter.finish()
        )
        #expect(result.content == "helloworld")
        #expect(result.thought.isEmpty)
    }

    @Test
    func stripsStrayCloseTagSplitAcrossChunks() {
        var splitter = DS4TranscriptSplitter(startsInThinking: false)
        var parts = splitter.consume("hello</thin")
        parts += splitter.consume("k>world")
        parts += splitter.finish()
        let result = render(parts)
        #expect(result.content == "helloworld")
    }

    @Test
    func preservesWellFormedThinkSpanWithTrailingStrayClose() {
        var splitter = DS4TranscriptSplitter(startsInThinking: false)
        let result = render(
            splitter.consume("a<think>secret</think>b</think>c") + splitter.finish()
        )
        #expect(result.content == "abc")
        #expect(result.thought == "secret")
    }

    @Test
    func streamingFilterSplitsThoughtAndContent() {
        var filter = DS4StreamingOutputFilter(startsInThinking: true)
        var parts = filter.consume("reasoning</th")
        parts += filter.consume("ink>visible")
        parts += filter.finish()

        let result = render(parts)
        #expect(result.thought == "reasoning")
        #expect(result.content == "visible")
    }

    @Test
    func streamingFilterSuppressesToolCallsAcrossChunks() {
        let marker = DS4ToolBridge.toolCallsStart
        let splitIndex = marker.index(marker.startIndex, offsetBy: 5)
        var filter = DS4StreamingOutputFilter(startsInThinking: false)
        var parts = filter.consume("visible " + String(marker[..<splitIndex]))
        parts += filter.consume(String(marker[splitIndex...]) + "\n<｜DSML｜invoke name=\"noop\">")
        parts += filter.finish()

        let result = render(parts)
        #expect(result.content == "visible ")
        #expect(result.thought.isEmpty)
    }

    @Test
    func streamingFilterDoesNotLeakPartialToolMarker() {
        let marker = DS4ToolBridge.toolCallsStart
        let splitIndex = marker.index(marker.startIndex, offsetBy: 3)
        var filter = DS4StreamingOutputFilter(startsInThinking: false)

        let firstParts = render(filter.consume("prefix " + String(marker[..<splitIndex])))
        #expect(firstParts.content == "prefix ")

        let result = render(
            filter.consume(String(marker[splitIndex...]) + " hidden") + filter.finish()
        )
        #expect(result.content.isEmpty)
        #expect(result.thought.isEmpty)
    }

    @Test
    func streamingFilterSuppressesToolCallsInsideThinking() {
        let marker = DS4ToolBridge.toolCallsStart
        let splitIndex = marker.index(marker.startIndex, offsetBy: 5)
        var filter = DS4StreamingOutputFilter(startsInThinking: true)

        var parts = filter.consume("reasoning " + String(marker[..<splitIndex]))
        parts += filter.consume(String(marker[splitIndex...]) + "\n<｜DSML｜invoke name=\"noop\">")
        parts += filter.finish()

        let result = render(parts)
        #expect(result.thought == "reasoning ")
        #expect(result.content.isEmpty)
    }

    @Test
    func utf8StreamDecoderBuffersSplitScalars() {
        var decoder = DS4UTF8StreamDecoder()
        let bytes = Array("ciao 🙂".utf8)
        let splitIndex = bytes.count - 2

        let first = decoder.consume(Array(bytes[..<splitIndex]))
        let second = decoder.consume(Array(bytes[splitIndex...]))

        #expect(first + second + decoder.finish() == "ciao 🙂")
        #expect(!first.contains("\u{FFFD}"))
        #expect(!second.contains("\u{FFFD}"))
    }

    @Test
    func streamingFilterSuppressesToolMarkerSplitInsideUTF8Scalar() {
        let marker = DS4ToolBridge.toolCallsStart
        let markerBytes = Array(marker.utf8)
        var decoder = DS4UTF8StreamDecoder()
        var filter = DS4StreamingOutputFilter(startsInThinking: false)

        let firstText = decoder.consume(Array(markerBytes.prefix(2)))
        let firstParts = render(filter.consume("prefix " + firstText))
        #expect(firstParts.content == "prefix ")

        let secondBytes = Array(markerBytes.dropFirst(2)) + Array(" hidden".utf8)
        let secondText = decoder.consume(secondBytes) + decoder.finish()
        let result = render(filter.consume(secondText) + filter.finish())

        #expect(result.content.isEmpty)
        #expect(result.thought.isEmpty)
    }
}
#endif
