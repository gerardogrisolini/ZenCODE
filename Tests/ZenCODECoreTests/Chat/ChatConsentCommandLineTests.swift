//
//  ChatConsentCommandLineTests.swift
//  ZenCODE
//
//  The one-line command of a consent request and the runs that mark the
//  executables the consent covers.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct ChatConsentCommandLineTests {
    private typealias Run = ChatConsentCommandLine.Run

    private func line(_ command: String, toolName: String = "local.exec") -> ChatConsentCommandLine {
        ChatConsentCommandLine(request: AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call",
            toolName: toolName,
            title: "Run command",
            kind: "shell",
            command: command,
            workingDirectory: "/tmp/project"
        ))
    }

    /// The text the consent card showed before the runs: sanitized, then
    /// collapsed to one line.
    private func legacyText(_ command: String) -> String {
        LocalExecPermissionAuthorizer.sanitizedForTerminal(command)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    @Test(arguments: [
        "swift test --filter One",
        "  git push --force-with-lease\n  origin main  ",
        "cd /x &&\tgrep -rn foo Setup |\n\n head -30",
        "rm\u{1B}[2J -rf\r/",
        "a\u{7F}b\u{85}c\u{9F}d\u{07}e",
        "printf '界🙂'\r\n| cat",
        "cat <<'EOF'\nrm -rf /\nEOF",
        "",
        " \n\t ",
    ])
    func textIsTheSanitizedSingleLineCommand(command: String) {
        #expect(line(command).text == legacyText(command))
        #expect(line(command, toolName: "local.delete").text == legacyText(command))
    }

    @Test
    func everyCoveredExecutableIsMarked() {
        #expect(
            line(#"cd /x && grep -rn -i "invalid\|rewrite" Setup/A.swift | head -30; grep -rn "agents.json" Setup | head"#).runs == [
                Run(text: "cd /x && ", isExecutable: false),
                Run(text: "grep", isExecutable: true),
                Run(text: #" -rn -i "invalid\|rewrite" Setup/A.swift | "#, isExecutable: false),
                Run(text: "head", isExecutable: true),
                Run(text: " -30; ", isExecutable: false),
                Run(text: "grep", isExecutable: true),
                Run(text: #" -rn "agents.json" Setup | "#, isExecutable: false),
                Run(text: "head", isExecutable: true),
            ]
        )
        // Collapsed whitespace is never marked, and heredoc bodies are not
        // commands.
        #expect(
            line("cd /x &&\n  python3 - <<'EOF'\nimport os\nrm -rf y\nEOF").runs == [
                Run(text: "cd /x && ", isExecutable: false),
                Run(text: "python3", isExecutable: true),
                Run(text: " - <<'EOF' import os rm -rf y EOF", isExecutable: false),
            ]
        )
        // A shell `-c` invocation: the payload's commands, not the shell.
        #expect(
            line("bash -c 'rm -rf x'").runs == [
                Run(text: "bash -c '", isExecutable: false),
                Run(text: "rm", isExecutable: true),
                Run(text: " -rf x'", isExecutable: false),
            ]
        )
        // A replaced control character splits a name like any space.
        #expect(
            line("rm\u{1B}[2J -rf\r/").runs == [
                Run(text: "rm", isExecutable: true),
                Run(text: " ", isExecutable: false),
                Run(text: "[2J", isExecutable: true),
                Run(text: " -rf ", isExecutable: false),
                Run(text: "/", isExecutable: true),
            ]
        )
        // Nothing the consent covers: nothing marked.
        #expect(line("cd /tmp && echo done").runs == [Run(text: "cd /tmp && echo done", isExecutable: false)])
    }

    @Test
    func otherToolsMarkTheFirstWord() {
        #expect(
            line("  git push\n origin  main", toolName: "git.push").runs == [
                Run(text: "git", isExecutable: true),
                Run(text: " push origin main", isExecutable: false),
            ]
        )
        #expect(
            line("Sources/Old", toolName: "local.delete").runs == [
                Run(text: "Sources/Old", isExecutable: true),
            ]
        )
        // `cd` is only skipped by the `local.exec` parser.
        #expect(line("cd /tmp", toolName: "local.delete").runs.first == Run(text: "cd", isExecutable: true))
    }

    @Test
    func anEmptyCommandHasNoRuns() {
        #expect(line("").runs.isEmpty)
        #expect(line("").text.isEmpty)
        #expect(line(" \n\t\u{1B}", toolName: "local.delete").runs.isEmpty)
    }
}
