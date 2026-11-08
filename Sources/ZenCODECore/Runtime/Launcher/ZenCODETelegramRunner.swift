//
//  ZenCODETelegramRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 05/11/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import ZenPackageMetadata

/// `zen --telegram`: a session without the TUI, driven only by the linked
/// Telegram chat, for an agent that stays on for days (a Raspberry Pi under a
/// systemd user unit, a Mac started over ssh).
///
/// The composition is the terminal's and ACP's: a runner from
/// ``ChatSessionRuntimeFactory``, a ``ChatSessionHost`` over it, and one slot
/// (``ChatSlotIdentity/telegram``) whose primary channel is silent and asks
/// nothing (``ZenCODETelegramSession``). The session starts as the terminal's
/// does, without anything interactive, and the slot is handed to its
/// ``TelegramChannel`` at once, which then runs everything the chat asks, as
/// on an ACP slot after `/telegram on`.
///
/// The process side is thin (``runProcess(configuration:backendFactory:)``):
/// SIGHUP ignored, standard input from `/dev/null`, the safe output of
/// ``ZenCODETelegramProcess``, and the stop signals of
/// ``ZenCODETelegramSignalMonitor``. The rest is ``run(configuration:log:stopSignals:makeSessionRunner:telegramTransportFactory:didStart:)``,
/// which a test drives with a stream of its own, a log sink, and a scripted
/// transport.
///
/// Exit status: 0 after a stop by SIGINT or SIGTERM, also during the startup;
/// 1 when the startup fails (Telegram not set up, no model, the preload, the
/// link to Telegram, the network at startup included: the mode does not retry,
/// the service manager restarts it). After the link is up, polling failures
/// are retried by the channel's backoff and only logged. A fatal error is
/// logged as every text mode prints it, `ZenCODE: <error>` followed by the
/// `zen --doctor` hint, each line with its timestamp. Nothing is written on
/// standard output. The chat cannot stop the process.
enum ZenCODETelegramRunner {
    /// The name of the primary channel in the texts the chat receives: `/help`
    /// answers "…the current ZenCODE Telegram session."
    static let primaryChannelDescription = "Telegram"
    /// The reason of the assertion that keeps the machine awake.
    static let sleepAssertionReason = "ZenCODE Telegram session active"
    /// The prefix of every session id of the slot (`telegram-<uuid>`).
    static let sessionIDPrefix = "telegram"

    /// Runs the mode in this process and returns its exit status.
    static func runProcess(
        configuration: AgentConfiguration,
        backendFactory: AgentRuntimeBackendFactory?
    ) async -> Int32 {
        ZenCODETelegramProcess.detachFromTerminal()
        let log = ZenCODETelegramLog.standardError
        ZenCODETelegramProcess.installSafeOutput(log: log)
        let signals = ZenCODETelegramSignalMonitor.start(log: log) {
            _exit(1)
        }
        let status = await run(
            configuration: configuration,
            log: log,
            stopSignals: signals.stopSignals,
            makeSessionRunner: { toolAuthorizationHandler in
                ChatSessionRuntimeFactory.makeSessionRunner(
                    toolAuthorizationHandler: toolAuthorizationHandler,
                    backendFactory: backendFactory ?? ChatSessionRuntimeFactory.productionBackendFactory
                )
            }
        )
        // The sources stop with the monitor: keep them until the exit.
        withExtendedLifetime(signals) {}
        return status
    }

    private enum RunEvent: Sendable {
        case started
        case startupFailed(any Error)
        case stopRequested(ZenCODETelegramStopSignal)
    }

    /// Runs the session until the first of `stopSignals`, and returns the
    /// exit status.
    ///
    /// Telegram must be set up (paired) before anything else starts. The
    /// startup (``ZenCODETelegramSession/start()``) runs while the stop is
    /// awaited: a stop that arrives first cancels it. Once Telegram drives
    /// the slot, the startup reports it (`didStart`) and then, in the same
    /// task, offers in the chat the task graphs earlier sessions left
    /// incomplete (``ZenCODETelegramSession/offerResumableTaskGraphs()``), so
    /// neither `didStart` nor the stop waits for the operator's answer: a
    /// stop cancels the startup task, which withdraws the menu. A stop logs
    /// `Stopping (<signal>).`, ends the session
    /// (``ZenCODETelegramSession/stop()``), and logs `Stopped.`; a failed
    /// startup logs its error and ends the session.
    ///
    /// - Parameters:
    ///   - makeSessionRunner: Builds the runner with the default consent of
    ///     its gated tool calls, the slot's authorizer.
    ///   - telegramTransportFactory: The Bot API transport; `nil` is the
    ///     production one.
    ///   - didStart: Called once the slot is driven by Telegram (a test seam).
    @ChatSessionActor
    static func run(
        configuration: AgentConfiguration,
        log: ZenCODETelegramLog,
        stopSignals: AsyncStream<ZenCODETelegramStopSignal>,
        makeSessionRunner: @Sendable (@escaping AgentToolAuthorizationHandler) -> AgentCoreSessionRunner,
        telegramTransportFactory: (@Sendable () -> any TelegramHTTPTransport)? = nil,
        didStart: (@ChatSessionActor (ZenCODETelegramSession) async -> Void)? = nil
    ) async -> Int32 {
        guard AgentSettingsManifestStore.load()?.telegram?.isEnabled == true else {
            log.log(fatalErrorText(for: ZenCODETelegramRunnerError.telegramNotSetUp))
            return 1
        }
        let session: ZenCODETelegramSession
        do {
            session = try ZenCODETelegramSession(
                configuration: configuration,
                log: log,
                makeSessionRunner: makeSessionRunner,
                telegramTransportFactory: telegramTransportFactory
            )
        } catch {
            log.log(fatalErrorText(for: error))
            return 1
        }

        let (events, continuation) = AsyncStream.makeStream(of: RunEvent.self)
        let startup = Task(name: "ZenCODE.Telegram.startup") { @ChatSessionActor in
            do {
                try await session.start()
                continuation.yield(.started)
            } catch {
                continuation.yield(.startupFailed(error))
                return
            }
            await session.offerResumableTaskGraphs()
        }
        let stopForwarding = Task(name: "ZenCODE.Telegram.stop-signals") {
            for await signal in stopSignals {
                continuation.yield(.stopRequested(signal))
                return
            }
        }
        defer {
            stopForwarding.cancel()
            continuation.finish()
        }

        for await event in events {
            switch event {
            case .started:
                await didStart?(session)
            case let .startupFailed(error):
                log.log(fatalErrorText(for: error))
                await session.stop()
                return 1
            case let .stopRequested(signal):
                log.log("Stopping (\(signal.name)).")
                // A startup still running is cancelled; once the host is shut
                // down, every step it has left fails at once.
                startup.cancel()
                await session.stop()
                await startup.value
                log.log("Stopped.")
                return 0
            }
        }
        // The events end only with this function.
        return 1
    }

    /// What the log says for a fatal error: the text every text mode prints
    /// for it (`ZenCODE: <error>`, the attach failure's own text for the link
    /// to Telegram), then the `zen --doctor` hint.
    static func fatalErrorText(for error: any Error) -> String {
        let message: String
        if let attachError = error as? TelegramChannelAttachError {
            message = attachError.failureText
        } else {
            message = "ZenCODE: \(error.localizedDescription)\n"
        }
        return message + ZenCODEDoctorRunner.troubleshootingHint
    }
}

/// Why `zen --telegram` cannot run its session.
enum ZenCODETelegramRunnerError: LocalizedError, Equatable {
    /// The settings hold no enabled and paired Telegram link.
    case telegramNotSetUp
    /// The link started, but the slot is not driven by Telegram.
    case notDrivenByTelegram

    var errorDescription: String? {
        switch self {
        case .telegramNotSetUp:
            "Telegram is not set up. Run zen --setup to configure and pair Telegram."
        case .notDrivenByTelegram:
            "Telegram did not take over the session."
        }
    }
}

// MARK: - Session

/// The session of `zen --telegram`: one ``ChatSessionHost`` with one slot,
/// ``ChatSlotIdentity/telegram``, handed to its ``TelegramChannel`` at
/// startup and never taken back.
///
/// The slot's primary channel has nothing to show and nobody to ask: its
/// presenter is silent and its host (``ZenCODETelegramPrimaryHost``) refuses
/// everything without reading any terminal. Its authorizer is a
/// ``ChatToolConsentAuthorizer`` of its own over that host, which is also the
/// runner's default consent: while Telegram drives the slot the host routes
/// each request to the channel, where `/allow`, `/always`, and `/deny` answer
/// it; a request it cannot route is refused, never asked on a terminal, and
/// the persisted *Always* approvals hold as everywhere. The channel hooks
/// (``ZenCODETelegramChannelHooks``) lock the response language as the
/// terminal does; the transcript and the file artifact history are kept as
/// the terminal keeps them, and the slot publishes no state, as the
/// terminal's.
@ChatSessionActor
final class ZenCODETelegramSession {
    let host: ChatSessionHost
    let slotID: ChatSlotID
    let authorizer: ChatToolConsentAuthorizer
    /// The slot holds its hooks weakly: the session owns them.
    let channelHooks: ZenCODETelegramChannelHooks
    private let configuration: AgentConfiguration
    private let log: ZenCODETelegramLog
    /// `true` from the first step of ``stop()``: the startup links nothing
    /// more, and the channel's notices are no longer logged, so nothing an
    /// attach still in flight presents follows `Stopping`.
    private(set) var isStopping = false

    init(
        configuration: AgentConfiguration,
        log: ZenCODETelegramLog,
        makeSessionRunner: @Sendable (@escaping AgentToolAuthorizationHandler) -> AgentCoreSessionRunner,
        telegramTransportFactory: (@Sendable () -> any TelegramHTTPTransport)?
    ) throws {
        self.configuration = configuration
        self.log = log
        let primaryHost = ZenCODETelegramPrimaryHost()
        let authorizer = ChatToolConsentAuthorizer(host: primaryHost)
        let runner = makeSessionRunner { request in
            await authorizer.authorize(request)
        }
        let host = ChatSessionHost(
            runner: runner,
            environment: ChatSessionEnvironment(
                configuration: configuration,
                featureRuntime: runner.swiftFeatureRuntime,
                userHomeDirectoryURL: UserHomeDirectory.current()
            ),
            sleepAssertionReason: ZenCODETelegramRunner.sleepAssertionReason
        )
        if let telegramTransportFactory {
            host.telegramTransportFactory = telegramTransportFactory
        }
        let channelHooks = ZenCODETelegramChannelHooks()
        let descriptor = ChatSlotDescriptor(
            identity: .telegram,
            workingDirectory: configuration.workingDirectory,
            presenter: ZenCODETelegramSilentPresenter(),
            interaction: .host(primaryHost),
            authorizer: authorizer,
            channelHooks: channelHooks,
            defaultOrigin: .telegram,
            publishesState: false,
            sessionIDPrefix: ZenCODETelegramRunner.sessionIDPrefix
        )
        let incarnation = try host.openSlot(
            descriptor,
            sessionID: ChatSessionController.mintedSessionID(prefix: ZenCODETelegramRunner.sessionIDPrefix)
        )
        self.host = host
        self.slotID = incarnation.slotID
        self.authorizer = authorizer
        self.channelHooks = channelHooks
    }

    /// The slot's Telegram channel, once the startup created it.
    var telegramChannel: TelegramChannel? {
        host.telegramChannel(in: slotID)
    }

    /// Starts the session as the terminal does, without anything interactive,
    /// then hands the slot to Telegram.
    ///
    /// The launch agent's profile is applied, the model resolved (without a
    /// menu, a missing choice is `modelSelectionRequired`), the `--skills`
    /// selection applied, the startup logged, the runtime session created
    /// with the selected skills, and the model preloaded, so a model that
    /// cannot load fails here. No workspace access is asked: the primary host
    /// has no folder gate, so the tools stay as the agent selected them. Then
    /// the slot's Telegram channel is created with its notices going to the
    /// log, and attached; the slot must end up driven by Telegram. The task
    /// graphs left incomplete by earlier sessions are offered afterwards, in
    /// the chat (``offerResumableTaskGraphs()``).
    func start() async throws {
        guard let controller = host.incarnation(in: slotID)?.controller else {
            throw ChatSessionHostError.noSession
        }
        await controller.applyInitialAgentSelectionIfNeeded()
        try Task.checkCancellation()
        _ = try await controller.resolveInitialModel()
        try controller.applyInitialSkillSelectionIfNeeded()
        log.log(startupText(of: controller))
        try Task.checkCancellation()
        try await controller.createSessionWithSelectedSkills(discoverExternalTools: true)
        try Task.checkCancellation()
        _ = try await host.runner.preloadModel(
            configuration: await controller.composedSessionConfiguration(discoverExternalTools: false)
        ) { _ in }
        try Task.checkCancellation()
        try await attachTelegram()
    }

    /// `Starting ZenCODE <version> in Telegram mode: agent <name>, model <id>,
    /// working directory <path>.`
    private func startupText(of controller: ChatSessionController) -> String {
        let agent = controller.selection.agent?.displayName ?? AgentProfileStore.developerAgentName
        let model = controller.currentEffectiveModelID() ?? "default model"
        return "Starting ZenCODE \(ZenPackageMetadata.version) in Telegram mode: agent \(agent), model \(model), working directory \(configuration.workingDirectory.path)."
    }

    /// Creates the slot's Telegram channel, sends its notices to the log
    /// (the activation text with the linked chat, the polling health, the
    /// failures), and hands the slot to it.
    private func attachTelegram() async throws {
        guard let channel = host.telegramChannelCreatingIfNeeded(
            in: slotID,
            primaryChannelDescription: ZenCODETelegramRunner.primaryChannelDescription
        ) else {
            throw ChatSessionHostError.unknownSlot
        }
        let log = log
        channel.noticeSink = { [weak self] text, _ in
            guard let self, !self.isStopping else { return }
            log.log(text)
        }
        guard !isStopping else { throw CancellationError() }
        try await host.activateTelegram(
            in: slotID,
            primaryChannelDescription: ZenCODETelegramRunner.primaryChannelDescription
        )
        guard host.activeChannel(in: slotID) == .telegram, channel.isActive else {
            throw ZenCODETelegramRunnerError.notDrivenByTelegram
        }
    }

    /// Offers in the linked chat the task graphs that earlier sessions of the
    /// project left incomplete, once Telegram drives the slot: the shared
    /// offer of the controller (``ChatSessionController/offerResumableTaskGraphs(choiceHost:)``)
    /// asks through the slot's interaction host, which is the Telegram
    /// channel now, and a graph the operator resumes is moved into this
    /// session, which keeps its id. Its notices then reach the chat through
    /// the slot's presenter; the log only says which graph was resumed. A
    /// stop withdraws the menu (the startup task is cancelled) and presents
    /// nothing more.
    func offerResumableTaskGraphs() async {
        guard !isStopping, let controller = host.incarnation(in: slotID)?.controller else {
            return
        }
        let outcome = await controller.offerResumableTaskGraphs()
        guard !isStopping, !Task.isCancelled else { return }
        if let graph = outcome.resumedGraph {
            log.log("Resumed task graph \(graph.graphID) from a previous session.")
        }
        await controller.presentSessionNotices(outcome.notices)
    }

    /// Ends the session: from now on the channel's notices are no longer
    /// logged and the startup links nothing more (``isStopping``). The turn
    /// in progress is cancelled first (its reservation dropped, the channel's
    /// task and the runner's prompt cancelled, so it is not waited for until
    /// it ends), then the session is closed (keeping its persisted task
    /// graph), the Telegram channel shut down, and the host with its runner.
    /// Safe at any point of the startup.
    func stop() async {
        isStopping = true
        if let channel = telegramChannel {
            host.cancelPrompt(in: slotID)
            await channel.stopActiveTurn()
        }
        await host.closeSession(in: slotID, runtimeSession: .close)
        // The host shuts the channel down again with the slot, which changes
        // nothing.
        await telegramChannel?.shutdown()
        await host.shutdown()
    }
}

// MARK: - Primary channel

/// The primary channel's presenter of the `zen --telegram` slot: there is
/// nothing to present outside the chat, and the log never carries the
/// session's output.
struct ZenCODETelegramSilentPresenter: ChatSessionPresenter {}

/// The primary channel's host of the `zen --telegram` slot: it has no
/// capability and refuses every request, without ever reading a terminal or
/// `/dev/tty`. Once Telegram drives the slot, the slot asks the channel; only
/// a request that is not routed to the slot ends here.
struct ZenCODETelegramPrimaryHost: ChatInteractionHost {
    var capabilities: ChatChannelCapabilities { [] }

    func requestToolConsent(
        _ request: AgentToolAuthorizationRequest
    ) async -> ChatConsentDecision? {
        nil
    }
}

/// The channel hooks of the `zen --telegram` slot: the response-language
/// lock of the terminal (`TerminalChat+ResponseLanguage.swift`). The first
/// prompt the operator writes (``ChatSessionHost`` calls
/// ``responseLanguageShouldLock()`` before a turn from the chat) or an
/// approved plan locks the language configured in the settings, else the
/// system's, and every later composition carries its section; another agent,
/// `/sessions new`, and the load of a saved session decide it again. The
/// other steps keep their no-op defaults: the turns use the controller's own
/// composition, as the terminal's.
@ChatSessionActor
final class ZenCODETelegramChannelHooks: ChatSessionChannelHooks {
    /// The language the session answers in once locked; `nil` before, and
    /// when neither the settings nor the system name one.
    private(set) var lockedResponseLanguageName: String?
    private(set) var didLockResponseLanguage = false

    init() {}

    func responseLanguageSection() -> String? {
        lockedResponseLanguageName.map {
            SystemPromptBuilder.responseLanguageSection(languageName: $0)
        }
    }

    func responseLanguageShouldLock() {
        guard !didLockResponseLanguage else { return }
        didLockResponseLanguage = true
        // The language of the settings, else the system's, as the terminal.
        lockedResponseLanguageName = Self.configuredResponseLanguageName()
            ?? ResponseLanguageResolver.systemDisplayName()
    }

    func agentDidChange(_ agent: AgentProfile) async {
        resetResponseLanguageLock()
    }

    func incarnationDidChange(reason: ChatIncarnationChange) async {
        switch reason {
        case .newSessionWillStart, .savedSessionWillLoad:
            resetResponseLanguageLock()
        case .newSessionDidStart, .savedSessionWillRestore, .savedSessionDidRestore, .sessionDidCompact:
            break
        }
    }

    private func resetResponseLanguageLock() {
        lockedResponseLanguageName = nil
        didLockResponseLanguage = false
    }

    /// The response language of `settings.json` as an English name; `nil`
    /// when none is configured or its code is unknown.
    private static func configuredResponseLanguageName() -> String? {
        guard let code = AgentSettingsManifestStore.load()?.responseLanguage else {
            return nil
        }
        return ResponseLanguageResolver.displayName(forCode: code)
    }
}
