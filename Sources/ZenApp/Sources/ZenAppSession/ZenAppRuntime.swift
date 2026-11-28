//
//  ZenAppRuntime.swift
//  ZenApp
//
//  The composition root of the app: one per process. It owns the session
//  host, the host's runner, and the consent authorizer every session shares;
//  each session runs on a runner of its own that the host owns.
//

import Foundation
import Observation
import ToolCore
import ZenCODECore

@MainActor
private final class WeakWorkspaceWindow {
    weak var value: ZenWorkspaceWindow?

    init(_ value: ZenWorkspaceWindow) {
        self.value = value
    }
}

/// The app's runtime, one per process: the `ChatSessionHost` over the host's
/// runner, one consent authorizer for every session (the host routes each
/// request to the slot that runs it), and the shell of the host.
/// Each session's slot runs on a runner of its own
/// (``ZenWindowSession/runner``), a sibling of the host's runner that the
/// host owns and shuts down, so a session changes its model, agent, thinking
/// level, tools, and skills while the other sessions work. `/models` and
/// `/think` change only their session: the app does not
/// persist the model selections (`persistsModelSelections: false`).
///
/// The access mode (``localExecAccessMode``, the terminal's Ctrl+G) is
/// app-wide: one toggle (``toggleLocalExecAccessMode()``) changes it on the
/// host's runner and on the runner of every session, and every open session
/// shows it. It is never persisted: each launch starts in the default mode.
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
    /// The app's access mode for `local.exec` and the destructive direct
    /// tools, as of the last toggle that finished, on the host's runner and
    /// on every window's: in
    /// ``AgentLocalExecAccessMode/fullAccess`` they run without asking for
    /// consent.
    public private(set) var localExecAccessMode: AgentLocalExecAccessMode
    /// What voice mode does now, for every window: on, paused, reading
    /// aloud, starting. `isSpeaking` follows the controller's reports at
    /// once, ahead of the session's own state, so Esc can stop a reading as
    /// soon as it starts; `isStarting` is `false` while it reads.
    public var voiceState: VoiceModeSessionState {
        let isSpeaking = voiceSessionState.isOn && isVoiceSpeaking
        return VoiceModeSessionState(
            isOn: voiceSessionState.isOn,
            isPaused: voiceSessionState.isPaused,
            isSpeaking: isSpeaking,
            isStarting: voiceSessionState.isStarting && !isSpeaking
        )
    }
    /// The window voice mode follows: the last one that became active and
    /// that voice mode moved to; `nil` before any did, and once it closed
    /// with no other active window left.
    public private(set) var activeVoiceWindowID: UUID?
    /// How the worktree of a `--worktree` launch is closed before the app
    /// quits; `nil` without one. Its decision shuts this runtime down first.
    public private(set) var worktreeClosure: ZenWorktreeClosure?
    /// The session's state, from its stream.
    private var voiceSessionState = VoiceModeSessionState.off
    /// The controller reads aloud, as it last reported.
    private var isVoiceSpeaking = false

    @ObservationIgnored let authorizer: ChatToolConsentAuthorizer
    @ObservationIgnored let openExternal: @Sendable (ChatOpenTarget) async throws -> Void
    /// The host's runner: the source of the access mode, which every window's
    /// runner follows (``ZenWindowSession/runner``, the sibling each slot
    /// runs its sessions on).
    @ObservationIgnored let runner: AgentCoreSessionRunner
    /// The open windows, in the order they opened.
    private(set) var windows: [ZenWindowSession] = []
    /// Workspace windows register before their first session starts opening.
    @ObservationIgnored private var workspaceWindows: [WeakWorkspaceWindow] = []
    /// Requests made after opening a window but before its view is installed.
    @ObservationIgnored private var pendingWorktreeWindows: [String: Int] = [:]
    @ObservationIgnored private var workspaceOpenings: [String: Int] = [:]
    @ObservationIgnored private var sessionsClosing = 0
    @ObservationIgnored private var worktreeOperationsDidEnd: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var menuWorktrees: [String: AgentWorktree] = [:]
    private var usedMenuWorktrees: Set<String> = []
    private var menuWorktreeClosures: [ZenWorktreeClosure] = []
    private var worktreePreparations = 0
    /// The shell installs the action once a workspace scene is available.
    @ObservationIgnored package var showWorktreeClosure: (@MainActor () -> Void)?
    @ObservationIgnored private var shellObservation: Task<Void, Never>?
    /// The latest toggle of the access mode, or alignment of a window that
    /// opened; each one waits for the one before it, so they reach the
    /// runners in order.
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
    ///   `--skills`, `--working-directory`, `--worktree`.
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
        // In the app `/models` and `/think` change only the session of their
        // window, never the persisted selection the other windows start from.
        let environment = ChatSessionEnvironment(
            configuration: configuration,
            featureRuntime: featureRuntime == nil ? nil : runner.swiftFeatureRuntime,
            userHomeDirectoryURL: userHomeDirectoryURL,
            persistsModelSelections: false
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
        if let worktree = configuration.worktree {
            // Weak: the runtime owns the closure.
            self.worktreeClosure = ZenWorktreeClosure(
                worktree: worktree,
                shutdown: { [weak self] in await self?.shutdown() }
            )
        }
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
    /// session, ready for the first line. The session starts clean, as a
    /// first launch of the app on `workspace` would: from the defaults of
    /// that folder's project (its default agent, unless the launch asked
    /// for one), never from the selection of another session.
    public func openWindow(workspace: URL) async throws -> ZenWindowSession {
        guard !isShutDown else { throw ChatSessionHostError.shutDown }
        let path = Self.workspacePath(workspace)
        guard canOpenWorkspace(at: path) else { throw MenuWorktreeError.closing }
        workspaceOpenings[path, default: 0] += 1
        defer {
            if workspaceOpenings[path] == 1 {
                workspaceOpenings.removeValue(forKey: path)
            } else {
                workspaceOpenings[path, default: 0] -= 1
            }
            worktreeOperationDidEnd()
            evaluateMenuWorktreeClosures()
        }
        let window = try await ZenWindowSession.open(runtime: self, workspace: workspace)
        guard !isShutDown else {
            await window.close()
            throw ChatSessionHostError.shutDown
        }
        windows.append(window)
        usedMenuWorktrees.formUnion(menuWorktrees.keys.filter { Self.isInside(path, directory: $0) })
        // A toggle that finished while the window was opening, or still runs.
        alignLocalExecAccessMode(of: window)
        return window
    }

    /// Registers a native workspace window before its first session opens.
    /// Further requests queued while its view was being created become new sessions.
    public func registerWorkspaceWindow(_ window: ZenWorkspaceWindow) {
        workspaceWindows.removeAll { $0.value == nil || $0.value?.isClosed == true }
        guard !workspaceWindows.contains(where: { $0.value === window }) else { return }
        workspaceWindows.append(WeakWorkspaceWindow(window))
        let path = Self.workspacePath(window.workspace)
        let additional = max(0, (pendingWorktreeWindows.removeValue(forKey: path) ?? 0) - 1)
        if additional > 0 {
            Task { @MainActor in
                for _ in 0..<additional {
                    guard !window.isClosed, !window.isClosingWindow, !self.isShutDown else { return }
                    if let session = await window.openNewSession(), !self.focusWindow(session) {
                        window.pendingWorktreeFocus = session
                    }
                }
            }
        }
    }

    /// Opens a prepared menu worktree and retains the name and directory for
    /// its eventual close. The launch worktree already has its own decision.
    @discardableResult
    public func openWorktreeSession(
        _ worktree: AgentWorktree,
        openWindow: @MainActor (URL) -> Void
    ) async -> Bool {
        let path = Self.workspacePath(worktree.directory)
        guard !isShutDown, canOpenWorkspace(at: path) else { return false }
        if worktreeClosure.map({ Self.workspacePath($0.worktree.directory) }) != path {
            menuWorktrees[path] = worktree
            if windows.contains(where: { Self.isInside(Self.workspacePath($0.workspace), directory: path) }) {
                usedMenuWorktrees.insert(path)
            }
        }
        await openWorktreeSession(in: worktree.directory, openWindow: openWindow)
        return true
    }

    /// Opens a new worktree session in an existing workspace window, or asks
    /// the shell to open one. Requests made before that window registers are
    /// queued rather than lost when SwiftUI reuses the same window value.
    public func openWorktreeSession(
        in workspace: URL,
        openWindow: @MainActor (URL) -> Void
    ) async {
        guard !isShutDown, canOpenWorkspace(workspace) else { return }
        let workspace = workspace.standardizedFileURL
        let path = Self.workspacePath(workspace)
        workspaceWindows.removeAll { $0.value == nil || $0.value?.isClosed == true }
        if let window = workspaceWindows.compactMap(\.value).first(where: {
            Self.workspacePath($0.workspace) == path && !$0.isClosingWindow && !$0.closeRequested
        }) {
            if let session = await window.openNewSession() {
                if !focusWindow(session) { window.pendingWorktreeFocus = session }
            } else if let session = window.selectedSession {
                if !focusWindow(session) { window.pendingWorktreeFocus = session }
            }
            return
        }
        let count = pendingWorktreeWindows[path, default: 0]
        pendingWorktreeWindows[path] = count + 1
        if count == 0 { openWindow(workspace) }
    }

    /// The live windows of `workspace`, in the order they opened.
    public func openWindows(in workspace: URL) -> [ZenWindowSession] {
        let workspace = workspace.standardizedFileURL
        return windows.filter { !$0.isClosed && $0.workspace.standardizedFileURL == workspace }
    }

    /// Brings a registered, live window forward using its native focus
    /// action. Returns `false` when there is no action to run.
    @discardableResult
    public func focusWindow(_ window: ZenWindowSession) -> Bool {
        guard !isShutDown, !window.isClosed, windows.contains(where: { $0 === window }),
              let bringToFront = window.bringToFront else { return false }
        bringToFront()
        return true
    }

    /// Whether a window other than `session` is open: one whose session
    /// opened and has not started to close. A window whose session is still
    /// opening, or never opened, is not counted.
    package func hasOpenWindow(otherThan session: ZenWindowSession?) -> Bool {
        windows.contains { $0 !== session && !$0.isClosed }
    }

    /// Whether a session other than `sessions` is open, counted as the
    /// overload above counts them: `sessions` are every session of a system
    /// window that closes (``ZenWorkspaceWindow/sessions``), so it tells
    /// whether that window is the last one.
    package func hasOpenWindow(otherThan sessions: [ZenWindowSession]) -> Bool {
        windows.contains { window in
            !window.isClosed && !sessions.contains { $0 === window }
        }
    }

    func windowDidStartClosing() {
        sessionsClosing += 1
    }

    /// Forgets `window`. When voice mode followed it, it moves to the most
    /// recent active window left, or to none.
    func windowDidClose(_ window: ZenWindowSession) {
        sessionsClosing -= 1
        windows.removeAll { $0 === window }
        voiceActivations.removeAll { $0 == window.id }
        let fallback = voiceActivations.last.flatMap { id in windows.first { $0.id == id } }
        voice.sink.post(.windowClosed(window.voiceHost, fallback: fallback?.voiceHost))
        worktreeOperationDidEnd()
        evaluateMenuWorktreeClosures()
    }

    // MARK: - Menu worktree closure

    /// Hold automatic quit even during the gap between a native window close
    /// and its last slot finishing teardown, before the dialog can open.
    package var hasPendingMenuWorktreeClosure: Bool {
        !usedMenuWorktrees.isEmpty || !menuWorktreeClosures.isEmpty
    }

    package var displayedWorktreeClosure: ZenWorktreeClosure? {
        if let worktreeClosure, worktreeClosure.isRequested, worktreeClosure.isRunning || isShutDown {
            return worktreeClosure
        }
        return menuWorktreeClosures.first ?? worktreeClosure.flatMap { $0.isRequested ? $0 : nil }
    }

    package var hasMenuWorktreeDialog: Bool { !isShutDown && !menuWorktreeClosures.isEmpty }

    package func requestLaunchWorktreeClosure() {
        guard let worktreeClosure, worktreeClosure.isPending else { return }
        worktreeClosure.request()
        showWorktreeClosure?()
    }

    /// A native close without a choice is Keep: discard the decision without
    /// running Git, but keep tracking the worktree if it is used again.
    package func dismissMenuWorktreeClosure(_ closure: ZenWorktreeClosure) {
        guard !closure.isRunning, menuWorktreeClosures.first === closure else { return }
        closure.dismissWithoutDecision()
        menuWorktreeClosures.removeFirst()
        // Only reopen after the native window has finished closing.
        Task { [weak self] in
            guard let self, self.displayedWorktreeClosure != nil else { return }
            self.showWorktreeClosure?()
        }
    }

    package func beginWorktreePreparation() -> Bool {
        guard !isShutDown, worktreeClosure?.isRunning != true,
              !menuWorktreeClosures.contains(where: \.isRunning) else { return false }
        worktreePreparations += 1
        return true
    }

    package func endWorktreePreparation() {
        worktreePreparations -= 1
        worktreeOperationDidEnd()
    }

    private func worktreeOperationDidEnd() {
        guard worktreePreparations == 0, workspaceOpenings.isEmpty, sessionsClosing == 0 else { return }
        let waiting = worktreeOperationsDidEnd
        worktreeOperationsDidEnd.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    package func canOpenWorkspace(_ workspace: URL) -> Bool {
        canOpenWorkspace(at: Self.workspacePath(workspace))
    }

    private func canOpenWorkspace(at path: String) -> Bool {
        !menuWorktreeClosures.contains {
            ($0.isPending || $0.isRunning) && Self.isInside(path, directory: Self.workspacePath($0.worktree.directory))
        }
    }

    /// Called at completion of session opening or teardown. Closing sessions
    /// stay in `windows` until their host slot and observer have stopped.
    func evaluateMenuWorktreeClosures() {
        guard !isShutDown, worktreeClosure?.isRunning != true else { return }
        let wasEmpty = menuWorktreeClosures.isEmpty
        for path in usedMenuWorktrees.sorted() {
            guard let worktree = menuWorktrees[path], !usesMenuWorktree(at: path) else { continue }
            usedMenuWorktrees.remove(path)
            let closure = ZenWorktreeClosure(
                worktree: worktree,
                shutdown: {},
                canModify: { [weak self] in
                    guard let self, !self.isShutDown, self.worktreePreparations == 0,
                          self.worktreeClosure?.isRunning != true else { return false }
                    return !self.usesMenuWorktree(at: path)
                }
            )
            closure.request()
            menuWorktreeClosures.append(closure)
        }
        if wasEmpty, !menuWorktreeClosures.isEmpty { showWorktreeClosure?() }
    }

    private func usesMenuWorktree(at path: String) -> Bool {
        windows.contains { Self.isInside(Self.workspacePath($0.workspace), directory: path) }
            || workspaceOpenings.keys.contains { Self.isInside($0, directory: path) }
            || pendingWorktreeWindows.keys.contains { Self.isInside($0, directory: path) }
            || workspaceWindows.contains {
                guard let window = $0.value, !window.isClosed, window.isAwaitingFirstSession else { return false }
                return Self.isInside(Self.workspacePath(window.workspace), directory: path)
            }
    }

    private static func workspacePath(_ workspace: URL) -> String {
        workspace.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isInside(_ workspace: String, directory: String) -> Bool {
        // Treat case-only differences as in use even on case-sensitive
        // volumes: a false positive is safer than removing an open checkout.
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return workspace.caseInsensitiveCompare(directory) == .orderedSame
            || workspace.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
    }

    package enum MenuWorktreeError: LocalizedError {
        case closing

        package var errorDescription: String? {
            "Finish the open Worktree dialog before opening this workspace."
        }
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

    /// Switches the app's access mode to the other value, as the terminal's
    /// Ctrl+G does, for every session of the app, also while a turn runs.
    /// Returns at once; the toggles run in order, each after the one before
    /// it ended. Each one switches the host's runner, the source of the mode,
    /// then gives the new mode to the runner of every open window, and only
    /// then publishes it: ``localExecAccessMode``, the status bar of each of
    /// those windows, and its message
    /// (``ChatSessionNoticeText/localExecAccessModeChangeText(_:)``) in each
    /// transcript. A window that opens meanwhile is aligned after it
    /// (``alignLocalExecAccessMode(of:)``). Does nothing after ``shutdown()``.
    public func toggleLocalExecAccessMode() {
        guard !isShutDown else { return }
        let previous = accessModeToggle
        let runner = runner
        accessModeToggle = Task { [weak self] in
            await previous?.value
            guard let self, !self.isShutDown else { return }
            let mode = await runner.toggleLocalExecAccessMode()
            let windows = self.windows
            for window in windows {
                await window.runner.setLocalExecAccessMode(mode)
            }
            self.publishLocalExecAccessMode(mode, to: windows)
        }
    }

    /// Shows `mode`, the new access mode the runners of `windows` already
    /// have, in each of them that is still open.
    private func publishLocalExecAccessMode(
        _ mode: AgentLocalExecAccessMode,
        to windows: [ZenWindowSession]
    ) {
        if localExecAccessMode != mode {
            localExecAccessMode = mode
        }
        for window in windows {
            window.localExecAccessModeDidChange(mode)
        }
    }

    /// Brings `window`, just registered, to the app's access mode: its runner
    /// first, then its status bar, without a message row. On the chain of the
    /// toggles, after every toggle asked before, so a toggle that ended while
    /// the window was opening, or that still runs, reaches it too, in order.
    private func alignLocalExecAccessMode(of window: ZenWindowSession) {
        let previous = accessModeToggle
        accessModeToggle = Task { [weak self, weak window] in
            await previous?.value
            guard let self, let window, !self.isShutDown, !window.isClosed else { return }
            let mode = self.localExecAccessMode
            await window.runner.setLocalExecAccessMode(mode)
            window.adoptLocalExecAccessMode(mode)
        }
    }

    /// Waits for the toggles of the access mode, and the alignments of the
    /// windows that opened, asked so far, for tests.
    func waitForAccessModeToggles() async {
        await accessModeToggle?.value
    }

    /// Ends every window at once, then shuts the host down with its runner
    /// and the runner of every window: each window is marked closed and its
    /// queue dropped before anything suspends, so none of them writes again;
    /// then one `sessionHost.shutdown()` ends every slot (it fences each
    /// controller, drops its reservation, and refuses its pending requests),
    /// and the task-graph observers of the sessions the slots ran are
    /// stopped; only then is each window's work cancelled, so a cancelled
    /// turn never runs unfenced. A second call does nothing.
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
        if worktreePreparations != 0 || !workspaceOpenings.isEmpty || sessionsClosing != 0 {
            await withCheckedContinuation { worktreeOperationsDidEnd.append($0) }
        }
    }
}
