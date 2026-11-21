//
//  AgentConfiguration+WorkingDirectory.swift
//  ZenCODE
//
//  Resolution of the agent working directory from arguments, the environment
//  and the launch directory, and validation of worktree names.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import ToolCore

extension AgentConfiguration {
    public static func resolvedWorkingDirectory(
        rawValue: String,
        applyLaunchDirectoryFallback: Bool = true
    ) -> URL {
        let candidate = URL(fileURLWithPath: rawValue)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard applyLaunchDirectoryFallback,
              let executableDirectory = executableDirectoryURL(),
              sameFilePath(candidate, executableDirectory) else {
            return candidate
        }
        return UserHomeDirectory.current()
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    /// The working directory used when no `--working-directory` argument is
    /// given: `ZENCODE_AGENT_CWD`, else the shell's absolute and existing `PWD`,
    /// else the process's current directory.
    static func defaultWorkingDirectoryRawPath(environment: [String: String]) -> String {
        environment["ZENCODE_AGENT_CWD"]?.nilIfBlank
            ?? shellWorkingDirectory(environment: environment)
            ?? FileManager.default.currentDirectoryPath
    }

    /// The directory a launch with `arguments` and `environment` works in,
    /// resolved like the full parser does but without validating any other
    /// option: the last `--working-directory <value>` wins over the default.
    /// For flows that run before (or without) building a configuration, such as
    /// the memory maintenance of `zen --setup`, which still has to know which
    /// project it works on.
    package static func launchWorkingDirectoryURL(
        arguments: [String],
        environment: [String: String]
    ) -> URL {
        var argumentValue: String?
        var index = 1
        while index < arguments.count {
            if arguments[index] == "--working-directory", index + 1 < arguments.count {
                argumentValue = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        let hasExplicitWorkingDirectory = argumentValue != nil
            || environment["ZENCODE_AGENT_CWD"]?.nilIfBlank != nil
        return resolvedWorkingDirectory(
            rawValue: argumentValue ?? defaultWorkingDirectoryRawPath(environment: environment),
            applyLaunchDirectoryFallback: !hasExplicitWorkingDirectory
        )
    }

    /// Whether `name` can name a worktree (and its branch): not empty, not
    /// `.` or `..`, without `/`, `\` or whitespace, and not starting with `-`.
    /// Git may still reject a name it does not accept as a branch name.
    static func isValidWorktreeName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.hasPrefix("-")
            && !name.contains(where: { $0 == "/" || $0 == "\\" || $0.isWhitespace })
    }

    private static func shellWorkingDirectory(environment: [String: String]) -> String? {
        guard let path = environment["PWD"]?.nilIfBlank,
              path.hasPrefix("/") else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return path
    }

    private static func executableDirectoryURL() -> URL? {
        guard let executableURL = Bundle.main.executableURL else {
            return nil
        }
        return executableURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    private static func sameFilePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
