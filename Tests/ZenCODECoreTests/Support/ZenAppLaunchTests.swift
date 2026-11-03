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
@testable import ZenCODECore

@Suite("zen --ui", .serialized)
struct ZenAppLaunchTests {
    private typealias Installation = ZenAppInstallation
    private typealias Stamp = ZenAppInstallation.BuildStamp
    private typealias Launcher = ZenAppProcessLauncher

    // MARK: - Parsing

    @Test
    func theOptionIsLookedForOnlyAfterTheExecutable() {
        #expect(ZenAppLaunchCommand.option == "--ui")
        #expect(ZenAppLaunchCommand.isRequested(["zen", "--ui"]))
        #expect(ZenAppLaunchCommand.isRequested(["zen", "--agent", "Developer", "--ui"]))
        #expect(!ZenAppLaunchCommand.isRequested(["zen"]))
        #expect(!ZenAppLaunchCommand.isRequested(["--ui"]))
        #expect(!ZenAppLaunchCommand.isRequested(["zen", "--acp", "-p", "hi"]))
    }

    @Test
    func theForwardedOptionsAreKeptInOrderWithoutTheRepeatedOption() throws {
        let kept = try ZenAppLaunchCommand.forwardedArguments(from: [
            "zen", "--ui",
            "--agent", "Developer",
            "--ui",
            "--model", "openrouter:openrouter/auto",
            "--skills", "all",
            "--working-directory", "/tmp/project",
            "--ui"
        ])
        #expect(kept == [
            "--agent", "Developer",
            "--model", "openrouter:openrouter/auto",
            "--skills", "all",
            "--working-directory", "/tmp/project"
        ])
        #expect(try ZenAppLaunchCommand.forwardedArguments(from: ["zen", "--ui"]).isEmpty)
    }

    @Test(arguments: ["-p", "--prompt", "-f", "--jsonl", "--acp", "--max-tool-rounds", "--max-output-tokens"])
    func theOptionsOfTheOtherModesConflict(option: String) {
        let expected = "Options --ui and \(option) cannot be combined."
        #expect(Self.parsingError(["zen", "--ui", option, "value"]) == expected)
        #expect(Self.parsingError(["zen", option, "value", "--ui"]) == expected)
    }

    @Test
    func anythingElseIsAnUnknownArgument() {
        #expect(Self.parsingError(["zen", "--ui", "--bogus"]) == "Unknown argument: --bogus")
        #expect(Self.parsingError(["zen", "--ui", "stray"]) == "Unknown argument: stray")
        #expect(Self.parsingError(["zen", "--ui", "--agent", "Developer", "extra"]) == "Unknown argument: extra")
    }

    @Test(arguments: ["--agent", "--model", "--skills", "--working-directory"])
    func aForwardedOptionWithoutItsValueIsReported(option: String) {
        #expect(Self.parsingError(["zen", "--ui", option]) == "Missing value for \(option).")
    }

    /// `validateArguments` checks the syntax of what is kept, not the values
    /// of `--skills` and `--working-directory`: they reach the app unchanged,
    /// as they reach the chat.
    @Test(arguments: ["", "none", "unknown-skill,7", "/no/such/directory", "relative/directory"])
    func theValuesOfSkillsAndWorkingDirectoryPassValidationUnchanged(value: String) throws {
        let kept = try ZenAppLaunchCommand.forwardedArguments(from: [
            "zen", "--ui", "--skills", value, "--working-directory", value
        ])
        #expect(kept == ["--skills", value, "--working-directory", value])
    }

    // MARK: - Decision

    @Test
    func theAppIsBuiltUnlessTheInstalledOneMatchesTheRunningZen() {
        let stamp = Self.stamp()
        #expect(Installation.decision(installedExecutableIsRunnable: true, installedStamp: stamp, currentStamp: stamp) == .launchInstalled)
        #expect(Installation.decision(installedExecutableIsRunnable: false, installedStamp: stamp, currentStamp: stamp) == .build)
        #expect(Installation.decision(installedExecutableIsRunnable: true, installedStamp: nil, currentStamp: stamp) == .build)

        var changes: [Stamp] = []
        var version = stamp; version.zenVersion = "9.9.9"; changes.append(version)
        var path = stamp; path.zenExecutablePath = "/elsewhere/zen"; changes.append(path)
        var date = stamp; date.zenExecutableModificationDate.addTimeInterval(1); changes.append(date)
        var size = stamp; size.zenExecutableSize += 1; changes.append(size)
        var source = stamp; source.sourcePackagePath = "/other/Sources/ZenApp"; changes.append(source)
        for changed in changes {
            #expect(Installation.decision(installedExecutableIsRunnable: true, installedStamp: changed, currentStamp: stamp) == .build)
        }
    }

    @Test
    func theDecisionReadsTheInstalledExecutableAndItsStamp() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let layout = Installation.Layout(supportDirectory: root)
        let stamp = Self.stamp()

        #expect(Installation.decision(layout: layout, currentStamp: stamp) == .build)

        try Self.writeFile("#!/bin/sh\n", to: layout.installedExecutable, permissions: 0o755)
        #expect(Installation.decision(layout: layout, currentStamp: stamp) == .build)

        try Installation.encodedStamp(stamp).write(to: layout.stampFile)
        #expect(Installation.decision(layout: layout, currentStamp: stamp) == .launchInstalled)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: layout.installedExecutable.path)
        #expect(Installation.decision(layout: layout, currentStamp: stamp) == .build)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.installedExecutable.path)
        try Self.writeFile("{ not a stamp", to: layout.stampFile)
        #expect(Installation.readStamp(at: layout.stampFile) == nil)
        #expect(Installation.decision(layout: layout, currentStamp: stamp) == .build)
    }

    @Test
    func theStampDescribesTheRunningZenThroughItsSymbolicLinks() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let zen = root.appendingPathComponent("real/zen")
        try Self.writeFile("zen-binary", to: zen, permissions: 0o755)
        let link = root.appendingPathComponent("zen-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: zen)
        let package = root.appendingPathComponent("checkout/Sources/ZenApp", isDirectory: true)

        let stamp = try Stamp.current(zenExecutable: link, sourcePackage: package, zenVersion: "1.2.3")

        let modificationDate = try #require(
            FileManager.default.attributesOfItem(atPath: zen.path)[.modificationDate] as? Date
        )
        #expect(stamp.zenVersion == "1.2.3")
        #expect(stamp.zenExecutablePath == zen.resolvingSymlinksInPath().path)
        #expect(stamp.zenExecutableSize == 10)
        #expect(stamp.zenExecutableModificationDate.timeIntervalSince1970 == modificationDate.timeIntervalSince1970.rounded(.down))
        #expect(stamp.sourcePackagePath == package.standardizedFileURL.path)

        let stampFile = root.appendingPathComponent("build-stamp.json")
        try Installation.encodedStamp(stamp).write(to: stampFile)
        #expect(Installation.readStamp(at: stampFile) == stamp)
        #expect(Installation.readStamp(at: root.appendingPathComponent("missing.json")) == nil)

        #expect(throws: Installation.InstallationError.self) {
            try Stamp.current(zenExecutable: root.appendingPathComponent("missing-zen"), sourcePackage: package)
        }
    }

    // MARK: - Source checkout

    @Test
    func theFirstCheckoutWithTheAppPackageWins() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let plain = try Self.makeCheckout(at: root.appendingPathComponent("plain"), withApp: false)
        let first = try Self.makeCheckout(at: root.appendingPathComponent("first"), withApp: true)
        let second = try Self.makeCheckout(at: root.appendingPathComponent("second"), withApp: true)

        #expect(
            try Installation.sourcePackageURL(checkouts: [plain, first, second])
                == first.appendingPathComponent("Sources/ZenApp", isDirectory: true).standardizedFileURL
        )
        #expect(
            try Installation.sourcePackageURL(checkouts: [second, first])
                == second.appendingPathComponent("Sources/ZenApp", isDirectory: true).standardizedFileURL
        )
    }

    @Test
    func aCheckoutWithoutTheAppPackageIsNotAccepted() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let plain = try Self.makeCheckout(at: root.appendingPathComponent("plain"), withApp: false)
        let missing = root.appendingPathComponent("missing", isDirectory: true)

        do {
            _ = try Installation.sourcePackageURL(checkouts: [plain, missing])
            Issue.record("A checkout without Sources/ZenApp/Package.swift was accepted")
        } catch let error as Installation.InstallationError {
            #expect(error == .sourceNotFound(searchedCheckouts: [plain.path, missing.path]))
            let message = error.localizedDescription
            #expect(message.contains("Sources/ZenApp/Package.swift"))
            #expect(message.contains("\(plain.path), \(missing.path)"))
            #expect(message.contains("Reinstall ZenCODE with Scripts/install.sh"))
            #expect(message.contains("run a zen built from a ZenCODE checkout"))
        }
    }

    @Test
    func theDefaultCheckoutsAreTheBuildCheckoutThenTheInstallerCopy() throws {
        let checkouts = Installation.defaultSourceCheckouts()
        let buildCheckout = try #require(SwiftFeatureRuntime.sourcePackageRootURL(fileManager: .default))
        #expect(checkouts == [
            buildCheckout.standardizedFileURL,
            SwiftFeatureRuntime.supportSourceCheckoutURL().standardizedFileURL
        ])
        // The tests run from a ZenCODE checkout, which has the app package.
        #expect(
            try Installation.sourcePackageURL(checkouts: checkouts)
                == buildCheckout.appendingPathComponent("Sources/ZenApp", isDirectory: true).standardizedFileURL
        )
    }

    // MARK: - Build helpers

    @Test
    func theBuildCommandsUseTheScratchPathOfTheSupportDirectory() {
        let layout = Installation.Layout(supportDirectory: URL(fileURLWithPath: "/support", isDirectory: true))
        let package = URL(fileURLWithPath: "/src/Sources/ZenApp", isDirectory: true)
        #expect(layout.buildDirectory.path == "/support/app/build")
        #expect(layout.currentDirectory.path == "/support/app/current")
        #expect(layout.installedExecutable.path == "/support/app/current/ZenCODE")
        #expect(layout.stampFile.path == "/support/app/current/build-stamp.json")
        #expect(layout.logFile.path == "/support/app/ZenCODE.log")
        #expect(Installation.buildArguments(sourcePackage: package, layout: layout) == [
            "build", "-c", "release", "--package-path", "/src/Sources/ZenApp",
            "--scratch-path", "/support/app/build", "--product", "ZenCODE"
        ])
        #expect(Installation.binPathArguments(sourcePackage: package, layout: layout) == [
            "build", "-c", "release", "--package-path", "/src/Sources/ZenApp",
            "--scratch-path", "/support/app/build", "--show-bin-path"
        ])
    }

    @Test
    func theBinDirectoryIsTheLastAbsoluteLineOfShowBinPath() {
        #expect(
            Installation.binDirectory(fromShowBinPathOutput: "warning: something\n/s/app/build/out/Products/Release\n\n")
                == URL(fileURLWithPath: "/s/app/build/out/Products/Release", isDirectory: true)
        )
        #expect(Installation.binDirectory(fromShowBinPathOutput: "") == nil)
        #expect(Installation.binDirectory(fromShowBinPathOutput: "relative/path\n") == nil)
    }

    @Test
    func theWorkspaceIsShownWithTheHomeAbbreviatedByTheSharedHelper() {
        func abbreviated(_ path: String) -> String {
            LocalExecPermissionAuthorizer.abbreviatedHomePath(path, homeDirectory: "/Users/me")
        }
        #expect(abbreviated("/Users/me/project") == "~/project")
        #expect(abbreviated("/Users/me") == "~")
        #expect(abbreviated("/Users/meow/project") == "/Users/meow/project")
        #expect(abbreviated("/tmp/project") == "/tmp/project")
    }

    @Test
    func theAppGetsTheWorkspaceOfZenUnlessAWorkingDirectoryIsForwarded() {
        let workspace = URL(fileURLWithPath: "/Users/me/project", isDirectory: true)
        func appArguments(_ forwarded: [String]) -> [String] {
            ZenAppLaunchCommand.appArguments(forwardedArguments: forwarded, workspace: workspace)
        }
        #expect(appArguments([]) == ["--working-directory", "/Users/me/project"])
        #expect(appArguments(["--agent", "Developer"]) == [
            "--agent", "Developer", "--working-directory", "/Users/me/project"
        ])
        #expect(appArguments(["--working-directory", "/tmp/other", "--agent", "Developer"]) == [
            "--working-directory", "/tmp/other", "--agent", "Developer"
        ])
        // A value that reads like the option is still a value.
        #expect(appArguments(["--model", "--working-directory"]) == [
            "--model", "--working-directory", "--working-directory", "/Users/me/project"
        ])
    }

    // MARK: - Install

    @Test
    func installingReplacesCurrentWithTheExecutableAndEveryBundle() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try Self.makeFakeBuild(in: bin)
        // A bundle that is a symbolic link is installed as a directory.
        let linkedTarget = root.appendingPathComponent("elsewhere/Linked_Resources.bundle", isDirectory: true)
        try Self.writeFile("linked", to: linkedTarget.appendingPathComponent("Contents/Resources/linked.txt"))
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("Linked_Resources.bundle"),
            withDestinationURL: linkedTarget
        )
        let layout = Installation.Layout(supportDirectory: root.appendingPathComponent("support", isDirectory: true))
        try Self.writeFile("old", to: layout.currentDirectory.appendingPathComponent("stale.txt"))
        let stamp = Self.stamp()

        let installed = try Installation.install(binDirectory: bin, stamp: stamp, layout: layout)

        let fileManager = FileManager.default
        #expect(installed == layout.installedExecutable)
        #expect(fileManager.isExecutableFile(atPath: installed.path))
        #expect(try fileManager.contentsOfDirectory(atPath: layout.currentDirectory.path).sorted() == [
            "Linked_Resources.bundle", "ZenApp_ZenCODEApp.bundle", "ZenCODE", "build-stamp.json"
        ])
        let linked = layout.currentDirectory.appendingPathComponent("Linked_Resources.bundle")
        #expect(try fileManager.attributesOfItem(atPath: linked.path)[.type] as? FileAttributeType == .typeDirectory)
        #expect(try String(contentsOf: linked.appendingPathComponent("Contents/Resources/linked.txt"), encoding: .utf8) == "linked")
        #expect(try String(
            contentsOf: layout.currentDirectory.appendingPathComponent("ZenApp_ZenCODEApp.bundle/Contents/Resources/icon.svg"),
            encoding: .utf8
        ) == "<svg/>")
        #expect(Installation.readStamp(at: layout.stampFile) == stamp)
        // Neither the staging directory nor the previous `current` is left.
        #expect(try fileManager.contentsOfDirectory(atPath: layout.appDirectory.path) == ["current"])
    }

    @Test
    func aBuildWithoutTheExecutableInstallsNothing() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try Self.writeFile("<svg/>", to: bin.appendingPathComponent("ZenApp_ZenCODEApp.bundle/icon.svg"))
        let layout = Installation.Layout(supportDirectory: root.appendingPathComponent("support", isDirectory: true))
        try Self.writeFile("old", to: layout.currentDirectory.appendingPathComponent("stale.txt"))

        #expect(throws: Installation.InstallationError.productMissing(path: bin.appendingPathComponent("ZenCODE").path)) {
            try Installation.install(binDirectory: bin, stamp: Self.stamp(), layout: layout)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.appDirectory.path) == ["current"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.currentDirectory.path) == ["stale.txt"])
    }

    // MARK: - Launcher

    @Test
    func theWaitStatusIsDescribed() {
        #expect(Launcher.terminationDescription(waitStatus: 3 << 8) == "exit status 3")
        #expect(Launcher.terminationDescription(waitStatus: 0) == "exit status 0")
        #expect(Launcher.terminationDescription(waitStatus: SIGKILL) == "terminated by signal 9")
        #expect(Launcher.childEnvironment(["ZENCODE_AGENT_MODE": "acp", "PATH": "/bin"]) == ["PATH": "/bin"])
    }

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
    func aRunningAppIsDetachedWithItsArgumentsAndWithoutTheAgentMode() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let script = root.appendingPathComponent("runs")
        try Self.writeFile(
            """
            #!/bin/sh
            echo "mode=${ZENCODE_AGENT_MODE-unset}"
            echo "marker=${ZEN_APP_LAUNCH_TEST_MARKER-unset}"
            echo "args=$*"
            exec sleep 30

            """,
            to: script,
            permissions: 0o755
        )
        let log = root.appendingPathComponent("app/ZenCODE.log")
        var environment = ProcessInfo.processInfo.environment
        environment["ZENCODE_AGENT_MODE"] = "acp"
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
        #expect(output == "mode=unset\nmarker=kept\nargs=--agent Developer\n")

        #expect(kill(pid, SIGTERM) == 0)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)
        reaped = true
        #expect(Launcher.terminationDescription(waitStatus: status) == "terminated by signal \(SIGTERM)")
    }

    @Test
    func anExecutableThatCannotBeSpawnedIsReported() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let missing = root.appendingPathComponent("missing")

        await #expect(throws: Launcher.LaunchError.spawnFailed(
            path: missing.path,
            reason: "posix_spawn: No such file or directory"
        )) {
            _ = try await Launcher.launch(
                executable: missing,
                arguments: [],
                logFile: root.appendingPathComponent("app/ZenCODE.log")
            )
        }
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
            Started the ZenCODE app in \(fixture.workspace.path).

            """)
        #expect(state.error.isEmpty)
        #expect(FileManager.default.isExecutableFile(atPath: layout.installedExecutable.path))
        let stamp = try #require(Installation.readStamp(at: layout.stampFile))
        #expect(stamp.sourcePackagePath == fixture.package.path)
        #expect(stamp.zenExecutablePath == fixture.zen.resolvingSymlinksInPath().path)

        // Same zen: the installed app starts as it is.
        fixture.recorder.reset()
        #expect(await ZenAppLaunchCommand.run(forwardedArguments: forwarded, tools: tools) == 0)
        state = fixture.recorder.snapshot
        #expect(state.swiftCalls.isEmpty)
        #expect(state.launches.count == 1)
        #expect(state.output == "Started the ZenCODE app in \(fixture.workspace.path).\n")

        // A new zen (another size): the app is built again.
        fixture.recorder.reset()
        try Self.writeFile("zen-binary-updated", to: fixture.zen, permissions: 0o755)
        #expect(await ZenAppLaunchCommand.run(forwardedArguments: forwarded, tools: tools) == 0)
        state = fixture.recorder.snapshot
        #expect(state.swiftCalls.count == 2)
        #expect(state.launches.count == 1)
        #expect(state.output.hasPrefix("Building the ZenCODE app"))
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
    func aConfigurationErrorIsReportedBeforeAnyBuild() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let fixture = try Fixture(root: root)
        var tools = fixture.tools()
        tools.configuration = { _ in
            throw AgentConfigurationError.unknownAgent("Nobody", ["Developer", "Reviewer"])
        }

        #expect(await ZenAppLaunchCommand.run(forwardedArguments: ["--agent", "Nobody"], tools: tools) == 1)

        let state = fixture.recorder.snapshot
        #expect(state.error == "ZenCODE: Unknown agent 'Nobody'. Available agents: Developer, Reviewer.\n")
        #expect(state.swiftCalls.isEmpty)
        #expect(state.launches.isEmpty)
        #expect(state.output.isEmpty)
    }

    @Test
    func aMissingCheckoutAndAnAppThatDoesNotStartAreReported() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let fixture = try Fixture(root: root)
        let missing = root.appendingPathComponent("no-checkout", isDirectory: true)
        var tools = fixture.tools()
        tools.sourcePackage = { try Installation.sourcePackageURL(checkouts: [missing]) }

        #expect(await ZenAppLaunchCommand.run(forwardedArguments: [], tools: tools) == 1)
        #expect(fixture.recorder.snapshot.error.hasPrefix("ZenCODE: The ZenCODE app cannot be built: no ZenCODE source checkout"))
        #expect(fixture.recorder.snapshot.launches.isEmpty)

        fixture.recorder.reset()
        let logPath = Installation.Layout(supportDirectory: fixture.support).logFile.path
        tools = fixture.tools()
        tools.launch = { _, _, _ in
            throw Launcher.LaunchError.exitedRightAfterStarting(
                termination: "exit status 3",
                logPath: logPath,
                output: "boom"
            )
        }
        #expect(await ZenAppLaunchCommand.run(forwardedArguments: [], tools: tools) == 1)
        let state = fixture.recorder.snapshot
        #expect(state.error == """
            ZenCODE: The ZenCODE app exited right after starting (exit status 3). Its output is in \(logPath):
            boom

            """)
        #expect(!state.output.contains("Started"))
    }

    @Test
    func withoutAWorkingDirectoryTheAppOpensTheWorkspaceZenPrints() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let fixture = try Fixture(root: root)
        let layout = Installation.Layout(supportDirectory: fixture.support)

        #expect(await ZenAppLaunchCommand.run(forwardedArguments: ["--agent", "Developer"], tools: fixture.tools()) == 0)

        let state = fixture.recorder.snapshot
        #expect(state.configurationArguments == [["zen", "--agent", "Developer"]])
        #expect(state.launches == [Recorder.Launch(
            executable: layout.installedExecutable,
            arguments: ["--agent", "Developer", "--working-directory", fixture.workspace.path],
            logFile: layout.logFile
        )])
        #expect(state.output.hasSuffix("Started the ZenCODE app in \(fixture.workspace.path).\n"))
    }

    @Test
    func aWorkspaceUnderTheHomeIsPrintedWithATilde() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let fixture = try Fixture(root: root)
        var tools = fixture.tools()
        let home = root.path
        tools.homeDirectory = { home }

        #expect(await ZenAppLaunchCommand.run(forwardedArguments: [], tools: tools) == 0)
        #expect(fixture.recorder.snapshot.output.hasSuffix("Started the ZenCODE app in ~/workspace.\n"))
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

    @Test
    func aBuildThatTimesOutIsReportedWithTheEndOfItsOutput() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let fixture = try Fixture(root: root)
        var tools = fixture.tools()
        let recorder = fixture.recorder
        tools.runSwift = { arguments, _, timeout, _ in
            recorder.update { $0.swiftCalls.append(arguments + ["timeout=\(Int(timeout))"]) }
            return Installation.SwiftRunResult(exitCode: 15, timedOut: true, stdout: "Compiling ZenCODEApp\n", stderr: "")
        }
        let layout = Installation.Layout(supportDirectory: fixture.support)

        #expect(await ZenAppLaunchCommand.run(forwardedArguments: [], tools: tools) == 1)

        let state = fixture.recorder.snapshot
        #expect(state.error == """
            ZenCODE: The ZenCODE app could not be built: swift build did not finish within 1800 seconds.
            Compiling ZenCODEApp

            """)
        // Only the build ran, with the 30-minute timeout.
        #expect(state.swiftCalls == [
            Installation.buildArguments(sourcePackage: fixture.package, layout: layout) + ["timeout=1800"]
        ])
        #expect(state.launches.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: layout.currentDirectory.path))
    }

    @Test(arguments: [
        (Installation.SwiftRunResult(exitCode: 1, timedOut: false, stdout: "", stderr: "error: no such product\n"),
         "it exited with status 1\nerror: no such product"),
        (Installation.SwiftRunResult(exitCode: 15, timedOut: true, stdout: "", stderr: ""),
         "it did not finish within 300 seconds"),
        (Installation.SwiftRunResult(exitCode: 0, timedOut: false, stdout: "relative/path\n", stderr: ""),
         "it exited with status 0\nrelative/path")
    ])
    func aShowBinPathStepThatFailsIsReportedAndNothingIsInstalled(
        binPathResult: ZenAppInstallation.SwiftRunResult,
        detail: String
    ) async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let fixture = try Fixture(root: root)
        var tools = fixture.tools()
        let fakeSwift = tools.runSwift
        tools.runSwift = { arguments, directory, timeout, progress in
            if arguments.contains("--show-bin-path") {
                return binPathResult
            }
            return try await fakeSwift(arguments, directory, timeout, progress)
        }
        let layout = Installation.Layout(supportDirectory: fixture.support)

        #expect(await ZenAppLaunchCommand.run(forwardedArguments: [], tools: tools) == 1)

        let state = fixture.recorder.snapshot
        #expect(state.error == """
            ZenCODE: The ZenCODE app was built, but swift build --show-bin-path did not report \
            the build directory: \(detail)

            """)
        #expect(state.launches.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: layout.currentDirectory.path))
    }

    @Test
    func aSwiftThatCannotRunIsReportedAsAMissingToolchain() async throws {
        struct SwiftNotFound: LocalizedError {
            var errorDescription: String? { "swift was not found" }
        }
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let fixture = try Fixture(root: root)
        let expected = "ZenCODE: The ZenCODE app cannot be built: swift could not be run (swift was not found). "
            + "Building it needs the Swift toolchain.\n"

        // The build cannot run.
        var tools = fixture.tools()
        tools.runSwift = { _, _, _, _ in throw SwiftNotFound() }
        #expect(await ZenAppLaunchCommand.run(forwardedArguments: [], tools: tools) == 1)
        #expect(fixture.recorder.snapshot.error == expected)
        #expect(fixture.recorder.snapshot.launches.isEmpty)

        // The build runs, then `--show-bin-path` cannot.
        fixture.recorder.reset()
        tools = fixture.tools()
        let fakeSwift = tools.runSwift
        tools.runSwift = { arguments, directory, timeout, progress in
            if arguments.contains("--show-bin-path") {
                throw SwiftNotFound()
            }
            return try await fakeSwift(arguments, directory, timeout, progress)
        }
        #expect(await ZenAppLaunchCommand.run(forwardedArguments: [], tools: tools) == 1)
        #expect(fixture.recorder.snapshot.error == expected)
        #expect(fixture.recorder.snapshot.launches.isEmpty)
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

    private static func parsingError(_ arguments: [String]) -> String? {
        do {
            _ = try ZenAppLaunchCommand.forwardedArguments(from: arguments)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func stamp() -> Stamp {
        Stamp(
            zenVersion: "1.0.0",
            zenExecutablePath: "/opt/zencode/bin/zen",
            zenExecutableModificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            zenExecutableSize: 42,
            sourcePackagePath: "/opt/zencode/source/Sources/ZenApp"
        )
    }

    fileprivate static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-app-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    fileprivate static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    fileprivate static func writeFile(_ text: String, to url: URL, permissions: Int = 0o644) throws {
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
    fileprivate static func makeFakeBuild(in bin: URL) throws {
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

/// A support directory, a source checkout, a `zen` executable, a home and a
/// workspace (outside the home) under one temporary root, and tools that fake
/// the build and the launch.
private struct Fixture {
    let support: URL
    let checkout: URL
    let package: URL
    let zen: URL
    let home: URL
    let workspace: URL
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
        bin = root.appendingPathComponent("build/out/Products/Release", isDirectory: true)
    }

    func tools() -> ZenAppLaunchCommand.Tools {
        let recorder = recorder
        let support = support
        let checkout = checkout
        let zen = zen
        let home = home.path
        let workspace = workspace
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
            writeOutput: { text in recorder.update { $0.output += text } },
            writeError: { text in recorder.update { $0.error += text } }
        )
    }
}
#endif
