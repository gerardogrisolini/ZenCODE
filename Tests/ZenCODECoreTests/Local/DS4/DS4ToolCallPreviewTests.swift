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

// MARK: - Harness

private typealias Preview = DirectAgentToolCallPreview

/// Decodes a byte stream like the engine bridge: an incomplete UTF-8 scalar is
/// held and yields an empty string.
private struct PreviewChunkDecoder {
    private var pending: [UInt8] = []

    mutating func decode(_ bytes: some Sequence<UInt8>) -> String {
        pending.append(contentsOf: bytes)
        let length = DS4Bytes.completeUTF8PrefixLength(pending)
        let text = String(decoding: pending[..<length], as: UTF8.self)
        pending.removeFirst(length)
        return text
    }
}

/// Splits the bytes of `text` at `offsets` and decodes each piece like the
/// engine bridge.
private func splitChunks(_ text: String, at offsets: [Int]) -> [String] {
    let bytes = Array(text.utf8)
    var decoder = PreviewChunkDecoder()
    var result: [String] = []
    var start = 0
    for offset in offsets + [bytes.count] {
        result.append(decoder.decode(bytes[start..<offset]))
        start = offset
    }
    return result
}

private func bytewiseChunks(_ text: String) -> [String] {
    splitChunks(text, at: Array(0..<text.utf8.count))
}

/// Byte range of the last occurrence of `needle` in `text`.
private func lastByteRange(of needle: String, in text: String) -> Range<Int>? {
    let bytes = Array(text.utf8)
    let pattern = Array(needle.utf8)
    var index = bytes.count - pattern.count
    while index >= 0 {
        if Array(bytes[index..<index + pattern.count]) == pattern {
            return index..<index + pattern.count
        }
        index -= 1
    }
    return nil
}

private struct GenerationFlags: Equatable {
    let stop: Bool
    let greedy: Bool
}

private struct OutputSummary: Equatable {
    let visible: String
    let reasoning: String
    let calls: [String]
    let replays: [DS4ToolCallReplay]
    let error: DS4ToolParseError?
    let raw: String
    let finalDeltas: [DS4ParsedOutputDelta]

    init(_ output: DS4ParsedOutput) {
        visible = output.visibleText
        reasoning = output.reasoningText
        // Call ids are random: compare name and arguments.
        calls = output.toolCalls.map { $0.name + " " + $0.argumentsJSON }
        replays = output.toolCallReplays
        error = output.parseError
        raw = output.rawText
        finalDeltas = output.finalDeltas
    }
}

private struct PreviewRun {
    /// Deltas returned by each `consume`.
    var deltas: [[DS4ParsedOutputDelta]] = []
    /// Flags read after each `consume`.
    var flags: [GenerationFlags] = []
    /// Previews drained after each `consume`, then after `finish()` (empty
    /// when the run did not drain).
    var drains: [[Preview]] = []
    var output: DS4ParsedOutput?

    var previews: [Preview] {
        drains.flatMap { $0 }
    }

    var summary: OutputSummary? {
        output.map(OutputSummary.init)
    }
}

private func previewRun(
    _ chunks: [String],
    syntax: DS4ToolSyntax,
    thinking: Bool = false,
    draining: Bool = true
) -> PreviewRun {
    var parser = DS4GeneratedOutputParser(syntax: syntax, startsInsideThinking: thinking)
    var run = PreviewRun()
    for chunk in chunks {
        run.deltas.append(parser.consume(chunk))
        run.flags.append(GenerationFlags(stop: parser.shouldStopGeneration, greedy: parser.wantsGreedySampling))
        if draining {
            run.drains.append(parser.drainToolCallPreviews())
        }
    }
    run.output = parser.finish()
    if draining {
        run.drains.append(parser.drainToolCallPreviews())
        // Everything was drained: a further drain has nothing left.
        #expect(parser.drainToolCallPreviews().isEmpty)
    }
    return run
}

/// `previews` with adjacent `parameterText` fragments joined.
private func merged(_ previews: [Preview]) -> [Preview] {
    var result: [Preview] = []
    for preview in previews {
        if case let .parameterText(text) = preview, case let .parameterText(previous) = result.last {
            result[result.count - 1] = .parameterText(previous + text)
        } else {
            result.append(preview)
        }
    }
    return result
}

private func fragments(_ previews: [Preview]) -> [String] {
    previews.compactMap { preview in
        if case let .parameterText(text) = preview {
            return text
        }
        return nil
    }
}

/// The streamed text of every parameter that ended, in order.
private func closedParameterTexts(_ previews: [Preview]) -> [String] {
    var texts: [String] = []
    var current: String?
    for preview in previews {
        switch preview {
        case .parameterStarted:
            current = ""
        case let .parameterText(text):
            current = (current ?? "") + text
        case .parameterEnded:
            texts.append(current ?? "")
            current = nil
        case .toolStarted, .ended:
            current = nil
        }
    }
    return texts
}

/// The streamed text of the parameter still open at the end of `previews`.
private func openParameterText(_ previews: [Preview]) -> String? {
    var current: String?
    for preview in previews {
        switch preview {
        case .parameterStarted:
            current = ""
        case let .parameterText(text):
            current = (current ?? "") + text
        case .parameterEnded, .toolStarted, .ended:
            current = nil
        }
    }
    return current
}

private func endedCount(_ previews: [Preview]) -> Int {
    previews.filter { $0 == .ended }.count
}

/// The visible text of `deltas`, in order.
private func visibleText(_ deltas: some Sequence<[DS4ParsedOutputDelta]>) -> String {
    deltas.joined().map { delta in
        if case let .visible(text) = delta {
            return text
        }
        return ""
    }.joined()
}

/// Raw argument values of the standalone stream parser, in order.
private func rawValues(_ text: String, syntax: DS4ToolSyntax) -> [String] {
    var parser = DS4ToolCallStreamParser(syntax: syntax)
    for byte in text.utf8 {
        parser.feed(byte: byte)
    }
    parser.finish()
    return parser.calls.flatMap(\.arguments).map(\.rawValue)
}

/// After every drain, the text streamed so far for the open parameter is a
/// prefix of its final raw value: nothing that is not content was emitted.
private func expectStreamedPrefixes(
    _ drains: [[Preview]],
    rawValues: [String],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    var index = -1
    var streamed: [UInt8] = []
    for drain in drains {
        for preview in drain {
            switch preview {
            case .parameterStarted:
                index += 1
                streamed = []
            case let .parameterText(text):
                streamed += Array(text.utf8)
            case .parameterEnded, .toolStarted, .ended:
                break
            }
        }
        guard index >= 0, index < rawValues.count else {
            continue
        }
        #expect(
            Array(rawValues[index].utf8).starts(with: streamed),
            "streamed \(String(decoding: streamed, as: UTF8.self).debugDescription) is not a prefix of \(rawValues[index].debugDescription)",
            sourceLocation: sourceLocation
        )
    }
}

private typealias ArgumentObject = [String: JSONValue]

private func stringArguments(_ call: DirectAgentToolCall?) throws -> [String: String] {
    let call = try #require(call)
    let object = try JSONDecoder().decode(ArgumentObject.self, from: Data(call.argumentsJSON.utf8))
    var strings: [String: String] = [:]
    for (key, value) in object {
        if case let .string(text) = value {
            strings[key] = text
        }
    }
    return strings
}

/// Tool-call markup of one syntax, rendered like the model writes it.
private struct Markup {
    let syntax: DS4ToolSyntax

    var blockOpen: String {
        syntax.usesDSML ? syntax.toolCallOpenMarker + "\n" : ""
    }

    var blockClose: String {
        syntax.usesDSML ? syntax.dsmlCloseTag(.toolCalls) : ""
    }

    func callOpen(_ name: String) -> String {
        switch syntax {
        case .dsml, .dsml41:
            syntax.dsmlOpenTag(.invoke) + " name=\"\(name)\">\n"
        case .glm:
            "<tool_call>" + name
        case .qwen:
            "<tool_call>\n<function=\(name)>\n"
        }
    }

    var callClose: String {
        switch syntax {
        case .dsml, .dsml41:
            syntax.dsmlCloseTag(.invoke) + "\n"
        case .glm:
            "</tool_call>\n"
        case .qwen:
            "</function>\n</tool_call>\n"
        }
    }

    func parameterOpen(_ name: String) -> String {
        switch syntax {
        case .dsml, .dsml41:
            syntax.dsmlOpenTag(.parameter) + " name=\"\(name)\" string=\"true\">"
        case .glm:
            "<arg_key>\(name)</arg_key><arg_value>"
        case .qwen:
            "<parameter=\(name)>\n"
        }
    }

    /// Qwen writes a newline on each side of the value; the parser removes it.
    var parameterClose: String {
        switch syntax {
        case .dsml, .dsml41:
            syntax.parameterCloseMarker + "\n"
        case .glm:
            "</arg_value>"
        case .qwen:
            "\n</parameter>\n"
        }
    }

    func call(_ name: String, _ arguments: [(String, String)]) -> String {
        callOpen(name) + arguments.map { parameterOpen($0.0) + $0.1 + parameterClose }.joined() + callClose
    }

    func block(_ calls: [(String, [(String, String)])]) -> String {
        blockOpen + calls.map { call($0.0, $0.1) }.joined() + blockClose
    }
}

private let prose = "Writing the file.\n\n"
private let filePath = "Sources/App/main.swift"
private let fileContent = "import Foundation\n\nlet ok = 1 < 2 && 3 > 2\nprint(\"<div>x</div>\")\n// ciao 🙂\n"

private func writeBlock(_ syntax: DS4ToolSyntax, content: String = fileContent) -> String {
    Markup(syntax: syntax).block([("local.writeFile", [("path", filePath), ("content", content)])])
}

private func writePreviews(content: String) -> [Preview] {
    [
        .toolStarted(name: "local.writeFile"),
        .parameterStarted(name: "path"),
        .parameterText(filePath),
        .parameterEnded,
        .parameterStarted(name: "content"),
        .parameterText(content),
        .parameterEnded,
        .ended,
    ]
}

/// Inputs whose `consume`/`finish` results must not depend on draining.
private func representativeInputs() -> [(syntax: DS4ToolSyntax, thinking: Bool, text: String)] {
    var inputs: [(DS4ToolSyntax, Bool, String)] = []
    for syntax in DS4ToolSyntax.allCases {
        let markup = Markup(syntax: syntax)
        inputs.append((syntax, false, prose + writeBlock(syntax)))
        inputs.append((syntax, true, "plan</think>" + prose + writeBlock(syntax)))
        inputs.append((syntax, false, markup.block([
            ("local.readFile", [("path", "a.swift")]),
            ("local.writeFile", [("path", "b.swift"), ("content", "x\n")]),
        ])))
        inputs.append((syntax, false, prose + markup.blockOpen + markup.callOpen("local.writeFile")
            + markup.parameterOpen("content") + "partial line\nnext <"))
        inputs.append((syntax, true, "plan " + markup.block([("local.readFile", [("path", "a")])])))
        inputs.append((syntax, false, "a < b | c <thi <｜x <DSM done 🙂"))
    }
    inputs.append((.dsml, false, "<｜DSML｜tool_calls>\n<｜DSML｜invoke name=\"local.readFile\">\n<｜DSML｜bogus name=\"x\">"))
    inputs.append((.dsml, false, "see <DSML｜ and ｜DSML｜ later"))
    inputs.append((.glm, false, "<tool_call>local.readFile<arg_key>path</arg_key>oops</tool_call>"))
    inputs.append((.qwen, false, "<tool_call>\n<function=local.readFile>\n<parameter=path>\na\n</parameter>\n</function>\nnope"))
    return inputs.map { (syntax: $0.0, thinking: $0.1, text: $0.2) }
}

// MARK: - Bridge harness

private enum BridgeEvent: Equatable {
    case content(String)
    case thought(String)
    case preview(Preview)
    case other
}

private func bridgeEvent(_ event: DirectAgentEvent) -> BridgeEvent {
    switch event {
    case let .content(text):
        .content(text)
    case let .thought(text):
        .thought(text)
    case let .toolCallPreview(preview):
        .preview(preview)
    default:
        .other
    }
}

private func collect(_ stream: AsyncStream<DirectAgentEvent>) async -> [BridgeEvent] {
    var events: [BridgeEvent] = []
    for await event in stream {
        events.append(bridgeEvent(event))
    }
    return events
}

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
