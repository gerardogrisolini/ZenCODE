//
//  ZenCODESetupRunner+ScheduledPrompts.swift
//  ZenCODE
//
//  The "Scheduled prompts (ZenCRON)" setup section. ZenCRON is the stable host
//  that cron starts for the prompts scheduled with `/cron add`: on macOS the
//  privacy permissions of a cron job go to the first program cron launches, so
//  that program must not change at every ZenCODE update. Like the optional
//  features, it is built from the ZenCODE source checkout by `/setup`, not by
//  the installer, and installed without sudo at `<support directory>/bin`.
//
//  The section keeps nothing in the settings manifest; it only builds and
//  installs. The build and the process execution are injected (see
//  `ZenCRONSetupTools`) so tests never run `swift build`.
//

import Foundation
import ToolCore

extension ZenCODESetupRunner {
    // MARK: - Status

    /// What the setup menu shows about the installed ZenCRON.
    struct ZenCRONSetupStatus: Equatable, Sendable {
        enum State: Equatable, Sendable {
            case notInstalled
            /// An executable file is present; its version was not read (the
            /// menu default, which starts no process).
            case installedUnchecked
            case installed(version: String)
            /// An executable file is present but did not report its version.
            case unreadable(reason: String)
        }

        let path: String
        let state: State

        /// The detail shown next to the section in the main menu.
        var detail: String {
            switch state {
            case .notInstalled:
                return "not installed"
            case .installedUnchecked:
                return "installed"
            case let .installed(version):
                return "\(version) installed"
            case .unreadable:
                return "installed, but it does not start"
            }
        }

        /// Whether the section is ready, for the status marker.
        var isReady: Bool {
            switch state {
            case .installedUnchecked, .installed:
                return true
            case .notInstalled, .unreadable:
                return false
            }
        }

        /// The line shown when the section opens.
        var summary: String {
            switch state {
            case .notInstalled:
                return "ZenCRON: not installed (expected at \(path))"
            case .installedUnchecked:
                return "ZenCRON: installed at \(path)"
            case let .installed(version):
                return "ZenCRON: \(version) installed at \(path)"
            case let .unreadable(reason):
                return "ZenCRON: installed at \(path), but it does not start (\(reason))"
            }
        }

        /// File-system only: no process is started, so it is safe wherever a
        /// synchronous answer is needed.
        static func fileCheck(
            supportDirectory: URL = ZenFileService.supportDirectoryURL(),
            fileManager: FileManager = .default
        ) -> ZenCRONSetupStatus {
            let url = ZenCRONInstallation.installedExecutableURL(supportDirectory: supportDirectory)
            return ZenCRONSetupStatus(
                path: url.path,
                state: fileManager.isExecutableFile(atPath: url.path) ? .installedUnchecked : .notInstalled
            )
        }

        /// Like `fileCheck`, and when an executable is present asks it for its
        /// version.
        static func load(
            supportDirectory: URL = ZenFileService.supportDirectoryURL(),
            fileManager: FileManager = .default,
            readVersion: @Sendable (URL) async throws -> String = {
                try await ZenCRONInstallation.version(ofExecutableAt: $0)
            }
        ) async -> ZenCRONSetupStatus {
            let url = ZenCRONInstallation.installedExecutableURL(supportDirectory: supportDirectory)
            guard fileManager.isExecutableFile(atPath: url.path) else {
                return ZenCRONSetupStatus(path: url.path, state: .notInstalled)
            }
            do {
                return ZenCRONSetupStatus(
                    path: url.path,
                    state: .installed(version: try await readVersion(url))
                )
            } catch {
                return ZenCRONSetupStatus(
                    path: url.path,
                    state: .unreadable(reason: error.localizedDescription)
                )
            }
        }
    }

    // MARK: - Injected tools

    /// The result of `swift build`, as the section needs it.
    struct ZenCRONBuildResult: Equatable, Sendable {
        let exitCode: Int32
        let timedOut: Bool
        let stdout: String
        let stderr: String
    }

    /// Everything the build-and-install flow takes from the machine, so tests
    /// can run it without a checkout, a toolchain or a real ZenCRON.
    struct ZenCRONSetupTools: Sendable {
        /// The ZenCODE source checkout (the same one the features use).
        var checkoutURL: @Sendable () throws -> URL
        /// Runs `swift build -c release --product ZenCRON` on a package copy
        /// and reports progress lines while it runs.
        var build: @Sendable (
            _ packageDirectory: URL,
            _ timeout: TimeInterval,
            _ progress: @escaping @Sendable (String) -> Void
        ) async throws -> ZenCRONBuildResult
        /// Runs `<executable> --zencron-version` and returns its version line.
        var readVersion: @Sendable (_ executable: URL) async throws -> String
        var platform: ZenCRONInstallation.Platform

        static let live = ZenCRONSetupTools(
            checkoutURL: { try SwiftFeatureRuntime.zenCODESourceCheckoutURL() },
            build: { packageDirectory, timeout, progress in
                try await ZenCODESetupRunner.runZenCRONSwiftBuild(
                    packageDirectory: packageDirectory,
                    timeout: timeout,
                    progress: progress
                )
            },
            readVersion: { try await ZenCRONInstallation.version(ofExecutableAt: $0) },
            platform: .current
        )
    }

    private static let zenCRONBuildProgressIntervalSeconds = 15

    /// The real `swift build`, started the way the features start it: the
    /// toolchain found like `SwiftFeatureRuntime` does, the developer
    /// environment, a timeout, and a periodic "still building" line.
    private static func runZenCRONSwiftBuild(
        packageDirectory: URL,
        timeout: TimeInterval,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> ZenCRONBuildResult {
        let fileManager = FileManager.default
        let baseEnvironment = ProcessInfo.processInfo.environment
        let swiftExecutableURL = try SwiftFeatureRuntime.swiftExecutableURL(
            fileManager: fileManager,
            environment: baseEnvironment
        )
        var environment = DeveloperToolEnvironment.processEnvironment(base: baseEnvironment)
        let swiftBinPath = swiftExecutableURL.deletingLastPathComponent().path
        let searchPaths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        if !searchPaths.contains(swiftBinPath) {
            environment["PATH"] = ([swiftBinPath] + searchPaths).joined(separator: ":")
        }

        let interval = zenCRONBuildProgressIntervalSeconds
        let ticker = Task(name: "ZenCRON SwiftPM build progress") {
            var elapsedSeconds = interval
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                progress("Still building \(ZenCRONInstallation.executableName)… \(elapsedSeconds)s elapsed.")
                elapsedSeconds += interval
            }
        }
        defer { ticker.cancel() }

        let result = try await AsyncProcessRunner.run(
            executableURL: swiftExecutableURL,
            arguments: zenCRONBuildArguments(packageDirectory: packageDirectory),
            workingDirectory: packageDirectory,
            environment: environment,
            timeout: timeout
        )
        return ZenCRONBuildResult(
            exitCode: result.exitCode,
            timedOut: result.timedOut,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }

    /// Arguments of `swift` for the release build of the ZenCRON product.
    static func zenCRONBuildArguments(packageDirectory: URL) -> [String] {
        [
            "build", "-c", "release",
            "--product", ZenCRONInstallation.executableName,
            "--package-path", packageDirectory.path
        ]
    }

    // MARK: - Outcome

    /// How one build-and-install run ended.
    enum ZenCRONSetupOutcome: Equatable {
        case installed(path: String, version: String)
        /// macOS only: the installed version equals the built one.
        case kept(path: String, version: String)
        case replaced(path: String, version: String)
        /// No source checkout, or no ZenCRON package in it.
        case sourceMissing(detail: String)
        case buildFailed(summary: String, output: String)
        case versionUnreadable(path: String, reason: String)
        case installFailed(message: String)

        /// The message shown to the operator.
        var message: String {
            switch self {
            case let .installed(path, version):
                return "Installed \(version) at \(path)."
            case let .kept(path, version):
                return "\(version) is already installed at \(path); it was kept so that macOS "
                    + "keeps the privacy permissions of scheduled prompts."
            case let .replaced(path, version):
                return "Replaced \(ZenCRONInstallation.executableName) at \(path) with \(version)."
            case let .sourceMissing(detail):
                return "ZenCRON cannot be built: \(detail). Building it needs a ZenCODE source "
                    + "checkout and a Swift toolchain, as for the optional features."
            case let .buildFailed(summary, output):
                let text = "ZenCRON could not be built: \(summary)"
                return output.isEmpty ? text : "\(text)\n\(output)"
            case let .versionUnreadable(path, reason):
                return "The ZenCRON built at \(path) does not report its version (\(reason)); "
                    + "nothing was installed."
            case let .installFailed(message):
                return message
            }
        }
    }

    /// The part of the build output worth showing: the end of standard error,
    /// or of standard output when standard error is empty.
    static func zenCRONUsefulBuildOutput(
        _ result: ZenCRONBuildResult,
        lineLimit: Int = 40,
        characterLimit: Int = 4_000
    ) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = stderr.isEmpty ? stdout : stderr
        var lines = text.components(separatedBy: .newlines)
        if lines.count > lineLimit {
            lines = Array(lines.suffix(lineLimit))
        }
        let tail = lines.joined(separator: "\n")
        guard tail.count > characterLimit else { return tail }
        return String(tail.suffix(characterLimit))
    }

    // MARK: - Build and install

    /// Builds ZenCRON from the source checkout and installs it, applying the
    /// replacement policy of `ZenCRONInstallation.decision`.
    ///
    /// 1. Resolves the checkout and requires `<checkout>/Sources/ZenCRON/Package.swift`.
    /// 2. Syncs the package into the stable working copy under the support
    ///    directory (its `.build` is kept, so later builds are incremental).
    /// 3. Runs `swift build -c release --product ZenCRON` with a timeout.
    /// 4. Reads the version of the built executable, decides, and installs.
    static func buildAndInstallZenCRON(
        tools: ZenCRONSetupTools,
        supportDirectory: URL = ZenFileService.supportDirectoryURL(),
        fileManager: FileManager = .default,
        buildTimeout: TimeInterval = SwiftFeatureRuntime.defaultOptionalFeatureInstallTimeoutSeconds,
        progress: @escaping @Sendable (String) -> Void
    ) async -> ZenCRONSetupOutcome {
        progress("Resolving ZenCODE source checkout…")
        let checkout: URL
        do {
            checkout = try tools.checkoutURL()
        } catch {
            return .sourceMissing(detail: "no ZenCODE source checkout was found")
        }
        let sourcePackage = checkout
            .appendingPathComponent(ZenCRONInstallation.packageRelativePath, isDirectory: true)
        let sourceManifest = sourcePackage.appendingPathComponent("Package.swift")
        guard fileManager.fileExists(atPath: sourceManifest.path) else {
            return .sourceMissing(detail: "\(sourceManifest.path) does not exist")
        }
        progress("Source package: \(sourcePackage.path)")

        let workingCopy = ZenCRONInstallation.workingCopyURL(supportDirectory: supportDirectory)
        progress("Syncing the package to \(workingCopy.path)…")
        do {
            try ZenCRONInstallation.syncPackage(
                from: sourcePackage,
                to: workingCopy,
                fileManager: fileManager
            )
        } catch {
            return .buildFailed(
                summary: "the package could not be copied to \(workingCopy.path): \(error.localizedDescription)",
                output: ""
            )
        }

        progress("Running: swift " + zenCRONBuildArguments(packageDirectory: workingCopy).joined(separator: " "))
        let buildResult: ZenCRONBuildResult
        do {
            buildResult = try await tools.build(workingCopy, buildTimeout, progress)
        } catch {
            return .buildFailed(
                summary: "swift could not be run: \(error.localizedDescription)",
                output: ""
            )
        }
        guard !buildResult.timedOut else {
            return .buildFailed(
                summary: "swift build did not finish within \(Int(buildTimeout)) seconds.",
                output: zenCRONUsefulBuildOutput(buildResult)
            )
        }
        guard buildResult.exitCode == 0 else {
            return .buildFailed(
                summary: "swift build exited with status \(buildResult.exitCode).",
                output: zenCRONUsefulBuildOutput(buildResult)
            )
        }
        let built = ZenCRONInstallation.builtExecutableURL(packageDirectory: workingCopy)
        guard fileManager.isExecutableFile(atPath: built.path) else {
            return .buildFailed(
                summary: "swift build succeeded, but the executable \(built.path) was not produced.",
                output: ""
            )
        }

        progress("Reading the version of the built ZenCRON…")
        let builtVersion: String
        do {
            builtVersion = try await tools.readVersion(built)
        } catch {
            return .versionUnreadable(path: built.path, reason: error.localizedDescription)
        }

        let target = ZenCRONInstallation.installedExecutableURL(supportDirectory: supportDirectory)
        let hadInstalledExecutable = fileManager.fileExists(atPath: target.path)
        // Only macOS compares versions; Linux replaces regardless.
        var installedVersion: String?
        if hadInstalledExecutable, tools.platform == .macOS {
            installedVersion = try? await tools.readVersion(target)
        }
        switch ZenCRONInstallation.decision(
            installedVersion: installedVersion,
            builtVersion: builtVersion,
            platform: tools.platform
        ) {
        case .keep:
            return .kept(path: target.path, version: builtVersion)
        case .install:
            progress("Installing into \(target.deletingLastPathComponent().path)…")
            do {
                try ZenCRONInstallation.install(
                    builtExecutable: built,
                    supportDirectory: supportDirectory,
                    fileManager: fileManager
                )
            } catch {
                return .installFailed(message: error.localizedDescription)
            }
            return hadInstalledExecutable
                ? .replaced(path: target.path, version: builtVersion)
                : .installed(path: target.path, version: builtVersion)
        }
    }

    // MARK: - Section

    enum ScheduledPromptsAction: Hashable {
        case build
        case back
    }

    static func scheduledPromptsMenuItems(
        status: ZenCRONSetupStatus
    ) -> [TerminalCheckboxMenuItem<ScheduledPromptsAction>] {
        let isInstalled: Bool
        switch status.state {
        case .notInstalled:
            isInstalled = false
        case .installedUnchecked, .installed, .unreadable:
            isInstalled = true
        }
        return [
            TerminalCheckboxMenuItem(
                value: .build,
                title: isInstalled ? "Rebuild and update ZenCRON" : "Build and install ZenCRON",
                detail: "build \(ZenCRONInstallation.packageRelativePath) from the ZenCODE source checkout "
                    + "and install it at \(status.path)"
            ),
            TerminalCheckboxMenuItem(
                value: .back,
                title: "Back",
                detail: "return to the main setup menu"
            )
        ]
    }

    /// The "Scheduled prompts (ZenCRON)" section: shows what is installed and
    /// offers to build and install (or update) ZenCRON. Back or Esc leaves
    /// without doing anything. Nothing is saved in the settings manifest.
    static func configureScheduledPrompts(
        tools: ZenCRONSetupTools = .live,
        supportDirectory: URL = ZenFileService.supportDirectoryURL(),
        fileManager: FileManager = .default,
        write: @escaping @Sendable (String) -> Void = { AgentOutput.standardError.writeString($0) },
        selectOne: (String, [TerminalCheckboxMenuItem<ScheduledPromptsAction>], ScheduledPromptsAction) -> ScheduledPromptsAction? = {
            TerminalCheckboxMenu.selectOne(title: $0, items: $1, selected: $2)
        }
    ) async {
        let status = await ZenCRONSetupStatus.load(
            supportDirectory: supportDirectory,
            fileManager: fileManager,
            readVersion: tools.readVersion
        )
        write(
            """

            \(SetupSection.scheduledPrompts.title)
            ZenCRON is the stable host cron starts for the prompts scheduled with /cron, so that
            macOS keeps their privacy permissions across ZenCODE updates.
            \(status.summary)

            """
        )
        guard selectOne(
            SetupSection.scheduledPrompts.title,
            scheduledPromptsMenuItems(status: status),
            .build
        ) == .build else {
            return
        }

        let outcome = await buildAndInstallZenCRON(
            tools: tools,
            supportDirectory: supportDirectory,
            fileManager: fileManager,
            progress: { write("  • \($0)\n") }
        )
        write("\(outcome.message)\n")
    }
}
