//
//  ZenAppLaunchCommand.swift
//  ZenCODE
//
//  `zen --ui` (macOS only): validates the options forwarded to the ZenCODE
//  app, builds and installs the app when the running `zen` is new to it, and
//  starts it detached so that the terminal returns at once. The machine work
//  (configuration, `swift`, the spawn) is injected through `Tools`, so tests
//  never run `swift build` nor start an app.
//

#if os(macOS)
import Darwin
import Foundation
import ToolCore

package enum ZenAppLaunchCommand {
    /// The option that opens the app.
    package static let option = "--ui"

    /// The options the app accepts, each followed by its value. Keep in sync
    /// with `ZenAppLaunchArguments.forwardedOptions` of the app package
    /// (`Sources/ZenApp/Sources/ZenAppSession/ZenAppLaunchArguments.swift`),
    /// which reads them from the app's command line.
    static let forwardedOptions: Set<String> = [
        "--agent", "--model", "--skills", "--working-directory", "--worktree"
    ]

    /// Options of the other modes, refused with `--ui`.
    static let conflictingOptions: Set<String> = [
        "-p", "--prompt", "-f", "--jsonl", "--acp", "--tui", "--telegram",
        "--max-tool-rounds", "--max-output-tokens"
    ]

    /// Whether `arguments` (with the executable at index 0) ask for the app.
    package static func isRequested(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains(option)
    }

    /// The arguments forwarded to the app: every `--agent`, `--model`,
    /// `--skills`, `--working-directory` and `--worktree` with its value, in
    /// order, without the executable and without `--ui` (which may be
    /// repeated).
    ///
    /// - Throws: `AgentConfigurationError.missingValue` for a forwarded option
    ///   without a value, `.conflictingOptions("--ui", option)` for an option of
    ///   another mode, `.unknownArgument` for anything else, and whatever
    ///   `AgentConfiguration.validateArguments` reports for what is kept.
    package static func forwardedArguments(from arguments: [String]) throws -> [String] {
        var kept: [String] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == option {
                index += 1
            } else if forwardedOptions.contains(argument) {
                guard index + 1 < arguments.count else {
                    throw AgentConfigurationError.missingValue(argument)
                }
                kept.append(argument)
                kept.append(arguments[index + 1])
                index += 2
            } else if conflictingOptions.contains(argument) {
                throw AgentConfigurationError.conflictingOptions(option, argument)
            } else {
                throw AgentConfigurationError.unknownArgument(argument)
            }
        }
        try AgentConfiguration.validateArguments(["zen"] + kept)
        return kept
    }

    /// Opens the app with `forwardedArguments` and returns the exit status of
    /// `zen`: 0 once the app runs, 1 after printing `ZenCODE: <message>` on
    /// standard error.
    package static func run(forwardedArguments: [String]) async -> Int32 {
        await run(forwardedArguments: forwardedArguments, tools: .live)
    }

    /// `run(forwardedArguments:)` over `tools`:
    ///
    /// 1. prepares the worktree of `--worktree NAME`, if any
    ///    (`AgentWorktreeManager.rewritingArguments`): its directory becomes
    ///    the last `--working-directory`, so it is the workspace;
    /// 2. reads the configuration as the app will (the persisted settings), so
    ///    an unknown agent is reported here and the workspace is known;
    /// 3. builds and installs the app when needed (`preparedExecutable`);
    /// 4. starts it with `appArguments`: the forwarded options and the
    ///    workspace;
    /// 5. prints `Started the ZenCODE app in <workspace>.`
    static func run(forwardedArguments: [String], tools: Tools) async -> Int32 {
        do {
            let arguments = try await AgentWorktreeManager.rewritingArguments(
                ["zen"] + forwardedArguments,
                environment: ProcessInfo.processInfo.environment
            )
            let forwardedArguments = Array(arguments.dropFirst())
            let configuration = try tools.configuration(arguments)
            let layout = ZenAppInstallation.Layout(supportDirectory: tools.supportDirectory())
            let executable = try await preparedExecutable(tools: tools, layout: layout)
            _ = try await tools.launch(
                executable,
                appArguments(forwardedArguments: forwardedArguments, workspace: configuration.workingDirectory),
                layout.logFile
            )
            let workspace = LocalExecPermissionAuthorizer.abbreviatedHomePath(
                configuration.workingDirectory.path,
                homeDirectory: tools.homeDirectory()
            )
            tools.writeOutput("Started the ZenCODE app in \(workspace).\n")
            return 0
        } catch {
            tools.writeError("ZenCODE: \(error.localizedDescription)\n")
            return 1
        }
    }

    /// The arguments the app starts with: `forwardedArguments` (option and
    /// value pairs), followed by `--working-directory <workspace>` when they
    /// have no `--working-directory`. The app then opens the workspace that
    /// `zen` resolved and prints: without the option, its configuration would
    /// compare the current directory with the app's own folder, not `zen`'s.
    ///
    /// Only the last `--working-directory` is kept, where it is: it is the one
    /// that wins, and with `--worktree` it is the worktree's, appended after
    /// the one given on the command line.
    static func appArguments(forwardedArguments: [String], workspace: URL) -> [String] {
        let pairs = stride(from: 0, to: forwardedArguments.count, by: 2).map {
            Array(forwardedArguments[$0..<min($0 + 2, forwardedArguments.count)])
        }
        guard let lastWorkingDirectory = pairs.lastIndex(where: { $0.first == "--working-directory" }) else {
            return forwardedArguments + ["--working-directory", workspace.path]
        }
        return pairs.indices
            .filter { $0 == lastWorkingDirectory || pairs[$0].first != "--working-directory" }
            .flatMap { pairs[$0] }
    }

    /// The installed executable, built and installed first when the installed
    /// app does not match the running `zen` (`ZenAppInstallation.decision`).
    ///
    /// A build happens under the install lock: the decision is taken again
    /// once the lock is held, so a run that waited for another one building
    /// the same app only launches it, and the leftovers of an interrupted
    /// install are removed first.
    static func preparedExecutable(
        tools: Tools,
        layout: ZenAppInstallation.Layout,
        fileManager: FileManager = .default
    ) async throws -> URL {
        let sourcePackage = try tools.sourcePackage()
        let stamp = try ZenAppInstallation.BuildStamp.current(
            zenExecutable: try tools.zenExecutable(),
            sourcePackage: sourcePackage,
            fileManager: fileManager
        )
        if ZenAppInstallation.decision(layout: layout, currentStamp: stamp, fileManager: fileManager) == .launchInstalled {
            return layout.installedExecutable
        }

        let lock = try await ZenAppInstallation.acquireInstallLock(layout: layout, fileManager: fileManager)
        defer { ZenAppInstallation.releaseInstallLock(lock) }
        ZenAppInstallation.removeInstallLeftovers(layout: layout, fileManager: fileManager)
        switch ZenAppInstallation.decision(layout: layout, currentStamp: stamp, fileManager: fileManager) {
        case .launchInstalled:
            return layout.installedExecutable
        case .build:
            tools.writeOutput(
                "Building the ZenCODE app (first use or after a ZenCODE update, this can take a few minutes)…\n"
            )
            let binDirectory = try await build(sourcePackage: sourcePackage, layout: layout, tools: tools)
            let installed = try ZenAppInstallation.install(
                binDirectory: binDirectory,
                stamp: stamp,
                layout: layout,
                fileManager: fileManager
            )
            tools.writeOutput("Installed the ZenCODE app in \(layout.currentDirectory.path).\n")
            return installed
        }
    }

    /// Runs the release build, then asks SwiftPM for its bin directory.
    static func build(
        sourcePackage: URL,
        layout: ZenAppInstallation.Layout,
        tools: Tools,
        timeout: TimeInterval = ZenAppInstallation.defaultBuildTimeout
    ) async throws -> URL {
        let writeOutput = tools.writeOutput
        let result: ZenAppInstallation.SwiftRunResult
        do {
            result = try await tools.runSwift(
                ZenAppInstallation.buildArguments(sourcePackage: sourcePackage, layout: layout),
                sourcePackage,
                timeout,
                { elapsedSeconds in
                    writeOutput("Still building the ZenCODE app… \(elapsedSeconds)s elapsed.\n")
                }
            )
        } catch {
            throw ZenAppInstallation.InstallationError.swiftUnavailable(error.localizedDescription)
        }
        guard !result.timedOut else {
            throw ZenAppInstallation.InstallationError.buildTimedOut(
                seconds: Int(timeout),
                output: ZenAppInstallation.usefulOutput(result)
            )
        }
        guard result.exitCode == 0 else {
            throw ZenAppInstallation.InstallationError.buildFailed(
                status: result.exitCode,
                output: ZenAppInstallation.usefulOutput(result)
            )
        }

        let binPath: ZenAppInstallation.SwiftRunResult
        do {
            binPath = try await tools.runSwift(
                ZenAppInstallation.binPathArguments(sourcePackage: sourcePackage, layout: layout),
                sourcePackage,
                ZenAppInstallation.binPathTimeout,
                nil
            )
        } catch {
            throw ZenAppInstallation.InstallationError.swiftUnavailable(error.localizedDescription)
        }
        guard !binPath.timedOut,
              binPath.exitCode == 0,
              let binDirectory = ZenAppInstallation.binDirectory(fromShowBinPathOutput: binPath.stdout) else {
            let output = ZenAppInstallation.usefulOutput(binPath)
            let summary = binPath.timedOut
                ? "it did not finish within \(Int(ZenAppInstallation.binPathTimeout)) seconds"
                : "it exited with status \(binPath.exitCode)"
            throw ZenAppInstallation.InstallationError.binPathUnavailable(
                output.isEmpty ? summary : "\(summary)\n\(output)"
            )
        }
        return binDirectory
    }
}

// MARK: - Tools

extension ZenAppLaunchCommand {
    /// Runs `swift` with arguments in a working directory, within a timeout,
    /// and calls `progress` with the elapsed seconds every
    /// `ZenAppInstallation.buildProgressIntervalSeconds` while it runs.
    typealias SwiftRunner = @Sendable (
        _ arguments: [String],
        _ workingDirectory: URL,
        _ timeout: TimeInterval,
        _ progress: (@Sendable (_ elapsedSeconds: Int) -> Void)?
    ) async throws -> ZenAppInstallation.SwiftRunResult

    /// Everything `zen --ui` takes from the machine, so tests can run it
    /// without a configuration, a toolchain, a build or an app.
    struct Tools: Sendable {
        /// The configuration for `arguments` (`zen` plus the forwarded
        /// options), read with the persisted settings.
        var configuration: @Sendable (_ arguments: [String]) throws -> AgentConfiguration
        /// The support directory the app is installed under.
        var supportDirectory: @Sendable () -> URL
        /// The package to build (`<checkout>/Sources/ZenApp`).
        var sourcePackage: @Sendable () throws -> URL
        /// The running `zen` executable, for the stamp (which resolves its
        /// symbolic links).
        var zenExecutable: @Sendable () throws -> URL
        /// The home directory, abbreviated to `~` in the printed workspace.
        var homeDirectory: @Sendable () -> String
        var runSwift: SwiftRunner
        /// Starts the installed app detached and returns its process id.
        var launch: @Sendable (_ executable: URL, _ arguments: [String], _ logFile: URL) async throws -> pid_t
        var writeOutput: @Sendable (String) -> Void
        var writeError: @Sendable (String) -> Void

        static let live = Tools(
            configuration: { try AgentConfiguration(arguments: $0) },
            supportDirectory: { AppStorageDirectory.appSupportDirectoryURL() },
            sourcePackage: {
                try ZenAppInstallation.sourcePackageURL(
                    checkouts: ZenAppInstallation.defaultSourceCheckouts()
                )
            },
            zenExecutable: { try ZenAppInstallation.runningZenExecutableURL() },
            homeDirectory: { UserHomeDirectory.current().path },
            runSwift: { arguments, workingDirectory, timeout, progress in
                try await ZenAppLaunchCommand.runSwift(
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    timeout: timeout,
                    progress: progress
                )
            },
            launch: { executable, arguments, logFile in
                try await ZenAppProcessLauncher.launch(
                    executable: executable,
                    arguments: arguments,
                    logFile: logFile
                )
            },
            writeOutput: { AgentOutput.standardOutput.writeString($0) },
            writeError: { AgentOutput.standardError.writeString($0) }
        )
    }

    /// The real `swift`, started the way the ZenCRON build starts it: the
    /// toolchain found like `SwiftFeatureRuntime` does, the developer
    /// environment with the toolchain first on `PATH`, a timeout, and a
    /// periodic progress call.
    private static func runSwift(
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval,
        progress: (@Sendable (_ elapsedSeconds: Int) -> Void)?
    ) async throws -> ZenAppInstallation.SwiftRunResult {
        let baseEnvironment = ProcessInfo.processInfo.environment
        let swiftExecutableURL = try SwiftFeatureRuntime.swiftExecutableURL(
            fileManager: .default,
            environment: baseEnvironment
        )
        var environment = DeveloperToolEnvironment.processEnvironment(base: baseEnvironment)
        let swiftBinPath = swiftExecutableURL.deletingLastPathComponent().path
        let searchPaths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        if !searchPaths.contains(swiftBinPath) {
            environment["PATH"] = ([swiftBinPath] + searchPaths).joined(separator: ":")
        }

        let ticker = progress.map { progress in
            let interval = ZenAppInstallation.buildProgressIntervalSeconds
            return Task(name: "ZenCODE app SwiftPM build progress") {
                var elapsedSeconds = interval
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(interval))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    progress(elapsedSeconds)
                    elapsedSeconds += interval
                }
            }
        }
        defer { ticker?.cancel() }

        let result = try await AsyncProcessRunner.run(
            executableURL: swiftExecutableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout
        )
        return ZenAppInstallation.SwiftRunResult(
            exitCode: result.exitCode,
            timedOut: result.timedOut,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }
}
#endif
