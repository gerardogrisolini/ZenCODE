//
//  TerminalInteractiveLineReader+Keys.swift
//  ZenCODE
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
#if canImport(os)
import os
#endif

extension TerminalInteractiveLineReader {
    func readKey(pollTimeoutMilliseconds: Int32? = nil) -> Key? {
        guard case let .key(key) = readKeyResult(
            pollTimeoutMilliseconds: pollTimeoutMilliseconds
        ) else {
            return nil
        }
        return key
    }

    func readKeyResult(pollTimeoutMilliseconds: Int32? = nil) -> KeyReadResult {
        let byte: UInt8
        switch rawInput.readByteResult(timeoutMilliseconds: pollTimeoutMilliseconds) {
        case let .byte(value):
            byte = value
        case .timedOut:
            return .timedOut
        case .endOfInput:
            return .endOfInput
        }

        if let key = Self.controlKey(for: byte) {
            return .key(key)
        }

        switch byte {
        case 0x1B:
            return .key(readEscapeKey())
        default:
            return .key(decodeCharacter(startingWith: byte).map(Key.character) ?? .unknown)
        }
    }

    static func controlKey(for byte: UInt8) -> Key? {
        switch byte {
        case 0x04: return .endOfInput
        case 0x01: return .toggleAccessMode
        case 0x05: return .end
        case 0x0B: return .clearAfterCursor
        case 0x15: return .clearBeforeCursor
        case 0x14: return .toggleToolDetails
        case 0x0D: return .enter
        case 0x09: return .tab
        case 0x7F, 0x08: return .backspace
        default: return nil
        }
    }

    func readEscapeKey() -> Key {
        guard let secondByte = readByte(timeoutMilliseconds: Self.escapeSequenceInitialTimeout) else {
            return .cancel
        }

        switch secondByte {
        case 0x0A, 0x0D:
            // Legacy Option+Enter (ESC+CR) fallback for terminals without an
            // extended keyboard protocol, where Shift+Enter is not detectable.
            return .newline
        case 0x5B:
            return readCSIKey()
        case 0x4F:
            return readSS3Key()
        default:
            drainPendingEscapeSequence()
            return .unknown
        }
    }

    func readCSIKey() -> Key {
        var bytes: [UInt8] = []
        while bytes.count < Self.escapeSequenceMaximumLength {
            guard let byte = readByte(timeoutMilliseconds: Self.escapeSequenceContinuationTimeout) else {
                return .unknown
            }
            bytes.append(byte)
            if byte >= 0x40 && byte <= 0x7E {
                return keyFromCSI(bytes)
            }
        }

        drainPendingEscapeSequence()
        return .unknown
    }

    func readSS3Key() -> Key {
        guard let byte = readByte(timeoutMilliseconds: Self.escapeSequenceContinuationTimeout) else {
            return .unknown
        }

        switch byte {
        case 0x41:
            return .up
        case 0x42:
            return .down
        case 0x43:
            return .right
        case 0x44:
            return .left
        case 0x46:
            return .end
        case 0x48:
            return .home
        default:
            drainPendingEscapeSequence()
            return .unknown
        }
    }

    func keyFromCSI(_ bytes: [UInt8]) -> Key {
        guard let finalByte = bytes.last else {
            return .unknown
        }

        switch finalByte {
        case 0x41:
            return .up
        case 0x42:
            return .down
        case 0x43:
            return .right
        case 0x44:
            return .left
        case 0x46:
            return .end
        case 0x48:
            return .home
        case 0x7E:
            return tildeTerminatedKey(bytes)
        case 0x75:
            return csiUKey(bytes)
        default:
            return .unknown
        }
    }

    func tildeTerminatedKey(_ bytes: [UInt8]) -> Key {
        guard let sequence = String(bytes: bytes.dropLast(), encoding: .utf8) else {
            return .unknown
        }
        let components = sequence.split(separator: ";").map(String.init)
        if let key = Self.shiftReturnKey(components: components, keyCodeIndex: 0, modifierIndex: 1) {
            return key
        }
        if let key = Self.modifyOtherKeysKey(components: components) {
            return key
        }
        let numericPrefix = components.first

        switch numericPrefix {
        case "200":
            return .paste(readBracketedPaste())
        case "201":
            return .unknown
        case "1", "7":
            return .home
        case "3":
            return .delete
        case "4", "8":
            return .end
        default:
            return .unknown
        }
    }

    func csiUKey(_ bytes: [UInt8]) -> Key {
        guard let sequence = String(bytes: bytes.dropLast(), encoding: .utf8) else {
            return .unknown
        }
        let components = sequence.split(separator: ";").map(String.init)
        guard Self.isKittyPressEvent(components: components, modifierIndex: 1) else {
            return .unknown
        }
        if let key = Self.shiftReturnKey(components: components, keyCodeIndex: 0, modifierIndex: 1) {
            return key
        }
        if let key = Self.shiftReturnKey(components: components, keyCodeIndex: 2, modifierIndex: 1) {
            return key
        }
        if let key = Self.controlShortcutKey(components: components, keyCodeIndex: 0, modifierIndex: 1) {
            return key
        }
        return .unknown
    }

    func readBracketedPaste() -> String {
        let endSequence: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        var bytes: [UInt8] = []

        while true {
            guard let byte = readByte(timeoutMilliseconds: Self.bracketedPasteByteTimeout) else {
                return Self.normalizedPastedText(bytes: bytes)
            }
            bytes.append(byte)
            if bytes.suffix(endSequence.count) == endSequence {
                bytes.removeLast(endSequence.count)
                return Self.normalizedPastedText(bytes: bytes)
            }
        }
    }

    static func normalizedPastedText(bytes: [UInt8]) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func shiftReturnKey(
        components: [String],
        keyCodeIndex: Int,
        modifierIndex: Int
    ) -> Key? {
        guard components.indices.contains(keyCodeIndex),
              Self.isReturnKeyCode(Self.integerPrefix(in: components[keyCodeIndex])) else {
            return nil
        }
        guard components.indices.contains(modifierIndex),
              let modifier = Self.integerPrefix(in: components[modifierIndex]) else {
            return .enter
        }
        let modifierBits = modifier - 1
        // Shift (0b01) or Alt (0b10): both are newline shortcuts, matching
        // the legacy ESC+CR (Option+Enter) fallback path.
        return (modifierBits & 0b11) != 0 ? .newline : .enter
    }

    static func isReturnKeyCode(_ keyCode: Int?) -> Bool {
        keyCode == 10 || keyCode == 13
    }

    static func isKittyPressEvent(
        components: [String],
        modifierIndex: Int
    ) -> Bool {
        guard components.indices.contains(modifierIndex) else {
            return true
        }
        let fields = components[modifierIndex].split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard fields.count <= 2,
              let modifier = fields.first.flatMap({ Int($0) }),
              modifier > 0 else {
            return false
        }
        guard fields.count == 2 else {
            return true
        }
        return Int(fields[1]) == 1
    }

    static func modifyOtherKeysKey(components: [String]) -> Key? {
        guard components.count == 3,
              components[0] == "27",
              Int(components[1]) != nil,
              Int(components[2]) != nil else {
            return nil
        }
        return shiftReturnKey(components: components, keyCodeIndex: 2, modifierIndex: 1)
        ?? controlShortcutKey(components: components, keyCodeIndex: 2, modifierIndex: 1)
    }

    static func controlShortcutKey(
        components: [String],
        keyCodeIndex: Int,
        modifierIndex: Int
    ) -> Key? {
        guard components.indices.contains(keyCodeIndex),
              let keyCode = Self.integerPrefix(in: components[keyCodeIndex]),
              components.indices.contains(modifierIndex),
              let modifier = Self.integerPrefix(in: components[modifierIndex]),
              modifier > 0,
              ((modifier - 1) & 0b100) != 0 else {
            return nil
        }

        switch keyCode {
        case 97:
            return .toggleAccessMode
        case 116:
            return .toggleToolDetails
        default:
            return nil
        }
    }

    static func integerPrefix(in component: String) -> Int? {
        let prefix = component.split(separator: ":", maxSplits: 1).first
        return prefix.flatMap { Int($0) }
    }

    func decodeCharacter(startingWith firstByte: UInt8) -> String? {
        guard firstByte >= 0x20 else {
            return nil
        }

        let byteCount = utf8ByteCount(startingWith: firstByte)
        guard byteCount > 0 else {
            return nil
        }
        guard byteCount > 1 else {
            return String(bytes: [firstByte], encoding: .utf8)
        }

        var bytes = [firstByte]
        while bytes.count < byteCount {
            guard let byte = readByte(timeoutMilliseconds: Self.escapeSequenceContinuationTimeout) else {
                return nil
            }
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    func utf8ByteCount(startingWith byte: UInt8) -> Int {
        if byte & 0b1000_0000 == 0 {
            return 1
        }
        if byte & 0b1110_0000 == 0b1100_0000 {
            return 2
        }
        if byte & 0b1111_0000 == 0b1110_0000 {
            return 3
        }
        if byte & 0b1111_1000 == 0b1111_0000 {
            return 4
        }
        return 0
    }

    func drainPendingEscapeSequence() {
        while readByte(timeoutMilliseconds: Self.escapeSequenceContinuationTimeout) != nil {}
    }

    func readByte(timeoutMilliseconds: Int32? = nil) -> UInt8? {
        rawInput.readByte(timeoutMilliseconds: timeoutMilliseconds)
    }
}
