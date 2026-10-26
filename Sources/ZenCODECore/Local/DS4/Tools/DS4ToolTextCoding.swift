//
//  DS4ToolTextCoding.swift
//  ZenCODE
//
//  Byte-level helpers shared by the DS4 tool-call parser, renderer and prompt
//  builder: the closing-delimiter escape of ds4_tool_text.h, XML attribute
//  escaping, and order-preserving JSON helpers.
//

import Foundation
import ToolCore

enum DS4Bytes {
    static let lessThan = UInt8(ascii: "<")
    static let greaterThan = UInt8(ascii: ">")
    static let quote = UInt8(ascii: "\"")
    static let ampersand = UInt8(ascii: "&")
    static let newline = UInt8(ascii: "\n")

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }

    static func hasPrefix(_ bytes: [UInt8], at index: Int, _ prefix: [UInt8]) -> Bool {
        guard index >= 0, bytes.count - index >= prefix.count else {
            return false
        }
        var offset = 0
        while offset < prefix.count {
            if bytes[index + offset] != prefix[offset] {
                return false
            }
            offset += 1
        }
        return true
    }

    /// The bytes from `index` to the end are a proper prefix of `prefix`
    /// (`bytes_is_partial_prefix`). An empty remainder counts as partial.
    static func isPartialPrefix(_ bytes: [UInt8], at index: Int, _ prefix: [UInt8]) -> Bool {
        let remaining = bytes.count - index
        guard remaining >= 0, remaining < prefix.count else {
            return false
        }
        var offset = 0
        while offset < remaining {
            if bytes[index + offset] != prefix[offset] {
                return false
            }
            offset += 1
        }
        return true
    }

    static func hasSuffix(_ bytes: [UInt8], _ suffix: [UInt8]) -> Bool {
        hasPrefix(bytes, at: bytes.count - suffix.count, suffix)
    }

    /// Whether the last `length` bytes of `bytes` are a proper prefix of
    /// `marker`, i.e. a marker that may still be completed by later bytes.
    static func suffix(of bytes: [UInt8], length: Int, isProperPrefixOf marker: [UInt8]) -> Bool {
        guard length > 0, length < marker.count, length <= bytes.count else {
            return false
        }
        let start = bytes.count - length
        var offset = 0
        while offset < length {
            if bytes[start + offset] != marker[offset] {
                return false
            }
            offset += 1
        }
        return true
    }

    /// Length of the longest suffix of `bytes` that is a proper prefix of one
    /// of `markers` (0 when none).
    static func longestSuffixStartingAny(_ bytes: [UInt8], markers: [[UInt8]]) -> Int {
        let longest = markers.map(\.count).max() ?? 0
        var length = min(bytes.count, max(longest - 1, 0))
        while length > 0 {
            for marker in markers where suffix(of: bytes, length: length, isProperPrefixOf: marker) {
                return length
            }
            length -= 1
        }
        return 0
    }

    static func firstIndex(of needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count else {
            return nil
        }
        var index = max(start, 0)
        let last = bytes.count - needle.count
        while index <= last {
            if bytes[index] == needle[0], hasPrefix(bytes, at: index, needle) {
                return index
            }
            index += 1
        }
        return nil
    }

    static func firstIndex(of byte: UInt8, in bytes: [UInt8], from start: Int) -> Int? {
        var index = max(start, 0)
        while index < bytes.count {
            if bytes[index] == byte {
                return index
            }
            index += 1
        }
        return nil
    }

    static func skipWhitespace(_ bytes: [UInt8], from start: Int, to end: Int? = nil) -> Int {
        let limit = end ?? bytes.count
        var index = start
        while index < limit, isWhitespace(bytes[index]) {
            index += 1
        }
        return index
    }

    /// `agent_trim_span`.
    static func trimmedRange(_ bytes: [UInt8], _ range: Range<Int>) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, isWhitespace(bytes[lower]) {
            lower += 1
        }
        while upper > lower, isWhitespace(bytes[upper - 1]) {
            upper -= 1
        }
        return lower..<upper
    }

    static func string(_ bytes: some Collection<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Length of the longest prefix of `bytes` that ends on a complete UTF-8
    /// scalar. Only a trailing incomplete sequence (at most three bytes) is
    /// excluded; invalid bytes elsewhere are left to the lossy decoder.
    static func completeUTF8PrefixLength(_ bytes: [UInt8]) -> Int {
        let count = bytes.count
        var back = 1
        while back <= min(3, count) {
            let byte = bytes[count - back]
            if byte & 0xC0 != 0x80 {
                let needed: Int
                if byte & 0x80 == 0 {
                    needed = 1
                } else if byte & 0xE0 == 0xC0 {
                    needed = 2
                } else if byte & 0xF0 == 0xE0 {
                    needed = 3
                } else if byte & 0xF8 == 0xF0 {
                    needed = 4
                } else {
                    return count
                }
                return needed > back ? count - back : count
            }
            back += 1
        }
        return count
    }

    /// Truncates to at most `limit` bytes without splitting a UTF-8 scalar.
    static func truncatedUTF8(_ bytes: [UInt8], limit: Int) -> [UInt8] {
        guard bytes.count > limit else {
            return bytes
        }
        let prefix = Array(bytes.prefix(limit))
        return Array(prefix.prefix(completeUTF8PrefixLength(prefix)))
    }
}

/// Tool bodies are not HTML: only their own closing delimiter, and spellings
/// that would collide with its escape, are escaped (ds4_tool_text.h).
enum DS4ToolTextEscaping {
    private static let ampEntity = Array("amp;".utf8)
    private static let ltEntity = Array("lt;".utf8)

    /// `ds4_tool_text_escaped_close`: `&` + `amp;`* + `lt;` + closing tag
    /// without its leading `<`.
    static func isEscapedClose(_ bytes: [UInt8], at index: Int, closingTag: [UInt8]) -> Bool {
        guard index < bytes.count, bytes[index] == DS4Bytes.ampersand else {
            return false
        }
        var cursor = index + 1
        while DS4Bytes.hasPrefix(bytes, at: cursor, ampEntity) {
            cursor += ampEntity.count
        }
        guard DS4Bytes.hasPrefix(bytes, at: cursor, ltEntity) else {
            return false
        }
        return DS4Bytes.hasPrefix(bytes, at: cursor + ltEntity.count, Array(closingTag.dropFirst()))
    }

    /// `ds4_tool_text_needs_escape` applied to a whole value: a literal closing
    /// tag gets its `<` written as `&lt;`, an already-escaped spelling gets its
    /// `&` written as `&amp;`.
    static func escape(_ text: String, closingTag: String) -> String {
        let bytes = Array(text.utf8)
        let tag = Array(closingTag.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if DS4Bytes.hasPrefix(bytes, at: index, tag) {
                output.append(contentsOf: Array("&lt;".utf8))
            } else if isEscapedClose(bytes, at: index, closingTag: tag) {
                output.append(contentsOf: Array("&amp;".utf8))
            } else {
                output.append(bytes[index])
            }
            index += 1
        }
        return DS4Bytes.string(output)
    }

    /// `ds4_tool_text_unescape`.
    static func unescape(_ text: String, closingTag: String) -> String {
        let bytes = Array(text.utf8)
        let tag = Array(closingTag.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if isEscapedClose(bytes, at: index, closingTag: tag) {
                if DS4Bytes.hasPrefix(bytes, at: index, Array("&amp;".utf8)) {
                    output.append(DS4Bytes.ampersand)
                    index += 5
                } else {
                    output.append(DS4Bytes.lessThan)
                    index += 4
                }
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return DS4Bytes.string(output)
    }

    /// `append_dsml_attr_escaped` (ds4_server.c).
    static func escapeAttribute(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&":
                output += "&amp;"
            case "<":
                output += "&lt;"
            case ">":
                output += "&gt;"
            case "\"":
                output += "&quot;"
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    /// `dsml_unescape_text` (ds4_server.c): attributes are XML-escaped.
    static func unescapeAttribute(_ text: String) -> String {
        guard text.contains("&") else {
            return text
        }
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
        ]
        var output = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            output += rest[..<ampersand]
            rest = rest[ampersand...]
            if let entity = entities.first(where: { rest.hasPrefix($0.0) }) {
                output += entity.1
                rest = rest.dropFirst(entity.0.count)
            } else {
                output += "&"
                rest = rest.dropFirst()
            }
        }
        output += rest
        return output
    }
}

/// Order-preserving JSON helpers. Foundation dictionaries lose key order, but
/// the replayed tool markup and the tools prompt must stay byte-stable.
enum DS4JSONText {
    struct Member: Sendable, Equatable {
        let key: String
        let value: JSONValue
        /// The member value as minified JSON text, in its original key order.
        let minifiedJSON: String
    }

    /// Decodes one complete JSON value (fragments allowed), ignoring
    /// surrounding whitespace.
    static func decodeValue(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
    }

    /// A JSON string literal for `text`.
    static func quoted(_ text: String) -> String {
        JSONValue.string(text).compactString()
    }

    /// Removes insignificant whitespace while preserving key order and the
    /// exact spelling of strings and numbers. Does not validate.
    static func minify(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var inString = false
        var escaped = false
        for byte in bytes {
            if inString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == DS4Bytes.quote {
                    inString = false
                }
                continue
            }
            if DS4Bytes.isWhitespace(byte) {
                continue
            }
            if byte == DS4Bytes.quote {
                inString = true
            }
            output.append(byte)
        }
        return DS4Bytes.string(output)
    }

    /// Minified text of a JSON object, or `nil` when `text` is not one.
    static func minifiedObject(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            return nil
        }
        return minify(text)
    }

    /// The members of a top-level JSON object in source order, or `nil` when
    /// `json` is not a valid object.
    static func orderedMembers(_ json: String) -> [Member]? {
        let bytes = Array(json.utf8)
        var index = DS4Bytes.skipWhitespace(bytes, from: 0)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else {
            return nil
        }
        index += 1
        var members: [Member] = []
        index = DS4Bytes.skipWhitespace(bytes, from: index)
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return DS4Bytes.skipWhitespace(bytes, from: index) == bytes.count ? [] : nil
        }
        while index < bytes.count {
            guard bytes[index] == DS4Bytes.quote,
                  let keyEnd = endOfValue(bytes, from: index),
                  let key = try? JSONDecoder().decode(String.self, from: Data(bytes[index..<keyEnd])) else {
                return nil
            }
            index = DS4Bytes.skipWhitespace(bytes, from: keyEnd)
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                return nil
            }
            index = DS4Bytes.skipWhitespace(bytes, from: index + 1)
            guard let valueEnd = endOfValue(bytes, from: index) else {
                return nil
            }
            let rawValue = DS4Bytes.string(bytes[index..<valueEnd])
            guard let value = decodeValue(rawValue) else {
                return nil
            }
            members.append(Member(key: key, value: value, minifiedJSON: minify(rawValue)))
            index = DS4Bytes.skipWhitespace(bytes, from: valueEnd)
            guard index < bytes.count else {
                return nil
            }
            if bytes[index] == UInt8(ascii: ",") {
                index = DS4Bytes.skipWhitespace(bytes, from: index + 1)
                continue
            }
            guard bytes[index] == UInt8(ascii: "}") else {
                return nil
            }
            return DS4Bytes.skipWhitespace(bytes, from: index + 1) == bytes.count ? members : nil
        }
        return nil
    }

    /// Compact JSON object text with members in the given order.
    static func object(_ members: [(key: String, value: JSONValue)]) -> String {
        "{" + members.map { quoted($0.key) + ":" + $0.value.compactString(sortedKeys: true) }
            .joined(separator: ",") + "}"
    }

    /// End offset (exclusive) of the JSON value starting at `start`. Only the
    /// extent is scanned; the value is validated by the decoder afterwards.
    private static func endOfValue(_ bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else {
            return nil
        }
        let first = bytes[start]
        if first == DS4Bytes.quote {
            var index = start + 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == DS4Bytes.quote {
                    return index + 1
                }
                index += 1
            }
            return nil
        }
        if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            var depth = 0
            var index = start
            var inString = false
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == UInt8(ascii: "\\") {
                        escaped = true
                    } else if byte == DS4Bytes.quote {
                        inString = false
                    }
                } else if byte == DS4Bytes.quote {
                    inString = true
                } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                    depth += 1
                } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 {
                        return index + 1
                    }
                }
                index += 1
            }
            return nil
        }
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]")
                || DS4Bytes.isWhitespace(byte) {
                break
            }
            index += 1
        }
        return index > start ? index : nil
    }
}
