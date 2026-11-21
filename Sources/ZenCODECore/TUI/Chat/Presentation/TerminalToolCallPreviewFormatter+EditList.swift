//
//  TerminalToolCallPreviewFormatter+EditList.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 15/11/26.
//

import Foundation

extension TerminalToolCallPreviewFormatter {
    /// Reads the `edits` argument of `local.multiEdit` while it streams: a JSON
    /// array of objects whose `old` and `new` strings are the source text to
    /// draw. Everything else in the JSON (punctuation, other keys, numbers,
    /// booleans, `null`, nested objects and arrays, and the strings of other
    /// keys) is skipped.
    ///
    /// A pure value that takes one scalar at a time, at a constant cost, and
    /// returns the decoded scalars of the strings it draws, so the result does
    /// not depend on how the argument was split into fragments, even in the
    /// middle of an escape, of a key, or of a surrogate pair. Only the keys
    /// `old` and `new` of the objects that stand directly in the array are
    /// drawn; the structure is checked only as far as needed to find them, and
    /// the contents of a skipped nested value are not validated. Whatever is
    /// not JSON of that shape (the first scalar that is not whitespace is not
    /// `[`, an element that is not an object, or a scalar where punctuation is
    /// expected) ends the reading for good: nothing else is drawn, and nothing
    /// that was already drawn is taken back.
    ///
    /// Inside a string a raw scalar, a line break included, is taken as it is.
    /// A lone surrogate and an invalid escape decode to U+FFFD; the scalar
    /// that interrupts a `\u` escape goes on as ordinary text of the string.
    struct EditListDecoder: Sendable {
        /// What the argument has drawn so far.
        enum Event: Sendable, Equatable {
            /// One decoded scalar of an `old` (`.removal`) or `new`
            /// (`.addition`) string.
            case scalar(Unicode.Scalar, CodeMarker)
            /// The closing quote of such a string.
            case stringEnded(CodeMarker)
        }

        /// The events one scalar produced, in order. A scalar produces at most
        /// three: the replacement of a surrogate it leaves lone, the
        /// replacement of the escape it ends, and itself as text.
        struct Events: Sequence, IteratorProtocol, Sendable {
            private var first: Event?
            private var second: Event?
            private var third: Event?

            fileprivate mutating func append(_ event: Event) {
                if first == nil {
                    first = event
                } else if second == nil {
                    second = event
                } else {
                    assert(third == nil, "one scalar produces at most three events")
                    third = event
                }
            }

            mutating func next() -> Event? {
                defer {
                    first = second
                    second = third
                    third = nil
                }
                return first
            }
        }

        private enum Phase: Sendable, Equatable {
            /// Before the `[` of the array.
            case beforeArray
            /// After `[` or a comma of the array: an object or the end.
            case beforeElement
            /// After an object of the array: a comma or the end.
            case afterElement
            /// After `{` or a comma of an object: a key or the end.
            case beforeKey
            case inKey
            case afterKey
            case beforeValue
            /// Inside the string of a value: drawn when its key is `old` or
            /// `new`, skipped otherwise.
            case inString
            /// Inside a number, `true`, `false`, or `null`.
            case inLiteral
            /// Inside a nested object or array, skipped with its depth.
            case inNested
            case afterValue
            /// After the `]` of the array.
            case finished
            case malformed
        }

        private enum Escape: Sendable, Equatable {
            case idle
            /// After a backslash.
            case backslash
            /// Inside `\uXXXX`, with the hexadecimal digits read so far.
            case unicode(digits: Int, value: UInt32)
        }

        private static let replacement: Unicode.Scalar = "\u{FFFD}"
        private static let removalKey: [Unicode.Scalar] = ["o", "l", "d"]
        private static let additionKey: [Unicode.Scalar] = ["n", "e", "w"]

        private var phase = Phase.beforeArray
        private var escape = Escape.idle
        /// A high surrogate of a `\u` escape that waits for its low one.
        private var pendingHighSurrogate: UInt32?
        /// The decoded scalars read of the current key, and whether they are
        /// still the start of `old` or of `new`.
        private var keyLength = 0
        private var keyMayBeRemoval = true
        private var keyMayBeAddition = true
        /// The marker of the value that follows the last key: `nil` for a key
        /// that is neither `old` nor `new`.
        private var valueMarker: CodeMarker?
        private var depth = 0
        private var nestedStringIsOpen = false

        /// The marker of the `old` or `new` string that is open at this point:
        /// the scalars read next belong to it.
        var openMarker: CodeMarker? {
            phase == .inString ? valueMarker : nil
        }

        /// Consumes one scalar of the argument.
        mutating func consume(_ scalar: Unicode.Scalar) -> Events {
            var events = Events()
            switch phase {
            case .beforeArray:
                if scalar == "[" {
                    phase = .beforeElement
                } else {
                    rejectUnlessWhitespace(scalar)
                }
            case .beforeElement:
                switch scalar {
                case "{": phase = .beforeKey
                case "]": phase = .finished
                default: rejectUnlessWhitespace(scalar)
                }
            case .afterElement:
                switch scalar {
                case ",": phase = .beforeElement
                case "]": phase = .finished
                default: rejectUnlessWhitespace(scalar)
                }
            case .beforeKey:
                switch scalar {
                case "\"": beginKey()
                case "}": phase = .afterElement
                default: rejectUnlessWhitespace(scalar)
                }
            case .inKey:
                decodeString(scalar, into: &events)
            case .afterKey:
                if scalar == ":" {
                    phase = .beforeValue
                } else {
                    rejectUnlessWhitespace(scalar)
                }
            case .beforeValue:
                beginValue(scalar)
            case .inString:
                if valueMarker != nil {
                    decodeString(scalar, into: &events)
                } else if skipString(scalar) {
                    phase = .afterValue
                }
            case .inLiteral:
                if Self.isLiteralScalar(scalar) {
                    break
                }
                // The scalar that ends the literal is punctuation of the object.
                phase = .afterValue
                return consume(scalar)
            case .inNested:
                skipNested(scalar)
            case .afterValue:
                switch scalar {
                case ",": phase = .beforeKey
                case "}": phase = .afterElement
                default: rejectUnlessWhitespace(scalar)
                }
            case .finished:
                rejectUnlessWhitespace(scalar)
            case .malformed:
                break
            }
            return events
        }

        // MARK: - Structure

        private mutating func rejectUnlessWhitespace(_ scalar: Unicode.Scalar) {
            if !scalar.properties.isWhitespace {
                phase = .malformed
            }
        }

        private mutating func beginKey() {
            phase = .inKey
            escape = .idle
            pendingHighSurrogate = nil
            keyLength = 0
            keyMayBeRemoval = true
            keyMayBeAddition = true
            valueMarker = nil
        }

        private mutating func beginValue(_ scalar: Unicode.Scalar) {
            switch scalar {
            case "\"":
                phase = .inString
                escape = .idle
                pendingHighSurrogate = nil
            case "{", "[":
                phase = .inNested
                depth = 1
                nestedStringIsOpen = false
            case "-", "0"..."9", "t", "f", "n":
                phase = .inLiteral
            default:
                rejectUnlessWhitespace(scalar)
            }
        }

        private static func isLiteralScalar(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar {
            case "0"..."9", "a"..."z", "A"..."Z", "+", "-", ".": true
            default: false
            }
        }

        // MARK: - Skipped values

        /// Skips one scalar of a string that is not drawn; `true` when the
        /// scalar is its closing quote. Whatever follows a backslash belongs
        /// to the string.
        private mutating func skipString(_ scalar: Unicode.Scalar) -> Bool {
            if escape == .backslash {
                escape = .idle
                return false
            }
            if scalar == "\\" {
                escape = .backslash
                return false
            }
            return scalar == "\""
        }

        /// Skips one scalar of a nested object or array, whose strings may
        /// hold brackets and quotes.
        private mutating func skipNested(_ scalar: Unicode.Scalar) {
            if nestedStringIsOpen {
                if skipString(scalar) {
                    nestedStringIsOpen = false
                }
                return
            }
            switch scalar {
            case "\"":
                nestedStringIsOpen = true
                escape = .idle
            case "{", "[":
                depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 {
                    phase = .afterValue
                }
            default:
                break
            }
        }

        // MARK: - Decoded strings

        /// Decodes one scalar of the current key or of the string of an `old`
        /// or `new` value.
        private mutating func decodeString(_ scalar: Unicode.Scalar, into events: inout Events) {
            switch escape {
            case .idle:
                if scalar == "\\" {
                    // A pending high surrogate may still be completed.
                    escape = .backslash
                    return
                }
                flushPendingHighSurrogate(into: &events)
                if scalar == "\"" {
                    endString(into: &events)
                } else {
                    emit(scalar, into: &events)
                }
            case .backslash:
                escape = .idle
                if scalar == "u" {
                    escape = .unicode(digits: 0, value: 0)
                    return
                }
                flushPendingHighSurrogate(into: &events)
                emit(Self.simpleEscape(scalar) ?? Self.replacement, into: &events)
            case let .unicode(digits, value):
                guard let digit = Self.hexadecimalValue(scalar) else {
                    // Not an escape: the scalar goes on as text of the string.
                    escape = .idle
                    flushPendingHighSurrogate(into: &events)
                    emit(Self.replacement, into: &events)
                    decodeString(scalar, into: &events)
                    return
                }
                let value = value << 4 | digit
                if digits < 3 {
                    escape = .unicode(digits: digits + 1, value: value)
                } else {
                    escape = .idle
                    emitEscapedUnit(value, into: &events)
                }
            }
        }

        /// The scalar a one-character escape stands for, or `nil` when the
        /// character after the backslash starts no valid escape.
        private static func simpleEscape(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
            switch scalar {
            case "\"", "\\", "/": scalar
            case "b": "\u{08}"
            case "f": "\u{0C}"
            case "n": "\n"
            case "r": "\r"
            case "t": "\t"
            default: nil
            }
        }

        private static func hexadecimalValue(_ scalar: Unicode.Scalar) -> UInt32? {
            switch scalar.value {
            case 0x30...0x39: scalar.value - 0x30
            case 0x41...0x46: scalar.value - 0x41 + 10
            case 0x61...0x66: scalar.value - 0x61 + 10
            default: nil
            }
        }

        /// A UTF-16 unit read from a `\uXXXX` escape: a high surrogate waits
        /// for the low one, which completes the pair; a surrogate without its
        /// mate becomes U+FFFD.
        private mutating func emitEscapedUnit(_ unit: UInt32, into events: inout Events) {
            switch unit {
            case 0xD800...0xDBFF:
                flushPendingHighSurrogate(into: &events)
                pendingHighSurrogate = unit
            case 0xDC00...0xDFFF:
                if let high = pendingHighSurrogate {
                    pendingHighSurrogate = nil
                    let value = 0x10000 + ((high - 0xD800) << 10) + (unit - 0xDC00)
                    emit(Unicode.Scalar(value) ?? Self.replacement, into: &events)
                } else {
                    emit(Self.replacement, into: &events)
                }
            default:
                flushPendingHighSurrogate(into: &events)
                emit(Unicode.Scalar(unit) ?? Self.replacement, into: &events)
            }
        }

        private mutating func flushPendingHighSurrogate(into events: inout Events) {
            guard pendingHighSurrogate != nil else {
                return
            }
            pendingHighSurrogate = nil
            emit(Self.replacement, into: &events)
        }

        /// A decoded scalar: a scalar of the key to compare, or of the string
        /// to draw.
        private mutating func emit(_ scalar: Unicode.Scalar, into events: inout Events) {
            if phase == .inKey {
                keyMayBeRemoval = keyMayBeRemoval && keyLength < Self.removalKey.count
                    && Self.removalKey[keyLength] == scalar
                keyMayBeAddition = keyMayBeAddition && keyLength < Self.additionKey.count
                    && Self.additionKey[keyLength] == scalar
                keyLength += 1
            } else if let marker = valueMarker {
                events.append(.scalar(scalar, marker))
            }
        }

        private mutating func endString(into events: inout Events) {
            if phase == .inKey {
                if keyMayBeRemoval && keyLength == Self.removalKey.count {
                    valueMarker = .removal
                } else if keyMayBeAddition && keyLength == Self.additionKey.count {
                    valueMarker = .addition
                } else {
                    valueMarker = nil
                }
                phase = .afterKey
            } else {
                if let marker = valueMarker {
                    events.append(.stringEnded(marker))
                }
                phase = .afterValue
            }
        }
    }
}
