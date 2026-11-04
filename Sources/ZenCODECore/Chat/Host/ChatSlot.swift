//
//  ChatSlot.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation

/// Identifies one slot of a ``ChatSessionHost`` for as long as it is open.
public struct ChatSlotID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init() {
        rawValue = UUID()
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }
}

/// What a slot is to the channel that opened it.
public enum ChatSlotIdentity: Hashable, Sendable {
    /// The terminal the `zen` process runs in.
    case terminal
    /// One ACP session, by its session id.
    case acpSession(String)
    /// One window of a host app, by an identifier the app chooses.
    case window(String)
}

/// How the operator is asked, in every incarnation of a slot, what the
/// controller cannot decide alone (tool consent, menus, text, workspace
/// access): see ``ChatInteractionHost``.
public enum ChatSlotInteraction: Sendable {
    /// The channel's own host, the same object for every incarnation.
    case host(any ChatInteractionHost)
    /// A ``ChatPendingRequestHost`` per incarnation, bound to the reducer of
    /// that incarnation, which publishes each request in its snapshot and
    /// refuses the requests still open when the incarnation ends. Requires
    /// ``ChatSlotDescriptor/publishesState``.
    case pendingRequests(
        capabilities: ChatChannelCapabilities,
        gatesWorkspaceAccess: Bool = false,
        openExternal: (@Sendable (ChatOpenTarget) async throws -> Void)? = nil
    )
}

/// What a channel gives a ``ChatSessionHost`` to open a slot: the identity of
/// the place, its working directory, and the channel's bindings, which the
/// host applies to every incarnation the slot runs (see
/// ``ChatSessionHost/openSlot(_:)``).
public struct ChatSlotDescriptor: Sendable {
    public var identity: ChatSlotIdentity
    /// The working directory of every session the slot runs.
    public var workingDirectory: URL
    /// The channel's presenter, the presenter of every controller while the
    /// channel drives the slot (see ``ChatSlotChannel``).
    public var presenter: any ChatSessionPresenter
    public var interaction: ChatSlotInteraction
    /// The channel's consent policy for the gated tools.
    public var authorizer: ChatToolConsentAuthorizer
    /// The channel's own steps between the steps of a session operation,
    /// held weakly by the slot and by every controller.
    public var channelHooks: (any ChatSessionChannelHooks)?
    /// The slash commands of the channel; `nil` keeps the shared commands.
    public var commandRegistry: ChatCommandRegistry?
    /// See ``ChatSessionController``: `false` for channels that never read
    /// the session transcript or the artifact history.
    public var retainsTranscript: Bool
    public var retainsFileArtifactHistory: Bool
    /// The origin of the turns the channel starts without naming one, and
    /// the active channel of the snapshot while no turn runs.
    public var defaultOrigin: ChatTurnOrigin
    /// Whether every incarnation gets a ``ChatSessionStateReducer``, attached
    /// to its controller as it is created, so its snapshot sees the whole
    /// session (``ChatSessionIncarnation/reducer``). `false` for channels
    /// that present the session themselves and would retain the log for
    /// nobody.
    public var publishesState: Bool
    /// The prefix of the id of every session `/sessions new` starts in the
    /// slot, followed by a dash and a new lowercased UUID: `terminal` for the
    /// terminal (`terminal-<uuid>`), ``defaultSessionIDPrefix`` otherwise.
    public var sessionIDPrefix: String
    /// Whether every new session of the slot (`/sessions new`,
    /// ``ChatSessionHost/newSession(in:sessionID:)``) starts from the
    /// selection of the session it replaces (agent, model, thinking, tools,
    /// and skills, see ``ChatSessionSelection``) instead of the launch
    /// profile. A load still restores the selection the saved session
    /// recorded; the first session of a slot, and the one after
    /// ``ChatSessionHost/closeSession(in:runtimeSession:)``, start from the
    /// launch profile either way. `false` by default.
    public var keepsSelectionOnNewSession: Bool
    /// Presents the ending of a turn another channel of the slot ran, when
    /// the channel drives the slot as the turn ends, for a channel whose
    /// presenter does not conform to the slot's channel presenter (see
    /// ``ChatSessionHost/presentTurnEnding(_:in:)``). Internal: the terminal
    /// sets it; a presenter that conforms needs none.
    var presentTurnEnding: (@ChatSessionActor (ChatTurnEnding) async -> Void)?

    /// The ``sessionIDPrefix`` of a slot that names none: `chat`
    /// (`chat-<uuid>`).
    public static let defaultSessionIDPrefix = "chat"

    public init(
        identity: ChatSlotIdentity,
        workingDirectory: URL,
        presenter: any ChatSessionPresenter,
        interaction: ChatSlotInteraction,
        authorizer: ChatToolConsentAuthorizer,
        channelHooks: (any ChatSessionChannelHooks)? = nil,
        commandRegistry: ChatCommandRegistry? = nil,
        retainsTranscript: Bool = true,
        retainsFileArtifactHistory: Bool = true,
        defaultOrigin: ChatTurnOrigin = .local,
        publishesState: Bool = true,
        sessionIDPrefix: String = ChatSlotDescriptor.defaultSessionIDPrefix,
        keepsSelectionOnNewSession: Bool = false
    ) {
        self.identity = identity
        self.workingDirectory = workingDirectory
        self.presenter = presenter
        self.interaction = interaction
        self.authorizer = authorizer
        self.channelHooks = channelHooks
        self.commandRegistry = commandRegistry
        self.retainsTranscript = retainsTranscript
        self.retainsFileArtifactHistory = retainsFileArtifactHistory
        self.defaultOrigin = defaultOrigin
        self.publishesState = publishesState
        self.sessionIDPrefix = sessionIDPrefix
        self.keepsSelectionOnNewSession = keepsSelectionOnNewSession
    }
}

/// One place a channel runs sessions in: a terminal, an ACP session, a
/// window. The slot outlives its incarnations
/// (``ChatSessionIncarnation``): the channel's bindings belong to it and are
/// applied to each new controller, so a new or loaded session keeps the
/// channel's presenter, interaction, hooks, and commands while selection,
/// plan, workflow, and transcript start over (a new session keeps the
/// selection when the slot asks for it, see
/// ``ChatSlotDescriptor/keepsSelectionOnNewSession``). So does the slot's
/// Telegram link: the channel that drives the slot (``activeChannel``) and
/// the ``TelegramChannel`` behind it survive `/sessions new` and
/// `/sessions load`.
///
/// Every controller of the slot presents through the slot's
/// ``ChatSlotPresenter`` and asks through its ``ChatSlotInteractionHost``,
/// which forward to the channel that drives the slot now.
///
/// Isolated to ``ChatSessionActor`` with the host that owns it.
@ChatSessionActor
final class ChatSlot {
    let id: ChatSlotID
    let identity: ChatSlotIdentity
    let workingDirectory: URL
    /// The presenter of the channel that opened the slot.
    let presenter: any ChatSessionPresenter
    let interaction: ChatSlotInteraction
    let authorizer: ChatToolConsentAuthorizer
    /// Held weakly, as the controller holds it: the channel owns its hooks.
    weak var channelHooks: (any ChatSessionChannelHooks)?
    var commandRegistry: ChatCommandRegistry?
    let retainsTranscript: Bool
    let retainsFileArtifactHistory: Bool
    let defaultOrigin: ChatTurnOrigin
    let publishesState: Bool
    /// See ``ChatSlotDescriptor/sessionIDPrefix``.
    let sessionIDPrefix: String
    /// See ``ChatSlotDescriptor/keepsSelectionOnNewSession``.
    let keepsSelectionOnNewSession: Bool
    /// See ``ChatSlotDescriptor/presentTurnEnding``.
    let presentTurnEndingHandler: (@ChatSessionActor (ChatTurnEnding) async -> Void)?
    /// The session the slot runs now; `nil` between sessions. Every change
    /// (another incarnation, a reservation, a reducer attached or detached)
    /// is a change of the facts the shell shows.
    var incarnation: ChatSessionIncarnation? {
        didSet { shellFactsDidChange?() }
    }
    /// Called with the new incarnation (or `nil`) after every change of
    /// ``incarnation``, in registration order. A channel that follows the
    /// slot from one controller to the next registers here (see
    /// ``ChatSessionHost/addIncarnationObserver(to:_:)``).
    var incarnationObservers: [UUID: @ChatSessionActor (ChatSessionIncarnation?) -> Void] = [:]
    /// The streams of ``ChatSessionHost/incarnations(in:)`` still open, by
    /// the token of the observer that feeds them.
    var incarnationStreams: [UUID: AsyncStream<ChatSessionIncarnation?>.Continuation] = [:]
    /// Called after every change of what the shell shows of the slot (its
    /// incarnation, the channel that drives it, the state its controller
    /// presents), set by the host when it opens the slot (see
    /// `ChatSessionHost+Shell.swift`).
    var shellFactsDidChange: (@ChatSessionActor () -> Void)?
    /// `true` while the host replaces the slot's incarnation: the shell
    /// shows the slot once the replacement is done, never in between (see
    /// `ChatSessionHost+Shell.swift`).
    var holdsShellFacts = false
    /// The epoch of the incarnation the shell last read the saved sessions
    /// for, so that a new incarnation reads them again.
    var shellSavedSessionsEpoch: UInt64?

    // MARK: Channels

    /// The channel that drives the slot's turns now.
    var activeChannel: ChatSlotChannel = .primary
    /// The slot's Telegram channel, created by the first `/telegram on` and
    /// kept, attached or not, for the life of the slot.
    var telegramChannel: TelegramChannel?
    /// The presenter of every controller of the slot (see
    /// ``ChatSlotPresenter``); created with the slot.
    private(set) var slotPresenter: ChatSlotPresenter!
    /// The interaction host of every controller of the slot (see
    /// ``ChatSlotInteractionHost``); created with the slot.
    let slotInteractionHost: ChatSlotInteractionHost
    /// The last sequence the primary channel saw when it handed the slot to
    /// Telegram, with the epoch of the incarnation it was read on; `nil`
    /// while the primary channel drives the slot.
    var telegramHandoverLastSeenSequence: Int?
    var telegramHandoverEpoch: UInt64?
    /// `true` when the reducer of the current incarnation was created for the
    /// Telegram handover, not by ``ChatSlotDescriptor/publishesState``: it is
    /// detached once the catch-up is delivered.
    var reducerIsOnDemand = false
    /// The prompt the slot's Telegram channel reserved for the turn it runs
    /// now (``ChatSessionHost/runTelegramTurn(in:prompt:attachments:purpose:isUserVisible:)``);
    /// `nil` while no turn of the channel holds the slot's reservation.
    var telegramTurnPromptID: UUID? {
        didSet { shellFactsDidChange?() }
    }
    /// `true` while ``ChatSessionHost/activateTelegram(in:primaryChannelDescription:)``
    /// runs on the slot: another activation waits for it
    /// (``waitForTelegramActivation()``) instead of handing the slot over a
    /// second time.
    var isActivatingTelegram = false
    private var telegramActivationWaiters: [CheckedContinuation<Void, Never>] = []

    init(id: ChatSlotID, descriptor: ChatSlotDescriptor) {
        self.id = id
        identity = descriptor.identity
        workingDirectory = descriptor.workingDirectory
        presenter = descriptor.presenter
        interaction = descriptor.interaction
        authorizer = descriptor.authorizer
        channelHooks = descriptor.channelHooks
        commandRegistry = descriptor.commandRegistry
        retainsTranscript = descriptor.retainsTranscript
        retainsFileArtifactHistory = descriptor.retainsFileArtifactHistory
        defaultOrigin = descriptor.defaultOrigin
        publishesState = descriptor.publishesState
        sessionIDPrefix = descriptor.sessionIDPrefix
        keepsSelectionOnNewSession = descriptor.keepsSelectionOnNewSession
        presentTurnEndingHandler = descriptor.presentTurnEnding
        let primaryHost: any ChatInteractionHost
        switch descriptor.interaction {
        case let .host(host):
            primaryHost = host
        case .pendingRequests:
            // Replaced by the incarnation's pending-request host as soon as
            // one exists (see ``setIncarnation(_:)``).
            primaryHost = ChatRefusingInteractionHost()
        }
        slotInteractionHost = ChatSlotInteractionHost(activeHost: primaryHost)
        slotPresenter = ChatSlotPresenter(slot: self, primary: descriptor.presenter)
    }

    /// Installs `incarnation`, points the slot's host at its primary host
    /// while the primary channel drives the slot, and tells the observers.
    func setIncarnation(_ incarnation: ChatSessionIncarnation?) {
        self.incarnation = incarnation
        if activeChannel == .primary {
            setPrimaryInteractionHostActive()
        }
        for observer in incarnationObservers.values {
            observer(incarnation)
        }
    }

    /// The host of the primary channel for the incarnation the slot runs: the
    /// channel's own, or the pending-request host of the incarnation.
    var primaryInteractionHost: any ChatInteractionHost {
        switch interaction {
        case let .host(host):
            return host
        case .pendingRequests:
            return incarnation?.pendingRequestHost ?? ChatRefusingInteractionHost()
        }
    }

    /// Makes `channel` the channel that drives the slot: the slot's host asks
    /// on that channel from now on, and the requests still open are asked
    /// again there.
    func setActiveChannel(_ channel: ChatSlotChannel) {
        activeChannel = channel
        switch channel {
        case .primary:
            setPrimaryInteractionHostActive()
        case .telegram:
            slotInteractionHost.setActiveHost(
                telegramChannel ?? primaryInteractionHost,
                channel: .telegram,
                incarnationEpoch: incarnation?.epoch
            )
        }
        shellFactsDidChange?()
    }

    /// Points the slot's host at the primary host of the incarnation the slot
    /// runs; nothing moves when that is the host already active.
    private func setPrimaryInteractionHostActive() {
        slotInteractionHost.setActiveHost(
            primaryInteractionHost,
            channel: .primary,
            incarnationEpoch: incarnation?.epoch
        )
    }

    /// Waits until no activation of Telegram runs on the slot.
    func waitForTelegramActivation() async {
        while isActivatingTelegram {
            await withCheckedContinuation { telegramActivationWaiters.append($0) }
        }
    }

    /// Ends the activation of Telegram that runs on the slot and wakes the
    /// activations that wait for it; the first of them to run goes on, the
    /// others wait for that one.
    func endTelegramActivation() {
        isActivatingTelegram = false
        let waiters = telegramActivationWaiters
        telegramActivationWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Forgets the observers and ends the streams: the slot is closing.
    func endObservation() {
        incarnationObservers.removeAll()
        shellFactsDidChange = nil
        let streams = incarnationStreams
        incarnationStreams.removeAll()
        for continuation in streams.values {
            continuation.finish()
        }
    }
}
