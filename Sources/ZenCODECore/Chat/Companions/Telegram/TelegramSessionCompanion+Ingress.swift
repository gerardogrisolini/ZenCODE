//
//  TelegramSessionCompanion+Ingress.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// What the primary channel does with a line from Telegram once
/// ``TelegramSessionCompanion/lineAction(for:lease:)`` answered it.
enum TelegramCompanionLineAction: Sendable, Equatable {
    /// The companion answered the line in the linked chat (a remote command,
    /// a live mention, a refusal); nothing follows.
    case handled
    /// The line was `/plan`, `/goal`, `/review`, or a reply to the
    /// conversation waiting for the operator, and the controller ran it. The
    /// channel presents the outcome's notices and takes its action, exactly
    /// as for a line typed on the channel. When the action starts no turn,
    /// the companion already sent the command's notices to the linked chat.
    case commandOutcome(ChatCommandOutcome)
    /// An ordinary prompt: the channel runs it as a turn of origin
    /// ``TelegramTurnOrigin/telegram(_:)``.
    case runPrompt(String)
}

/// The Telegram ingress, as the terminal's panel loop hands it over: owner
/// authorization, callbacks, the busy gate, ForceReply for a bare menu
/// command, replies to forwarded cards, admission to the channel's prompt
/// queue, and the remote commands a line carries when it leaves that
/// queue. ``Policy/mirrorOnly`` refuses what would drive the session before
/// the busy gate (see its documentation).
extension TelegramSessionCompanion {
    // MARK: - Texts

    /// The answer to a request that arrives while the session is generating.
    static let busyMessageText =
        "ZenCODE is busy generating a response in this session. This Telegram request was not queued; wait for the current response to finish and send it again."

    /// The answer to a permission reply without a request ID on the route
    /// several sessions share (see ``permissionReplyNeedsRequestID(_:lease:)``).
    static let sharedRoutePermissionReplyText =
        "ZenCODE: several ZenCODE sessions are attached to this chat; reply with the request ID: /allow ID, /always ID or /deny ID."

    /// The answer to `/start` on a linked chat.
    var alreadyLinkedText: String {
        switch configuration.policy {
        case .full:
            "Telegram is already linked to this ZenCODE session. Send a prompt or /help."
        case .mirrorOnly:
            "Telegram is already linked to this ZenCODE session. Send /help."
        }
    }

    /// The answer to the remote `/undo`, naming the primary channel.
    var undoText: String {
        "Use /undo in the \(configuration.primaryChannelDescription) to revert file changes."
    }

    // MARK: - Messages

    /// Handles one message the channel read from the control service's
    /// ingress, as the terminal's `handleTelegramMessage` does it, and
    /// returns `true` when it admitted a prompt to the channel's queue.
    ///
    /// Only an active link reads messages, and only a private chat whose
    /// owner route belongs to this session, or to every session
    /// (`default`), is answered; any other message is dropped without a
    /// word. A stop-generation update is dropped too: the channel that owns
    /// the turn checks it with ``stoppedDraftBelongsToActiveTurn(_:)``
    /// before calling this.
    ///
    /// An answered message makes its route the link's route and the
    /// shared-chat relay's, except in topic mode
    /// (`TelegramSessionCompanion+Topics.swift`): there a message from
    /// another route than the session's topic (General, or a topic no route
    /// knows) is answered, and its prompt run, in the topic it came from,
    /// while the link, the relay, and the next turn of the primary channel
    /// stay on the session's topic.
    ///
    /// `isSessionGenerating` is the channel's state when it read the message:
    /// while it is `true`, only permission replies, `/status`, `/chat`, the
    /// slash forms of `/help` and `/changes`, the mention picker taps, and
    /// the artifact consent taps are answered; everything else is told the
    /// session is busy. Permission replies go through
    /// ``handlePermissionReplyIfNeeded(_:lease:)``, which refuses one
    /// without a request ID on a route several sessions share. A prompt, and
    /// a menu command completed through its ForceReply, are handed to
    /// `admit` as a submitted line on the message's route; a full queue or a
    /// refusal is answered in the chat.
    /// The channel reacts to the queued prompt only after this method
    /// returns. A ``Policy/mirrorOnly`` companion never calls `admit`: it
    /// answers the line at once with ``lineAction(for:lease:)``.
    func handleIncomingMessage(
        _ message: TerminalTelegramIncomingMessage,
        isSessionGenerating: Bool,
        admit: (ChatQueuedPrompt<TerminalTelegramRouteLease>) -> TelegramPromptAdmission
    ) async -> Bool {
        // Stop-generation updates are consumed by the channel that owns the
        // generating turn; never reinterpret them as a prompt.
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
            activeRouteLease = routeLease
            await sharedChatRelay.activate(
                roomID: routeLease.key.roomID,
                chatID: routeLease.key.chatID,
                lease: routeLease,
                repliesEnabled: readsIngress
            )
        }
        let routeOrigin = TelegramTurnOrigin.telegram(routeLease)
        guard let ingressFence = wireFence(for: routeOrigin) else { return false }

        if let callbackQueryID = message.callbackQueryID,
           let callbackData = message.callbackData {
            await controlService.answerCallbackQuery(
                callbackQueryID, chatID: message.chatID, fence: ingressFence
            )
            if await handleArtifactConsentCallback(
                callbackData, message: message, origin: routeOrigin
            ) {
                return false
            }
            guard !isSessionGenerating
                || callbackData.hasPrefix(Self.mentionPickerCallbackPrefix) else {
                await sendBusyMessage(origin: routeOrigin)
                return false
            }
            await handleMentionPickerCallback(
                callbackData, chatID: message.chatID, origin: routeOrigin
            )
            return false
        }

        // A mirror-only session is never driven from Telegram, busy or not:
        // what would drive it is refused before the busy gate.
        if configuration.policy == .mirrorOnly, await mirrorOnlyRefuses(message) {
            await sendSystemMessageIfLinked(mirrorOnlyRefusalText, origin: routeOrigin)
            return false
        }

        // Owner resolution, lease capture and the wire fence stay above the
        // gate; the gate rejects before attachment downloads, voice
        // transcription, command parsing or shared-chat publication.
        // Permission replies remain live because an active turn may be
        // blocked waiting for exactly this operator decision.
        if isSessionGenerating,
           let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           TerminalTelegramPermissionBroker.permissionCommand(from: text) != nil,
           await handlePermissionReplyIfNeeded(text, lease: routeLease) {
            return false
        }
        if isSessionGenerating,
           let busyText = message.text.map(Self.commandWithoutBotMention),
           let invocation = TerminalTelegramRemoteCommand.invocation(text: busyText),
           invocation.argument.isEmpty {
            let isSlash = CoordinatorCommandParser.isSlashCommand(busyText)
            switch invocation.command {
            case .status:
                await sendSystemMessageIfLinked(remoteStatusText(), origin: routeOrigin)
                return false
            case .chat:
                await handleMentionPickerRequest(chatID: message.chatID, origin: routeOrigin)
                return false
            case .help where isSlash:
                await sendSystemMessageIfLinked(remoteHelpText(), origin: routeOrigin)
                return false
            case .changes where isSlash:
                await sendSystemMessageIfLinked(remoteChangesText(), origin: routeOrigin)
                return false
            default:
                break
            }
        }
        guard !isSessionGenerating else {
            await sendBusyMessage(origin: routeOrigin)
            return false
        }

        if let attachment = message.attachment {
            await handleInboundAttachment(attachment, message: message, origin: routeOrigin)
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
                    origin: routeOrigin
                )
                return false
            }
            await handleVoiceMessage(voice, origin: routeOrigin)
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
            await sendSystemMessageIfLinked(alreadyLinkedText, origin: routeOrigin)
            return false
        case (.chat?, true?):
            await handleMentionPickerRequest(chatID: message.chatID, origin: routeOrigin)
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
            return await admitLine(
                completedCommand, lease: routeLease, kind: "command", admit: admit
            )
        }

        // A reply to a forwarded live-message card answers its sender
        // directly. Remote commands and explicit `@mention` routing keep
        // precedence, so quoting a card never changes what an explicitly
        // addressed line means.
        if await replyRoutingHasPrecedence(over: text) == false,
           await handleSharedChatReplyIfNeeded(text, message: message, origin: routeOrigin) {
            return false
        }

        guard (try? await router.validate(routeLease)) != nil else { return false }
        if configuration.policy == .mirrorOnly {
            // No queue to wait in: the line is a command, answered at once.
            // `lineAction` never runs a line for a mirror-only companion.
            _ = await lineAction(for: text, lease: routeLease)
            return false
        }
        return await admitLine(text, lease: routeLease, kind: "prompt", admit: admit)
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
              lease.key.roomID == controller.sessionID || lease.key.roomID == "default" else {
            return nil
        }
        return lease
    }

    /// Whether `message` is a stop-generation update for the draft of the
    /// turn in progress: the turn's route is still valid and its topic is
    /// the message's, and the turn's reporter streamed that draft. A delayed
    /// update for a retired or rebound turn is not. The channel that owns the
    /// generating turn stops it when this is `true`, as the terminal's panel
    /// loop does, and ignores the update otherwise.
    func stoppedDraftBelongsToActiveTurn(
        _ message: TerminalTelegramIncomingMessage
    ) async -> Bool {
        guard let draftID = message.stoppedMessageGenerationDraftID,
              let origin = activeTurnOrigin,
              await validateOrigin(origin),
              origin.lease?.effectiveMessageThreadID == message.topicID,
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

    /// Answers a line that came from Telegram on `lease`, as the terminal's
    /// `submittedTelegramLineAction` does it when the line leaves the queue.
    ///
    /// Remote commands (`/help`, `/status`, `/chat`, `/changes`, `/undo`,
    /// `/diff`, `/start`) and live `@mention` messages are answered in the
    /// linked chat; a remote command with an argument and an unknown slash
    /// command are told so. `/plan`, `/goal` and `/review` run through
    /// ``ChatSessionController/handleCommandLine(_:context:)`` with the
    /// channel's ``TelegramCompanionChannel/commandContext()``, and a plain
    /// line goes first to the conversation waiting for the operator
    /// (``ChatSessionController/pendingReplyAction(for:fence:policy:)``).
    /// When such a command starts no turn, the notices it presented and its
    /// closing notices go to the chat, in order, as the terminal sends what
    /// it wrote. A plain-word alias ("status") is a command only while no
    /// conversation waits for a reply. Anything else is a prompt.
    ///
    /// A ``Policy/mirrorOnly`` companion refuses with
    /// ``mirrorOnlyRefusalText`` what would drive the session, and never
    /// answers ``TelegramCompanionLineAction/commandOutcome(_:)`` or
    /// ``TelegramCompanionLineAction/runPrompt(_:)``. A line whose route is
    /// no longer valid is dropped.
    func lineAction(
        for line: String,
        lease: TerminalTelegramRouteLease
    ) async -> TelegramCompanionLineAction {
        let origin = TelegramTurnOrigin.telegram(lease)
        guard await validateOrigin(origin) else { return .handled }
        let prompt = Self.commandWithoutBotMention(line)
        let isMirrorOnly = configuration.policy == .mirrorOnly
        if isMirrorOnly, await mirrorOnlyRefusesLine(prompt) {
            await sendSystemMessageIfLinked(mirrorOnlyRefusalText, origin: origin)
            return .handled
        }
        let isSlash = CoordinatorCommandParser.isSlashCommand(prompt)
        let remoteInvocation = TerminalTelegramRemoteCommand.invocation(text: prompt)
        let remoteCommand = remoteInvocation?.command
        if let remoteInvocation, remoteInvocation.command != .start, isSlash,
           !remoteInvocation.argument.isEmpty {
            let name = prompt.split(whereSeparator: \.isWhitespace).first
                .map { String($0).lowercased() } ?? prompt
            await sendSystemMessageIfLinked(
                "ZenCODE: \(name) does not accept arguments.", origin: origin
            )
            return .handled
        }
        // A plain-word alias ("status", "diff", "undo", ...) is ordinary text
        // while a conversation explicitly waits for the operator: the pending
        // reply wins, exactly as in the terminal, where those words are never
        // commands. Slash forms keep their command meaning. A mirror-only
        // companion takes no replies, so its aliases stay commands.
        if !isMirrorOnly, remoteCommand != nil, !isSlash,
           let action = await pendingReplyLineAction(prompt, origin: origin) {
            return action
        }
        switch remoteCommand {
        case .start:
            await sendSystemMessageIfLinked(alreadyLinkedText, origin: origin)
            return .handled
        case .help:
            await sendSystemMessageIfLinked(remoteHelpText(), origin: origin)
            return .handled
        case .status:
            await sendSystemMessageIfLinked(remoteStatusText(), origin: origin)
            return .handled
        case .chat:
            await handleMentionPickerRequest(chatID: lease.key.chatID, origin: origin)
            return .handled
        case .changes:
            await sendSystemMessageIfLinked(remoteChangesText(), origin: origin)
            return .handled
        case .undo:
            await sendSystemMessageIfLinked(undoText, origin: origin)
            return .handled
        case .diff:
            await handleDiffRequest(origin: origin)
            return .handled
        case .none:
            break
        }

        switch SharedChatMentionParser.parse(
            from: prompt,
            readableHandles: await sessionRunner.sharedChatMentionHandles(
                rootSessionID: controller.sessionID
            )
        ) {
        case let .route(route):
            await sendSharedChatMention(route, origin: origin)
            return .handled
        case .missingText:
            await sendSystemMessageIfLinked(
                "ZenCODE message: add a message after the live mention.", origin: origin
            )
            return .handled
        case .none:
            break
        }

        if !isMirrorOnly, !isSlash,
           let action = await pendingReplyLineAction(prompt, origin: origin) {
            return action
        }
        if !isMirrorOnly, let coordinatorCommand = CoordinatorCommandParser.parse(prompt) {
            return await coordinatorCommandLineAction(coordinatorCommand, line: prompt, origin: origin)
        }
        if isSlash, TerminalTelegramPermissionBroker.permissionCommand(from: prompt) == nil {
            let token = prompt.split(whereSeparator: \.isWhitespace).first
                .map(String.init) ?? prompt
            await sendSystemMessageIfLinked(
                "ZenCODE: unknown command '\(token)'. Available commands: \(Self.remoteCommandList(policy: configuration.policy))",
                origin: origin
            )
            return .handled
        }
        guard !isMirrorOnly else {
            // Unreachable from the ingress, which consumes permission replies
            // first; a mirror-only companion runs no line.
            await sendSystemMessageIfLinked(mirrorOnlyRefusalText, origin: origin)
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
        origin: TelegramTurnOrigin
    ) async -> TelegramCompanionLineAction {
        let commandLine = Self.coordinatorCommandLine(command, from: line)
        presenter.beginNoticeCapture()
        let outcome = await controller.handleCommandLine(
            commandLine,
            context: channel?.commandContext() ?? []
        )
        let captured = presenter.endNoticeCapture()
        await sendCommandNotices(of: outcome, captured: captured, origin: origin)
        return .commandOutcome(outcome)
    }

    /// Routes a plain line to the conversation that is explicitly waiting
    /// for the operator (the Goal for `/plan approve`, an open Planner
    /// question, a `/goal` workflow awaiting the user), or `nil` when none
    /// waits. The notices the reply produced reach the chat with the rule of
    /// the coordinator commands; otherwise an approval failure would appear
    /// only on the primary channel.
    private func pendingReplyLineAction(
        _ prompt: String,
        origin: TelegramTurnOrigin
    ) async -> TelegramCompanionLineAction? {
        presenter.beginNoticeCapture()
        let outcome = await controller.pendingReplyAction(for: prompt)
        let captured = presenter.endNoticeCapture()
        guard let outcome else { return nil }
        await sendCommandNotices(of: outcome, captured: captured, origin: origin)
        return .commandOutcome(outcome)
    }

    /// Sends to the chat of `origin`, when the command starts no turn, the
    /// notices it presented while it ran (`captured`) and its closing
    /// notices, in order, joined by newlines; a blank result sends nothing.
    private func sendCommandNotices(
        of outcome: ChatCommandOutcome,
        captured: [String],
        origin: TelegramTurnOrigin
    ) async {
        if case .startTurn = outcome.action { return }
        let texts = captured + outcome.notices.map { ChatSessionNoticeText.text(for: $0) }
        guard let output = texts.joined(separator: "\n").nilIfBlank else { return }
        await sendSystemMessageIfLinked(output, origin: origin)
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
            origin: .telegram(lease)
        )
        return true
    }

    /// Whether `text` is an `/allow`, `/always` or `/deny` without a request
    /// ID on the route several sessions share (no topic: General, an
    /// unknown topic that fell back to it, or the legacy route) while more
    /// than one companion is attached to this bot. Such a reply could
    /// decide a request of another session, so it must name its request.
    /// With one companion, or in the session's own topic, the reply is
    /// answered as before.
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
        return attachments.attachedCount(botID: botID) > 1
    }

    // MARK: - Mirror only

    /// Whether a ``Policy/mirrorOnly`` companion refuses `message` before
    /// the busy gate: a voice note, or a text line
    /// ``mirrorOnlyRefusesLine(_:)`` refuses that is not a text reply to an
    /// answerable forwarded card. Documents and images are not refused.
    private func mirrorOnlyRefuses(_ message: TerminalTelegramIncomingMessage) async -> Bool {
        guard message.attachment == nil else { return false }
        if message.voice != nil { return true }
        guard let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              await mirrorOnlyRefusesLine(Self.commandWithoutBotMention(text)) else {
            return false
        }
        // A plain line quoting an answerable card is a reply to its sender,
        // the same as a reply after `/chat`.
        if await replyRoutingHasPrecedence(over: text) == false,
           await directReplyTarget(for: message) != nil {
            return false
        }
        return true
    }

    /// Whether a ``Policy/mirrorOnly`` companion refuses the line `prompt`
    /// (without its bot mention): `/undo` in any form, `/plan` `/goal`
    /// `/review` in any form, and any plain text that is neither a remote
    /// command alias nor a live mention, which covers prompts and replies
    /// to pending questions. Permission replies, the other remote commands,
    /// live mentions, and unknown slash commands are not refused.
    private func mirrorOnlyRefusesLine(_ prompt: String) async -> Bool {
        if TerminalTelegramPermissionBroker.permissionCommand(from: prompt) != nil {
            return false
        }
        if let invocation = TerminalTelegramRemoteCommand.invocation(text: prompt) {
            return invocation.command == .undo
        }
        if CoordinatorCommandParser.parse(prompt) != nil {
            return true
        }
        if CoordinatorCommandParser.isSlashCommand(prompt) {
            return false
        }
        switch SharedChatMentionParser.parse(
            from: prompt,
            readableHandles: await sessionRunner.sharedChatMentionHandles(
                rootSessionID: controller.sessionID
            )
        ) {
        case .route, .missingText:
            return false
        case .none:
            return true
        }
    }

    // MARK: - Consuming

    /// Reads the control service's ingress for a primary channel without an
    /// event loop of its own (an ACP session), until ``detach()`` or
    /// ``shutdown()``. Starting it again while it reads does nothing.
    ///
    /// Each message is handled as the terminal's panel loop handles it: a
    /// stop-generation update is ignored, the others go through
    /// ``handleIncomingMessage(_:isSessionGenerating:admit:)`` with the
    /// channel's ``TelegramCompanionChannel/isSessionGenerating()``. Such a
    /// channel has no prompt queue, so a prompt that would be admitted is
    /// refused. ``readsIngress`` is `true` while it reads.
    func startConsuming() {
        guard ingressConsumerTask == nil else { return }
        readsIngress = true
        let messages = controlService.incomingMessages
        ingressConsumerTask = Task(name: "ZenCODE.Telegram.companion-ingress") { [weak self] in
            for await message in messages {
                guard !Task.isCancelled, let self else { return }
                await self.consumeIngressMessage(message)
            }
        }
    }

    /// Handles one message ``startConsuming()`` read.
    private func consumeIngressMessage(_ message: TerminalTelegramIncomingMessage) async {
        guard message.stoppedMessageGenerationDraftID == nil else { return }
        let isSessionGenerating = channel?.isSessionGenerating() ?? false
        _ = await handleIncomingMessage(
            message,
            isSessionGenerating: isSessionGenerating,
            admit: { _ in .refused }
        )
    }

    /// Stops what ``startConsuming()`` started and waits for the message in
    /// hand, if any. `shuttingDown` also ends every voice transcription for
    /// good, as the end of the terminal's panel loop does; a detach lets a
    /// later attach transcribe again. Without a consumer nothing changes.
    func stopConsuming(shuttingDown: Bool) async {
        guard let task = ingressConsumerTask else { return }
        ingressConsumerTask = nil
        task.cancel()
        await task.value
        readsIngress = false
        if shuttingDown {
            await cancelVoiceTranscriptions()
        }
    }

    // MARK: - Support

    /// Hands `text` to `admit` as a submitted line on `lease`, answering a
    /// full queue (the terminal's text, where `kind` names what was not
    /// queued) and a refusal in the chat. `true` when it was queued.
    private func admitLine(
        _ text: String,
        lease: TerminalTelegramRouteLease,
        kind: String,
        admit: (ChatQueuedPrompt<TerminalTelegramRouteLease>) -> TelegramPromptAdmission
    ) async -> Bool {
        let origin = TelegramTurnOrigin.telegram(lease)
        switch admit(ChatQueuedPrompt(text: text, origin: lease)) {
        case .queued:
            return true
        case .queueFull:
            await sendSystemMessageIfLinked(
                "ZenCODE is busy and the prompt queue is full. Your \(kind) was not queued; try again after a running prompt completes.",
                origin: origin
            )
            return false
        case .refused:
            await sendSystemMessageIfLinked(mirrorOnlyRefusalText, origin: origin)
            return false
        }
    }

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
            prompt, to: chatID, replyMarkup: .forceReply, origin: .telegram(lease)
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

    private func sendBusyMessage(origin: TelegramTurnOrigin) async {
        await sendSystemMessageIfLinked(Self.busyMessageText, origin: origin)
    }
}
