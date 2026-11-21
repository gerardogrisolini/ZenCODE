//
//  TelegramChannel+IngressMessages.swift
//  ZenCODE
//
//  One message read from the Telegram ingress, handled phase by phase
//  (callbacks, permission replies, pending readers, remote commands, the busy
//  gate, media, and text lines), with the dispatcher of the remote commands
//  and the ForceReply argument requests.
//

import Foundation
import ToolCore

extension TelegramChannel {
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
    /// (``pickAttachment(startingAt:)``) before anything else. A menu of the
    /// controller (``chooseOne(title:items:selectedID:)``,
    /// ``chooseMany(title:items:selectedIDs:)``) takes its taps, which go to
    /// ``handleChoiceMenuCallback(_:chatID:messageID:lease:)``
    /// (`TelegramChannel+ChoiceMenus.swift`) after the artifact consent taps
    /// and before the busy gate; while it waits, every other text, command,
    /// attachment, or voice note that is not a permission reply is answered
    /// with ``choicePendingText`` and does not run. While the session
    /// generates, only permission replies, `/status`, `/chat`, the slash
    /// forms of `/help` and `/changes`, the mention picker taps, the artifact
    /// consent taps, the controller menu taps, and the live shared-chat text
    /// lines (a live
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
    ///
    /// The precedence is the order of the phases below, each run after the
    /// one before it, with the session's state as it was read once the route
    /// was admitted (`isSessionGenerating`, `refusesAsBusy`): the callbacks
    /// (``handleCallback(_:queryID:message:lease:fence:isSessionGenerating:)``),
    /// a permission reply while the session generates, the questions of the
    /// controller (``handlePendingReaders(_:lease:isSessionGenerating:)``),
    /// the remote commands that run while it generates, the busy gate, the
    /// attachments and voice notes, and finally the text line
    /// (``handleTextLine(_:lease:)``), the only phase that admits a prompt.
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
        await followIngressRoute(routeLease)
        guard let ingressFence = wireFence(for: routeLease) else { return false }
        let isSessionGenerating = isSessionGenerating
        let refusesAsBusy = refusesMessagesAsBusy

        if let callbackQueryID = message.callbackQueryID,
           let callbackData = message.callbackData {
            await handleCallback(
                callbackData, queryID: callbackQueryID, message: message,
                lease: routeLease, fence: ingressFence,
                isSessionGenerating: isSessionGenerating
            )
            return false
        }
        if await handlePermissionReplyWhileGenerating(
            message, lease: routeLease, isSessionGenerating: isSessionGenerating
        ) == .handled {
            return false
        }
        if await handlePendingReaders(
            message, lease: routeLease, isSessionGenerating: isSessionGenerating
        ) == .handled {
            return false
        }
        if await handleRemoteCommandWhileGenerating(
            message, lease: routeLease, isSessionGenerating: isSessionGenerating
        ) == .handled {
            return false
        }
        if await handleBusyGate(message, lease: routeLease, refusesAsBusy: refusesAsBusy) == .handled {
            return false
        }
        if await handleMedia(message, lease: routeLease) == .handled {
            return false
        }
        return await handleTextLine(message, lease: routeLease)
    }

    /// What a phase of ``handleIncomingMessage(_:)`` did with the message.
    private enum IngressStep {
        /// The phase answered the message: nothing follows, and no prompt
        /// was admitted.
        case handled
        /// The phase let the message go on to the next one.
        case next
    }

    /// Where a callback goes once it is not an artifact consent tap
    /// (``callbackRoute(for:isSessionGenerating:)``).
    private enum CallbackRoute {
        /// A tap of a controller menu, which passes the busy gate.
        case choiceMenu
        /// Any other tap but the mention picker's while the session
        /// generates: the chat is told the session is busy.
        case busy
        /// A tap of a selection menu (`/models` `/think` `/agents`
        /// `/sessions`).
        case selectionMenu
        /// Every other tap: the mention picker's, which ignores data it does
        /// not know.
        case mentionPicker
    }

    /// Makes `lease`, the route that admitted a message, the link's route
    /// and the shared-chat relay's. In topic mode the link stays on the
    /// session's topic: a message from another route (General, or a topic no
    /// route knows) is answered where it came from without moving the relay
    /// or the next turn off the topic.
    private func followIngressRoute(_ lease: TerminalTelegramRouteLease) async {
        guard sessionTopic.map({ $0.lease.key.topicID == lease.key.topicID }) ?? true else { return }
        let hadRouteLease = activeRouteLease != nil
        activeRouteLease = lease
        // The relay follows the session's room whatever route admitted the
        // message: the shared route (`default`) serves every room, and a
        // relay bound to its own room would drop every batch of the session.
        await activateSharedChatRelay(roomID: sessionID, lease: lease)
        await activeRouteLeaseDidChange(hadLease: hadRouteLease)
    }

    // MARK: - Ingress phases

    /// Answers the callback query `queryID` and handles its `data`: an
    /// artifact consent tap first, then the route
    /// ``callbackRoute(for:isSessionGenerating:)`` gives it.
    private func handleCallback(
        _ data: String,
        queryID: String,
        message: TerminalTelegramIncomingMessage,
        lease: TerminalTelegramRouteLease,
        fence: TerminalTelegramWireFence,
        isSessionGenerating: Bool
    ) async {
        await controlService.answerCallbackQuery(queryID, chatID: message.chatID, fence: fence)
        if await handleArtifactConsentCallback(data, message: message, lease: lease) {
            return
        }
        switch Self.callbackRoute(for: data, isSessionGenerating: isSessionGenerating) {
        case .choiceMenu:
            await handleChoiceMenuCallback(
                data, chatID: message.chatID, messageID: message.messageID, lease: lease
            )
        case .busy:
            await sendBusyMessage(lease: lease)
        case .selectionMenu:
            await handleSelectionMenuCallback(
                data, chatID: message.chatID, messageID: message.messageID, lease: lease
            )
        case .mentionPicker:
            await handleMentionPickerCallback(data, chatID: message.chatID, lease: lease)
        }
    }

    /// Where a tap with `data` goes once it is not an artifact consent tap:
    /// a controller menu may wait while a turn runs, so its taps pass the
    /// busy gate, and so do the mention picker's; while the session
    /// generates every other tap is told the session is busy.
    private nonisolated static func callbackRoute(
        for data: String,
        isSessionGenerating: Bool
    ) -> CallbackRoute {
        if data.hasPrefix(choiceMenuCallbackPrefix) {
            return .choiceMenu
        }
        guard !isSessionGenerating || data.hasPrefix(mentionPickerCallbackPrefix) else {
            return .busy
        }
        return isSelectionMenuCallback(data) ? .selectionMenu : .mentionPicker
    }

    /// A permission reply while the session generates. Owner resolution,
    /// lease capture and the wire fence stay above the gate; the gate
    /// rejects before attachment downloads, voice transcription, or command
    /// parsing. Permission replies remain live because an active turn may be
    /// blocked waiting for exactly this operator decision.
    private func handlePermissionReplyWhileGenerating(
        _ message: TerminalTelegramIncomingMessage,
        lease: TerminalTelegramRouteLease,
        isSessionGenerating: Bool
    ) async -> IngressStep {
        guard isSessionGenerating,
              let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              TerminalTelegramPermissionBroker.permissionCommand(from: text) != nil,
              await handlePermissionReplyIfNeeded(text, lease: lease) else {
            return .next
        }
        return .handled
    }

    /// The questions of the controller waiting for the next message, before
    /// the busy gate: the session waits for exactly this answer. A menu
    /// waiting for a tap takes precedence over every other message, a
    /// permission reply excepted: nothing else runs until it is answered.
    /// Then a question for an attachment takes a document or image, and a
    /// question for a line takes a text message.
    private func handlePendingReaders(
        _ message: TerminalTelegramIncomingMessage,
        lease: TerminalTelegramRouteLease,
        isSessionGenerating: Bool
    ) async -> IngressStep {
        if pendingChoiceReader != nil {
            let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty || message.attachment != nil || message.voice != nil else {
                return .handled
            }
            if !isSessionGenerating, message.attachment == nil, message.voice == nil,
               TerminalTelegramPermissionBroker.permissionCommand(from: text) != nil,
               await handlePermissionReplyIfNeeded(text, lease: lease) {
                return .handled
            }
            await sendSystemMessageIfLinked(Self.choicePendingText, lease: lease)
            return .handled
        }
        if let attachment = message.attachment, pendingAttachmentReader != nil {
            await handleInboundAttachment(attachment, message: message, lease: lease)
            return .handled
        }
        if pendingLineReader != nil, message.attachment == nil, message.voice == nil,
           let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           deliverPendingLine(text, lease: lease) {
            return .handled
        }
        return .next
    }

    /// The remote commands that run while the session generates
    /// (``remoteCommandWhileGenerating(in:)``).
    private func handleRemoteCommandWhileGenerating(
        _ message: TerminalTelegramIncomingMessage,
        lease: TerminalTelegramRouteLease,
        isSessionGenerating: Bool
    ) async -> IngressStep {
        guard isSessionGenerating,
              let command = Self.remoteCommandWhileGenerating(in: message.text) else {
            return .next
        }
        await runRemoteCommand(command, lease: lease, chatID: message.chatID)
        return .handled
    }

    /// The remote command a message with `text` runs while the session
    /// generates: `/status` and `/chat`, the slash forms of `/help` and
    /// `/changes`, each without an argument; `nil` for anything else.
    private nonisolated static func remoteCommandWhileGenerating(
        in text: String?
    ) -> TerminalTelegramRemoteCommand? {
        guard let commandText = text.map(commandWithoutBotMention),
              let invocation = TerminalTelegramRemoteCommand.invocation(text: commandText),
              invocation.argument.isEmpty else {
            return nil
        }
        let isSlash = CoordinatorCommandParser.isSlashCommand(commandText)
        switch invocation.command {
        case .status, .chat:
            return invocation.command
        case .help where isSlash:
            return invocation.command
        case .changes where isSlash:
            return invocation.command
        default:
            return nil
        }
    }

    /// The busy gate. The live shared-chat text lines pass it, because the
    /// agents they address exist while the turn runs; text only: a voice
    /// note quoting a card would need the transcription the gate refuses,
    /// and an attachment never addresses a participant. Everything else is
    /// told the session is busy.
    private func handleBusyGate(
        _ message: TerminalTelegramIncomingMessage,
        lease: TerminalTelegramRouteLease,
        refusesAsBusy: Bool
    ) async -> IngressStep {
        if refusesAsBusy, message.attachment == nil, message.voice == nil,
           let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           await handleLiveSharedChatLineWhileBusy(text, message: message, lease: lease) {
            return .handled
        }
        guard !refusesAsBusy else {
            await sendBusyMessage(lease: lease)
            return .handled
        }
        return .next
    }

    /// An attachment, then a voice note.
    private func handleMedia(
        _ message: TerminalTelegramIncomingMessage,
        lease: TerminalTelegramRouteLease
    ) async -> IngressStep {
        if let attachment = message.attachment {
            await handleInboundAttachment(attachment, message: message, lease: lease)
            return .handled
        }
        guard let voice = message.voice else { return .next }
        // A voice note that quotes an answerable card is ambiguous: the
        // reply target cannot be carried through transcription, so direct
        // replies are text-only. Quoting a card that routes nowhere is not
        // a direct reply and keeps the ordinary voice-prompt path.
        if await directReplyTarget(for: message) != nil {
            await sendSystemMessageIfLinked(
                "ZenCODE message: replies to a live message must be text. Send your answer as text, or record a voice note without replying to run it as an ordinary prompt.",
                lease: lease
            )
            return .handled
        }
        await handleVoiceMessage(voice, lease: lease)
        return .handled
    }

    /// A text line: a permission reply, the remote commands answered before
    /// the queue (``remoteCommandBeforeTheQueue(in:)``), a bare coordinator
    /// command asking for its argument, the reply that completes one, a
    /// reply to a live card, and otherwise a prompt admitted to the queue.
    /// Returns whether a prompt was admitted.
    private func handleTextLine(
        _ message: TerminalTelegramIncomingMessage,
        lease: TerminalTelegramRouteLease
    ) async -> Bool {
        let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return false }

        if await handlePermissionReplyIfNeeded(text, lease: lease) {
            return false
        }

        let commandText = Self.commandWithoutBotMention(text)
        if let command = Self.remoteCommandBeforeTheQueue(in: commandText) {
            await runRemoteCommand(command, lease: lease, chatID: message.chatID)
            return false
        }

        if let coordinatorCommand = CoordinatorCommandParser.parse(commandText),
           coordinatorCommand.requiresArgument {
            await requestCommandArgument(commandText, chatID: message.chatID, lease: lease)
            return false
        }

        if let completedCommand = consumeCommandArgumentReply(from: message, lease: lease) {
            return await admitPrompt(completedCommand, lease: lease, kind: "command")
        }

        // A reply to a forwarded live-message card answers its sender
        // directly. Remote commands and explicit `@mention` routing keep
        // precedence, so quoting a card never changes what an explicitly
        // addressed line means.
        if await replyRoutingHasPrecedence(over: text) == false,
           await handleSharedChatReplyIfNeeded(text, message: message, lease: lease) {
            return false
        }

        guard (try? await router.validate(lease)) != nil else { return false }
        return await admitPrompt(text, lease: lease, kind: "prompt")
    }

    /// The remote command the ingress answers before the prompt queue, for
    /// the line `commandText` (without its `@botname`): `/start`, and `/chat`
    /// without an argument. They must work even when the queue is full and
    /// must never be consumed as the argument of a pending ForceReply
    /// command request. `/chat <text>` goes on to the queued path, which
    /// rejects the argument.
    private nonisolated static func remoteCommandBeforeTheQueue(
        in commandText: String
    ) -> TerminalTelegramRemoteCommand? {
        switch TerminalTelegramRemoteCommand.invocation(text: commandText) {
        case (.start, _)?:
            return .start
        case let (.chat, argument)? where argument.isEmpty:
            return .chat
        default:
            return nil
        }
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

    // MARK: - Remote commands

    /// Answers the remote `command` in the chat on `lease`: `/start`,
    /// `/help`, `/status`, `/changes` and `/undo` with their text, `/chat`
    /// with the mention picker sent to `chatID`, `/sessions`, `/models`,
    /// `/think` and `/agents` with their selection menu, and `/diff` with the
    /// session's diff. The one dispatcher of the remote commands: the
    /// ingress while the session generates
    /// (``remoteCommandWhileGenerating(in:)``), the ingress before the queue
    /// (``remoteCommandBeforeTheQueue(in:)``), and ``lineAction(for:lease:)``
    /// each decide which commands they run.
    func runRemoteCommand(
        _ command: TerminalTelegramRemoteCommand,
        lease: TerminalTelegramRouteLease,
        chatID: Int64
    ) async {
        switch command {
        case .start:
            await sendSystemMessageIfLinked(alreadyLinkedText, lease: lease)
        case .help:
            await sendSystemMessageIfLinked(remoteHelpText(), lease: lease)
        case .status:
            await sendSystemMessageIfLinked(remoteStatusText(), lease: lease)
        case .chat:
            await handleMentionPickerRequest(chatID: chatID, lease: lease)
        case .sessions:
            await handleSessionsMenuRequest(lease: lease)
        case .models:
            await handleModelsMenuRequest(lease: lease)
        case .think:
            await handleThinkMenuRequest(lease: lease)
        case .agents:
            await handleAgentsMenuRequest(lease: lease)
        case .changes:
            await sendSystemMessageIfLinked(remoteChangesText(), lease: lease)
        case .undo:
            await sendSystemMessageIfLinked(undoText, lease: lease)
        case .diff:
            await handleDiffRequest(lease: lease)
        }
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
}
