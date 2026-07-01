//
//  DS4ToolBridge.swift
//  ZenCODE
//

import Foundation
import ZenCODECore

struct DS4ParsedToolCall {
    let name: String
    let argumentsJSON: String
    let argumentsObject: [String: AnyHashable]
}

struct DS4ParsedGeneratedMessage {
    let replayText: String
    let toolCalls: [DS4ParsedToolCall]
    let rawDSML: String?
    let parseError: String?
}

enum DS4ToolBridge {
    static let toolCallsStart = "<｜DSML｜tool_calls>"
    static let toolCallsEnd = "</｜DSML｜tool_calls>"
    static var toolCallStartMarkers: [String] {
        syntaxes.map(\.toolCallsStart)
    }
    static let syntaxReminder = """
    DSML syntax reminder:
    <｜DSML｜tool_calls>
    <｜DSML｜invoke name="$TOOL_NAME">
    <｜DSML｜parameter name="$PARAMETER_NAME" string="true|false">$PARAMETER_VALUE</｜DSML｜parameter>
    </｜DSML｜invoke>
    </｜DSML｜tool_calls>
    """

    private struct Syntax {
        let toolCallsStart: String
        let toolCallsEnd: String
        let invokeStart: String
        let invokeEnd: String
        let parameterStart: String
        let parameterEnd: String
    }

    private static let syntaxes = [
        Syntax(
            toolCallsStart: "<｜DSML｜tool_calls>",
            toolCallsEnd: "</｜DSML｜tool_calls>",
            invokeStart: "<｜DSML｜invoke",
            invokeEnd: "</｜DSML｜invoke>",
            parameterStart: "<｜DSML｜parameter",
            parameterEnd: "</｜DSML｜parameter>"
        ),
        Syntax(
            toolCallsStart: "<DSML｜tool_calls>",
            toolCallsEnd: "</DSML｜tool_calls>",
            invokeStart: "<DSML｜invoke",
            invokeEnd: "</DSML｜invoke>",
            parameterStart: "<DSML｜parameter",
            parameterEnd: "</DSML｜parameter>"
        ),
        Syntax(
            toolCallsStart: "<tool_calls>",
            toolCallsEnd: "</tool_calls>",
            invokeStart: "<invoke",
            invokeEnd: "</invoke>",
            parameterStart: "<parameter",
            parameterEnd: "</parameter>"
        )
    ]

    static func toolPrompt(descriptors: [DirectToolDescriptor]) -> String? {
        guard !descriptors.isEmpty else {
            return nil
        }
        let schemas = descriptors
            .map(renderToolSchema)
            .joined(separator: "\n")
        guard !schemas.isEmpty else {
            return nil
        }
        return """
        ## Tools

        You have access to a set of tools to help answer the user question. You can invoke tools by writing a "<｜DSML｜tool_calls>" block like the following:

        <｜DSML｜tool_calls>
        <｜DSML｜invoke name="$TOOL_NAME">
        <｜DSML｜parameter name="$PARAMETER_NAME" string="true|false">$PARAMETER_VALUE</｜DSML｜parameter>
        ...
        </｜DSML｜invoke>
        <｜DSML｜invoke name="$TOOL_NAME2">
        ...
        </｜DSML｜invoke>
        </｜DSML｜tool_calls>

        String parameters should be specified as raw text and set `string="true"`. Preserve characters such as `>`, `&`, and `&&` exactly; never replace normal string characters with XML or HTML entity escapes. Only if a string value itself contains the exact closing parameter tag `</｜DSML｜parameter>`, write that tag as `&lt;/｜DSML｜parameter>` inside the value. For all other types (numbers, booleans, arrays, objects), pass the value in JSON format and set `string="false"`.

        If thinking_mode is enabled (triggered by <think>), you MUST output your complete reasoning inside <think>...</think> BEFORE any tool calls or final response.

        Otherwise, output directly after </think> with tool calls or final response.

        ### Available Tool Schemas

        \(schemas)

        You MUST strictly follow the above defined tool name and parameter schemas to invoke tool calls. Use the exact parameter names from the schemas.
        """
    }

    static func systemPrompt(
        basePrompt: String?,
        descriptors: [DirectToolDescriptor]
    ) -> String? {
        let sections = [
            toolPrompt(descriptors: descriptors),
            basePrompt?.nilIfBlank
        ].compactMap(\.self)
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    static func parseGeneratedMessage(
        _ text: String,
        requireThinkingClosed: Bool
    ) -> DS4ParsedGeneratedMessage {
        let searchStart: String.Index
        if requireThinkingClosed {
            guard let thinkEnd = text.range(of: "</think>", options: .backwards) else {
                return DS4ParsedGeneratedMessage(
                    replayText: text,
                    toolCalls: [],
                    rawDSML: nil,
                    parseError: nil
                )
            }
            searchStart = thinkEnd.upperBound
        } else {
            searchStart = text.startIndex
        }

        guard let match = firstToolCallsStart(in: text, from: searchStart) else {
            return DS4ParsedGeneratedMessage(
                replayText: text,
                toolCalls: [],
                rawDSML: nil,
                parseError: nil
            )
        }

        do {
            let parsed = try parseToolCalls(in: text, start: match.range.lowerBound, syntax: match.syntax)
            let replayEnd = text.trimmedWhitespaceEnd(before: match.range.lowerBound)
            return DS4ParsedGeneratedMessage(
                replayText: String(text[..<replayEnd]),
                toolCalls: parsed.calls,
                rawDSML: parsed.rawDSML,
                parseError: nil
            )
        } catch {
            let replayEnd = text.trimmedWhitespaceEnd(before: match.range.lowerBound)
            return DS4ParsedGeneratedMessage(
                replayText: String(text[..<replayEnd]),
                toolCalls: [],
                rawDSML: nil,
                parseError: error.localizedDescription.nilIfBlank ?? "parse error"
            )
        }
    }

    static func renderToolCalls(_ toolCalls: [AgentRuntimeToolCall]) -> String {
        guard !toolCalls.isEmpty else {
            return ""
        }
        var result = "\n\n\(toolCallsStart)\n"
        for toolCall in toolCalls {
            result += "<｜DSML｜invoke name=\"\(dsmlAttributeEscaped(toolCall.name))\">\n"
            let arguments = orderedArguments(from: toolCall.argumentsJSON)
            if arguments.isEmpty, !toolCall.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result += "<｜DSML｜parameter name=\"arguments\" string=\"true\">"
                result += dsmlParameterTextEscaped(toolCall.argumentsJSON)
                result += "</｜DSML｜parameter>\n"
            } else {
                for argument in arguments {
                    result += "<｜DSML｜parameter name=\"\(dsmlAttributeEscaped(argument.name))\" string=\"\(argument.isString ? "true" : "false")\">"
                    result += argument.isString
                        ? dsmlParameterTextEscaped(argument.stringValue ?? "")
                        : dsmlJSONLiteralEscaped(argument.rawValue)
                    result += "</｜DSML｜parameter>\n"
                }
            }
            result += "</｜DSML｜invoke>\n"
        }
        result += toolCallsEnd
        return result
    }

    static func directToolCall(from parsed: DS4ParsedToolCall, index: Int) -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: "call_ds4_\(UUID().uuidString.lowercased())_\(index)",
            name: parsed.name,
            argumentsObject: parsed.argumentsObject.mapValues { $0.jsonObject },
            argumentsJSON: parsed.argumentsJSON
        )
    }

    private static func renderToolSchema(_ descriptor: DirectToolDescriptor) -> String {
        let schema = minifiedJSON(descriptor.inputSchema)
            ?? #"{"type":"object","properties":{}}"#
        return """
        {"name":\(jsonString(descriptor.name)),"description":\(jsonString(descriptor.description)),"parameters":\(schema)}
        """
    }

    private static func firstToolCallsStart(
        in text: String,
        from start: String.Index
    ) -> (range: Range<String.Index>, syntax: Syntax)? {
        var best: (range: Range<String.Index>, syntax: Syntax)?
        for syntax in syntaxes {
            guard let range = text.range(
                of: syntax.toolCallsStart,
                range: start..<text.endIndex
            ) else {
                continue
            }
            if best == nil || range.lowerBound < best!.range.lowerBound {
                best = (range, syntax)
            }
        }
        return best
    }

    private static func parseToolCalls(
        in text: String,
        start: String.Index,
        syntax: Syntax
    ) throws -> (calls: [DS4ParsedToolCall], rawDSML: String) {
        guard text.hasPrefix(syntax.toolCallsStart, at: start) else {
            throw DS4ToolBridgeError.invalidDSML("missing tool_calls start")
        }
        var index = text.index(start, offsetBy: syntax.toolCallsStart.count)
        var calls: [DS4ParsedToolCall] = []

        while true {
            index = text.skippingASCIIWhitespace(from: index)
            if text.hasPrefix(syntax.toolCallsEnd, at: index) {
                let end = text.index(index, offsetBy: syntax.toolCallsEnd.count)
                return (calls, String(text[start..<end]))
            }

            let invokeSyntax = syntaxForInvokeTag(at: index, in: text)
            guard let invokeSyntax else {
                throw DS4ToolBridgeError.invalidDSML("expected invoke tag")
            }
            let tagEnd = try text.tagEnd(from: index)
            let tag = String(text[index...tagEnd])
            guard let name = attribute("name", in: tag)?.nilIfBlank else {
                throw DS4ToolBridgeError.invalidDSML("tool invoke without name")
            }
            index = text.index(after: tagEnd)

            var argumentPairs: [String] = []
            var argumentObject: [String: AnyHashable] = [:]
            while true {
                index = text.skippingASCIIWhitespace(from: index)
                if text.hasPrefix(invokeSyntax.invokeEnd, at: index) {
                    index = text.index(index, offsetBy: invokeSyntax.invokeEnd.count)
                    break
                }
                guard text.hasPrefix(invokeSyntax.parameterStart, at: index) else {
                    throw DS4ToolBridgeError.invalidDSML("expected parameter tag")
                }
                let parameterTagEnd = try text.tagEnd(from: index)
                let parameterTag = String(text[index...parameterTagEnd])
                guard let parameterName = attribute("name", in: parameterTag)?.nilIfBlank else {
                    throw DS4ToolBridgeError.invalidDSML("tool parameter without name")
                }
                let isString = (attribute("string", in: parameterTag) ?? "true") == "true"
                let valueStart = text.index(after: parameterTagEnd)
                guard let valueEnd = text.range(
                    of: invokeSyntax.parameterEnd,
                    range: valueStart..<text.endIndex
                )?.lowerBound else {
                    throw DS4ToolBridgeError.invalidDSML("parameter without closing tag")
                }
                let rawValue = String(text[valueStart..<valueEnd])
                let valueJSON: String
                if isString {
                    let value = dsmlUnescaped(rawValue)
                    valueJSON = jsonString(value)
                    argumentObject[parameterName] = AnyHashable(value)
                } else {
                    let minified = minifiedJSONFragment(rawValue) ?? "null"
                    valueJSON = minified
                    argumentObject[parameterName] = anyHashableJSONValue(from: minified)
                }
                argumentPairs.append("\(jsonString(parameterName)):\(valueJSON)")
                index = text.index(valueEnd, offsetBy: invokeSyntax.parameterEnd.count)
            }
            let argumentsJSON = "{\(argumentPairs.joined(separator: ","))}"
            calls.append(
                DS4ParsedToolCall(
                    name: name,
                    argumentsJSON: argumentsJSON,
                    argumentsObject: argumentObject
                )
            )
        }
    }

    private static func syntaxForInvokeTag(
        at index: String.Index,
        in text: String
    ) -> Syntax? {
        for syntax in syntaxes {
            if text.hasPrefix(syntax.invokeStart, at: index) {
                return syntax
            }
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let start = tag.range(of: "\(name)=\"")?.upperBound else {
            return nil
        }
        guard let end = tag[start...].firstIndex(of: "\"") else {
            return nil
        }
        return dsmlUnescaped(String(tag[start..<end]))
    }

    private static func dsmlAttributeEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func dsmlParameterTextEscaped(_ value: String) -> String {
        value.replacingOccurrences(
            of: "</｜DSML｜parameter>",
            with: "&lt;/｜DSML｜parameter>"
        )
    }

    private static func dsmlJSONLiteralEscaped(_ value: String) -> String {
        value.replacingOccurrences(
            of: "</｜DSML｜parameter>",
            with: "\\u003c/｜DSML｜parameter>"
        )
    }

    private static func dsmlUnescaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func orderedArguments(from json: String) -> [OrderedArgument] {
        var parser = OrderedJSONObjectParser(json)
        return (try? parser.parse()) ?? []
    }

    private static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            case "\u{08}":
                result += "\\b"
            case "\u{0c}":
                result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }

    private static func minifiedJSON(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: encoded, encoding: .utf8)
    }

    fileprivate static func minifiedJSONFragment(_ raw: String) -> String? {
        let wrapped = "[\(raw)]"
        guard let data = wrapped.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let value = array.first else {
            return nil
        }
        return jsonFragment(from: value)
    }

    private static func jsonFragment(from value: Any) -> String? {
        if value is NSNull {
            return "null"
        }
        if let string = value as? String {
            return jsonString(string)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func anyHashableJSONValue(from raw: String) -> AnyHashable {
        let wrapped = "[\(raw)]"
        guard let data = wrapped.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let value = array.first else {
            return AnyHashable(NSNull())
        }
        return AnyHashable(jsonCompatibleHashable(value))
    }

    private static func jsonCompatibleHashable(_ value: Any) -> AnyHashable {
        if value is NSNull {
            return AnyHashable(NSNull())
        }
        if let value = value as? String {
            return AnyHashable(value)
        }
        if let value = value as? Bool {
            return AnyHashable(value)
        }
        if let value = value as? NSNumber {
            return AnyHashable(value)
        }
        if let value = value as? [Any] {
            return AnyHashable(value.map { jsonCompatibleHashable($0) })
        }
        if let value = value as? [String: Any] {
            return AnyHashable(value.mapValues { jsonCompatibleHashable($0) })
        }
        return AnyHashable(String(describing: value))
    }
}

private struct OrderedArgument {
    let name: String
    let rawValue: String
    let isString: Bool
    let stringValue: String?
}

private struct OrderedJSONObjectParser {
    private let text: String
    private var index: String.Index

    init(_ text: String) {
        self.text = text
        self.index = text.startIndex
    }

    mutating func parse() throws -> [OrderedArgument] {
        index = text.skippingASCIIWhitespace(from: index)
        guard index < text.endIndex, text[index] == "{" else {
            throw DS4ToolBridgeError.invalidJSON("expected object")
        }
        index = text.index(after: index)
        var arguments: [OrderedArgument] = []
        while true {
            index = text.skippingASCIIWhitespace(from: index)
            guard index < text.endIndex else {
                throw DS4ToolBridgeError.invalidJSON("unexpected end")
            }
            if text[index] == "}" {
                index = text.index(after: index)
                return arguments
            }
            let name = try parseJSONString()
            index = text.skippingASCIIWhitespace(from: index)
            guard index < text.endIndex, text[index] == ":" else {
                throw DS4ToolBridgeError.invalidJSON("expected colon")
            }
            index = text.index(after: index)
            index = text.skippingASCIIWhitespace(from: index)
            let valueStart = index
            let valueEnd = try scanJSONValueEnd()
            let rawValue = String(text[valueStart..<valueEnd])
            let isString = text[valueStart] == "\""
            let stringValue = isString ? try decodeJSONString(rawValue) : nil
            arguments.append(
                OrderedArgument(
                    name: name,
                    rawValue: DS4ToolBridge.minifiedJSONFragment(rawValue) ?? rawValue,
                    isString: isString,
                    stringValue: stringValue
                )
            )
            index = text.skippingASCIIWhitespace(from: valueEnd)
            guard index < text.endIndex else {
                throw DS4ToolBridgeError.invalidJSON("unexpected end")
            }
            if text[index] == "," {
                index = text.index(after: index)
                continue
            }
            if text[index] == "}" {
                continue
            }
            throw DS4ToolBridgeError.invalidJSON("expected comma or object end")
        }
    }

    private mutating func parseJSONString() throws -> String {
        let start = index
        let end = try scanJSONStringEnd()
        let raw = String(text[start..<end])
        index = end
        return try decodeJSONString(raw)
    }

    private mutating func scanJSONStringEnd() throws -> String.Index {
        guard index < text.endIndex, text[index] == "\"" else {
            throw DS4ToolBridgeError.invalidJSON("expected string")
        }
        var cursor = text.index(after: index)
        var escaped = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return text.index(after: cursor)
            }
            cursor = text.index(after: cursor)
        }
        throw DS4ToolBridgeError.invalidJSON("unterminated string")
    }

    private mutating func scanJSONValueEnd() throws -> String.Index {
        guard index < text.endIndex else {
            throw DS4ToolBridgeError.invalidJSON("unexpected end")
        }
        if text[index] == "\"" {
            return try scanJSONStringEnd()
        }
        var cursor = index
        var depth = 0
        var inString = false
        var escaped = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                cursor = text.index(after: cursor)
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "{", "[":
                depth += 1
            case "}", "]":
                if depth == 0 {
                    return cursor
                }
                depth -= 1
            case ",":
                if depth == 0 {
                    return cursor
                }
            default:
                break
            }
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    private func decodeJSONString(_ raw: String) throws -> String {
        let wrapped = "[\(raw)]"
        guard let data = wrapped.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let value = array.first as? String else {
            throw DS4ToolBridgeError.invalidJSON("invalid string")
        }
        return value
    }
}

enum DS4ToolBridgeError: LocalizedError {
    case invalidDSML(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidDSML(let message):
            return message
        case .invalidJSON(let message):
            return message
        }
    }
}

private extension AnyHashable {
    var jsonObject: Any {
        if let array = base as? [AnyHashable] {
            return array.map(\.jsonObject)
        }
        if let object = base as? [String: AnyHashable] {
            return object.mapValues(\.jsonObject)
        }
        return base
    }
}

private extension String {
    func hasPrefix(_ prefix: String, at index: String.Index) -> Bool {
        guard index <= endIndex,
              let upper = self.index(index, offsetBy: prefix.count, limitedBy: endIndex) else {
            return false
        }
        return self[index..<upper] == prefix
    }

    func skippingASCIIWhitespace(from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < endIndex {
            switch self[cursor] {
            case " ", "\n", "\r", "\t":
                cursor = index(after: cursor)
            default:
                return cursor
            }
        }
        return cursor
    }

    func tagEnd(from start: String.Index) throws -> String.Index {
        guard let end = self[start...].firstIndex(of: ">") else {
            throw DS4ToolBridgeError.invalidDSML("unterminated tag")
        }
        return end
    }

    func trimmedWhitespaceEnd(before end: String.Index) -> String.Index {
        var cursor = end
        while cursor > startIndex {
            let previous = index(before: cursor)
            switch self[previous] {
            case " ", "\n", "\r", "\t":
                cursor = previous
            default:
                return cursor
            }
        }
        return cursor
    }
}
