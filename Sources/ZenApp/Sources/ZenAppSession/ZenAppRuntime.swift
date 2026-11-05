//
//  ZenAppRuntime.swift
//  ZenApp
//
//  The composition root of the app: one per process. It owns the session
//  host, the runner, and the consent authorizer every window shares.
//

import Foundation
import Observation
import ToolCore
import ZenCODECore

/// The app's runtime, one per process: the `ChatSessionHost` over one runner,
/// one consent authorizer for every window (the host routes each request to
/// the slot that runs its session), and the shell of the host.
///
/// The access mode of the runner (``localExecAccessMode``, the terminal's
/// Ctrl+G) is app-wide: one toggle
/// (``toggleLocalExecAccessMode()``) changes it for every session of every
/// window, and every open window shows it. It is never persisted: each launch
/// starts in the default mode.
@MainActor
@Observable
public final class ZenAppRuntime {
    /// The working directory of the launch configuration.
    public let launchWorkspace: URL
    /// The container of every session of the app.
    @ObservationIgnored public let sessionHost: ChatSessionHost
    /// What a shell shows about every session, kept current.
    public private(set) var shell: ChatShellSnapshot
    /// ``shutdown()`` ran.
    public private(set) var isShutDown = false
    /// The runner's access mode for `local.exec` and the destructive direct
    /// tools, as of the last toggle that finished: in
    /// ``AgentLocalExecAccessMode/fullAccess`` they run without asking for
    /// consent.
    public private(set) var localExecAccessMode: AgentLocalExecAccessMode

    @ObservationIgnored let authorizer: ChatToolConsentAuthorizer
    @ObservationIgnored let openExternal: @Sendable (ChatOpenTarget) async throws -> Void
    /// The runner every session of the host runs on.
    @ObservationIgnored let runner: AgentCoreSessionRunner
    /// The open windows, in the order they opened.
    @ObservationIgnored private(set) var windows: [ZenWindowSession] = []
    @ObservationIgnored private var shellObservation: Task<Void, Never>?
    /// The latest toggle of the access mode; each one waits for the one
    /// before it, so they reach the runner in order.
    @ObservationIgnored private var accessModeToggle: Task<Void, Never>?

    /// `true` once the provider-key migration ran in this process.
    private static var didMigrateProviderKeys = false

    /// Launches the runtime as `zen` does: migrates the provider keys once,
    /// reads the persisted settings of the support directory
    /// (`AgentConfiguration(arguments: arguments)`), both off the main actor,
    /// then composes the runtime with the production backend, the optional
    /// features, and the operator's home folder.
    ///
    /// - Parameter arguments: The executable name, then the configuration
    ///   options (see ``ZenAppLaunchArguments``): `--agent`, `--model`,
    ///   `--skills`, `--working-directory`.
    /// - Returns: The runtime, ``ZenAppLaunchFailure/invalidArguments(_:)``
    ///   when an argument is wrong (an unknown agent, a missing or invalid
    ///   value), or ``ZenAppLaunchFailure/notConfigured(_:)`` when the
    ///   configuration cannot be read.
    public static func launch(
        arguments: [String],
        openExternal: @escaping @Sendable (ChatOpenTarget) async throws -> Void
    ) async -> Result<ZenAppRuntime, ZenAppLaunchFailure> {
        let migratesProviderKeys = !didMigrateProviderKeys
        didMigrateProviderKeys = true
        let configuration: AgentConfiguration
        switch await readLaunchConfiguration(
            arguments: arguments,
            migratingProviderKeys: migratesProviderKeys
        ) {
        case let .success(launchConfiguration):
            configuration = launchConfiguration
        case let .failure(failure):
            return .failure(failure)
        }
        let runtime = await ZenAppRuntime(
            configuration: configuration,
            featureRuntime: SwiftFeatureRuntime(),
            userHomeDirectoryURL: UserHomeDirectory.current(),
            openExternal: openExternal
        )
        return .success(runtime)
    }

    /// The file work of ``launch(arguments:openExternal:)``, off the main
    /// actor: the provider-key migration when `migratingProviderKeys`, then
    /// the launch configuration. An `AgentConfigurationError` is a wrong
    /// argument, not a missing setup: it is `.invalidArguments`; any other
    /// error is `.notConfigured`.
    @concurrent
    nonisolated static func readLaunchConfiguration(
        arguments: [String],
        migratingProviderKeys: Bool
    ) async -> Result<AgentConfiguration, ZenAppLaunchFailure> {
        if migratingProviderKeys {
            AgentProviderKeyMigration.migrateIfNeededReportingFailures()
        }
        do {
            return .success(try AgentConfiguration(arguments: arguments))
        } catch let error as AgentConfigurationError {
            return .failure(.invalidArguments(error.localizedDescription))
        } catch {
            return .failure(.notConfigured(
                "\(ZenAppLaunchFailure.notConfiguredMessage)\n\(error.localizedDescription)"
            ))
        }
    }

    /// Composes the runtime over `configuration`: the composition seam of
    /// ``launch(arguments:openExternal:)``, for tests and hosted
    /// configurations. Asynchronous because it reads the host's first shell
    /// snapshot before returning.
    ///
    /// - Parameters:
    ///   - featureRuntime: The optional features; `nil` lists none (the runner
    ///     still gets a feature runtime of its own).
    ///   - userHomeDirectoryURL: The home folder the attachment picker starts
    ///     in; `nil` disables the picker.
    ///   - backendFactory: The model backend; `nil` is the production one.
    ///   - openExternal: Opens a file or URL for `/open`.
    public init(
        configuration: AgentConfiguration,
        featureRuntime: SwiftFeatureRuntime?,
        userHomeDirectoryURL: URL?,
        backendFactory: AgentRuntimeBackendFactory? = nil,
        openExternal: @escaping @Sendable (ChatOpenTarget) async throws -> Void
    ) async {
        let authorizer = ChatToolConsentAuthorizer(host: ZenRefusingInteractionHost())
        let runner = ChatSessionRuntimeFactory.makeSessionRunner(
            toolAuthorizationHandler: { request in await authorizer.authorize(request) },
            featureRuntime: featureRuntime ?? SwiftFeatureRuntime(),
            backendFactory: backendFactory ?? ChatSessionRuntimeFactory.productionBackendFactory
        )
        let environment = ChatSessionEnvironment(
            configuration: configuration,
            featureRuntime: featureRuntime == nil ? nil : runner.swiftFeatureRuntime,
            userHomeDirectoryURL: userHomeDirectoryURL
        )
        let sessionHost = ChatSessionHost(
            runner: runner,
            environment: environment,
            sleepAssertionReason: "ZenCODE app session active"
        )
        let shell = await sessionHost.shellSnapshot
        let accessMode = await runner.localExecAccessMode()
        self.launchWorkspace = configuration.workingDirectory
        self.sessionHost = sessionHost
        self.authorizer = authorizer
        self.openExternal = openExternal
        self.runner = runner
        self.shell = shell
        self.localExecAccessMode = accessMode
        observeShell()
    }

    private func observeShell() {
        let sessionHost = sessionHost
        shellObservation = Task { [weak self] in
            let shells = await sessionHost.shellSnapshots()
            for await shell in shells {
                guard let self else { return }
                if self.shell != shell {
                    self.shell = shell
                }
            }
        }
    }

    /// Opens a window on `workspace`: a slot of the host with its first
    /// session, ready for the first line.
    public func openWindow(workspace: URL) async throws -> ZenWindowSession {
        guard !isShutDown else { throw ChatSessionHostError.shutDown }
        let window = try await ZenWindowSession.open(runtime: self, workspace: workspace)
        guard !isShutDown else {
            await window.close()
            throw ChatSessionHostError.shutDown
        }
        windows.append(window)
        // A toggle that finished while the window was opening.
        window.adoptLocalExecAccessMode(localExecAccessMode)
        return window
    }

    func windowDidClose(_ window: ZenWindowSession) {
        windows.removeAll { $0 === window }
    }

    // MARK: - Access mode

    /// Switches the runner's access mode to the other value, as the
    /// terminal's Ctrl+G does, for every session of the app, also while a turn
    /// runs. Returns at once; the toggles run in order, each after the one
    /// before it ended, so ``localExecAccessMode`` is the runner's mode once
    /// the last one ended. Each one shows the new mode in the status bar of
    /// every open window and adds its message
    /// (``ChatSessionNoticeText/localExecAccessModeChangeText(_:)``) to each
    /// transcript. Does nothing after ``shutdown()``.
    public func toggleLocalExecAccessMode() {
        guard !isShutDown else { return }
        let previous = accessModeToggle
        let runner = runner
        accessModeToggle = Task { [weak self] in
            await previous?.value
            guard let self, !self.isShutDown else { return }
            let mode = await runner.toggleLocalExecAccessMode()
            self.publishLocalExecAccessMode(mode)
        }
    }

    /// Shows `mode`, the runner's new access mode, in every open window.
    private func publishLocalExecAccessMode(_ mode: AgentLocalExecAccessMode) {
        if localExecAccessMode != mode {
            localExecAccessMode = mode
        }
        for window in windows {
            window.localExecAccessModeDidChange(mode)
        }
    }

    /// Waits for the toggles of the access mode asked so far, for tests.
    func waitForAccessModeToggles() async {
        await accessModeToggle?.value
    }

    /// Ends every window at once, then shuts the host and its runner down:
    /// each window is marked closed and its queue dropped before anything
    /// suspends, so none of them writes again; then one
    /// `sessionHost.shutdown()` ends every slot (it fences each controller,
    /// drops its reservation, and refuses its pending requests), and the
    /// task-graph observers of the sessions the slots ran are stopped; only
    /// then is each window's work cancelled, so a cancelled turn never runs
    /// unfenced. A second call does nothing.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        let closing = windows
        windows.removeAll()
        for window in closing {
            window.markClosed()
        }
        await ZenWindowSteps.shutdown(sessionHost, slotIDs: closing.map(\.slotID))
        for window in closing {
            window.cancelWork()
        }
        // The shell stream ends with the host, after its last snapshot.
        await shellObservation?.value
        shellObservation = nil
    }
}
