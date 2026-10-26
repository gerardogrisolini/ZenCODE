//
//  DS4ToolSyntaxTests.swift
//  ZenCODE
//
//  Fixtures ported from ds4_agent.c's internal tests (7599-7990) plus
//  round-trip, prompt and every-byte-split coverage.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

// MARK: - Harness

private typealias JSONObject = [String: JSONValue]

/// Decodes a byte stream like the engine bridge: an incomplete UTF-8 scalar is
/// held and yields an empty string.
private struct UTF8ChunkDecoder {
    private var pending: [UInt8] = []

    mutating func decode(_ bytes: some Sequence<UInt8>) -> String {
        pending.append(contentsOf: bytes)
        let length = DS4Bytes.completeUTF8PrefixLength(pending)
        let text = String(decoding: pending[..<length], as: UTF8.self)
        pending.removeFirst(length)
        return text
    }
}

private struct Summary: Equatable, CustomStringConvertible {
    let visible: String
    let thought: String
    let calls: [String]
    let error: String?

    var description: String {
        "visible=\(visible.debugDescription) thought=\(thought.debugDescription) calls=\(calls) error=\(error ?? "nil")"
    }
}

private struct ParseRun {
    let output: DS4ParsedOutput
    let deltas: [DS4ParsedOutputDelta]
    /// Accumulated visible text after each consumed chunk.
    let visibleSnapshots: [String]

    var summary: Summary {
        Summary(
            visible: output.visibleText,
            thought: output.reasoningText,
            calls: output.toolCalls.map { $0.name + " " + $0.argumentsJSON },
            error: output.parseError?.detail
        )
    }

    var visibleFromDeltas: String {
        deltas.compactMap { delta -> String? in
            if case let .visible(text) = delta {
                return text
            }
            return nil
        }.joined()
    }

    var thoughtFromDeltas: String {
        deltas.compactMap { delta -> String? in
            if case let .thought(text) = delta {
                return text
            }
            return nil
        }.joined()
    }
}

private func run(
    _ chunks: [String],
    syntax: DS4ToolSyntax,
    thinking: Bool = false,
    types: [String: [String: DS4ToolParameterKind]] = [:]
) -> ParseRun {
    var parser = DS4GeneratedOutputParser(syntax: syntax, startsInsideThinking: thinking, parameterTypes: types)
    var deltas: [DS4ParsedOutputDelta] = []
    var snapshots: [String] = []
    var visible = ""
    for chunk in chunks {
        let produced = parser.consume(chunk)
        for case let .visible(text) in produced {
            visible += text
        }
        deltas += produced
        snapshots.append(visible)
    }
    let output = parser.finish()
    return ParseRun(output: output, deltas: deltas + output.finalDeltas, visibleSnapshots: snapshots)
}

/// Splits `bytes` at the given byte offsets and decodes each piece like the
/// engine bridge (incomplete scalars yield empty chunks).
private func chunks(_ text: String, splittingAt offsets: [Int]) -> [String] {
    let bytes = Array(text.utf8)
    var decoder = UTF8ChunkDecoder()
    var result: [String] = []
    var start = 0
    for offset in offsets + [bytes.count] {
        result.append(decoder.decode(bytes[start..<offset]))
        start = offset
    }
    return result
}

private func bytewiseChunks(_ text: String) -> [String] {
    chunks(text, splittingAt: Array(0..<text.utf8.count))
}

private func arguments(_ call: DirectAgentToolCall) throws -> [String: JSONValue] {
    try JSONDecoder().decode(JSONObject.self, from: Data(call.argumentsJSON.utf8))
}

private let markupFragments = [
    "<tool_call", "</tool_call", "<arg_key", "</arg_", "<arg_value", "<function=", "</function",
    "<parameter", "</parameter", "｜DSML", "DSML｜", "|DSML|",
]

private func expectNoMarkup(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
    for fragment in markupFragments {
        #expect(!text.contains(fragment), "visible text leaked \(fragment): \(text.debugDescription)", sourceLocation: sourceLocation)
    }
}

private func descriptor(_ name: String, _ schema: String, description: String? = nil) -> DirectToolDescriptor {
    DirectToolDescriptor(name: name, description: description ?? "The \(name) tool.", inputSchema: schema)
}

private let bashDescriptor = descriptor(
    "bash",
    #"{"type":"object","properties":{"command":{"type":"string"},"refresh_sec":{"type":"integer"}},"required":["command"]}"#,
    description: "Run a shell command."
)
private let writeDescriptor = descriptor(
    "write",
    #"{"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}, "overwrite": {"type": "boolean"}}, "required": ["path", "content"]}"#
)
private let searchDescriptor = descriptor(
    "search",
    #"{"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"integer"},"ratio":{"type":"number"},"paths":{"type":"array","items":{"type":"string"}},"options":{"type":"object"},"none":{},"maybe":{"type":["string","null"]}}}"#
)

// MARK: - Fixtures for every-byte splits

struct DS4ToolOutputFixture: Sendable, CustomTestStringConvertible {
    let name: String
    let syntax: DS4ToolSyntax
    let thinking: Bool
    let text: String

    var testDescription: String { name }
}

private let splitFixtures: [DS4ToolOutputFixture] = [
    DS4ToolOutputFixture(
        name: "dsml-two-invokes-after-thinking",
        syntax: .dsml,
        thinking: true,
        text: "plan ｜ step</think>\n\nReading.\n\n<｜DSML｜tool_calls>\n<｜DSML｜invoke name=\"read\">\n"
            + "<｜DSML｜parameter name=\"path\" string=\"true\">ds4_agent.c</｜DSML｜parameter>\n"
            + "<｜DSML｜parameter name=\"max_lines\" string=\"false\">80</｜DSML｜parameter>\n</｜DSML｜invoke>\n"
            + "<｜DSML｜invoke name=\"write\">\n<｜DSML｜parameter name=\"content\" string=\"true\">"
            + "<p>&amp; &lt;</p> </tool_call> </think> &lt;/｜DSML｜parameter></｜DSML｜parameter>\n"
            + "</｜DSML｜invoke>\n</｜DSML｜tool_calls>"
    ),
    DS4ToolOutputFixture(
        name: "dsml41-spaced-tags",
        syntax: .dsml41,
        thinking: false,
        text: "Ok <b>|x|</b>\n\n<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"bash\">\n"
            + "<｜DSML｜ parameter name=\"command\" string=\"true\">printf '｜DSML｜'</｜DSML｜ parameter>\n"
            + "<｜DSML｜ parameter name=\"refresh_sec\" string=\"false\">1</｜DSML｜ parameter>\n"
            + "</｜DSML｜ invoke>\n</｜DSML｜ calls>"
    ),
    DS4ToolOutputFixture(
        name: "glm-two-calls-with-markup-in-value",
        syntax: .glm,
        thinking: true,
        text: "think <tool</think>intro <to x <tool_call>write<arg_key>content</arg_key><arg_value><p>&amp; &lt;</p>"
            + " </tool_call> </think> &lt;/arg_value></arg_value></tool_call>\n"
            + "<tool_call>bash<arg_key>command</arg_key><arg_value>pwd</arg_value>"
            + "<arg_key>refresh_sec</arg_key><arg_value>1</arg_value></tool_call>"
    ),
    DS4ToolOutputFixture(
        name: "qwen-two-calls",
        syntax: .qwen,
        thinking: true,
        text: "reason\n</think>\n\nintro <toolbox>\n<tool_call>\n<function=bash>\n<parameter=command>\nprintf hi\n</parameter>\n"
            + "<parameter=refresh_sec>\n1\n</parameter>\n</function>\n</tool_call>\n<tool_call>\n<function=write>\n"
            + "<parameter=content>\nliteral </tool_call> </think> <think> &lt;/parameter>\n</parameter>\n</function>\n</tool_call>"
    ),
    DS4ToolOutputFixture(
        name: "glm-missing-arg-value",
        syntax: .glm,
        thinking: false,
        text: "x <tool_call>list<arg_key>path</arg_key></tool_call>"
    ),
    DS4ToolOutputFixture(
        name: "dsml-marker-in-prose",
        syntax: .dsml,
        thinking: false,
        text: "see <DSML｜ and ｜DSML｜ later"
    ),
    DS4ToolOutputFixture(
        name: "dsml-tool-inside-thinking",
        syntax: .dsml,
        thinking: true,
        text: "plan <｜DSML｜tool_calls><｜DSML｜invoke name=\"read\"></think>"
    ),
    DS4ToolOutputFixture(
        name: "plain-text-only",
        syntax: .dsml,
        thinking: false,
        text: "a < b | c <thi <｜x <DSM done 🙂"
    ),
]

// MARK: - Tests

@Suite
struct DS4ToolSyntaxTests {
    // MARK: Syntax

    @Test
    func syntaxMatchesEngineABIAndDS4AgentMarkers() {
        #expect(DS4ToolSyntax.allCases.map(\.rawValue) == [0, 1, 2, 3])
        #expect(DS4ToolSyntax(rawValue: 2) == .glm)
        #expect(DS4ToolSyntax.dsml.toolCallOpenMarker == "<｜DSML｜tool_calls>")
        #expect(DS4ToolSyntax.dsml41.toolCallOpenMarker == "<｜DSML｜ calls>")
        #expect(DS4ToolSyntax.glm.toolCallOpenMarker == "<tool_call>")
        #expect(DS4ToolSyntax.qwen.toolCallOpenMarker == "<tool_call>")
        #expect(DS4ToolSyntax.allCases.filter { !$0.assistantTurnUsesEOS } == [.glm])
        #expect(DS4ToolSyntax.allCases.filter(\.usesXMLToolCall) == [.glm, .qwen])
        #expect(DS4ToolSyntax.dsml.parameterCloseMarker == "</｜DSML｜parameter>")
        #expect(DS4ToolSyntax.dsml41.parameterCloseMarker == "</｜DSML｜ parameter>")
        #expect(DS4ToolSyntax.dsml41.dsmlOpenTag(.invoke) == "<｜DSML｜ invoke")
        #expect(DS4ToolSyntax.dsml41.dsmlCloseTag(.toolCalls) == "</｜DSML｜ calls>")
        #expect(DS4ToolSyntax.qwen.syntaxReminder.contains("<function=$TOOL_NAME>"))
        for syntax in DS4ToolSyntax.allCases {
            #expect(syntax.outputStartsInsideThinking(thinkModeEnabled: true))
            #expect(!syntax.outputStartsInsideThinking(thinkModeEnabled: false))
        }
    }

    @Test
    func parameterKindsComeFromDescriptorSchemas() {
        let kinds = DS4ToolParameterKind.map(from: [
            searchDescriptor,
            descriptor("odd", #"{"type":"object","properties":{"a":{"enum":["x","y"]},"b":{"anyOf":[{"type":"string"},{"type":"integer"}]},"c":{"type":["integer","null"]},"d":{}}}"#),
            descriptor("broken", "not json"),
            descriptor("search", #"{"type":"object","properties":{"query":{"type":"integer"}}}"#),
        ])
        #expect(kinds["search"]?["query"] == .string)
        #expect(kinds["search"]?["max_results"] == .integer)
        #expect(kinds["search"]?["ratio"] == .number)
        #expect(kinds["search"]?["paths"] == .array)
        #expect(kinds["search"]?["options"] == .object)
        #expect(kinds["search"]?["none"] == .any)
        #expect(kinds["search"]?["maybe"] == .string)
        #expect(kinds["odd"] == ["a": .string, "b": .any, "c": .integer, "d": .any])
        #expect(kinds["broken"] == nil)
    }

    @Test
    func toolTextEscapingMatchesDS4ToolTextHeader() {
        let close = "</｜DSML｜parameter>"
        #expect(DS4ToolTextEscaping.unescape("&lt;/｜DSML｜parameter> &amp;lt;/｜DSML｜parameter> &amp; &lt;", closingTag: close)
            == "</｜DSML｜parameter> &lt;/｜DSML｜parameter> &amp; &lt;")
        let value = "</｜DSML｜parameter> &lt;/｜DSML｜parameter> &amp;&amp;lt;/｜DSML｜parameter> & <"
        let escaped = DS4ToolTextEscaping.escape(value, closingTag: close)
        #expect(escaped == "&lt;/｜DSML｜parameter> &amp;lt;/｜DSML｜parameter> &amp;&amp;amp;lt;/｜DSML｜parameter> & <")
        #expect(DS4ToolTextEscaping.unescape(escaped, closingTag: close) == value)
    }

    // MARK: Qwen fixtures (ds4_agent.c 7599-7690)

    @Test
    func qwenToolParserChunkedMultiArg() throws {
        let a = "<tool_call>\n<function=bash>\n<parameter=command>\nprintf hi\n"
        let b = "</param"
        let c = "eter>\n<parameter=refresh_sec>\n1\n</parameter>\n</function>\n</tool_call>"
        var parser = DS4ToolCallStreamParser(syntax: .qwen)
        parser.feed(Array(a.utf8))
        #expect(parser.state == .parameterValue)
        parser.feed(Array(b.utf8))
        #expect(parser.state == .parameterValue)
        #expect(parser.parameterClosePrefix)
        parser.feed(Array(c.utf8))
        parser.finish()
        #expect(parser.state == .done)
        #expect(parser.calls.count == 1)
        #expect(parser.calls.first?.name == "bash")
        #expect(parser.calls.first?.arguments.map(\.rawValue) == ["printf hi", "1"])

        let output = run([a, b, c], syntax: .qwen).output
        let call = try #require(output.toolCalls.first)
        #expect(try arguments(call) == ["command": .string("printf hi"), "refresh_sec": .number(1)])
    }

    @Test
    func qwenToolParserTwoCallsAndError() throws {
        let text = "<tool_call>\n<function=list>\n<parameter=path>\n.\n</parameter>\n</function>\n</tool_call>\n"
            + "<tool_call>\n<function=read>\n<parameter=path>\n/tmp/x\n</parameter>\n</function>\n</tool_call>"
        let output = run([text], syntax: .qwen).output
        #expect(output.parseError == nil)
        #expect(output.toolCalls.map(\.name) == ["list", "read"])
        #expect(try arguments(output.toolCalls[1]) == ["path": .string("/tmp/x")])

        let bad = "<tool_call>\n<function=list>\n<parameter=path>\n.\n</parameter>\n</tool_call>"
        let failed = run([bad], syntax: .qwen).output
        #expect(failed.toolCalls.isEmpty)
        #expect(failed.parseError == DS4ToolParseError(detail: "expected <parameter=...> or </function> in Qwen tool call"))
    }

    @Test
    func qwenStreamToolCallChunked() throws {
        let result = run([
            "intro ",
            "<to",
            "ol_call>\n<function=bash>\n<parameter=command>\nprintf hi\n</param",
            "eter>\n<parameter=refresh_sec>\n1\n</parameter>\n</function>\n</tool_call>",
        ], syntax: .qwen)
        #expect(result.output.visibleText == "intro ")
        #expect(result.visibleFromDeltas == "intro ")
        let call = try #require(result.output.toolCalls.first)
        #expect(try arguments(call)["command"] == .string("printf hi"))
        expectNoMarkup(result.output.visibleText)
    }

    @Test
    func qwenArgumentMarkersBytewise() throws {
        let raw = "<tool_call><function=write><parameter=content>\n"
            + "literal </tool_call> </think> <think>\n"
            + "</parameter></function></tool_call>"
        var parser = DS4ToolCallStreamParser(syntax: .qwen)
        for byte in raw.utf8 {
            parser.feed(byte: byte)
            #expect(parser.state != .error)
        }
        parser.finish()
        #expect(parser.state == .done)
        #expect(parser.calls.first?.arguments.first?.rawValue == "literal </tool_call> </think> <think>")

        let output = run(bytewiseChunks(raw), syntax: .qwen).output
        let call = try #require(output.toolCalls.first)
        #expect(try arguments(call) == ["content": .string("literal </tool_call> </think> <think>")])
    }

    // MARK: GLM fixtures (ds4_agent.c 7690-7830)

    @Test
    func glmToolParserSingleArg() throws {
        let text = "prose before <tool_call>list<arg_key>path</arg_key><arg_value>.</arg_value></tool_call>"
        var parser = DS4ToolCallStreamParser(syntax: .glm)
        parser.feed(Array(text.utf8))
        parser.finish()
        #expect(parser.state == .done)
        #expect(parser.calls == [.init(name: "list", arguments: [.init(name: "path", rawValue: ".", markedString: false)])])

        let output = run([text], syntax: .glm).output
        #expect(output.visibleText == "prose before ")
        #expect(try arguments(try #require(output.toolCalls.first)) == ["path": .string(".")])
    }

    @Test
    func glmToolParserChunkedMultiArg() throws {
        let a = "<tool_call>bash<arg_key>command</arg_key>"
        let b = "<arg_value>printf hi</arg_value>"
        let c = "<arg_key>refresh_sec</arg_key><arg_value>1</arg_value></tool_call>"
        var parser = DS4ToolCallStreamParser(syntax: .glm)
        parser.feed(Array(a.utf8))
        #expect(parser.state == .structural)
        parser.feed(Array(b.utf8))
        #expect(parser.state == .structural)
        parser.feed(Array(c.utf8))
        parser.finish()
        #expect(parser.state == .done)
        #expect(parser.calls.first?.arguments.map(\.name) == ["command", "refresh_sec"])

        let output = run([a, b, c], syntax: .glm).output
        #expect(try arguments(try #require(output.toolCalls.first)) == [
            "command": .string("printf hi"),
            "refresh_sec": .number(1),
        ])
    }

    @Test
    func glmToolParserStreamsParamState() {
        var parser = DS4ToolCallStreamParser(syntax: .glm)
        parser.feed(Array("<tool_call>bash<arg_key>command</arg_key><arg_value>printf hi".utf8))
        #expect(parser.state == .parameterValue)
        #expect(parser.currentToolName == "bash")
        #expect(parser.currentParameterName == "command")
        #expect(!parser.parameterClosePrefix)
        parser.feed(Array("</arg".utf8))
        #expect(parser.state == .parameterValue)
        #expect(parser.parameterClosePrefix)
        parser.feed(Array("_value><arg_key>refresh_sec</arg_key><arg_value>1</arg_value></tool_call>".utf8))
        parser.finish()
        #expect(parser.state == .done)
        #expect(parser.calls.first?.arguments.map(\.rawValue) == ["printf hi", "1"])
    }

    @Test
    func glmToolParserMultipleAdjacentCalls() throws {
        let text = "<tool_call>list<arg_key>path</arg_key><arg_value>.</arg_value></tool_call>\n"
            + "<tool_call>bash<arg_key>command</arg_key><arg_value>pwd</arg_value></tool_call>"
        let output = run([text], syntax: .glm).output
        #expect(output.toolCalls.map(\.name) == ["list", "bash"])
        #expect(try arguments(output.toolCalls[0]) == ["path": .string(".")])
        #expect(try arguments(output.toolCalls[1]) == ["command": .string("pwd")])
    }

    @Test
    func glmStreamToolCallChunked() throws {
        let result = run([
            "intro ",
            "<to",
            "ol_call>bash<arg_key>command</arg_key><arg_value>printf hi</arg",
            "_value><arg_key>refresh_sec</arg_key><arg_value>1</arg_value></tool_call>",
        ], syntax: .glm)
        #expect(result.output.visibleText == "intro ")
        #expect(result.output.toolCalls.map(\.name) == ["bash"])
        #expect(try arguments(result.output.toolCalls[0])["command"] == .string("printf hi"))
        expectNoMarkup(result.output.visibleText)
    }

    @Test
    func toolArgumentLiteralMarkupForEverySyntax() throws {
        let cases: [(DS4ToolSyntax, [String], String)] = [
            (.dsml, [
                "<｜DSML｜tool_calls><｜DSML｜invoke name=\"write\"><｜DSML｜parameter name=\"content\" string=\"true\"><p>&amp; &lt;</p> </tool_call> </think> ",
                "&lt;/｜DSML｜parameter> &amp;lt;/｜DSML｜parameter></｜DSML｜parameter></｜DSML｜invoke></｜DSML｜tool_calls>",
            ], "<p>&amp; &lt;</p> </tool_call> </think> </｜DSML｜parameter> &lt;/｜DSML｜parameter>"),
            (.dsml41, [
                "<｜DSML｜ calls><｜DSML｜ invoke name=\"write\"><｜DSML｜ parameter name=\"content\" string=\"true\"><p>&amp; &lt;</p> </tool_call> </think> ",
                "&lt;/｜DSML｜ parameter> &amp;lt;/｜DSML｜ parameter></｜DSML｜ parameter></｜DSML｜ invoke></｜DSML｜ calls>",
            ], "<p>&amp; &lt;</p> </tool_call> </think> </｜DSML｜ parameter> &lt;/｜DSML｜ parameter>"),
            (.glm, [
                "<tool_call>write<arg_key>content</arg_key><arg_value><p>&amp; &lt;</p> </tool_call> </think> ",
                "&lt;/arg_value> &amp;lt;/arg_value></arg_value></tool_call>",
            ], "<p>&amp; &lt;</p> </tool_call> </think> </arg_value> &lt;/arg_value>"),
            (.qwen, [
                "<tool_call>\n<function=write>\n<parameter=content>\n<p>&amp; &lt;</p> ",
                "&lt;/parameter> &amp;lt;/parameter>\n</parameter>\n</function>\n</tool_call>",
            ], "<p>&amp; &lt;</p> </parameter> &lt;/parameter>"),
        ]
        for (syntax, chunks, expected) in cases {
            let output = run(chunks, syntax: syntax).output
            #expect(output.parseError == nil, "\(syntax)")
            let call = try #require(output.toolCalls.first)
            #expect(try arguments(call) == ["content": .string(expected)], "\(syntax)")
        }
    }

    @Test
    func glmStreamIgnoresToolInsideThink() {
        let result = run([
            "<think>plan <tool",
            "_call>bash<arg_key>command</arg_key><arg_value>printf hi</arg_value></tool_call>",
            "</think>done",
        ], syntax: .glm)
        #expect(result.output.toolCalls.isEmpty)
        #expect(result.output.parseError == DS4ToolParseError(detail: "tool calling is not allowed inside <think></think>"))
        #expect(result.output.reasoningText == "plan ")
        #expect(result.output.visibleText.isEmpty)
        expectNoMarkup(result.output.reasoningText)
    }

    @Test
    func glmStreamGreedySamplingBoundaries() {
        var parser = DS4GeneratedOutputParser(syntax: .glm, startsInsideThinking: false)
        _ = parser.consume("<tool")
        #expect(parser.wantsGreedySampling)
        _ = parser.consume("_call>bash<arg_key>command</arg_key><arg_value>printf hi")
        #expect(parser.isInsideToolCall)
        #expect(!parser.wantsGreedySampling)
        _ = parser.consume("</arg")
        #expect(parser.wantsGreedySampling)
        let deltas = parser.consume("_value></tool_call>")
        #expect(deltas.isEmpty)
        #expect(!parser.shouldStopGeneration)
        let output = parser.finish()
        #expect(output.toolCalls.count == 1)
        #expect(output.visibleText.isEmpty)
        #expect(!parser.wantsGreedySampling)
    }

    @Test
    func greedySamplingTracksDSMLStructure() {
        var parser = DS4GeneratedOutputParser(syntax: .dsml, startsInsideThinking: false)
        _ = parser.consume("Hi <")
        #expect(!parser.wantsGreedySampling)
        _ = parser.consume("｜")
        #expect(parser.wantsGreedySampling)
        _ = parser.consume("DSML｜tool_calls>\n")
        #expect(parser.wantsGreedySampling)
        _ = parser.consume("<｜DSML｜invoke name=\"read\">\n<｜DSML｜parameter name=\"path\" string=\"true\">a.txt")
        #expect(!parser.wantsGreedySampling)
        _ = parser.consume("</｜DSML｜para")
        #expect(parser.wantsGreedySampling)
        _ = parser.consume("meter>\n</｜DSML｜invoke>\n</｜DSML｜tool_calls>")
        #expect(parser.shouldStopGeneration)
        #expect(!parser.wantsGreedySampling)
    }

    @Test
    func dsmlStreamToolCallChunked() throws {
        let result = run([
            "<｜D",
            "SML｜tool_calls><｜DSML｜invoke name=\"read\">"
                + "<｜DSML｜parameter name=\"path\" string=\"true\">ds4_agent.c</｜DSML｜parameter>"
                + "</｜DSML｜invoke></｜DSML｜tool_calls>",
        ], syntax: .dsml)
        #expect(result.output.visibleText.isEmpty)
        let call = try #require(result.output.toolCalls.first)
        #expect(call.name == "read")
        #expect(try arguments(call) == ["path": .string("ds4_agent.c")])
    }

    @Test
    func glmToolParserRejectsMissingValue() {
        var parser = DS4ToolCallStreamParser(syntax: .glm)
        parser.feed(Array("<tool_call>list<arg_key>path</arg_key></tool_call>".utf8))
        #expect(parser.state == .error)
        #expect(parser.errorDetail == "expected <arg_value> in GLM tool call")

        var output = DS4GeneratedOutputParser(syntax: .glm, startsInsideThinking: false)
        _ = output.consume("<tool_call>list<arg_key>path</arg_key></")
        #expect(output.shouldStopGeneration)
        let result = output.finish()
        #expect(result.toolCalls.isEmpty)
        #expect(result.parseError == DS4ToolParseError(detail: "expected <arg_value> in GLM tool call"))
    }

    // MARK: Stream behaviour

    @Test
    func thinkingFollowedByToolCallForEverySyntax() throws {
        let blocks: [DS4ToolSyntax: String] = [
            .dsml: "<｜DSML｜tool_calls>\n<｜DSML｜invoke name=\"read\">\n<｜DSML｜parameter name=\"path\" string=\"true\">a.txt</｜DSML｜parameter>\n</｜DSML｜invoke>\n</｜DSML｜tool_calls>",
            .dsml41: "<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"read\">\n<｜DSML｜ parameter name=\"path\" string=\"true\">a.txt</｜DSML｜ parameter>\n</｜DSML｜ invoke>\n</｜DSML｜ calls>",
            .glm: "<tool_call>read<arg_key>path</arg_key><arg_value>a.txt</arg_value></tool_call>",
            .qwen: "<tool_call>\n<function=read>\n<parameter=path>\na.txt\n</parameter>\n</function>\n</tool_call>",
        ]
        for syntax in DS4ToolSyntax.allCases {
            let block = try #require(blocks[syntax])
            let result = run(["I should read ", "a.txt.\n</th", "ink>\n\n", block], syntax: syntax, thinking: true)
            #expect(result.output.reasoningText == "I should read a.txt.\n", "\(syntax)")
            #expect(result.output.visibleText.isEmpty, "\(syntax)")
            #expect(result.output.parseError == nil, "\(syntax)")
            #expect(result.output.toolCalls.map(\.name) == ["read"], "\(syntax)")
            #expect(try arguments(result.output.toolCalls[0]) == ["path": .string("a.txt")], "\(syntax)")
        }
    }

    @Test
    func dsmlMultipleInvokesInOneBlock() throws {
        let text = "<｜DSML｜tool_calls>\n<｜DSML｜invoke name=\"list\">\n"
            + "<｜DSML｜parameter name=\"path\" string=\"true\">.</｜DSML｜parameter>\n</｜DSML｜invoke>\n"
            + "<｜DSML｜invoke name=\"bash\">\n<｜DSML｜parameter name=\"command\" string=\"true\">pwd</｜DSML｜parameter>\n"
            + "<｜DSML｜parameter name=\"refresh_sec\" string=\"false\">2</｜DSML｜parameter>\n</｜DSML｜invoke>\n</｜DSML｜tool_calls>"
        let output = run([text], syntax: .dsml).output
        #expect(output.toolCalls.map(\.name) == ["list", "bash"])
        #expect(try arguments(output.toolCalls[1]) == ["command": .string("pwd"), "refresh_sec": .number(2)])
        #expect(output.toolCallReplays[1].argumentsJSON == #"{"command":"pwd","refresh_sec":2}"#)
        let ids = output.toolCalls.map(\.id)
        #expect(Set(ids).count == 2)
        #expect(ids.allSatisfy { $0.hasPrefix("call_") && $0.count == 21 })
    }

    @Test
    func dsmlToleratedOpeners() throws {
        let missingBar = run([
            "<DSML｜tool_calls><｜DSML｜invoke name=\"list\"></｜DSML｜invoke></｜DSML｜tool_calls>",
        ], syntax: .dsml).output
        #expect(missingBar.toolCalls.map(\.name) == ["list"])

        let implicitInvoke = run([
            "Listing.\n<｜DSML｜invoke name=\"list\">",
            "<｜DSML｜parameter name=\"path\" string=\"true\">src</｜DSML｜parameter></｜DSML｜invoke>",
            "</｜DSML｜tool_calls>",
        ], syntax: .dsml)
        #expect(implicitInvoke.output.visibleText == "Listing.\n")
        #expect(try arguments(try #require(implicitInvoke.output.toolCalls.first)) == ["path": .string("src")])

        let lenientClose = run([
            "<｜DSML｜tool_calls><｜DSML｜invoke name=\"list\"><｜DSML｜parameter name=\"path\" string=\"true\">x</｜DSML｜parameter ｜>",
            "</｜DSML｜invoke ></｜DSML｜tool_calls｜>",
        ], syntax: .dsml).output
        #expect(try arguments(try #require(lenientClose.toolCalls.first)) == ["path": .string("x")])
    }

    @Test
    func incompleteBlocksAreReportedPerSyntax() {
        let cases: [(DS4ToolSyntax, String, String)] = [
            (.dsml, "<｜DSML｜tool_calls>\n<｜DSML｜invoke name=\"read\">", "incomplete DSML tool call"),
            (.dsml41, "<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"read\">\n<｜DSML｜ parameter name=\"p\" string=\"true\">x", "incomplete DSML tool call"),
            (.glm, "<tool_call>read<arg_key>path</arg_key><arg_value>a", "incomplete GLM tool call"),
            (.qwen, "<tool_call>\n<function=read>\n", "incomplete Qwen tool call"),
            (.glm, "<tool_call>read<arg_key>path</arg_key><arg_value>a</arg_value></tool_call><tool_c", "incomplete GLM tool call"),
        ]
        for (syntax, text, detail) in cases {
            let result = run([text], syntax: syntax)
            #expect(result.output.toolCalls.isEmpty, "\(syntax)")
            #expect(result.output.parseError == DS4ToolParseError(detail: detail), "\(syntax)")
            #expect(result.output.visibleText.isEmpty, "\(syntax)")
        }
    }

    @Test
    func malformedDSMLStructureIsAnError() {
        let unexpected = run(["<｜DSML｜tool_calls><｜DSML｜bogus x=\"1\">"], syntax: .dsml).output
        #expect(unexpected.parseError == DS4ToolParseError(detail: "unexpected DSML tag: <｜DSML｜bogus x=\"1\">"))
        let noName = run(["<｜DSML｜tool_calls><｜DSML｜invoke>"], syntax: .dsml).output
        #expect(noName.parseError == DS4ToolParseError(detail: "tool invoke without name"))
        let qwenNoFunction = run(["<tool_call>\n<parameter=x>"], syntax: .qwen).output
        #expect(qwenNoFunction.parseError == DS4ToolParseError(detail: "expected <function=...> in Qwen tool call"))
        let glmNoName = run(["<tool_call> <arg_key>a</arg_key>"], syntax: .glm).output
        #expect(glmNoName.parseError == DS4ToolParseError(detail: "GLM tool call without function name"))
    }

    @Test
    func strayDSMLMarkupInProseStopsWithoutLeaking() {
        let result = run(["Here is ｜DS", "ML｜ text"], syntax: .dsml)
        #expect(result.output.parseError == DS4ToolParseError(detail: "DSML markup outside a valid tool_calls block"))
        #expect(result.output.visibleText == "Here is ")
        #expect(result.visibleSnapshots == ["Here is ", "Here is "])

        let missingOpen = run(["a <DSML｜parameter>"], syntax: .dsml).output
        #expect(missingOpen.visibleText == "a ")
        #expect(missingOpen.parseError?.detail == "DSML markup outside a valid tool_calls block")

        let ascii = run(["x |DSML| y"], syntax: .dsml41).output
        #expect(ascii.visibleText == "x ")
        #expect(ascii.parseError != nil)

        // GLM/Qwen do not police DSML markers.
        let glm = run(["x ｜DSML｜ y"], syntax: .glm).output
        #expect(glm.visibleText == "x ｜DSML｜ y")
        #expect(glm.parseError == nil)
    }

    @Test
    func dsmlMarkerInsideThinkingIsAnError() {
        let result = run(["plan: emit ｜DSM", "L｜ now"], syntax: .dsml, thinking: true)
        #expect(result.output.parseError == DS4ToolParseError(detail: "tool calling is not allowed inside <think></think>"))
        #expect(result.output.reasoningText == "plan: emit ")
        #expect(result.output.toolCalls.isEmpty)
    }

    @Test
    func generationStopsWhenTheBlockCompletes() throws {
        var dsml = DS4GeneratedOutputParser(syntax: .dsml, startsInsideThinking: false)
        _ = dsml.consume("<｜DSML｜tool_calls><｜DSML｜invoke name=\"list\"></｜DSML｜invoke>")
        #expect(!dsml.shouldStopGeneration)
        _ = dsml.consume("</｜DSML｜tool_calls>")
        #expect(dsml.shouldStopGeneration)
        #expect(dsml.consume("After.").isEmpty)
        let dsmlOutput = dsml.finish()
        #expect(dsmlOutput.visibleText.isEmpty)
        #expect(dsmlOutput.rawText.hasSuffix("After."))
        #expect(dsmlOutput.toolCalls.count == 1)

        var glm = DS4GeneratedOutputParser(syntax: .glm, startsInsideThinking: false)
        _ = glm.consume("<tool_call>list<arg_key>path</arg_key><arg_value>.</arg_value></tool_call>")
        #expect(!glm.shouldStopGeneration)
        _ = glm.consume("\n")
        #expect(!glm.shouldStopGeneration)
        #expect(glm.consume("Done").isEmpty)
        #expect(glm.shouldStopGeneration)
        let glmOutput = glm.finish()
        #expect(glmOutput.visibleText.isEmpty)
        #expect(glmOutput.toolCalls.map(\.name) == ["list"])
        #expect(glm.finish().toolCalls.map(\.id) == glmOutput.toolCalls.map(\.id))
    }

    @Test
    func emptyChunksAndPlainTextStreamImmediately() {
        var parser = DS4GeneratedOutputParser(syntax: .dsml, startsInsideThinking: false)
        #expect(parser.consume("").isEmpty)
        #expect(parser.consume("Hello") == [.visible("Hello")])
        #expect(parser.consume(" <") == [.visible(" ")])
        #expect(parser.consume("b>") == [.visible("<b>")])
        #expect(parser.consume(" |") == [.visible(" ")])
        #expect(parser.consume("") == [])
        let output = parser.finish()
        #expect(output.finalDeltas == [.visible("|")])
        #expect(output.visibleText == "Hello <b> |")
        #expect(output.toolCalls.isEmpty)
        #expect(output.parseError == nil)
    }

    @Test
    func emptyToolBlockEndsTheTurnWithoutCalls() {
        let output = run(["Ok.<｜DSML｜tool_calls>\n</｜DSML｜tool_calls>"], syntax: .dsml).output
        #expect(output.visibleText == "Ok.")
        #expect(output.toolCalls.isEmpty)
        #expect(output.parseError == nil)
    }

    @Test(arguments: DS4ToolSyntax.allCases)
    func largeArgumentsAndLongProseStreamTokenByToken(_ syntax: DS4ToolSyntax) throws {
        let body = "<header> " + String(repeating: "line with | and ｜ and < b > & text\n", count: 7_000)
        let prose = String(repeating: "Some prose with a < b and | pipes. ", count: 1_000)
        let rendered = DS4ToolCallRenderer.renderToolCalls(
            [DS4ToolCallReplay(name: "write", argumentsJSON: JSONValue.object(["content": .string(body)]).compactString())],
            syntax: syntax
        )
        let text = prose + rendered
        // Feed in token-sized pieces, as the engine does.
        var pieces: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.utf8.count >= 4 {
                pieces.append(current)
                current = ""
            }
        }
        pieces.append(current)
        let result = run(pieces, syntax: syntax)
        #expect(result.output.parseError == nil)
        #expect(result.output.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
            == prose.trimmingCharacters(in: .whitespacesAndNewlines))
        let call = try #require(result.output.toolCalls.first)
        #expect(try arguments(call) == ["content": .string(body)])
    }

    // MARK: Argument values

    @Test
    func argumentValuesFollowStringFlagsAndDeclaredTypes() throws {
        let types = DS4ToolParameterKind.map(from: [writeDescriptor, searchDescriptor])
        let dsml = run([
            "<｜DSML｜tool_calls><｜DSML｜invoke name=\"search\">"
                + "<｜DSML｜parameter name=\"query\" string=\"false\">123</｜DSML｜parameter>"
                + "<｜DSML｜parameter name=\"max_results\" string=\"false\">5</｜DSML｜parameter>"
                + "<｜DSML｜parameter name=\"paths\" string=\"false\">[\"a\", \"b\"]</｜DSML｜parameter>"
                + "<｜DSML｜parameter name=\"options\" string=\"false\">{\"mode\": \"regex\"}</｜DSML｜parameter>"
                + "<｜DSML｜parameter name=\"ratio\" string=\"false\">not json</｜DSML｜parameter>"
                + "<｜DSML｜parameter name=\"extra\" string=\"false\">\"quoted\"</｜DSML｜parameter>"
                + "<｜DSML｜parameter name=\"flag\">true</｜DSML｜parameter>"
                + "<｜DSML｜parameter name=\"max_results\" string=\"false\">9</｜DSML｜parameter>"
                + "</｜DSML｜invoke></｜DSML｜tool_calls>",
        ], syntax: .dsml, types: types).output
        #expect(try arguments(try #require(dsml.toolCalls.first)) == [
            "query": .string("123"),
            "max_results": .number(5),
            "paths": .array([.string("a"), .string("b")]),
            "options": .object(["mode": .string("regex")]),
            "ratio": .string("not json"),
            "extra": .string("quoted"),
            "flag": .bool(true),
        ])

        let glmText = "<tool_call>write<arg_key>path</arg_key><arg_value>123</arg_value>"
            + "<arg_key>content</arg_key><arg_value>{\"a\":1}</arg_value>"
            + "<arg_key>overwrite</arg_key><arg_value>true</arg_value>"
            + "<arg_key>other</arg_key><arg_value> 42 </arg_value>"
            + "<arg_key>quoted</arg_key><arg_value>\"x\"</arg_value></tool_call>"
        let glmTyped = run([glmText], syntax: .glm, types: types).output
        #expect(try arguments(try #require(glmTyped.toolCalls.first)) == [
            "path": .string("123"),
            "content": .string("{\"a\":1}"),
            "overwrite": .bool(true),
            "other": .number(42),
            "quoted": .string("\"x\""),
        ])
        let glmUntyped = run([glmText], syntax: .glm).output
        #expect(try arguments(try #require(glmUntyped.toolCalls.first))["path"] == .number(123))

        let qwenText = "<tool_call>\n<function=write>\n<parameter=path>\n123\n</parameter>\n"
            + "<parameter=overwrite>\nfalse\n</parameter>\n<parameter=content>\n\n  [1, 2]\n\n</parameter>\n</function>\n</tool_call>"
        let qwenTyped = run([qwenText], syntax: .qwen, types: types).output
        #expect(try arguments(try #require(qwenTyped.toolCalls.first)) == [
            "path": .string("123"),
            "overwrite": .bool(false),
            "content": .string("\n  [1, 2]\n"),
        ])
        let qwenUntyped = run([qwenText], syntax: .qwen).output
        #expect(try arguments(try #require(qwenUntyped.toolCalls.first))["content"] == .array([.number(1), .number(2)]))
    }

    @Test
    func attributesAreXMLUnescaped() throws {
        let output = run([
            "<｜DSML｜tool_calls><｜DSML｜invoke name=\"a&amp;b\"><｜DSML｜parameter name=\"x&quot;y\" string=\"true\">v</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜tool_calls>",
        ], syntax: .dsml).output
        let call = try #require(output.toolCalls.first)
        #expect(call.name == "a&b")
        #expect(try arguments(call) == ["x\"y": .string("v")])
    }

    // MARK: Every-byte splits

    @Test(arguments: splitFixtures)
    func everyByteSplitMatchesTheOneShotParse(_ fixture: DS4ToolOutputFixture) {
        let reference = run([fixture.text], syntax: fixture.syntax, thinking: fixture.thinking)
        expectNoMarkup(reference.output.visibleText)
        #expect(reference.visibleFromDeltas == reference.output.visibleText)
        #expect(reference.thoughtFromDeltas == reference.output.reasoningText)

        let byteCount = fixture.text.utf8.count
        var runs: [ParseRun] = [run(bytewiseChunks(fixture.text), syntax: fixture.syntax, thinking: fixture.thinking)]
        for offset in 0...byteCount {
            runs.append(run(chunks(fixture.text, splittingAt: [offset]), syntax: fixture.syntax, thinking: fixture.thinking))
        }
        for (index, candidate) in runs.enumerated() {
            #expect(candidate.summary == reference.summary, "split #\(index)")
            #expect(candidate.visibleFromDeltas == reference.output.visibleText, "split #\(index)")
            #expect(candidate.thoughtFromDeltas == reference.output.reasoningText, "split #\(index)")
            #expect(candidate.output.rawText == fixture.text, "split #\(index)")
            for snapshot in candidate.visibleSnapshots {
                #expect(reference.output.visibleText.hasPrefix(snapshot), "split #\(index): \(snapshot.debugDescription)")
            }
        }
    }

    @Test
    func splitFixturesProduceTheExpectedResults() throws {
        func result(_ name: String) throws -> DS4ParsedOutput {
            let fixture = try #require(splitFixtures.first { $0.name == name })
            return run([fixture.text], syntax: fixture.syntax, thinking: fixture.thinking).output
        }
        let dsml = try result("dsml-two-invokes-after-thinking")
        #expect(dsml.reasoningText == "plan ｜ step")
        #expect(dsml.visibleText == "Reading.\n\n")
        #expect(dsml.toolCalls.map(\.name) == ["read", "write"])
        #expect(try arguments(dsml.toolCalls[0]) == ["path": .string("ds4_agent.c"), "max_lines": .number(80)])
        #expect(try arguments(dsml.toolCalls[1]) == ["content": .string("<p>&amp; &lt;</p> </tool_call> </think> </｜DSML｜parameter>")])

        let dsml41 = try result("dsml41-spaced-tags")
        #expect(dsml41.visibleText == "Ok <b>|x|</b>\n\n")
        #expect(try arguments(try #require(dsml41.toolCalls.first)) == ["command": .string("printf '｜DSML｜'"), "refresh_sec": .number(1)])

        let glm = try result("glm-two-calls-with-markup-in-value")
        #expect(glm.reasoningText == "think <tool")
        #expect(glm.visibleText == "intro <to x ")
        #expect(glm.toolCalls.map(\.name) == ["write", "bash"])
        #expect(try arguments(glm.toolCalls[0]) == ["content": .string("<p>&amp; &lt;</p> </tool_call> </think> </arg_value>")])

        let qwen = try result("qwen-two-calls")
        #expect(qwen.reasoningText == "reason\n")
        #expect(qwen.visibleText == "intro <toolbox>\n")
        #expect(qwen.toolCalls.map(\.name) == ["bash", "write"])
        #expect(try arguments(qwen.toolCalls[1]) == ["content": .string("literal </tool_call> </think> <think> </parameter>")])

        #expect(try result("glm-missing-arg-value").parseError?.detail == "expected <arg_value> in GLM tool call")
        let marker = try result("dsml-marker-in-prose")
        #expect(marker.visibleText == "see ")
        #expect(marker.parseError?.detail == "DSML markup outside a valid tool_calls block")
        let inThinking = try result("dsml-tool-inside-thinking")
        #expect(inThinking.reasoningText == "plan ")
        #expect(inThinking.parseError?.detail == "tool calling is not allowed inside <think></think>")
        let plain = try result("plain-text-only")
        #expect(plain.visibleText == "a < b | c <thi <｜x <DSM done 🙂")
        #expect(plain.parseError == nil)
    }

    // MARK: Replay rendering

    @Test
    func renderMatchesTheNativeTemplates() {
        let read = DS4ToolCallReplay(name: "read", argumentsJSON: #"{"path":"a.txt","max_lines":80}"#)
        let list = DS4ToolCallReplay(name: "list", argumentsJSON: "{}")
        #expect(DS4ToolCallRenderer.renderToolCalls([read], syntax: .dsml) == "\n\n<｜DSML｜tool_calls>\n<｜DSML｜invoke name=\"read\">\n"
            + "<｜DSML｜parameter name=\"path\" string=\"true\">a.txt</｜DSML｜parameter>\n"
            + "<｜DSML｜parameter name=\"max_lines\" string=\"false\">80</｜DSML｜parameter>\n"
            + "</｜DSML｜invoke>\n</｜DSML｜tool_calls>")
        #expect(DS4ToolCallRenderer.renderToolCalls([read], syntax: .dsml41) == "\n\n<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"read\">\n"
            + "<｜DSML｜ parameter name=\"path\" string=\"true\">a.txt</｜DSML｜ parameter>\n"
            + "<｜DSML｜ parameter name=\"max_lines\" string=\"false\">80</｜DSML｜ parameter>\n"
            + "</｜DSML｜ invoke>\n</｜DSML｜ calls>")
        #expect(DS4ToolCallRenderer.renderToolCalls([read, list], syntax: .glm)
            == "<tool_call>read<arg_key>path</arg_key><arg_value>a.txt</arg_value>"
            + "<arg_key>max_lines</arg_key><arg_value>80</arg_value></tool_call><tool_call>list</tool_call>")
        #expect(DS4ToolCallRenderer.renderToolCalls([read, list], syntax: .qwen)
            == "<tool_call>\n<function=read>\n<parameter=path>\na.txt\n</parameter>\n<parameter=max_lines>\n80\n</parameter>\n"
            + "</function>\n</tool_call>\n<tool_call>\n<function=list>\n</function>\n</tool_call>")
        #expect(DS4ToolCallRenderer.renderToolCalls([list], syntax: .qwen, hasContent: true)
            == "\n\n<tool_call>\n<function=list>\n</function>\n</tool_call>")
        #expect(DS4ToolCallRenderer.renderToolCalls([], syntax: .dsml).isEmpty)
    }

    @Test
    func renderFallsBackForNonObjectArguments() {
        let bad = DS4ToolCallReplay(name: "x", argumentsJSON: "not </arg_value> json")
        #expect(DS4ToolCallRenderer.renderToolCalls([bad], syntax: .dsml).contains(
            "<｜DSML｜parameter name=\"arguments\" string=\"true\">not </arg_value> json</｜DSML｜parameter>"))
        #expect(DS4ToolCallRenderer.renderToolCalls([bad], syntax: .glm)
            == "<tool_call>x<arg_key>arguments</arg_key><arg_value>not &lt;/arg_value> json</arg_value></tool_call>")
        #expect(DS4ToolCallRenderer.renderToolCalls([bad], syntax: .qwen)
            == "<tool_call>\n<function=x>\n<parameter=arguments>\nnot </arg_value> json\n</parameter>\n</function>\n</tool_call>")
    }

    @Test(arguments: DS4ToolSyntax.allCases)
    func renderThenParseRoundTrips(_ syntax: DS4ToolSyntax) throws {
        let content = "line1\n</｜DSML｜parameter> &lt;/｜DSML｜parameter> </｜DSML｜ parameter> </arg_value> &lt;/arg_value> "
            + "</parameter> &lt;/parameter> &amp;lt;/parameter> </tool_call> </think> <think> & &amp; 🙂\n"
        let calls = [
            DS4ToolCallReplay(
                name: "write",
                argumentsJSON: #"{"path": "/tmp/a b.txt", "content": "#
                    + DS4JSONText.quoted(content) + #", "overwrite": true}"#
            ),
            DS4ToolCallReplay(
                name: "search",
                argumentsJSON: #"{"query":"123","max_results":5,"ratio":1.5,"paths":["a","</｜DSML｜parameter>"],"options":{"flags":[1,2],"mode":"regex"},"none":null}"#
            ),
            DS4ToolCallReplay(name: "list", argumentsJSON: "{}"),
        ]
        let types = DS4ToolParameterKind.map(from: [writeDescriptor, searchDescriptor])
        let rendered = DS4ToolCallRenderer.renderToolCalls(calls, syntax: syntax)
        let text = "plan</think>" + rendered
        for chunks in [[text], bytewiseChunks(text)] {
            let output = run(chunks, syntax: syntax, thinking: true, types: types).output
            #expect(output.parseError == nil)
            #expect(output.reasoningText == "plan")
            #expect(output.visibleText.isEmpty)
            #expect(output.toolCalls.map(\.name) == calls.map(\.name))
            for (call, original) in zip(output.toolCalls, calls) {
                let expected = try JSONDecoder().decode(JSONObject.self, from: Data(original.argumentsJSON.utf8))
                #expect(try arguments(call) == expected)
            }
            let expectedReplays = calls.map { call in
                DS4ToolCallReplay(
                    name: call.name,
                    argumentsJSON: DS4JSONText.object((DS4JSONText.orderedMembers(call.argumentsJSON) ?? []).map { ($0.key, $0.value) })
                )
            }
            #expect(output.toolCallReplays == expectedReplays)
            #expect(DS4ToolCallRenderer.renderToolCalls(output.toolCallReplays, syntax: syntax) == rendered)
        }
    }

    // MARK: Tools prompt

    @Test
    func dsmlToolsPromptFollowsDS4AgentStructure() {
        let prompt = DS4ToolsPrompt.toolsPrompt(descriptors: [writeDescriptor, bashDescriptor], syntax: .dsml, hasVision: false)
        #expect(prompt.hasPrefix("## Tools\n\nYou have access to native DSML tools."))
        #expect(prompt.contains("<｜DSML｜tool_calls>\n<｜DSML｜invoke name=\"$TOOL_NAME\">\n"
            + "<｜DSML｜parameter name=\"$PARAMETER_NAME\" string=\"true|false\">$PARAMETER_VALUE</｜DSML｜parameter>\n"
            + "</｜DSML｜invoke>\n</｜DSML｜tool_calls>\n\n"))
        #expect(prompt.contains("escape a literal closing parameter tag as &lt;/｜DSML｜parameter>. "
            + "To write that escaped spelling literally, use &amp;lt;/｜DSML｜parameter>."))
        #expect(prompt.contains("### Available Tool Schemas\n\n"
            + #"{"type":"function","function":{"name":"bash","description":"Run a shell command.","parameters":{"type":"object","properties":{"command":{"type":"string"},"refresh_sec":{"type":"integer"}},"required":["command"]}}}"#
            + "\n\n"
            + #"{"type":"function","function":{"name":"write","description":"The write tool.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"overwrite":{"type":"boolean"}},"required":["path","content"]}}}"#
            + "\n\n# Rules\n\n- Always use strict syntax for DSML tool stanzas.\n"))
        #expect(prompt.hasSuffix("- Always use strict syntax for DSML tool stanzas.\n"))
        #expect(!prompt.contains("You are a coding agent"))
        #expect(!prompt.contains("｜DSML｜ calls"))
    }

    @Test
    func dsml41ToolsPromptUsesSpacedTags() {
        let prompt = DS4ToolsPrompt.toolsPrompt(descriptors: [bashDescriptor], syntax: .dsml41, hasVision: false)
        #expect(prompt.contains("<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"$TOOL_NAME\">\n<｜DSML｜ parameter name="))
        #expect(prompt.contains("</｜DSML｜ parameter>\n</｜DSML｜ invoke>\n</｜DSML｜ calls>\n"))
        #expect(prompt.contains("&lt;/｜DSML｜ parameter>. To write that escaped spelling literally, use &amp;lt;/｜DSML｜ parameter>."))
        #expect(!prompt.contains("｜DSML｜tool_calls"))
        #expect(!prompt.contains("｜DSML｜invoke"))
        #expect(!prompt.contains("｜DSML｜parameter"))
    }

    @Test
    func glmToolsPromptIsNative() {
        let prompt = DS4ToolsPrompt.toolsPrompt(descriptors: [bashDescriptor], syntax: .glm, hasVision: true)
        #expect(prompt.hasPrefix("# Tools\n\nYou may call one or more functions to assist with the user query.\n\n"))
        #expect(prompt.contains("<tools>\n"
            + #"{"name":"bash","description":"Run a shell command.","parameters":{"type":"object","properties":{"command":{"type":"string"},"refresh_sec":{"type":"integer"}},"required":["command"]}}"#
            + "\n</tools>\n\n"))
        #expect(prompt.contains("<tool_call>{function-name}<arg_key>{arg-key-1}</arg_key>"))
        #expect(prompt.contains("escape a literal </arg_value> as &lt;/arg_value>"))
        #expect(!prompt.contains("\"type\":\"function\""))
        #expect(!prompt.contains("\"function\":"))
        #expect(!prompt.contains("<｜DSML｜"))
        #expect(!prompt.contains("view_image"))
    }

    @Test
    func qwenToolsPromptIsNative() {
        let prompt = DS4ToolsPrompt.toolsPrompt(descriptors: [bashDescriptor], syntax: .qwen, hasVision: false)
        #expect(prompt.hasPrefix("# Tools\n\nYou have access to the following functions:\n\n<tools>\n"
            + #"{"type": "function", "function": {"name":"bash","description":"Run a shell command.","parameters":"#))
        #expect(prompt.contains("}}\n</tools>\n\n"))
        #expect(prompt.contains("<tool_call>\n<function=example_function_name>\n<parameter=example_parameter_1>\nvalue_1\n</parameter>\n"))
        #expect(prompt.contains("escape a literal </parameter> as &lt;/parameter>"))
        #expect(prompt.hasSuffix("finish thinking before emitting <tool_call>.\n"))
        #expect(!prompt.contains("<arg_key>"))
        #expect(!prompt.contains("<｜DSML｜"))
    }

    @Test
    func toolsPromptIsDeterministic() {
        let duplicate = descriptor("bash", #"{"type":"object","properties":{"other":{"type":"string"}}}"#)
        let broken = descriptor("broken", "{not json", description: "Line one.\n\"Quoted\" </tools>")
        for syntax in DS4ToolSyntax.allCases {
            let forward = DS4ToolsPrompt.toolsPrompt(
                descriptors: [bashDescriptor, writeDescriptor, broken, duplicate],
                syntax: syntax,
                hasVision: false
            )
            let shuffled = DS4ToolsPrompt.toolsPrompt(
                descriptors: [writeDescriptor, broken, bashDescriptor, duplicate],
                syntax: syntax,
                hasVision: true
            )
            #expect(forward == shuffled, "\(syntax)")
            #expect(!forward.contains("\"other\""), "\(syntax)")
            #expect(forward.contains(#""name":"broken","description":"Line one.\n\"Quoted\" </tools>","parameters":{"type":"object","properties":{}}"#), "\(syntax)")
            let bash = forward.range(of: "\"name\":\"bash\"")?.lowerBound
            let write = forward.range(of: "\"name\":\"write\"")?.lowerBound
            if let bash, let write {
                #expect(bash < write, "\(syntax)")
            } else {
                Issue.record("missing tool schema in \(syntax) prompt")
            }
            #expect(DS4ToolsPrompt.toolsPrompt(descriptors: [], syntax: syntax, hasVision: true).isEmpty)
        }
    }
}
