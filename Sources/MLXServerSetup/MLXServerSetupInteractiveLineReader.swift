//
//  MLXServerSetupInteractiveLineReader.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 31/05/26.
//

import Foundation
import Darwin

final class MLXServerSetupInteractiveLineReader: Sendable {
    func readLine(prompt: String) -> String? {
        FileHandle.standardError.writeString(prompt)

        return readRawLine(echoInput: true)
    }

    func readSecureLine(prompt: String) -> String? {
        FileHandle.standardError.writeString(prompt)

        return readRawLine(echoInput: false)
    }

    static func supportsInteractiveInput() -> Bool {
        isatty(STDIN_FILENO) == 1
    }

    private func readRawLine(echoInput: Bool) -> String? {
        var originalAttributes = termios()
        guard tcgetattr(STDIN_FILENO, &originalAttributes) == 0 else {
            return Swift.readLine()
        }

        var rawAttributes = Self.rawTerminalAttributes(from: originalAttributes)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &rawAttributes) == 0 else {
            return Swift.readLine()
        }
        defer {
            var attributes = originalAttributes
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
        }

        var bytes: [UInt8] = []
        while true {
            guard let byte = readByte() else {
                FileHandle.standardError.writeString("\n")
                return nil
            }

            switch byte {
            case 3:
                FileHandle.standardError.writeString("^C\n")
                return nil
            case 4:
                guard bytes.isEmpty else {
                    continue
                }
                FileHandle.standardError.writeString("\n")
                return nil
            case 10, 13:
                FileHandle.standardError.writeString("\n")
                return String(decoding: bytes, as: UTF8.self)
            case 8, 127:
                guard !bytes.isEmpty else {
                    continue
                }
                bytes.removeLast()
                if echoInput {
                    FileHandle.standardError.writeString("\u{8} \u{8}")
                }
            case 27:
                discardEscapeSequence()
            default:
                bytes.append(byte)
                if echoInput {
                    writeByte(byte)
                }
            }
        }
    }

    private static func rawTerminalAttributes(from attributes: termios) -> termios {
        var rawAttributes = attributes
        rawAttributes.c_lflag &= ~tcflag_t(ECHO | ECHONL | ICANON | IEXTEN)
        rawAttributes.c_iflag &= ~tcflag_t(BRKINT | ICRNL | IGNCR | INLCR | INPCK | ISTRIP | IXON)
        rawAttributes.c_cflag |= tcflag_t(CS8)
        withUnsafeMutableBytes(of: &rawAttributes.c_cc) { controlCharacters in
            let minimumByteCountIndex = Int(VMIN)
            let timeoutIndex = Int(VTIME)
            if controlCharacters.indices.contains(minimumByteCountIndex) {
                controlCharacters[minimumByteCountIndex] = 1
            }
            if controlCharacters.indices.contains(timeoutIndex) {
                controlCharacters[timeoutIndex] = 0
            }
        }
        return rawAttributes
    }

    private func readByte(timeoutMilliseconds: Int32? = nil) -> UInt8? {
        if let timeoutMilliseconds {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, timeoutMilliseconds)
            guard pollResult > 0,
                  (descriptor.revents & Int16(POLLIN)) != 0 else {
                return nil
            }
        }

        var byte: UInt8 = 0
        let readCount = read(STDIN_FILENO, &byte, 1)
        guard readCount == 1 else {
            return nil
        }
        return byte
    }

    private func discardEscapeSequence() {
        while let byte = readByte(timeoutMilliseconds: 10) {
            if (64...126).contains(byte) {
                return
            }
        }
    }

        private func writeByte(_ byte: UInt8) {
        try? FileHandle.standardError.write(contentsOf: Data([byte]))
    }
}
