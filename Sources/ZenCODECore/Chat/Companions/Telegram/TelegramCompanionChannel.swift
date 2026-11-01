//
//  TelegramCompanionChannel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// What the primary channel did with a prompt that arrived from Telegram
/// (see ``TelegramCompanionChannel/enqueueTelegramPrompt(_:lease:mode:)``).
public enum TelegramPromptAdmission: Sendable, Equatable {
    /// The prompt is in the channel's queue and runs as a turn of origin
    /// ``TelegramTurnOrigin/telegram(_:)`` when the session is free.
    case queued
    /// The channel's prompt queue is full; the prompt was dropped.
    case queueFull
    /// The channel does not run prompts from Telegram; the prompt was dropped.
    case refused
}

/// The primary channel a ``TelegramSessionCompanion`` runs next to: the
/// terminal, the macOS app, or an ACP session.
///
/// Telegram never runs alone. The companion mirrors the session to the
/// linked chat and sends what Telegram asks back to this channel, which owns
/// the session's prompt queue, its turns, and its presentation. The companion
/// holds the channel weakly: the channel owns the companion, never the
/// reverse, and a companion whose channel is gone drops what it would have
/// presented.
///
/// Isolated to ``ChatSessionActor``, like the controller and the companion,
/// so the companion calls it without hopping.
@ChatSessionActor
public protocol TelegramCompanionChannel: AnyObject {
    /// The name of the primary channel in the texts sent to Telegram ("TUI"
    /// for the terminal), the same one the channel passes in the companion's
    /// ``TelegramSessionCompanion/Configuration``.
    var primaryChannelDescription: String { get }

    /// The facts that decide which slash commands the operator sees in this
    /// session (see ``ChatCommandContext``).
    func commandContext() -> ChatCommandContext

    /// Presents a notice of the companion on the primary channel. `text` is
    /// complete, trailing newline included, exactly as the terminal writes it
    /// with `writeSystemMessage` or `writeFailureMessage`; `channel` is its
    /// tone.
    func presentCompanionNotice(_ text: String, channel: ChatSessionNoticeChannel) async

    /// Queues a prompt that arrived from Telegram on the route `lease`. `mode`
    /// says whether the text is a submitted line, classified again when it
    /// leaves the queue, or a prompt that runs as it is (a transcribed voice
    /// message).
    ///
    /// The answer is what happened to the prompt by the time the call
    /// returns. For a transcribed voice message the companion reports a
    /// ``TelegramPromptAdmission/queueFull`` (on this channel and in the
    /// chat) and a ``TelegramPromptAdmission/refused`` (in the chat). A
    /// channel that only hands the prompt on to a loop of its own, which
    /// reports a full queue itself when it handles the prompt, answers
    /// ``TelegramPromptAdmission/queued`` once the prompt is handed on, so
    /// the operator is not told twice: only a channel that knows
    /// synchronously that its queue is full answers
    /// ``TelegramPromptAdmission/queueFull``.
    func enqueueTelegramPrompt(
        _ text: String,
        lease: TerminalTelegramRouteLease,
        mode: ChatQueuedPromptMode
    ) async -> TelegramPromptAdmission

    /// The route `lease` was revoked, rebound, or closed while the turn that
    /// came from it was generating. When the turn in progress is still the
    /// one on `lease` (``TelegramSessionCompanion/activeTurnOrigin``), the
    /// channel stops it and then calls
    /// ``TelegramSessionCompanion/routeWasInvalidated(_:)``; otherwise it
    /// ignores the call. The companion calls it from the task that validates
    /// the route, which nothing awaits any more once the call starts, so the
    /// channel may end the turn's reporting from within it.
    func telegramRouteWasInvalidated(_ lease: TerminalTelegramRouteLease) async

    /// Returns once every overview publication the primary channel already
    /// queued for mirroring was handed to the companion, so a message the
    /// companion sends next cannot overtake the sections the turn already
    /// rendered. At a tool boundary the companion calls it before the
    /// channel presents the boundary (the fan-out calls companions first), so
    /// a channel whose presentation of the boundary renders sections renders
    /// them here first, as the terminal does. The default returns at once,
    /// for a channel that does not mirror overviews.
    func overviewMirrorBarrier() async

    /// The shared chat changed because of Telegram (a message was relayed to
    /// a participant), so a channel that suggests shared-chat recipients
    /// refreshes them. The default does nothing.
    func sharedChatPanelDidChange() async

    /// Whether the session is generating a turn right now. The default is
    /// `false`, for a channel that never reports one.
    func isSessionGenerating() -> Bool
}

extension TelegramCompanionChannel {
    public func overviewMirrorBarrier() async {}

    public func sharedChatPanelDidChange() async {}

    public func isSessionGenerating() -> Bool { false }
}
