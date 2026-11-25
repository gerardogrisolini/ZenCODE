//
//  ZenAppLaunchTests.swift
//  ZenCODECoreTests
//
//  `zen --ui` (macOS only): the option parsing, the build stamp and its
//  decision, the source checkout, the installation, the detached launcher,
//  and the whole run over injected tools. No test runs `swift build`, starts
//  the real app or touches the real support directory: the launcher starts
//  temporary shell scripts.
//

#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite("zen --ui", .serialized)
struct ZenAppLaunchTests {
    typealias Installation = ZenAppInstallation
    typealias Stamp = ZenAppInstallation.BuildStamp
    private typealias Launcher = ZenAppProcessLauncher

    // MARK: - Launcher

    @Test
    func anAppThatExitsRightAfterStartingIsReportedWithItsOutput() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let script = root.appendingPathComponent("exits")
        try Self.writeFile(
            "#!/bin/sh\necho \"first line\"\necho \"ZenCODE could not start: boom\" >&2\nexit 3\n",
            to: script,
            permissions: 0o755
        )
        let log = root.appendingPathComponent("app/ZenCODE.log")

        let error = try #require(await Self.launchError(of: script, logFile: log))
        #expect(error == .exitedRightAfterStarting(
            termination: "exit status 3",
            logPath: log.path,
            output: "first line\nZenCODE could not start: boom"
        ))
        #expect(error.localizedDescription == """
            The ZenCODE app exited right after starting (exit status 3). Its output is in \(log.path):
            first line
            ZenCODE could not start: boom
            """)
    }

    @Test
    func theLogIsPrivateWhenItIsCreatedAndWhenItAlreadyExists() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let script = root.appendingPathComponent("exits")
        try Self.writeFile("#!/bin/sh\necho done\nexit 0\n", to: script, permissions: 0o755)
        let log = root.appendingPathComponent("app/ZenCODE.log")

        #expect(await Self.launchError(of: script, logFile: log) != nil)
        #expect(try Self.permissions(of: log) == 0o600)

        // A log of an earlier version, readable by everyone.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
        #expect(await Self.launchError(of: script, logFile: log) != nil)
        #expect(try Self.permissions(of: log) == 0o600)
        #expect(try String(contentsOf: log, encoding: .utf8) == "done\n")
    }

    @Test
    func aRunningAppIsDetachedWithItsArgumentsAndTheEnvironmentOfZen() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let script = root.appendingPathComponent("runs")
        try Self.writeFile(
            """
            #!/bin/sh
            echo "marker=${ZEN_APP_LAUNCH_TEST_MARKER-unset}"
            echo "args=$*"
            exec sleep 30

            """,
            to: script,
            permissions: 0o755
        )
        let log = root.appendingPathComponent("app/ZenCODE.log")
        var environment = ProcessInfo.processInfo.environment
        environment["ZEN_APP_LAUNCH_TEST_MARKER"] = "kept"

        let pid = try await Launcher.launch(
            executable: script,
            arguments: ["--agent", "Developer"],
            logFile: log,
            environment: environment
        )
        var reaped = false
        defer {
            if !reaped {
                Self.killAndReap(pid)
            }
        }

        #expect(pid > 0)
        #expect(kill(pid, 0) == 0)
        // A session of its own: the terminal's hang-up and Ctrl+C never reach it.
        #expect(getsid(pid) == pid)
        let output = await Self.contents(of: log, onceTheyContain: "args=--agent Developer\n")
        #expect(output == "marker=kept\nargs=--agent Developer\n")

        #expect(kill(pid, SIGTERM) == 0)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)
        reaped = true
        #expect(Launcher.terminationDescription(waitStatus: status) == "terminated by signal \(SIGTERM)")
    }

    // MARK: - Run

    @Test
    func theFirstRunBuildsInstallsAndLaunchesAndTheNextOneOnlyLaunches() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let fixture = try Fixture(root: root)
        let tools = fixture.tools()
        let forwarded = ["--agent", "Developer", "--working-directory", fixture.workspace.path]
        let layout = Installation.Layout(supportDirectory: fixture.support)

        #expect(await ZenAppLaunchCommand.run(forwardedArguments: forwarded, tools: tools) == 0)

        var state = fixture.recorder.snapshot
        #expect(state.configurationArguments == [["zen"] + forwarded])
        #expect(state.swiftCalls == [
            Installation.buildArguments(sourcePackage: fixture.package, layout: layout),
            Installation.binPathArguments(sourcePackage: fixture.package, layout: layout)
        ])
        #expect(state.launches == [
            Recorder.Launch(executable: layout.installedExecutable, arguments: forwarded, logFile: layout.logFile)
        ])
        #expect(state.output == """
            Building the ZenCODE app (first use or after a ZenCODE update, this can take a few minutes)…
            Still building the ZenCODE app… 15s elapsed.
            Installed the ZenCODE app in \(layout.currentDirectory.path).
            Added \(fixture.applicationBundle.path): open it to choose a workspace folder.
            Started the ZenCODE app in \(fixture.workspace.path).

            """)
        #expect(state.error.isEmpty)
        #expect(FileManager.default.isExecutableFile(atPath: layout.installedExecutable.path))
        let stamp = try #require(Installation.readStamp(at: layout.stampFile))
        #expect(stamp.sourcePackagePath == fixture.package.path)
        #expect(stamp.zenExecutablePath == fixture.zen.resolvingSymlinksInPath().path)
        // The bundle is added once the app is installed: its icon is written
        // by the installed app, and it is signed before it is moved in.
        #expect(state.iconWrites.first?.first == layout.installedExecutable)
        #expect(state.signedBundles.count == 1)
        #expect(state.signedBundles.first?.lastPathComponent == "ZenCODE.app")
        #expect(state.signedBundles.first != fixture.applicationBundle)
        #expect(FileManager.default.isExecutableFile(
            atPath: fixture.applicationBundle.appendingPathComponent("Contents/MacOS/ZenCODE").path
        ))

        // Same zen: the installed app starts as it is.
        fixture.recorder.reset()
        #expect(await ZenAppLaunchCommand.run(forwardedArguments: forwarded, tools: tools) == 0)
        state = fixture.recorder.snapshot
        #expect(state.swiftCalls.isEmpty)
        #expect(state.signedBundles.isEmpty)
        #expect(state.launches.count == 1)
        #expect(state.output == "Started the ZenCODE app in \(fixture.workspace.path).\n")

        // A new zen (another size): the app is built again, and the bundle of
        // the earlier build is replaced.
        fixture.recorder.reset()
        try Self.writeFile("zen-binary-updated", to: fixture.zen, permissions: 0o755)
        #expect(await ZenAppLaunchCommand.run(forwardedArguments: forwarded, tools: tools) == 0)
        state = fixture.recorder.snapshot
        #expect(state.swiftCalls.count == 2)
        #expect(state.launches.count == 1)
        #expect(state.output.hasPrefix("Building the ZenCODE app"))
        #expect(state.output.contains("Updated \(fixture.applicationBundle.path).\n"))
        #expect(state.error.isEmpty)
    }

    @Test
    func aBundleThatCannotBeAddedToApplicationsIsAWarningAndTheAppStillStarts() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let fixture = try Fixture(root: root)
        var tools = fixture.tools()
        tools.signAppBundle = { _ in
            throw Installation.ApplicationBundleError.commandFailed("codesign exited with status 1: boom")
        }
        let layout = Installation.Layout(supportDirectory: fixture.support)

        #expect(await ZenAppLaunchCommand.run(forwardedArguments: [], tools: tools) == 0)

        let state = fixture.recorder.snapshot
        #expect(state.error == """
            ZenCODE: ZenCODE.app was not added to \(fixture.applications.path): it could not be signed \
            (codesign exited with status 1: boom).

            """)
        #expect(state.launches == [
            Recorder.Launch(
                executable: layout.installedExecutable,
                arguments: ["--working-directory", fixture.workspace.path],
                logFile: layout.logFile
            )
        ])
        #expect(state.output.hasSuffix("Started the ZenCODE app in \(fixture.workspace.path).\n"))
        #expect(!state.output.contains("Added"))
        #expect(!FileManager.default.fileExists(atPath: fixture.applicationBundle.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.appDirectory.path).sorted() == [
            ".install.lock", "current"
        ])
    }

    @Test
    func anotherSupportDirectoryDoesNotAddTheBundle() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let fixture = try Fixture(root: root)
        var tools = fixture.tools()
        tools.applicationsDirectory = { nil }

        #expect(await ZenAppLaunchCommand.run(forwardedArguments: [], tools: tools) == 0)

        let state = fixture.recorder.snapshot
        #expect(state.output.contains("""
            ZenCODE.app was not added to /Applications: ZENCODE_SUPPORT_DIRECTORY selects a support \
            directory other than ~/.zencode.

            """))
        #expect(state.iconWrites.isEmpty)
        #expect(state.signedBundles.isEmpty)
        #expect(state.error.isEmpty)
        #expect(state.launches.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.applications.path).isEmpty)
    }

    @Test
    func aFailedBuildIsReportedWithTheEndOfItsOutputAndNothingStarts() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let fixture = try Fixture(root: root)
        var tools = fixture.tools()
        tools.runSwift = { _, _, _, _ in
            Installation.SwiftRunResult(
                exitCode: 1,
                timedOut: false,
                stdout: (1...60).map { "line \($0)" }.joined(separator: "\n"),
                stderr: "error: fatalError\n"
            )
        }
        let layout = Installation.Layout(supportDirectory: fixture.support)

        #expect(await ZenAppLaunchCommand.run(forwardedArguments: [], tools: tools) == 1)

        let state = fixture.recorder.snapshot
        let lines = state.error.components(separatedBy: "\n")
        #expect(lines.first == "ZenCODE: The ZenCODE app could not be built: swift build exited with status 1.")
        // The last 40 lines of standard output and error together.
        #expect(Array(lines.dropFirst()) == (22...60).map { "line \($0)" } + ["error: fatalError", ""])
        #expect(state.launches.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: layout.currentDirectory.path))
        #expect(!state.output.contains("Started"))
    }

    @Test
    func aWorktreeIsPreparedAndTheAppOpensItAsItsOnlyWorkingDirectory() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let fixture = try Fixture(root: root)
        let repository = try await Self.makeRepository(at: root.appendingPathComponent("repo", isDirectory: true))
        var tools = fixture.tools()
        let recorder = fixture.recorder
        tools.configuration = { arguments in
            recorder.update { $0.configurationArguments.append(arguments) }
            return try AgentConfiguration.withoutPersistedConfiguration(arguments: arguments)
        }
        let forwarded = ["--working-directory", repository.path, "--worktree", "feature"]

        try await AppStorageDirectory.withSupportDirectoryURL(fixture.support) {
            #expect(await ZenAppLaunchCommand.run(forwardedArguments: forwarded, tools: tools) == 0)

            let expected = AgentWorktreeManager.directory(name: "feature", repositoryRoot: repository)
            let state = fixture.recorder.snapshot
            #expect(state.error.isEmpty)
            // The configuration reads the worktree as the last working directory.
            let arguments = try #require(state.configurationArguments.first)
            #expect(state.configurationArguments.count == 1)
            #expect(Array(arguments.dropLast(2)) == ["zen"] + forwarded)
            #expect(arguments.suffix(2).first == "--working-directory")
            let worktreePath = try #require(arguments.last)
            #expect(Self.sameFile(worktreePath, expected.path))
            #expect(try await Self.git(["rev-parse", "--abbrev-ref", "HEAD"], in: expected) == "feature")

            // The app gets the worktree, and no other working directory.
            let launch = try #require(state.launches.first)
            #expect(launch.arguments == ["--worktree", "feature", "--working-directory", worktreePath])
            let workspace = try AgentConfiguration.withoutPersistedConfiguration(arguments: arguments).workingDirectory
            #expect(Self.sameFile(workspace.path, expected.path))
            #expect(state.output.hasSuffix("Started the ZenCODE app in \(workspace.path).\n"))
        }
    }

    @Test
    func aWorktreeThatCannotBePreparedIsReportedAndNothingStarts() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let fixture = try Fixture(root: root)
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let tools = fixture.tools()

        let status = await AppStorageDirectory.withSupportDirectoryURL(fixture.support) {
            await ZenAppLaunchCommand.run(
                forwardedArguments: ["--working-directory", plain.path, "--worktree", "feature"],
                tools: tools
            )
        }

        #expect(status == 1)
        let state = fixture.recorder.snapshot
        #expect(state.error == "ZenCODE: \(AgentWorktreeError.notInRepository(path: plain.path).localizedDescription)\n")
        #expect(state.configurationArguments.isEmpty)
        #expect(state.swiftCalls.isEmpty)
        #expect(state.launches.isEmpty)
        #expect(state.output.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.support.appendingPathComponent("worktrees").path
        ))
    }

    @Test
    func twoRunsStartedTogetherBuildOnceAndRemoveTheLeftoversOfAnInterruptedInstall() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let fixture = try Fixture(root: root)
        var tools = fixture.tools()
        let fakeSwift = tools.runSwift
        tools.runSwift = { arguments, directory, timeout, progress in
            if !arguments.contains("--show-bin-path") {
                // Long enough for the other run to wait for the install lock.
                try await Task.sleep(for: .milliseconds(300))
            }
            return try await fakeSwift(arguments, directory, timeout, progress)
        }
        let layout = Installation.Layout(supportDirectory: fixture.support)
        try Self.writeFile("partial", to: layout.appDirectory.appendingPathComponent(".staging-interrupted/ZenCODE"))
        try Self.writeFile("old", to: layout.appDirectory.appendingPathComponent(".previous-interrupted/ZenCODE"))

        async let first = ZenAppLaunchCommand.preparedExecutable(tools: tools, layout: layout)
        async let second = ZenAppLaunchCommand.preparedExecutable(tools: tools, layout: layout)
        let executables = try await [first, second]

        #expect(executables == [layout.installedExecutable, layout.installedExecutable])
        let state = fixture.recorder.snapshot
        #expect(state.swiftCalls == [
            Installation.buildArguments(sourcePackage: fixture.package, layout: layout),
            Installation.binPathArguments(sourcePackage: fixture.package, layout: layout)
        ])
        #expect(state.output.components(separatedBy: "Building the ZenCODE app (").count == 2)
        #expect(state.output.components(separatedBy: "Installed the ZenCODE app in").count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.appDirectory.path).sorted() == [
            ".install.lock", "current"
        ])
    }

    @Test
    func theInstallLockIsPrivateExclusiveAndNotInherited() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let layout = Installation.Layout(supportDirectory: root)
        #expect(layout.installLockFile.path == root.appendingPathComponent("app/.install.lock").path)

        let descriptor = try await Installation.acquireInstallLock(layout: layout)
        defer { Installation.releaseInstallLock(descriptor) }
        #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        #expect(try Self.permissions(of: layout.installLockFile) == 0o600)

        let other = open(layout.installLockFile.path, O_RDWR | O_CLOEXEC)
        #expect(other >= 0)
        defer { _ = close(other) }
        let locked = flock(other, LOCK_EX | LOCK_NB)
        let code = errno
        #expect(locked == -1)
        #expect(code == EWOULDBLOCK)
    }

    // MARK: - Support

    /// Launches `script`, which exits at once, and returns why the launch
    /// failed. The watch is generous, since it ends as soon as the script is
    /// reaped; a script reported as running is stopped and reaped.
    private static func launchError(of script: URL, logFile: URL) async -> Launcher.LaunchError? {
        do {
            let pid = try await Launcher.launch(
                executable: script,
                arguments: [],
                logFile: logFile,
                startupObservation: .seconds(30)
            )
            killAndReap(pid)
            Issue.record("An app that exits at once was reported as started")
            return nil
        } catch let error as Launcher.LaunchError {
            return error
        } catch {
            Issue.record("Unexpected launch error: \(error)")
            return nil
        }
    }

    /// Stops a process the launcher started and reaps it.
    private static func killAndReap(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
    }

    /// The text of `file` once it contains `fragment`, or after `timeout`.
    private static func contents(
        of file: URL,
        onceTheyContain fragment: String,
        timeout: Duration = .seconds(10)
    ) async -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if text.contains(fragment) || clock.now >= deadline {
                return text
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func permissions(of url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    static func parsingError(_ arguments: [String]) -> String? {
        do {
            _ = try ZenAppLaunchCommand.forwardedArguments(from: arguments)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func stamp() -> Stamp {
        Stamp(
            zenVersion: "1.0.0",
            zenExecutablePath: "/opt/zencode/bin/zen",
            zenExecutableModificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            zenExecutableSize: 42,
            sourcePackagePath: "/opt/zencode/source/Sources/ZenApp"
        )
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-app-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A Git repository with one commit on `main`, its identity in its own
    /// configuration.
    private static func makeRepository(at repository: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try await git(["init", "--quiet"], in: repository)
        try await git(["symbolic-ref", "HEAD", "refs/heads/main"], in: repository)
        try await git(["config", "user.name", "ZenCODE Tests"], in: repository)
        try await git(["config", "user.email", "tests@example.com"], in: repository)
        try await git(["config", "commit.gpgsign", "false"], in: repository)
        try writeFile("initial\n", to: repository.appendingPathComponent("file.txt"))
        try await git(["add", "file.txt"], in: repository)
        try await git(["commit", "--quiet", "-m", "initial"], in: repository)
        return repository
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await AsyncProcessRunner.run(
            executableURL: GitExecutableResolver.executableURL(),
            arguments: ["-C", directory.path] + arguments,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: 60
        )
        try #require(result.exitCode == 0, "git \(arguments.joined(separator: " ")): \(result.stderr)")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: rhs).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func writeFile(_ text: String, to url: URL, permissions: Int = 0o644) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    /// A checkout with a root `Package.swift`, and `Sources/ZenApp/Package.swift`
    /// when `withApp`.
    fileprivate static func makeCheckout(at url: URL, withApp: Bool) throws -> URL {
        try writeFile("// swift-tools-version: 6.4\n", to: url.appendingPathComponent("Package.swift"))
        if withApp {
            try writeFile("// swift-tools-version: 6.4\n", to: url.appendingPathComponent("Sources/ZenApp/Package.swift"))
        }
        return url
    }

    /// What a release build leaves in its bin directory: the executable, a
    /// resource bundle, and files that are not installed.
    static func makeFakeBuild(in bin: URL) throws {
        try writeFile("#!/bin/sh\nexit 0\n", to: bin.appendingPathComponent("ZenCODE"), permissions: 0o755)
        try writeFile("<svg/>", to: bin.appendingPathComponent("ZenApp_ZenCODEApp.bundle/Contents/Resources/icon.svg"))
        try writeFile("dwarf", to: bin.appendingPathComponent("ZenCODE.dSYM/Contents/Resources/DWARF/ZenCODE"))
        try writeFile("object", to: bin.appendingPathComponent("ZenAppSession.o"))
        try writeFile("module", to: bin.appendingPathComponent("ZenAppSession.swiftmodule/arm64.swiftmodule"))
    }
}

/// What the injected tools of a run were asked to do.
private final class Recorder: Sendable {
    struct Launch: Equatable, Sendable {
        let executable: URL
        let arguments: [String]
        let logFile: URL
    }

    struct State: Sendable {
        var configurationArguments: [[String]] = []
        var swiftCalls: [[String]] = []
        var launches: [Launch] = []
        /// The executable and the icon file of every icon written.
        var iconWrites: [[URL]] = []
        /// The bundles signed, with the names of their `Contents` entries
        /// when they were signed.
        var signedBundles: [URL] = []
        var signedContents: [[String]] = []
        var output = ""
        var error = ""
    }

    private let state = Mutex(State())

    var snapshot: State {
        state.withLock { $0 }
    }

    func update(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func reset() {
        state.withLock { $0 = State() }
    }
}

/// A support directory, a source checkout, a `zen` executable, a home, a
/// workspace (outside the home) and an applications directory under one
/// temporary root, and tools that fake the build, the icon, the signature and
/// the launch.
private struct Fixture {
    let support: URL
    let checkout: URL
    let package: URL
    let zen: URL
    let home: URL
    let workspace: URL
    let applications: URL
    let bin: URL
    let recorder = Recorder()

    init(root: URL) throws {
        support = root.appendingPathComponent("support", isDirectory: true)
        checkout = try ZenAppLaunchTests.makeCheckout(at: root.appendingPathComponent("checkout"), withApp: true)
        package = checkout.appendingPathComponent("Sources/ZenApp", isDirectory: true).standardizedFileURL
        zen = root.appendingPathComponent("zen")
        try ZenAppLaunchTests.writeFile("zen-binary", to: zen, permissions: 0o755)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        bin = root.appendingPathComponent("build/out/Products/Release", isDirectory: true)
    }

    /// `<applications>/ZenCODE.app`.
    var applicationBundle: URL {
        applications.appendingPathComponent(ZenAppInstallation.applicationBundleName, isDirectory: true)
    }

    func tools() -> ZenAppLaunchCommand.Tools {
        let recorder = recorder
        let support = support
        let checkout = checkout
        let zen = zen
        let home = home.path
        let workspace = workspace
        let applications = applications
        let bin = bin
        return ZenAppLaunchCommand.Tools(
            configuration: { arguments in
                recorder.update { $0.configurationArguments.append(arguments) }
                return try AgentConfiguration(hostedModelID: "zen-app-model", workingDirectory: workspace)
            },
            supportDirectory: { support },
            sourcePackage: { try ZenAppInstallation.sourcePackageURL(checkouts: [checkout]) },
            zenExecutable: { zen },
            homeDirectory: { home },
            runSwift: { arguments, _, _, progress in
                recorder.update { $0.swiftCalls.append(arguments) }
                if arguments.contains("--show-bin-path") {
                    return ZenAppInstallation.SwiftRunResult(
                        exitCode: 0,
                        timedOut: false,
                        stdout: "warning: a note\n\(bin.path)\n",
                        stderr: ""
                    )
                }
                progress?(15)
                try ZenAppLaunchTests.makeFakeBuild(in: bin)
                return ZenAppInstallation.SwiftRunResult(exitCode: 0, timedOut: false, stdout: "Build complete!\n", stderr: "")
            },
            launch: { executable, arguments, logFile in
                recorder.update {
                    $0.launches.append(Recorder.Launch(executable: executable, arguments: arguments, logFile: logFile))
                }
                return 4_242
            },
            applicationsDirectory: { applications },
            writeAppIcon: { executable, icon in
                recorder.update { $0.iconWrites.append([executable, icon]) }
                try Data("icns".utf8).write(to: icon)
            },
            signAppBundle: { bundle in
                let contents = (try? FileManager.default.contentsOfDirectory(
                    atPath: bundle.appendingPathComponent("Contents").path
                ))?.sorted() ?? []
                recorder.update {
                    $0.signedBundles.append(bundle)
                    $0.signedContents.append(contents)
                }
            },
            writeOutput: { text in recorder.update { $0.output += text } },
            writeError: { text in recorder.update { $0.error += text } }
        )
    }
}
#endif
