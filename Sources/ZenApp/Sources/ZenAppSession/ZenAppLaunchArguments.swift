//
//  ZenAppLaunchArguments.swift
//  ZenApp
//
//  The options the app reads from its command line: the ones `zen --ui`
//  forwards, so that the app opens with the agent, the model, the skills,
//  the workspace and the worktree asked for in the terminal.
//

import Foundation
import ZenCODECore

/// The configuration arguments of the app, taken from its process arguments.
public enum ZenAppLaunchArguments {
    /// The options the app reads, each followed by its value: the ones that
    /// `zen --ui` forwards. Keep in sync with
    /// `ZenAppLaunchCommand.forwardedOptions` of ZenCODECore
    /// (`Sources/ZenCODECore/Support/App/ZenAppLaunchCommand.swift`), which
    /// accepts them on the `zen` command line.
    public static let forwardedOptions: Set<String> = [
        "--agent", "--model", "--skills", "--working-directory", "--worktree"
    ]

    /// The arguments to build the launch configuration from:
    /// `executableName`, then every `--agent`, `--model`, `--skills`,
    /// `--working-directory` and `--worktree` of `processArguments` with its
    /// value, in order.
    ///
    /// Everything else is ignored: the executable path at index 0, and the
    /// arguments AppKit or Xcode add, such as `-NSDocumentRevisionsDebugMode
    /// YES` or `-ApplePersistenceIgnoreState YES`.
    ///
    /// - Throws: `AgentConfigurationError.missingValue` when one of the
    ///   options is the last argument.
    public static func configurationArguments(
        from processArguments: [String],
        executableName: String = "ZenCODE"
    ) throws -> [String] {
        var arguments = [executableName]
        var index = 1
        while index < processArguments.count {
            let argument = processArguments[index]
            guard forwardedOptions.contains(argument) else {
                index += 1
                continue
            }
            guard index + 1 < processArguments.count else {
                throw AgentConfigurationError.missingValue(argument)
            }
            arguments.append(argument)
            arguments.append(processArguments[index + 1])
            index += 2
        }
        return arguments
    }

    /// Whether `bundleURL` (`Bundle.main.bundleURL`) is an application
    /// bundle, `ZenCODE.app`. For the bare executable that `zen --ui`, `swift
    /// run` and Xcode start, it is the folder of the executable.
    public static func isApplicationBundle(_ bundleURL: URL) -> Bool {
        bundleURL.pathExtension.lowercased() == "app"
    }

    /// Whether the app asks for its workspace folder before it launches: it
    /// runs from its application bundle (opened from /Applications, the Dock,
    /// Launchpad or Spotlight, which start it in `/`), and the configuration
    /// arguments (``configurationArguments(from:executableName:)``) have no
    /// `--working-directory`. `zen --ui` always passes one; `swift run` starts
    /// the bare executable in the workspace folder.
    public static func asksForWorkspace(configurationArguments: [String], isApplicationBundle: Bool) -> Bool {
        guard isApplicationBundle else { return false }
        // The arguments are the executable name, then option and value pairs.
        let options = stride(from: 1, to: configurationArguments.count, by: 2).map { configurationArguments[$0] }
        return !options.contains("--working-directory")
    }
}
