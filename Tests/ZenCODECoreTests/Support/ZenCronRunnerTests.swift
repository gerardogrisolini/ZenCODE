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

    @Test("split ends the command at the first unescaped percent, maps the others to newlines and unescapes \\%", arguments: [
        ("echo hello world", "echo hello world", ""),
        ("date +\\%Y-\\%m-\\%d", "date +%Y-%m-%d", ""),
        ("cat%line one%line two%line three", "cat", "line one\nline two\nline three"),
        ("printf 100\\%%50\\%%x", "printf 100%", "50%\nx"),
        // Backslashes that do not precede a percent sign are kept.
        ("printf 'a\\nb'%c\\d", "printf 'a\\nb'", "c\\d"),
        // A double backslash before a percent is a backslash plus an escaped percent.
        ("echo \\\\%x", "echo \\%x", ""),
        ("cmd%", "cmd", ""),
        ("%body", "", "body"),
        // The inverse of `ZenCronJobCommand.cronEscape`.
        ("echo '100\\% sure' 'a\\%b'", "echo '100% sure' 'a%b'", "")
    ])
    func splitMixedEscapes(_ cronCommand: String, _ shellCommand: String, _ stdin: String) {
        let parts = ZenCronCommandSplit.split(cronCommand)
        #expect(parts.shellCommand == shellCommand)
        #expect(parts.stdin == stdin)
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

    /// Shell command that creates `markerURL`, so a test knows the command
    /// has started (and passed any preceding `trap`) instead of guessing.
    private static func createMarkerCommand(_ markerURL: URL) -> String {
        ": > '\(markerURL.path)'"
    }

    /// Waits until the shell created `markerURL`; `false` once `timeout`
    /// elapsed without it.
    private static func waitForMarker(
        _ markerURL: URL,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !FileManager.default.fileExists(atPath: markerURL.path) {
            guard clock.now < deadline else {
                return false
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    @Test("feeds the part after the first percent to stdin")
    func runCatWithStdin() async throws {
        let outcome = try await run("cat%hello%second line")
        #expect(outcome.exitStatus == 0)
        #expect(outcome.stdout == "hello\nsecond line")
        #expect(outcome.wasTerminated == false)
    }

    @Test("reports the exit status and stderr")
    func runFailure() async throws {
        let outcome = try await run("echo oops >&2; exit 3")
        #expect(outcome.exitStatus == 3)
        #expect(outcome.stdout == "")
        #expect(outcome.stderr == "oops\n")
        #expect(outcome.wasTerminated == false)
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

    @Test("a child that never reads its stdin is neither an error nor a crash")
    func runIgnoredStdin() async throws {
        let payload = String(repeating: "x", count: 300_000)
        let outcome = try await run("printf done%\(payload)")
        #expect(outcome.exitStatus == 0)
        #expect(outcome.stdout == "done")
        #expect(outcome.wasTerminated == false)
    }

    // MARK: - Cancellation

    @Test("cancelling a running command terminates it promptly")
    func cancelRunning() async throws {
        let home = try Self.makeScratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = self.runner
        let clock = ContinuousClock()
        let started = clock.now
        let markerURL = home.appendingPathComponent("started")

        let task = Task {
            try await runner.run(
                cronCommand: "\(Self.createMarkerCommand(markerURL)); sleep 30",
                environment: ZenCronEnvironment.minimal(home: home),
                homeDirectory: home
            )
        }
        let markerAppeared = await Self.waitForMarker(markerURL)
        task.cancel()
        let outcome = try await task.value

        #expect(markerAppeared)
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

    @Test("cancellation does not wait for a descendant that outlives the shell")
    func cancelWithSurvivingDescendant() async throws {
        let home = try Self.makeScratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = self.runner
        let clock = ContinuousClock()
        let started = clock.now
        let markerURL = home.appendingPathComponent("started")

        // The shell stays the parent of `sleep`, so SIGTERM may leave the
        // sleep behind holding the output pipes open.
        let task = Task {
            try await runner.run(
                cronCommand: "\(Self.createMarkerCommand(markerURL)); sleep 20; echo never",
                environment: ZenCronEnvironment.minimal(home: home),
                homeDirectory: home
            )
        }
        let markerAppeared = await Self.waitForMarker(markerURL)
        task.cancel()
        let outcome = try await task.value

        #expect(markerAppeared)
        #expect(outcome.wasTerminated)
        #expect(clock.now - started < .seconds(12))
    }

    @Test("a child that ignores SIGTERM is killed and its survivors are not awaited")
    func cancelStubbornChild() async throws {
        let home = try Self.makeScratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Short graces keep the SIGKILL fallback and the bounded drain fast;
        // the production defaults are covered by the other cancellation tests.
        let runner = SystemCronJobRunner(
            killGrace: .milliseconds(150),
            drainGrace: .milliseconds(150)
        )
        let clock = ContinuousClock()
        let started = clock.now
        let markerURL = home.appendingPathComponent("trapped")

        // Both the shell and the sleep ignore SIGTERM: the runner must fall
        // back to SIGKILL for the shell, then stop waiting for the orphaned
        // sleep that still holds the output pipes. The marker is created only
        // once the trap is in place, so SIGTERM is always ignored.
        let task = Task {
            try await runner.run(
                cronCommand: "trap '' TERM; \(Self.createMarkerCommand(markerURL)); sleep 15",
                environment: ZenCronEnvironment.minimal(home: home),
                homeDirectory: home
            )
        }
        let markerAppeared = await Self.waitForMarker(markerURL)
        task.cancel()
        let outcome = try await task.value

        #expect(markerAppeared)
        #expect(outcome.wasTerminated)
        #expect(outcome.exitStatus == 128 + SIGKILL)
        #expect(clock.now - started < .seconds(12))
    }
}
