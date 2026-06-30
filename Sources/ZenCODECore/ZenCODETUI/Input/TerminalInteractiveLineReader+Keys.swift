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
        guard let byte = readByte(timeoutMilliseconds: pollTimeoutMilliseconds) else {
            return nil
        }

        switch byte {
        case 0x04:
            return .endOfInput
        case 0x01:
            return .home
        case 0x05:
            return .end
        case 0x0B:
            return .clearAfterCursor
        case 0x15:
            return .clearBeforeCursor
        case 0x14:
            return .toggleToolDetails
        case 0x0A:
            return .enter
        case 0x0D:
            return .enter
        case 0x09:
            return .tab
        case 0x7F, 0x08:
            return .backspace
        case 0x1B:
            return readEscapeKey()
        default:
            return decodeCharacter(startingWith: byte).map(Key.character) ?? .unknown
        }
    }

    func readEscapeKey() -> Key {
        guard let secondByte = readByte(timeoutMilliseconds: Self.escapeSequenceInitialTimeout) else {
            return .cancel
        }

        switch secondByte {
        case 0x0A, 0x0D:
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
        if let key = optionReturnKey(components: components, keyCodeIndex: 0, modifierIndex: 1) {
            return key
        }
        if let key = optionReturnKey(components: components, keyCodeIndex: 2, modifierIndex: 1) {
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
        if let key = optionReturnKey(components: components, keyCodeIndex: 0, modifierIndex: 1) {
            return key
        }
        if let key = optionReturnKey(components: components, keyCodeIndex: 2, modifierIndex: 1) {
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

    func optionReturnKey(
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
        return (modifierBits & 0b10) != 0 ? .newline : .enter
    }

    static func isReturnKeyCode(_ keyCode: Int?) -> Bool {
        keyCode == 10 || keyCode == 13
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
