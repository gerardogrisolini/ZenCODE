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
///
/// Voice mode (`/voice`) is app-wide too: one ``VoiceModeSession`` (one
/// microphone) for every window, with one state (``voiceState``) that every
/// window shows. It follows the active window (``activeVoiceWindowID``), the
/// last one that came to the front (``windowDidBecomeActive(_:)``) or ran
/// `/voice`: dictation goes into its draft, its answers and comments are read
/// aloud, its room's messages are announced, and its prompts carry the
/// per-turn instruction; the other windows get none of these. It is never
/// persisted: each launch starts with voice mode off.
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
    /// What voice mode does now, for every window: on, paused, reading
    /// aloud. `isSpeaking` follows the controller's reports at once, ahead
    /// of the session's own state, so Esc can stop a reading as soon as it
    /// starts.
    public var voiceState: VoiceModeSessionState {
        VoiceModeSessionState(
            isOn: voiceSessionState.isOn,
            isPaused: voiceSessionState.isPaused,
            isSpeaking: voiceSessionState.isOn && isVoiceSpeaking
        )
    }
    /// The window voice mode follows: the last one that became active and
    /// that voice mode moved to; `nil` before any did, and once it closed
    /// with no other active window left.
    public private(set) var activeVoiceWindowID: UUID?
    /// The session's state, from its stream.
    private var voiceSessionState = VoiceModeSessionState.off
    /// The controller reads aloud, as it last reported.
    private var isVoiceSpeaking = false

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
    /// Voice mode, for every window.
    @ObservationIgnored let voice: ZenAppVoice
    /// The windows that became active, the most recent last.
    @ObservationIgnored private var voiceActivations: [UUID] = []
    @ObservationIgnored private var voiceStateObservation: Task<Void, Never>?
    @ObservationIgnored private var voiceUpdateObservation: Task<Void, Never>?

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
    ///   - voiceSession: The app's voice mode: `nil` runs this platform's
    ///     controller (`VoiceModeSession()`); a test passes one built with
    ///     `VoiceModeSession(makeController:)`, which records nothing.
    ///   - openExternal: Opens a file or URL for `/open`.
    public init(
        configuration: AgentConfiguration,
        featureRuntime: SwiftFeatureRuntime?,
        userHomeDirectoryURL: URL?,
        backendFactory: AgentRuntimeBackendFactory? = nil,
        voiceSession: VoiceModeSession? = nil,
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
        let voiceSession = voiceSession ?? VoiceModeSession()
        let voice = await ZenAppVoice(session: voiceSession)
        let voiceStates = await voiceSession.stateUpdates()
        self.launchWorkspace = configuration.workingDirectory
        self.sessionHost = sessionHost
        self.authorizer = authorizer
        self.openExternal = openExternal
        self.runner = runner
        self.shell = shell
        self.localExecAccessMode = accessMode
        self.voice = voice
        observeShell()
        observeVoice(states: voiceStates)
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

    /// Forgets `window`. When voice mode followed it, it moves to the most
    /// recent active window left, or to none.
    func windowDidClose(_ window: ZenWindowSession) {
        windows.removeAll { $0 === window }
        voiceActivations.removeAll { $0 == window.id }
        let fallback = voiceActivations.last.flatMap { id in windows.first { $0.id == id } }
        voice.sink.post(.windowClosed(window.voiceHost, fallback: fallback?.voiceHost))
    }

    // MARK: - Voice mode

    /// `window` came to the front: voice mode follows it from now on, as
    /// the window it reads and listens for. The dictation the previous
    /// window shows stays in its draft as ordinary text, and dictation goes
    /// on in `window`; the reading stops, and the live-chat question and the
    /// queued announcements are dropped. The UI calls it whenever a window
    /// becomes the key one; nothing happens for the window voice mode
    /// follows already, for a closed one, and after ``shutdown()``. Returns
    /// at once; the switch runs in the order it was asked, after the voice
    /// work asked before it.
    public func windowDidBecomeActive(_ window: ZenWindowSession) {
        guard !isShutDown, !window.isClosed, windows.contains(where: { $0 === window }) else { return }
        noteVoiceActivation(of: window)
        voice.sink.post(.activate(window.voiceHost))
    }

    /// Runs `line`, a `/voice` line of `window`: the window becomes the one
    /// voice mode follows first, then the session runs the command. Returns
    /// once it ran.
    func runVoiceCommand(_ line: String, from window: ZenWindowSession) async {
        guard !isShutDown, !window.isClosed else { return }
        noteVoiceActivation(of: window)
        await voice.sink.perform(.command(line, host: window.voiceHost))
    }

    private func noteVoiceActivation(of window: ZenWindowSession) {
        voiceActivations.removeAll { $0 == window.id }
        voiceActivations.append(window.id)
    }

    /// Follows the session's state and what the voice context reports.
    private func observeVoice(states: AsyncStream<VoiceModeSessionState>) {
        voiceStateObservation = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                if self.voiceSessionState != state {
                    self.voiceSessionState = state
                }
            }
        }
        let updates = voice.sink.updates
        voiceUpdateObservation = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                switch update {
                case let .speaking(isSpeaking):
                    if self.isVoiceSpeaking != isSpeaking {
                        self.isVoiceSpeaking = isSpeaking
                    }
                case let .activeWindow(id):
                    if self.activeVoiceWindowID != id {
                        self.activeVoiceWindowID = id
                    }
                }
            }
        }
    }

    /// Waits until the voice work asked so far was done, for tests.
    func waitForVoice() async {
        await voice.sink.perform(.flush)
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
        // Voice mode stops with the app, after the voice work asked before.
        await voice.sink.perform(.shutdown)
        voiceStateObservation?.cancel()
        voiceStateObservation = nil
        voiceSessionState = .off
        isVoiceSpeaking = false
        await voiceUpdateObservation?.value
        voiceUpdateObservation = nil
        await ZenWindowSteps.shutdown(sessionHost, slotIDs: closing.map(\.slotID))
        for window in closing {
            window.cancelWork()
        }
        // The shell stream ends with the host, after its last snapshot.
        await shellObservation?.value
        shellObservation = nil
    }
}
