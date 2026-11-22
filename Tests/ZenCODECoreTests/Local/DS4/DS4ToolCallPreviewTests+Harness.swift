//
//  DS4ToolCallPreviewTests+Harness.swift
//  ZenCODE
//
//  Harness of the DS4 tool-call preview tests: chunk decoding, parsed-output
//  runs, preview merging, markup rendering and the bridge event collector.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

extension DS4ToolCallPreviewTests {
    typealias Preview = DirectAgentToolCallPreview

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
    func splitChunks(_ text: String, at offsets: [Int]) -> [String] {
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

    func bytewiseChunks(_ text: String) -> [String] {
        splitChunks(text, at: Array(0..<text.utf8.count))
    }

    /// Byte range of the last occurrence of `needle` in `text`.
    func lastByteRange(of needle: String, in text: String) -> Range<Int>? {
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

    struct GenerationFlags: Equatable {
        let stop: Bool
        let greedy: Bool
    }

    struct OutputSummary: Equatable {
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

    struct PreviewRun {
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

    func previewRun(
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
    func merged(_ previews: [Preview]) -> [Preview] {
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

    func fragments(_ previews: [Preview]) -> [String] {
        previews.compactMap { preview in
            if case let .parameterText(text) = preview {
                return text
            }
            return nil
        }
    }

    /// The streamed text of every parameter that ended, in order.
    func closedParameterTexts(_ previews: [Preview]) -> [String] {
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
    func openParameterText(_ previews: [Preview]) -> String? {
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

    func endedCount(_ previews: [Preview]) -> Int {
        previews.filter { $0 == .ended }.count
    }

    /// The visible text of `deltas`, in order.
    func visibleText(_ deltas: some Sequence<[DS4ParsedOutputDelta]>) -> String {
        deltas.joined().map { delta in
            if case let .visible(text) = delta {
                return text
            }
            return ""
        }.joined()
    }

    /// Raw argument values of the standalone stream parser, in order.
    func rawValues(_ text: String, syntax: DS4ToolSyntax) -> [String] {
        var parser = DS4ToolCallStreamParser(syntax: syntax)
        for byte in text.utf8 {
            parser.feed(byte: byte)
        }
        parser.finish()
        return parser.calls.flatMap(\.arguments).map(\.rawValue)
    }

    /// After every drain, the text streamed so far for the open parameter is a
    /// prefix of its final raw value: nothing that is not content was emitted.
    func expectStreamedPrefixes(
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

    func stringArguments(_ call: DirectAgentToolCall?) throws -> [String: String] {
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
    struct Markup {
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

    func writeBlock(_ syntax: DS4ToolSyntax, content: String = fileContent) -> String {
        Markup(syntax: syntax).block([("local.write", [("path", filePath), ("content", content)])])
    }

    func writePreviews(content: String) -> [Preview] {
        [
            .toolStarted(name: "local.write"),
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
    func representativeInputs() -> [(syntax: DS4ToolSyntax, thinking: Bool, text: String)] {
        var inputs: [(DS4ToolSyntax, Bool, String)] = []
        for syntax in DS4ToolSyntax.allCases {
            let markup = Markup(syntax: syntax)
            inputs.append((syntax, false, prose + writeBlock(syntax)))
            inputs.append((syntax, true, "plan</think>" + prose + writeBlock(syntax)))
            inputs.append((syntax, false, markup.block([
                ("local.read", [("path", "a.swift")]),
                ("local.write", [("path", "b.swift"), ("content", "x\n")]),
            ])))
            inputs.append((syntax, false, prose + markup.blockOpen + markup.callOpen("local.write")
                + markup.parameterOpen("content") + "partial line\nnext <"))
            inputs.append((syntax, true, "plan " + markup.block([("local.read", [("path", "a")])])))
            inputs.append((syntax, false, "a < b | c <thi <｜x <DSM done 🙂"))
        }
        inputs.append((.dsml, false, "<｜DSML｜tool_calls>\n<｜DSML｜invoke name=\"local.read\">\n<｜DSML｜bogus name=\"x\">"))
        inputs.append((.dsml, false, "see <DSML｜ and ｜DSML｜ later"))
        inputs.append((.glm, false, "<tool_call>local.read<arg_key>path</arg_key>oops</tool_call>"))
        inputs.append((.qwen, false, "<tool_call>\n<function=local.read>\n<parameter=path>\na\n</parameter>\n</function>\nnope"))
        return inputs.map { (syntax: $0.0, thinking: $0.1, text: $0.2) }
    }

    // MARK: - Bridge harness

    enum BridgeEvent: Equatable {
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

    func collect(_ stream: AsyncStream<DirectAgentEvent>) async -> [BridgeEvent] {
        var events: [BridgeEvent] = []
        for await event in stream {
            events.append(bridgeEvent(event))
        }
        return events
    }
}

let prose = "Writing the file.\n\n"
let filePath = "Sources/App/main.swift"
let fileContent = "import Foundation\n\nlet ok = 1 < 2 && 3 > 2\nprint(\"<div>x</div>\")\n// ciao 🙂\n"
