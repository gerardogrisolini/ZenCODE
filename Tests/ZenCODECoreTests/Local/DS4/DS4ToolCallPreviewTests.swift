//
//  DS4ToolCallPreviewTests.swift
//  ZenCODE
//
//  Live tool-call preview of the DS4 path: the fragments produced by
//  `DS4ToolCallStreamParser`/`DS4GeneratedOutputParser` while a call is
//  generated, and their forwarding by `DS4GenerationBridge` and the client.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

// MARK: - Harness

private typealias Preview = DirectAgentToolCallPreview

private func previews(in events: [DirectAgentEvent]) -> [Preview] {
    events.compactMap { event in
        if case let .toolCallPreview(preview) = event {
            return preview
        }
        return nil
    }
}

// MARK: - Tests

@Suite("DS4 tool-call preview")
struct DS4ToolCallPreviewTests {
    // MARK: Event sequence

    @Test(arguments: DS4ToolSyntax.allCases)
    func multilineFileWriteProducesTheFullSequence(syntax: DS4ToolSyntax) throws {
        let text = prose + writeBlock(syntax)
        let raws = rawValues(text, syntax: syntax)
        #expect(raws == [filePath, fileContent])

        for chunks in [[text], bytewiseChunks(text), splitChunks(text, at: Array(stride(from: 7, to: text.utf8.count, by: 7)))] {
            let run = previewRun(chunks, syntax: syntax)
            #expect(merged(run.previews) == writePreviews(content: fileContent))
            #expect(closedParameterTexts(run.previews) == raws)
            expectStreamedPrefixes(run.drains, rawValues: raws)
            let output = try #require(run.output)
            #expect(output.parseError == nil)
            #expect(output.toolCalls.map(\.name) == ["local.writeFile"])
            #expect(try stringArguments(output.toolCalls.first) == ["path": filePath, "content": fileContent])
        }
    }

    @Test(arguments: DS4ToolSyntax.allCases)
    func valueBytesAreReleasedAsSoonAsTheyAreSafe(syntax: DS4ToolSyntax) {
        let markup = Markup(syntax: syntax)
        let chunks = [
            prose + markup.blockOpen + markup.callOpen("local.writeFile") + markup.parameterOpen("content"),
            "line one\n",
            "a <",
            " b",
            "\nend",
            markup.parameterClose + markup.callClose + markup.blockClose,
        ]
        let run = previewRun(chunks, syntax: syntax)
        let qwen = syntax == .qwen
        // Qwen holds a newline that may be the one removed before the tag.
        let expected: [[Preview]] = [
            [.toolStarted(name: "local.writeFile"), .parameterStarted(name: "content")],
            [.parameterText(qwen ? "line one" : "line one\n")],
            [.parameterText(qwen ? "\na " : "a ")],
            [.parameterText("< b")],
            [.parameterText("\nend")],
            syntax.usesDSML ? [.parameterEnded, .ended] : [.parameterEnded],
            syntax.usesDSML ? [] : [.ended],
        ]
        #expect(run.drains == expected)
        #expect(closedParameterTexts(run.previews) == ["line one\na < b\nend"])
    }

    @Test(arguments: DS4ToolSyntax.allCases)
    func previewsDoNotDependOnChunking(syntax: DS4ToolSyntax) throws {
        let text = prose + writeBlock(syntax)
        let raws = rawValues(text, syntax: syntax)
        let expected = merged(previewRun([text], syntax: syntax).previews)
        #expect(expected == writePreviews(content: fileContent))

        let bytewise = previewRun(bytewiseChunks(text), syntax: syntax)
        #expect(merged(bytewise.previews) == expected)
        expectStreamedPrefixes(bytewise.drains, rawValues: raws)

        // The closing tag of `content` split at every point: the first chunk
        // already released the whole value, and no fragment holds tag bytes.
        let close = try #require(lastByteRange(of: syntax.parameterCloseMarker, in: text))
        for offset in close.lowerBound..<close.upperBound {
            let run = previewRun(splitChunks(text, at: [offset]), syntax: syntax)
            #expect(merged(run.previews) == expected, "split at \(offset)")
            #expect(openParameterText(run.drains[0]) == fileContent, "split at \(offset)")
            #expect(closedParameterTexts(run.previews) == raws)
            for fragment in fragments(run.previews) {
                #expect(!fragment.contains(syntax.parameterCloseMarker))
            }
        }
    }

    @Test(arguments: DS4ToolSyntax.allCases)
    func literalMarkupAndEscapedClosingTagStayRaw(syntax: DS4ToolSyntax) throws {
        let escapedClose = "&lt;" + String(syntax.parameterCloseMarker.dropFirst())
        let content = "a < b <= c\n<p>x</p> </tool_call> <think> </\n" + escapedClose + " tail <"
        let text = writeBlock(syntax, content: content + " end")
        let raws = rawValues(text, syntax: syntax)
        #expect(raws == [filePath, content + " end"])

        for chunks in [[text], bytewiseChunks(text)] {
            let run = previewRun(chunks, syntax: syntax)
            #expect(merged(run.previews) == writePreviews(content: content + " end"))
            expectStreamedPrefixes(run.drains, rawValues: raws)
            let output = try #require(run.output)
            // The argument is unescaped; the preview keeps the raw text.
            let unescaped = "a < b <= c\n<p>x</p> </tool_call> <think> </\n" + syntax.parameterCloseMarker + " tail < end"
            #expect(try stringArguments(output.toolCalls.first)["content"] == unescaped)
        }
    }

    @Test(arguments: DS4ToolSyntax.allCases)
    func aValueEndingWithLessThanRightBeforeItsClosingTagIsStreamedWhole(syntax: DS4ToolSyntax) throws {
        let markup = Markup(syntax: syntax)
        // The closing tag right after the `<`: for Qwen, without the newline
        // it usually writes before the tag.
        let close = syntax == .qwen ? syntax.parameterCloseMarker + "\n" : markup.parameterClose
        for content in ["a <", "<", "x\n<", "a <<"] {
            let text = markup.blockOpen + markup.callOpen("local.writeFile") + markup.parameterOpen("content")
                + content + close + markup.callClose + markup.blockClose
            let raws = rawValues(text, syntax: syntax)
            #expect(raws == [content], "\(content.debugDescription)")

            let tag = try #require(lastByteRange(of: syntax.parameterCloseMarker, in: text))
            var splits = [[text], bytewiseChunks(text)]
            for offset in tag.lowerBound..<tag.upperBound {
                splits.append(splitChunks(text, at: [offset]))
            }
            for chunks in splits {
                let run = previewRun(chunks, syntax: syntax)
                #expect(closedParameterTexts(run.previews) == [content], "\(content.debugDescription)")
                expectStreamedPrefixes(run.drains, rawValues: raws)
                #expect(endedCount(run.previews) == 1)
                for fragment in fragments(run.previews) {
                    #expect(!fragment.contains(syntax.parameterCloseMarker))
                }
                let output = try #require(run.output)
                #expect(output.parseError == nil)
                #expect(try stringArguments(output.toolCalls.first) == ["content": content])
            }
        }
    }

    @Test
    func tolerantDSMLClosingTagIsNeverStreamed() {
        for syntax in [DS4ToolSyntax.dsml, .dsml41] {
            let closeName = syntax.dsmlTagName(.parameter)
            let text = syntax.toolCallOpenMarker + "\n" + syntax.dsmlOpenTag(.invoke) + " name=\"local.writeFile\">\n"
                + syntax.dsmlOpenTag(.parameter) + " name=\"content\" string=\"true\">x </｜DSML｜ y"
                + "</｜DSML｜\(closeName) \n｜ >\n"
                + syntax.dsmlCloseTag(.invoke) + "\n" + syntax.dsmlCloseTag(.toolCalls)
            let raws = rawValues(text, syntax: syntax)
            #expect(raws == ["x </｜DSML｜ y"])
            for chunks in [[text], bytewiseChunks(text)] {
                let run = previewRun(chunks, syntax: syntax)
                #expect(closedParameterTexts(run.previews) == raws)
                expectStreamedPrefixes(run.drains, rawValues: raws)
                #expect(endedCount(run.previews) == 1)
            }
        }
    }

    // MARK: UTF-8

    @Test(arguments: DS4ToolSyntax.allCases)
    func scalarSplitBetweenChunksLeavesWhole(syntax: DS4ToolSyntax) throws {
        let content = "αβ🙂γ"
        let text = Markup(syntax: syntax).block([("local.writeFile", [("content", content)])])
        let scalar = try #require(lastByteRange(of: "🙂", in: text))
        for cut in scalar.lowerBound + 1..<scalar.upperBound {
            let run = previewRun(splitChunks(text, at: [cut]), syntax: syntax)
            #expect(openParameterText(run.drains[0]) == "αβ")
            #expect(fragments(run.drains[1]).first?.hasPrefix("🙂") == true)
            #expect(closedParameterTexts(run.previews) == [content])
            #expect(!fragments(run.previews).joined().contains("\u{FFFD}"))
        }
    }

    @Test(arguments: DS4ToolSyntax.allCases)
    func streamParserCutsFragmentsAtScalarBoundaries(syntax: DS4ToolSyntax) {
        let content = "é🙂x"
        let text = Markup(syntax: syntax).block([("local.writeFile", [("content", content)])])
        var parser = DS4ToolCallStreamParser(syntax: syntax)
        var previews: [Preview] = []
        // A drain after every byte: a scalar is emitted once all its bytes arrived.
        for byte in text.utf8 {
            parser.feed(byte: byte)
            previews += parser.drainPreviews(blockEnded: false)
        }
        parser.finish()
        previews += parser.drainPreviews(blockEnded: true)
        #expect(fragments(previews) == ["é", "🙂", "x"])
        #expect(previews.first == .toolStarted(name: "local.writeFile"))
        #expect(parser.calls.flatMap(\.arguments).map(\.rawValue) == [content])
    }

    // MARK: Qwen newlines

    @Test
    func qwenRemovesOneNewlineOnEachSideOnly() {
        let values = ["", "\n", "x", "\nx\n", "\n\nx\n\n", "a\n\nb"]
        for value in values {
            for (open, close) in [("\n", "\n"), ("", ""), ("\n", ""), ("", "\n")] {
                let text = "<tool_call>\n<function=local.writeFile>\n<parameter=content>" + open + value + close
                    + "</parameter>\n</function>\n</tool_call>"
                let raws = rawValues(text, syntax: .qwen)
                #expect(raws.count == 1)
                for chunks in [[text], bytewiseChunks(text)] {
                    let run = previewRun(chunks, syntax: .qwen)
                    #expect(closedParameterTexts(run.previews) == raws, "value \((open + value + close).debugDescription)")
                    expectStreamedPrefixes(run.drains, rawValues: raws)
                }
            }
        }
    }

    // MARK: Block lifecycle

    @Test(arguments: DS4ToolSyntax.allCases)
    func everyCallOfABlockStartsAndTheBlockEndsOnce(syntax: DS4ToolSyntax) throws {
        let text = Markup(syntax: syntax).block([
            ("local.readFile", [("path", "a.swift")]),
            ("local.writeFile", [("path", "b.swift"), ("content", "x\n")]),
        ])
        for chunks in [[text], bytewiseChunks(text)] {
            let run = previewRun(chunks, syntax: syntax)
            #expect(merged(run.previews) == [
                .toolStarted(name: "local.readFile"),
                .parameterStarted(name: "path"),
                .parameterText("a.swift"),
                .parameterEnded,
                .toolStarted(name: "local.writeFile"),
                .parameterStarted(name: "path"),
                .parameterText("b.swift"),
                .parameterEnded,
                .parameterStarted(name: "content"),
                .parameterText("x\n"),
                .parameterEnded,
                .ended,
            ])
            #expect(try #require(run.output).toolCalls.map(\.name) == ["local.readFile", "local.writeFile"])
        }
    }

    @Test
    func malformedBlockEndsOnceAndOnlyAfterAToolStarted() throws {
        let cases: [(syntax: DS4ToolSyntax, text: String, expected: [Preview])] = [
            (
                .dsml,
                "<｜DSML｜tool_calls>\n<｜DSML｜invoke name=\"local.readFile\">\n<｜DSML｜bogus name=\"x\">",
                [.toolStarted(name: "local.readFile"), .ended]
            ),
            (
                .glm,
                "<tool_call>local.readFile<arg_key>path</arg_key>oops</tool_call>",
                [.toolStarted(name: "local.readFile"), .ended]
            ),
            (
                .qwen,
                "<tool_call>\n<function=local.readFile>\n<parameter=path>\na\n</parameter>\n</function>\nnope",
                [.toolStarted(name: "local.readFile"), .parameterStarted(name: "path"), .parameterText("a"), .parameterEnded, .ended]
            ),
            // Malformed before any tool name: nothing was shown, nothing to end.
            (.dsml, "<｜DSML｜tool_calls>\n<｜DSML｜bogus>", []),
            (.dsml41, "<｜DSML｜ calls>\n<｜DSML｜ invoke>", []),
            (.qwen, "<tool_call>\nfoo", []),
        ]
        for entry in cases {
            for chunks in [[entry.text], bytewiseChunks(entry.text)] {
                let run = previewRun(chunks, syntax: entry.syntax)
                #expect(merged(run.previews) == entry.expected, "\(entry.text.debugDescription)")
                #expect(try #require(run.output).parseError != nil)
                // `ended` comes with the byte that made the block malformed.
                if !entry.expected.isEmpty {
                    let stopIndex = try #require(run.flags.firstIndex { $0.stop })
                    #expect(run.drains[stopIndex].last == .ended)
                }
            }
        }
    }

    @Test(arguments: DS4ToolSyntax.allCases)
    func truncatedBlockEndsAtFinishDroppingHeldBytes(syntax: DS4ToolSyntax) throws {
        let markup = Markup(syntax: syntax)
        let openValue = prose + markup.blockOpen + markup.callOpen("local.writeFile")
            + markup.parameterOpen("content") + "partial line\nnext <"
        let openCall = prose + markup.blockOpen + markup.callOpen("local.writeFile")
            + markup.parameterOpen("path") + "a.swift" + markup.parameterClose
        let cases: [(text: String, expected: [Preview])] = [
            (openValue, [
                .toolStarted(name: "local.writeFile"),
                .parameterStarted(name: "content"),
                .parameterText("partial line\nnext "),
                .ended,
            ]),
            (openCall, [
                .toolStarted(name: "local.writeFile"),
                .parameterStarted(name: "path"),
                .parameterText("a.swift"),
                .parameterEnded,
                .ended,
            ]),
        ]
        for entry in cases {
            for chunks in [[entry.text], bytewiseChunks(entry.text)] {
                let run = previewRun(chunks, syntax: syntax)
                #expect(merged(run.previews) == entry.expected)
                #expect(run.drains.last?.last == .ended)
                #expect(endedCount(run.previews) == 1)
                #expect(try #require(run.output).parseError?.detail == "incomplete \(syntax.displayName) tool call")
            }
        }
    }

    @Test(arguments: DS4ToolSyntax.allCases)
    func toolCallInsideThinkingOrStrayMarkupHasNoPreview(syntax: DS4ToolSyntax) throws {
        let block = Markup(syntax: syntax).block([("local.readFile", [("path", "a")])])
        for chunks in [["plan " + block], bytewiseChunks("plan " + block + "</think>")] {
            let run = previewRun(chunks, syntax: syntax, thinking: true)
            #expect(run.previews.isEmpty)
            #expect(try #require(run.output).parseError?.detail == DS4GeneratedOutputParser.thinkingToolCallDetail)
        }
        if syntax.usesDSML {
            let run = previewRun(["see ｜DSML｜ later"], syntax: syntax)
            #expect(run.previews.isEmpty)
            #expect(try #require(run.output).parseError?.detail == DS4GeneratedOutputParser.strayDSMLDetail)
        }
    }

    @Test(arguments: DS4ToolSyntax.allCases)
    func textHeldBeforeTheOpenerIsReleasedBeforeAnyPreview(syntax: DS4ToolSyntax) throws {
        // Each suffix may still start a DSML marker, so the visible stream
        // holds it back until the opener that follows resolves it.
        for suffix in ["|", "｜", "<", "</"] {
            let visible = "| a | b " + suffix
            let text = visible + writeBlock(syntax)
            for chunks in [[text], bytewiseChunks(text)] {
                let run = previewRun(chunks, syntax: syntax)
                let firstPreview = try #require(run.drains.firstIndex { !$0.isEmpty })
                // The deltas of a `consume` go out before the previews drained after it.
                #expect(visibleText(run.deltas.prefix(firstPreview + 1)) == visible, "\(suffix)")
                let laterDeltas = run.deltas.dropFirst(firstPreview + 1).filter { !$0.isEmpty }
                #expect(laterDeltas.isEmpty, "\(suffix)")
                #expect(merged(run.previews) == writePreviews(content: fileContent))
                let output = try #require(run.output)
                #expect(output.finalDeltas.isEmpty, "\(suffix)")
                #expect(output.visibleText == visible)
                #expect(output.rawText == text)
                #expect(output.parseError == nil)
                #expect(output.toolCalls.map(\.name) == ["local.writeFile"])
            }
        }
    }

    // MARK: Equivalence

    @Test
    func drainingNeverChangesConsumeOrFinish() {
        for input in representativeInputs() {
            for chunks in [[input.text], bytewiseChunks(input.text)] {
                let drained = previewRun(chunks, syntax: input.syntax, thinking: input.thinking, draining: true)
                let plain = previewRun(chunks, syntax: input.syntax, thinking: input.thinking, draining: false)
                #expect(drained.deltas == plain.deltas, "\(input.text.debugDescription)")
                #expect(drained.flags == plain.flags, "\(input.text.debugDescription)")
                #expect(drained.summary == plain.summary, "\(input.text.debugDescription)")
            }
        }
    }

    // MARK: Bridge

    @Test
    func bridgeYieldsPreviewsAfterTheDeltasOfTheSameToken() async {
        let (stream, continuation) = AsyncStream<DirectAgentEvent>.makeStream()
        let bridge = DS4GenerationBridge(
            parser: DS4GeneratedOutputParser(syntax: .dsml, startsInsideThinking: false),
            continuation: continuation
        )
        _ = bridge.consume(
            "Writing.<｜DSML｜tool_calls>\n<｜DSML｜invoke name=\"local.writeFile\">\n"
                + "<｜DSML｜parameter name=\"content\" string=\"true\">abc"
        )
        _ = bridge.consume(" def</｜DSML｜parameter>\n</｜DSML｜invoke>\n</｜DSML｜tool_calls>")
        _ = bridge.finish()
        // Nothing is left open: no synthetic `ended`.
        bridge.endOpenToolCallPreview()
        continuation.finish()

        #expect(await collect(stream) == [
            .content("Writing."),
            .preview(.toolStarted(name: "local.writeFile")),
            .preview(.parameterStarted(name: "content")),
            .preview(.parameterText("abc")),
            .preview(.parameterText(" def")),
            .preview(.parameterEnded),
            .preview(.ended),
        ])
    }

    @Test
    func bridgeFinishEndsATruncatedBlockOnce() async {
        let (stream, continuation) = AsyncStream<DirectAgentEvent>.makeStream()
        let bridge = DS4GenerationBridge(
            parser: DS4GeneratedOutputParser(syntax: .qwen, startsInsideThinking: false),
            continuation: continuation
        )
        _ = bridge.consume("<tool_call>\n<function=local.writeFile>\n<parameter=content>\nabc\n")
        let output = bridge.finish()
        bridge.endOpenToolCallPreview()
        continuation.finish()

        #expect(output.parseError?.detail == "incomplete Qwen tool call")
        #expect(await collect(stream) == [
            .preview(.toolStarted(name: "local.writeFile")),
            .preview(.parameterStarted(name: "content")),
            .preview(.parameterText("abc")),
            .preview(.ended),
        ])
    }

    @Test
    func bridgeEndsAnOpenPreviewWhenGenerationFails() async {
        let (stream, continuation) = AsyncStream<DirectAgentEvent>.makeStream()
        let bridge = DS4GenerationBridge(
            parser: DS4GeneratedOutputParser(syntax: .glm, startsInsideThinking: false),
            continuation: continuation
        )
        _ = bridge.consume("Ok <tool_call>local.writeFile<arg_key>content</arg_key><arg_value>abc</arg_")
        // The `catch` around `engine.generate`: once, and only when open.
        bridge.endOpenToolCallPreview()
        bridge.endOpenToolCallPreview()
        continuation.finish()

        #expect(await collect(stream) == [
            .content("Ok "),
            .preview(.toolStarted(name: "local.writeFile")),
            .preview(.parameterStarted(name: "content")),
            .preview(.parameterText("abc")),
            .preview(.ended),
        ])
    }
}

/// The client end to end. Serialized like the other suites that run
/// `DS4ClientHarness` turns (`RemoteGenerationClientDS4EngineTests`,
/// `DS4ExactTokenReplayTests`): a DS4 round goes through process-wide state,
/// the image staging directory `<support>/ds4/tmp` of the test process.
@Suite("DS4 tool-call preview client", .serialized)
struct DS4ToolCallPreviewClientTests {
    // MARK: Client

    @Test
    func clientForwardsPreviewsBeforeTheToolCall() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["Let me check.", DS4ClientHarness.dsml41EchoCall("hi")])
        harness.mock.enqueueGeneration(["Done"])
        let client = try await harness.makeClient()
        let recorder = DS4EventRecorder()

        _ = try await client.sendPrompt(sessionID: "session", prompt: "Echo", attachments: [], onEvent: recorder.handler)

        let events = recorder.events
        #expect(previews(in: events) == [
            .toolStarted(name: DS4ClientHarness.toolName),
            .parameterStarted(name: "text"),
            .parameterText("hi"),
            .parameterEnded,
            .ended,
        ])
        let lastPreview = try #require(events.lastIndex { if case .toolCallPreview = $0 { true } else { false } })
        let toolStarted = try #require(events.firstIndex { if case .toolCallStarted = $0 { true } else { false } })
        #expect(lastPreview < toolStarted)
        await client.shutdown()
    }

    @Test(arguments: [false, true])
    func clientEndsAnOpenPreviewWhenGenerationFailsOrIsCancelled(cancelled: Bool) async throws {
        let harness = try DS4ClientHarness()
        let chunks = [
            "Writing.",
            "\n\n<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"\(DS4ClientHarness.toolName)\">\n"
                + "<｜DSML｜ parameter name=\"text\" string=\"true\">hel",
            "lo <",
        ]
        harness.mock.enqueueGeneration(MockDS4Engine.ScriptedGeneration(
            chunks: chunks,
            outcome: cancelled ? .cancelled : .stop,
            errorAfterChunks: cancelled ? nil : .sessionFailed("generation failed")
        ))
        let client = try await harness.makeClient()
        let recorder = DS4EventRecorder()

        await #expect(throws: (any Error).self) {
            _ = try await client.sendPrompt(sessionID: "session", prompt: "Echo", attachments: [], onEvent: recorder.handler)
        }

        #expect(previews(in: recorder.events) == [
            .toolStarted(name: DS4ClientHarness.toolName),
            .parameterStarted(name: "text"),
            .parameterText("hel"),
            .parameterText("lo "),
            .ended,
        ])
        let events = recorder.events
        let firstContent = try #require(events.firstIndex { if case .content = $0 { true } else { false } })
        let firstPreview = try #require(events.firstIndex { if case .toolCallPreview = $0 { true } else { false } })
        #expect(firstContent < firstPreview)
        #expect(recorder.content.hasPrefix("Writing."))
        await client.shutdown()
    }
}
