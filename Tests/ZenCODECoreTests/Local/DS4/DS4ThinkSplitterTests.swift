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

/// One streamed input and the content/thought it must produce.
struct DS4ThinkSplitterCase: Sendable, CustomTestStringConvertible {
    let name: String
    let startsInThinking: Bool
    let chunks: [String]
    let content: String
    /// `nil` when the case does not constrain the thought.
    let thought: String?

    var testDescription: String { name }
}

private let splitterCases: [DS4ThinkSplitterCase] = [
    .init(name: "plain content", startsInThinking: false, chunks: ["hello world"], content: "hello world", thought: ""),
    .init(name: "think block in content", startsInThinking: false,
          chunks: ["before<think>reasoning</think>after"], content: "beforeafter", thought: "reasoning"),
    .init(name: "starts in thinking until close tag", startsInThinking: true,
          chunks: ["deep thoughts</think>visible"], content: "visible", thought: "deep thoughts"),
    .init(name: "unterminated thinking flushes as thought", startsInThinking: true,
          chunks: ["still thinking"], content: "", thought: "still thinking"),
    .init(name: "close tag split across chunks", startsInThinking: true,
          chunks: ["reasoning</th", "ink>visible"], content: "visible", thought: "reasoning"),
    .init(name: "open tag split across chunks", startsInThinking: false,
          chunks: ["visible<thi", "nk>secret</think>tail"], content: "visibletail", thought: "secret"),
    .init(name: "channel-style tags ignored by default", startsInThinking: false,
          chunks: ["a<|channel>thought<channel|>b"], content: "a<|channel>thought<channel|>b", thought: nil),
    .init(name: "leading newlines after think close", startsInThinking: true,
          chunks: ["reasoning</think>\n\n\nvisible"], content: "visible", thought: "reasoning"),
    .init(name: "leading newlines across chunks", startsInThinking: true,
          chunks: ["reasoning</think>", "\n\n", "\nvisible"], content: "visible", thought: "reasoning"),
    .init(name: "leading spaces and tabs like ds4_agent", startsInThinking: true,
          chunks: ["reasoning</think> \t\r\n visible"], content: "visible", thought: nil),
    .init(name: "newlines within content preserved", startsInThinking: true,
          chunks: ["reasoning</think>line1\n\nline2"], content: "line1\n\nline2", thought: nil),
    .init(name: "reasoning whitespace preserved", startsInThinking: false,
          chunks: ["<think>\n step \n</think>x"], content: "x", thought: "\n step \n"),
    .init(name: "stray close tag in content", startsInThinking: false,
          chunks: ["hello</think>world"], content: "helloworld", thought: ""),
    .init(name: "stray close tag split across chunks", startsInThinking: false,
          chunks: ["hello</thin", "k>world"], content: "helloworld", thought: nil),
    .init(name: "well-formed span with trailing stray close", startsInThinking: false,
          chunks: ["a<think>secret</think>b</think>c"], content: "abc", thought: "secret"),
    .init(name: "nested open tag inside thinking dropped", startsInThinking: true,
          chunks: ["one<think>two</think>three"], content: "three", thought: "onetwo"),
    .init(name: "unfinished tag prefix released at finish", startsInThinking: false,
          chunks: ["tail <thin"], content: "tail <thin", thought: nil),
]

@Suite
struct DS4ThinkSplitterTests {
    @Test(arguments: splitterCases)
    func splitsStreamedTextIntoContentAndThought(_ testCase: DS4ThinkSplitterCase) {
        var splitter = DS4ThinkSplitter(startsInThinking: testCase.startsInThinking)
        var parts: [DS4ThinkSplitter.Part] = []
        for chunk in testCase.chunks {
            parts += splitter.consume(chunk)
        }
        parts += splitter.finish()
        let result = render(parts)
        #expect(result.content == testCase.content)
        if let thought = testCase.thought {
            #expect(result.thought == thought)
        }
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
