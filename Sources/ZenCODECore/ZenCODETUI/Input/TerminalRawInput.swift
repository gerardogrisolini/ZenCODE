//
//  TerminalRawInput.swift
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

public final class TerminalRawInput: @unchecked Sendable {
    private struct InputFileDescriptor {
        let fileDescriptor: Int32
        let shouldClose: Bool
        let label: String
        let canWrite: Bool
    }

    private var fileDescriptor: Int32
    private var shouldCloseFileDescriptor: Bool
    private var controlFileDescriptor: Int32
    private var shouldCloseControlFileDescriptor: Bool
    private var inputFileDescriptorLabel: String
    private var rawModeFailureDescription: String?
    private let lock = OSAllocatedUnfairLock()
    private var originalAttributes: termios?
    private var didRequestEnhancedKeyboardProtocol = false
    private var didRequestBracketedPaste = false
    public init() {
        if let inputFileDescriptor = Self.openPreferredInputFileDescriptor() {
            let controlFileDescriptor = Self.openTerminalControlFileDescriptor(
                inputFileDescriptor: inputFileDescriptor
            )

            self.fileDescriptor = inputFileDescriptor.fileDescriptor
            self.shouldCloseFileDescriptor = inputFileDescriptor.shouldClose
            self.controlFileDescriptor = controlFileDescriptor.fileDescriptor
            self.shouldCloseControlFileDescriptor = controlFileDescriptor.shouldClose
            self.inputFileDescriptorLabel = inputFileDescriptor.label
        } else {
            self.fileDescriptor = -1
            self.shouldCloseFileDescriptor = false
            self.controlFileDescriptor = -1
            self.shouldCloseControlFileDescriptor = false
            self.inputFileDescriptorLabel = "terminal"
            self.rawModeFailureDescription = Self.noForegroundTerminalDescription
        }
    }

    deinit {
        restoreRawMode()
        if shouldCloseControlFileDescriptor,
           controlFileDescriptor >= 0,
           controlFileDescriptor != fileDescriptor {
            close(controlFileDescriptor)
        }
        if shouldCloseFileDescriptor, fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }

    public static func supportsInteractiveInput() -> Bool {
        guard let inputFileDescriptor = openPreferredInputFileDescriptor() else {
            return false
        }
        if inputFileDescriptor.shouldClose {
            close(inputFileDescriptor.fileDescriptor)
        }
        return true
    }

    private static func openPreferredInputFileDescriptor() -> InputFileDescriptor? {
        if isTerminalDevice(fileDescriptor: STDIN_FILENO) {
            return InputFileDescriptor(
                fileDescriptor: STDIN_FILENO,
                shouldClose: false,
                label: "stdin",
                canWrite: true
            )
        }

        if let terminalFileDescriptor = openTerminalInput(
            path: "/dev/tty",
            label: "/dev/tty"
        ) {
            return terminalFileDescriptor
        }

        return nil
    }

    private static func openTerminalControlFileDescriptor(
        inputFileDescriptor: InputFileDescriptor
    ) -> (fileDescriptor: Int32, shouldClose: Bool) {
        if inputFileDescriptor.canWrite {
            return (inputFileDescriptor.fileDescriptor, false)
        }

        if let terminalPath = terminalPath(for: inputFileDescriptor.fileDescriptor),
           let terminalFileDescriptor = openTerminalOutput(path: terminalPath) {
            return terminalFileDescriptor
        }

        if let terminalFileDescriptor = openTerminalOutput(path: "/dev/tty") {
            return terminalFileDescriptor
        }

        if isTerminalDevice(fileDescriptor: STDERR_FILENO) {
            return (STDERR_FILENO, false)
        }

        if isTerminalDevice(fileDescriptor: STDOUT_FILENO) {
            return (STDOUT_FILENO, false)
        }

        return (-1, false)
    }

    private static func openTerminalInput(
        path: String,
        label: String
    ) -> InputFileDescriptor? {
        let attempts: [(flags: Int32, canWrite: Bool)] = [
            (O_RDWR | O_NOCTTY, true),
            (O_RDONLY | O_NOCTTY, false)
        ]

        for attempt in attempts {
            let terminalFileDescriptor = open(path, attempt.flags)
            guard terminalFileDescriptor >= 0 else {
                continue
            }
            guard isTerminalDevice(fileDescriptor: terminalFileDescriptor) else {
                close(terminalFileDescriptor)
                continue
            }
            return InputFileDescriptor(
                fileDescriptor: terminalFileDescriptor,
                shouldClose: true,
                label: label,
                canWrite: attempt.canWrite
            )
        }
        return nil
    }

    private static func openTerminalOutput(
        path: String
    ) -> (fileDescriptor: Int32, shouldClose: Bool)? {
        let terminalFileDescriptor = open(path, O_WRONLY | O_NOCTTY)
        guard terminalFileDescriptor >= 0 else {
            return nil
        }

        guard isTerminalDevice(fileDescriptor: terminalFileDescriptor) else {
            close(terminalFileDescriptor)
            return nil
        }
        return (terminalFileDescriptor, true)
    }

    private static func isTerminalDevice(fileDescriptor: Int32) -> Bool {
        guard fileDescriptor >= 0,
              isatty(fileDescriptor) == 1 else {
            return false
        }
        return true
    }

    private static func ensureForegroundTerminal(fileDescriptor: Int32) -> Bool {
        guard isTerminalDevice(fileDescriptor: fileDescriptor) else {
            return false
        }

        let foregroundProcessGroup = tcgetpgrp(fileDescriptor)
        guard foregroundProcessGroup >= 0 else {
            return false
        }

        let currentProcessGroup = getpgrp()
        guard foregroundProcessGroup != currentProcessGroup else {
            return true
        }

        guard withSIGTTOUIgnored({ tcsetpgrp(fileDescriptor, currentProcessGroup) == 0 }) else {
            return false
        }
        return tcgetpgrp(fileDescriptor) == currentProcessGroup
    }

    @discardableResult
    public func beginRawMode() -> Bool {
        lock.withLock {
            if originalAttributes != nil {
                return true
            }

            rawModeFailureDescription = nil

            guard fileDescriptor >= 0 else {
                rawModeFailureDescription = Self.noForegroundTerminalDescription
                return false
            }

            _ = Self.ensureForegroundTerminal(fileDescriptor: fileDescriptor)

            if activateRawModeLocked(fileDescriptor: fileDescriptor) {
                rawModeFailureDescription = nil
                return true
            }

            return false
        }
    }

    private func activateRawModeLocked(fileDescriptor: Int32) -> Bool {
        var attributes = termios()
        guard tcgetattr(fileDescriptor, &attributes) == 0 else {
            rawModeFailureDescription = "\(inputFileDescriptorLabel): tcgetattr failed: \(Self.errnoDescription())"
            return false
        }

        var rawAttributes = Self.rawTerminalAttributes(from: attributes)
        let didSetAttributes = Self.withSIGTTOUIgnored {
            tcsetattr(fileDescriptor, TCSANOW, &rawAttributes) == 0
        }
        guard didSetAttributes else {
            rawModeFailureDescription = "\(inputFileDescriptorLabel): tcsetattr failed: \(Self.errnoDescription())"
            return false
        }

        originalAttributes = attributes
        requestEnhancedKeyboardProtocolLocked()
        enableBracketedPasteLocked()
        return true
    }

    private static func terminalPath(for fileDescriptor: Int32) -> String? {
        guard isatty(fileDescriptor) == 1,
              let path = ttyname(fileDescriptor) else {
            return nil
        }
        let value = String(cString: path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func restoreRawMode() {
        lock.withLock {
            guard var attributes = originalAttributes else {
                return
            }
            disableBracketedPasteLocked()
            restoreEnhancedKeyboardProtocolLocked()
            _ = Self.withSIGTTOUIgnored {
                tcsetattr(fileDescriptor, TCSANOW, &attributes)
            }
            originalAttributes = nil
        }
    }

    private func requestEnhancedKeyboardProtocolLocked() {
        guard !didRequestEnhancedKeyboardProtocol else {
            return
        }
        writeToTerminal("\u{1B}[>1u\u{1B}[>4;2m")
        didRequestEnhancedKeyboardProtocol = true
    }

    private func restoreEnhancedKeyboardProtocolLocked() {
        guard didRequestEnhancedKeyboardProtocol else {
            return
        }
        writeToTerminal("\u{1B}[<u\u{1B}[>4;0m")
        didRequestEnhancedKeyboardProtocol = false
    }

    private func enableBracketedPasteLocked() {
        guard !didRequestBracketedPaste else {
            return
        }
        writeToTerminal("\u{1B}[?2004h")
        didRequestBracketedPaste = true
    }

    private func disableBracketedPasteLocked() {
        guard didRequestBracketedPaste else {
            return
        }
        writeToTerminal("\u{1B}[?2004l")
        didRequestBracketedPaste = false
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

    private static func withSIGTTOUIgnored<T>(_ body: () -> T) -> T {
        let previousSIGTTOUHandler = signal(SIGTTOU, SIG_IGN)
        defer {
            signal(SIGTTOU, previousSIGTTOUHandler)
        }
        return body()
    }

    private static var noForegroundTerminalDescription: String {
        "no foreground controlling terminal"
    }

    private static func errnoDescription() -> String {
        String(cString: strerror(errno))
    }

    public func lastRawModeFailureDescription() -> String? {
        lock.withLock {
            rawModeFailureDescription
        }
    }

    private func writeToTerminal(_ text: String) {
        guard controlFileDescriptor >= 0 else {
            return
        }
        guard let data = text.data(using: .utf8) else {
            return
        }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
                                                _ = write(controlFileDescriptor, baseAddress, rawBuffer.count)
        }
    }

    public func withRawTerminal<T>(_ body: () -> T) -> T {
        guard beginRawMode() else {
            return body()
        }
        defer {
            restoreRawMode()
        }
        return body()
    }

    public func readByte(timeoutMilliseconds: Int32? = nil) -> UInt8? {
        guard fileDescriptor >= 0 else {
            return nil
        }

        if let timeoutMilliseconds {
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, timeoutMilliseconds)
            guard pollResult > 0,
                  (descriptor.revents & Int16(POLLIN)) != 0 else {
                return nil
            }
        }

        var byte: UInt8 = 0
        let readCount = read(fileDescriptor, &byte, 1)
        guard readCount == 1 else {
            return nil
        }
        return byte
    }
}
