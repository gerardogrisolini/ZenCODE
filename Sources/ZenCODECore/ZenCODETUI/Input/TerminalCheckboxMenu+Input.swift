//
//  TerminalCheckboxMenu+Input.swift
//  ZenCODE
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

extension TerminalCheckboxMenu {
    static func readInputLine(rawInput: TerminalRawInput) -> InputLineReadResult {
        var bytes: [UInt8] = []
        while true {
            guard let byte = rawInput.readByte() else {
                return .endOfInput
            }

            switch byte {
            case 0x03:
                return .cancel
            case 0x04:
                if bytes.isEmpty {
                    return .endOfInput
                }
            case 0x0A, 0x0D:
                return .submitted(String(decoding: bytes, as: UTF8.self))
            case 0x08, 0x7F:
                guard !bytes.isEmpty else {
                    continue
                }
                removeLastUTF8Character(from: &bytes)
                AgentOutput.standardError.writeString("\u{8} \u{8}")
            case 0x1B:
                if readEscapeKey(rawInput: rawInput) == .cancel {
                    return .cancel
                }
            default:
                guard byte >= 0x20 else {
                    continue
                }
                bytes.append(byte)
                writeRawOutputByte(byte)
            }
        }
    }

    static func removeLastUTF8Character(from bytes: inout [UInt8]) {
        repeat {
            let removedByte = bytes.removeLast()
            if removedByte < 0x80 || (removedByte & 0xC0) != 0x80 {
                return
            }
        } while !bytes.isEmpty
    }

    static func writeRawOutputByte(_ byte: UInt8) {
        var mutableByte = byte
        withUnsafeBytes(of: &mutableByte) { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            _ = write(AgentOutput.standardError.fileDescriptor, baseAddress, rawBuffer.count)
        }
    }

    static func readKey(rawInput: TerminalRawInput) -> Key? {
        guard let byte = rawInput.readByte() else {
            return nil
        }

        switch byte {
        case 0x0A, 0x0D:
            return .submit
        case 0x20:
            return .toggle
        case 0x1B:
            return readEscapeKey(rawInput: rawInput)
        case 0x61, 0x41:
            return .selectAll
        case 0x6E, 0x4E:
            return .selectNone
        case 0x71, 0x51:
            return .cancel
        case 0x6A:
            return .down
        case 0x6B:
            return .up
        default:
            return .unknown
        }
    }

    static func readEscapeKey(rawInput: TerminalRawInput) -> Key {
        guard let secondByte = rawInput.readByte(timeoutMilliseconds: escapeSequenceInitialTimeout) else {
            return .cancel
        }

        switch secondByte {
        case 0x5B:
            return readCSIKey(rawInput: rawInput)
        case 0x4F:
            return readSS3Key(rawInput: rawInput)
        default:
            drainPendingEscapeSequence(rawInput: rawInput)
            return .unknown
        }
    }

    static func readCSIKey(rawInput: TerminalRawInput) -> Key {
        var bytes: [UInt8] = []
        while bytes.count < escapeSequenceMaximumLength {
            guard let byte = rawInput.readByte(timeoutMilliseconds: escapeSequenceContinuationTimeout) else {
                return .unknown
            }
            bytes.append(byte)
            if byte >= 0x40 && byte <= 0x7E {
                return keyFromCSI(bytes)
            }
        }

        drainPendingEscapeSequence(rawInput: rawInput)
        return .unknown
    }

    static func readSS3Key(rawInput: TerminalRawInput) -> Key {
        guard let byte = rawInput.readByte(timeoutMilliseconds: escapeSequenceContinuationTimeout) else {
            return .unknown
        }

        switch byte {
        case 0x41:
            return .up
        case 0x42:
            return .down
        default:
            drainPendingEscapeSequence(rawInput: rawInput)
            return .unknown
        }
    }

    static func keyFromCSI(_ bytes: [UInt8]) -> Key {
        switch bytes.last {
        case 0x41:
            return .up
        case 0x42:
            return .down
        default:
            return .unknown
        }
    }

    static func drainPendingEscapeSequence(rawInput: TerminalRawInput) {
        while rawInput.readByte(timeoutMilliseconds: escapeSequenceContinuationTimeout) != nil {}
    }
}
