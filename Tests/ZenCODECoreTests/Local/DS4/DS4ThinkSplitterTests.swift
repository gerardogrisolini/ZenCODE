//
//  DS4ThinkSplitterTests.swift
//  ZenCODE
//
//  Ported from abd128942:Tests/ZenCODEDS4Tests/DS4TranscriptSplitterTests.swift.
//

import Foundation
import Testing
@testable import ZenCODECore

private func render(_ parts: [DS4ThinkSplitter.Part]) -> (content: String, thought: String) {
    var content = ""
    var thought = ""
    for part in parts {
        switch part {
        case let .content(text):
            content += text
        case let .thought(text):
            thought += text
        }
    }
    return (content, thought)
}

@Suite
struct DS4ThinkSplitterTests {
    @Test
    func plainContentWithoutThinking() {
        var splitter = DS4ThinkSplitter(startsInThinking: false)
        let result = render(splitter.consume("hello world") + splitter.finish())
        #expect(result.content == "hello world")
        #expect(result.thought.isEmpty)
    }

    @Test
    func extractsThinkBlockFromContent() {
        var splitter = DS4ThinkSplitter(startsInThinking: false)
        let result = render(splitter.consume("before<think>reasoning</think>after") + splitter.finish())
        #expect(result.content == "beforeafter")
        #expect(result.thought == "reasoning")
    }

    @Test
    func startsInThinkingUntilCloseTag() {
        var splitter = DS4ThinkSplitter(startsInThinking: true)
        let result = render(splitter.consume("deep thoughts</think>visible") + splitter.finish())
        #expect(result.thought == "deep thoughts")
        #expect(result.content == "visible")
    }

    @Test
    func unterminatedThinkingFlushesAsThought() {
        var splitter = DS4ThinkSplitter(startsInThinking: true)
        let result = render(splitter.consume("still thinking") + splitter.finish())
        #expect(result.thought == "still thinking")
        #expect(result.content.isEmpty)
    }

    @Test
    func handlesCloseTagSplitAcrossChunks() {
        var splitter = DS4ThinkSplitter(startsInThinking: true)
        var parts = splitter.consume("reasoning</th")
        parts += splitter.consume("ink>visible")
        parts += splitter.finish()
        let result = render(parts)
        #expect(result.thought == "reasoning")
        #expect(result.content == "visible")
    }

    @Test
    func handlesOpenTagSplitAcrossChunks() {
        var splitter = DS4ThinkSplitter(startsInThinking: false)
        var parts = splitter.consume("visible<thi")
        parts += splitter.consume("nk>secret</think>tail")
        parts += splitter.finish()
        let result = render(parts)
        #expect(result.content == "visibletail")
        #expect(result.thought == "secret")
    }

    @Test
    func holdsOnlyTheSuffixThatCanStartATag() {
        var splitter = DS4ThinkSplitter(startsInThinking: false)
        let first = render(splitter.consume("a < b <th"))
        #expect(first.content == "a < b ")
        #expect(splitter.hasPendingText)
        let second = render(splitter.consume("ree"))
        #expect(second.content == "<three")
        #expect(!splitter.hasPendingText)
    }

    @Test
    func supportsChannelStyleThoughtTagsWhenConfigured() {
        var splitter = DS4ThinkSplitter(
            startsInThinking: false,
            openTags: ["<think>", "<|channel>thought"],
            closeTags: ["</think>", "<channel|>"]
        )
        let result = render(splitter.consume("a<|channel>thoughtreasoning<channel|>b") + splitter.finish())
        #expect(result.content == "ab")
        #expect(result.thought == "reasoning")
    }

    @Test
    func ignoresChannelStyleTagsByDefault() {
        var splitter = DS4ThinkSplitter(startsInThinking: false)
        let result = render(splitter.consume("a<|channel>thought<channel|>b") + splitter.finish())
        #expect(result.content == "a<|channel>thought<channel|>b")
    }

    // MARK: - Leading whitespace after the thinking boundary

    @Test
    func stripsLeadingNewlinesAfterThinkClose() {
        var splitter = DS4ThinkSplitter(startsInThinking: true)
        let result = render(splitter.consume("reasoning</think>\n\n\nvisible") + splitter.finish())
        #expect(result.thought == "reasoning")
        #expect(result.content == "visible")
    }

    @Test
    func stripsLeadingNewlinesAcrossChunks() {
        var splitter = DS4ThinkSplitter(startsInThinking: true)
        var parts = splitter.consume("reasoning</think>")
        parts += splitter.consume("\n\n")
        parts += splitter.consume("\nvisible")
        parts += splitter.finish()
        let result = render(parts)
        #expect(result.thought == "reasoning")
        #expect(result.content == "visible")
    }

    @Test
    func stripsLeadingSpacesAndTabsAfterThinkCloseLikeDS4Agent() {
        var splitter = DS4ThinkSplitter(startsInThinking: true)
        let result = render(splitter.consume("reasoning</think> \t\r\n visible") + splitter.finish())
        #expect(result.content == "visible")
    }

    @Test
    func preservesNewlinesWithinContent() {
        var splitter = DS4ThinkSplitter(startsInThinking: true)
        let result = render(splitter.consume("reasoning</think>line1\n\nline2") + splitter.finish())
        #expect(result.content == "line1\n\nline2")
    }

    @Test
    func preservesReasoningWhitespace() {
        var splitter = DS4ThinkSplitter(startsInThinking: false)
        let result = render(splitter.consume("<think>\n step \n</think>x") + splitter.finish())
        #expect(result.thought == "\n step \n")
        #expect(result.content == "x")
    }

    // MARK: - Stray tags

    @Test
    func stripsStrayCloseTagInContent() {
        var splitter = DS4ThinkSplitter(startsInThinking: false)
        let result = render(splitter.consume("hello</think>world") + splitter.finish())
        #expect(result.content == "helloworld")
        #expect(result.thought.isEmpty)
    }

    @Test
    func stripsStrayCloseTagSplitAcrossChunks() {
        var splitter = DS4ThinkSplitter(startsInThinking: false)
        var parts = splitter.consume("hello</thin")
        parts += splitter.consume("k>world")
        parts += splitter.finish()
        #expect(render(parts).content == "helloworld")
    }

    @Test
    func preservesWellFormedThinkSpanWithTrailingStrayClose() {
        var splitter = DS4ThinkSplitter(startsInThinking: false)
        let result = render(splitter.consume("a<think>secret</think>b</think>c") + splitter.finish())
        #expect(result.content == "abc")
        #expect(result.thought == "secret")
    }

    @Test
    func nestedOpenTagInsideThinkingIsDropped() {
        var splitter = DS4ThinkSplitter(startsInThinking: true)
        let result = render(splitter.consume("one<think>two</think>three") + splitter.finish())
        #expect(result.thought == "onetwo")
        #expect(result.content == "three")
    }

    @Test
    func unfinishedTagPrefixIsReleasedAtFinish() {
        var splitter = DS4ThinkSplitter(startsInThinking: false)
        var parts = splitter.consume("tail <thin")
        parts += splitter.finish()
        #expect(render(parts).content == "tail <thin")
    }

    // MARK: - Byte API

    @Test
    func byteAPIReportsConsumedTags() {
        var splitter = DS4ThinkSplitter(startsInThinking: false)
        var events: [DS4ThinkSplitter.Event] = []
        for byte in "a<think>b</think>c".utf8 {
            events += splitter.consumeBytes(CollectionOfOne(byte))
        }
        events += splitter.finishBytes()
        #expect(events == [
            .text(thought: false, bytes: Array("a".utf8)),
            .tag(bytes: Array("<think>".utf8), opensThinking: true),
            .text(thought: true, bytes: Array("b".utf8)),
            .tag(bytes: Array("</think>".utf8), opensThinking: false),
            .text(thought: false, bytes: Array("c".utf8)),
        ])
    }

    @Test
    func multibyteTextSplitAtEveryByteIsPreserved() {
        let text = "ciao 🙂 <think>pensiero ｜ unicode</think> fine ｜DSML｜"
        let bytes = Array(text.utf8)
        for split in 0...bytes.count {
            var splitter = DS4ThinkSplitter(startsInThinking: false)
            var events = splitter.consumeBytes(bytes[..<split])
            events += splitter.consumeBytes(bytes[split...])
            events += splitter.finishBytes()
            var content: [UInt8] = []
            var thought: [UInt8] = []
            for case let .text(isThought, chunk) in events {
                if isThought {
                    thought += chunk
                } else {
                    content += chunk
                }
            }
            #expect(String(decoding: content, as: UTF8.self) == "ciao 🙂 fine ｜DSML｜")
            #expect(String(decoding: thought, as: UTF8.self) == "pensiero ｜ unicode")
        }
    }
}
