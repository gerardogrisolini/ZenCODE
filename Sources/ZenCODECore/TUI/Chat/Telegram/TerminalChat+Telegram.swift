//
//  TerminalChat+Telegram.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

// MARK: - Origins

extension TerminalPromptOrigin {
    /// The origin the Telegram companion follows a turn of this origin with
    /// (see ``TelegramTurnOrigin``): the terminal is the primary channel and
    /// a validated lease is its Telegram route. An origin that carries no
    /// validated lease (`.telegram(chatID:)`, `.telegramRoute`) has none: the
    /// companion follows such a turn without an origin, which reaches no
    /// chat.
    var telegramTurnOrigin: TelegramTurnOrigin? {
        switch self {
        case .local: .primary
        case let .telegramLease(lease): .telegram(lease)
        case .telegram, .telegramRoute: nil
        }
    }

    /// The companion's origin for a lookup or a send that does not route the
    /// turn onto the link: the lease of a Telegram origin, and the primary
    /// channel for any other origin. The companion's egress reaches a chat
    /// only through a lease, so an origin without one reaches none, as the
    /// terminal's own egress did.
    var telegramEgressOrigin: TelegramTurnOrigin {
        telegramLease.map(TelegramTurnOrigin.telegram) ?? .primary
    }

    /// The terminal's origin of a turn the Telegram companion follows.
    init(_ origin: TelegramTurnOrigin) {
        switch origin {
        case .primary:
            self = .local
        case let .telegram(lease):
            self = .telegramLease(lease)
        }
    }
}

// MARK: - `/telegram`

extension TerminalChat {
    func handleTelegramCommand(_ command: String) async {
        let argument = Self.slashCommandArguments(
            from: command,
            commandPrefix: "/telegram"
        ).lowercased()

        switch TerminalTelegramCommandAction(argument: argument) {
        case .status:
            await printTelegramStatus()
        case .turnOn:
            await startTelegramControl()
        case .turnOff:
            await stopTelegramControl()
        case .usage:
            await writeSystemMessage("Usage: /telegram [on|off]\n")
        }
    }

    /// `/telegram on`: links the session through the companion, which tells
    /// the terminal the link is active (see ``presentCompanionNotice(_:channel:)``).
    func startTelegramControl() async {
        guard stdinIsTerminal else {
            await writeFailureMessage("ZenCODE: /telegram requires the interactive TUI.\n")
            return
        }
        guard isTelegramConfigured() else {
            await writeFailureMessage(Self.unknownCommandMessage(for: "/telegram"))
            return
        }
        do {
            try await telegramCompanion.attach()
        } catch {
            await writeFailureMessage(error.failureText)
        }
    }

    /// `/telegram off`: unlinks the session; the companion tells the terminal
    /// the link stopped.
    func stopTelegramControl() async {
        await telegramCompanion.detach()
    }

    func printTelegramStatus() async {
        await writeSystemMessage(await telegramCompanion.statusText() + "\n")
    }

    /// Echoes a prompt from the linked chat before it runs.
    func writeTelegramSubmittedPrompt(_ prompt: String) async {
        let title = telegramLinkedChatTitle?.nilIfBlank ?? "Telegram"
        await writeSystemMessage("\n\(title) sent a prompt:\n")
        await writeSubmittedPrompt(prompt)
    }

    /// Retires the turn's Telegram side with `outcome`, the turn's end as the
    /// terminal presented it, or without one when the panel loop tears down
    /// while a turn runs. The overview barrier only drains meanwhile (see
    /// ``overviewMirrorBarrier()``).
    func finishTelegramTurn(
        outcome: TelegramSessionCompanion.Outcome?,
        fileChangeSummary: TurnFileChangeSummary?
    ) async {
        isRetiringTelegramTurn = true
        defer { isRetiringTelegramTurn = false }
        await telegramCompanion.finishTurn(outcome: outcome, fileChangeSummary: fileChangeSummary)
    }

    /// Moves the session's Telegram topic to the session the terminal's slot
    /// switched to (`/sessions new`, `/sessions load`), named after the saved
    /// session or, for a session never saved, as the companion names a new
    /// topic. The companion already follows the new controller. Nothing
    /// happens outside topic mode.
    func rebindTelegramTopicToCurrentSession() async {
        let displayName = activeSavedSessionName?.nilIfBlank
            ?? TelegramSessionCompanion.defaultTopicName(
                workingDirectory: chatSession.workingDirectory,
                sessionID: sessionID
            )
        await telegramCompanion.rebind(sessionID: sessionID, displayName: displayName)
    }
}

// MARK: - Companion channel

/// The terminal is the primary channel of its Telegram companion.
extension TerminalChat: TelegramCompanionChannel {
    public var primaryChannelDescription: String {
        "TUI"
    }

    public func commandContext() -> ChatCommandContext {
        currentCommandContext()
    }

    public func presentCompanionNotice(_ text: String, channel: ChatSessionNoticeChannel) async {
        switch channel {
        case .system:
            await writeSystemMessage(text)
        case .failure:
            await writeFailureMessage(text)
        case .markdown:
            await writeMarkdownMessage(text)
        }
    }

    /// The companion queues here the transcript of a voice note
    /// (`.directPrompt`); lines from Telegram reach the panel loop's queue
    /// through the `admit` of ``TelegramSessionCompanion/handleIncomingMessage(_:isSessionGenerating:admit:)``.
    /// The transcript is handed to the panel loop as a completed voice
    /// prompt, which runs it when the session is free and itself reports a
    /// full queue, so the answer is always ``TelegramPromptAdmission/queued``.
    /// Without a loop to hand it to, the transcript is dropped silently, as a
    /// completion delivered after the loop ended always was.
    public func enqueueTelegramPrompt(
        _ text: String,
        lease: TerminalTelegramRouteLease,
        mode: ChatQueuedPromptMode
    ) async -> TelegramPromptAdmission {
        _ = await telegramRuntimeEventQueue?.sendWithBackpressure(
            .voicePromptCompleted(
                TerminalVoicePromptResult(origin: .telegramLease(lease), outcome: .success(text))
            )
        )
        return .queued
    }

    /// Hands the invalidation to the panel loop, which stops the turn that
    /// came from `lease` when it is still the one in progress and then calls
    /// ``TelegramSessionCompanion/routeWasInvalidated(_:)``. Without a loop
    /// nothing happens.
    public func telegramRouteWasInvalidated(_ lease: TerminalTelegramRouteLease) async {
        _ = await telegramRuntimeEventQueue?.sendWithBackpressure(.telegramRouteInvalidated(lease))
    }

    /// Returns once every overview section the render coordinator queued for
    /// mirroring was handed to the companion.
    ///
    /// The fan-out calls the companion's presenter before this terminal's, so
    /// at a tool boundary the companion publishes the root response before
    /// the terminal writes the comment that precedes the call. Writing that
    /// comment begins by closing a tool block that is still pending
    /// (`interruptActiveToolForInterleavedOutputIfNeeded`), which writes the
    /// messages held next to that tool and renders the overviews deferred
    /// behind it: those sections reached the linked chat before the response
    /// when the terminal published it after its own writes. So while a comment
    /// waits for its tool boundary, the barrier takes that first step of the
    /// comment ahead of time, and the comment's own step finds nothing left
    /// to close: the terminal writes the same, and the chat receives those
    /// sections ahead of the response, as before. While the terminal retires
    /// the turn (``finishTelegramTurn(outcome:fileChangeSummary:)``) no comment
    /// follows, and the barrier only drains.
    ///
    /// Sections queued by producers that run on their own (the sub-agent
    /// overview refresh, the task-graph observer) while the boundary is
    /// presented land before or after the response depending on timing, as
    /// they always did.
    public func overviewMirrorBarrier() async {
        if !isRetiringTelegramTurn,
           let output = activeAssistantOutput,
           await output.hasPendingContent {
            await renderCoordinator.interruptActiveToolForInterleavedOutputIfNeeded()
        }
        await renderCoordinator.waitForOverviewMirrorsToDrain()
    }

    public func sharedChatPanelDidChange() async {
        await refreshSharedChatPanelSuggestions()
    }
}

// MARK: - Forwarders

/// The terminal's former Telegram members, kept with their signatures and
/// answered by the companion. An origin is mapped with
/// ``TerminalPromptOrigin/telegramTurnOrigin`` where the companion routes the
/// turn, and with ``TerminalPromptOrigin/telegramEgressOrigin`` where it only
/// looks a route up or sends through it.
extension TerminalChat {
    typealias TelegramWorkEffectForTesting = TelegramSessionCompanion.TelegramWorkEffectForTesting

    // MARK: State

    public var telegramControlService: TerminalTelegramControlService {
        telegramCompanion.controlService
    }

    var telegramSessionRouter: TerminalTelegramSessionRouter {
        telegramCompanion.router
    }

    var telegramRouteRuntimeState: TerminalTelegramRouteRuntimeState {
        telegramCompanion.routeRuntimeState
    }

    var telegramPermissionBroker: TerminalTelegramPermissionBroker {
        telegramCompanion.permissionBroker
    }

    public var telegramControlState: TerminalTelegramControlState {
        get { telegramCompanion.controlState }
        set { telegramCompanion.controlState = newValue }
    }

    public var telegramLinkedChatID: Int64? {
        get { telegramCompanion.linkedChatID }
        set { telegramCompanion.linkedChatID = newValue }
    }

    public var telegramLinkedChatTitle: String? {
        get { telegramCompanion.linkedChatTitle }
        set { telegramCompanion.linkedChatTitle = newValue }
    }

    /// Telegram user id of the last linked-chat sender, used to bind outbound
    /// artifact consent offers to the operator who will confirm them.
    public var telegramLinkedUserID: Int64? {
        get { telegramCompanion.linkedUserID }
        set { telegramCompanion.linkedUserID = newValue }
    }

    var telegramActiveRouteLease: TerminalTelegramRouteLease? {
        get { telegramCompanion.activeRouteLease }
        set { telegramCompanion.activeRouteLease = newValue }
    }

    var activeTelegramTurnOrigin: TerminalPromptOrigin? {
        get { telegramCompanion.activeTurnOrigin.map(TerminalPromptOrigin.init) }
        set { telegramCompanion.activeTurnOrigin = newValue?.telegramTurnOrigin }
    }

    var activeTelegramProgressReporter: TerminalTelegramTurnProgressReporter? {
        get { telegramCompanion.activeProgressReporter }
        set { telegramCompanion.activeProgressReporter = newValue }
    }

    var activeTelegramPresenceLease: TerminalTelegramPresenceLeaseManager.Lease? {
        get { telegramCompanion.activePresenceLease }
        set { telegramCompanion.activePresenceLease = newValue }
    }

    var telegramRouteValidationTask: Task<Void, Never>? {
        get { telegramCompanion.routeValidationTask }
        set { telegramCompanion.routeValidationTask = newValue }
    }

    var onTelegramWorkEffectForTesting: (@Sendable (TelegramWorkEffectForTesting) -> Bool)? {
        get { telegramCompanion.onTelegramWorkEffectForTesting }
        set { telegramCompanion.onTelegramWorkEffectForTesting = newValue }
    }

    var onDirectTelegramTurnMessage: (@Sendable (TerminalTelegramTurnPayload, Int64) async -> Bool)? {
        get { telegramCompanion.onDirectTelegramTurnMessage }
        set { telegramCompanion.onDirectTelegramTurnMessage = newValue }
    }

    var telegramCommandReplyBindings: [TerminalTelegramCommandReplyKey: TerminalTelegramCommandReplyBinding] {
        get { telegramCompanion.commandReplyBindings }
        set { telegramCompanion.commandReplyBindings = newValue }
    }

    var onTelegramSystemMessage: (@Sendable (String, Int64) async -> Bool)? {
        get { telegramCompanion.onTelegramSystemMessage }
        set { telegramCompanion.onTelegramSystemMessage = newValue }
    }

    var onTelegramRoutedSystemMessage: (@Sendable (String, Int64, Int?) async -> Bool)? {
        get { telegramCompanion.onTelegramRoutedSystemMessage }
        set { telegramCompanion.onTelegramRoutedSystemMessage = newValue }
    }

    var onTelegramMentionPickerMessage: (@Sendable (String, Int64, TerminalTelegramReplyMarkup) async -> Int?)? {
        get { telegramCompanion.onTelegramMentionPickerMessage }
        set { telegramCompanion.onTelegramMentionPickerMessage = newValue }
    }

    var telegramRootResponseBlockHasContent: Bool {
        get { telegramCompanion.rootResponseBlockHasContent }
        set { telegramCompanion.rootResponseBlockHasContent = newValue }
    }

    var telegramRootResponseBlockIsSuppressed: Bool {
        get { telegramCompanion.rootResponseBlockIsSuppressed }
        set { telegramCompanion.rootResponseBlockIsSuppressed = newValue }
    }

    var telegramDidPublishIntermediateRootResponse: Bool {
        get { telegramCompanion.didPublishIntermediateRootResponse }
        set { telegramCompanion.didPublishIntermediateRootResponse = newValue }
    }

    var mirroredTaskGraphOverviewSignature: String? {
        get { telegramCompanion.mirroredTaskGraphOverviewSignature }
        set { telegramCompanion.mirroredTaskGraphOverviewSignature = newValue }
    }

    var currentTelegramMirrorEpoch: Int {
        get { telegramCompanion.currentMirrorEpoch }
        set { telegramCompanion.currentMirrorEpoch = newValue }
    }

    /// `true` only while the interactive panel loop, the single surface that
    /// consumes Telegram ingress, is running (see
    /// ``TelegramSessionCompanion/readsIngress``).
    var readsTelegramIngress: Bool {
        get { telegramCompanion.readsIngress }
        set { telegramCompanion.readsIngress = newValue }
    }

    var telegramSharedChatRelayStorage: TerminalTelegramSharedChatRelay? {
        get { telegramCompanion.sharedChatRelayStorage }
        set { telegramCompanion.sharedChatRelayStorage = newValue }
    }

    var telegramVoiceTranscriptions: TerminalVoiceTranscriptionRegistry {
        telegramCompanion.voiceTranscriptions
    }

    var telegramSharedChatRelay: TerminalTelegramSharedChatRelay {
        telegramCompanion.sharedChatRelay
    }

    // MARK: Egress and consent

    func telegramToolAuthorizationHandler(
        for origin: TerminalPromptOrigin
    ) -> AgentToolAuthorizationHandler? {
        // Not routed: a local origin owns no handler here, as before; a turn
        // is routed when it starts (`promptAttempt`, `beginTurn`).
        guard let lease = origin.telegramLease else { return nil }
        return telegramCompanion.toolAuthorizationHandler(for: .telegram(lease))
    }

    func authorizeTelegramToolRequest(
        _ request: AgentToolAuthorizationRequest,
        origin: TerminalPromptOrigin
    ) async -> Bool {
        await telegramCompanion.authorizeToolRequest(request, origin: origin.telegramEgressOrigin)
    }

    func handleTelegramPermissionResponseIfNeeded(
        _ text: String,
        lease: TerminalTelegramRouteLease
    ) async -> Bool {
        await telegramCompanion.handlePermissionResponseIfNeeded(text, lease: lease)
    }

    func sendTelegramSystemMessageIfLinked(
        _ message: String,
        origin: TerminalPromptOrigin
    ) async {
        await telegramCompanion.sendSystemMessageIfLinked(message, origin: origin.telegramEgressOrigin)
    }

    @discardableResult
    func sendTelegramTurnMessage(
        _ payload: TerminalTelegramTurnPayload,
        to chatID: Int64,
        origin: TerminalPromptOrigin
    ) async -> Bool {
        await telegramCompanion.sendTurnMessage(payload, to: chatID, origin: origin.telegramEgressOrigin)
    }

    func sendTelegramTurnMessageIfLinked(
        _ payload: TerminalTelegramTurnPayload,
        origin: TerminalPromptOrigin
    ) async {
        await telegramCompanion.sendTurnMessageIfLinked(payload, origin: origin.telegramEgressOrigin)
    }

    func telegramOutgoingChatID(for origin: TerminalPromptOrigin) -> Int64? {
        telegramCompanion.outgoingChatID(for: origin.telegramEgressOrigin)
    }

    func validateTelegramOrigin(_ origin: TerminalPromptOrigin) async -> Bool {
        await telegramCompanion.validateOrigin(origin.telegramEgressOrigin)
    }

    func telegramWireFence(for origin: TerminalPromptOrigin) -> TerminalTelegramWireFence? {
        telegramCompanion.wireFence(for: origin.telegramEgressOrigin)
    }

    @discardableResult
    func sendTelegramSystemMessage(
        _ message: String, to chatID: Int64, origin: TerminalPromptOrigin
    ) async -> Bool {
        await telegramCompanion.sendSystemMessage(message, to: chatID, origin: origin.telegramEgressOrigin)
    }

    @discardableResult
    func sendTelegramSystemMessage(
        _ message: String, to chatID: Int64, topicID: Int? = nil,
        fence: TerminalTelegramWireFence
    ) async -> Bool {
        await telegramCompanion.sendSystemMessage(message, to: chatID, topicID: topicID, fence: fence)
    }

    /// The `/telegram` status of the link as last read.
    func telegramStatusText() -> String {
        TelegramSessionCompanion.statusText(
            controlState: telegramCompanion.controlState,
            linkedChatTitle: telegramCompanion.linkedChatTitle,
            topicName: telegramCompanion.sessionTopic?.name
        )
    }

    func telegramRemoteStatusText() -> String {
        telegramCompanion.remoteStatusText()
    }

    func telegramRemoteChangesText() -> String {
        telegramCompanion.remoteChangesText()
    }

    func telegramRemoteHelpText() -> String {
        telegramCompanion.remoteHelpText()
    }

    nonisolated static func telegramRemoteCommandList() -> String {
        TelegramSessionCompanion.remoteCommandList(policy: .full)
    }

    func makeTelegramTurnProgressReporter(
        for origin: TerminalPromptOrigin
    ) -> TerminalTelegramTurnProgressReporter? {
        telegramCompanion.makeTurnProgressReporter(for: origin.telegramEgressOrigin)
    }

    // MARK: Ingress

    /// A line from Telegram as it leaves the queue, answered by the
    /// companion: a line it answered continues the chat, a prompt runs, and
    /// the outcome of `/plan` `/goal` `/review` or of a pending reply is
    /// presented as a line typed in the terminal would be.
    func submittedTelegramLineAction(
        _ prompt: String,
        origin: TerminalPromptOrigin
    ) async -> TerminalSubmittedLineAction {
        guard let lease = origin.telegramLease else { return .continueChat }
        switch await telegramCompanion.lineAction(for: prompt, lease: lease) {
        case .handled:
            return .continueChat
        case let .runPrompt(prompt):
            return .runPrompt(prompt)
        case let .commandOutcome(outcome):
            return await terminalAction(presenting: outcome)
        }
    }

    nonisolated static func telegramCommandWithoutBotMention(_ text: String) -> String {
        TelegramSessionCompanion.commandWithoutBotMention(text)
    }

    /// Forwards incoming Telegram messages into the runtime queue.
    ///
    /// The task holds only a weak reference to the chat, so it cannot keep it
    /// alive after teardown, and it stops as soon as it is cancelled or the chat
    /// is gone rather than draining messages into a queue nobody consumes.
    func startTelegramForwardingTask(
        eventQueue: TerminalChatEventQueue
    ) -> Task<Void, Never> {
        let service = telegramControlService
        return Task(name: "ZenCODE.Telegram.forwarding") { [weak self] in
            for await message in service.incomingMessages {
                if Task.isCancelled || self == nil {
                    return
                }
                guard await eventQueue.sendWithBackpressure(.telegramMessage(message)) else {
                    // The runtime loop ended or this forwarder was cancelled.
                    return
                }
            }
        }
    }

    /// One Telegram message a runtime loop dequeued, handled by the companion,
    /// which admits a prompt to `queuedPrompts`. Returns `true` when this
    /// message queued a prompt. `transcriptions` is not used: the companion
    /// owns the voice transcriptions, whose transcripts reach
    /// ``telegramRuntimeEventQueue``.
    func handleTelegramRuntimeMessage(
        _ message: TerminalTelegramIncomingMessage,
        eventQueue: TerminalChatEventQueue,
        queuedPrompts: inout ChatPromptQueue<TerminalPromptOrigin>,
        transcriptions: TerminalVoiceTranscriptionRegistry,
        isSessionGenerating: Bool = false
    ) async -> Bool {
        let didQueuePrompt = await telegramCompanion.handleIncomingMessage(
            message,
            isSessionGenerating: isSessionGenerating
        ) { prompt in
            queuedPrompts.enqueue(
                ChatQueuedPrompt<TerminalPromptOrigin>(
                    text: prompt.text,
                    origin: .telegramLease(prompt.origin),
                    mode: prompt.mode
                )
            ) ? .queued : .queueFull
        }
        if didQueuePrompt {
            // The queue whose consumer runs the prompt follows its turn.
            telegramRuntimeEventQueue = eventQueue
        }
        return didQueuePrompt
    }

    /// ``handleTelegramRuntimeMessage(_:eventQueue:queuedPrompts:transcriptions:isSessionGenerating:)``
    /// without its answer.
    func handleTelegramMessage(
        _ message: TerminalTelegramIncomingMessage,
        queuedPrompts: inout ChatPromptQueue<TerminalPromptOrigin>,
        eventQueue: TerminalChatEventQueue,
        transcriptions: TerminalVoiceTranscriptionRegistry,
        isSessionGenerating: Bool = false
    ) async {
        _ = await handleTelegramRuntimeMessage(
            message,
            eventQueue: eventQueue,
            queuedPrompts: &queuedPrompts,
            transcriptions: transcriptions,
            isSessionGenerating: isSessionGenerating
        )
    }

    func telegramEgressRouteLease(
        settings: AgentTelegramSettingsManifest,
        linkedChatID: Int64
    ) async -> TerminalTelegramRouteLease? {
        await telegramCompanion.egressRoute(settings: settings, linkedChatID: linkedChatID)?.lease
    }

    func writeTelegramPollHealthNotice(_ notice: TerminalTelegramPollHealthNotice) async {
        await telegramCompanion.presentPollHealthNotice(notice)
    }

    // MARK: Turn

    func beginTelegramTurnProgressReporting(for origin: TerminalPromptOrigin) async {
        await telegramCompanion.beginTurn(
            origin: origin.telegramTurnOrigin,
            mirrorEpoch: await renderCoordinator.advanceMirrorEpoch()
        )
    }

    func synchronizeTelegramTurnProgressReporting() async {
        await telegramCompanion.synchronizeTurnReporting()
    }

    func endTelegramTurnProgressReporting() async {
        await telegramCompanion.endTurnReporting()
    }

    func appendTelegramRootResponseDelta(_ delta: String) async {
        await telegramCompanion.appendRootResponseDelta(delta)
    }

    func publishTelegramRootResponseAtToolBoundary() async {
        await telegramCompanion.publishRootResponseAtToolBoundary()
    }

    func telegramMirroredFinalResponseText(fallback: String) async -> String {
        await telegramCompanion.mirroredFinalResponseText(fallback: fallback)
    }

    /// Retires the turn's Telegram side, mirroring `outcome` as it is.
    func finalizeTelegramTurnProgressReporting(
        outcome: TerminalTelegramTurnPayload? = nil,
        fileChangeSummary: TurnFileChangeSummary? = nil
    ) async {
        isRetiringTelegramTurn = true
        defer { isRetiringTelegramTurn = false }
        await telegramCompanion.retireTurn(outcomePayload: outcome, fileChangeSummary: fileChangeSummary)
    }

    // MARK: Mention picker

    nonisolated static var telegramMentionPickerCallbackPrefix: String {
        TelegramSessionCompanion.mentionPickerCallbackPrefix
    }

    func handleTelegramMentionPickerRequest(
        chatID: Int64, origin: TerminalPromptOrigin? = nil
    ) async {
        await telegramCompanion.handleMentionPickerRequest(
            chatID: chatID, origin: origin?.telegramEgressOrigin
        )
    }

    /// One button per direct recipient among `suggestions`; only the command
    /// of a suggestion reaches its button.
    nonisolated static func telegramMentionPickerButtons(
        from suggestions: [TerminalCommandSuggestion]
    ) -> [TerminalTelegramInlineKeyboardButton] {
        TelegramSessionCompanion.mentionPickerButtons(
            from: suggestions.compactMap { suggestion in
                let command = suggestion.command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard command.first == "@" else { return nil }
                let handle = String(command.dropFirst())
                return SharedChatMentionParser.Suggestion(handle: handle, target: .agent(name: handle))
            }
        )
    }

    func handleTelegramMentionPickerCallback(
        _ data: String, chatID: Int64, origin: TerminalPromptOrigin? = nil
    ) async {
        await telegramCompanion.handleMentionPickerCallback(
            data, chatID: chatID, origin: origin?.telegramEgressOrigin
        )
    }

    nonisolated static func telegramMentionPickerReplyTarget(
        destination: AgentSharedChat.Destination, roomID: String, chatID: Int64, handle: String
    ) -> TerminalTelegramSharedChatReplyTarget {
        TelegramSessionCompanion.mentionPickerReplyTarget(
            destination: destination, roomID: roomID, chatID: chatID, handle: handle
        )
    }

    // MARK: Artifacts and voice

    /// Directories whose individually selected files may be exported to the
    /// linked chat: the artifact staging directory only.
    nonisolated static var telegramArtifactPolicy: TerminalTelegramArtifactPolicy {
        TerminalTelegramArtifactPolicy(
            allowedDirectories: [Self.telegramArtifactStagingDirectory]
        )
    }

    /// The companion's default staging directory for outbound artifacts,
    /// created 0700 when missing.
    nonisolated static var telegramArtifactStagingDirectory: URL {
        let url = TelegramSessionCompanion.defaultArtifactStagingDirectory
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return url
    }

    func handleTelegramDiffRequest(origin: TerminalPromptOrigin) async {
        await telegramCompanion.handleDiffRequest(origin: origin.telegramEgressOrigin)
    }

    func handleTelegramArtifactConsentCallback(
        _ data: String,
        message: TerminalTelegramIncomingMessage,
        origin: TerminalPromptOrigin
    ) async -> Bool {
        await telegramCompanion.handleArtifactConsentCallback(
            data, message: message, origin: origin.telegramEgressOrigin
        )
    }

    func handleTelegramInboundAttachment(
        _ attachment: TerminalTelegramInboundAttachment,
        message: TerminalTelegramIncomingMessage,
        origin: TerminalPromptOrigin
    ) async {
        await telegramCompanion.handleInboundAttachment(
            attachment, message: message, origin: origin.telegramEgressOrigin
        )
    }

    /// A voice note received on `origin`'s route, transcribed by the
    /// companion; `eventQueue` and `transcriptions` are not used (see
    /// ``enqueueTelegramPrompt(_:lease:mode:)``).
    func handleTelegramVoiceMessage(
        _ voice: TerminalTelegramVoiceAttachment,
        origin: TerminalPromptOrigin,
        eventQueue: TerminalChatEventQueue,
        transcriptions: TerminalVoiceTranscriptionRegistry
    ) async {
        await telegramCompanion.handleVoiceMessage(voice, origin: origin.telegramEgressOrigin)
    }

    // MARK: Shared chat

    func telegramReplyRoutingHasPrecedence(over text: String) async -> Bool {
        await telegramCompanion.replyRoutingHasPrecedence(over: text)
    }

    func forwardSharedChatMessagesToTelegram(
        _ messages: [AgentSharedChat.Message],
        roomID: String
    ) async {
        await telegramCompanion.forwardSharedChatMessages(messages, roomID: roomID)
    }

    func rebindTelegramSharedChatRelay(roomID: String) async {
        await telegramCompanion.rebindSharedChatRelay(roomID: roomID)
    }

    func telegramDirectReplyTarget(
        for message: TerminalTelegramIncomingMessage
    ) async -> TerminalTelegramSharedChatReplyTarget? {
        await telegramCompanion.directReplyTarget(for: message)
    }

    func handleTelegramSharedChatReplyIfNeeded(
        _ text: String,
        message: TerminalTelegramIncomingMessage,
        origin: TerminalPromptOrigin
    ) async -> Bool {
        await telegramCompanion.handleSharedChatReplyIfNeeded(
            text, message: message, origin: origin.telegramEgressOrigin
        )
    }

    /// Associates a live shared-chat message with the coordinator turn that
    /// will consume it (see ``TelegramSessionCompanion/recordSharedChatMessageOrigin(_:origin:)``).
    /// An origin without a validated lease is not recorded.
    func recordTelegramSharedChatMessageOrigin(
        _ messageID: UUID, origin: TerminalPromptOrigin
    ) {
        guard let origin = origin.telegramTurnOrigin else { return }
        telegramCompanion.recordSharedChatMessageOrigin(messageID, origin: origin)
    }

    /// Returns the Telegram origin of a trigger, consuming its batch mappings
    /// so a replay cannot mirror an unrelated later coordinator response.
    func takeTelegramSharedChatOrigin(
        for messages: [AgentSharedChat.Message]
    ) -> TerminalPromptOrigin? {
        telegramCompanion.takeSharedChatOrigin(for: messages).map(TerminalPromptOrigin.init)
    }
}
