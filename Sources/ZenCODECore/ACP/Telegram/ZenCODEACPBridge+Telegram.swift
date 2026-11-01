//
//  ZenCODEACPBridge+Telegram.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/11/26.
//

import Foundation
import Synchronization
import ToolCore

/// The channel hooks of every slot an ACP bridge opens: the composition and
/// the environment of the turns the slot's Telegram channel runs
/// (``ChatSessionChannelHooks/turnSessionConfiguration(for:controller:)``,
/// ``ChatSessionChannelHooks/runTurnFromAnotherChannel(controller:_:)``),
/// which are those of the editor's own prompts, so a prompt from the linked
/// chat runs with the session's configuration (its system prompt, the history
/// the client gave it, its grant) plus the tools of the turn's purpose, with
/// the agent's skills selected and with the text file system the client
/// serves, as a prompt typed in the editor does: a file the turn writes goes
/// to the editor's buffer, not past it to the disk.
///
/// One object serves every slot of the bridge: it finds the session by the
/// controller it is asked for, which is the live incarnation's. The bridge
/// owns it and binds itself once it exists (``bind(to:)``); it holds the
/// bridge weakly. A controller the bridge no longer runs (closed meanwhile)
/// gets the controller's own composition, as a slot without hooks would.
///
/// ACP's editor turns never move to Telegram: `/telegram on` is itself a
/// `session/prompt`, which holds the slot's reservation, and the editor's
/// prompts present through a presenter bound to the prompt, not through the
/// slot's presenter, so no turn of the editor is ever open when the slot
/// changes hands. The other hooks keep their no-op defaults.
@ChatSessionActor
final class ACPSessionChannelHooks: ChatSessionChannelHooks {
    private struct WeakBridge: Sendable {
        weak var bridge: ZenCODEACPBridge?
    }

    /// Set once by the bridge, after it exists; read on the chat actor.
    private let bridgeBox = Mutex(WeakBridge())

    nonisolated init() {}

    /// Binds the hooks to `bridge`, the bridge that owns them.
    nonisolated func bind(to bridge: ZenCODEACPBridge) {
        bridgeBox.withLock { $0.bridge = bridge }
    }

    private nonisolated var bridge: ZenCODEACPBridge? {
        bridgeBox.withLock { $0.bridge }
    }

    func turnSessionConfiguration(
        for purpose: ChatTurnPurpose,
        controller: ChatSessionController
    ) async -> AgentCoreSessionConfiguration {
        if let bridge, let configuration = await bridge.sessionConfiguration(of: controller) {
            return configuration.addingAllowedToolNames(controller.additionalToolNames(for: purpose))
        }
        return await controller.turnSessionConfiguration(for: purpose, responseLanguageSection: nil)
    }

    func runTurnFromAnotherChannel(
        controller: ChatSessionController,
        _ body: () async throws -> ChatTurnResult
    ) async throws -> ChatTurnResult {
        // A controller the bridge no longer runs has no environment: the turn
        // runs as a slot without hooks would run it.
        guard let bridge, let environment = await bridge.turnEnvironment(of: controller) else {
            return try await body()
        }
        // The editor's order: inside the client's file system, the agent's
        // skills are selected, then the turn starts.
        return try await ClientTextFileSystem.$current.withValue(environment.clientFiles) {
            await bridge.applySelectedAgentSkills(
                sessionID: environment.sessionID,
                selectedAgent: environment.selectedAgent
            )
            return try await body()
        }
    }
}

/// What a turn from Telegram needs around it on an ACP session beyond its
/// configuration, as ``ZenCODEACPBridge/turnEnvironment(of:)`` prepares it.
struct ACPTelegramTurnEnvironment: Sendable {
    let sessionID: String
    /// The agent whose skills the turn selects, as the editor's prompt does
    /// (``ZenCODEACPBridge/applySelectedAgentSkills(sessionID:selectedAgent:)``).
    let selectedAgent: AgentProfile?
    /// The text file system the client serves to the session, if it
    /// advertised one.
    let clientFiles: ClientTextFileSystem?
}

extension ZenCODEACPBridge {
    /// The live session whose incarnation runs `controller`; `nil` when no
    /// live session runs it.
    func liveSession(of controller: ChatSessionController) -> SessionState? {
        sessions.values.first { $0.controller === controller }
    }

    /// The configuration of the live session whose incarnation runs
    /// `controller`, as the editor's prompts compose from it; `nil` when no
    /// live session runs it.
    func sessionConfiguration(of controller: ChatSessionController) -> AgentCoreSessionConfiguration? {
        liveSession(of: controller)?.configuration
    }

    /// What the editor's prompt gives its turn, for a turn from Telegram on
    /// the live session whose incarnation runs `controller`: the session's
    /// agent, whose skills the turn selects, and the client's file system made
    /// for the incarnation, usable while it lives (the editor's prompts get
    /// both through the same helpers,
    /// ``applySelectedAgentSkills(sessionID:selectedAgent:)`` and
    /// ``clientTextFileSystem(sessionID:epoch:)``). `nil` when no live session
    /// runs `controller`.
    func turnEnvironment(of controller: ChatSessionController) -> ACPTelegramTurnEnvironment? {
        guard let session = liveSession(of: controller) else { return nil }
        return ACPTelegramTurnEnvironment(
            sessionID: session.id,
            selectedAgent: session.selectedAgent,
            clientFiles: clientTextFileSystem(sessionID: session.id, epoch: session.epoch)
        )
    }

    /// The reason a `session/prompt` is refused while the slot's session is
    /// busy: the editor's own prompt, or a turn from Telegram while Telegram
    /// drives the slot, which the editor cannot take over in the middle (see
    /// `routeACPTelegramCommand`): it stops it with `session/cancel`, or
    /// waits for it to end, and `/telegram off` then catches up.
    func promptBusyMessage(slotID: ChatSlotID) async -> String {
        if await host.reservedPromptIsTelegramTurn(in: slotID) {
            return Self.telegramTurnBusyMessage
        }
        return "A prompt is already running for this session."
    }

    static let telegramTurnBusyMessage =
        "A turn from Telegram is running for this session. Send session/cancel to stop it, or wait for it to end, then send /telegram off."
}

// MARK: - Notices in the `/telegram on` reply

extension ChatSessionHost {
    /// ``activateTelegram(in:primaryChannelDescription:)`` for a channel that
    /// has no place for a text outside a prompt's reply: the notices the slot's
    /// Telegram channel presents while it attaches (the activation text, then,
    /// for one, a topic that could not be created) are collected instead of
    /// dropped and returned, in order and without their trailing newlines,
    /// for the reply. The channel's notice sink is restored afterwards, so
    /// every later notice is dropped again, as it was. When the activation
    /// throws, the notices are dropped and the error is rethrown.
    func activateTelegramCollectingNotices(
        in slotID: ChatSlotID,
        primaryChannelDescription: String
    ) async throws -> [String] {
        guard let channel = telegramChannelCreatingIfNeeded(
            in: slotID, primaryChannelDescription: primaryChannelDescription
        ) else {
            throw ChatSessionHostError.unknownSlot
        }
        let collector = ACPTelegramNoticeCollector()
        let previousSink = channel.noticeSink
        channel.noticeSink = { text, _ in collector.append(text) }
        defer { channel.noticeSink = previousSink }
        try await activateTelegram(in: slotID, primaryChannelDescription: primaryChannelDescription)
        return collector.take()
    }
}

/// The notices a Telegram channel presented while ACP answered `/telegram
/// on`, without their trailing newlines.
@ChatSessionActor
private final class ACPTelegramNoticeCollector {
    private var notices: [String] = []

    init() {}

    func append(_ text: String) {
        var notice = Substring(text)
        while notice.last?.isNewline == true {
            notice.removeLast()
        }
        notices.append(String(notice))
    }

    func take() -> [String] {
        defer { notices.removeAll() }
        return notices
    }
}
