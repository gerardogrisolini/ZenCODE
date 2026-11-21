//
//  DS4ToolCallStreamParser+LivePreview.swift
//  ZenCODE
//
//  Close-prefix tracking of the open parameter value and the live tool-call
//  preview of DS4ToolCallStreamParser, with the incremental closing-tag
//  matcher.
//

import Foundation

extension DS4ToolCallStreamParser {
    // MARK: - Close-prefix tracking (agent_dsml_update_param_close_prefix)

    mutating func updateParameterClosePrefix() {
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

    // MARK: - Live preview

    /// Live-preview fragments recorded since the last call, in stream order.
    /// Released value bytes become a `parameterText` cut at a UTF-8 scalar
    /// boundary. `blockEnded`: the block is complete, malformed or cut short
    /// and will not be fed again, so the bytes still held are dropped.
    mutating func drainPreviews(blockEnded: Bool) -> [DirectAgentToolCallPreview] {
        flushPreviewBytes(keepingIncompleteScalar: true)
        if blockEnded {
            previewBytes.removeAll()
            previewCloseStart = nil
        }
        defer { previews.removeAll() }
        return previews
    }

    /// Releases the open value's bytes that can no longer belong to its
    /// closing tag (`agent_tool_viz_param_value_byte`). Each byte is examined
    /// once: a closing tag holds a single `<`, so at most one candidate is
    /// open, and it is advanced by the new byte only.
    mutating func advancePreview() {
        while previewScanned < raw.count {
            let index = previewScanned
            let byte = raw[index]
            previewScanned += 1
            if syntax == .qwen, index == parameterValueStart, byte == DS4Bytes.newline {
                // The newline after `<parameter=…>` is not part of the value.
                previewReleased = index + 1
                continue
            }
            if previewCloseStart != nil, !previewCloseMatcher.advance(byte) {
                previewCloseStart = nil
            }
            if previewCloseStart == nil, byte == DS4Bytes.lessThan {
                previewCloseStart = index
                previewCloseMatcher.reset()
            }
        }
        var end = previewCloseStart ?? raw.count
        if syntax == .qwen, end > previewReleased, raw[end - 1] == DS4Bytes.newline {
            // It may be the newline removed before `</parameter>`.
            end -= 1
        }
        if end > previewReleased {
            previewBytes.append(contentsOf: raw[previewReleased..<end])
            previewReleased = end
        }
    }

    mutating func flushPreviewBytes(keepingIncompleteScalar: Bool) {
        let length = keepingIncompleteScalar
            ? DS4Bytes.completeUTF8PrefixLength(previewBytes)
            : previewBytes.count
        guard length > 0 else {
            return
        }
        previews.append(.parameterText(DS4Bytes.string(previewBytes[..<length])))
        previewBytes.removeFirst(length)
    }

    /// Incremental form of `valueCloseTail` after a `<`: the literal closing
    /// tag (GLM, Qwen) or the DSML prefix, optional whitespace, an optional
    /// bar, optional whitespace and `>`, matched one byte at a time.
    struct CloseTagMatcher: Sendable {
        private enum Phase: Sendable {
            case prefix(Int)
            case beforeBar
            case bar(Int)
            case afterBar
            /// `>` ended the tag: the parser closes the value on that byte.
            case closed
        }

        private let prefix: [UInt8]
        private let tolerant: Bool
        private var phase: Phase = .prefix(1)

        init(syntax: DS4ToolSyntax) {
            switch syntax {
            case .glm:
                prefix = DS4ToolCallStreamParser.argValueClose
                tolerant = false
            case .qwen:
                prefix = DS4ToolCallStreamParser.qwenParameterClose
                tolerant = false
            case .dsml, .dsml41:
                prefix = Array(syntax.dsmlCloseTag(.parameter).utf8.dropLast())
                tolerant = true
            }
        }

        /// Starts over after a `<`.
        mutating func reset() {
            phase = .prefix(1)
        }

        /// Whether `byte` keeps the bytes since the `<` a possible closing tag.
        mutating func advance(_ byte: UInt8) -> Bool {
            let bar = DS4ToolCallStreamParser.dsmlBar
            switch phase {
            case let .prefix(matched):
                guard matched < prefix.count, byte == prefix[matched] else {
                    return false
                }
                phase = matched + 1 == prefix.count && tolerant ? .beforeBar : .prefix(matched + 1)
                return true
            case .beforeBar:
                if byte == DS4Bytes.greaterThan {
                    phase = .closed
                    return true
                }
                if DS4Bytes.isWhitespace(byte) {
                    return true
                }
                guard byte == bar[0] else {
                    return false
                }
                phase = bar.count == 1 ? .afterBar : .bar(1)
                return true
            case let .bar(matched):
                guard byte == bar[matched] else {
                    return false
                }
                phase = matched + 1 == bar.count ? .afterBar : .bar(matched + 1)
                return true
            case .afterBar:
                if byte == DS4Bytes.greaterThan {
                    phase = .closed
                    return true
                }
                return DS4Bytes.isWhitespace(byte)
            case .closed:
                return false
            }
        }
    }
}
