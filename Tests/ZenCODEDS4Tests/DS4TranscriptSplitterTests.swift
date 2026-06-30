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
}
#endif
