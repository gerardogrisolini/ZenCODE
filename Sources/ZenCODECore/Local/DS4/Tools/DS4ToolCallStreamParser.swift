//
//  DS4ToolCallStreamParser.swift
//  ZenCODE
//
//  Port of ds4-agent's streaming tool-call parser (`agent_dsml_parser`,
//  ds4_agent.c agent_dsml_feed/agent_dsml_parse/agent_glm_tool_parse/
//  agent_qwen_tool_parse/agent_dsml_finish). It is fed one byte at a time:
//  incomplete input leaves the state unchanged until enough bytes arrive,
//  malformed completed input switches to `.error` so the model gets a retryable
//  tool error. Argument values are kept raw; DS4GeneratedOutputParser turns them
//  into JSON.
//

import Foundation

struct DS4ToolCallStreamParser: Sendable {
    enum State: Sendable, Equatable {
        /// Looking for the opening marker (standalone use only; the output
        /// parser starts the block itself through `start()`).
        case search
        case structural
        case parameterValue
        case done
        case error
    }

    struct Argument: Sendable, Equatable {
        /// Parameter name (GLM keys are already trimmed and unescaped).
        let name: String
        /// Raw value text. Qwen values have one leading and one trailing
        /// newline removed; nothing is unescaped yet.
        let rawValue: String
        /// DSML `string="true"`. Always false for GLM and Qwen.
        let markedString: Bool
    }

    struct Call: Sendable, Equatable {
        let name: String
        let arguments: [Argument]
    }

    let syntax: DS4ToolSyntax
    private(set) var state: State = .search
    private(set) var errorDetail = ""
    private(set) var calls: [Call] = []
    /// A possible closing tag of the current value is being streamed
    /// (`param_close_prefix`), used to force greedy sampling.
    private(set) var parameterClosePrefix = false
    private(set) var raw: [UInt8] = []

    private var searchTail: [UInt8] = []
    private var parsePosition = 0
    private var currentName: String?
    private var currentArguments: [Argument] = []
    private var parameterName: String?
    private var parameterIsString = false
    private var parameterValueStart = 0
    private var lastValueLessThan: Int?
    private var afterCall = false

    private let startMarker: [UInt8]
    private let dsmlCallsName: [UInt8]
    private let dsmlInvokeName: [UInt8]
    private let dsmlParameterName: [UInt8]
    /// `</｜DSML｜parameter` (without `>`) in this syntax's spelling.
    private let dsmlParameterClosePrefix: [UInt8]
    private static let dsmlOpenPrefix = Array("<｜DSML｜".utf8)
    private static let dsmlClosePrefix = Array("</｜DSML｜".utf8)
    private static let dsmlBar = Array(DS4ToolSyntax.dsmlBar.utf8)
    private static let toolCallOpen = Array("<tool_call>".utf8)
    private static let toolCallClose = Array("</tool_call>".utf8)
    private static let argKeyOpen = Array("<arg_key>".utf8)
    private static let argKeyClose = Array("</arg_key>".utf8)
    private static let argValueOpen = Array("<arg_value>".utf8)
    private static let argValueClose = Array("</arg_value>".utf8)
    private static let functionOpen = Array("<function=".utf8)
    private static let functionClose = Array("</function>".utf8)
    private static let qwenParameterOpen = Array("<parameter=".utf8)
    private static let qwenParameterClose = Array("</parameter>".utf8)

    init(syntax: DS4ToolSyntax) {
        self.syntax = syntax
        self.startMarker = Array(syntax.toolCallOpenMarker.utf8)
        self.dsmlCallsName = Array(syntax.dsmlTagName(.toolCalls).utf8)
        self.dsmlInvokeName = Array(syntax.dsmlTagName(.invoke).utf8)
        self.dsmlParameterName = Array(syntax.dsmlTagName(.parameter).utf8)
        self.dsmlParameterClosePrefix = Array(syntax.dsmlCloseTag(.parameter).utf8.dropLast())
    }

    /// Name of the call being parsed, once known.
    var currentToolName: String? {
        currentName
    }

    /// Name of the parameter whose value is streaming.
    var currentParameterName: String? {
        state == .parameterValue ? parameterName : nil
    }

    /// `agent_dsml_start`: seeds the canonical opening marker.
    mutating func start() {
        state = .structural
        searchTail.removeAll()
        raw.append(contentsOf: startMarker)
        parsePosition = raw.count
    }

    mutating func feed(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            feed(byte: byte)
        }
    }

    /// `agent_dsml_feed` for one byte.
    mutating func feed(byte: UInt8) {
        switch state {
        case .done, .error:
            return
        case .search:
            if searchTail.count == 64 {
                searchTail.removeFirst()
            }
            searchTail.append(byte)
            if DS4Bytes.hasSuffix(searchTail, startMarker) {
                start()
            }
            return
        case .structural, .parameterValue:
            break
        }
        raw.append(byte)
        if state == .parameterValue, byte == DS4Bytes.lessThan {
            lastValueLessThan = raw.count - 1
        }
        parse()
        if state == .parameterValue {
            updateParameterClosePrefix()
        } else {
            parameterClosePrefix = false
        }
    }

    /// `agent_dsml_finish`: GLM/Qwen blocks end after the last `</tool_call>`
    /// once only whitespace follows.
    mutating func finish() {
        guard state != .done, state != .error, syntax.usesXMLToolCall, afterCall else {
            return
        }
        parsePosition = DS4Bytes.skipWhitespace(raw, from: parsePosition)
        if parsePosition >= raw.count {
            afterCall = false
            state = .done
        }
    }

    // MARK: - Shared

    private mutating func fail(_ detail: String) {
        state = .error
        errorDetail = detail
    }

    /// `agent_tool_calls_push`: a call without a name is dropped.
    private mutating func pushCurrent() {
        guard let name = currentName else {
            return
        }
        calls.append(Call(name: name, arguments: currentArguments))
        currentName = nil
        currentArguments.removeAll()
    }

    private mutating func resetCurrent() {
        currentName = nil
        currentArguments.removeAll()
    }

    private mutating func beginValue(name: String, isString: Bool, start: Int) {
        parameterName = name
        parameterIsString = isString
        parameterValueStart = start
        parsePosition = start
        parameterClosePrefix = false
        lastValueLessThan = nil
        state = .parameterValue
    }

    private mutating func endValue(rawValue: String, closeEnd: Int) {
        currentArguments.append(
            Argument(name: parameterName ?? "", rawValue: rawValue, markedString: parameterIsString)
        )
        parameterName = nil
        parameterClosePrefix = false
        lastValueLessThan = nil
        parsePosition = closeEnd
        state = .structural
    }

    private mutating func parse() {
        switch syntax {
        case .dsml, .dsml41:
            parseDSML()
        case .glm:
            parseGLM()
        case .qwen:
            parseQwen()
        }
    }

    // MARK: - Close-prefix tracking (agent_dsml_update_param_close_prefix)

    private mutating func updateParameterClosePrefix() {
        parameterClosePrefix = false
        guard state == .parameterValue, raw.count > parameterValueStart,
              let lessThan = lastValueLessThan, lessThan >= parameterValueStart,
              raw.count - lessThan <= 64 else {
            return
        }
        let (matches, complete) = valueCloseTail(Array(raw[lessThan...]))
        parameterClosePrefix = matches && !complete
    }

    /// `agent_tool_value_close_tail`.
    private func valueCloseTail(_ tail: [UInt8]) -> (matches: Bool, complete: Bool) {
        switch syntax {
        case .glm:
            return Self.literalCloseTail(tail, Self.argValueClose)
        case .qwen:
            return Self.literalCloseTail(tail, Self.qwenParameterClose)
        case .dsml, .dsml41:
            return dsmlParameterCloseTail(tail)
        }
    }

    private static func literalCloseTail(_ tail: [UInt8], _ close: [UInt8]) -> (matches: Bool, complete: Bool) {
        guard tail.count <= close.count, DS4Bytes.hasPrefix(close, at: 0, tail) else {
            return (false, false)
        }
        return (true, tail.count == close.count)
    }

    /// `agent_dsml_parameter_close_tail`: accepts whitespace and an optional
    /// trailing bar before `>`, like the close-tag matcher.
    private func dsmlParameterCloseTail(_ tail: [UInt8]) -> (matches: Bool, complete: Bool) {
        let prefix = dsmlParameterClosePrefix
        let bar = Self.dsmlBar
        let length = tail.count
        if length <= prefix.count {
            return (DS4Bytes.hasPrefix(prefix, at: 0, tail), false)
        }
        guard DS4Bytes.hasPrefix(tail, at: 0, prefix) else {
            return (false, false)
        }
        var index = prefix.count
        while index < length, DS4Bytes.isWhitespace(tail[index]) {
            index += 1
        }
        if index < length, length - index <= bar.count,
           DS4Bytes.hasPrefix(bar, at: 0, Array(tail[index...])) {
            return (true, false)
        }
        if DS4Bytes.hasPrefix(tail, at: index, bar) {
            index += bar.count
        }
        while index < length {
            if tail[index] == DS4Bytes.greaterThan {
                let complete = index == length - 1
                return (complete, complete)
            }
            if !DS4Bytes.isWhitespace(tail[index]) {
                return (false, false)
            }
            index += 1
        }
        return (true, false)
    }

    // MARK: - DSML (agent_dsml_parse)

    private mutating func parseDSML() {
        while state == .structural || state == .parameterValue {
            if state == .parameterValue {
                guard let closeStart = dsmlParameterCloseEndingAtTail() else {
                    return
                }
                endValue(
                    rawValue: DS4Bytes.string(raw[parameterValueStart..<closeStart]),
                    closeEnd: raw.count
                )
                continue
            }

            parsePosition = DS4Bytes.skipWhitespace(raw, from: parsePosition)
            guard parsePosition < raw.count else {
                return
            }
            if let length = dsmlCloseTagLength(at: parsePosition, name: dsmlCallsName) {
                pushCurrent()
                parsePosition += length
                state = .done
                return
            }
            if let length = dsmlCloseTagLength(at: parsePosition, name: dsmlInvokeName) {
                pushCurrent()
                parsePosition += length
                continue
            }
            guard let tagEnd = DS4Bytes.firstIndex(of: DS4Bytes.greaterThan, in: raw, from: parsePosition) else {
                return
            }
            let tag = Array(raw[parsePosition...tagEnd])
            if dsmlOpenTagIs(tag, name: dsmlInvokeName) {
                resetCurrent()
                guard let name = Self.attribute(tag, "name") else {
                    fail("tool invoke without name")
                    return
                }
                currentName = name
                parsePosition = tagEnd + 1
            } else if dsmlOpenTagIs(tag, name: dsmlParameterName) {
                guard let name = Self.attribute(tag, "name") else {
                    fail("tool parameter without name")
                    return
                }
                beginValue(name: name, isString: Self.attribute(tag, "string") == "true", start: tagEnd + 1)
            } else {
                fail("unexpected DSML tag: " + DS4Bytes.string(DS4Bytes.truncatedUTF8(tag, limit: 80)))
                return
            }
        }
    }

    /// `agent_dsml_open_tag_is`.
    private func dsmlOpenTagIs(_ tag: [UInt8], name: [UInt8]) -> Bool {
        let prefix = Self.dsmlOpenPrefix + name
        guard DS4Bytes.hasPrefix(tag, at: 0, prefix), tag.count > prefix.count else {
            return false
        }
        let next = tag[prefix.count]
        return next == DS4Bytes.greaterThan || DS4Bytes.isWhitespace(next)
    }

    /// `agent_dsml_close_tag_at`: `</｜DSML｜name`, optional whitespace, an
    /// optional bar, optional whitespace, `>`.
    private func dsmlCloseTagLength(at index: Int, name: [UInt8]) -> Int? {
        let prefix = Self.dsmlClosePrefix + name
        guard DS4Bytes.hasPrefix(raw, at: index, prefix) else {
            return nil
        }
        var cursor = DS4Bytes.skipWhitespace(raw, from: index + prefix.count)
        if DS4Bytes.hasPrefix(raw, at: cursor, Self.dsmlBar) {
            cursor += Self.dsmlBar.count
        }
        cursor = DS4Bytes.skipWhitespace(raw, from: cursor)
        guard cursor < raw.count, raw[cursor] == DS4Bytes.greaterThan else {
            return nil
        }
        return cursor - index + 1
    }

    /// Start of a parameter close tag that ends exactly at the last byte.
    ///
    /// ds4-agent searches the whole value with strstr after every byte; since
    /// the parser runs after every byte, the first close tag is always the one
    /// completed by the newest `>`, so only the tail needs to be inspected.
    private func dsmlParameterCloseEndingAtTail() -> Int? {
        guard let last = raw.last, last == DS4Bytes.greaterThan else {
            return nil
        }
        let lower = parameterValueStart
        var cursor = raw.count - 1
        while cursor > lower, DS4Bytes.isWhitespace(raw[cursor - 1]) {
            cursor -= 1
        }
        if cursor - Self.dsmlBar.count >= lower,
           DS4Bytes.hasPrefix(raw, at: cursor - Self.dsmlBar.count, Self.dsmlBar) {
            cursor -= Self.dsmlBar.count
        }
        while cursor > lower, DS4Bytes.isWhitespace(raw[cursor - 1]) {
            cursor -= 1
        }
        let prefix = dsmlParameterClosePrefix
        let start = cursor - prefix.count
        guard start >= lower, DS4Bytes.hasPrefix(raw, at: start, prefix) else {
            return nil
        }
        return start
    }

    /// `dsml_attr` (ds4_server.c): `name="value"`, XML-unescaped.
    private static func attribute(_ tag: [UInt8], _ name: String) -> String? {
        let pattern = Array((name + "=\"").utf8)
        guard let start = DS4Bytes.firstIndex(of: pattern, in: tag, from: 0) else {
            return nil
        }
        let valueStart = start + pattern.count
        guard let end = DS4Bytes.firstIndex(of: DS4Bytes.quote, in: tag, from: valueStart) else {
            return nil
        }
        return DS4ToolTextEscaping.unescapeAttribute(DS4Bytes.string(tag[valueStart..<end]))
    }

    // MARK: - GLM (agent_glm_tool_parse)

    private mutating func parseGLM() {
        guard DS4Bytes.hasPrefix(raw, at: 0, Self.toolCallOpen) else {
            return
        }
        while state == .structural || state == .parameterValue {
            if state == .parameterValue {
                let closeStart = raw.count - Self.argValueClose.count
                guard closeStart >= parameterValueStart, DS4Bytes.hasSuffix(raw, Self.argValueClose) else {
                    return
                }
                endValue(rawValue: DS4Bytes.string(raw[parameterValueStart..<closeStart]), closeEnd: raw.count)
                continue
            }

            parsePosition = DS4Bytes.skipWhitespace(raw, from: parsePosition)
            guard parsePosition < raw.count else {
                return
            }
            var cursor = parsePosition
            if afterCall {
                if DS4Bytes.hasPrefix(raw, at: cursor, Self.toolCallOpen) {
                    parsePosition += Self.toolCallOpen.count
                    afterCall = false
                    continue
                }
                if DS4Bytes.isPartialPrefix(raw, at: cursor, Self.toolCallOpen) {
                    return
                }
                afterCall = false
                state = .done
                return
            }

            if currentName == nil {
                let nameStart = DS4Bytes.skipWhitespace(raw, from: cursor)
                guard let lessThan = DS4Bytes.firstIndex(of: DS4Bytes.lessThan, in: raw, from: nameStart) else {
                    return
                }
                let atArgument = DS4Bytes.hasPrefix(raw, at: lessThan, Self.argKeyOpen)
                let atClose = DS4Bytes.hasPrefix(raw, at: lessThan, Self.toolCallClose)
                if !atArgument, !atClose {
                    if DS4Bytes.isPartialPrefix(raw, at: lessThan, Self.argKeyOpen)
                        || DS4Bytes.isPartialPrefix(raw, at: lessThan, Self.toolCallClose) {
                        return
                    }
                    fail("expected <arg_key> or </tool_call> in GLM tool call")
                    return
                }
                let name = DS4Bytes.trimmedRange(raw, nameStart..<lessThan)
                guard !name.isEmpty else {
                    fail("GLM tool call without function name")
                    return
                }
                resetCurrent()
                currentName = DS4Bytes.string(raw[name])
                parsePosition = lessThan
                cursor = lessThan
            }

            if DS4Bytes.hasPrefix(raw, at: cursor, Self.toolCallClose) {
                parsePosition += Self.toolCallClose.count
                pushCurrent()
                afterCall = true
                continue
            }
            if DS4Bytes.isPartialPrefix(raw, at: cursor, Self.toolCallClose) {
                return
            }
            guard DS4Bytes.hasPrefix(raw, at: cursor, Self.argKeyOpen) else {
                if DS4Bytes.isPartialPrefix(raw, at: cursor, Self.argKeyOpen) {
                    return
                }
                fail("expected <arg_key> in GLM tool call")
                return
            }
            cursor += Self.argKeyOpen.count
            guard let keyEnd = DS4Bytes.firstIndex(of: Self.argKeyClose, in: raw, from: cursor) else {
                return
            }
            let keyRange = DS4Bytes.trimmedRange(raw, cursor..<keyEnd)
            guard !keyRange.isEmpty else {
                fail("empty <arg_key> in GLM tool call")
                return
            }
            let key = DS4ToolTextEscaping.unescape(DS4Bytes.string(raw[keyRange]), closingTag: "</arg_key>")
            cursor = DS4Bytes.skipWhitespace(raw, from: keyEnd + Self.argKeyClose.count)
            guard DS4Bytes.hasPrefix(raw, at: cursor, Self.argValueOpen) else {
                if DS4Bytes.isPartialPrefix(raw, at: cursor, Self.argValueOpen) {
                    return
                }
                fail("expected <arg_value> in GLM tool call")
                return
            }
            beginValue(name: key, isString: false, start: cursor + Self.argValueOpen.count)
        }
    }

    // MARK: - Qwen (agent_qwen_tool_parse)

    private mutating func parseQwen() {
        guard DS4Bytes.hasPrefix(raw, at: 0, Self.toolCallOpen) else {
            return
        }
        while state == .structural || state == .parameterValue {
            if state == .parameterValue {
                // The value may contain literal tool/reasoning tags; only its
                // own delimiter ends it. An unfinished value is rejected at EOF.
                let closeStart = raw.count - Self.qwenParameterClose.count
                guard closeStart >= parameterValueStart, DS4Bytes.hasSuffix(raw, Self.qwenParameterClose) else {
                    return
                }
                var valueStart = parameterValueStart
                var valueEnd = closeStart
                if valueStart < valueEnd, raw[valueStart] == DS4Bytes.newline {
                    valueStart += 1
                }
                if valueEnd > valueStart, raw[valueEnd - 1] == DS4Bytes.newline {
                    valueEnd -= 1
                }
                endValue(rawValue: DS4Bytes.string(raw[valueStart..<valueEnd]), closeEnd: raw.count)
                continue
            }

            parsePosition = DS4Bytes.skipWhitespace(raw, from: parsePosition)
            guard parsePosition < raw.count else {
                return
            }
            let cursor = parsePosition
            if afterCall {
                if DS4Bytes.hasPrefix(raw, at: cursor, Self.toolCallOpen) {
                    parsePosition += Self.toolCallOpen.count
                    afterCall = false
                    continue
                }
                if DS4Bytes.isPartialPrefix(raw, at: cursor, Self.toolCallOpen) {
                    return
                }
                afterCall = false
                state = .done
                return
            }

            if currentName == nil {
                guard DS4Bytes.hasPrefix(raw, at: cursor, Self.functionOpen) else {
                    if DS4Bytes.isPartialPrefix(raw, at: cursor, Self.functionOpen) {
                        return
                    }
                    fail("expected <function=...> in Qwen tool call")
                    return
                }
                let nameStart = cursor + Self.functionOpen.count
                guard let greaterThan = DS4Bytes.firstIndex(of: DS4Bytes.greaterThan, in: raw, from: nameStart) else {
                    return
                }
                let name = DS4Bytes.trimmedRange(raw, nameStart..<greaterThan)
                guard !name.isEmpty else {
                    fail("Qwen tool call without function name")
                    return
                }
                resetCurrent()
                currentName = DS4Bytes.string(raw[name])
                parsePosition = greaterThan + 1
                continue
            }

            if DS4Bytes.hasPrefix(raw, at: cursor, Self.functionClose) {
                let after = DS4Bytes.skipWhitespace(raw, from: cursor + Self.functionClose.count)
                if after >= raw.count || DS4Bytes.isPartialPrefix(raw, at: after, Self.toolCallClose) {
                    return
                }
                guard DS4Bytes.hasPrefix(raw, at: after, Self.toolCallClose) else {
                    fail("expected </tool_call> after </function>")
                    return
                }
                parsePosition = after + Self.toolCallClose.count
                pushCurrent()
                afterCall = true
                continue
            }
            if DS4Bytes.isPartialPrefix(raw, at: cursor, Self.functionClose) {
                return
            }
            guard DS4Bytes.hasPrefix(raw, at: cursor, Self.qwenParameterOpen) else {
                if DS4Bytes.isPartialPrefix(raw, at: cursor, Self.qwenParameterOpen) {
                    return
                }
                fail("expected <parameter=...> or </function> in Qwen tool call")
                return
            }
            let keyStart = cursor + Self.qwenParameterOpen.count
            guard let greaterThan = DS4Bytes.firstIndex(of: DS4Bytes.greaterThan, in: raw, from: keyStart) else {
                return
            }
            let key = DS4Bytes.trimmedRange(raw, keyStart..<greaterThan)
            guard !key.isEmpty else {
                fail("empty <parameter=> name in Qwen tool call")
                return
            }
            beginValue(name: DS4Bytes.string(raw[key]), isString: false, start: greaterThan + 1)
        }
    }
}
