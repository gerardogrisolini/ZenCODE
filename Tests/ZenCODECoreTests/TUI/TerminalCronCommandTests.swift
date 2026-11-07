//
//  TerminalCronCommandTests.swift
//  ZenCODECoreTests
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// In-memory crontab that records every access. No test uses the system
/// `crontab`: the real one is never read or written.
private final class FakeCrontabClient: CrontabClient {
    private struct State {
        var text: String
        var writes: [String] = []
        var readCount = 0
    }

    private let state: Mutex<State>
    private let readError: (any Error & Sendable)?
    private let writeError: (any Error & Sendable)?

    init(
        text: String,
        readError: (any Error & Sendable)? = nil,
        writeError: (any Error & Sendable)? = nil
    ) {
        state = Mutex(State(text: text))
        self.readError = readError
        self.writeError = writeError
    }

    var writes: [String] { state.withLock { $0.writes } }
    var readCount: Int { state.withLock { $0.readCount } }

    func readCrontab() throws -> String {
        let text = state.withLock { state -> String in
            state.readCount += 1
            return state.text
        }
        if let readError { throw readError }
        return text
    }

    func writeCrontab(_ text: String) throws {
        if let writeError { throw writeError }
        state.withLock { state in
            state.writes.append(text)
            state.text = text
        }
    }
}

/// Stand-in for the cron runner: records each call and, unless created
/// released, holds it until `release()` before returning `outcome`. No test
/// uses the system runner: no job is ever launched.
private final class FakeCronJobRunner: CronJobRunning {
    struct Call: Equatable {
        let cronCommand: String
        let environment: [String: String]
        let homeDirectory: URL
    }

    private struct State {
        var calls: [Call] = []
        var isReleased: Bool
        var pendingRuns: [CheckedContinuation<Void, Never>] = []
        var invocationWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>
    private let outcome: ZenCronRunOutcome

    init(outcome: ZenCronRunOutcome = FakeCronJobRunner.defaultOutcome, isReleased: Bool = false) {
        state = Mutex(State(isReleased: isReleased))
        self.outcome = outcome
    }

    static let defaultOutcome = ZenCronRunOutcome(
        exitStatus: 0,
        stdout: #"{"type":"message.completed","text":"All good"}"# + "\n",
        stderr: "",
        duration: .milliseconds(1_250),
        wasTerminated: false
    )

    var calls: [Call] { state.withLock { $0.calls } }

    func run(
        cronCommand: String,
        environment: [String: String],
        homeDirectory: URL
    ) async throws -> ZenCronRunOutcome {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.calls.append(
                Call(cronCommand: cronCommand, environment: environment, homeDirectory: homeDirectory)
            )
            defer { state.invocationWaiters = [] }
            return state.invocationWaiters
        }
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                guard !state.isReleased else { return true }
                state.pendingRuns.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return outcome
    }

    /// Lets every held run, and every later one, return.
    func release() {
        let pending = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isReleased = true
            defer { state.pendingRuns = [] }
            return state.pendingRuns
        }
        pending.forEach { $0.resume() }
    }

    /// Returns once `run` has been called at least once.
    func waitUntilInvoked() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                guard state.calls.isEmpty else { return true }
                state.invocationWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// Stand-in for the `zen` search of `/cron add`: records every `PATH` it is
/// asked about and answers with a fixed result. No test depends on what is
/// installed on the machine.
private final class FakeZenLocator: Sendable {
    private let result: String?
    private let requests = Mutex<[String]>([])

    init(result: String? = "/fake/bin/zen") {
        self.result = result
    }

    var requestedPaths: [String] { requests.withLock { $0 } }

    func locate(onPath path: String) -> String? {
        requests.withLock { $0.append(path) }
        return result
    }
}

/// Stand-in for the ZenCRON check of `/cron add`: counts the calls and answers
/// with a fixed result. No test depends on a ZenCRON built on the machine, and
/// no test starts a real process.
private final class FakeZenCRONLocator: Sendable {
    static let path = "/fake/support/bin/ZenCRON"
    static let version = "ZenCRON 1"

    private let outcome: Result<ZenCRONInstallation.InstalledExecutable, ZenCrontabError>
    private let calls = Mutex(0)

    init(
        outcome: Result<ZenCRONInstallation.InstalledExecutable, ZenCrontabError> = .success(
            ZenCRONInstallation.InstalledExecutable(path: FakeZenCRONLocator.path, version: FakeZenCRONLocator.version)
        )
    ) {
        self.outcome = outcome
    }

    var callCount: Int { calls.withLock { $0 } }

    func locate() throws -> ZenCRONInstallation.InstalledExecutable {
        calls.withLock { $0 += 1 }
        return try outcome.get()
    }
}

@ChatSessionActor
@Suite(.serialized)
struct TerminalCronCommandTests {
    private static let userLines = [
        "# m h dom mon dow command",
        "MAILTO=root",
        "",
        "0 3 * * * /usr/bin/backup --full",
        "\t# indented comment  ",
        "*/5 * * * * /usr/local/bin/ping >/dev/null 2>&1"
    ]
    private static let userCrontab = userLines.joined(separator: "\n") + "\n"

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

    // MARK: - Command surface

    @Test
    func cronCompletionListsEverySubcommand() async throws {
        let arguments = TerminalPromptCompletionCatalog.argumentSuggestions(for: "/cron")
        #expect(arguments.map(\.command) == ["list", "add", "remove", "run", "mailto"])
        #expect(arguments.map(\.requiresArgument) == [false, true, true, true, false])

        let (terminal, _) = try makeTerminal(crontab: "")
        let matches = TerminalPromptCompletion.matches(
            buffer: Array("/cron m"),
            cursorIndex: 7,
            commands: terminal.commandSuggestionsForCurrentAgent()
        )
        #expect(matches.map(\.command) == ["mailto"])
    }

    // MARK: - Completion explains the parameters

    @Test(arguments: [
        ("/cron add ", [
            "@hourly", "@daily", "@weekly", "@monthly", "@yearly", "@reboot",
            "0 9 * * 1-5", "*/15 * * * *", "30 18 * * *", "-json", "-agent"
        ]),
        ("/cron ADD ", [
            "@hourly", "@daily", "@weekly", "@monthly", "@yearly", "@reboot",
            "0 9 * * 1-5", "*/15 * * * *", "30 18 * * *", "-json", "-agent"
        ]),
        // `-json` completes from a prefix starting with `-`, in the first slot only;
        // the options are exact and case-sensitive, `-json` first.
        ("/cron add -", ["-json", "-agent"]),
        ("/cron ADD -", ["-json", "-agent"]),
        ("/cron add -j", ["-json"]),
        ("/cron add -js", ["-json"]),
        ("/cron add -jso", ["-json"]),
        ("/cron add -json", ["-json"]),
        ("/cron ADD -j", ["-json"]),
        ("/cron add -J", ["<minute>"]),
        ("/cron add -JS", ["<minute>"]),
        ("/cron add -JSON", ["<minute>"]),
        ("/cron add -jsonx", ["<minute>"]),
        ("/cron add -x", ["<minute>"]),
        // The old keyword is not completed any more, in any case.
        ("/cron add j", ["<minute>"]),
        ("/cron add J", ["<minute>"]),
        ("/cron add js", ["<minute>"]),
        ("/cron add JS", ["<minute>"]),
        ("/cron add jso", ["<minute>"]),
        ("/cron add json", ["<minute>"]),
        ("/cron add JSON", ["<minute>"]),
        ("/cron ADD j", ["<minute>"]),
        ("/cron add jsonx", ["<minute>"]),
        ("/cron add s", ["<minute>"]),
        // It is plain text: the first field of a schedule.
        ("/cron add json ", ["<hour>"]),
        ("/cron add JSON ", ["<hour>"]),
        ("/cron add JSON @daily Summarize open PRs", ["<day-of-week>"]),
        // After `-json` the schedule is completed as for a text job, `-json` is not offered again.
        ("/cron add -json ", [
            "@hourly", "@daily", "@weekly", "@monthly", "@yearly", "@reboot",
            "0 9 * * 1-5", "*/15 * * * *", "30 18 * * *", "-agent"
        ]),
        ("/cron add -json -", ["-agent"]),
        ("/cron add -json -a", ["-agent"]),
        ("/cron add -json -agent", ["-agent"]),
        ("/cron add -json -j", ["<minute>"]),
        ("/cron add -json -json", ["<minute>"]),
        ("/cron add -json --ag", ["<minute>"]),
        // `-agent` completes from a prefix starting with `-`, before the schedule only.
        ("/cron add -a", ["-agent"]),
        ("/cron add -ag", ["-agent"]),
        ("/cron add -agent", ["-agent"]),
        ("/cron add --", ["<minute>"]),
        ("/cron add --a", ["<minute>"]),
        ("/cron add --agent", ["<minute>"]),
        ("/cron add -A", ["<minute>"]),
        ("/cron add -Agent", ["<minute>"]),
        ("/cron add -agentx", ["<minute>"]),
        ("/cron add 0 -", ["<hour>"]),
        // `--agent` is the flag of `zen`, not an option here: plain schedule text.
        ("/cron add --agent ", ["<hour>"]),
        ("/cron add --agent Rev", ["<hour>"]),
        // Once `-agent` is typed: the name, then the schedule without `-json` or `-agent`.
        ("/cron add -agent ", ["<agent>"]),
        ("/cron add -agent Rev", ["<agent>"]),
        ("/cron add -json -agent ", ["<agent>"]),
        ("/cron add -agent 'Night ", ["<agent>"]),
        ("/cron add -agent Reviewer ", [
            "@hourly", "@daily", "@weekly", "@monthly", "@yearly", "@reboot",
            "0 9 * * 1-5", "*/15 * * * *", "30 18 * * *"
        ]),
        ("/cron add -agent 'Night Shift' ", [
            "@hourly", "@daily", "@weekly", "@monthly", "@yearly", "@reboot",
            "0 9 * * 1-5", "*/15 * * * *", "30 18 * * *"
        ]),
        ("/cron add -agent Reviewer -", ["<minute>"]),
        ("/cron add -agent Reviewer -json", ["<minute>"]),
        ("/cron add -agent Reviewer j", ["<minute>"]),
        ("/cron add -agent Reviewer @d", ["@daily"]),
        ("/cron add -agent Reviewer 0 ", ["<hour>"]),
        ("/cron add -agent 'Night Shift' 0 9 * * ", ["<day-of-week>"]),
        ("/cron add -json -agent Reviewer @daily ", ["<prompt>", "-f"]),
        ("/cron add -agent Reviewer 0 9 * * 1-5 -f ", ["<path>"]),
        ("/cron add -agent Reviewer @daily Summarize", ["<prompt>"]),
        ("/cron add -json @", ["@hourly", "@daily", "@weekly", "@monthly", "@yearly", "@reboot"]),
        ("/cron add -json @d", ["@daily"]),
        ("/cron add -json @mid", ["@midnight"]),
        ("/cron add -json j", ["<minute>"]),
        ("/cron add -json 0", ["<minute>"]),
        ("/cron add -json 0 ", ["<hour>"]),
        ("/cron add -json 0 9", ["<hour>"]),
        ("/cron add -json 0 9 ", ["<day-of-month>"]),
        ("/cron add -json 0 9 * ", ["<month>"]),
        ("/cron add -json 0 9 * * ", ["<day-of-week>"]),
        ("/cron add -json 0 9 * * 1-5 ", ["<prompt>", "-f"]),
        ("/cron add -json 0 9 * * 1-5 Summ", ["<prompt>"]),
        ("/cron add -json @daily ", ["<prompt>", "-f"]),
        ("/cron add -json @daily Summarize open PRs", ["<prompt>"]),
        // Later slots never offer the options.
        ("/cron add @daily j", ["<prompt>"]),
        ("/cron add @daily -json", ["<prompt>"]),
        ("/cron add @daily -agent", ["<prompt>"]),
        ("/cron add 0 j", ["<hour>"]),
        ("/cron add 0 -json", ["<hour>"]),
        ("/cron add 0 -agent", ["<hour>"]),
        ("/cron add @", ["@hourly", "@daily", "@weekly", "@monthly", "@yearly", "@reboot"]),
        ("/cron add @d", ["@daily"]),
        ("/cron add @D", ["@daily"]),
        ("/cron ADD @d", ["@daily"]),
        ("/cron add @daily", ["@daily"]),
        ("/cron add @m", ["@monthly", "@midnight"]),
        ("/cron add @mid", ["@midnight"]),
        ("/cron add @a", ["@annually"]),
        ("/cron add @nope", []),
        ("/cron add 0", ["<minute>"]),
        ("/cron add */15", ["<minute>"]),
        ("/cron add 0 ", ["<hour>"]),
        ("/cron add 0 9", ["<hour>"]),
        ("/cron add 0 9 ", ["<day-of-month>"]),
        ("/cron add 0 9 * ", ["<month>"]),
        ("/cron add 0 9 * * ", ["<day-of-week>"]),
        ("/cron add 0 9 * * 1", ["<day-of-week>"]),
        ("/cron add 0 9 * * 1-5 ", ["<prompt>", "-f"]),
        ("/cron add 0 9 * * 1-5 Summ", ["<prompt>"]),
        ("/cron add 0 9 * * 1-5 Summarize open PRs", ["<prompt>"]),
        ("/cron add @daily ", ["<prompt>", "-f"]),
        ("/cron add @daily Summarize open PRs", ["<prompt>"]),
        ("/cron ADD @daily Summarize open PRs", ["<prompt>"]),
        // `-f` is offered only in the first slot after the schedule, and only as a
        // prefix of `-f` itself (case-sensitive).
        ("/cron add @daily -", ["-f"]),
        ("/cron add @daily -f", ["-f"]),
        ("/cron add @daily -F", ["<prompt>"]),
        ("/cron add @daily -x", ["<prompt>"]),
        ("/cron add @daily --", ["<prompt>"]),
        ("/cron add @daily -fo", ["<prompt>"]),
        ("/cron add @daily f", ["<prompt>"]),
        ("/cron add 0 9 * * 1-5 -", ["-f"]),
        ("/cron add 0 9 * * 1-5 -f", ["-f"]),
        ("/cron add -json @daily -", ["-f"]),
        ("/cron add -json 0 9 * * 1-5 -f", ["-f"]),
        ("/cron ADD @daily -f", ["-f"]),
        ("/cron add @daily Summarize -", ["<prompt>"]),
        ("/cron add @daily Summarize -f", ["<prompt>"]),
        ("/cron add @daily Summarize -f ", ["<prompt>"]),
        ("/cron add @daily -F /tmp/p.md ", ["<prompt>"]),
        // Once `-f` is the first operand: the path, then the optional instruction.
        ("/cron add @daily -f ", ["<path>"]),
        ("/cron add @daily -f /tm", ["<path>"]),
        ("/cron add @daily -f -", ["<path>"]),
        ("/cron add @daily -f /tmp/p.md ", ["<prompt>"]),
        ("/cron add @daily -f /tmp/p.md Summ", ["<prompt>"]),
        ("/cron add @daily -f /tmp/p.md -f", ["<prompt>"]),
        ("/cron add @daily -f /tmp/p.md Summarize open PRs", ["<prompt>"]),
        ("/cron ADD @daily -f ", ["<path>"]),
        ("/cron add 0 9 * * 1-5 -f ", ["<path>"]),
        ("/cron add 0 9 * * 1-5 -f /tmp/p.md ", ["<prompt>"]),
        ("/cron add -json @daily -f ", ["<path>"]),
        ("/cron add -json 0 9 * * 1-5 -f /tmp/p.md ", ["<prompt>"]),
        // A quoted path with spaces splits into several words here, which only
        // changes which guide is shown for the slots inside it.
        ("/cron add @daily -f '/tmp/my ", ["<prompt>"]),
        ("/cron add @daily -f '/tmp/my prompts/p.md' ", ["<prompt>"]),
        ("/cron remove ", ["<n>"]),
        ("/cron remove 2", ["<n>"]),
        ("/cron REMOVE ", ["<n>"]),
        ("/cron remove 2 ", []),
        ("/cron run ", ["<n>"]),
        ("/cron run 2 ", []),
        ("/cron mailto ", ["<address>", "none", "default"]),
        ("/cron MAILTO ", ["<address>", "none", "default"]),
        ("/cron mailto n", ["none"]),
        ("/cron mailto none", ["none"]),
        ("/cron mailto D", ["default"]),
        ("/cron mailto ops@", ["<address>"]),
        ("/cron mailto none ", []),
        ("/cron list ", []),
        ("/cron list x", []),
        ("/cron bogus ", []),
        ("/cron bogus x", [])
    ])
    func cronCompletionFollowsTheSlotUnderTheCursor(text: String, expected: [String]) {
        #expect(cronCompletions(text).map(\.command) == expected, "typed: \(text)")
    }

    @Test
    func completionOnAFieldFollowsTheCursorNotTheEndOfTheLine() {
        let line = "/cron add 0 9 * * 1-5 Summarize"

        // After the `0`: still the first field.
        #expect(cronCompletions(line, cursorIndex: 11).map(\.command) == ["<minute>"])
        // Right before the `9`: the second field, empty prefix.
        #expect(cronCompletions(line, cursorIndex: 12).map(\.command) == ["<hour>"])
        // Inside the prompt.
        #expect(cronCompletions(line, cursorIndex: 27).map(\.command) == ["<prompt>"])

        let completion = TerminalPromptCompletion.completion(
            buffer: Array(line),
            cursorIndex: 13
        )
        #expect(
            completion?.kind == .laterArgument(command: "/cron", precedingArguments: ["add", "0"])
        )
        #expect(completion?.prefix == "9")
        #expect(completion?.replacementRange == 12..<13)
    }

    @Test
    func everyAliasAndExampleOfTheScheduleSlotIsAcceptedByTheScheduleParser() throws {
        var schedules = TerminalPromptCompletionCatalog.cronScheduleExamples.map(\.command)
        // `-json` and `-agent` are options, not schedules.
        schedules += cronCompletions("/cron add ").map(\.command).filter { $0 != "-json" && $0 != "-agent" }
        // The synonyms only show once a letter is typed.
        schedules += cronCompletions("/cron add @a").map(\.command)
        schedules += cronCompletions("/cron add @mid").map(\.command)

        #expect(schedules.count >= 14)
        for schedule in schedules {
            _ = try ZenCronSchedule(parsing: schedule)
        }
    }

    @Test
    func cronOperandsAreOfferedOnlyWhenTheCommandIsAvailableToTheAgent() throws {
        let (terminal, _) = try makeTerminal(crontab: "")
        let available = terminal.commandSuggestionsForCurrentAgent()
        #expect(available.contains { $0.command == "/cron" })
        #expect(
            TerminalPromptCompletion.matches(
                buffer: Array("/cron mailto "),
                cursorIndex: 13,
                commands: available
            ).map(\.command) == ["<address>", "none", "default"]
        )

        let withoutCron = available.filter { $0.command != "/cron" }
        for text in ["/cron ma", "/cron mailto ", "/cron add @d", "/cron add 0 9 "] {
            #expect(
                TerminalPromptCompletion.matches(
                    buffer: Array(text),
                    cursorIndex: Array(text).count,
                    commands: withoutCron
                ).isEmpty,
                "\(text)"
            )
        }
    }

    @Test
    func completingNeverReadsTheCrontab() async throws {
        let (terminal, client) = try makeTerminal(crontab: Self.userCrontab)
        let commands = terminal.commandSuggestionsForCurrentAgent()

        for text in ["/cron ", "/cron add ", "/cron add 0 9 ", "/cron remove ", "/cron mailto "] {
            _ = TerminalPromptCompletion.matches(
                buffer: Array(text),
                cursorIndex: Array(text).count,
                commands: commands
            )
        }

        #expect(client.readCount == 0)
        #expect(client.writes.isEmpty)
    }

    @Test
    func slashCronReachesTheHandlerThroughTheDispatcher() async throws {
        let (terminal, client) = try makeTerminal(crontab: Self.userCrontab)

        let action = await terminal.submittedLineAction("/cron list")

        guard case .continueChat = action else {
            Issue.record("expected /cron to continue the chat")
            return
        }
        #expect(client.readCount == 1)
        #expect(client.writes.isEmpty)
    }

    // MARK: - Helpers

    /// Menu rows for `text` with `/cron` available, the cursor at `cursorIndex`
    /// (the end of the line by default). Pure: no terminal, no crontab.
    private func cronCompletions(
        _ text: String,
        cursorIndex: Int? = nil
    ) -> [TerminalCommandSuggestion] {
        let buffer = Array(text)
        return TerminalPromptCompletion.matches(
            buffer: buffer,
            cursorIndex: cursorIndex ?? buffer.count,
            commands: [TerminalCommandSuggestion(command: "/cron", summary: "schedule prompts")]
        )
    }

    private func makeTerminal(
        crontab: String,
        zen: FakeZenLocator = FakeZenLocator(),
        zenCRON: FakeZenCRONLocator = FakeZenCRONLocator()
    ) throws -> (TerminalChat, FakeCrontabClient) {
        try makeTerminal(client: FakeCrontabClient(text: crontab), zen: zen, zenCRON: zenCRON)
    }

    private func makeTerminal(
        client: FakeCrontabClient,
        zen: FakeZenLocator = FakeZenLocator(),
        zenCRON: FakeZenCRONLocator = FakeZenCRONLocator(),
        renderCoordinator: TerminalChatRenderCoordinator? = nil,
        agents: [AgentProfile] = AgentProfileStore.defaultProfiles()
    ) throws -> (TerminalChat, FakeCrontabClient) {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: agents,
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-cron-\(UUID().uuidString)",
                isDirectory: true
            )
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil),
            telegramTransportFactory: nil,
            renderCoordinator: renderCoordinator
        )
        terminal.crontabClient = client
        // Never the system runner, even in tests that do not expect a run.
        terminal.cronJobRunner = FakeCronJobRunner(isReleased: true)
        // Never the machine's PATH search: `/cron add` must not depend on a `zen` being installed.
        terminal.cronZenLocator = { zen.locate(onPath: $0) }
        // Never the installed ZenCRON, nor a real process: no test depends on `/setup`.
        terminal.cronZenCRONLocator = { try zenCRON.locate() }
        terminal.selectedAgent = nil
        return (terminal, client)
    }

    // MARK: - Temporary prompt files

    /// Writes `contents` at `directory/name` (creating intermediate
    /// directories) and returns the absolute path.
    private func writePromptFile(_ contents: String, named name: String, in directory: String) throws -> String {
        try writePromptFile(Data(contents.utf8), named: name, in: directory)
    }

    private func writePromptFile(_ contents: Data, named name: String, in directory: String) throws -> String {
        let url = URL(fileURLWithPath: directory + "/" + name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url)
        return url.path
    }
}
