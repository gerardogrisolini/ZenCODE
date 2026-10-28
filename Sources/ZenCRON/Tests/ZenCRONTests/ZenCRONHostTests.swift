import Foundation
import Synchronization
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Black-box tests for the `ZenCRON` host: the real compiled binary is copied
/// to its own directory, a fake `zen` shell script is put in another directory
/// that is on the `PATH` given to the launched process, and the host is run as
/// a separate process by absolute path, the way cron runs it. They pin the
/// contract written at the top of `Sources/ZenCRON/main.swift`: verbatim
/// pass-through, exit-status and signal mirroring, signal forwarding, and the
/// `zen` lookup on `PATH`. `PATH` is always passed in the environment of the
/// child process; it is never changed in the test process.
@Suite(.serialized)
struct ZenCRONHostTests {
    private static let timeout: TimeInterval = 30

    /// True where `Foundation.Process` gives the child the signal mask of the
    /// launching thread (Linux); macOS resets it to empty.
    private static let processPassesSignalMaskToChild: Bool = {
        #if os(Linux)
        true
        #else
        false
        #endif
    }()

    enum KillSignal: String, CaseIterable, Sendable {
        case kill = "KILL"
        case term = "TERM"

        var number: Int32 {
            switch self {
            case .kill: SIGKILL
            case .term: SIGTERM
            }
        }
    }

    // MARK: (a) Verbatim pass-through

    @Test(arguments: [Int32(0), Int32(7)])
    func passesArgumentsStreamsEnvironmentAndExitCodeUnchanged(exitCode: Int32) async throws {
        let fixture = try HostFixture.make(zen: Self.recordingZen(exitCode: exitCode))
        defer { fixture.remove() }

        let arguments = [
            "plain", "two words", "", "it's", "say \"hi\"", "h\u{E9}llo \u{2713} \u{65E5}\u{672C}\u{8A9E}",
            "--flag=value", "-x", "$HOME", "*"
        ]
        let input = "line one\nline two with \u{FC}n\u{EF}code\n"
        let host = try await HostProcess(
            executable: fixture.hostURL,
            arguments: arguments,
            environment: fixture.environment(extra: [
                "ZENCRON_TEST_VALUE": "value with spaces and \u{FC}n\u{EF}code",
                "ZENCRON_TEST_EMPTY": ""
            ]),
            standardInput: Data(input.utf8),
            outputDirectory: fixture.root
        )
        try await host.waitForExit(timeout: Self.timeout)
        let result = host.result()

        #expect(result.reason == .exit)
        #expect(result.status == exitCode)
        #expect(result.standardOutput == "to-stdout\nenv=value with spaces and \u{FC}n\u{EF}code\nempty=set\n")
        #expect(result.standardError == "to-stderr\n")
        #expect(fixture.read("stdin.txt") == input)

        let expectedRecord = ["argv0=\(fixture.zenPath)", "argc=\(arguments.count)"]
            + arguments.map { "[\($0)]" }
        #expect(fixture.read("args.txt") == expectedRecord.joined(separator: "\n") + "\n")
    }

    @Test func passesNoArgumentsWhenCalledWithNone() async throws {
        let fixture = try HostFixture.make(zen: Self.recordingZen(exitCode: 0))
        defer { fixture.remove() }

        let result = try await Self.run(fixture, arguments: [])

        #expect(result.reason == .exit)
        #expect(result.status == 0)
        #expect(fixture.read("args.txt") == "argv0=\(fixture.zenPath)\nargc=0\n")
    }

    // MARK: (b) Dying from the same signal as zen

    @Test(arguments: KillSignal.allCases)
    func diesFromTheSignalThatKilledZen(signal: KillSignal) async throws {
        let fixture = try HostFixture.make(zen: """
        #!/bin/sh
        kill -s \(signal.rawValue) $$
        exit 0
        """)
        defer { fixture.remove() }

        let result = try await Self.run(fixture, arguments: ["ignored"])

        #expect(result.reason == .uncaughtSignal)
        #expect(result.status == signal.number)
    }

    // MARK: (b2) Transparency to the signal mask of the launcher

    /// `Foundation.Process` hands the child the signal mask of the thread that
    /// calls `run()` on Linux, but resets it to empty on macOS (verified with
    /// `ps -o blocked`). The scenario can therefore only be set up on Linux,
    /// and the fake zen reads `/proc/self/status`, which macOS does not have.
    @Test(.enabled(if: Self.processPassesSignalMaskToChild, "Foundation.Process only passes the signal mask on Linux"))
    func zenReceivesTheBlockedSignalsOfTheLauncherUnchanged() async throws {
        // Builtins only: `/proc/self` is resolved by the shell itself, so the
        // mask read is the one zen runs with, not that of a helper process.
        let fixture = try HostFixture.make(zen: """
        #!/bin/sh
        dir="${0%/*}"
        while read -r key value; do
            if [ "$key" = "SigBlk:" ]; then
                echo "$value" > "$dir/sigblk"
            fi
        done < /proc/self/status
        kill -s TERM $$
        echo survived > "$dir/survived"
        exit 0
        """)
        defer { fixture.remove() }

        // The host is launched with SIGTERM blocked, as a parent that blocks it
        // would do. The host is transparent: zen must get the same mask, so its
        // own `kill -s TERM $$` stays pending instead of killing it.
        let host = try await HostProcess(
            executable: fixture.hostURL,
            arguments: [],
            environment: fixture.environment(),
            standardInput: nil,
            outputDirectory: fixture.root,
            blockedSignals: [SIGTERM]
        )
        try await host.waitForExit(timeout: Self.timeout)
        let result = host.result()

        #expect(result.reason == .exit)
        #expect(result.status == 0)
        #expect(fixture.read("survived") == "survived\n")

        let report = fixture.read("sigblk")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocked = report.flatMap { UInt64($0, radix: 16) }
        try #require(blocked != nil, "zen did not report a SigBlk mask: \(report ?? "nothing")")
        let mask = blocked ?? 0
        func isBlocked(_ signalNumber: Int32) -> Bool {
            mask & (UInt64(1) << UInt64(signalNumber - 1)) != 0
        }
        #expect(isBlocked(SIGTERM))
        // The signals the host blocks only while it spawns zen must not leak.
        #expect(!isBlocked(SIGINT))
        #expect(!isBlocked(SIGHUP))
        #expect(!isBlocked(SIGQUIT))
    }

    // MARK: (c) Signal forwarding

    @Test func forwardsSIGTERMSentOnlyToTheHostToZen() async throws {
        let fixture = try HostFixture.make(zen: """
        #!/bin/sh
        dir="${0%/*}"
        trap 'echo received-term > "$dir/received"; exit 42' TERM
        : > "$dir/ready"
        n=0
        while [ "$n" -lt 600 ]; do
            sleep 0.1
            n=$((n + 1))
        done
        exit 1
        """)
        defer { fixture.remove() }

        let host = try await HostProcess(
            executable: fixture.hostURL,
            arguments: [],
            environment: fixture.environment(),
            standardInput: nil,
            outputDirectory: fixture.root
        )
        let isReady = try await Self.waitForFile(fixture.url("ready"), host: host)
        try #require(isReady, "zen never signalled readiness")

        // Only the host's PID is signalled: zen must hear about it from the host.
        #expect(kill(host.process.processIdentifier, SIGTERM) == 0)
        try await host.waitForExit(timeout: Self.timeout)
        let result = host.result()

        #expect(result.reason == .exit)
        #expect(result.status == 42)
        #expect(fixture.read("received") == "received-term\n")
    }

    @Test func zenStaysAChildInTheProcessGroupOfTheHost() async throws {
        let fixture = try HostFixture.make(zen: """
        #!/bin/sh
        dir="${0%/*}"
        echo "$$ $PPID" > "$dir/zen.pid"
        n=0
        while [ ! -e "$dir/release" ] && [ "$n" -lt 600 ]; do
            sleep 0.1
            n=$((n + 1))
        done
        exit 0
        """)
        defer { fixture.remove() }

        let host = try await HostProcess(
            executable: fixture.hostURL,
            arguments: [],
            environment: fixture.environment(),
            standardInput: nil,
            outputDirectory: fixture.root
        )
        let hostPID = host.process.processIdentifier
        var zenPIDs: [Int32] = []
        let deadline = Date().addingTimeInterval(Self.timeout)
        while zenPIDs.count != 2, Date() < deadline, host.process.isRunning {
            zenPIDs = (fixture.read("zen.pid") ?? "")
                .split(whereSeparator: \.isWhitespace)
                .compactMap { Int32($0) }
            if zenPIDs.count != 2 {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try #require(zenPIDs.count == 2, "zen never reported its PIDs")
        let zenPID = zenPIDs[0]
        let zenParentPID = zenPIDs[1]

        // A spawn, not an exec: zen is a distinct process whose parent is the host.
        #expect(zenPID != hostPID)
        #expect(zenParentPID == hostPID)
        // No setsid/setpgid: zen shares the host's process group.
        let hostGroup = getpgid(hostPID)
        #expect(hostGroup > 0)
        #expect(getpgid(zenPID) == hostGroup)

        try Data().write(to: fixture.url("release"))
        try await host.waitForExit(timeout: Self.timeout)
        #expect(host.result().status == 0)
    }

    @Test func ignoredSignalsStayIgnoredForZen() async throws {
        let fixture = try HostFixture.make(zen: """
        #!/bin/sh
        dir="${0%/*}"
        kill -s TERM $$
        echo survived > "$dir/survived"
        exit 0
        """)
        defer { fixture.remove() }

        // exec keeps the ignored disposition, so the host starts with SIGTERM
        // ignored, as it would when inherited from cron.
        let host = try await HostProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; exec \"$1\"", "sh", fixture.hostURL.path],
            environment: fixture.environment(),
            standardInput: nil,
            outputDirectory: fixture.root
        )
        try await host.waitForExit(timeout: Self.timeout)
        let result = host.result()

        #expect(result.reason == .exit)
        #expect(result.status == 0)
        #expect(fixture.read("survived") == "survived\n")
    }

    // MARK: (d) No executable zen on PATH

    @Test func exits127WithTheExactMessageWhenPATHHasNoZen() async throws {
        let fixture = try HostFixture.make(zen: nil)
        defer { fixture.remove() }

        // Decoys that a lookup relative to the working directory (the fixture
        // root) would find: they must never be run.
        try HostFixture.install(script: "#!/bin/sh\nexit 99\n", named: "zen", in: fixture.root)
        let relative = try fixture.makeDirectory("relative")
        try HostFixture.install(script: "#!/bin/sh\nexit 99\n", named: "zen", in: relative)

        let emptyDirectory = try fixture.makeDirectory("empty")
        let missingDirectory = fixture.root.appendingPathComponent("missing-\(UUID().uuidString)").path
        let path = "\(emptyDirectory.path):\(missingDirectory)::.:relative:./relative:"

        let result = try await Self.run(
            fixture,
            arguments: ["anything"],
            environment: fixture.environment(path: path)
        )

        #expect(result.reason == .exit)
        #expect(result.status == 127)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError == "ZenCRON: no executable zen in PATH=\(path)\n")
    }

    @Test func exits127WhenPATHIsNotSet() async throws {
        let fixture = try HostFixture.make(zen: Self.recordingZen(exitCode: 0))
        defer { fixture.remove() }

        // The environment is not empty, it just has no PATH.
        let result = try await Self.run(
            fixture,
            arguments: ["anything"],
            environment: ["ZENCRON_TEST_VALUE": "present"]
        )

        #expect(result.reason == .exit)
        #expect(result.status == 127)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError == "ZenCRON: no executable zen in PATH=\n")
        #expect(fixture.read("args.txt") == nil)
    }

    @Test func exits127WhenTheOnlyZenOnPATHIsNotExecutable() async throws {
        let fixture = try HostFixture.make(zen: "#!/bin/sh\nexit 0\n", zenPermissions: 0o644)
        defer { fixture.remove() }

        let result = try await Self.run(fixture, arguments: [])

        #expect(result.reason == .exit)
        #expect(result.status == 127)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError == "ZenCRON: no executable zen in PATH=\(fixture.path)\n")
    }

    // MARK: (e) Version query

    @Test func versionQueryPrintsTheHostVersionWithoutLaunchingZen() async throws {
        let fixture = try HostFixture.make(zen: Self.recordingZen(exitCode: 9))
        defer { fixture.remove() }

        let result = try await Self.run(fixture, arguments: ["--zencron-version"])

        #expect(result.reason == .exit)
        #expect(result.status == 0)
        #expect(result.standardOutput == "ZenCRON 1\n")
        #expect(result.standardError.isEmpty)
        #expect(fixture.read("args.txt") == nil)
    }

    @Test func versionQueryWorksWithoutZenOnPATH() async throws {
        let fixture = try HostFixture.make(zen: nil)
        defer { fixture.remove() }

        let result = try await Self.run(
            fixture,
            arguments: ["--zencron-version"],
            environment: ["ZENCRON_TEST_VALUE": "present"]
        )

        #expect(result.status == 0)
        #expect(result.standardOutput == "ZenCRON 1\n")
        #expect(result.standardError.isEmpty)
    }

    @Test func versionFlagIsOnlyRecognisedAsTheSoleArgument() async throws {
        let fixture = try HostFixture.make(zen: Self.recordingZen(exitCode: 9))
        defer { fixture.remove() }

        let result = try await Self.run(fixture, arguments: ["--zencron-version", "extra"])

        #expect(result.status == 9)
        #expect(fixture.read("args.txt") == "argv0=\(fixture.zenPath)\nargc=2\n[--zencron-version]\n[extra]\n")
    }

    // MARK: (f) Lookup rule on PATH

    @Test func firstDirectoryOnPATHWins() async throws {
        let fixture = try HostFixture.make(zen: Self.recordingZen(exitCode: 22))
        defer { fixture.remove() }
        let first = try fixture.makeDirectory("first")
        try HostFixture.install(script: "#!/bin/sh\nexit 11\n", named: "zen", in: first)

        let firstWins = try await Self.run(
            fixture,
            arguments: [],
            environment: fixture.environment(path: "\(first.path):\(fixture.zenDirectory.path):/usr/bin:/bin")
        )
        #expect(firstWins.reason == .exit)
        #expect(firstWins.status == 11)
        #expect(fixture.read("args.txt") == nil)

        // The same two directories in the other order: the winner follows the
        // order of PATH, not the directories.
        let swappedWins = try await Self.run(
            fixture,
            arguments: [],
            environment: fixture.environment(path: "\(fixture.zenDirectory.path):\(first.path):/usr/bin:/bin")
        )
        #expect(swappedWins.reason == .exit)
        #expect(swappedWins.status == 22)
        #expect(fixture.read("args.txt") == "argv0=\(fixture.zenPath)\nargc=0\n")
    }

    @Test func emptyAndRelativeEntriesAreIgnored() async throws {
        let fixture = try HostFixture.make(zen: Self.recordingZen(exitCode: 7))
        defer { fixture.remove() }

        // The host runs with the fixture root as working directory. Decoys sit
        // where an empty entry, "." and relative entries would point.
        try HostFixture.install(script: "#!/bin/sh\nexit 99\n", named: "zen", in: fixture.root)
        let relative = try fixture.makeDirectory("relative")
        try HostFixture.install(script: "#!/bin/sh\nexit 99\n", named: "zen", in: relative)

        let path = ":.:relative:./relative::\(fixture.path):"
        let result = try await Self.run(
            fixture,
            arguments: ["real"],
            environment: fixture.environment(path: path)
        )

        #expect(result.reason == .exit)
        #expect(result.status == 7)
        #expect(fixture.read("args.txt") == "argv0=\(fixture.zenPath)\nargc=1\n[real]\n")
    }

    @Test func nonExecutableZenInAnEarlierDirectoryIsSkipped() async throws {
        let fixture = try HostFixture.make(zen: Self.recordingZen(exitCode: 7))
        defer { fixture.remove() }
        let first = try fixture.makeDirectory("first")
        try HostFixture.install(script: "#!/bin/sh\nexit 99\n", named: "zen", permissions: 0o644, in: first)

        let result = try await Self.run(
            fixture,
            arguments: [],
            environment: fixture.environment(path: "\(first.path):\(fixture.path)")
        )

        #expect(result.reason == .exit)
        #expect(result.status == 7)
        #expect(fixture.read("args.txt") == "argv0=\(fixture.zenPath)\nargc=0\n")
    }

    @Test func trailingSlashesOfAnEntryAreRemoved() async throws {
        let fixture = try HostFixture.make(zen: "#!/bin/sh\nprintf '%s\\n' \"$0\"\n")
        defer { fixture.remove() }

        let result = try await Self.run(
            fixture,
            arguments: [],
            environment: fixture.environment(path: "\(fixture.zenDirectory.path)//:/usr/bin:/bin")
        )

        #expect(result.reason == .exit)
        #expect(result.status == 0)
        #expect(result.standardOutput == "\(fixture.zenPath)\n")
    }

    @Test func zenIsRunUnderItsAbsolutePath() async throws {
        let fixture = try HostFixture.make(zen: "#!/bin/sh\nprintf '%s\\n' \"$0\"\n")
        defer { fixture.remove() }

        let result = try await Self.run(fixture, arguments: [])

        #expect(result.reason == .exit)
        #expect(result.status == 0)
        #expect(result.standardOutput == "\(fixture.zenPath)\n")
    }

    @Test func argv0OfZenIsTheAbsolutePathFoundOnPATH() async throws {
        let fixture = try HostFixture.make(zen: nil)
        defer { fixture.remove() }

        // The $0 of a script is the path given to exec. A shell started under
        // another name through a symlink, with a command string and nothing
        // after it, reports its real argv[0] instead.
        try FileManager.default.createSymbolicLink(
            at: fixture.zenDirectory.appendingPathComponent("zen"),
            withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )

        let result = try await Self.run(fixture, arguments: ["-c", "printf '%s\\n' \"$0\""])

        #expect(result.reason == .exit)
        #expect(result.status == 0)
        #expect(result.standardOutput == "\(fixture.zenPath)\n")
    }

    @Test func neverUsesAZenNextToTheHostEvenThroughASymlink() async throws {
        let fixture = try HostFixture.make(zen: Self.recordingZen(exitCode: 7))
        defer { fixture.remove() }

        // Decoys next to the real host file and next to a symlink to it: the
        // host looks on PATH only, never next to itself.
        let decoy = "#!/bin/sh\nexit 99\n"
        let hostDirectory = fixture.hostURL.deletingLastPathComponent()
        try HostFixture.install(script: decoy, named: "zen", in: hostDirectory)
        let linkDirectory = try fixture.makeDirectory("links")
        try HostFixture.install(script: decoy, named: "zen", in: linkDirectory)
        let link = linkDirectory.appendingPathComponent("ZenCRON")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.hostURL)

        let found = try await Self.run(fixture, executable: link, arguments: ["via-link"])
        #expect(found.reason == .exit)
        #expect(found.status == 7)
        #expect(fixture.read("args.txt") == "argv0=\(fixture.zenPath)\nargc=1\n[via-link]\n")

        // With no zen on PATH the decoys are not a fallback.
        let emptyDirectory = try fixture.makeDirectory("empty")
        let path = emptyDirectory.path
        let missing = try await Self.run(
            fixture,
            executable: link,
            arguments: ["via-link"],
            environment: fixture.environment(path: path)
        )
        #expect(missing.reason == .exit)
        #expect(missing.status == 127)
        #expect(missing.standardError == "ZenCRON: no executable zen in PATH=\(path)\n")
    }

    // MARK: (g) Run by a shell, as cron does

    @Test func shellRunsTheHostByAbsolutePathAndTheHostFindsZenOnPATH() async throws {
        // Builtins only in the fake zen, so nothing else is needed on PATH.
        let fixture = try HostFixture.make(zen: """
        #!/bin/sh
        printf '[%s]\\n' "$@" > "${0%/*}/args.txt"
        exit 5
        """)
        defer { fixture.remove() }

        // cron runs `/bin/sh -c '<command>'` with the PATH of the ZenCODE block
        // of the crontab. The command names ZenCRON by absolute path: its own
        // directory is not on PATH, and neither is anything next to it.
        let hostDirectory = fixture.hostURL.deletingLastPathComponent().path
        let path = "\(fixture.zenDirectory.path):/usr/bin:/bin"
        try #require(!path.split(separator: ":").contains(where: { $0 == hostDirectory }))

        let host = try await HostProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "'\(fixture.hostURL.path)' a b"],
            environment: ["PATH": path],
            standardInput: nil,
            outputDirectory: fixture.root
        )
        try await host.waitForExit(timeout: Self.timeout)
        let result = host.result()

        #expect(result.reason == .exit)
        #expect(result.status == 5)
        #expect(fixture.read("args.txt") == "[a]\n[b]\n")
    }
}

// MARK: - Fake zen scripts

private extension ZenCRONHostTests {
    /// Records argv0, the argument list, stdin and one environment variable,
    /// writes to both output streams, then exits with `exitCode`.
    static func recordingZen(exitCode: Int32) -> String {
        """
        #!/bin/sh
        dir="${0%/*}"
        {
            echo "argv0=$0"
            echo "argc=$#"
            for arg in "$@"; do
                printf '[%s]\\n' "$arg"
            done
        } > "$dir/args.txt"
        cat > "$dir/stdin.txt"
        echo "to-stdout"
        echo "to-stderr" >&2
        echo "env=$ZENCRON_TEST_VALUE"
        echo "empty=${ZENCRON_TEST_EMPTY+set}"
        exit \(exitCode)
        """
    }

    /// Runs the host and waits for it. By default it is the fixture's host with
    /// the fixture's cron-like environment.
    static func run(
        _ fixture: HostFixture,
        executable: URL? = nil,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: Data? = nil
    ) async throws -> HostRun {
        let host = try await HostProcess(
            executable: executable ?? fixture.hostURL,
            arguments: arguments,
            environment: environment ?? fixture.environment(),
            standardInput: standardInput,
            outputDirectory: fixture.root
        )
        try await host.waitForExit(timeout: timeout)
        return host.result()
    }

    /// Polls until `url` exists. Returns false if the host exits first or the
    /// timeout elapses.
    static func waitForFile(_ url: URL, host: HostProcess) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            if !host.process.isRunning {
                return false
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

// MARK: - Process plumbing

private struct HostTestError: Error, CustomStringConvertible {
    let description: String
}

private struct HostRun {
    let status: Int32
    let reason: Process.TerminationReason
    let standardOutput: String
    let standardError: String
}

/// A temporary directory (named with a UUID) laid out the way ZenCRON is
/// installed: the compiled `ZenCRON` copied to a directory of its own, and an
/// optional fake `zen` in a separate directory that the default `PATH` lists.
/// Nothing is next to the host.
private struct HostFixture {
    let root: URL
    /// The copy of the compiled host, alone in its directory.
    let hostURL: URL
    /// The directory of the fake `zen`. Fake zen scripts write the files they
    /// record next to themselves, so `url(_:)` and `read(_:)` refer to it.
    let zenDirectory: URL

    var zenPath: String {
        zenDirectory.appendingPathComponent("zen").path
    }

    /// A cron-like `PATH`: the directory of the fake `zen`, then the system ones.
    var path: String {
        "\(zenDirectory.path):/usr/bin:/bin"
    }

    /// The environment of a launched process: only `PATH` (the default one
    /// unless `path` is given) plus `extra`, no inherited test-runner variables.
    func environment(path: String? = nil, extra: [String: String] = [:]) -> [String: String] {
        ["PATH": path ?? self.path].merging(extra) { _, new in new }
    }

    static func make(zen: String?, zenPermissions: Int = 0o755) throws -> HostFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencron-host-\(UUID().uuidString)", isDirectory: true)
        let hostDirectory = root.appendingPathComponent("host", isDirectory: true)
        let zenDirectory = root.appendingPathComponent("zen-bin", isDirectory: true)

        let hostURL = hostDirectory.appendingPathComponent("ZenCRON")
        do {
            try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: zenDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: try locateCompiledHost(), to: hostURL)
            if let zen {
                try install(script: zen, named: "zen", permissions: zenPermissions, in: zenDirectory)
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        return HostFixture(root: root, hostURL: hostURL, zenDirectory: zenDirectory)
    }

    static func install(script: String, named name: String, permissions: Int = 0o755, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    /// Creates an extra directory under the fixture root.
    func makeDirectory(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func url(_ name: String) -> URL {
        zenDirectory.appendingPathComponent(name)
    }

    func read(_ name: String) -> String? {
        try? String(contentsOf: url(name), encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// SwiftPM places executable products next to the test bundle (or next to
    /// the test executable on Linux). Resolve that product directory from the
    /// test bundle path supplied to `swiftpm-testing-helper` instead of asking
    /// SwiftPM to inspect its build directory while tests are running; that
    /// command would contend for SwiftPM's build-directory lock.
    private static func locateCompiledHost() throws -> URL {
        let fileManager = FileManager.default
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let arguments = CommandLine.arguments
        var executableURLs: [URL] = []

        func appendExecutableURL(from path: String) {
            guard !path.isEmpty else { return }
            executableURLs.append(
                URL(fileURLWithPath: path, relativeTo: currentDirectory).standardizedFileURL
            )
        }

        for (index, argument) in arguments.enumerated() {
            if argument == "--test-bundle-path", arguments.indices.contains(index + 1) {
                appendExecutableURL(from: arguments[index + 1])
            } else if argument.hasPrefix("--test-bundle-path=") {
                appendExecutableURL(from: String(argument.dropFirst("--test-bundle-path=".count)))
            } else if argument.contains(".xctest") {
                appendExecutableURL(from: argument)
            }
        }
        if let executableURL = Bundle.main.executableURL {
            executableURLs.append(executableURL.standardizedFileURL)
        }
        if let argument = arguments.first {
            appendExecutableURL(from: argument)
        }

        var searchedDirectories: [URL] = []

        func appendSearchDirectory(_ directory: URL) {
            let standardized = directory.standardizedFileURL
            guard !searchedDirectories.contains(where: { $0.path == standardized.path }) else { return }
            searchedDirectories.append(standardized)
        }

        for executableURL in executableURLs {
            appendSearchDirectory(productDirectory(for: executableURL))
        }
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            appendSearchDirectory(productDirectory(for: bundle.bundleURL))
            if let executableURL = bundle.executableURL {
                appendSearchDirectory(productDirectory(for: executableURL))
            }
        }
        for key in ["BUILT_PRODUCTS_DIR", "TARGET_BUILD_DIR", "__XCODE_BUILT_PRODUCTS_DIR_PATHS"] {
            guard let value = ProcessInfo.processInfo.environment[key] else { continue }
            for path in value.split(separator: ":") where !path.isEmpty {
                appendSearchDirectory(URL(fileURLWithPath: String(path)))
            }
        }

        for directory in searchedDirectories {
            let candidate = directory.appendingPathComponent("ZenCRON")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        let searched = searchedDirectories.map(\.path).joined(separator: ", ")
        throw HostTestError(description: "ZenCRON executable not found (searched in: \(searched))")
    }

    private static func productDirectory(for executableURL: URL) -> URL {
        let components = executableURL.standardizedFileURL.path.split(separator: "/")
        if let bundleIndex = components.firstIndex(where: { $0.hasSuffix(".xctest") }) {
            let bundlePath = "/" + components[...bundleIndex].joined(separator: "/")
            return URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
        }
        return executableURL.deletingLastPathComponent()
    }
}

/// Set by `terminationHandler` once the child has been reaped.
private final class ExitFlag: Sendable {
    private let state = Mutex(false)

    func set() {
        state.withLock { $0 = true }
    }

    var isSet: Bool {
        state.withLock { $0 }
    }
}

/// Carries a `Process` to the launcher thread. Only one thread touches the
/// process at a time: the awaiting task does not use it until the launcher
/// thread has resumed the continuation, which is the synchronisation point.
private struct ProcessHandoff: @unchecked Sendable {
    let process: Process
}

/// Launches a `Process` from a dedicated thread whose signal mask is set
/// first, instead of from whatever thread the caller happens to run on.
///
/// This is needed because, on Linux, `Foundation.Process.run()` gives the
/// child the mask of BLOCKED signals of the calling thread. A Swift task runs
/// on a libdispatch worker thread, and a probe showed such a worker blocking
/// SIGTERM, SIGINT, SIGHUP and SIGQUIT (`SigBlk: fffffffe3bfbea27`), while the
/// main thread gave the child `SigBlk: 0`. ZenCRON is transparent and passes to
/// zen the mask it received, so with SIGTERM blocked neither a `kill -s TERM`
/// by zen on itself nor the forwarding of SIGTERM would work. Production is
/// different: cron starts ZenCRON with an empty mask. The harness reproduces
/// that by clearing the mask on the launcher thread (or by blocking just the
/// signals a test asks for). The same path is used on macOS and Linux.
private enum SignalMaskedLauncher {
    /// Runs `process` from a new thread whose signal mask blocks exactly
    /// `blockedSignals`, and resumes with the outcome of `run()`, errors
    /// included. The calling task is suspended, not blocked, while the thread
    /// works, so the cooperative pool stays free.
    static func run(_ process: Process, blockedSignals: [Int32]) async throws {
        let handoff = ProcessHandoff(process: process)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let thread = Thread {
                do {
                    try setSignalMask(blocking: blockedSignals)
                    try handoff.process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
            thread.name = "zencron-test-launcher"
            thread.start()
        }
    }

    /// Replaces the signal mask of the calling thread.
    private static func setSignalMask(blocking signals: [Int32]) throws {
        var mask = sigset_t()
        sigemptyset(&mask)
        for signalNumber in signals {
            sigaddset(&mask, signalNumber)
        }
        let status = pthread_sigmask(SIG_SETMASK, &mask, nil)
        guard status == 0 else {
            throw HostTestError(description: "pthread_sigmask failed: \(String(cString: strerror(status)))")
        }
    }
}

/// A launched host. Output goes to files rather than pipes so a chatty or
/// stuck child can never deadlock the test, and standard input is a pipe (as
/// cron provides one) that is filled and closed right after launch.
///
/// The host is started by `SignalMaskedLauncher`, with an empty signal mask
/// as under cron unless `blockedSignals` says otherwise.
///
/// Exit is observed through `terminationHandler`, never through
/// `Process.waitUntilExit()`: on Darwin that call waits on the run loop of the
/// calling thread and can park forever on a cooperative-pool thread when the
/// machine is busy, even though the child is long gone.
private final class HostProcess {
    let process = Process()
    private let outputURL: URL
    private let errorURL: URL
    private let exitFlag = ExitFlag()

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        outputDirectory: URL,
        blockedSignals: [Int32] = []
    ) async throws {
        outputURL = outputDirectory.appendingPathComponent("host-stdout-\(UUID().uuidString)")
        errorURL = outputDirectory.appendingPathComponent("host-stderr-\(UUID().uuidString)")
        let fileManager = FileManager.default
        // On Linux `createFile` is not discardable: check it instead of ignoring it.
        for url in [outputURL, errorURL] {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw HostTestError(description: "cannot create \(url.path)")
            }
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        let inputPipe = Pipe()
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = outputDirectory
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.standardInput = standardInput == nil ? FileHandle.nullDevice : inputPipe
        process.terminationHandler = { [exitFlag] _ in
            exitFlag.set()
        }
        try await SignalMaskedLauncher.run(process, blockedSignals: blockedSignals)

        // The parent keeps the read end open until the data is written, so the
        // write cannot hit EPIPE even if the child never reads.
        if let standardInput {
            try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
        }
        try inputPipe.fileHandleForWriting.close()
        try inputPipe.fileHandleForReading.close()
    }

    deinit {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Waits for the host to exit; a host that outlives `timeout` is killed.
    func waitForExit(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !exitFlag.isSet {
            if Date() >= deadline {
                kill(process.processIdentifier, SIGKILL)
                // Bounded wait: the kill cannot be refused, but never park here.
                let killDeadline = Date().addingTimeInterval(5)
                while !exitFlag.isSet, Date() < killDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw HostTestError(description: "ZenCRON did not exit within \(timeout) seconds")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func result() -> HostRun {
        HostRun(
            status: process.terminationStatus,
            reason: process.terminationReason,
            standardOutput: (try? String(contentsOf: outputURL, encoding: .utf8)) ?? "",
            standardError: (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        )
    }
}
