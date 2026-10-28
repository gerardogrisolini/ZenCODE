//
//  ZenCronJobCommand.swift
//  ZenCODE
//

import Foundation

/// The shell command ZenCODE writes on a crontab line for one scheduled
/// prompt, plus its exact inverse.
///
/// The encoded grammar is fixed-order and single-quoted, except for the bare
/// `zen` executable (cron finds it through the `PATH=` line of the ZenCODE
/// block, see `ZenCrontabDocument.defaultPath`):
///
///     [ZENCODE_SUPPORT_DIRECTORY='<dir>' ]<exe> [--agent '<name>'] --working-directory '<dir>' [--jsonl] [-f '<path>'] [-p '<prompt>']
///
/// The lines `/cron add` writes now run ZenCRON, the stable host that starts
/// `zen`, so `<exe>` is the absolute path of ZenCRON written single-quoted
/// (`'/…/bin/ZenCRON'`); ZenCRON finds `zen` through the `PATH=` line of the
/// ZenCODE block, see `ZenCrontabDocument.defaultPath`. The bare `zen` belongs
/// to the lines written before ZenCRON existed: cron finds it through that same
/// `PATH=` line, and they stay valid.
///
/// Without `--jsonl` the run prints only the final answer text on standard
/// output, which cron mails as is; with it, standard output holds the JSONL
/// records of the run.
///
/// `-f` names a prompt file that `zen` reads at every run (its content is never
/// stored on the crontab line); when `-p` is also present, it is the
/// instruction and the file is its context. At least one of the two is
/// required, `-f` first: a line with neither is not a ZenCODE job. Lines
/// without `-f` are encoded exactly as before it existed.
///
/// An executable other than `zen` (a ZenCRON path written by `/cron add`, or a
/// line hand-edited to a full path) is a single-quoted word: `'<exe>'`.
///
/// `decode(_:)` accepts only that grammar, so anything a user hand-edited into
/// another shape is reported as "not a ZenCODE job" instead of being guessed.
/// All scanning is done on Unicode scalars so that combining marks following a
/// quote never merge with it.
struct ZenCronJobCommand: Sendable, Equatable {
    /// The bare executable name of the lines written before ZenCRON existed;
    /// cron searches it on the `PATH` of the ZenCODE block. New lines run the
    /// absolute path of ZenCRON instead (see `ZenCRONInstallation`).
    static let zenExecutable = "zen"

    /// `zen` (written bare, by lines that predate ZenCRON) or a path (written
    /// single-quoted, the ZenCRON host of new lines).
    var executable: String
    var supportDirectory: String?
    var agentName: String?
    var workingDirectory: String
    var outputFormat: OutputFormat
    /// Absolute path of the prompt file (`-f`), read by `zen` at every run.
    ///
    /// Invariant: at least one of `promptFile` and `prompt` is non-nil.
    var promptFile: String? = nil
    /// The instruction (`-p`); with a `promptFile` it is optional and the file
    /// is its context.
    ///
    /// Invariant: at least one of `promptFile` and `prompt` is non-nil.
    var prompt: String?

    /// What the scheduled run writes on standard output, and so what cron
    /// mails.
    enum OutputFormat: Sendable, Equatable {
        /// Plain `zen`: only the final answer text.
        case text
        /// `zen --jsonl`: the JSONL records of the run.
        case jsonl
    }

    // MARK: - Encoding

    /// Returns the shell command (not yet escaped for cron; see `cronEscape`).
    ///
    /// The prompt and the prompt file path must be single lines: line breaks
    /// would split the crontab line, so callers must reject them before
    /// scheduling.
    func encode() -> String {
        var command = ""
        if let supportDirectory {
            command += "ZENCODE_SUPPORT_DIRECTORY=\(Self.shellQuote(supportDirectory)) "
        }
        command += executable == Self.zenExecutable ? executable : Self.shellQuote(executable)
        if let agentName {
            command += " --agent \(Self.shellQuote(agentName))"
        }
        command += " --working-directory \(Self.shellQuote(workingDirectory))"
        if outputFormat == .jsonl {
            command += " --jsonl"
        }
        if let promptFile {
            command += " -f \(Self.shellQuote(promptFile))"
        }
        if let prompt {
            command += " -p \(Self.shellQuote(prompt))"
        }
        return command
    }

    /// Wraps `value` in single quotes, rewriting every `'` as `'\''`.
    static func shellQuote(_ value: String) -> String {
        var result = "'"
        for scalar in value.unicodeScalars {
            if scalar == "'" {
                result += "'\\''"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        result += "'"
        return result
    }

    // MARK: - Decoding

    /// Parses a command produced by `encode()`; returns `nil` for any other
    /// shape (different order, unquoted values other than the bare `zen`
    /// executable, extra arguments, line breaks, neither `-f` nor `-p`).
    static func decode(_ shellCommand: String) -> ZenCronJobCommand? {
        var cursor = Cursor(shellCommand)

        var supportDirectory: String?
        if cursor.consume("ZENCODE_SUPPORT_DIRECTORY=") {
            guard let value = cursor.readQuoted(), cursor.consume(" ") else { return nil }
            supportDirectory = value
        }

        // The bare word must be exactly `zen`: any other word, such as `zenith`
        // or `ls`, fails the fixed grammar that follows. Otherwise the
        // executable is a quoted word.
        let executable: String
        if cursor.consume(zenExecutable) {
            executable = zenExecutable
        } else if let quoted = cursor.readQuoted() {
            executable = quoted
        } else {
            return nil
        }

        var agentName: String?
        if cursor.consume(" --agent ") {
            guard let value = cursor.readQuoted() else { return nil }
            agentName = value
        }

        guard cursor.consume(" --working-directory "),
              let workingDirectory = cursor.readQuoted()
        else { return nil }

        // Lines written before the text format existed always carry `--jsonl`.
        let outputFormat: OutputFormat = cursor.consume(" --jsonl") ? .jsonl : .text

        var promptFile: String?
        if cursor.consume(" -f ") {
            guard let value = cursor.readQuoted() else { return nil }
            promptFile = value
        }

        var prompt: String?
        if cursor.consume(" -p ") {
            guard let value = cursor.readQuoted() else { return nil }
            prompt = value
        }

        // A job runs a prompt, a prompt file, or both; nothing else may follow.
        guard promptFile != nil || prompt != nil, cursor.isAtEnd else { return nil }

        return ZenCronJobCommand(
            executable: executable,
            supportDirectory: supportDirectory,
            agentName: agentName,
            workingDirectory: workingDirectory,
            outputFormat: outputFormat,
            promptFile: promptFile,
            prompt: prompt
        )
    }

    /// A strict left-to-right reader over the Unicode scalars of a command.
    private struct Cursor {
        private let scalars: [Unicode.Scalar]
        private var index = 0

        init(_ text: String) {
            scalars = Array(text.unicodeScalars)
        }

        var isAtEnd: Bool { index >= scalars.count }

        /// Consumes `literal` when it is next; otherwise leaves the cursor unchanged.
        mutating func consume(_ literal: String) -> Bool {
            let expected = Array(literal.unicodeScalars)
            guard index + expected.count <= scalars.count,
                  Array(scalars[index..<(index + expected.count)]) == expected
            else { return false }
            index += expected.count
            return true
        }

        /// Reads one word written by `shellQuote`: `'…'` segments joined by
        /// `\'` (an escaped quote). Anything else, including adjacent quoted
        /// segments, an unterminated quote, or a line break, yields `nil`.
        mutating func readQuoted() -> String? {
            var value = String.UnicodeScalarView()
            while true {
                guard index < scalars.count, scalars[index] == "'" else { return nil }
                index += 1
                while true {
                    guard index < scalars.count else { return nil }
                    let scalar = scalars[index]
                    index += 1
                    if scalar == "'" { break }
                    if scalar == "\n" || scalar == "\r" { return nil }
                    value.append(scalar)
                }
                // `'\''` is the closing quote, an escaped quote, and the next opening quote.
                if index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "'" {
                    value.append("'")
                    index += 2
                    continue
                }
                return String(value)
            }
        }
    }

    // MARK: - Cron percent escaping

    /// Escapes every `%` as `\%`: cron turns an unescaped `%` into a newline
    /// that is fed to the command's standard input.
    static func cronEscape(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "%" {
                result.append("\\")
            }
            result.append(scalar)
        }
        return String(result)
    }

    /// Reverses `cronEscape`. Returns `nil` when an unescaped `%` remains,
    /// because cron would have split the command at that point.
    static func cronUnescape(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var position = 0
        while position < scalars.count {
            let scalar = scalars[position]
            if scalar == "%" {
                return nil
            }
            if scalar == "\\", position + 1 < scalars.count, scalars[position + 1] == "%" {
                result.append("%")
                position += 2
                continue
            }
            result.append(scalar)
            position += 1
        }
        return String(result)
    }

    // MARK: - Executable

    /// The first executable `zen` in the `:`-separated `path`. Empty and
    /// relative entries are ignored: they would depend on the working
    /// directory of the job, not on a fixed location. `isExecutableFile`
    /// answers whether a candidate path is executable; by default it asks
    /// the file system.
    static func locateZen(
        onPath path: String,
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        for entry in path.split(separator: ":", omittingEmptySubsequences: true) {
            guard entry.hasPrefix("/") else { continue }
            var directory = String(entry)
            while directory.count > 1, directory.hasSuffix("/") {
                directory.removeLast()
            }
            let candidate = directory == "/" ? "/\(zenExecutable)" : "\(directory)/\(zenExecutable)"
            if isExecutableFile(candidate) {
                return candidate
            }
        }
        return nil
    }
}
