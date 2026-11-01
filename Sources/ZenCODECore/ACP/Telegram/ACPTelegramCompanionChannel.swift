//
//  ACPTelegramCompanionChannel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import Synchronization
import ToolCore

/// Which ACP session incarnations are generating a prompt right now, as the
/// bridge last published them: the epoch of every session whose
/// `activePromptID` is set, by session id.
///
/// ``TelegramCompanionChannel/isSessionGenerating()`` is synchronous on
/// ``ChatSessionActor``, while `activePromptID` is isolated to the bridge
/// actor, so the channel cannot ask the bridge directly. The protocol stays
/// synchronous on purpose: it is the contract of every primary channel, and
/// making it asynchronous for ACP would change the companion and the
/// terminal for nothing. The bridge publishes instead, from its own
/// isolation, a copy of what the question needs after every change of its
/// sessions (`sessions`' `didSet`), and the channel reads that copy under
/// the lock for its own incarnation. The answer is the one the bridge gave
/// at its last change, which is the most any reader on another actor could
/// observe.
final class ACPSessionPromptActivity: Sendable {
    private let generatingEpochs = Mutex<[String: UInt64]>([:])

    /// Replaces the published state with `epochsBySessionID`: the epoch of
    /// each session generating a prompt.
    func publish(_ epochsBySessionID: [String: UInt64]) {
        generatingEpochs.withLock { $0 = epochsBySessionID }
    }

    /// Whether the incarnation `epoch` of `sessionID` is generating a prompt.
    /// A newer incarnation with the same id does not count.
    func isGenerating(sessionID: String, epoch: UInt64) -> Bool {
        generatingEpochs.withLock { $0[sessionID] == epoch }
    }
}

/// The ACP session as the primary channel of its Telegram companion.
///
/// An editor drives the session: the companion only mirrors it
/// (``TelegramSessionCompanion/Policy/mirrorOnly``) and answers what can be
/// consulted or approved from the linked chat. So the channel runs no prompt
/// that arrives from Telegram, and, when a route is invalidated, unlinks
/// Telegram without stopping the editor's turn. ACP has no place for a
/// message outside a prompt's reply, so the companion's notices are
/// presented only while the bridge answers `/telegram on`: they follow the
/// activation text in that reply (see ``takePendingNotices()``); every other
/// notice is dropped.
///
/// One channel serves one incarnation of one session (`sessionID`, `epoch`).
/// The bridge keeps it in the session state next to the companion, which
/// holds it weakly; the channel holds the companion weakly too.
@ChatSessionActor
final class ACPTelegramCompanionChannel: TelegramCompanionChannel {
    /// The companion configuration of every ACP session: the session is
    /// driven by the editor, where permissions are asked too.
    nonisolated static let configuration = TelegramSessionCompanion.Configuration(
        primaryChannelDescription: "editor",
        policy: .mirrorOnly,
        consentLocationDescription: "the editor"
    )

    let primaryChannelDescription = ACPTelegramCompanionChannel.configuration.primaryChannelDescription
    let sessionID: String
    let epoch: UInt64
    private let promptActivity: ACPSessionPromptActivity
    weak var companion: TelegramSessionCompanion?
    /// The notices the companion presented since
    /// ``beginCollectingNotices()``, without their trailing newlines.
    private var pendingNotices: [String] = []
    /// Whether a `/telegram on` reply is being composed, so the companion's
    /// notices are kept for it instead of being dropped.
    private var collectsNotices = false

    init(sessionID: String, epoch: UInt64, promptActivity: ACPSessionPromptActivity) {
        self.sessionID = sessionID
        self.epoch = epoch
        self.promptActivity = promptActivity
    }

    /// No facts: the context only decides `/plan`, `/goal` and `/review`
    /// from Telegram, which the mirror-only policy refuses before reading it.
    func commandContext() -> ChatCommandContext {
        []
    }

    /// Kept for the `/telegram on` reply while one is being composed (see
    /// ``beginCollectingNotices()``); dropped otherwise, because ACP writes
    /// only inside a prompt's reply.
    func presentCompanionNotice(_ text: String, channel: ChatSessionNoticeChannel) async {
        guard collectsNotices else { return }
        var notice = Substring(text)
        while notice.last?.isNewline == true {
            notice.removeLast()
        }
        pendingNotices.append(String(notice))
    }

    /// Starts keeping the companion's notices for the reply to a
    /// `/telegram on`, from an empty list.
    func beginCollectingNotices() {
        pendingNotices.removeAll()
        collectsNotices = true
    }

    /// The notices kept since ``beginCollectingNotices()``, in the order the
    /// companion presented them, without their trailing newlines. From here
    /// on the notices are dropped again.
    func takePendingNotices() -> [String] {
        let notices = pendingNotices
        pendingNotices.removeAll()
        collectsNotices = false
        return notices
    }

    /// Attaches `companion` (`/telegram on`) and returns the notices it
    /// presented on this channel meanwhile, in order and without their
    /// trailing newlines: the activation notice first, then, for one, a
    /// topic that could not be created. When the attach throws, the notices
    /// are dropped and the error is rethrown.
    static func attachCollectingNotices(
        _ companion: TelegramSessionCompanion
    ) async throws(TelegramCompanionAttachError) -> [String] {
        let channel = companion.channel as? ACPTelegramCompanionChannel
        channel?.beginCollectingNotices()
        do {
            try await companion.attach()
        } catch {
            _ = channel?.takePendingNotices()
            throw error
        }
        return channel?.takePendingNotices() ?? []
    }

    /// Refused: the session runs only the editor's prompts. The mirror-only
    /// companion refuses them before asking, so this is never reached in
    /// practice.
    func enqueueTelegramPrompt(
        _ text: String,
        lease: TerminalTelegramRouteLease,
        mode: ChatQueuedPromptMode
    ) async -> TelegramPromptAdmission {
        .refused
    }

    /// The route of the turn in progress was revoked, rebound, or closed:
    /// the companion forgets it and Telegram is unlinked (as `/telegram off`
    /// would), while the editor's turn goes on, unmirrored. An invalidation
    /// for a route that is no longer the turn's is ignored, as the protocol
    /// asks.
    func telegramRouteWasInvalidated(_ lease: TerminalTelegramRouteLease) async {
        guard let companion, companion.activeTurnOrigin?.lease == lease else { return }
        await companion.routeWasInvalidated(lease)
        await companion.detach()
    }

    /// Whether the session's `activePromptID` is set, as the bridge published
    /// it (see ``ACPSessionPromptActivity``).
    func isSessionGenerating() -> Bool {
        promptActivity.isGenerating(sessionID: sessionID, epoch: epoch)
    }

    /// The reply to a `/telegram on` that attached `companion`: the notice
    /// the companion presents on attaching, without its trailing newline.
    /// The notices presented after it while attaching follow it in the reply.
    static func activationText(of companion: TelegramSessionCompanion) -> String {
        let chatTitle = companion.linkedChatTitle?.nilIfBlank
            ?? companion.linkedChatID.map { "chat \($0)" }
            ?? "chat"
        return "Telegram remote control is active.\nLinked chat: \(chatTitle)"
    }

    /// The Telegram companion of the incarnation `epoch` of `sessionID`, with
    /// its channel. The companion registers its presenter in `controller` as
    /// it is created.
    static func makeCompanion(
        controller: ChatSessionController,
        sessionRunner: AgentCoreSessionRunner,
        router: TerminalTelegramSessionRouter,
        controlService: TerminalTelegramControlService,
        sessionID: String,
        epoch: UInt64,
        promptActivity: ACPSessionPromptActivity
    ) -> (companion: TelegramSessionCompanion, channel: ACPTelegramCompanionChannel) {
        let channel = ACPTelegramCompanionChannel(
            sessionID: sessionID,
            epoch: epoch,
            promptActivity: promptActivity
        )
        let companion = TelegramSessionCompanion(
            controller: controller,
            sessionRunner: sessionRunner,
            router: router,
            controlService: controlService,
            channel: channel,
            configuration: configuration
        )
        channel.companion = companion
        return (companion, channel)
    }
}

// MARK: - Bridge

extension ZenCODEACPBridge {
    /// Publishes which incarnations are generating a prompt to the Telegram
    /// channels (see ``ACPSessionPromptActivity``).
    func publishTelegramPromptActivity() {
        telegramPromptActivity.publish(
            sessions.compactMapValues { $0.activePromptID == nil ? nil : $0.epoch }
        )
    }

    /// The router every companion of this bridge resolves its routes with,
    /// created on first use from the settings as they are then.
    func sharedTelegramRouter() -> TerminalTelegramSessionRouter {
        if let router = telegramRouterStorage {
            return router
        }
        let router = TelegramCompanionRuntimeFactory.makeRouter()
        telegramRouterStorage = router
        return router
    }

    /// The poller every companion's control service subscribes through,
    /// created with the router (see `telegramDispatcherStorage`).
    func sharedTelegramDispatcher() -> TerminalTelegramBotDispatcher {
        if let dispatcher = telegramDispatcherStorage {
            return dispatcher
        }
        let dispatcher = TerminalTelegramBotDispatcher()
        telegramDispatcherStorage = dispatcher
        return dispatcher
    }

    /// The Telegram companion of the incarnation that holds the prompt
    /// reservation `promptID`, created and stored in its session state on
    /// first use, with a control service of its own on the shared router and
    /// dispatcher.
    ///
    /// The companion is stored before anything attaches it, so a
    /// `session/close` or a `shutdown()` that lands while it attaches finds
    /// it and ends it. When the reservation is gone once the companion is
    /// made, it is shut down again (its presenter leaves the controller) and
    /// the prompt ends cancelled.
    func reservedPromptTelegramCompanion(
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async throws -> TelegramSessionCompanion {
        guard let session = reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            throw CancellationError()
        }
        if let companion = session.telegramCompanion {
            return companion
        }
        let transportFactory = telegramTransportFactoryForTesting ?? { NIOTelegramHTTPTransport() }
        let controlService = TerminalTelegramControlService(
            transportFactory: transportFactory,
            dispatcher: sharedTelegramDispatcher()
        )
        let made = await ACPTelegramCompanionChannel.makeCompanion(
            controller: session.controller,
            sessionRunner: sessionRunner,
            router: sharedTelegramRouter(),
            controlService: controlService,
            sessionID: sessionID,
            epoch: epoch,
            promptActivity: telegramPromptActivity
        )
        guard updateReservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID, { live in
            live.telegramCompanion = made.companion
            live.telegramCompanionChannel = made.channel
        }) else {
            await made.companion.shutdown()
            throw CancellationError()
        }
        return made.companion
    }
}
