//
//  TerminalCronCommandTests+Parsing.swift
//  ZenCODECoreTests
//
//  Tests of the `/cron` command that parse its arguments and render its
//  output: the add operands, the prompt file and agent options, the list and
//  the run report.
//  Tests of this serialized suite run in file-name order: keep the name.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

extension TerminalCronCommandTests {
    // MARK: - add

    // MARK: - add: the ZenCRON host

    @Test(arguments: [
        ("0 9 * * 1-5 Summarize open PRs", "0 9 * * 1-5", "Summarize open PRs", false),
        ("@daily Hello", "@daily", "Hello", false),
        ("@daily -json report", "@daily", "-json report", false),
        ("-json @daily Hello", "@daily", "Hello", true),
        ("-json 0 9 * * 1-5 Hello world", "0 9 * * 1-5", "Hello world", true),
        ("-json @DAILY  Hello  ", "@DAILY", "Hello  ", true)
    ])
    func parseCronAddArgumentsSplitsFormatScheduleAndPrompt(
        arguments: String,
        schedule: String,
        prompt: String,
        isJSONL: Bool
    ) {
        let expected: ZenCronJobCommand.OutputFormat = isJSONL ? .jsonl : .text
        let parsed = TerminalChat.parseCronAddArguments(arguments)

        #expect(parsed?.schedule == schedule)
        #expect(parsed?.prompt == prompt)
        #expect(parsed?.outputFormat == expected)
        #expect(parsed?.promptFile == nil)
    }

    @Test(arguments: [
        "", "-json", "-json   ", "-json 0 9 * *", "0 9 * *", "-json -json report",
        "json", "JSON", "json   ", "-JSON @daily Hello", "json @daily Hello", "--agent Reviewer @daily go"
    ])
    func parseCronAddArgumentsRejectsTooFewTokensForASchedule(arguments: String) {
        #expect(TerminalChat.parseCronAddArguments(arguments) == nil)
    }

    @Test(arguments: [
        // The old keyword, and any case of it, is schedule text now.
        ("json 0 9 * * Hello", "json 0 9 * *", "Hello"),
        ("JSON 0 9 * * Hello", "JSON 0 9 * *", "Hello"),
        ("Json @daily Hello x y", "Json @daily Hello x y", ""),
        // The option is exact and case-sensitive.
        ("-JSON 0 9 * * Hello", "-JSON 0 9 * *", "Hello"),
        ("-Json 0 9 * * Hello", "-Json 0 9 * *", "Hello"),
        ("--json 0 9 * * Hello", "--json 0 9 * *", "Hello"),
        ("-jsonl 0 9 * * Hello", "-jsonl 0 9 * *", "Hello"),
        ("-json: 0 9 * * Hello", "-json: 0 9 * *", "Hello")
    ])
    func parseCronAddArgumentsTreatsAnyOtherJSONSpellingAsScheduleText(
        arguments: String,
        schedule: String,
        prompt: String
    ) {
        let parsed = TerminalChat.parseCronAddArguments(arguments)

        #expect(parsed?.outputFormat == .text)
        #expect(parsed?.agentName == nil)
        #expect(parsed?.schedule == schedule)
        #expect(parsed?.prompt == prompt)
    }

    // MARK: - parsing the prompt file option

    @Test(arguments: [
        // Unquoted: one whitespace-delimited token.
        ("@daily -f /tmp/p.md Summarize it", "@daily", "/tmp/p.md", "Summarize it", false),
        ("@daily -f /tmp/p.md", "@daily", "/tmp/p.md", "", false),
        ("@daily -f   /tmp/p.md   ", "@daily", "/tmp/p.md", "", false),
        ("@daily   -f\t/tmp/p.md\tGo  ", "@daily", "/tmp/p.md", "Go  ", false),
        ("@daily -f /tmp/it's.md go", "@daily", "/tmp/it's.md", "go", false),
        ("@daily -f relative/p.md go", "@daily", "relative/p.md", "go", false),
        ("@daily -f /tmp/p.md -json report", "@daily", "/tmp/p.md", "-json report", false),
        ("@daily -f /tmp/p.md -f /tmp/q.md", "@daily", "/tmp/p.md", "-f /tmp/q.md", false),
        ("@daily -f /tmp/p.md first\nsecond", "@daily", "/tmp/p.md", "first\nsecond", false),
        // Single-quoted: spaces allowed, no escape sequences.
        ("@daily -f '/tmp/my prompts/p.md' Summarize it", "@daily", "/tmp/my prompts/p.md", "Summarize it", false),
        ("@daily -f '/tmp/my prompts/p.md'", "@daily", "/tmp/my prompts/p.md", "", false),
        ("@daily -f '/tmp/my prompts/p.md'   Summarize", "@daily", "/tmp/my prompts/p.md", "Summarize", false),
        ("@daily -f '/tmp/my prompts/p.md'\nSummarize", "@daily", "/tmp/my prompts/p.md", "Summarize", false),
        ("@daily -f '  /tmp/p.md  ' go", "@daily", "  /tmp/p.md  ", "go", false),
        ("@daily -f 'say \"hi\"/p.md' go", "@daily", "say \"hi\"/p.md", "go", false),
        ("@daily -f '/tmp/back\\slash.md' go", "@daily", "/tmp/back\\slash.md", "go", false),
        ("@daily -f '/tmp/a\nb.md' go", "@daily", "/tmp/a\nb.md", "go", false),
        // Double-quoted.
        ("@daily -f \"/tmp/my prompts/p.md\" Summarize it", "@daily", "/tmp/my prompts/p.md", "Summarize it", false),
        ("@daily -f \"/tmp/my prompts/p.md\"", "@daily", "/tmp/my prompts/p.md", "", false),
        ("@daily -f \"/tmp/it's here/p.md\" go", "@daily", "/tmp/it's here/p.md", "go", false),
        // With the `-json` option and with five-field schedules.
        ("-json @daily -f /tmp/p.md Summarize", "@daily", "/tmp/p.md", "Summarize", true),
        ("-json @DAILY -f '/tmp/a b.md'", "@DAILY", "/tmp/a b.md", "", true),
        ("0 9 * * 1-5 -f /tmp/p.md Summarize it", "0 9 * * 1-5", "/tmp/p.md", "Summarize it", false),
        ("0 9 * * 1-5 -f '/tmp/a b.md'", "0 9 * * 1-5", "/tmp/a b.md", "", false),
        ("0 9 * * 1-5 -f \"/tmp/a b.md\" go", "0 9 * * 1-5", "/tmp/a b.md", "go", false),
        ("-json 0 9 * * 1-5 -f /tmp/p.md", "0 9 * * 1-5", "/tmp/p.md", "", true),
        ("-json */15 * * * * -f '/tmp/a b.md' go", "*/15 * * * *", "/tmp/a b.md", "go", true)
    ])
    func parseCronAddArgumentsReadsThePromptFileRightAfterTheSchedule(
        arguments: String,
        schedule: String,
        promptFile: String,
        prompt: String,
        isJSONL: Bool
    ) {
        let parsed = TerminalChat.parseCronAddArguments(arguments)

        #expect(parsed?.schedule == schedule)
        #expect(parsed?.promptFile == promptFile)
        #expect(parsed?.prompt == prompt)
        #expect(parsed?.outputFormat == (isJSONL ? .jsonl : .text))
    }

    @Test(arguments: [
        // `-f` is the option only as the first token right after the schedule.
        ("@daily Summarize -f /tmp/p.md", "@daily", "Summarize -f /tmp/p.md"),
        ("0 9 * * 1-5 report -f x", "0 9 * * 1-5", "report -f x"),
        ("-json @daily -json -f /tmp/p.md", "@daily", "-json -f /tmp/p.md"),
        // Exact and case-sensitive.
        ("@daily -F /tmp/p.md go", "@daily", "-F /tmp/p.md go"),
        ("@daily -file /tmp/p.md", "@daily", "-file /tmp/p.md"),
        ("@daily -f/tmp/p.md", "@daily", "-f/tmp/p.md"),
        ("@daily --f /tmp/p.md", "@daily", "--f /tmp/p.md"),
        ("@daily -fx /tmp/p.md", "@daily", "-fx /tmp/p.md"),
        ("@daily f /tmp/p.md", "@daily", "f /tmp/p.md"),
        ("@daily Summarize", "@daily", "Summarize")
    ])
    func parseCronAddArgumentsTreatsAnyOtherDashFAsPromptText(
        arguments: String,
        schedule: String,
        prompt: String
    ) {
        let parsed = TerminalChat.parseCronAddArguments(arguments)

        #expect(parsed?.schedule == schedule)
        #expect(parsed?.promptFile == nil)
        #expect(parsed?.prompt == prompt)
    }

    @Test(arguments: [
        // Missing path.
        "@daily -f",
        "@daily -f ",
        "@daily -f   ",
        "@daily -f\n",
        "-json @daily -f",
        "0 9 * * * -f",
        "-json 0 9 * * * -f   ",
        // Unterminated quote.
        "@daily -f '",
        "@daily -f \"",
        "@daily -f '/tmp/p.md",
        "@daily -f \"/tmp/p.md",
        "@daily -f '/tmp/p.md go",
        "@daily -f '/tmp/p.md\" go",
        "@daily -f \"/tmp/p.md' go",
        "0 9 * * * -f '/tmp/my prompts/p.md",
        // The closing quote must be followed by whitespace or the end.
        "@daily -f '/tmp/p.md'go",
        "@daily -f \"/tmp/p.md\"go",
        "@daily -f '/tmp/p.md'.bak go",
        "@daily -f '/tmp/p.md''/tmp/q.md'",
        "@daily -f '/tmp/p.md'\"x\"",
        // There are no escape sequences: a backslash does not protect the quote.
        "@daily -f \"/tmp/back\\\"slash.md\" go",
        "@daily -f '/tmp/it\\'s.md' go",
        "@daily -f '/tmp/p.md'\u{0301} go",
        "-json @daily -f '/tmp/p.md'x"
    ])
    func parseCronAddArgumentsRejectsAMalformedPromptFileOption(arguments: String) {
        #expect(TerminalChat.parseCronAddArguments(arguments) == nil)
    }

    @Test(arguments: [
        ("-agent Reviewer @daily go", "Reviewer", "@daily", "go", nil, false),
        ("-agent Reviewer 0 9 * * 1-5 go on", "Reviewer", "0 9 * * 1-5", "go on", nil, false),
        ("-json -agent Reviewer @daily go", "Reviewer", "@daily", "go", nil, true),
        ("-json -agent 'Night Shift' @daily -f /tmp/p.md go", "Night Shift", "@daily", "go", "/tmp/p.md", true),
        ("-agent \"Night Shift\" @daily go", "Night Shift", "@daily", "go", nil, false),
        ("-agent   Reviewer   @daily   go", "Reviewer", "@daily", "go", nil, false)
    ])
    func parseCronAddArgumentsReadsTheAgentBeforeTheSchedule(
        arguments: String,
        agentName: String,
        schedule: String,
        prompt: String,
        promptFile: String?,
        isJSONL: Bool
    ) {
        let parsed = TerminalChat.parseCronAddArguments(arguments)

        #expect(parsed?.agentName == agentName)
        #expect(parsed?.schedule == schedule)
        #expect(parsed?.prompt == prompt)
        #expect(parsed?.promptFile == promptFile)
        #expect(parsed?.outputFormat == (isJSONL ? .jsonl : .text))
    }

    @Test(arguments: [
        "-agent",
        "-agent ",
        "-json -agent",
        "-agent Reviewer",
        "-agent Reviewer 0 9 * *",
        "-agent 'Night Shift @daily go",
        "-agent 'Night Shift'@daily go",
        "-agent Reviewer -json @daily go"
    ])
    func parseCronAddArgumentsRejectsAMalformedAgentOption(arguments: String) {
        #expect(TerminalChat.parseCronAddArguments(arguments) == nil)
    }

    @Test
    func validatedCronAgentNameMatchesProfilesLikeZenAgent() throws {
        let agents = [
            AgentProfile(id: "night-shift", name: "Night Shift", role: .reporter),
            AgentProfile(id: "organizer", name: "Organizer", role: .organizer)
        ]

        #expect(try TerminalChat.validatedCronAgentName("Organizer", availableAgents: agents) == "Organizer")
        #expect(try TerminalChat.validatedCronAgentName("ORGANIZER", availableAgents: agents) == "ORGANIZER")
        #expect(try TerminalChat.validatedCronAgentName(" Night Shift ", availableAgents: agents) == "Night Shift")
        #expect(try TerminalChat.validatedCronAgentName("night-shift", availableAgents: agents) == "night-shift")
        #expect(try TerminalChat.validatedCronAgentName("Nïght Shîft", availableAgents: agents) == "Nïght Shîft")
        for name in ["Nobody", "", "   ", "Night\nShift", "Night"] {
            #expect(throws: AgentConfigurationError.self, "name: \(name)") {
                try TerminalChat.validatedCronAgentName(name, availableAgents: agents)
            }
        }
    }

    // MARK: - add with a prompt file

    @Test
    func validatedCronPromptFileKeepsASingleLinePathAsGiven() throws {
        #expect(try TerminalChat.validatedCronPromptFile("/tmp/my prompts/it's 100%.md") == "/tmp/my prompts/it's 100%.md")
        for path in ["/tmp/a\nb", "/tmp/a\rb", "/tmp/a\r\nb", "\n", "/tmp/a\n"] {
            #expect(
                throws: ZenCrontabError.invalidPromptFile(reason: "its path contains a line break"),
                "path: \(path.debugDescription)"
            ) {
                try TerminalChat.validatedCronPromptFile(path)
            }
        }
    }

    // MARK: - remove

    // MARK: - mailto

    // MARK: - list

    @Test
    func renderCronListShowsEveryKindOfItem() throws {
        let text = [
            ZenCrontabDocument.beginMarker,
            "PATH=/opt/zen/bin:/usr/bin",
            "MAILTO=ops@example.com",
            "# zencode-cron id=11111111-1111-1111-1111-111111111111 created=2026-01-02T03:04:05Z",
            "0 9 * * 1-5 '/usr/local/bin/zen' --agent 'Builder' --working-directory '/work/a b' --jsonl -p 'Check CI'",
            "# zencode-cron id=33333333-3333-3333-3333-333333333333 created=2026-01-02T03:04:05Z",
            "@weekly zen --working-directory '/work/c' -p 'Weekly digest'",
            "# zencode-cron id=22222222-2222-2222-2222-222222222222 created=2026-01-02T03:04:05Z",
            "@daily /usr/bin/true",
            "not a cron line",
            ZenCrontabDocument.endMarker,
            ""
        ].joined(separator: "\n")

        // The `PATH=` header line is not an item: the table is the same with or without it.
        let rendered = TerminalChat.renderCronList(try ZenCrontabDocument.parse(text))

        #expect(
            rendered == """
            Scheduled prompts — MAILTO: ops@example.com
              1. 0 9 * * 1-5 · agent: Builder · dir: /work/a b · output: JSONL · prompt: Check CI
              2. @weekly · agent: default · dir: /work/c · output: text · prompt: Weekly digest
              3. @daily · command: /usr/bin/true
              4. (unrecognized) not a cron line
            Results are mailed by cron; set the recipient with /cron mailto <address>.

            """
        )
    }

    // MARK: - errors and unknown subcommands

    // MARK: - run

    @Test
    func renderCronRunReportShowsTheCompletedMessage() {
        let report = TerminalChat.renderCronRunReport(
            number: 3,
            outcome: ZenCronRunOutcome(
                exitStatus: 0,
                stdout: [
                    #"{"type":"run.started","schema":1}"#,
                    #"{"type":"message.completed","text":"Two PRs are open.\nBoth pass CI."}"#,
                    #"{"type":"run.completed"}"#,
                    ""
                ].joined(separator: "\n"),
                stderr: "",
                duration: .milliseconds(12_340),
                wasTerminated: false
            ),
            outputFormat: .jsonl
        )

        #expect(
            report == """
            Scheduled prompt #3 finished in 12.3s with exit status 0.
            Result:
            Two PRs are open.
            Both pass CI.

            """
        )
    }

    @Test
    func renderCronRunReportShowsTheErrorRecordAndTheStderrTail() {
        let stderr = (1...25).map { "line \($0)" }.joined(separator: "\n") + "\n\n"
        let report = TerminalChat.renderCronRunReport(
            number: 1,
            outcome: ZenCronRunOutcome(
                exitStatus: 1,
                stdout: #"{"type":"error","category":"provider","message":"Model unavailable"}"# + "\n",
                stderr: stderr,
                duration: .milliseconds(450),
                wasTerminated: false
            ),
            outputFormat: .jsonl
        )

        let expectedTail = (6...25).map { "line \($0)" }.joined(separator: "\n")
        #expect(
            report == """
            Scheduled prompt #1 finished in 0.5s with exit status 1.
            Error (provider): Model unavailable
            stderr (last 20 lines):
            \(expectedTail)

            """
        )
    }

    @Test
    func renderCronRunReportOfATextRunShowsTheTrimmedAnswer() {
        let report = TerminalChat.renderCronRunReport(
            number: 3,
            outcome: ZenCronRunOutcome(
                exitStatus: 0,
                stdout: "\n  Two PRs are open.\nBoth pass CI.\n\n",
                stderr: "",
                duration: .milliseconds(12_340),
                wasTerminated: false
            ),
            outputFormat: .text
        )

        #expect(
            report == """
            Scheduled prompt #3 finished in 12.3s with exit status 0.
            Result:
            Two PRs are open.
            Both pass CI.

            """
        )
    }
}
