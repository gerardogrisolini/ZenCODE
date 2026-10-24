//
//  ZenCronRunnerTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Cron immediate runner")
struct ZenCronRunnerTests {
    // MARK: - ZenCronCommandSplit

    @Test("split without a percent sign leaves the command whole and stdin empty")
    func splitWithoutPercent() {
        let parts = ZenCronCommandSplit.split("echo hello world")
        #expect(parts.shellCommand == "echo hello world")
        #expect(parts.stdin == "")
    }

    @Test("split turns an escaped percent into a literal percent")
    func splitEscapedPercent() {
        let parts = ZenCronCommandSplit.split("date +\\%Y-\\%m-\\%d")
        #expect(parts.shellCommand == "date +%Y-%m-%d")
        #expect(parts.stdin == "")
    }

    @Test("split ends the command at the first percent and maps the others to newlines")
    func splitMultilineStdin() {
        let parts = ZenCronCommandSplit.split("cat%line one%line two%line three")
        #expect(parts.shellCommand == "cat")
        #expect(parts.stdin == "line one\nline two\nline three")
    }

    @Test("split keeps escaped percent signs literal on both sides of the first percent")
    func splitMixedEscapes() {
        let parts = ZenCronCommandSplit.split("printf 100\\%%50\\%%x")
        #expect(parts.shellCommand == "printf 100%")
        #expect(parts.stdin == "50%\nx")
    }

    @Test("split keeps backslashes that do not precede a percent sign")
    func splitKeepsOtherBackslashes() {
        let parts = ZenCronCommandSplit.split("printf 'a\\nb'%c\\d")
        #expect(parts.shellCommand == "printf 'a\\nb'")
        #expect(parts.stdin == "c\\d")
    }

    @Test("split treats a double backslash before a percent as backslash plus escaped percent")
    func splitDoubleBackslash() {
        let parts = ZenCronCommandSplit.split("echo \\\\%x")
        #expect(parts.shellCommand == "echo \\%x")
        #expect(parts.stdin == "")
    }

    @Test("split handles a trailing percent and a leading percent")
    func splitEdges() {
        let trailing = ZenCronCommandSplit.split("cmd%")
        #expect(trailing.shellCommand == "cmd")
        #expect(trailing.stdin == "")

        let leading = ZenCronCommandSplit.split("%body")
        #expect(leading.shellCommand == "")
        #expect(leading.stdin == "body")
    }

    @Test("split is the inverse of the command's cronEscape")
    func splitInvertsCronEscape() {
        let command = "echo '100% sure' 'a%b'"
        let parts = ZenCronCommandSplit.split(ZenCronJobCommand.cronEscape(command))
        #expect(parts.shellCommand == command)
        #expect(parts.stdin == "")
    }

    // MARK: - ZenCronEnvironment

    @Test("minimal environment has exactly the cron variables")
    func minimalKeys() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let environment = ZenCronEnvironment.minimal(
            current: [
                "HOME": "/somewhere/else",
                "LOGNAME": "tester",
                "USER": "tester",
                "PATH": "/opt/evil/bin",
                "SHELL": "/bin/zsh",
                "ANTHROPIC_API_KEY": "secret",
                "LANG": "it_IT.UTF-8"
            ],
            home: home
        )
        #expect(Set(environment.keys) == ["HOME", "LOGNAME", "USER", "SHELL", "PATH"])
        #expect(environment["HOME"] == "/Users/tester")
        #expect(environment["LOGNAME"] == "tester")
        #expect(environment["USER"] == "tester")
        #expect(environment["SHELL"] == "/bin/sh")
        #expect(environment["PATH"] == "/usr/bin:/bin")
    }

    @Test("minimal environment omits LOGNAME and USER when the current one lacks them")
    func minimalWithoutIdentity() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let environment = ZenCronEnvironment.minimal(current: [:], home: home)
        #expect(environment == [
            "HOME": "/Users/tester",
            "SHELL": "/bin/sh",
            "PATH": "/usr/bin:/bin"
        ])
    }

    @Test("minimal environment defaults draw from the real process")
    func minimalDefaults() {
        let environment = ZenCronEnvironment.minimal()
        #expect(environment["HOME"] == UserHomeDirectory.current().path)
        #expect(environment["PATH"] == "/usr/bin:/bin")
        #expect(Set(environment.keys).isSubset(of: ["HOME", "LOGNAME", "USER", "SHELL", "PATH"]))
    }

    @Test("minimal environment takes the PATH the crontab sets for the job and nothing else")
    func minimalWithCustomPath() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let environment = ZenCronEnvironment.minimal(
            current: ["PATH": "/opt/evil/bin", "USER": "tester"],
            home: home,
            path: ZenCrontabDocument.defaultPath
        )
        #expect(environment == [
            "HOME": "/Users/tester",
            "SHELL": "/bin/sh",
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "USER": "tester"
        ])
    }

    // MARK: - ZenCronRunReport

    @Test("extract returns the text of the completed message")
    func extractSuccess() {
        let stdout = """
        {"schema_version":1,"type":"run.started","run_id":"A1"}
        {"schema_version":1,"type":"tool.started","run_id":"A1","name":"read"}
        {"schema_version":1,"type":"tool.completed","run_id":"A1","name":"read"}
        {"schema_version":1,"type":"message.completed","run_id":"A1","text":"No uncommitted changes.\\nAll clean."}
        {"schema_version":1,"type":"run.completed","run_id":"A1"}

        """
        #expect(
            ZenCronRunReport.extract(stdout: stdout)
                == .completed(text: "No uncommitted changes.\nAll clean.")
        )
    }

    @Test("extract returns the error record when nothing completed")
    func extractError() {
        let stdout = """
        {"schema_version":1,"type":"run.started","run_id":"A1"}
        {"schema_version":1,"type":"error","run_id":"A1","category":"provider","message":"The provider request failed."}

        """
        #expect(
            ZenCronRunReport.extract(stdout: stdout)
                == .failed(category: "provider", message: "The provider request failed.")
        )
    }

    @Test("extract finds no result in empty or whitespace output")
    func extractEmpty() {
        #expect(ZenCronRunReport.extract(stdout: "") == .noResult)
        #expect(ZenCronRunReport.extract(stdout: "\n\n  \n") == .noResult)
    }

    @Test("extract ignores lines that are not JSON objects")
    func extractSpuriousLines() {
        let stdout = """
        zen: warning: something went sideways
        {not json at all
        "just a string"
        [1, 2, 3]
        42
        {"type":"message.completed","text":"first"}
        trailing garbage {"type":"message.completed","text":"never"}
        {"type":"message.completed","text":"last"}
        {"type":"tool.started"}
        {"no":"type"}
        {"type":"message.completed"}
        {"type":"message.completed","text":7}
        """
        #expect(ZenCronRunReport.extract(stdout: stdout) == .completed(text: "last"))
    }

    @Test("extract takes the last record of a kind and prefers a message over an error")
    func extractPrecedence() {
        let twoErrors = """
        {"type":"error","category":"configuration","message":"first"}
        {"type":"error","category":"runtime","message":"second"}
        """
        #expect(
            ZenCronRunReport.extract(stdout: twoErrors)
                == .failed(category: "runtime", message: "second")
        )

        let messageThenError = """
        {"type":"message.completed","text":"done"}
        {"type":"error","category":"runtime","message":"late"}
        """
        #expect(ZenCronRunReport.extract(stdout: messageThenError) == .completed(text: "done"))
    }

    @Test("extract skips an error record missing its fields")
    func extractIncompleteError() {
        let stdout = """
        {"type":"error","category":"runtime"}
        {"type":"error","message":"no category"}
        """
        #expect(ZenCronRunReport.extract(stdout: stdout) == .noResult)
    }

    @Test("extract tolerates CRLF framing and Unicode line separators inside text")
    func extractFraming() {
        let stdout = "{\"type\":\"message.completed\",\"text\":\"a\u{2028}b\"}\r\n"
        #expect(ZenCronRunReport.extract(stdout: stdout) == .completed(text: "a\u{2028}b"))
    }

    // MARK: - SystemCronJobRunner

    private let runner = SystemCronJobRunner()

    /// Runs `cronCommand` the way `/cron run` will, from a scratch home.
    private func run(
        _ cronCommand: String,
        environment: [String: String]? = nil
    ) async throws -> ZenCronRunOutcome {
        let home = try Self.makeScratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        return try await runner.run(
            cronCommand: cronCommand,
            environment: environment ?? ZenCronEnvironment.minimal(home: home),
            homeDirectory: home
        )
    }

    private static func makeScratchHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCronRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("runs a shell command and captures stdout; an escaped percent stays literal")
    func runPrintf() async throws {
        // Cron syntax: the percent sign must be escaped to reach printf.
        let outcome = try await run("printf '\\%s' hello")
        #expect(outcome.exitStatus == 0)
        #expect(outcome.stdout == "hello")
        #expect(outcome.stderr == "")
        #expect(outcome.wasTerminated == false)
    }

    @Test("feeds the part after the first percent to stdin")
    func runCatWithStdin() async throws {
        let outcome = try await run("cat%hello%second line")
        #expect(outcome.exitStatus == 0)
        #expect(outcome.stdout == "hello\nsecond line")
        #expect(outcome.wasTerminated == false)
    }

    @Test("closes stdin when the command has none")
    func runCatWithoutStdin() async throws {
        let outcome = try await run("cat")
        #expect(outcome.exitStatus == 0)
        #expect(outcome.stdout == "")
    }

    @Test("reports the exit status and stderr")
    func runFailure() async throws {
        let outcome = try await run("echo oops >&2; exit 3")
        #expect(outcome.exitStatus == 3)
        #expect(outcome.stdout == "")
        #expect(outcome.stderr == "oops\n")
        #expect(outcome.wasTerminated == false)
    }

    @Test("measures the duration of the run")
    func runDuration() async throws {
        let outcome = try await run("sleep 0.2")
        #expect(outcome.exitStatus == 0)
        #expect(outcome.duration >= .milliseconds(150))
        #expect(outcome.duration < .seconds(20))
    }

    @Test("runs from the home directory with exactly the given environment")
    func runEnvironmentAndDirectory() async throws {
        let home = try Self.makeScratchHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let outcome = try await runner.run(
            cronCommand: "printf '\\%s|\\%s' \"${USER-unset}\" \"${ZEN_CRON_TEST-unset}\"; pwd -P >&2",
            environment: ["PATH": "/usr/bin:/bin", "ZEN_CRON_TEST": "bar"],
            homeDirectory: home
        )
        #expect(outcome.exitStatus == 0)
        // USER is not forwarded from the test process, only what was passed.
        #expect(outcome.stdout == "unset|bar")
        let reportedDirectory = URL(
            fileURLWithPath: outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        #expect(reportedDirectory.resolvingSymlinksInPath().path
            == home.resolvingSymlinksInPath().path)
    }

    @Test("bounds retained output to 1 MiB of stdout and 64 KiB of stderr")
    func runBoundsOutput() async throws {
        let outcome = try await run(
            "head -c 1500000 /dev/zero | tr '\\000' o; head -c 200000 /dev/zero | tr '\\000' e >&2"
        )
        #expect(outcome.exitStatus == 0)
        #expect(outcome.stdout.utf8.count == 1 << 20)
        #expect(outcome.stdout.utf8.allSatisfy { $0 == UInt8(ascii: "o") })
        #expect(outcome.stderr.utf8.count == 64 * 1024)
        #expect(outcome.stderr.utf8.allSatisfy { $0 == UInt8(ascii: "e") })
    }

    @Test("delivers a large stdin to a reading child")
    func runLargeStdin() async throws {
        let payload = String(repeating: "x", count: 300_000)
        let outcome = try await run("wc -c%\(payload)")
        #expect(outcome.exitStatus == 0)
        #expect(outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "300000")
    }

    @Test("a child that never reads its stdin is neither an error nor a crash")
    func runIgnoredStdin() async throws {
        let payload = String(repeating: "x", count: 300_000)
        let outcome = try await run("printf done%\(payload)")
        #expect(outcome.exitStatus == 0)
        #expect(outcome.stdout == "done")
        #expect(outcome.wasTerminated == false)
    }

    @Test("an unusable home directory is a launch error")
    func runMissingHomeThrows() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCronRunnerTests-missing-\(UUID().uuidString)", isDirectory: true)
        await #expect(throws: (any Error).self) {
            _ = try await runner.run(
                cronCommand: "true",
                environment: ["PATH": "/usr/bin:/bin"],
                homeDirectory: missing
            )
        }
    }

    // MARK: - Cancellation

    @Test("cancelling a running command terminates it promptly")
    func cancelRunning() async throws {
        let home = try Self.makeScratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = self.runner
        let clock = ContinuousClock()
        let started = clock.now

        let task = Task {
            try await runner.run(
                cronCommand: "sleep 30",
                environment: ZenCronEnvironment.minimal(home: home),
                homeDirectory: home
            )
        }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        let outcome = try await task.value

        #expect(outcome.wasTerminated)
        #expect(outcome.exitStatus != 0)
        #expect(clock.now - started < .seconds(15))
    }

    @Test("cancelling before the command starts returns without running it")
    func cancelBeforeStart() async throws {
        let home = try Self.makeScratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = self.runner
        let clock = ContinuousClock()
        let started = clock.now

        let task = Task {
            try await runner.run(
                cronCommand: "sleep 30",
                environment: ZenCronEnvironment.minimal(home: home),
                homeDirectory: home
            )
        }
        task.cancel()
        let outcome = try await task.value

        #expect(outcome.wasTerminated)
        // Whether or not the launch won the race, the sleep never completes.
        #expect(clock.now - started < .seconds(15))
    }

    @Test("cancelling after the command ended changes nothing")
    func cancelAfterCompletion() async throws {
        let home = try Self.makeScratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = self.runner

        let task = Task {
            try await runner.run(
                cronCommand: "printf '\\%s' finished",
                environment: ZenCronEnvironment.minimal(home: home),
                homeDirectory: home
            )
        }
        let outcome = try await task.value
        task.cancel()

        #expect(outcome.exitStatus == 0)
        #expect(outcome.stdout == "finished")
        #expect(outcome.wasTerminated == false)
    }

    @Test("cancellation does not wait for a descendant that outlives the shell")
    func cancelWithSurvivingDescendant() async throws {
        let home = try Self.makeScratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = self.runner
        let clock = ContinuousClock()
        let started = clock.now

        // The shell stays the parent of `sleep`, so SIGTERM may leave the
        // sleep behind holding the output pipes open.
        let task = Task {
            try await runner.run(
                cronCommand: "sleep 20; echo never",
                environment: ZenCronEnvironment.minimal(home: home),
                homeDirectory: home
            )
        }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        let outcome = try await task.value

        #expect(outcome.wasTerminated)
        #expect(clock.now - started < .seconds(12))
    }

    @Test("a child that ignores SIGTERM is killed and its survivors are not awaited")
    func cancelStubbornChild() async throws {
        let home = try Self.makeScratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = self.runner
        let clock = ContinuousClock()
        let started = clock.now

        // Both the shell and the sleep ignore SIGTERM: the runner must fall
        // back to SIGKILL for the shell, then stop waiting for the orphaned
        // sleep that still holds the output pipes.
        let task = Task {
            try await runner.run(
                cronCommand: "trap '' TERM; sleep 15",
                environment: ZenCronEnvironment.minimal(home: home),
                homeDirectory: home
            )
        }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        let outcome = try await task.value

        #expect(outcome.wasTerminated)
        #expect(outcome.exitStatus == 128 + SIGKILL)
        #expect(clock.now - started < .seconds(12))
    }
}
