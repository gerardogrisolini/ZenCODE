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

    // MARK: Stream behaviour

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
