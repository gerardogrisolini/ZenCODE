//
//  FigmaBrowserLauncher.swift
//  ZenCODE
//
//  Opens the local sign-in page in the system browser: `open` on macOS;
//  `wslview` (WSL) and then `xdg-open` (desktop Linux), the same launchers
//  and order ZenCODE uses for its other browser sign-ins.
//

import Foundation

enum FigmaBrowserLauncher {
    struct Command: Equatable, Sendable {
        let executablePath: String
        let arguments: [String]
    }

    static let macOSLaunchers = ["/usr/bin/open"]
    static let linuxLaunchers = [
        "/usr/bin/wslview", "/usr/local/bin/wslview",
        "/usr/bin/xdg-open", "/usr/local/bin/xdg-open"
    ]

    static var platformLaunchers: [String] {
        #if os(macOS)
        macOSLaunchers
        #else
        linuxLaunchers
        #endif
    }

    /// The first launcher in `launchers` that `isExecutable` accepts, or `nil`
    /// when the machine has none. Pure: it never starts a process.
    static func command(
        for url: URL,
        launchers: [String] = platformLaunchers,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Command? {
        launchers
            .first(where: isExecutable)
            .map { Command(executablePath: $0, arguments: [url.absoluteString]) }
    }

    /// Starts the launcher without waiting for it and reports whether it
    /// could be started. Its output and input are detached: the feature talks
    /// to ZenCODE over stdin/stdout, which a child must neither read nor write.
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard let command = command(for: url) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }
}
