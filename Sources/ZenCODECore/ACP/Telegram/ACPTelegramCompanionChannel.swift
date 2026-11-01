//
//  ACPTelegramCompanionChannel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

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
///
/// ``TelegramCompanionChannel/isSessionGenerating()`` is synchronous on
/// ``ChatSessionActor``, the isolation of the ``ChatSessionHost`` that owns
/// the prompt reservation of the incarnation, so the channel asks the host
/// directly for its own incarnation; a newer incarnation with the same id
/// does not count.
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
    private let host: ChatSessionHost
    private let slotID: ChatSlotID
    weak var companion: TelegramSessionCompanion?
    /// The notices the companion presented since
    /// ``beginCollectingNotices()``, without their trailing newlines.
    private var pendingNotices: [String] = []
    /// Whether a `/telegram on` reply is being composed, so the companion's
    /// notices are kept for it instead of being dropped.
    private var collectsNotices = false

    init(sessionID: String, epoch: UInt64, host: ChatSessionHost, slotID: ChatSlotID) {
        self.sessionID = sessionID
        self.epoch = epoch
        self.host = host
        self.slotID = slotID
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

    /// Whether a prompt is reserved on the incarnation, as the host holds it.
    func isSessionGenerating() -> Bool {
        host.activePromptID(in: slotID, epoch: epoch) != nil
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

    /// The Telegram companion of the incarnation `epoch` of `sessionID`, run
    /// by `host` in `slotID`, with its channel. The companion registers its
    /// presenter in `controller` as it is created.
    static func makeCompanion(
        controller: ChatSessionController,
        sessionRunner: AgentCoreSessionRunner,
        router: TerminalTelegramSessionRouter,
        controlService: TerminalTelegramControlService,
        sessionID: String,
        epoch: UInt64,
        host: ChatSessionHost,
        slotID: ChatSlotID
    ) -> (companion: TelegramSessionCompanion, channel: ACPTelegramCompanionChannel) {
        let channel = ACPTelegramCompanionChannel(
            sessionID: sessionID,
            epoch: epoch,
            host: host,
            slotID: slotID
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
    /// The Telegram companion of the incarnation that holds the prompt
    /// reservation `promptID`, created and stored in its session state on
    /// first use, with a control service of its own on the router and
    /// dispatcher the host shares among every session (see
    /// `ChatSessionHost+Telegram.swift`).
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
        guard let session = await reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            throw CancellationError()
        }
        if let companion = session.telegramCompanion {
            return companion
        }
        let transportFactory = telegramTransportFactoryForTesting ?? { NIOTelegramHTTPTransport() }
        let dispatcher = await host.telegramDispatcher()
        let router = await host.telegramRouter()
        let controlService = TerminalTelegramControlService(
            transportFactory: transportFactory,
            dispatcher: dispatcher
        )
        let made = await ACPTelegramCompanionChannel.makeCompanion(
            controller: session.controller,
            sessionRunner: sessionRunner,
            router: router,
            controlService: controlService,
            sessionID: sessionID,
            epoch: epoch,
            host: host,
            slotID: session.slotID
        )
        guard await updateReservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID, { live in
            live.telegramCompanion = made.companion
            live.telegramCompanionChannel = made.channel
        }) else {
            await made.companion.shutdown()
            throw CancellationError()
        }
        return made.companion
    }
}
