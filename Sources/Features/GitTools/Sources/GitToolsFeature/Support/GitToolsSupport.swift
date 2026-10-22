import ToolCore
import Foundation
import FeatureKit

/// Input of a git tool whose `path` argument is a file or pathspec target
/// (diff, show, blame, grep, add, restore): only `workingDirectory` selects the
/// repository.
protocol GitWorkingDirectoryInput: WorkingDirectoryInput {
    /// True when `path` is a working-directory alias rather than a pathspec.
    static var pathSelectsWorkingDirectory: Bool { get }
}

extension GitWorkingDirectoryInput {
    static var pathSelectsWorkingDirectory: Bool { false }
}

/// Input of a git tool that takes no file pathspec: `path` is a working
/// directory alias with the FeatureKit `WorkingDirectoryInput` semantics
/// (`workingDirectory` wins when both are given).
protocol GitRepositoryDirectoryInput: GitWorkingDirectoryInput {}

extension GitRepositoryDirectoryInput {
    static var pathSelectsWorkingDirectory: Bool { true }
}

/// A git tool whose whole behavior is mapping its input to a validated argv.
protocol GitArgumentTool: FeatureTool where Input: GitWorkingDirectoryInput {
    static func arguments(for input: Input) throws -> [String]
}

extension GitArgumentTool {
    func run(_ input: Input, context: FeatureContext) async throws -> String {
        try await GitToolsSupport.runGit(try Self.arguments(for: input), input: input, context: context)
    }
}

enum GitToolsSupport {
    static func runGit<T: GitWorkingDirectoryInput>(
        _ arguments: [String],
        input: T,
        context: FeatureContext
    ) async throws -> String {
        try await runGitResult(arguments, input: input, context: context).renderedProcessOutput
    }

    /// Runs `git <arguments>` without the shell and returns the raw result so
    /// callers can post-process stdout before rendering it.
    static func runGitResult<T: GitWorkingDirectoryInput>(
        _ arguments: [String],
        input: T,
        context: FeatureContext
    ) async throws -> FeatureProcessResult {
        try await FeatureProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            workingDirectory: try gitWorkingDirectory(input: input, context: context),
            environment: gitEnvironment(context.environment),
            timeout: 60
        )
    }

    /// Resolves and validates the repository directory. Tools whose `path` is a
    /// pathspec target only honour `workingDirectory`; the others treat `path`
    /// as a working-directory alias. A relative value is resolved against the
    /// session working directory; a missing or non-directory value fails with a
    /// clear error instead of silently running in the host working directory.
    static func gitWorkingDirectory<T: GitWorkingDirectoryInput>(input: T, context: FeatureContext) throws -> URL {
        let argumentName: String
        let value: String?
        if T.pathSelectsWorkingDirectory, input.workingDirectory?.nilIfBlank == nil, let path = input.path?.nilIfBlank {
            argumentName = "path"
            value = path
        } else {
            argumentName = "workingDirectory"
            value = input.workingDirectory?.nilIfBlank
        }
        let directory = context.resolvePath(value ?? ".")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw GitToolsFeatureError.invalidWorkingDirectory(
                "Working directory does not exist: \(directory.path) (argument '\(argumentName)')."
            )
        }
        guard isDirectory.boolValue else {
            var message = "Argument '\(argumentName)' must be a directory, got a file: \(directory.path)."
            if argumentName == "path" {
                message += " This tool takes no file pathspec; pass the repository directory in 'workingDirectory'."
            }
            throw GitToolsFeatureError.invalidWorkingDirectory(message)
        }
        return directory
    }

    /// The child environment: git must never block on a credential or
    /// passphrase prompt on the controlling terminal, which the feature
    /// process shares with ZenCODE. Caller-provided values are preserved.
    static func gitEnvironment(_ base: [String: String]) -> [String: String] {
        var environment = base
        if environment["GIT_TERMINAL_PROMPT"] == nil {
            environment["GIT_TERMINAL_PROMPT"] = "0"
        }
        return environment
    }

    /// Keeps at most `maxLines` lines of `stdout` and renders the result in the
    /// shared process format, noting the truncation so a cut list is never
    /// mistaken for the complete one.
    static func renderLimitedStdout(_ result: FeatureProcessResult, maxLines: Int) -> String {
        var lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        var stdout = lines.prefix(maxLines).joined(separator: "\n")
        if lines.count > maxLines {
            stdout += "\n[output truncated to the first \(maxLines) of \(lines.count) lines; raise maxResults or narrow the request]"
        }
        return render(result, stdout: stdout)
    }

    /// Renders `git grep -n -z --column` output keeping at most `maxMatches`
    /// MATCH lines: context lines and `--` group separators do not consume the
    /// budget. With `-z` every separator is NUL and the column is printed only
    /// on match lines, so a match is `path\0LINE\0COLUMN\0text` and a context
    /// line is `path\0LINE\0text`, whatever the path contains. Lines are
    /// re-rendered in the usual `path:LINE:text` / `path-LINE-text` form. The
    /// output stops before the (maxMatches + 1)-th match; a trailing group
    /// separator, together with the leading context of the dropped match that
    /// follows it, is removed. A context line whose text itself starts with
    /// `digits\0` would be counted as a match; that is harmless.
    static func renderLimitedGrep(_ result: FeatureProcessResult, maxMatches: Int) -> String {
        var lines = result.stdoutData.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        var rendered: [String] = []
        var totalMatches = 0
        var cut = false
        var lastSeparatorIndex: Int?
        var matchSinceSeparator = false
        for line in lines {
            let fields = line.split(separator: 0, maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                // `--` group separator (or a line git did not delimit).
                if !cut {
                    lastSeparatorIndex = rendered.count
                    matchSinceSeparator = false
                    rendered.append(String(decoding: line, as: UTF8.self))
                }
                continue
            }
            let path = String(decoding: fields[0], as: UTF8.self)
            let number = String(decoding: fields[1], as: UTF8.self)
            if let text = grepTextAfterColumn(fields[2]) {
                totalMatches += 1
                if totalMatches > maxMatches {
                    cut = true
                } else {
                    matchSinceSeparator = true
                    rendered.append("\(path):\(number):\(String(decoding: text, as: UTF8.self))")
                }
            } else if !cut {
                rendered.append("\(path)-\(number)-\(String(decoding: fields[2], as: UTF8.self))")
            }
        }
        if cut, !matchSinceSeparator, let lastSeparatorIndex {
            rendered.removeSubrange(lastSeparatorIndex...)
        }
        var stdout = rendered.joined(separator: "\n")
        if cut {
            stdout += "\n[output truncated to the first \(maxMatches) of \(totalMatches) matches; raise maxResults or narrow the request]"
        }
        return render(result, stdout: stdout)
    }

    /// The text of a `--column` match line after `COLUMN\0`, nil when `rest`
    /// does not start with a non-empty run of digits followed by NUL (a context line).
    private static func grepTextAfterColumn(_ rest: Data.SubSequence) -> Data.SubSequence? {
        guard let separator = rest.firstIndex(of: 0), separator > rest.startIndex else { return nil }
        let column = rest[rest.startIndex..<separator]
        guard column.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
        return rest[rest.index(after: separator)...]
    }

    /// Renders `result` with the given (already limited) stdout, flagging the
    /// safety-limit truncations of the process runner.
    private static func render(_ result: FeatureProcessResult, stdout limitedStdout: String) -> String {
        var stdout = limitedStdout
        if result.stdoutWasTruncated {
            stdout = "[stdout exceeded its safety limit; output was truncated and the producer was stopped if still running.]\n" + stdout
        }
        let stderr = result.stderrWasTruncated
            ? "[stderr exceeded its safety limit; output was truncated and the producer was stopped if still running.]\n" + result.stderr
            : result.stderr
        return FeatureProcessOutputRenderer.render(
            exitCode: result.exitCode,
            stdout: stdout,
            stderr: stderr,
            timedOut: result.timedOut
        )
    }

    /// Validates a model-supplied value that becomes a positional git argument.
    /// Rejects blanks, option-like values (leading `-`) and NUL/newline characters.
    @discardableResult
    static func positional(_ value: String, named name: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitToolsFeatureError.permissionDenied("Argument '\(name)' must not be empty.")
        }
        try rejectControlCharacters(trimmed, named: name)
        guard !trimmed.hasPrefix("-") else {
            throw GitToolsFeatureError.permissionDenied("Argument '\(name)' must not start with '-' (value would be parsed as a git option).")
        }
        return trimmed
    }

    /// Branch/refspec for push, fetch and pull: also rejects the `+` prefix (forced refspec).
    static func refspec(_ value: String, named name: String) throws -> String {
        let trimmed = try positional(value, named: name)
        guard !trimmed.hasPrefix("+") else {
            throw GitToolsFeatureError.permissionDenied("Argument '\(name)' must not start with '+' (forced refspecs bypass force-with-lease gating).")
        }
        return trimmed
    }

    /// Remote name or URL: also rejects remote helpers that execute commands.
    static func remote(_ value: String) throws -> String {
        let trimmed = try positional(value, named: "remote")
        let lowered = trimmed.lowercased()
        for helper in ["ext::", "fd::"] where lowered.hasPrefix(helper) {
            throw GitToolsFeatureError.permissionDenied("Remote helper '\(helper)' is not allowed.")
        }
        return trimmed
    }

    /// Appends `remote [branch|refspec]` after validating each value.
    static func appendRemote(to args: inout [String], remote: String?, branch: String?, refspec: String?) throws {
        guard let remote = remote?.nilIfBlank else { return }
        args.append(try Self.remote(remote))
        if let branchOrRefspec = firstNonBlank(branch, refspec) {
            args.append(try Self.refspec(branchOrRefspec, named: "branch"))
        }
    }

    static func rejectControlCharacters(_ value: String, named name: String) throws {
        if value.unicodeScalars.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) {
            throw GitToolsFeatureError.permissionDenied("Argument '\(name)' must not contain NUL or newline characters.")
        }
    }

    static func gitStashArguments(action: String, input: GitStashTool.Input) throws -> [String] {
        switch action {
        case "list":
            return ["stash", "list"]
        case "show":
            let stash = try positional(input.stash?.nilIfBlank ?? "stash@{0}", named: "stash")
            return ["stash", "show", "--stat", "--patch", stash]
        case "push", "save":
            var args = ["stash", "push"]
            if let message = input.message?.nilIfBlank {
                args.append(contentsOf: ["-m", message])
            }
            if input.includeUntracked == true {
                args.append("--include-untracked")
            }
            if let paths = input.paths, !paths.isEmpty {
                args.append("--")
                args.append(contentsOf: paths)
            }
            return args
        case "apply", "pop", "drop":
            var args = ["stash", action]
            if let stash = input.stash?.nilIfBlank {
                args.append(try positional(stash, named: "stash"))
            }
            return args
        default:
            throw GitToolsFeatureError.permissionDenied("Unsupported git stash action: \(action).")
        }
    }
}

enum GitToolsFeatureError: LocalizedError {
    case missingArgument(String)
    case permissionDenied(String)
    case invalidWorkingDirectory(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(argument):
            return "Missing required argument: \(argument)"
        case let .permissionDenied(message), let .invalidWorkingDirectory(message):
            return message
        }
    }
}
