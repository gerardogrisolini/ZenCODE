//
//  TelegramSessionCompanion.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Links one chat session to Telegram, next to the session's primary channel.
///
/// Telegram never runs alone: a companion follows the session of exactly one
/// primary channel (the terminal, the macOS app, or an ACP session), which
/// owns it, owns the session's controller, and is reached through
/// ``TelegramCompanionChannel``. The companion owns everything the link
/// needs: the control service and its lifecycle, the validated route lease,
/// the linked chat, and the Telegram-side state of the turn in progress.
///
/// ``attach()`` links the session (`/telegram on`), ``detach()`` unlinks it
/// and keeps what a later attach reuses (`/telegram off`), and
/// ``shutdown()`` is the teardown when the session ends. The three are meant
/// to run one at a time, as the channel's command handling runs them.
///
/// The turn the companion mirrors is driven by the channel
/// (`TelegramSessionCompanion+Turn.swift`) and by the companion's
/// ``presenter``, which the controller fans the turn's output out to; the
/// consent race of a mirrored turn is in
/// `TelegramSessionCompanion+Consent.swift`.
///
/// What Telegram asks of the session beyond prompts is answered by the
/// companion too: `/diff`, the artifact consent buttons and inbound
/// attachments (`+Artifacts`), voice notes (`+Voice`), the shared-chat relay
/// and its replies (`+SharedChatRelay`), and the `/chat` mention picker
/// (`+MentionPicker`). The channel that reads the Telegram ingress calls
/// them.
///
/// Which route of the linked chat the session uses, its own topic or the
/// route every session shares, is decided in
/// `TelegramSessionCompanion+Topics.swift`, which also moves the topic to the
/// session the channel switches to (``rebind(sessionID:displayName:)``).
///
/// The ingress itself is in `TelegramSessionCompanion+Ingress.swift`:
/// ``handleIncomingMessage(_:isSessionGenerating:admit:)`` authorizes and
/// dispatches one message the channel read, ``lineAction(for:lease:)``
/// answers a line from Telegram when it leaves the channel's queue, and
/// ``startConsuming()`` reads the ingress for a channel without a loop of
/// its own.
///
/// All state is isolated to ``ChatSessionActor``, like the controller. The
/// companion holds the controller strongly and the channel weakly; the
/// controller holds the ``presenter``, which holds the companion weakly, so
/// no strong cycle runs through the controller.
@ChatSessionActor
public final class TelegramSessionCompanion {
    /// What the operator can do from Telegram.
    public enum Policy: Sendable, Equatable {
        /// Everything: prompts, voice notes, `/plan`, `/goal` and `/review`,
        /// replies to pending questions, and every remote command. The
        /// terminal uses it.
        case full
        /// The session is mirrored and can be consulted and approved, not
        /// driven: `/start`, `/help`, `/status`, `/chat`, `/changes`,
        /// `/diff`, and `/allow` `/always` `/deny` are accepted; prompts,
        /// voice notes, `/plan` `/goal` `/review`, replies to pending
        /// questions, and `/undo` are refused. The ACP bridge uses it.
        ///
        /// What is refused gets ``TelegramSessionCompanion/mirrorOnlyRefusalText``
        /// before the busy gate; what is accepted keeps the busy gate of
        /// ``full``. Beyond those lists:
        /// - a live `@mention` and a text reply to a forwarded card are
        ///   accepted, like the `/chat` picker whose reply they are;
        /// - documents and images are received as in ``full``: the
        ///   attachment store neither starts a turn nor attaches them to a
        ///   prompt;
        /// - an unknown slash command is answered with the unknown-command
        ///   text, listing the commands of this policy;
        /// - a plain-word alias ("status", "diff") stays a command even
        ///   while a question waits for a reply, because replies are
        ///   refused anyway; "undo" and every other plain text are refused.
        ///
        /// The companion never queues a line: the channel has no prompt to
        /// run, so an accepted command is answered as soon as it passes the
        /// busy gate.
        case mirrorOnly
    }

    /// How the primary channel configures its companion.
    public struct Configuration: Sendable, Equatable {
        /// The primary channel's name in the texts sent to Telegram: "TUI"
        /// for the terminal.
        public let primaryChannelDescription: String
        public let policy: Policy
        /// Where the primary channel asks for a tool permission, as the
        /// consent texts name it ("the terminal", "the editor"): the linked
        /// chat is told that the permission was granted or denied there, and
        /// the primary channel that it can approve or deny there. The default
        /// is the terminal's, so the terminal's texts stay as they were.
        public let consentLocationDescription: String

        public init(
            primaryChannelDescription: String,
            policy: Policy,
            consentLocationDescription: String = "the terminal"
        ) {
            self.primaryChannelDescription = primaryChannelDescription
            self.policy = policy
            self.consentLocationDescription = consentLocationDescription
        }
    }

    /// External effects a test records instead of performing.
    enum TelegramWorkEffectForTesting: Sendable {
        case attachmentDownload
        case voiceTranscription
        case sharedChatPublication
    }

    // MARK: - Collaborators

    /// The session the companion follows.
    let controller: ChatSessionController
    /// The runtime behind the shared chat the companion relays.
    let sessionRunner: AgentCoreSessionRunner
    /// The route authority: every lease is resolved and validated here.
    let router: TerminalTelegramSessionRouter
    /// The companion's own control service: transport, polling, and wire
    /// lifecycle.
    let controlService: TerminalTelegramControlService
    /// The primary channel, held weakly: it owns the companion.
    weak var channel: (any TelegramCompanionChannel)?
    let configuration: Configuration
    /// Where the companion is registered while attached.
    let attachments: TelegramCompanionAttachments
    /// Per-route runtime state (pending replies, voice, uploads) torn down
    /// with the route of the turn in progress.
    let routeRuntimeState: TerminalTelegramRouteRuntimeState
    /// Permission requests asked in the linked chat.
    let permissionBroker = TerminalTelegramPermissionBroker()
    /// Owns all Telegram voice download and transcription tasks across
    /// detach and attach.
    let voiceTranscriptions = TerminalVoiceTranscriptionRegistry()
    /// The companion's presenter in the controller, registered once when
    /// the companion is created and removed by ``shutdown()`` (see
    /// ``TelegramCompanionPresenter``).
    let presenter: TelegramCompanionPresenter

    // MARK: - Link

    /// The control service's state as last read; ``isActive`` is its
    /// `isActive`.
    var controlState = TerminalTelegramControlState.inactive()
    public internal(set) var linkedChatID: Int64?
    public internal(set) var linkedChatTitle: String?
    /// Telegram user id of the last linked-chat sender, used to bind outbound
    /// artifact consent offers to the operator who will confirm them.
    var linkedUserID: Int64?
    /// Last validated route binding. Shared-chat relay and receipts and
    /// synthetic coordinator origins are fenced by this exact generation and
    /// topic. In topic mode it stays the session's topic (see
    /// `TelegramSessionCompanion+Topics.swift`).
    var activeRouteLease: TerminalTelegramRouteLease?
    /// The session's own topic while the link is in topic mode; `nil` in
    /// legacy mode and while detached.
    public internal(set) var sessionTopic: SessionTopic?

    // MARK: - Turn in progress

    /// Origin of the turn currently generating. Unlike the reporter itself,
    /// this remains populated while Telegram is detached, so ``attach()`` can
    /// adopt the turn in flight without waiting for the next prompt.
    public internal(set) var activeTurnOrigin: TelegramTurnOrigin?
    /// Ordered Telegram channel of the turn currently generating, when that
    /// turn's progress is mirrored to the linked chat. Permission dialogue is
    /// enqueued here so it cannot overtake the tool activity that raised it.
    var activeProgressReporter: TerminalTelegramTurnProgressReporter?
    /// Lifecycle-safe typing lease held for the mirrored turn, if any.
    /// Replaced by the next turn's lease, released at turn end, and fenced by
    /// generation inside the lease manager.
    var activePresenceLease: TerminalTelegramPresenceLeaseManager.Lease?
    /// Stops a Telegram-originated turn as soon as its route generation is
    /// revoked, rebound, or closed.
    var routeValidationTask: Task<Void, Never>?
    /// `true` when the root response block currently streaming already
    /// produced visible text, so a detach or an attach in the middle of a
    /// response is detected.
    var rootResponseBlockHasContent = false
    /// `true` when the root response block currently streaming must not be
    /// mirrored: part of it was produced while Telegram was detached, so
    /// publishing the rest would send a suffix of a response the chat never
    /// saw begin. Cleared at the next boundary, where a new block starts.
    var rootResponseBlockIsSuppressed = false
    /// `true` when at least one intermediate root response was already
    /// mirrored during the current turn, so the accumulated turn text must
    /// not be mirrored again as the final response.
    var didPublishIntermediateRootResponse = false
    /// Change signature of the task-graph overview already mirrored during
    /// the current turn, so republished identical content does not repeat in
    /// the chat. Reset when a new turn begins.
    var mirroredTaskGraphOverviewSignature: String?
    /// Mirroring epoch of the current turn, advanced at every turn boundary:
    /// a mirror notification delivered after its turn ended is discarded
    /// instead of being adopted by the next turn.
    var currentMirrorEpoch = 0

    // MARK: - Remote commands

    /// Pending ForceReply receipts for coordinator commands that need an
    /// argument. A reply must match both the receipt and its original route.
    var commandReplyBindings: [TerminalTelegramCommandReplyKey: TerminalTelegramCommandReplyBinding] = [:]

    // MARK: - Shared chat

    /// Telegram origin of a live shared-chat message, keyed by the transient
    /// bus message identity, so the coordinator turn it triggers answers on
    /// the same route. Bounded like the retained shared-chat transcript.
    var sharedChatMessageOrigins: [UUID: TelegramTurnOrigin] = [:]
    /// FIFO order of ``sharedChatMessageOrigins``.
    var sharedChatMessageOriginOrder: [UUID] = []
    /// The relay that forwards operator-directed shared-chat messages to the
    /// linked chat, created on first use and kept for the companion's
    /// lifetime, so its ledger survives a detach and a later attach.
    var sharedChatRelayStorage: TerminalTelegramSharedChatRelay?
    /// `true` only while something consumes the Telegram ingress of this
    /// session, so a reply to a forwarded card can actually be delivered.
    /// Whoever owns the ingress sets it while it reads (the terminal's panel
    /// loop sets it while it runs, and ``startConsuming()``
    /// sets it for a channel without a loop); ``rebindSharedChatRelay(roomID:)``
    /// reads it, so cards invite a reply only when one would be read.
    var readsIngress = false

    // MARK: - Ingress

    /// The task ``startConsuming()`` started to read the control service's
    /// messages, until ``detach()`` or ``shutdown()`` stops it.
    var ingressConsumerTask: Task<Void, Never>?

    // MARK: - Artifacts

    /// Where outbound artifacts are staged before an upload; the only
    /// directory whose files `/diff` may send (see ``artifactPolicy``). The
    /// terminal's location by default; a test points it at a directory of
    /// its own. Created 0700 when used.
    var artifactStagingDirectory = TelegramSessionCompanion.defaultArtifactStagingDirectory

    // MARK: - Test seams

    /// Returning true records and consumes the effect before external I/O.
    var onTelegramWorkEffectForTesting: (@Sendable (TelegramWorkEffectForTesting) -> Bool)?
    /// Direct turn-message delivery when no progress reporter owns the
    /// linked chat. `nil` in production.
    var onDirectTelegramTurnMessage: (@Sendable (TerminalTelegramTurnPayload, Int64) async -> Bool)?
    /// Bot-control messages. Production sends through the service.
    var onTelegramSystemMessage: (@Sendable (String, Int64) async -> Bool)?
    /// Route-aware bot-control messages; takes precedence over
    /// ``onTelegramSystemMessage``. `nil` in production.
    var onTelegramRoutedSystemMessage: (@Sendable (String, Int64, Int?) async -> Bool)?
    /// Mention picker cards. Production uses the service.
    var onTelegramMentionPickerMessage: (@Sendable (String, Int64, TerminalTelegramReplyMarkup) async -> Int?)?

    // MARK: - Lifecycle bookkeeping

    /// Advanced by every ``attach()``, ``detach()`` and ``shutdown()``, so an
    /// attach or a poll-health notice overtaken while it waited leaves the
    /// state to the operation that overtook it.
    private var lifecycleGeneration = 0
    /// Delivers the control service's poll-health notices, in order, while
    /// the companion is attached.
    private var pollHealthTask: Task<Void, Never>?
    private var pollHealthContinuation: AsyncStream<TerminalTelegramPollHealthNotice>.Continuation?
    /// The ``attach()`` calls in progress. Poll-health notices wait for them,
    /// as they waited for `/telegram on` in the terminal's serial event loop,
    /// so a failure that polling reports while the service starts is
    /// presented once the link is active, after the text that says so.
    private var runningAttachCount = 0
    private var attachCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    /// The companion of the session `controller` runs, next to its primary
    /// `channel`. It registers its ``presenter`` in `controller` at once, and
    /// stays detached until ``attach()``.
    public convenience init(
        controller: ChatSessionController,
        sessionRunner: AgentCoreSessionRunner,
        router: TerminalTelegramSessionRouter,
        controlService: TerminalTelegramControlService,
        channel: any TelegramCompanionChannel,
        configuration: Configuration
    ) {
        self.init(
            controller: controller,
            sessionRunner: sessionRunner,
            router: router,
            controlService: controlService,
            channel: channel,
            configuration: configuration,
            attachments: .shared
        )
    }

    init(
        controller: ChatSessionController,
        sessionRunner: AgentCoreSessionRunner,
        router: TerminalTelegramSessionRouter,
        controlService: TerminalTelegramControlService,
        channel: any TelegramCompanionChannel,
        configuration: Configuration,
        attachments: TelegramCompanionAttachments
    ) {
        self.controller = controller
        self.sessionRunner = sessionRunner
        self.router = router
        self.controlService = controlService
        self.channel = channel
        self.configuration = configuration
        self.attachments = attachments
        self.routeRuntimeState = TerminalTelegramRouteRuntimeState(router: router)
        self.presenter = TelegramCompanionPresenter()
        presenter.companion = self
        controller.attachCompanionPresenter(presenter)
    }

    /// Whether the link is active: the control service started and was not
    /// stopped since.
    public var isActive: Bool {
        controlState.isActive
    }

    // MARK: - Attach

    /// Links the session to Telegram (`/telegram on`).
    ///
    /// Resolves the owner route persisted by setup, records the linked chat,
    /// and starts the control service, which restarts it when the companion
    /// is already attached, exactly as a repeated `/telegram on` does. The
    /// route is the session's topic, reused or created once the service
    /// started, or the route every session shares (see
    /// `TelegramSessionCompanion+Topics.swift`). A turn
    /// of the primary channel already running moves onto the route, the
    /// turn in progress is mirrored from there (see
    /// ``synchronizeTurnReporting()``), and the primary channel is told the
    /// link is active; a created topic is then announced in General, and a
    /// topic that could not be created is reported after the activation
    /// text. On success the companion is registered in
    /// ``attachments`` under its bot.
    ///
    /// Throws when the session cannot be linked; the primary channel presents
    /// the error's ``TelegramCompanionAttachError/failureText``. When the
    /// service fails to start, the error is recorded as the control state's
    /// `lastError`, the turn in progress follows the link that is left, and
    /// the companion stays registered only if the service still reports an
    /// active link. Whether `/telegram` is available at all
    /// in the channel is the channel's decision, taken before it attaches.
    /// An attach that a later attach, a detach, or a shutdown overtook while
    /// it waited returns without effect: the later operation owns the state.
    public func attach() async throws(TelegramCompanionAttachError) {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        runningAttachCount += 1
        defer { finishRunningAttach() }
        guard let settings = AgentSettingsManifestStore.load()?.telegram,
              let linkedChatID = settings.linkedChatID else {
            throw TelegramCompanionAttachError.notPaired
        }
        // Unsupported, ownerless or incoherent settings remain fail-closed
        // until setup creates a complete schema-2 owner route.
        guard let route = await egressRoute(
            settings: settings,
            linkedChatID: linkedChatID
        ) else {
            throw TelegramCompanionAttachError.invalidConfiguration
        }
        guard generation == lifecycleGeneration else { return }
        self.linkedChatID = linkedChatID
        linkedChatTitle = settings.linkedChatTitle
        linkedUserID = route.lease.key.userID
        activeRouteLease = route.lease
        sessionTopic = recordedSessionTopic(for: route)
        await installPollHealthHandlerIfNeeded()
        let startedState: TerminalTelegramControlState
        do {
            startedState = try await controlService.start()
        } catch {
            guard generation == lifecycleGeneration else { return }
            let description = TerminalTelegramControlError.operatorDescription(error)
            let currentState = await controlService.currentState()
            guard generation == lifecycleGeneration else { return }
            controlState = currentState
            controlState.lastError = description
            synchronizeAttachmentRegistration()
            await synchronizeTurnReporting()
            // A start that failed before reaching the poller leaves the link
            // that was up still up, and still notified; only a link that is
            // down stops receiving poll-health notices.
            if !controlState.isActive {
                await removePollHealthHandler()
            }
            throw TelegramCompanionAttachError.controlFailed(description: description)
        }
        guard generation == lifecycleGeneration else { return }
        controlState = startedState
        // Threaded mode is known, and the wire fenced, only from here on.
        let topicCreation = await createSessionTopicIfNeeded(for: route)
        guard generation == lifecycleGeneration else { return }
        if let topicCreation {
            adoptTopicCreation(topicCreation)
        }
        let lease = sessionTopic?.lease ?? route.lease
        // A turn of the primary channel that was already running while
        // Telegram was detached uses the same validated lease as the next one.
        if activeTurnOrigin == .primary {
            activeTurnOrigin = .telegram(lease)
        }
        voiceTranscriptions.resume()
        synchronizeAttachmentRegistration()
        await synchronizeTurnReporting()
        let chatTitle = linkedChatTitle?.nilIfBlank ?? "chat \(linkedChatID)"
        await channel?.presentCompanionNotice(
            """
            Telegram remote control is active.
            Linked chat: \(chatTitle)

            """,
            channel: .system
        )
        guard let topicCreation, generation == lifecycleGeneration else { return }
        await announceTopicCreation(topicCreation)
    }

    // MARK: - Detach and shutdown

    /// Unlinks the session (`/telegram off`).
    ///
    /// Stops the turn's Telegram side first, so nothing emitted while the
    /// service stops can reach the chat, then unbinds the shared-chat relay
    /// and stops the service. The relay's ledger and the turn's origin are
    /// kept, so a later ``attach()`` resumes them, and the ``presenter``
    /// stays in the controller, sending nothing until then. Every inbound
    /// temporary is deleted and every pending upload consent dropped. The
    /// companion leaves ``attachments`` and the primary channel is told the
    /// link stopped. Detaching a companion that is not attached does the same
    /// and tells the same. The consumption ``startConsuming()`` started
    /// stops first; a later attach is read again once the channel starts it
    /// again. In topic mode the session's topic route is closed and the
    /// inactive routes pruned once the service stopped
    /// (``closeSessionTopic()``); in legacy mode nothing is written.
    public func detach() async {
        lifecycleGeneration &+= 1
        // Disconnect the current turn before hopping to the service actor, so
        // events emitted while `stop()` is in flight cannot enqueue more output.
        controlState.isActive = false
        synchronizeAttachmentRegistration()
        await stopConsuming(shuttingDown: false)
        await voiceTranscriptions.cancelAllAndWait()
        let validationTask = routeValidationTask
        routeValidationTask = nil
        validationTask?.cancel()
        await validationTask?.value
        let reporter = activeProgressReporter
        activeProgressReporter = nil
        if let reporter { await reporter.shutdown() }
        if let presence = activePresenceLease {
            await controlService.releasePresenceLease(presence)
            activePresenceLease = nil
        }
        if let lease = activeTurnOrigin?.lease {
            await routeRuntimeState.teardown(lease: lease)
        }
        // Unbind before stopping the transport so no card is queued for a chat
        // that is about to be released. The ledger is retained on purpose; a
        // relay never created has nothing bound.
        await sharedChatRelayStorage?.deactivate()
        await removePollHealthHandler()
        controlState = await controlService.stop()
        await closeSessionTopic()
        activeRouteLease = nil
        linkedChatID = nil
        linkedChatTitle = nil
        linkedUserID = nil
        // Deterministic inbound-attachment teardown: every received temporary
        // is deleted and every pending upload consent is dropped.
        _ = await controlService.cleanupInboundAttachments()
        await channel?.presentCompanionNotice(
            "Telegram remote control stopped.\n",
            channel: .system
        )
    }

    /// Tears the link down when the session ends: the turn's Telegram side,
    /// the shared-chat relay, which cannot be used again, and the control
    /// service. Nothing is presented. The companion leaves ``attachments``,
    /// and its ``presenter`` leaves the controller. The consumption
    /// ``startConsuming()`` started stops, and with it, as at the end of
    /// the terminal's panel loop, every voice transcription for good. In
    /// topic mode the session's topic route is closed and the inactive
    /// routes pruned, as ``detach()`` does: the terminal always ends through
    /// here, and a route left active at every launch would never be pruned.
    public func shutdown() async {
        lifecycleGeneration &+= 1
        controlState.isActive = false
        synchronizeAttachmentRegistration()
        controller.detachCompanionPresenter(presenter)
        await stopConsuming(shuttingDown: true)
        let validationTask = routeValidationTask
        routeValidationTask = nil
        validationTask?.cancel()
        await validationTask?.value
        let reporter = activeProgressReporter
        activeProgressReporter = nil
        if let reporter { await reporter.shutdown() }
        if let presence = activePresenceLease {
            activePresenceLease = nil
            await controlService.releasePresenceLease(presence)
        }
        if let lease = activeTurnOrigin?.lease {
            await routeRuntimeState.teardown(lease: lease)
        }
        // Quiesce the relay before the transport it uses: its drain worker must
        // not outlive the service it sends through.
        await sharedChatRelayStorage?.shutdown()
        await removePollHealthHandler()
        _ = await controlService.stop()
        await closeSessionTopic()
    }

    /// Ends one ``attach()`` and, after the last one running, releases the
    /// poll-health notices that waited for it.
    private func finishRunningAttach() {
        runningAttachCount -= 1
        guard runningAttachCount == 0 else { return }
        let waiters = attachCompletionWaiters
        attachCompletionWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Registers the companion under its bot while the link is active, and
    /// removes it otherwise.
    private func synchronizeAttachmentRegistration() {
        if controlState.isActive, let botID = controlState.botID {
            attachments.register(self, botID: botID)
        } else {
            attachments.unregister(self)
        }
    }

    // MARK: - Poll health

    /// Tells the primary channel, once per transition, that Telegram ingress
    /// is dead because of a persistent polling failure, and when it comes
    /// back. Without it the channel would keep saying the link is active
    /// while no message can arrive, and the error would be visible only
    /// through `/telegram status`.
    func presentPollHealthNotice(_ notice: TerminalTelegramPollHealthNotice) async {
        guard controlState.isActive else { return }
        let generation = lifecycleGeneration
        let currentState = await controlService.currentState()
        // A lifecycle operation that started meanwhile owns the state.
        guard generation == lifecycleGeneration else { return }
        controlState = currentState
        switch notice {
        case let .failing(text):
            await channel?.presentCompanionNotice(
                """
                ZenCODE: Telegram is not receiving messages. \(text)
                ZenCODE keeps retrying every minute. Check the bot token with /setup, or stop the other process polling this bot. /telegram status shows the latest error.

                """,
                channel: .failure
            )
        case .recovered:
            await channel?.presentCompanionNotice(
                "Telegram polling recovered; messages are being received again.\n",
                channel: .system
            )
        }
    }

    /// Presents `notice` once no ``attach()`` is running, unless the task
    /// that delivers the notices was cancelled meanwhile.
    private func presentPollHealthNoticeAfterAttach(
        _ notice: TerminalTelegramPollHealthNotice
    ) async {
        while runningAttachCount > 0 {
            await withCheckedContinuation { attachCompletionWaiters.append($0) }
        }
        guard !Task.isCancelled else { return }
        await presentPollHealthNotice(notice)
    }

    /// Installs the control service's poll-health handler, unless it is
    /// already installed. The handler runs on the service actor and must not
    /// block, so it only yields the notice to a stream that one task
    /// presents in order.
    private func installPollHealthHandlerIfNeeded() async {
        guard pollHealthTask == nil else { return }
        let (notices, continuation) = AsyncStream.makeStream(
            of: TerminalTelegramPollHealthNotice.self
        )
        pollHealthContinuation = continuation
        pollHealthTask = Task(name: "ZenCODE.Telegram.companion-poll-health") { [weak self] in
            for await notice in notices {
                await self?.presentPollHealthNoticeAfterAttach(notice)
            }
        }
        await controlService.setPollHealthHandler { notice in
            continuation.yield(notice)
        }
    }

    /// Removes the poll-health handler and stops the task that presents its
    /// notices. It does not wait for that task, which may be waiting for the
    /// attach that removes the handler; once cancelled it presents nothing.
    private func removePollHealthHandler() async {
        guard let task = pollHealthTask else { return }
        pollHealthTask = nil
        let continuation = pollHealthContinuation
        pollHealthContinuation = nil
        task.cancel()
        continuation?.finish()
        await controlService.setPollHealthHandler(nil)
    }
}
