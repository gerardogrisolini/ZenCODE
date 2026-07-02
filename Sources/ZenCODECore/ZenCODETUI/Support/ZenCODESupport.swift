//
//  ZenCODESupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import ZenPackageMetadata

let agentVersion = ZenPackageMetadata.version

public enum SwiftPMResourceBundleDirectory {
    private static let environmentKey = "PACKAGE_RESOURCE_BUNDLE_PATH"

    public static func configure() {
        guard getenv(environmentKey) == nil,
              let executableDirectory = resolvedExecutableDirectory() else {
            return
        }
        setenv(environmentKey, executableDirectory, 0)
    }

    private static func resolvedExecutableDirectory() -> String? {
        let candidatePaths = [
            executablePathFromDyld(),
            CommandLine.arguments.first
        ].compactMap { path -> String? in
            let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedPath?.isEmpty == false ? trimmedPath : nil
        }

        for candidatePath in candidatePaths {
            guard let resolvedPath = realPath(candidatePath) else {
                continue
            }
            return URL(fileURLWithPath: resolvedPath)
                .deletingLastPathComponent()
                .path
        }

        return nil
    }

    private static func executablePathFromDyld() -> String? {
        Bundle.main.executableURL?.path
    }

    private static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else {
            return nil
        }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        let bytes = buffer[..<length].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

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
