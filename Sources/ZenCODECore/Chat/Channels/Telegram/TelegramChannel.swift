//
//  TelegramChannel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The Telegram channel of one slot of a ``ChatSessionHost``: the linked
/// chat drives the slot's session while the slot is handed to it
/// (`/telegram on`, see ``ChatSessionHost/activateTelegram(in:primaryChannelDescription:)``),
/// and the primary channel takes it back with `/telegram off`. There is no
/// mirror: while Telegram drives the slot, the chat is where the session's
/// turns start and are presented, where its questions are asked, and where
/// the shared chat's messages for the operator arrive.
///
/// The channel owns everything the link needs: the control service and its
/// lifecycle, the validated route lease, the linked chat, the session's topic
/// (`+Topics`), and the Telegram side of the turn in progress (`+Turn`). It
/// runs the turns the chat asks for through the host
/// (``ChatSessionHost/runTelegramTurn(in:prompt:attachments:purpose:isUserVisible:)``),
/// with the composition of the slot's primary channel, so a prompt, a voice
/// note, or a `/plan` `/goal` `/review` from the chat runs as one typed on the
/// primary channel; a prompt that arrives while the session generates waits
/// in the channel's queue. Its ``presenter`` receives the session's output
/// from the slot's presenter while the channel drives the slot, a turn that
/// moved onto it included, and its interaction host
/// (`TelegramChannel+Consent.swift`) answers the controller's questions in the
/// chat: tool consent with `/allow`, `/always` and `/deny`, a line of text
/// with the next message, an attachment with the next document or image, and
/// a single or multiple choice with an inline menu (`+ChoiceMenus`), during
/// which any other message is answered with ``choicePendingText``.
///
/// What Telegram asks of the session beyond prompts is answered here too:
/// `/diff`, the artifact consent buttons and inbound attachments
/// (`+Artifacts`), voice notes (`+Voice`), the shared-chat relay and its
/// replies (`+SharedChatRelay`), the `/chat` mention picker
/// (`+MentionPicker`), and the `/models` `/think` `/agents` selection menus
/// (`+SelectionMenus`) and the `/sessions` menus (`+SessionsMenu`). The
/// ingress is in `TelegramChannel+Ingress.swift`; the
/// task-graph observer the channel runs on an ACP session's slot, and on the
/// slot of a session started by `zen --telegram`, is in
/// `TelegramChannel+TaskGraph.swift`.
///
/// ``attach()`` links the session, ``detach()`` unlinks it and keeps what a
/// later attach reuses, and ``shutdown()`` is the teardown when the slot
/// closes. The host runs them one at a time.
///
/// All state is isolated to ``ChatSessionActor``, like the host and the
/// controllers. The channel holds the host weakly: the host owns the channel
/// through the slot, which outlives the slot's incarnations, so the channel
/// reads the controller it drives from the host at each use.
@ChatSessionActor
public final class TelegramChannel: ChatInteractionHost {
    /// External effects a test records instead of performing.
    enum TelegramWorkEffectForTesting: Sendable {
        case attachmentDownload
        case voiceTranscription
        case sharedChatPublication
    }

    // MARK: - Collaborators

    /// The host whose slot the channel belongs to.
    weak var host: ChatSessionHost?
    /// The slot the channel drives.
    let slotID: ChatSlotID
    /// The runtime behind the shared chat the channel relays.
    let sessionRunner: AgentCoreSessionRunner
    /// The route authority: every lease is resolved and validated here.
    let router: TerminalTelegramSessionRouter
    /// The channel's own control service: transport, polling, and wire
    /// lifecycle.
    let controlService: TerminalTelegramControlService
    /// The primary channel's name in the texts sent to Telegram: "TUI" for
    /// the terminal, "editor" for an ACP session, "Telegram" for a session
    /// started by `zen --telegram`, which has no other channel.
    let primaryChannelDescription: String
    /// Where the channel is registered while attached.
    let registry: TelegramChannelRegistry
    /// Per-route runtime state (pending replies, voice, uploads) torn down
    /// with the route of the turn in progress.
    let routeRuntimeState: TerminalTelegramRouteRuntimeState
    /// Permission requests asked in the linked chat.
    let permissionBroker = TerminalTelegramPermissionBroker()
    /// Owns all Telegram voice download and transcription tasks across
    /// detach and attach.
    let voiceTranscriptions = TerminalVoiceTranscriptionRegistry()
    /// The channel's presenter, which the slot's presenter forwards to while
    /// the channel drives the slot (see ``TelegramChannelPresenter``).
    let presenter: TelegramChannelPresenter
    /// Where the texts meant for the primary channel go (the activation
    /// text, a poll-health notice, a failure): the terminal writes them as
    /// system or failure messages. `text` is complete, trailing newline
    /// included. `nil` drops them.
    public var noticeSink: (@ChatSessionActor (_ text: String, _ channel: ChatSessionNoticeChannel) async -> Void)?

    // MARK: - Link

    /// The control service's state as last read; ``isActive`` is its
    /// `isActive`.
    var controlState = TerminalTelegramControlState.inactive()
    public internal(set) var linkedChatID: Int64?
    public internal(set) var linkedChatTitle: String?
    /// Telegram user id of the last linked-chat sender, used to bind outbound
    /// artifact consent offers to the operator who will confirm them.
    var linkedUserID: Int64?
    /// Last validated route binding. Shared-chat relay and receipts are
    /// fenced by this exact generation and topic. In topic mode it stays the
    /// session's topic (see `TelegramChannel+Topics.swift`).
    var activeRouteLease: TerminalTelegramRouteLease?
    /// The session's own topic while the link is in topic mode; `nil` in
    /// legacy mode and while detached.
    public internal(set) var sessionTopic: SessionTopic?
    /// The id of the session the channel last drove, for a lookup between
    /// incarnations.
    var lastKnownSessionID: String

    // MARK: - Turn in progress

    /// The route lease of the turn currently generating, when the turn's
    /// progress reaches the linked chat: the lease of the message that
    /// started it, or the link's route for a turn that moved onto the
    /// channel.
    var activeTurnLease: TerminalTelegramRouteLease?
    /// Ordered Telegram channel of the turn currently generating. Permission
    /// dialogue is enqueued here so it cannot overtake the tool activity that
    /// raised it.
    var activeProgressReporter: TerminalTelegramTurnProgressReporter?
    /// Lifecycle-safe typing lease held for the turn, if any. Replaced by
    /// the next turn's lease, released at turn end, and fenced by generation
    /// inside the lease manager.
    var activePresenceLease: TerminalTelegramPresenceLeaseManager.Lease?
    /// Stops a Telegram-originated turn as soon as its route generation is
    /// revoked, rebound, or closed.
    var routeValidationTask: Task<Void, Never>?
    /// `true` when the root response block currently streaming already
    /// produced visible text.
    var rootResponseBlockHasContent = false
    /// `true` when the root response block currently streaming must not be
    /// sent: part of it was produced before the channel presented the turn,
    /// so publishing the rest would send a suffix of a response the chat
    /// never saw begin. Cleared at the next boundary, where a new block
    /// starts.
    var rootResponseBlockIsSuppressed = false
    /// `true` when at least one intermediate root response was already sent
    /// during the current turn, so the accumulated turn text must not be
    /// sent again as the final response.
    var didPublishIntermediateRootResponse = false
    /// Change signature of the task-graph overview already sent during the
    /// current turn, so republished identical content does not repeat in
    /// the chat. Reset when a new turn begins.
    var publishedTaskGraphOverviewSignature: String?
    /// The reasoning of the block streaming now, aggregated until the event
    /// that closes it (assistant content, a tool call, an automatic `/goal`
    /// continuation, the end of the turn) and then sent as one thinking
    /// message (see `TelegramChannel+Turn.swift`). Bounded just above the
    /// message limit, so the cut is still seen.
    var pendingThought = ""
    /// `true` while the reasoning streaming now must not be sent: the turn
    /// moved onto the channel while its assistant text streamed, so a
    /// reasoning block may have begun before the move. Cleared by the next
    /// event that closes a reasoning block.
    var thoughtBlockIsSuppressed = false
    /// The task running the turn the channel started through the host, while
    /// one runs (see `TelegramChannel+Turn.swift`).
    var activeTurnTask: Task<Void, Never>?
    /// The prompt the host had reserved when the turn the channel follows
    /// began on the channel (``beginTurn(adoptingStreamingBlock:)``): the
    /// channel's own turn, or the primary channel's turn that moved onto it.
    /// ``stopActiveTurn(promptID:)`` cancels that reservation and no other.
    var activeTurnPromptID: UUID?
    /// The route of the message whose turn is about to start, set around the
    /// host call so that ``beginTurn(adoptingStreamingBlock:)`` reports the
    /// turn on it; `nil` otherwise.
    var nextTurnLease: TerminalTelegramRouteLease?
    /// The prompts from the chat waiting for the session to be free, each on
    /// the route it arrived on, run in order once the turn in progress ends.
    var promptQueue = ChatPromptQueue<TerminalTelegramRouteLease>()

    // MARK: - Remote commands

    /// Pending ForceReply receipts for coordinator commands that need an
    /// argument. A reply must match both the receipt and its original route.
    var commandReplyBindings: [TerminalTelegramCommandReplyKey: TerminalTelegramCommandReplyBinding] = [:]

    // MARK: - Shared chat

    /// Telegram route of a live shared-chat message, keyed by the transient
    /// bus message identity, so the coordinator turn it triggers answers on
    /// the same route. Bounded like the retained shared-chat transcript.
    var sharedChatMessageLeases: [UUID: TerminalTelegramRouteLease] = [:]
    /// FIFO order of ``sharedChatMessageLeases``.
    var sharedChatMessageLeaseOrder: [UUID] = []
    /// The relay that forwards operator-directed shared-chat messages to the
    /// linked chat, created on first use and kept for the channel's
    /// lifetime, so its ledger survives a detach and a later attach.
    var sharedChatRelayStorage: TerminalTelegramSharedChatRelay?
    /// `true` only while something consumes the Telegram ingress of this
    /// session, so a reply to a forwarded card can actually be delivered.
    var readsIngress = false
    /// The observation of the session's shared-chat room while the channel
    /// drives the slot (see `TelegramChannel+SharedChatRelay.swift`).
    var sharedChatObservationTask: Task<Void, Never>?
    var sharedChatObservation: AgentSharedChatCoordinator.Observation?
    /// The room ``sharedChatObservationTask`` observes.
    var observedSharedChatRoomID: String?

    // MARK: - Task graph (ACP and `zen --telegram` slots)

    /// `true` while the channel observes the graph of an ACP session's slot
    /// or of a `zen --telegram` slot (see ``runsTaskGraphObserver``): set by
    /// ``startDriving()`` on such a slot, even when the slot runs no session
    /// yet, and cleared by ``stopTaskGraphObservation()``. The observer
    /// follows the slot's incarnations while it is `true` (see
    /// `TelegramChannel+TaskGraph.swift`).
    var observesTaskGraph = false
    /// The last work on the controller's task-graph observer the channel
    /// queued (a binding, the quiescence at a turn boundary, the restart
    /// after it), which awaits the work queued before it; ``stopTaskGraphObservation()``
    /// awaits it. It stays set once done, until the observation stops;
    /// always `nil` on every other slot.
    var taskGraphObservationTask: Task<Void, Never>?
    /// The controller whose task-graph observer the channel binds, from the
    /// moment it queues the binding until the observation stops.
    weak var taskGraphObservedController: ChatSessionController?

    // MARK: - Ingress

    /// The task ``startDriving()`` started to read the control service's
    /// messages, until ``stopDriving()`` or ``shutdown()`` stops it.
    var ingressConsumerTask: Task<Void, Never>?
    /// The question waiting for the next text message of the chat, when the
    /// controller asked for a line (see `TelegramChannel+Consent.swift`).
    var pendingLineReader: PendingReader<String>?
    /// The question waiting for the next document or image of the chat, when
    /// the controller asked for an attachment.
    var pendingAttachmentReader: PendingReader<URL>?
    /// The menu waiting for a tap, when the controller asked for a choice
    /// (see `TelegramChannel+ChoiceMenus.swift`).
    var pendingChoiceReader: PendingChoiceReader?

    /// A controller question answered by the next message of the chat.
    struct PendingReader<Answer: Sendable> {
        let id: UUID
        let lease: TerminalTelegramRouteLease
        let continuation: CheckedContinuation<Answer?, Never>
    }

    // MARK: - Artifacts

    /// Where outbound artifacts are staged before an upload; the only
    /// directory whose files `/diff` may send (see ``artifactPolicy``). The
    /// terminal's location by default; a test points it at a directory of
    /// its own. Created 0700 when used.
    var artifactStagingDirectory = TelegramChannel.defaultArtifactStagingDirectory

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
    /// Keyboard edits of a selection menu's message, with the new markup
    /// (`nil` removes the keyboard), the chat, and the message; `nil` in
    /// production, which edits through the service.
    var onTelegramReplyMarkupEditForTesting: (@Sendable (TerminalTelegramReplyMarkup?, Int64, Int) async -> Void)?
    /// Stands in for the turn the channel would run through the host, with
    /// the prompt, its route, and its purpose; `nil` in production.
    var onRunTurnForTesting: (@Sendable (String, TerminalTelegramRouteLease, ChatTurnPurpose) async -> Void)?
    /// Called each time ``beginTurn(adoptingStreamingBlock:liveThought:)``
    /// waits for the turn that is finishing, before it suspends; `nil` in
    /// production.
    var onBeginTurnWaitsForFinishingTurnForTesting: (@ChatSessionActor () -> Void)?

    // MARK: - Turn boundaries

    /// How many ``finishTurn(ending:)`` calls are running: while one is, the
    /// turn it closes still owns the turn's Telegram side, and a turn that
    /// begins waits (see ``beginTurn(adoptingStreamingBlock:liveThought:)``).
    var finishingTurnCount = 0
    /// The turns waiting in ``beginTurn(adoptingStreamingBlock:liveThought:)``
    /// for ``finishingTurnCount`` to drop to zero, oldest first.
    var finishingTurnWaiters: [CheckedContinuation<Void, Never>] = []
    /// `true` while the primary channel presents in the chat the ending of a
    /// turn it ran, with the session still reserved for that turn: from
    /// ``primaryTurnEndingWillPresent()`` to ``sessionReservationDidEnd()``
    /// (see `TerminalChat+Telegram.swift`). What a message from the chat gets
    /// meanwhile is ``refusesMessagesWhilePrimaryTurnEndingPresents``.
    var isPresentingPrimaryTurnEnding = false
    /// The one policy for a message from the chat that arrives while the
    /// primary channel presents here the ending of a turn it ran, with the
    /// session still reserved for that turn
    /// (``isPresentingPrimaryTurnEnding``). `false`, the default, lets it
    /// through the busy gate, so a prompt queues and runs once the session is
    /// released (``sessionReservationDidEnd()``), after the turn's outcome and
    /// summary; `true` answers it with ``busyMessageText``, as during the rest
    /// of the turn. The callback of a button is answered busy either way. Read
    /// by ``refusesMessagesAsBusy``; a test sets it.
    var refusesMessagesWhilePrimaryTurnEndingPresents = false

    // MARK: - Lifecycle bookkeeping

    /// Advanced by every ``attach()``, ``detach()`` and ``shutdown()``, so an
    /// attach or a poll-health notice overtaken while it waited leaves the
    /// state to the operation that overtook it.
    private var lifecycleGeneration = 0
    /// Delivers the control service's poll-health notices, in order, while
    /// the channel is attached.
    private var pollHealthTask: Task<Void, Never>?
    private var pollHealthContinuation: AsyncStream<TerminalTelegramPollHealthNotice>.Continuation?
    /// The ``attach()`` calls in progress. Poll-health notices wait for them,
    /// so a failure that polling reports while the service starts is
    /// presented once the link is active, after the text that says so.
    private var runningAttachCount = 0
    private var attachCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    /// The Telegram channel of the slot `slotID` of `host`, detached until
    /// ``attach()``.
    convenience init(
        host: ChatSessionHost,
        slotID: ChatSlotID,
        sessionRunner: AgentCoreSessionRunner,
        router: TerminalTelegramSessionRouter,
        controlService: TerminalTelegramControlService,
        primaryChannelDescription: String
    ) {
        self.init(
            host: host,
            slotID: slotID,
            sessionRunner: sessionRunner,
            router: router,
            controlService: controlService,
            primaryChannelDescription: primaryChannelDescription,
            registry: .shared
        )
    }

    init(
        host: ChatSessionHost,
        slotID: ChatSlotID,
        sessionRunner: AgentCoreSessionRunner,
        router: TerminalTelegramSessionRouter,
        controlService: TerminalTelegramControlService,
        primaryChannelDescription: String,
        registry: TelegramChannelRegistry
    ) {
        self.host = host
        self.slotID = slotID
        self.sessionRunner = sessionRunner
        self.router = router
        self.controlService = controlService
        self.primaryChannelDescription = primaryChannelDescription
        self.registry = registry
        self.routeRuntimeState = TerminalTelegramRouteRuntimeState(router: router)
        self.workingDirectory = host.slotWorkingDirectory(slotID) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        self.lastKnownSessionID = host.incarnation(in: slotID)?.sessionID ?? ""
        self.presenter = TelegramChannelPresenter()
        presenter.channel = self
        incarnationObserverToken = host.addIncarnationObserver(to: slotID) { [weak self] incarnation in
            self?.incarnationDidChange(incarnation)
        }
    }

    /// The slot runs `incarnation` now: a new session (`/sessions new`,
    /// `/sessions load`) or a session that changed id in place. While the
    /// channel drives the slot, the shared-chat observation and the relay
    /// follow the new room; the topic follows it when the primary channel
    /// rebinds it (``rebind(sessionID:displayName:)``).
    private func incarnationDidChange(_ incarnation: ChatSessionIncarnation?) {
        guard let incarnation else { return }
        lastKnownSessionID = incarnation.sessionID
        guard drivesSlot else { return }
        rebindTaskGraphObservationIfNeeded()
        Task { @ChatSessionActor [weak self] in
            await self?.rebindSharedChatObservationIfNeeded()
        }
    }

    /// The token of the channel's incarnation observer on its slot.
    private var incarnationObserverToken: UUID?

    /// The working directory of the slot's sessions.
    let workingDirectory: URL

    /// Whether the link is active: the control service started and was not
    /// stopped since.
    public var isActive: Bool {
        controlState.isActive
    }

    /// Whether the channel drives its slot now.
    var drivesSlot: Bool {
        host?.activeChannel(in: slotID) == .telegram
    }

    // MARK: - Session

    /// The controller of the session the slot runs now; `nil` between
    /// sessions or once the host is gone.
    var controller: ChatSessionController? {
        host?.incarnation(in: slotID)?.controller
    }

    /// The id of the session the slot runs now, or the last one it ran.
    var sessionID: String {
        host?.incarnation(in: slotID)?.sessionID ?? lastKnownSessionID
    }

    /// Whether the slot's session generates a turn right now, as the host
    /// holds the prompt reservation; `false` for a slot without session.
    var isSessionGenerating: Bool {
        host?.incarnation(in: slotID)?.activePromptID != nil
    }

    // MARK: - Attach

    /// Links the session to Telegram (`/telegram on`).
    ///
    /// Resolves the owner route persisted by setup, records the linked chat,
    /// and starts the control service, which restarts it when the channel
    /// is already attached, exactly as a repeated `/telegram on` does. The
    /// route is the session's topic, reused or created once the service
    /// started, or the route every session shares (see
    /// `TelegramChannel+Topics.swift`). The primary channel is told the link
    /// is active through ``noticeSink``; a created topic is then announced
    /// in General, and a topic that could not be created is reported after
    /// the activation text. On success the channel is registered in
    /// ``registry`` under its bot.
    ///
    /// Throws when the session cannot be linked; the primary channel presents
    /// the error's ``TelegramChannelAttachError/failureText``. When the
    /// service fails to start, the error is recorded as the control state's
    /// `lastError`, and the channel stays registered only if the service
    /// still reports an active link. Whether `/telegram` is available at all
    /// in the channel is the channel's decision, taken before it attaches. An
    /// attach that a later attach, a detach, or a shutdown overtook while it
    /// waited returns without effect: the later operation owns the state.
    public func attach() async throws(TelegramChannelAttachError) {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        runningAttachCount += 1
        defer { finishRunningAttach() }
        guard let settings = AgentSettingsManifestStore.load()?.telegram,
              let linkedChatID = settings.linkedChatID else {
            throw TelegramChannelAttachError.notPaired
        }
        // Unsupported, ownerless or incoherent settings remain fail-closed
        // until setup creates a complete schema-2 owner route.
        guard let route = await egressRoute(
            settings: settings,
            linkedChatID: linkedChatID
        ) else {
            throw TelegramChannelAttachError.invalidConfiguration
        }
        guard generation == lifecycleGeneration else { return }
        self.linkedChatID = linkedChatID
        linkedChatTitle = settings.linkedChatTitle
        linkedUserID = route.lease.key.userID
        let hadRouteLease = activeRouteLease != nil
        activeRouteLease = route.lease
        sessionTopic = recordedSessionTopic(for: route)
        // A repeated `/telegram on` gives a channel that lost its route one.
        await activeRouteLeaseDidChange(hadLease: hadRouteLease)
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
            synchronizeRegistration()
            await synchronizeTurnReporting()
            // A start that failed before reaching the poller leaves the link
            // that was up still up, and still notified; only a link that is
            // down stops receiving poll-health notices.
            if !controlState.isActive {
                await removePollHealthHandler()
            }
            throw TelegramChannelAttachError.controlFailed(description: description)
        }
        guard generation == lifecycleGeneration else { return }
        controlState = startedState
        // Threaded mode is known, and the wire fenced, only from here on.
        let topicCreation = await createSessionTopicIfNeeded(for: route)
        guard generation == lifecycleGeneration else { return }
        if let topicCreation {
            adoptTopicCreation(topicCreation)
        }
        voiceTranscriptions.resume()
        synchronizeRegistration()
        await synchronizeTurnReporting()
        let chatTitle = linkedChatTitle?.nilIfBlank ?? "chat \(linkedChatID)"
        await presentNotice(
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

    /// What ``detach()`` tells the primary channel once the link stopped, and
    /// what a primary channel without a Telegram channel answers to
    /// `/telegram off`.
    public nonisolated static let stoppedNoticeText = "Telegram remote control stopped.\n"

    /// Unlinks the session (`/telegram off`).
    ///
    /// Stops the turn's Telegram side first, so nothing emitted while the
    /// service stops can reach the chat, then unbinds the shared-chat relay
    /// and stops the service. The relay's ledger is kept, so a later
    /// ``attach()`` resumes it. Every inbound temporary is deleted and every
    /// pending upload consent dropped. The channel leaves ``registry`` and
    /// the primary channel is told the link stopped. Detaching a channel that
    /// is not attached does the same and tells the same. What
    /// ``startDriving()`` started stops first; the queued prompts are
    /// dropped. In topic mode the session's topic route is closed and the
    /// inactive routes pruned once the service stopped
    /// (``closeSessionTopic()``); in legacy mode nothing is written.
    public func detach() async {
        lifecycleGeneration &+= 1
        // Disconnect the current turn before hopping to the service actor, so
        // events emitted while `stop()` is in flight cannot enqueue more output.
        controlState.isActive = false
        synchronizeRegistration()
        await stopDriving(shuttingDown: false)
        await voiceTranscriptions.cancelAllAndWait()
        await endTurnReporting()
        if let lease = activeRouteLease {
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
        await presentNotice(Self.stoppedNoticeText, channel: .system)
    }

    /// Tears the link down when the slot closes: the turn's Telegram side,
    /// the shared-chat relay, which cannot be used again, and the control
    /// service. Nothing is presented. The channel leaves ``registry``. What
    /// ``startDriving()`` started stops, and with it every voice
    /// transcription for good. In topic mode the session's topic route is
    /// closed and the inactive routes pruned, as ``detach()`` does: the
    /// terminal always ends through here, and a route left active at every
    /// launch would never be pruned.
    public func shutdown() async {
        lifecycleGeneration &+= 1
        controlState.isActive = false
        synchronizeRegistration()
        await stopDriving(shuttingDown: true)
        await endTurnReporting()
        if let lease = activeRouteLease {
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

    /// Registers the channel under its bot while the link is active, and
    /// removes it otherwise.
    private func synchronizeRegistration() {
        if controlState.isActive, let botID = controlState.botID {
            registry.register(self, botID: botID)
        } else {
            registry.unregister(self)
        }
    }

    // MARK: - Notices to the primary channel

    /// Presents `text` on the primary channel through ``noticeSink``.
    func presentNotice(_ text: String, channel: ChatSessionNoticeChannel) async {
        await noticeSink?(text, channel)
    }

    // MARK: - Poll health

    /// Tells the primary channel, once per transition, that Telegram ingress
    /// is dead because of a persistent polling failure, and when it comes
    /// back. Without it the channel would keep saying the link is active
    /// while no message can arrive, and the error would be visible only
    /// through `/telegram`.
    func presentPollHealthNotice(_ notice: TerminalTelegramPollHealthNotice) async {
        guard controlState.isActive else { return }
        let generation = lifecycleGeneration
        let currentState = await controlService.currentState()
        // A lifecycle operation that started meanwhile owns the state.
        guard generation == lifecycleGeneration else { return }
        controlState = currentState
        switch notice {
        case let .failing(text):
            await presentNotice(
                """
                ZenCODE: Telegram is not receiving messages. \(text)
                ZenCODE keeps retrying every minute. Check the bot token with /setup, or stop the other process polling this bot. /telegram shows the latest error.

                """,
                channel: .failure
            )
        case .recovered:
            await presentNotice(
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
        pollHealthTask = Task(name: "ZenCODE.Telegram.channel-poll-health") { [weak self] in
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
