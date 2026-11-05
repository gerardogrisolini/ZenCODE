//
//  ZenAppLauncher.swift
//  ZenApp
//
//  Owns the runtime of the app: launches it once, publishes its state to the
//  windows, and shuts it down when the app quits.
//

import AppKit
import Foundation
import Observation
import ZenAppSession
import ZenCODECore

/// The state of the app's runtime, observed by every window.
@MainActor
@Observable
final class ZenAppLauncher {
    /// Where the launch is.
    enum Phase {
        /// ``ZenAppRuntime/launch(arguments:openExternal:)`` runs.
        case launching
        /// The runtime is up.
        case ready(ZenAppRuntime)
        /// The runtime could not start: why, as the window shows it.
        case failed(ZenAppLaunchFailure)
    }

    /// What ``ZenAppDelegate/applicationShouldTerminate(_:)`` does.
    enum TerminationStep: Equatable {
        /// Nothing to shut down.
        case terminateNow
        /// Shut the runtime down (or wait for the launch), then quit.
        case shutDownFirst
        /// A shutdown already runs; it answers the pending request.
        case alreadyShuttingDown
    }

    /// Where the launch is, as ``terminationStep(isShuttingDown:launch:)``
    /// reads it.
    enum LaunchState: Equatable {
        /// ``start()`` did not run.
        case notStarted
        /// The launch runs.
        case launching
        /// The runtime is up; `isShutDown` once it shut down.
        case ready(isShutDown: Bool)
        /// The launch failed: there is no runtime.
        case failed
    }

    /// The executable name the configuration is read for, as `zen` does.
    static let executableName = "ZenCODE"

    /// The longest a quit waits for the shutdown: the app quits when the
    /// shutdown ends or when this much time passed, whichever comes first.
    static let terminationTimeout: Duration = .seconds(5)

    private(set) var phase: Phase = .launching

    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?

    init() {}

    /// Launches the runtime with the options of the command line (the ones
    /// `zen --ui` forwards); later calls do nothing.
    func start() {
        guard launchTask == nil else { return }
        let launchArguments = Self.launchArguments(from: CommandLine.arguments)
        launchTask = Task { [weak self] in
            let result: Result<ZenAppRuntime, ZenAppLaunchFailure>
            switch launchArguments {
            case let .success(arguments):
                result = await ZenAppRuntime.launch(
                    arguments: arguments,
                    openExternal: { target in try await ZenExternalOpener.open(target) }
                )
            case let .failure(failure):
                result = .failure(failure)
            }
            guard let self else { return }
            switch result {
            case let .success(runtime):
                self.phase = .ready(runtime)
            case let .failure(failure):
                self.phase = .failed(failure)
            }
        }
    }

    /// The configuration arguments of `processArguments`
    /// (``ZenAppLaunchArguments``), or the failure the window shows when one
    /// of them has no value.
    static func launchArguments(from processArguments: [String]) -> Result<[String], ZenAppLaunchFailure> {
        do {
            return .success(try ZenAppLaunchArguments.configurationArguments(
                from: processArguments,
                executableName: executableName
            ))
        } catch {
            return .failure(.invalidArguments(error.localizedDescription))
        }
    }

    /// Decides how a quit request proceeds.
    func terminationStep() -> TerminationStep {
        Self.terminationStep(isShuttingDown: shutdownTask != nil, launch: launchState)
    }

    /// Where the launch is now.
    var launchState: LaunchState {
        switch phase {
        case .launching:
            launchTask == nil ? .notStarted : .launching
        case let .ready(runtime):
            .ready(isShutDown: runtime.isShutDown)
        case .failed:
            .failed
        }
    }

    /// How a quit request proceeds: a shutdown already running answers it;
    /// otherwise a launch in progress or a runtime that is up is shut down
    /// first, and anything else quits at once.
    static func terminationStep(isShuttingDown: Bool, launch: LaunchState) -> TerminationStep {
        if isShuttingDown {
            return .alreadyShuttingDown
        }
        switch launch {
        case .notStarted, .failed:
            return .terminateNow
        case .launching:
            return .shutDownFirst
        case let .ready(isShutDown):
            return isShutDown ? .terminateNow : .shutDownFirst
        }
    }

    /// Waits for a launch in progress, then shuts the runtime down. Every
    /// call waits for the same shutdown.
    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let launchTask = launchTask
        let task = Task { [weak self] in
            await launchTask?.value
            guard let self, case let .ready(runtime) = self.phase else { return }
            await runtime.shutdown()
        }
        shutdownTask = task
        await task.value
    }
}

/// Opens the files and URLs of `/open` with the workspace of the system.
enum ZenExternalOpener {
    /// Why a target could not be opened.
    enum OpenError: LocalizedError, Equatable {
        case invalidURL(String)
        case openFailed(String)

        var errorDescription: String? {
            switch self {
            case let .invalidURL(target):
                "Not a valid URL: \(target)"
            case let .openFailed(target):
                "Could not open \(target)"
            }
        }
    }

    /// The URL of `target`: a file URL for a file, the parsed URL (with a
    /// scheme) for a URL. A kind this version does not know is not opened.
    static func url(for target: ChatOpenTarget) throws -> URL {
        switch target.kind {
        case .file:
            return URL(filePath: target.target)
        case .url:
            guard let url = URL(string: target.target), url.scheme != nil else {
                throw OpenError.invalidURL(target.target)
            }
            return url
        @unknown default:
            throw OpenError.openFailed(target.target)
        }
    }

    /// Opens `target` with its default application.
    @MainActor
    static func open(_ target: ChatOpenTarget) throws {
        let url = try url(for: target)
        guard NSWorkspace.shared.open(url) else {
            throw OpenError.openFailed(target.target)
        }
    }
}
