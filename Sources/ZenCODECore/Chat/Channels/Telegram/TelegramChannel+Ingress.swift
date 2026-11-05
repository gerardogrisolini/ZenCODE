//
//  TelegramChannel+Ingress.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// What the channel does with a line from Telegram once
/// ``TelegramChannel/lineAction(for:lease:)`` answered it.
enum TelegramLineAction: Sendable, Equatable {
    /// The channel answered the line in the linked chat (a remote command, a
    /// live mention, a reply the controller took); nothing follows.
    case handled
    /// An ordinary prompt: the channel runs it as a turn.
    case runPrompt(String)
    /// The line was `/plan`, `/goal`, `/review`, or a reply to the
    /// conversation waiting for the operator, and the controller asks for a
    /// turn with `prompt` and `purpose`; `locksResponseLanguage` tells a
    /// prompt the operator wrote from one the command built.
    case startTurn(prompt: String, purpose: ChatTurnPurpose, locksResponseLanguage: Bool)
}

/// The Telegram ingress: owner authorization, callbacks, the busy gate,
/// ForceReply for a bare menu command, replies to forwarded cards, the
/// questions of the controller waiting for the next message, admission to the
/// channel's prompt queue, and the remote commands a line carries when it
/// runs.
extension TelegramChannel {
    // MARK: - Texts

    /// The answer to a request that arrives while the session is generating.
    static let busyMessageText =
        "ZenCODE is busy generating a response in this session. This Telegram request was not queued; wait for the current response to finish and send it again."

    /// Whether a message from the chat is answered with ``busyMessageText``
    /// instead of being handled (the busy gate of
    /// ``handleIncomingMessage(_:)``): while the session generates a turn,
    /// and while the primary channel presents the ending of its turn here as
    /// ``refusesMessagesWhilePrimaryTurnEndingPresents`` says.
    var refusesMessagesAsBusy: Bool {
        guard isSessionGenerating else { return false }
        return refusesMessagesWhilePrimaryTurnEndingPresents || !isPresentingPrimaryTurnEnding
    }

    /// The answer to a permission reply without a request ID on the route
    /// several sessions share (see ``permissionReplyNeedsRequestID(_:lease:)``).
    static let sharedRoutePermissionReplyText =
        "ZenCODE: several ZenCODE sessions are attached to this chat; reply with the request ID: /allow ID, /always ID or /deny ID."

    /// The answer to `/start` on a linked chat.
    var alreadyLinkedText: String {
        "Telegram is already linked to this ZenCODE session. Send a prompt or /help."
    }

    /// The answer to the remote `/undo`, naming the primary channel, which
    /// runs `/undo` only once it drives the slot again. A session started by
    /// `zen --telegram` has no primary channel to take the slot back with
    /// `/telegram off`, so there `/undo` is simply not available.
    var undoText: String {
        if case .telegram? = host?.slotIdentity(slotID) {
            return Self.telegramSessionUndoText
        }
        return "Use /undo in the \(primaryChannelDescription) after /telegram off to revert file changes."
    }

    /// ``undoText`` on the slot of a session started by `zen --telegram`.
    static let telegramSessionUndoText =
        "/undo is not available in a session started with zen --telegram."

    // MARK: - Driving

    /// Starts reading the chat: the control service's ingress, until
    /// ``stopDriving(shuttingDown:)``, and the session's shared-chat room,
    /// whose messages for the operator are forwarded to the chat (see
    /// `TelegramChannel+SharedChatRelay.swift`). On an ACP session's slot, and
    /// on the slot of a session started by `zen --telegram`, the
    /// controller's task-graph observer starts too (see
    /// `TelegramChannel+TaskGraph.swift`), and the presenter applies its
    /// policy for the sub-agent responses already complete
    /// (``TelegramChannelPresenter/channelDidStartDriving()``). Starting it
    /// again while it reads does nothing. ``readsIngress`` is `true` while it
    /// reads.
    func startDriving() {
        startSharedChatObservation()
        startTaskGraphObservationIfNeeded()
        guard ingressConsumerTask == nil else { return }
        presenter.channelDidStartDriving()
        readsIngress = true
        let messages = controlService.incomingMessages
        ingressConsumerTask = Task(name: "ZenCODE.Telegram.channel-ingress") { [weak self] in
            for await message in messages {
                guard !Task.isCancelled, let self else { return }
                await self.consumeIngressMessage(message)
            }
        }
    }

    /// Stops what ``startDriving()`` started and waits for the message in
    /// hand, if any: the questions waiting for the next message are refused,
    /// the queued prompts dropped (what the message in hand queued too), and
    /// the shared-chat observation ended. The sub-agent refresh the presenter
    /// started and the task-graph observer of an ACP or `zen --telegram` slot
    /// stop as well, so nothing keeps publishing on the channel's presenter
    /// once another channel drives the slot. A task of the channel that holds
    /// no reservation yet, such as a line still answered, is stopped and
    /// awaited (``stopTurnTaskWithoutReservation()``), so nothing read from the
    /// chat starts a turn afterwards; a turn already reserved goes on.
    /// `shuttingDown` also ends every voice transcription for good; a detach
    /// lets a later attach transcribe again.
    func stopDriving(shuttingDown: Bool = false) async {
        await stopSharedChatObservation()
        await presenter.channelDidStopDriving()
        await stopTaskGraphObservation()
        cancelPendingReaders()
        promptQueue = ChatPromptQueue()
        if let task = ingressConsumerTask {
            ingressConsumerTask = nil
            task.cancel()
            await task.value
        }
        readsIngress = false
        promptQueue = ChatPromptQueue()
        await stopTurnTaskWithoutReservation()
        if shuttingDown {
            await cancelVoiceTranscriptions()
        }
    }

    /// Handles one message ``startDriving()`` read: a stop-generation update
    /// stops the turn that streamed the draft, the others go through
    /// ``handleIncomingMessage(_:)``.
    private func consumeIngressMessage(_ message: TerminalTelegramIncomingMessage) async {
        if message.stoppedMessageGenerationDraftID != nil {
            // Correlate the stop to the current reporter's native draft. A
            // delayed update for a retired/rebound turn is inert.
            if await stoppedDraftBelongsToActiveTurn(message) {
                await stopActiveTurn()
            }
            return
        }
        await handleIncomingMessage(message)
    }

    // MARK: - Messages

    /// Handles one message read from the control service's ingress and
    /// returns `true` when it admitted a prompt (started or queued).
    ///
    /// Only an active link reads messages, and only a private chat whose
    /// owner route belongs to this session, or to every session
    /// (`default`), is answered; any other message is dropped without a
    /// word. A stop-generation update is dropped too: ``startDriving()``
    /// checks it with ``stoppedDraftBelongsToActiveTurn(_:)`` before calling
    /// this.
    ///
    /// An answered message makes its route the link's route and the
    /// shared-chat relay's, except in topic mode
    /// (`TelegramChannel+Topics.swift`): there a message from another route
    /// than the session's topic (General, or a topic no route knows) is
    /// answered, and its prompt run, in the topic it came from, while the
    /// link, the relay, and the next turn stay on the session's topic.
    ///
    /// A question of the controller waiting for the next message takes a
    /// text message (``readLine(prompt:)``) or a document or image
    /// (``pickAttachment(startingAt:)``) before anything else. While the
    /// session generates, only permission replies, `/status`, `/chat`, the
    /// slash forms of `/help` and `/changes`, the mention picker taps, the
    /// artifact consent taps, and the live shared-chat text lines (a live
    /// `@mention`, a reply to an answerable card such as the picker's; see
    /// ``handleLiveSharedChatLineWhileBusy(_:message:lease:)``) are
    /// answered; everything else, `/sessions` `/models` `/think` `/agents`
    /// and the taps of their menus included, is told the session is busy.
    /// Otherwise a tap of a selection menu goes to
    /// ``handleSelectionMenuCallback(_:chatID:messageID:lease:)``
    /// (`TelegramChannel+SelectionMenus.swift`). Permission replies go
    /// through
    /// ``handlePermissionReplyIfNeeded(_:lease:)``, which refuses one
    /// without a request ID on a route several sessions share. A prompt,
    /// and a menu command completed through its ForceReply, are admitted to
    /// the channel's queue (``admitPrompt(_:lease:mode:kind:)``).
    @discardableResult
    func handleIncomingMessage(_ message: TerminalTelegramIncomingMessage) async -> Bool {
        // Stop-generation updates are consumed by `startDriving()`; never
        // reinterpret them as a prompt.
        guard message.stoppedMessageGenerationDraftID == nil else { return false }
        guard controlState.isActive else { return false }

        guard let routeLease = await authorizedRoute(for: message) else {
            // Fail closed and stay silent: disclosing whether another room or
            // user owns a route would itself leak cross-session state.
            return false
        }
        // Remember the authorized operator for outbound artifact consent.
        linkedUserID = message.userID
        // In topic mode the link stays on the session's topic: a message from
        // another route (General, or a topic no route knows) is answered where
        // it came from without moving the relay or the next turn off the topic.
        if sessionTopic.map({ $0.lease.key.topicID == routeLease.key.topicID }) ?? true {
            let hadRouteLease = activeRouteLease != nil
            activeRouteLease = routeLease
            // The relay follows the session's room whatever route admitted the
            // message: the shared route (`default`) serves every room, and a
            // relay bound to its own room would drop every batch of the session.
            await activateSharedChatRelay(roomID: sessionID, lease: routeLease)
            await activeRouteLeaseDidChange(hadLease: hadRouteLease)
        }
        guard let ingressFence = wireFence(for: routeLease) else { return false }
        let isSessionGenerating = isSessionGenerating
        let refusesAsBusy = refusesMessagesAsBusy

        if let callbackQueryID = message.callbackQueryID,
           let callbackData = message.callbackData {
            await controlService.answerCallbackQuery(
                callbackQueryID, chatID: message.chatID, fence: ingressFence
            )
            if await handleArtifactConsentCallback(
                callbackData, message: message, lease: routeLease
            ) {
                return false
            }
            guard !isSessionGenerating
                || callbackData.hasPrefix(Self.mentionPickerCallbackPrefix) else {
                await sendBusyMessage(lease: routeLease)
                return false
            }
            if Self.isSelectionMenuCallback(callbackData) {
                await handleSelectionMenuCallback(
                    callbackData, chatID: message.chatID,
                    messageID: message.messageID, lease: routeLease
                )
                return false
            }
            await handleMentionPickerCallback(
                callbackData, chatID: message.chatID, lease: routeLease
            )
            return false
        }

        // Owner resolution, lease capture and the wire fence stay above the
        // gate; the gate rejects before attachment downloads, voice
        // transcription, or command parsing. Permission replies remain live
        // because an active turn may be blocked waiting for exactly this
        // operator decision, and so do the live shared-chat text lines,
        // because the agents they address exist while the turn runs.
        if isSessionGenerating,
           let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           TerminalTelegramPermissionBroker.permissionCommand(from: text) != nil,
           await handlePermissionReplyIfNeeded(text, lease: routeLease) {
            return false
        }
        // A question of the controller takes the next message before the
        // busy gate: the session waits for exactly this answer.
        if let attachment = message.attachment, pendingAttachmentReader != nil {
            await handleInboundAttachment(attachment, message: message, lease: routeLease)
            return false
        }
        if pendingLineReader != nil, message.attachment == nil, message.voice == nil,
           let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           deliverPendingLine(text, lease: routeLease) {
            return false
        }
        if isSessionGenerating,
           let busyText = message.text.map(Self.commandWithoutBotMention),
           let invocation = TerminalTelegramRemoteCommand.invocation(text: busyText),
           invocation.argument.isEmpty {
            let isSlash = CoordinatorCommandParser.isSlashCommand(busyText)
            switch invocation.command {
            case .status:
                await sendSystemMessageIfLinked(remoteStatusText(), lease: routeLease)
                return false
            case .chat:
                await handleMentionPickerRequest(chatID: message.chatID, lease: routeLease)
                return false
            case .help where isSlash:
                await sendSystemMessageIfLinked(remoteHelpText(), lease: routeLease)
                return false
            case .changes where isSlash:
                await sendSystemMessageIfLinked(remoteChangesText(), lease: routeLease)
                return false
            default:
                break
            }
        }
        // Text only: a voice note quoting a card would need the transcription
        // the gate refuses, and an attachment never addresses a participant.
        if refusesAsBusy, message.attachment == nil, message.voice == nil,
           let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           await handleLiveSharedChatLineWhileBusy(text, message: message, lease: routeLease) {
            return false
        }
        guard !refusesAsBusy else {
            await sendBusyMessage(lease: routeLease)
            return false
        }

        if let attachment = message.attachment {
            await handleInboundAttachment(attachment, message: message, lease: routeLease)
            return false
        }

        if let voice = message.voice {
            // A voice note that quotes an answerable card is ambiguous: the
            // reply target cannot be carried through transcription, so direct
            // replies are text-only. Quoting a card that routes nowhere is not
            // a direct reply and keeps the ordinary voice-prompt path.
            if await directReplyTarget(for: message) != nil {
                await sendSystemMessageIfLinked(
                    "ZenCODE message: replies to a live message must be text. Send your answer as text, or record a voice note without replying to run it as an ordinary prompt.",
                    lease: routeLease
                )
                return false
            }
            await handleVoiceMessage(voice, lease: routeLease)
            return false
        }

        let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return false }

        if await handlePermissionReplyIfNeeded(text, lease: routeLease) {
            return false
        }

        let commandText = Self.commandWithoutBotMention(text)
        let invocation = TerminalTelegramRemoteCommand.invocation(text: commandText)
        // `/start` and `/chat` are answered before the prompt queue: they must
        // work even when the queue is full and must never be consumed as the
        // argument of a pending ForceReply command request. `/chat <text>`
        // falls through to the queued path, which rejects the argument.
        switch (invocation?.command, invocation?.argument.isEmpty) {
        case (.start?, _):
            await sendSystemMessageIfLinked(alreadyLinkedText, lease: routeLease)
            return false
        case (.chat?, true?):
            await handleMentionPickerRequest(chatID: message.chatID, lease: routeLease)
            return false
        default:
            break
        }

        if let coordinatorCommand = CoordinatorCommandParser.parse(commandText),
           coordinatorCommand.requiresArgument {
            await requestCommandArgument(commandText, chatID: message.chatID, lease: routeLease)
            return false
        }

        if let completedCommand = consumeCommandArgumentReply(from: message, lease: routeLease) {
            return await admitPrompt(completedCommand, lease: routeLease, kind: "command")
        }

        // A reply to a forwarded live-message card answers its sender
        // directly. Remote commands and explicit `@mention` routing keep
        // precedence, so quoting a card never changes what an explicitly
        // addressed line means.
        if await replyRoutingHasPrecedence(over: text) == false,
           await handleSharedChatReplyIfNeeded(text, message: message, lease: routeLease) {
            return false
        }

        guard (try? await router.validate(routeLease)) != nil else { return false }
        return await admitPrompt(text, lease: routeLease, kind: "prompt")
    }

    /// The owner route of `message` for this session, or `nil`.
    /// Authorization is entirely owner and lifecycle based: a private chat,
    /// a route the router resolves, of this session or of every session
    /// (`default`).
    func authorizedRoute(
        for message: TerminalTelegramIncomingMessage
    ) async -> TerminalTelegramRouteLease? {
        guard message.chatKind == .privateChat,
              let lease = try? await router.resolve(
                  chatID: message.chatID, userID: message.userID,
                  topicID: message.topicID
              ),
              lease.key.admits(roomID: sessionID) else {
            return nil
        }
        return lease
    }

    /// Whether `message` is a stop-generation update for the draft of the
    /// turn in progress: the turn's route is still valid and its topic is
    /// the message's, and the turn's reporter streamed that draft. A delayed
    /// update for a retired or rebound turn is not.
    func stoppedDraftBelongsToActiveTurn(
        _ message: TerminalTelegramIncomingMessage
    ) async -> Bool {
        guard let draftID = message.stoppedMessageGenerationDraftID,
              let lease = activeTurnLease,
              await validateLease(lease),
              lease.effectiveMessageThreadID == message.topicID,
              let reporter = activeProgressReporter else {
            return false
        }
        return await reporter.ownsStoppedDraft(chatID: message.chatID, draftID: draftID)
    }

    /// The command token of a Telegram line without its `@botname` suffix
    /// (`/review@zencode_bot x` is `/review x`); the line is trimmed.
    nonisolated static func commandWithoutBotMention(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(where: \.isWhitespace) else {
            guard trimmed.first == "/", let at = trimmed.firstIndex(of: "@") else { return trimmed }
            return String(trimmed[..<at])
        }
        let token = trimmed[..<separator]
        guard token.first == "/", let at = token.firstIndex(of: "@") else { return trimmed }
        return String(token[..<at]) + trimmed[separator...]
    }

    // MARK: - Lines

    /// Answers a line that came from Telegram on `lease` when it leaves the
    /// queue.
    ///
    /// Remote commands (`/help`, `/status`, `/chat`, `/changes`, `/undo`,
    /// `/diff`, `/start`) and live `@mention` messages are answered in the
    /// linked chat, and `/sessions`, `/models`, `/think` and `/agents` send
    /// their selection menu (`TelegramChannel+SelectionMenus.swift`,
    /// `TelegramChannel+SessionsMenu.swift`); a remote command with an
    /// argument and an unknown slash command are told so. `/plan`, `/goal`
    /// and `/review` run through
    /// ``ChatSessionController/handleCommandLine(_:context:)`` with the
    /// context of the slot's primary channel, and a plain line goes first to
    /// the conversation waiting for the operator
    /// (``ChatSessionController/pendingReplyAction(for:fence:policy:)``).
    /// When such a command starts no turn, the notices it presented and its
    /// closing notices go to the chat, in order, as the terminal sends what
    /// it wrote. A plain-word alias ("status") is a command only while no
    /// conversation waits for a reply. Anything else is a prompt. A line
    /// whose route is no longer valid is dropped.
    func lineAction(
        for line: String,
        lease: TerminalTelegramRouteLease
    ) async -> TelegramLineAction {
        guard await validateLease(lease) else { return .handled }
        let prompt = Self.commandWithoutBotMention(line)
        let isSlash = CoordinatorCommandParser.isSlashCommand(prompt)
        let remoteInvocation = TerminalTelegramRemoteCommand.invocation(text: prompt)
        let remoteCommand = remoteInvocation?.command
        if let remoteInvocation, remoteInvocation.command != .start, isSlash,
           !remoteInvocation.argument.isEmpty {
            let name = prompt.split(whereSeparator: \.isWhitespace).first
                .map { String($0).lowercased() } ?? prompt
            await sendSystemMessageIfLinked(
                "ZenCODE: \(name) does not accept arguments.", lease: lease
            )
            return .handled
        }
        // A plain-word alias ("status", "diff", "undo", ...) is ordinary text
        // while a conversation explicitly waits for the operator: the pending
        // reply wins, exactly as in the terminal, where those words are never
        // commands. Slash forms keep their command meaning.
        if remoteCommand != nil, !isSlash,
           let action = await pendingReplyLineAction(prompt, lease: lease) {
            return action
        }
        switch remoteCommand {
        case .start:
            await sendSystemMessageIfLinked(alreadyLinkedText, lease: lease)
            return .handled
        case .help:
            await sendSystemMessageIfLinked(remoteHelpText(), lease: lease)
            return .handled
        case .status:
            await sendSystemMessageIfLinked(remoteStatusText(), lease: lease)
            return .handled
        case .chat:
            await handleMentionPickerRequest(chatID: lease.key.chatID, lease: lease)
            return .handled
        case .sessions:
            await handleSessionsMenuRequest(lease: lease)
            return .handled
        case .models:
            await handleModelsMenuRequest(lease: lease)
            return .handled
        case .think:
            await handleThinkMenuRequest(lease: lease)
            return .handled
        case .agents:
            await handleAgentsMenuRequest(lease: lease)
            return .handled
        case .changes:
            await sendSystemMessageIfLinked(remoteChangesText(), lease: lease)
            return .handled
        case .undo:
            await sendSystemMessageIfLinked(undoText, lease: lease)
            return .handled
        case .diff:
            await handleDiffRequest(lease: lease)
            return .handled
        case .none:
            break
        }

        switch SharedChatMentionParser.parse(
            from: prompt,
            readableHandles: await sessionRunner.sharedChatMentionHandles(
                rootSessionID: sessionID
            )
        ) {
        case let .route(route):
            await sendSharedChatMention(route, lease: lease)
            return .handled
        case .missingText:
            await sendSystemMessageIfLinked(
                "ZenCODE message: add a message after the live mention.", lease: lease
            )
            return .handled
        case .none:
            break
        }

        if !isSlash, let action = await pendingReplyLineAction(prompt, lease: lease) {
            return action
        }
        if let coordinatorCommand = CoordinatorCommandParser.parse(prompt) {
            return await coordinatorCommandLineAction(coordinatorCommand, line: prompt, lease: lease)
        }
        if isSlash, TerminalTelegramPermissionBroker.permissionCommand(from: prompt) == nil {
            let token = prompt.split(whereSeparator: \.isWhitespace).first
                .map(String.init) ?? prompt
            await sendSystemMessageIfLinked(
                "ZenCODE: unknown command '\(token)'. Available commands: \(Self.remoteCommandList())",
                lease: lease
            )
            return .handled
        }
        return .runPrompt(prompt)
    }

    /// Runs `/plan`, `/goal` or `/review` through the controller. The line
    /// is rebuilt as `/<family> <argument>`, the spelling the command
    /// registry resolves, so a token the coordinator parser accepts (any
    /// case, any whitespace before the argument) runs the same command.
    private func coordinatorCommandLineAction(
        _ command: CoordinatorCommand,
        line: String,
        lease: TerminalTelegramRouteLease
    ) async -> TelegramLineAction {
        guard let controller else { return .handled }
        let commandLine = Self.coordinatorCommandLine(command, from: line)
        presenter.beginNoticeCapture()
        let outcome = await controller.handleCommandLine(
            commandLine,
            context: commandContext()
        )
        let captured = presenter.endNoticeCapture()
        await sendCommandNotices(of: outcome, captured: captured, lease: lease)
        return Self.lineAction(for: outcome)
    }

    /// Routes a plain line to the conversation that is explicitly waiting
    /// for the operator (the Goal for `/plan approve`, an open Planner
    /// question, a `/goal` workflow awaiting the user), or `nil` when none
    /// waits. The notices the reply produced reach the chat with the rule of
    /// the coordinator commands; otherwise an approval failure would appear
    /// only on the primary channel.
    private func pendingReplyLineAction(
        _ prompt: String,
        lease: TerminalTelegramRouteLease
    ) async -> TelegramLineAction? {
        guard let controller else { return nil }
        presenter.beginNoticeCapture()
        let outcome = await controller.pendingReplyAction(for: prompt)
        let captured = presenter.endNoticeCapture()
        guard let outcome else { return nil }
        await sendCommandNotices(of: outcome, captured: captured, lease: lease)
        return Self.lineAction(for: outcome)
    }

    /// The action of a command's outcome: the turn it asks for, or nothing
    /// more (its notices were sent).
    nonisolated static func lineAction(for outcome: ChatCommandOutcome) -> TelegramLineAction {
        switch outcome.action {
        case let .startTurn(prompt, purpose, locksResponseLanguage):
            .startTurn(prompt: prompt, purpose: purpose, locksResponseLanguage: locksResponseLanguage)
        case .none, .channelCommand:
            .handled
        }
    }

    /// The facts that decide which slash commands the session accepts from
    /// the chat: the registry context of the slot's primary channel is not
    /// known here, so the shared commands decide with what the controller
    /// knows (the agent, the plan, the workflow).
    func commandContext() -> ChatCommandContext {
        []
    }

    /// Sends to the chat on `lease`, when the command starts no turn, the
    /// notices it presented while it ran (`captured`) and its closing
    /// notices, in order, joined by newlines; a blank result sends nothing.
    func sendCommandNotices(
        of outcome: ChatCommandOutcome,
        captured: [String],
        lease: TerminalTelegramRouteLease
    ) async {
        if case .startTurn = outcome.action { return }
        let texts = captured + outcome.notices.map { ChatSessionNoticeText.text(for: $0) }
        guard let output = texts.joined(separator: "\n").nilIfBlank else { return }
        await sendSystemMessageIfLinked(output, lease: lease)
    }

    /// `line` as the command registry resolves `command`: the family's
    /// canonical token, then the argument the coordinator parser read.
    nonisolated static func coordinatorCommandLine(
        _ command: CoordinatorCommand,
        from line: String
    ) -> String {
        let family: CoordinatorCommandFamily = switch command {
        case .plan: .plan
        case .goal: .goal
        case .review: .review
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenEnd = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
        let argument = String(trimmed[tokenEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return argument.isEmpty ? "/\(family.rawValue)" : "/\(family.rawValue) \(argument)"
    }

    // MARK: - Permission replies

    /// Answers a permission reply on `lease` like
    /// ``handlePermissionResponseIfNeeded(_:lease:)``, except that a reply
    /// without a request ID that
    /// ``permissionReplyNeedsRequestID(_:lease:)`` cannot attribute is
    /// refused with ``sharedRoutePermissionReplyText`` and never reaches the
    /// broker. The refusal goes on the turn's ordered channel, like the
    /// broker's answers; on a route that is no longer valid the reply is
    /// consumed without effect.
    func handlePermissionReplyIfNeeded(
        _ text: String,
        lease: TerminalTelegramRouteLease
    ) async -> Bool {
        guard permissionReplyNeedsRequestID(text, lease: lease) else {
            return await handlePermissionResponseIfNeeded(text, lease: lease)
        }
        guard (try? await router.validate(lease)) != nil else { return true }
        await sendTurnMessage(
            .authorization(Self.sharedRoutePermissionReplyText),
            to: lease.key.chatID,
            lease: lease
        )
        return true
    }

    /// Whether `text` is an `/allow`, `/always` or `/deny` without a request
    /// ID on the route several sessions share (no topic: General, an
    /// unknown topic that fell back to it, or the legacy route) while more
    /// than one channel is attached to this bot. Such a reply could decide
    /// a request of another session, so it must name its request. With one
    /// channel, or in the session's own topic, the reply is answered as
    /// before.
    func permissionReplyNeedsRequestID(
        _ text: String,
        lease: TerminalTelegramRouteLease
    ) -> Bool {
        guard let command = TerminalTelegramPermissionBroker.permissionCommand(from: text),
              command.requestID == nil,
              lease.key.topicID == nil,
              let botID = controlState.botID else {
            return false
        }
        return registry.attachedCount(botID: botID) > 1
    }

    // MARK: - Support

    /// A menu selection is delivered by Telegram as a bare message. Asks for
    /// the missing argument with a receipt-backed ForceReply, then accepts
    /// only a reply to that exact receipt on its original route.
    private func requestCommandArgument(
        _ command: String, chatID: Int64, lease: TerminalTelegramRouteLease
    ) async {
        let prompt: String
        if command == "/plan" {
            prompt = "Enter the goal or subcommand for /plan (save, load, list, delete, status, approve, clear). Reply to this message; it will not be treated as a normal prompt."
        } else {
            prompt = "Enter the argument for \(command). Reply to this message; it will not be treated as a normal prompt."
        }
        let receipt = await sendReplyMarkupMessage(
            prompt, to: chatID, replyMarkup: .forceReply, lease: lease
        )
        guard let receipt else { return }
        // One unanswered command per route bounds this ledger even if an
        // operator repeatedly opens a parameterized menu command.
        commandReplyBindings = commandReplyBindings.filter { $0.value.lease != lease }
        commandReplyBindings[.init(chatID: chatID, receiptMessageID: receipt)] =
            TerminalTelegramCommandReplyBinding(command: command, chatID: chatID, lease: lease)
    }

    /// The command a reply to a ForceReply receipt completes, consuming the
    /// receipt, or `nil` when `message` answers no receipt of its route.
    private func consumeCommandArgumentReply(
        from message: TerminalTelegramIncomingMessage,
        lease: TerminalTelegramRouteLease
    ) -> String? {
        guard let receipt = message.replyToMessageID,
              let binding = commandReplyBindings[
                  .init(chatID: message.chatID, receiptMessageID: receipt)
              ],
              binding.chatID == message.chatID,
              binding.lease == lease,
              let argument = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !argument.isEmpty else {
            return nil
        }
        commandReplyBindings.removeValue(
            forKey: .init(chatID: message.chatID, receiptMessageID: receipt)
        )
        return "\(binding.command) \(argument)"
    }

    /// Tells the chat on `lease` that the session is busy
    /// (``busyMessageText``).
    func sendBusyMessage(lease: TerminalTelegramRouteLease) async {
        await sendSystemMessageIfLinked(Self.busyMessageText, lease: lease)
    }
}
