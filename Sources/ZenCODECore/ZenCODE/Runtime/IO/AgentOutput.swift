//
//  AgentOutput.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public enum AgentOutput {
    private static let nullPath = "/dev/null"

    public static let standardOutput: FileHandle = {
        let fileDescriptor = dup(STDOUT_FILENO)
        guard fileDescriptor >= 0 else {
            return .standardOutput
        }
        return FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    }()

    public static let standardError: FileHandle = {
        let fileDescriptor = dup(STDERR_FILENO)
        guard fileDescriptor >= 0 else {
            return .standardError
        }
        return FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    }()

    public static var standardErrorIsTerminal: Bool {
        isatty(standardError.fileDescriptor) == 1
    }

    public static var standardOutputIsTerminal: Bool {
        isatty(standardOutput.fileDescriptor) == 1
    }

    public static func clearTerminalScreenIfNeeded() {
        guard standardErrorIsTerminal else {
            return
        }
        standardError.writeString("\u{1B}[2J\u{1B}[H")
    }

    public static func silenceInheritedProcessOutput(keepStandardError: Bool) {
        _ = standardOutput
        _ = standardError

        let nullFileDescriptor = open(nullPath, O_WRONLY)
        guard nullFileDescriptor >= 0 else {
            return
        }
        defer { close(nullFileDescriptor) }

        _ = dup2(nullFileDescriptor, STDOUT_FILENO)
        if !keepStandardError {
            _ = dup2(nullFileDescriptor, STDERR_FILENO)
        }
    }

    public static func silenceInheritedProcessError() {
        _ = standardError

        let nullFileDescriptor = open(nullPath, O_WRONLY)
        guard nullFileDescriptor >= 0 else {
            return
        }
        defer { close(nullFileDescriptor) }

        _ = dup2(nullFileDescriptor, STDERR_FILENO)
    }
}
