//
//  SystemLogViewerLauncher.swift
//  ZenCODE
//

import Foundation

enum SystemLogViewerLauncher {
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
                return "No system log viewer is available."
            case .timedOut:
                return "The system log viewer did not open before the timeout."
            case let .failed(exitCode):
                return "The system log viewer failed with exit code \(exitCode)."
            }
        }
    }

    static func command(
        isExecutableFile: (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Command {
        #if os(macOS)
        let path = "/usr/bin/open"
        guard isExecutableFile(path) else {
            throw LaunchError.unavailable
        }
        return Command(
            executableURL: URL(fileURLWithPath: path),
            arguments: ["-b", "com.apple.Console"]
        )
        #elseif os(Windows)
        return Command(
            executableURL: URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe"),
            arguments: ["/c", "start", "", "eventvwr.msc"]
        )
        #else
        let desktopLaunchers: [(path: String, arguments: [String])] = [
            ("/usr/bin/gtk-launch", ["org.gnome.Logs"]),
            ("/usr/local/bin/gtk-launch", ["org.gnome.Logs"]),
            ("/usr/bin/kstart5", ["ksystemlog"]),
            ("/usr/bin/kstart", ["ksystemlog"])
        ]
        if let launcher = desktopLaunchers.first(where: {
            isExecutableFile($0.path)
        }) {
            return Command(
                executableURL: URL(fileURLWithPath: launcher.path),
                arguments: launcher.arguments
            )
        }

        if environment["WSL_DISTRO_NAME"]?.isEmpty == false {
            let windowsShells = [
                "/mnt/c/Windows/System32/cmd.exe",
                "/mnt/c/WINDOWS/System32/cmd.exe"
            ]
            if let shell = windowsShells.first(where: isExecutableFile) {
                return Command(
                    executableURL: URL(fileURLWithPath: shell),
                    arguments: ["/c", "start", "", "eventvwr.msc"]
                )
            }
        }
        throw LaunchError.unavailable
        #endif
    }

    static func open(timeout: TimeInterval = 15) async throws {
        let command = try command()
        let result = try await AsyncProcessRunner.run(
            executableURL: command.executableURL,
            arguments: command.arguments,
            timeout: timeout
        )
        guard !result.timedOut else { throw LaunchError.timedOut }
        guard result.exitCode == 0 else { throw LaunchError.failed(result.exitCode) }
    }
}
