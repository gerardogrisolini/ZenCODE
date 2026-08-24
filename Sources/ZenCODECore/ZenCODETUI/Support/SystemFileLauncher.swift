//
//  SystemFileLauncher.swift
//  ZenCODE
//

import Foundation

/// Shared, cross-platform launcher for files and URLs opened by terminal commands.
enum SystemFileLauncher {
    struct Command: Sendable, Equatable {
        let executableURL: URL
        let arguments: [String]
    }

    enum LaunchError: LocalizedError, Equatable {
        case unavailable
        case timedOut
        case failed(Int32)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "No system file launcher is available."
            case .timedOut:
                return "The system file launcher did not finish before the timeout."
            case let .failed(exitCode):
                return "The system file launcher failed with exit code \(exitCode)."
            }
        }
    }

    static func command(for target: String, fileManager: FileManager = .default) throws -> Command {
        #if os(macOS)
        let path = "/usr/bin/open"
        guard fileManager.isExecutableFile(atPath: path) else { throw LaunchError.unavailable }
        return Command(executableURL: URL(fileURLWithPath: path), arguments: [target])
        #elseif os(Windows)
        return Command(
            executableURL: URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe"),
            arguments: ["/c", "start", "", target]
        )
        #else
        let candidates = [
            "/usr/bin/wslview", "/usr/local/bin/wslview",
            "/usr/bin/xdg-open", "/usr/local/bin/xdg-open"
        ]
        guard let path = candidates.first(where: fileManager.isExecutableFile(atPath:)) else {
            throw LaunchError.unavailable
        }
        return Command(executableURL: URL(fileURLWithPath: path), arguments: [target])
        #endif
    }

    static func open(_ target: String, timeout: TimeInterval = 15) async throws {
        let command = try command(for: target)
        let result = try await AsyncProcessRunner.run(
            executableURL: command.executableURL,
            arguments: command.arguments,
            timeout: timeout
        )
        guard !result.timedOut else { throw LaunchError.timedOut }
        guard result.exitCode == 0 else { throw LaunchError.failed(result.exitCode) }
    }
}
