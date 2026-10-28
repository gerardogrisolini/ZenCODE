//
//  TerminalCheckboxMenu+Input.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

extension TerminalCheckboxMenu {
    static func readInputLine(rawInput: TerminalRawInput) -> InputLineReadResult {
        readInputLine(rawInput: rawInput, shouldCancel: nil)
    }

    static func readInputLine(
        rawInput: TerminalRawInput,
        shouldCancel: (@Sendable () -> Bool)?
    ) -> InputLineReadResult {
        readInputLine(
            rawInput: rawInput,
            shouldCancel: shouldCancel,
            initialValue: "",
            resizeGeneration: nil
        )
    }

    static func readInputLine(
        rawInput: TerminalRawInput,
        shouldCancel: (@Sendable () -> Bool)?,
        initialValue: String,
        resizeGeneration: UInt64?,
        onChange: ((String) -> Void)? = nil
    ) -> InputLineReadResult {
        var bytes = Array(initialValue.utf8)
        if let onChange { onChange(initialValue) }
        else if !bytes.isEmpty { bytes.forEach(writeRawOutputByte) }

        while true {
            switch readByteEvent(
                rawInput: rawInput,
                shouldCancel: shouldCancel,
                resizeGeneration: resizeGeneration
            ) {
            case let .byte(byte):
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
                    var value = String(decoding: bytes, as: UTF8.self)
                    value.removeLast()
                    bytes = Array(value.utf8)
                    if let onChange { onChange(value) }
                    else { writeTerminal("\u{8} \u{8}") }
                case 0x1B:
                    switch readEscapeKey(
                        rawInput: rawInput,
                        resizeGeneration: resizeGeneration
                    ) {
                    case .cancel:
                        return .cancel
                    case .resize:
                        return .resized(String(decoding: bytes, as: UTF8.self))
                    default:
                        break
                    }
                default:
                    guard byte >= 0x20 else {
                        continue
                    }
                    bytes.append(byte)
                    if let onChange {
                        // Do not paint an incomplete UTF-8 scalar mid-keystroke.
                        if let value = String(bytes: bytes, encoding: .utf8) { onChange(value) }
                    } else { writeRawOutputByte(byte) }
                }
            case .resize:
                return .resized(String(decoding: bytes, as: UTF8.self))
            case .end:
                return .endOfInput
            }
        }
    }

    enum ByteReadEvent {
        case byte(UInt8)
        case resize
        case end
    }

    static func readByteEvent(
        rawInput: TerminalRawInput,
        shouldCancel: (@Sendable () -> Bool)?,
        resizeGeneration: UInt64?,
        timeoutMilliseconds: Int32? = nil
    ) -> ByteReadEvent {
        guard shouldCancel != nil || resizeGeneration != nil else {
            return rawInput.readByte(timeoutMilliseconds: timeoutMilliseconds)
                .map(ByteReadEvent.byte) ?? .end
        }

        let deadlineNanoseconds: UInt64? = timeoutMilliseconds.map { timeout in
            let durationMilliseconds = UInt64(max(0, Int64(timeout)))
            return DispatchTime.now().uptimeNanoseconds &+ durationMilliseconds * 1_000_000
        }

        while true {
            if shouldCancel?() == true {
                return .end
            }
            if let resizeGeneration,
               TerminalResizeCoordinator.shared.currentGeneration() != resizeGeneration {
                return .resize
            }
            let pollTimeoutMilliseconds: Int32
            if let deadlineNanoseconds {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadlineNanoseconds else {
                    return .end
                }
                let remainingNanoseconds = deadlineNanoseconds - now
                let remainingMilliseconds = max(1, (remainingNanoseconds + 999_999) / 1_000_000)
                pollTimeoutMilliseconds = Int32(
                    min(UInt64(cancellationPollTimeout), remainingMilliseconds)
                )
            } else {
                pollTimeoutMilliseconds = cancellationPollTimeout
            }
            guard let result = TerminalConsentInputOwnership.withBackgroundRead({
                rawInput.readByteResult(timeoutMilliseconds: pollTimeoutMilliseconds)
            }) else {
                continue
            }
            switch result {
            case let .byte(byte):
                return .byte(byte)
            case .timedOut:
                if let deadlineNanoseconds,
                   DispatchTime.now().uptimeNanoseconds >= deadlineNanoseconds {
                    return .end
                }
                continue
            case .endOfInput:
                return .end
            }
        }
    }

    static func readByte(
        rawInput: TerminalRawInput,
        shouldCancel: (@Sendable () -> Bool)?
    ) -> UInt8? {
        switch readByteEvent(
            rawInput: rawInput,
            shouldCancel: shouldCancel,
            resizeGeneration: nil
        ) {
        case let .byte(byte):
            return byte
        case .resize, .end:
            return nil
        }
    }

    static func writeRawOutputByte(_ byte: UInt8) {
        TerminalOutputSynchronization.writeOverlay(
            Data([byte]),
            to: AgentOutput.standardError
        )
    }

    static func readKey(rawInput: TerminalRawInput) -> Key? {
        readKey(rawInput: rawInput, shouldCancel: nil)
    }

    static func readKey(
        rawInput: TerminalRawInput,
        shouldCancel: (@Sendable () -> Bool)?
    ) -> Key? {
        readKey(rawInput: rawInput, shouldCancel: shouldCancel, resizeGeneration: nil)
    }

    static func readKey(
        rawInput: TerminalRawInput,
        shouldCancel: (@Sendable () -> Bool)?,
        resizeGeneration: UInt64?
    ) -> Key? {
        switch readByteEvent(
            rawInput: rawInput,
            shouldCancel: shouldCancel,
            resizeGeneration: resizeGeneration
        ) {
        case let .byte(byte):
            switch byte {
            case 0x0A, 0x0D:
                return .submit
            case 0x09:
                return .tab
            case 0x20:
                return .toggle
            case 0x58, 0x78:
                return .toggle
            case 0x1B:
                return readEscapeKey(rawInput: rawInput, resizeGeneration: resizeGeneration)
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
        case .resize:
            return .resize
        case .end:
            return nil
        }
    }

    static func readEscapeKey(rawInput: TerminalRawInput, resizeGeneration: UInt64?) -> Key {
        let secondByte: UInt8
        switch readByteEvent(
            rawInput: rawInput,
            shouldCancel: nil,
            resizeGeneration: resizeGeneration,
            timeoutMilliseconds: escapeSequenceInitialTimeout
        ) {
        case let .byte(byte):
            secondByte = byte
        case .resize:
            return .resize
        case .end:
            return .cancel
        }

        switch secondByte {
        case 0x5B:
            return readCSIKey(rawInput: rawInput, resizeGeneration: resizeGeneration)
        case 0x4F:
            return readSS3Key(rawInput: rawInput, resizeGeneration: resizeGeneration)
        default:
            drainPendingEscapeSequence(rawInput: rawInput)
            return .unknown
        }
    }

    static func readCSIKey(rawInput: TerminalRawInput, resizeGeneration: UInt64?) -> Key {
        var bytes: [UInt8] = []
        while bytes.count < escapeSequenceMaximumLength {
            switch readByteEvent(
                rawInput: rawInput,
                shouldCancel: nil,
                resizeGeneration: resizeGeneration,
                timeoutMilliseconds: escapeSequenceContinuationTimeout
            ) {
            case let .byte(byte):
                bytes.append(byte)
                if byte >= 0x40 && byte <= 0x7E {
                    return keyFromCSI(bytes)
                }
            case .resize:
                return .resize
            case .end:
                return .unknown
            }
        }

        drainPendingEscapeSequence(rawInput: rawInput)
        return .unknown
    }

    static func readSS3Key(rawInput: TerminalRawInput, resizeGeneration: UInt64?) -> Key {
        switch readByteEvent(
            rawInput: rawInput,
            shouldCancel: nil,
            resizeGeneration: resizeGeneration,
            timeoutMilliseconds: escapeSequenceContinuationTimeout
        ) {
        case .byte(0x41):
            return .up
        case .byte(0x42):
            return .down
        case .byte:
            drainPendingEscapeSequence(rawInput: rawInput)
            return .unknown
        case .resize:
            return .resize
        case .end:
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
