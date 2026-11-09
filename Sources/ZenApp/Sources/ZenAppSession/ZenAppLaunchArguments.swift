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
}
