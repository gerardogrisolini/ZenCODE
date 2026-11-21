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
    /// The root response block and the reasoning block of the turn the
    /// channel follows (see `TelegramChannel+Turn.swift`).
    var turnBlocks = TurnBlocks()
    /// Change signature of the task-graph overview already sent during the
    /// current turn, so republished identical content does not repeat in
    /// the chat. Reset when a new turn begins.
    var publishedTaskGraphOverviewSignature: String?
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

    /// The root response block and the reasoning block streaming now in the
    /// turn the channel follows, and whether an intermediate root response
    /// was sent during the turn: what the channel decides at their
    /// boundaries. A turn boundary resets both blocks.
    struct TurnBlocks {
        /// The most characters a reasoning block keeps: just above the
        /// message limit, so the cut is still seen.
        static let maximumThoughtLength = TerminalTelegramTurnProgressReporter.maximumMessageLength + 1

        /// `true` when the root response block currently streaming already
        /// produced visible text.
        private(set) var rootResponseHasContent = false
        /// `true` when the root response block currently streaming must not
        /// be sent: part of it was produced before the channel presented
        /// the turn, so publishing the rest would send a suffix of a
        /// response the chat never saw begin. Cleared at the next boundary,
        /// where a new block starts.
        private(set) var rootResponseIsSuppressed = false
        /// `true` when at least one intermediate root response was already
        /// sent during the current turn, so the accumulated turn text must
        /// not be sent again as the final response.
        var didPublishIntermediateRootResponse = false
        /// The reasoning of the block streaming now, aggregated until the
        /// event that closes it (assistant content, a tool call, an
        /// automatic `/goal` continuation, the end of the turn) and then
        /// sent as one thinking message. Bounded by
        /// ``maximumThoughtLength``.
        private(set) var pendingThought = ""
        /// `true` while the reasoning streaming now must not be sent: the
        /// turn moved onto the channel while its assistant text streamed, so
        /// a reasoning block may have begun before the move. Cleared by the
        /// next event that closes a reasoning block.
        private(set) var thoughtIsSuppressed = false

        /// A turn moved onto the channel while its assistant text streamed:
        /// the rest of the root response block, and the reasoning streaming
        /// meanwhile, are suppressed until their next boundary.
        mutating func adoptStreamingBlocks() {
            rootResponseHasContent = true
            rootResponseIsSuppressed = true
            thoughtIsSuppressed = true
        }

        /// Records that the root response block produced visible text, and
        /// returns whether the text may be sent: `false` while the block is
        /// suppressed.
        mutating func recordRootResponseContent() -> Bool {
            rootResponseHasContent = true
            return !rootResponseIsSuppressed
        }

        /// Ends the root response block at a boundary, where a new block
        /// starts, and returns whether the block that ends was suppressed.
        mutating func endRootResponseBlock() -> Bool {
            let wasSuppressed = rootResponseIsSuppressed
            rootResponseHasContent = false
            rootResponseIsSuppressed = false
            return wasSuppressed
        }

        /// Suppresses the root response block, when one is streaming.
        mutating func suppressRootResponseIfStreaming() {
            guard rootResponseHasContent else { return }
            rootResponseIsSuppressed = true
        }

        /// Forgets the root-response state at a turn boundary.
        mutating func resetRootResponse() {
            rootResponseHasContent = false
            rootResponseIsSuppressed = false
            didPublishIntermediateRootResponse = false
        }

        /// Aggregates `delta` into the reasoning block, unless the block is
        /// suppressed, up to ``maximumThoughtLength``.
        mutating func appendThought(_ delta: String) {
            guard !delta.isEmpty, !thoughtIsSuppressed else { return }
            let remainingCount = Self.maximumThoughtLength - pendingThought.count
            guard remainingCount > 0 else { return }
            pendingThought.append(contentsOf: delta.prefix(remainingCount))
        }

        /// Returns the reasoning block and forgets it, as
        /// ``resetThought()`` does.
        mutating func takeThought() -> String {
            let thought = pendingThought
            resetThought()
            return thought
        }

        /// Forgets the reasoning block at a turn boundary.
        mutating func resetThought() {
            pendingThought = ""
            thoughtIsSuppressed = false
        }
    }

    // MARK: - Remote commands

    /// Pending ForceReply receipts for coordinator commands that need an
    /// argument. A reply must match both the receipt and its original route.
    var commandReplyBindings: [TerminalTelegramCommandReplyKey: TerminalTelegramCommandReplyBinding] = [:]

    // MARK: - Shared chat

    /// Telegram route of each live shared-chat message sent from the chat,
    /// so the coordinator turn it triggers answers on the same route (see
    /// `TelegramChannel+SharedChatRelay.swift`).
    var sharedChatMessageLeases = SharedChatMessageLeases()
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

    /// The Telegram route of each live shared-chat message sent from the
    /// chat, keyed by the transient bus message identity. Bounded like the
    /// retained shared-chat transcript: past
    /// ``AgentSharedChat/maximumRetainedMessagesPerRoom`` messages, the
    /// first one recorded is forgotten first.
    struct SharedChatMessageLeases {
        private var leases: [UUID: TerminalTelegramRouteLease] = [:]
        /// FIFO order of `leases`, by first recording.
        private var order: [UUID] = []

        /// Associates `lease` with the message `messageID`. A message
        /// recorded again keeps its place in the order.
        mutating func record(_ messageID: UUID, lease: TerminalTelegramRouteLease) {
            if leases[messageID] == nil {
                order.append(messageID)
            }
            leases[messageID] = lease
            let maximumLeases = AgentSharedChat.maximumRetainedMessagesPerRoom
            while order.count > maximumLeases {
                let oldestMessageID = order.removeFirst()
                leases.removeValue(forKey: oldestMessageID)
            }
        }

        /// Forgets the route of the message `messageID`.
        mutating func discard(_ messageID: UUID) {
            leases.removeValue(forKey: messageID)
            order.removeAll { $0 == messageID }
        }

        /// The route of the first of `messages` with one, without
        /// forgetting it.
        func lease(for messages: [AgentSharedChat.Message]) -> TerminalTelegramRouteLease? {
            for message in messages {
                if let lease = leases[message.id] {
                    return lease
                }
            }
            return nil
        }

        /// The route of the first of `messages` with one; the route of every
        /// message of `messages` is forgotten.
        mutating func take(for messages: [AgentSharedChat.Message]) -> TerminalTelegramRouteLease? {
            let lease = lease(for: messages)
            for message in messages {
                discard(message.id)
            }
            return lease
        }
    }

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
    /// (see `TerminalChat+Telegram.swift`). A message from the chat that
    /// arrives meanwhile passes the busy gate (``refusesMessagesAsBusy``), so a
    /// prompt queues and runs once the session is released
    /// (``sessionReservationDidEnd()``), after the turn's outcome and summary;
    /// the callback of a button is answered busy either way.
    var isPresentingPrimaryTurnEnding = false

    // MARK: - Lifecycle bookkeeping

    /// Advanced by every ``attach()``, ``detach()`` and ``shutdown()``, so an
    /// attach or a poll-health notice overtaken while it waited leaves the
    /// state to the operation that overtook it.
    var lifecycleGeneration = 0
    /// Delivers the control service's poll-health notices, in order, while
    /// the channel is attached.
    var pollHealthTask: Task<Void, Never>?
    var pollHealthContinuation: AsyncStream<TerminalTelegramPollHealthNotice>.Continuation?
    /// The ``attach()`` calls in progress. Poll-health notices wait for them,
    /// so a failure that polling reports while the service starts is
    /// presented once the link is active, after the text that says so.
    var runningAttachCount = 0
    var attachCompletionWaiters: [CheckedContinuation<Void, Never>] = []

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
        self.workingDirectory = host.slotWorkingDirectory(slotID) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        self.lastKnownSessionID = host.incarnation(in: slotID)?.sessionID ?? ""
        self.presenter = TelegramChannelPresenter()
        presenter.channel = self
        host.addIncarnationObserver(to: slotID) { [weak self] incarnation in
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

    // MARK: - Detach and shutdown

    /// What ``detach()`` tells the primary channel once the link stopped, and
    /// what a primary channel without a Telegram channel answers to
    /// `/telegram off`.
    public nonisolated static let stoppedNoticeText = "Telegram remote control stopped.\n"
}
