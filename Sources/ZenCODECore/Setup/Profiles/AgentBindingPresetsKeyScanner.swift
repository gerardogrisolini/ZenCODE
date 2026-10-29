//
//  AgentBindingPresetsKeyScanner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 29/10/26.
//
//  Reads the key order of a JSON object, which Foundation decoders discard.
//

import Foundation

/// Returns the keys of a JSON object in the order they appear in the file.
///
/// `JSONDecoder` and `JSONSerialization` both build dictionaries, so the order in
/// which an operator wrote the keys is lost. Binding presets use that order as
/// the provider priority, so this scanner walks the raw bytes instead. It only
/// locates and tokenizes keys: values are skipped without being interpreted, and
/// the file is expected to be validated by a real JSON decoder first.
enum AgentBindingPresetsKeyScanner {
    /// Deepest value nesting the scanner follows before giving up. It matches
    /// the depth `JSONDecoder` accepts, so a file the decoder validated never
    /// reaches the limit.
    private static let maximumDepth = 512

    /// Keys of the object stored under `name` in the top-level object, in file
    /// order. A repeated key counts at its first occurrence. Returns `nil` when
    /// the data is not an object, has no such member, the member is not an
    /// object, or the data is malformed.
    static func keys(ofMember name: String, in data: Data) -> [String]? {
        var cursor = Cursor(bytes: [UInt8](data))
        return cursor.keys(ofMember: name)
    }

    private struct Cursor {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func keys(ofMember name: String) -> [String]? {
            skipByteOrderMark()
            skipWhitespace()
            guard consume(UInt8(ascii: "{")) else { return nil }

            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return nil }
            while true {
                skipWhitespace()
                guard let key = readString() else { return nil }
                skipWhitespace()
                guard consume(UInt8(ascii: ":")) else { return nil }
                skipWhitespace()
                if key == name {
                    return readObjectKeys()
                }
                guard skipValue(depth: 1) else { return nil }
                skipWhitespace()
                if consume(UInt8(ascii: ",")) { continue }
                return nil
            }
        }

        /// Keys of the object at the cursor, positioned on its `{`.
        private mutating func readObjectKeys() -> [String]? {
            guard consume(UInt8(ascii: "{")) else { return nil }
            var keys: [String] = []
            var seen = Set<String>()

            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return keys }
            while true {
                skipWhitespace()
                guard let key = readString() else { return nil }
                if seen.insert(key).inserted {
                    keys.append(key)
                }
                skipWhitespace()
                guard consume(UInt8(ascii: ":")) else { return nil }
                skipWhitespace()
                guard skipValue(depth: 2) else { return nil }
                skipWhitespace()
                if consume(UInt8(ascii: ",")) { continue }
                guard consume(UInt8(ascii: "}")) else { return nil }
                return keys
            }
        }

        // MARK: - Values

        private mutating func skipValue(depth: Int) -> Bool {
            guard depth <= AgentBindingPresetsKeyScanner.maximumDepth,
                  index < bytes.count else {
                return false
            }
            switch bytes[index] {
            case UInt8(ascii: "\""):
                return readToken() != nil
            case UInt8(ascii: "{"):
                return skipContainer(
                    open: UInt8(ascii: "{"),
                    close: UInt8(ascii: "}"),
                    isObject: true,
                    depth: depth
                )
            case UInt8(ascii: "["):
                return skipContainer(
                    open: UInt8(ascii: "["),
                    close: UInt8(ascii: "]"),
                    isObject: false,
                    depth: depth
                )
            default:
                return skipLiteral()
            }
        }

        private mutating func skipContainer(
            open: UInt8,
            close: UInt8,
            isObject: Bool,
            depth: Int
        ) -> Bool {
            guard consume(open) else { return false }
            skipWhitespace()
            if consume(close) { return true }
            while true {
                skipWhitespace()
                if isObject {
                    guard readToken() != nil else { return false }
                    skipWhitespace()
                    guard consume(UInt8(ascii: ":")) else { return false }
                    skipWhitespace()
                }
                guard skipValue(depth: depth + 1) else { return false }
                skipWhitespace()
                if consume(UInt8(ascii: ",")) { continue }
                return consume(close)
            }
        }

        /// Numbers, `true`, `false` and `null`: everything up to a delimiter.
        private mutating func skipLiteral() -> Bool {
            let start = index
            while index < bytes.count, !Self.isLiteralTerminator(bytes[index]) {
                index += 1
            }
            return index > start
        }

        // MARK: - Strings

        /// The decoded string at the cursor, positioned on its opening quote.
        private mutating func readString() -> String? {
            guard let token = readToken() else { return nil }
            // JSONSerialization decodes every escape, including surrogate pairs,
            // exactly like the decoder that validated the file.
            guard let value = try? JSONSerialization.jsonObject(
                with: Data(token),
                options: [.fragmentsAllowed]
            ) as? String else {
                return nil
            }
            return value
        }

        /// The raw bytes of the string at the cursor, quotes included.
        private mutating func readToken() -> ArraySlice<UInt8>? {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                return nil
            }
            let start = index
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"):
                    // The escaped byte can be a quote; never close on it.
                    index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    return bytes[start..<index]
                default:
                    index += 1
                }
            }
            return nil
        }

        // MARK: - Cursor

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while index < bytes.count, Self.isWhitespace(bytes[index]) {
                index += 1
            }
        }

        private mutating func skipByteOrderMark() {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
                index = 3
            }
        }

        private static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: " ")
                || byte == UInt8(ascii: "\t")
                || byte == UInt8(ascii: "\n")
                || byte == UInt8(ascii: "\r")
        }

        private static func isLiteralTerminator(_ byte: UInt8) -> Bool {
            isWhitespace(byte)
                || byte == UInt8(ascii: ",")
                || byte == UInt8(ascii: "}")
                || byte == UInt8(ascii: "]")
        }
    }
}
