//
//  ChatConsentCommandLine.swift
//  ZenCODE
//
//  The command of a tool-consent request as one line of text, split into the
//  runs a consent surface emphasizes.
//

/// The command of a tool-consent request as one line of text, split into runs
/// that mark the executables the consent covers, for consent surfaces that
/// emphasize them (the terminal card, the macOS app's consent sheet).
///
/// ``text`` is the request's command as the terminal card shows it: control
/// characters become spaces (newlines and tabs excepted), then the whitespace
/// is trimmed and every whitespace sequence collapses to one space, so the
/// command fits one logical line.
///
/// For `local.exec`, every occurrence of every executable the authorization
/// covers is marked: the identities the consent remembers, never harmless
/// built-ins such as `cd`, decorative `echo`/`printf`, wrappers such as `env`
/// and their options, assignments, control keywords, arguments, or heredoc
/// bodies; for a shell `-c` invocation, the commands of its payload rather
/// than the shell. For any other tool, the first word is marked. The runs are
/// presentation only: no authorization decision depends on them.
public struct ChatConsentCommandLine: Sendable, Equatable {
    /// A stretch of the command text with one emphasis.
    public struct Run: Sendable, Equatable {
        /// The text of the run.
        public let text: String
        /// Whether the run names an executable the consent covers.
        public let isExecutable: Bool
    }

    /// The runs in reading order. Adjacent runs differ in ``Run/isExecutable``
    /// and the collapsed spaces are never marked. Empty when the command has
    /// no visible text.
    public let runs: [Run]

    /// The whole one-line command: the runs joined.
    public var text: String {
        runs.map(\.text).joined()
    }

    /// Builds the line of `request.command`, marking executables according to
    /// `request.toolName`.
    public init(request: AgentToolAuthorizationRequest) {
        runs = Self.runs(command: request.command, toolName: request.toolName)
    }

    private static func runs(command: String, toolName: String) -> [Run] {
        let characters = Array(command)
        // Indices in `characters`; `nil` marks the first word instead.
        let executablePositions: Set<Int>? = toolName == "local.exec"
            ? Set(LocalExecCommandParser.executablePositions(in: command))
            : nil

        var runs: [Run] = []
        var runText = ""
        var runIsExecutable = false
        func append(_ character: Character, isExecutable: Bool) {
            if !runText.isEmpty, isExecutable != runIsExecutable {
                runs.append(Run(text: runText, isExecutable: runIsExecutable))
                runText = ""
            }
            runIsExecutable = isExecutable
            runText.append(character)
        }

        var hasText = false
        var pendingSpace = false
        var wordIndex = 0
        for (index, original) in characters.enumerated() {
            let character = LocalExecPermissionAuthorizer.sanitizedTerminalCharacter(original)
            if character.isWhitespace {
                pendingSpace = hasText
                continue
            }
            if pendingSpace {
                append(" ", isExecutable: false)
                pendingSpace = false
                wordIndex += 1
            }
            hasText = true
            append(
                character,
                isExecutable: executablePositions?.contains(index) ?? (wordIndex == 0)
            )
        }
        if !runText.isEmpty {
            runs.append(Run(text: runText, isExecutable: runIsExecutable))
        }

        // Character-wise collapsing matches sanitizing then collapsing the
        // whole string, except when a replaced control character regroups
        // with a following combining mark. Keep the exact text then, without
        // emphasis.
        let line = LocalExecPermissionAuthorizer.sanitizedForTerminal(command)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard runs.map(\.text).joined() == line else {
            return line.isEmpty ? [] : [Run(text: line, isExecutable: false)]
        }
        return runs
    }
}
