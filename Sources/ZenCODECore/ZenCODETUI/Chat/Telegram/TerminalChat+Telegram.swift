//
//  TerminalChat+Telegram.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation
import ToolCore

private enum TerminalTelegramAuthorizationChannelResult: Sendable {
    case terminal(LocalExecPermissionAuthorizer.AuthorizationOutcome)
    case telegram(TerminalTelegramPermissionOutcome)
}

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

    func submittedTelegramLineAction(
        _ prompt: String,
        chatID: Int64? = nil
    ) async -> TerminalSubmittedLineAction {
        let prompt = Self.telegramCommandWithoutBotMention(prompt)
        switch TerminalTelegramRemoteCommand(text: prompt) {
        case .start:
            await sendTelegramSystemMessageIfLinked(
                "Telegram is already linked to this ZenCODE session. Send a prompt or /help."
            )
            return .continueChat
        case .help:
            await sendTelegramSystemMessageIfLinked(telegramRemoteHelpText())
            return .continueChat
        case .status:
            await sendTelegramSystemMessageIfLinked(telegramRemoteStatusText())
            return .continueChat
        case .changes:
            await sendTelegramSystemMessageIfLinked(telegramRemoteChangesText())
            return .continueChat
        case .undo:
            await sendTelegramSystemMessageIfLinked(
                "Use /undo in the TUI to revert file changes."
            )
            return .continueChat
        case .none:
            switch Self.parseSharedChatMention(
                from: prompt,
                readableHandles: await sessionRunner.sharedChatMentionHandles(
                    rootSessionID: sessionID
                )
            ) {
            case let .route(sharedChatRoute):
                await sendSharedChatMention(
                    sharedChatRoute,
                    telegramChatID: chatID
                )
                return .continueChat
            case .missingText:
                await sendTelegramSystemMessageIfLinked(
                    "ZenCODE message: add a message after the live mention."
                )
                return .continueChat
            case .none:
                break
            }

            if let coordinatorCommand = CoordinatorCommandParser.parse(prompt) {
                telegramImmediateCommandOutput = []
                let action: TerminalSubmittedLineAction = switch coordinatorCommand {
                case .plan:
                    await handlePlanCommand(prompt)
                case .goal:
                    await handleWorkflowCommand(prompt)
                case .review:
                    await handleReviewCommand(prompt)
                }
                let output = telegramImmediateCommandOutput?.joined(separator: "\n").nilIfBlank
                telegramImmediateCommandOutput = nil
                if case .continueChat = action, let output {
                    await sendTelegramSystemMessageIfLinked(output)
                }
                return action
            }
            if !CoordinatorCommandParser.isSlashCommand(prompt),
               let action = handlePlanBrainstormingReply(prompt) {
                return action
            }
            // Same cross-surface rule as the TUI: a plain Telegram message
            // continues the open `/goal` workflow while the coordinator is
            // explicitly waiting for the user.
            if !CoordinatorCommandParser.isSlashCommand(prompt),
               let action = await handleWorkflowContinuationReply(prompt) {
                return action
            }
            return .runPrompt(prompt)
        }
    }

    nonisolated static func telegramCommandWithoutBotMention(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(where: \.isWhitespace) else {
            guard trimmed.first == "/", let at = trimmed.firstIndex(of: "@") else { return trimmed }
            return String(trimmed[..<at])
        }
        let token = trimmed[..<separator]
        guard token.first == "/", let at = token.firstIndex(of: "@") else { return trimmed }
        return String(token[..<at]) + trimmed[separator...]
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

    /// Single production entry point for one Telegram message that the runtime
    /// loop dequeued. Interactive and non-interactive consumers dispatch
    /// through this method so ingress filtering, prompt routing and queued
    /// prompt admission are exercised identically by the TUI loop and by any
    /// other runtime that consumes the same event queue.
    ///
    /// Returns `true` when this message actually queued a prompt. The caller
    /// reacts only after this method returns so the exclusive `inout` access to
    /// `queuedPrompts` has ended; invoking a callback that reads the same buffer
    /// from inside this method would trigger Swift's runtime exclusivity trap.
    /// The queued prompt itself is never removed here; admission of queued
    /// prompts stays with the consumer, exactly as `startNextQueuedPrompt`
    /// does for the interactive loop.
    func handleTelegramRuntimeMessage(
        _ message: TerminalTelegramIncomingMessage,
        eventQueue: TerminalChatEventQueue,
        queuedPrompts: inout TerminalQueuedPromptBuffer,
        transcriptions: TerminalVoiceTranscriptionRegistry
    ) async -> Bool {
        let countBefore = queuedPrompts.count
        await handleTelegramMessage(
            message,
            queuedPrompts: &queuedPrompts,
            eventQueue: eventQueue,
            transcriptions: transcriptions
        )
        return queuedPrompts.count > countBefore
    }

    func handleTelegramMessage(
        _ message: TerminalTelegramIncomingMessage,
        queuedPrompts: inout TerminalQueuedPromptBuffer,
        eventQueue: TerminalChatEventQueue,
        transcriptions: TerminalVoiceTranscriptionRegistry
    ) async {
        guard telegramControlState.isActive else {
            return
        }

        guard telegramLinkedChatID != nil else {
            await sendTelegramSystemMessage(
                "Telegram is not paired. Run the /setup command in zen to pair this bot.",
                to: message.chatID
            )
            return
        }

        guard telegramLinkedChatID == message.chatID else {
            await sendTelegramSystemMessage(
                "This bot is already linked to another ZenCODE session.",
                to: message.chatID
            )
            return
        }

        if let callbackQueryID = message.callbackQueryID,
           let callbackData = message.callbackData {
            await telegramControlService.answerCallbackQuery(callbackQueryID)
            await handleTelegramMentionPickerCallback(callbackData, chatID: message.chatID)
            return
        }

        if let voice = message.voice {
            // A voice note that quotes an *answerable* card is ambiguous: the
            // reply target cannot be carried through transcription and
            // revalidated at completion, so direct replies are text-only by
            // contract. Refusing is the only unambiguous option; silently
            // transcribing it would turn a message meant for one participant
            // into a root prompt.
            //
            // Quoting a card that routes nowhere (the operator's own mirrored
            // traffic) is not a direct reply at all, so it must keep the
            // ordinary voice-prompt path instead of being refused.
            if await telegramDirectReplyTarget(for: message) != nil {
                await sendTelegramSystemMessage(
                    "ZenCODE message: replies to a live message must be text. Send your answer as text, or record a voice note without replying to run it as an ordinary prompt.",
                    to: message.chatID
                )
                return
            }
            await handleTelegramVoiceMessage(
                voice,
                chatID: message.chatID,
                eventQueue: eventQueue,
                transcriptions: transcriptions
            )
            return
        }

        let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }

        if await handleTelegramPermissionResponseIfNeeded(text, chatID: message.chatID) {
            return
        }

        if TerminalTelegramRemoteCommand(text: text) == .start {
            await sendTelegramSystemMessage(
                "Telegram is already linked to this ZenCODE session. Send a prompt or /help.",
                to: message.chatID
            )
            return
        }

        if text == "@" {
            await handleTelegramMentionPickerRequest(chatID: message.chatID)
            return
        }

        // A reply to a forwarded live-message card answers its sender directly.
        // Remote commands and explicit `@mention` routing keep precedence, so
        // quoting a card never changes what an explicitly addressed line means.
        // Precedence is decided by the parsers that actually own those routes:
        // any slash line stays reserved for commands exactly as in the
        // submitted-line path, while a leading `@` only wins when the mention
        // really resolves — `@nobody hi` is ordinary text and stays replyable.
        if await telegramReplyRoutingHasPrecedence(over: text) == false,
           await handleTelegramSharedChatReplyIfNeeded(text, message: message) {
            return
        }

        guard queuedPrompts.enqueue(
            TerminalQueuedPrompt(text: text, origin: .telegram(chatID: message.chatID))
        ) else {
            await sendTelegramSystemMessage(
                "ZenCODE is busy and the prompt queue is full. Your prompt was not queued; try again after a running prompt completes.",
                to: message.chatID
            )
            return
        }
    }

    // MARK: - Mention picker

    nonisolated static let telegramMentionPickerCallbackPrefix = "zencode:mention:"

    /// The Telegram Bot API has no typing events. A standalone `@` is therefore
    /// the explicit, non-ambiguous trigger for the discoverable mention picker.
    func handleTelegramMentionPickerRequest(chatID: Int64) async {
        let buttons = Self.telegramMentionPickerButtons(
            from: await sharedChatMentionSuggestions()
        )
        guard !buttons.isEmpty else { return }
        let markup = TerminalTelegramReplyMarkup.inlineKeyboard(buttons.map { [$0] })
        _ = await sendTelegramMentionPickerMessage(
            "Choose who to message. After selecting, reply to the next card with your message.",
            to: chatID,
            replyMarkup: markup
        )
    }

    nonisolated static func telegramMentionPickerButtons(
        from suggestions: [TerminalCommandSuggestion]
    ) -> [TerminalTelegramInlineKeyboardButton] {
        suggestions.compactMap { suggestion in
            let handle = suggestion.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard handle.first == "@", handle != "@all", handle.utf8.count <= 48 else { return nil }
            return TerminalTelegramInlineKeyboardButton(
                text: handle,
                callbackData: telegramMentionPickerCallbackPrefix + String(handle.dropFirst())
            )
        }
    }

    func handleTelegramMentionPickerCallback(_ data: String, chatID: Int64) async {
        guard data.hasPrefix(Self.telegramMentionPickerCallbackPrefix) else { return }
        let handle = String(data.dropFirst(Self.telegramMentionPickerCallbackPrefix.count))
        guard handle.utf8.count <= 48 else { return }
        let roster = await sessionRunner.sharedChatMentionRoster(rootSessionID: sessionID)
        guard case let .route(route) = Self.parseSharedChatMention(
            from: "@\(handle) selected",
            readableHandles: roster.handleMap
        ), await isCurrentSharedChatDirectDestination(route.destination) else {
            await sendTelegramSystemMessage("ZenCODE message: that agent is no longer active. Open `@` again.", to: chatID)
            return
        }
        let receipt = await sendTelegramMentionPickerMessage(
            "Writing to @\(handle). Reply to this message with the content to send; it will not be treated as a normal prompt.",
            to: chatID,
            replyMarkup: .forceReply
        )
        guard let receipt else { return }
        await telegramSharedChatRelay.registerReplyTarget(
            Self.telegramMentionPickerReplyTarget(
                destination: route.destination, roomID: sessionID, chatID: chatID, handle: handle
            ),
            forTelegramMessageID: receipt
        )
    }

    private func sendTelegramMentionPickerMessage(
        _ text: String, to chatID: Int64, replyMarkup: TerminalTelegramReplyMarkup
    ) async -> Int? {
        if let hook = onTelegramMentionPickerMessage { return await hook(text, chatID, replyMarkup) }
        do { return try await telegramControlService.sendPlainMessageWithReceipt(text, to: chatID, replyMarkup: replyMarkup) }
        catch { telegramControlState.lastError = error.localizedDescription; return nil }
    }

    nonisolated static func telegramMentionPickerReplyTarget(
        destination: AgentSharedChat.Destination, roomID: String, chatID: Int64, handle: String
    ) -> TerminalTelegramSharedChatReplyTarget {
        let senderID: String
        let senderKind: AgentSharedChat.ParticipantKind
        let senderName: String
        switch destination {
        case let .direct(ids):
            senderID = ids.first ?? ""
            senderKind = .agent
            senderName = handle
        case .coordinator:
            senderID = AgentSharedChat.coordinatorID(for: roomID)
            senderKind = .coordinator
            senderName = "coordinator"
        case .all, .operator, .peers:
            // These are excluded from the picker because force-reply is direct.
            senderID = ""
            senderKind = .operator
            senderName = handle
        }
        return TerminalTelegramSharedChatReplyTarget(
            roomID: roomID, chatID: chatID, sharedChatMessageID: UUID(),
            senderID: senderID, senderKind: senderKind, senderName: senderName
        )
    }

    // MARK: - Live-message relay

    /// Reports whether `text` is already claimed by a higher-precedence route, in
    /// which case quoting a card must not change its meaning.
    ///
    /// The decision uses the real parsers: ``TerminalTelegramRemoteCommand`` for
    /// remote commands, ``CoordinatorCommandParser`` for slash commands and the
    /// actual ``parseSharedChatMention(from:readableHandles:)`` outcome for
    /// mentions — including `missingText`, which is a recognised mention whose
    /// diagnostic must not be replaced by a reply. A leading `@` that resolves to
    /// nothing is not a mention, so it does not suppress the reply route.
    func telegramReplyRoutingHasPrecedence(over text: String) async -> Bool {
        if TerminalTelegramRemoteCommand(text: text) != nil {
            return true
        }
        if CoordinatorCommandParser.isSlashCommand(text) {
            return true
        }
        switch Self.parseSharedChatMention(
            from: text,
            readableHandles: await sessionRunner.sharedChatMentionHandles(
                rootSessionID: sessionID
            )
        ) {
        case .route, .missingText:
            return true
        case .none:
            return false
        }
    }

    /// Offers one shared-chat observer batch to the Telegram relay.
    ///
    /// The TUI's single observation stays the only subscriber; the relay owns its
    /// own delivery ledger, so the terminal reader buffer (which is rebuilt on a
    /// forced reattach) can never be mistaken for a "already sent" record.
    func forwardSharedChatMessagesToTelegram(
        _ messages: [AgentSharedChat.Message],
        roomID: String
    ) async {
        guard telegramControlState.isActive, telegramLinkedChatID != nil else {
            return
        }
        let roster = await sessionRunner.sharedChatMentionRoster(rootSessionID: roomID)
        await telegramSharedChatRelay.forward(
            messages,
            roomID: roomID,
            participants: roster.participants
        )
    }

    /// Follows a room swap (`/new`, `/resume`, observation restart). A new room
    /// invalidates the ledger and the receipt map: identifiers of a retired room
    /// must never route a reply into the live one.
    func rebindTelegramSharedChatRelay(roomID: String) async {
        guard telegramControlState.isActive,
              let chatID = telegramLinkedChatID else {
            await telegramSharedChatRelay.deactivate()
            return
        }
        await telegramSharedChatRelay.activate(
            roomID: roomID,
            chatID: chatID,
            repliesEnabled: readsTelegramIngress
        )
    }

    /// Delivers one relay card as plain text and returns its Telegram receipt.
    ///
    /// A failure is recorded on the control state but never written to the
    /// terminal: cards are asynchronous notifications, and a transient Telegram
    /// error must not inject noise into the operator's transcript.
    func sendTelegramSharedChatCard(_ text: String, to chatID: Int64) async -> Int? {
        guard telegramControlState.isActive,
              telegramLinkedChatID == chatID else {
            return nil
        }
        do {
            return try await telegramControlService.sendPlainMessageWithReceipt(
                text,
                to: chatID
            )
        } catch {
            telegramControlState.lastError = error.localizedDescription
            return nil
        }
    }

    /// Resolves the participant a Telegram reply addresses, or `nil` when the
    /// quoted message is not an answerable card of the live room.
    ///
    /// Single source of truth for "this message is a direct reply": the text
    /// route and the voice-note guard must agree, otherwise a message could be
    /// refused as a reply on one path and treated as an ordinary prompt on the
    /// other. A card whose sender has no live destination — the operator's own
    /// mirrored traffic — is deliberately not one, so answering it by voice or by
    /// text simply prompts the session as usual.
    func telegramDirectReplyTarget(
        for message: TerminalTelegramIncomingMessage
    ) async -> TerminalTelegramSharedChatReplyTarget? {
        guard let replyToMessageID = message.replyToMessageID,
              let target = await telegramSharedChatRelay.replyTarget(
                  forTelegramMessageID: replyToMessageID,
                  chatID: message.chatID
              ),
              target.roomID == sessionID,
              target.replyDestination != nil else {
            return nil
        }
        return target
    }

    /// Routes a Telegram reply back to the participant that produced the quoted
    /// card. Returns `true` when the message was consumed as a live reply.
    ///
    /// The destination comes only from the relay's local receipt map and the
    /// stable sender id it recorded, never from the quoted text: Telegram echoes
    /// user-controlled content in `reply_to_message`, which must not be able to
    /// address an arbitrary participant. When the quoted card is unknown the
    /// message falls through to the ordinary prompt path.
    func handleTelegramSharedChatReplyIfNeeded(
        _ text: String,
        message: TerminalTelegramIncomingMessage
    ) async -> Bool {
        guard let target = await telegramDirectReplyTarget(for: message),
              let destination = target.replyDestination else {
            return false
        }

        // The sender may have finished since its card was delivered. Fail loudly
        // instead of silently turning the reply into a root prompt: the operator
        // explicitly addressed one participant.
        guard await isCurrentSharedChatDirectDestination(destination) else {
            await sendTelegramSystemMessage(
                "ZenCODE message: that agent is no longer active, so the reply was not delivered.",
                to: message.chatID
            )
            return true
        }

        do {
            _ = try await sessionRunner.sendSharedChatMessage(
                text: text,
                destination: destination,
                rootSessionID: target.roomID
            )
            await refreshSharedChatPanelSuggestions()
        } catch {
            let safeError = Self.sharedChatInlineTerminalSafeText(error.localizedDescription)
            await sendTelegramSystemMessage(
                "ZenCODE message: \(safeError)",
                to: message.chatID
            )
        }
        return true
    }

    func handleTelegramVoiceMessage(
        _ voice: TerminalTelegramVoiceAttachment,
        chatID: Int64,
        eventQueue: TerminalChatEventQueue,
        transcriptions: TerminalVoiceTranscriptionRegistry
    ) async {
        guard isVoiceConfigured() else {
            await sendTelegramSystemMessage(
                "Voice-message transcription is not configured. Run the /setup command in zen and enable voice-message transcription.",
                to: chatID
            )
            return
        }

        // Bounded ownership: a burst of voice notes must not start an unbounded
        // number of concurrent downloads and transcriptions, and every started
        // task must be cancellable at teardown.
        guard let slot = transcriptions.reserveSlot() else {
            await sendTelegramSystemMessage(
                "Too many voice messages are being transcribed. Try again shortly.",
                to: chatID
            )
            return
        }

        let task = Task(name: "ZenCODE.Telegram.voice-transcription") { [weak self] in
            defer { transcriptions.release(slot) }
            guard let self else { return }
            do {
                let audio = try await self.telegramControlService.downloadVoiceAudio(voice)
                try Task.checkCancellation()
                let transcript = try await AgentVoiceTranscriptionService()
                    .transcribe(audio)
                guard await eventQueue.sendWithBackpressure(
                    .voicePromptCompleted(
                        TerminalVoicePromptResult(
                            origin: .telegram(chatID: chatID),
                            outcome: .success(transcript)
                        )
                    )
                ) else {
                    return
                }
            } catch is CancellationError {
                // Teardown or an explicit cancel: the runtime loop is gone, so
                // no completion event is reported.
                return
            } catch {
                guard await eventQueue.sendWithBackpressure(
                    .voicePromptCompleted(
                        TerminalVoicePromptResult(
                            origin: .telegram(chatID: chatID),
                            outcome: .failure(error.localizedDescription)
                        )
                    )
                ) else {
                    return
                }
            }
        }
        transcriptions.register(task, for: slot)
    }

    func writeTelegramSubmittedPrompt(_ prompt: String) async {
        let title = telegramLinkedChatTitle?.nilIfBlank ?? "Telegram"
        await writeSystemMessage("\n\(title) sent a prompt:\n")
        await writeSubmittedPrompt(prompt)
    }

    func startTelegramControl() async {
        guard stdinIsTerminal else {
            await writeFailureMessage("ZenCODE: /telegram requires the interactive TUI.\n")
            return
        }
        guard isTelegramConfigured() else {
            await writeFailureMessage(Self.unknownCommandMessage(for: "/telegram"))
            return
        }
        guard let settings = AgentSettingsManifestStore.load()?.telegram,
              let linkedChatID = settings.linkedChatID else {
            await writeFailureMessage("ZenCODE: Telegram is not paired. Run the /setup command in zen.\n")
            return
        }

        do {
            telegramLinkedChatID = linkedChatID
            telegramLinkedChatTitle = settings.linkedChatTitle
            telegramControlState = try await telegramControlService.start()
            // Bind the shared-chat relay to the live room. Re-enabling Telegram
            // for the same room and chat keeps the delivery ledger, so already
            // forwarded messages are not sent again.
            await telegramSharedChatRelay.activate(
                roomID: sessionID,
                chatID: linkedChatID,
                repliesEnabled: readsTelegramIngress
            )
            synchronizeTelegramTurnProgressReporting()
            let chatTitle = telegramLinkedChatTitle?.nilIfBlank ?? "chat \(linkedChatID)"
            await writeSystemMessage(
                """
                Telegram remote control is active.
                Linked chat: \(chatTitle)

                """
            )
            let activationMessage = activeTelegramTurnOrigin == nil
                ? "ZenCODE remote control is active. Send a prompt or /help to begin."
                : "ZenCODE remote control is active. The current ZenCODE request is now being mirrored."
            await sendTelegramSystemMessage(activationMessage, to: linkedChatID)
            if !readsTelegramIngress {
                // The blocking input fallback has no Telegram ingress consumer.
                // Say so instead of leaving the operator waiting for an answer
                // that this session will never read.
                await sendTelegramSystemMessage(
                    "ZenCODE message: this session runs the terminal fallback input loop and does not read Telegram messages. Live messages are still forwarded here, but prompts and replies must be typed in the terminal.",
                    to: linkedChatID
                )
            }
        } catch {
            telegramControlState = await telegramControlService.currentState()
            telegramControlState.lastError = error.localizedDescription
            synchronizeTelegramTurnProgressReporting()
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    func stopTelegramControl() async {
        // Disconnect the current turn before hopping to the service actor, so
        // events emitted while `stop()` is in flight cannot enqueue more output.
        telegramControlState.isActive = false
        synchronizeTelegramTurnProgressReporting()
        // Unbind before stopping the transport so no card is queued for a chat
        // that is about to be released. The ledger is retained on purpose.
        await telegramSharedChatRelay.deactivate()
        telegramControlState = await telegramControlService.stop()
        telegramLinkedChatID = nil
        telegramLinkedChatTitle = nil
        await writeSystemMessage("Telegram remote control stopped.\n")
    }

    func printTelegramStatus() async {
        telegramControlState = await telegramControlService.currentState()
        await writeSystemMessage(telegramStatusText() + "\n")
    }

    /// Starts tracking a turn even when Telegram is currently disabled. Keeping
    /// the origin lets `/telegram on` attach a reporter to an already-running
    /// local request; previously the reporter was a one-time snapshot created at
    /// turn start, so enabling Telegram mid-turn had no effect.
    func beginTelegramTurnProgressReporting(for origin: TerminalPromptOrigin) async {
        activeTelegramProgressReporter = nil
        activeTelegramTurnOrigin = origin
        resetTelegramRootResponseBlock()
        resetMirroredOverviewSignatures()
        // Fence off any undelivered mirror notification from the previous
        // turn before the new turn's reporter exists: stale-epoch deliveries
        // are discarded instead of being adopted by the new reporter.
        currentTelegramMirrorEpoch = await renderCoordinator.advanceMirrorEpoch()
        synchronizeTelegramTurnProgressReporting()
    }

    /// Reconciles the current turn with the latest Telegram on/off state.
    /// Existing reporters are retained for the same chat so queued messages keep
    /// their ordering across a repeated `/telegram on`.
    ///
    /// Turning Telegram off drops the reporter together with the root response
    /// text it had aggregated; turning it back on starts a new, empty channel.
    /// A response block that was already streaming across such a transition is
    /// therefore suppressed, so the remote chat never receives a fragment whose
    /// beginning it could not see, nor a replay of text produced while off.
    func synchronizeTelegramTurnProgressReporting() {
        guard let origin = activeTelegramTurnOrigin,
              let chatID = telegramOutgoingChatID(for: origin) else {
            if activeTelegramProgressReporter != nil {
                suppressTelegramRootResponseBlockIfStreaming()
            }
            activeTelegramProgressReporter = nil
            return
        }
        guard activeTelegramProgressReporter?.chatID != chatID else {
            return
        }
        suppressTelegramRootResponseBlockIfStreaming()
        activeTelegramProgressReporter = makeTelegramTurnProgressReporter(for: origin)
    }

    func endTelegramTurnProgressReporting() {
        activeTelegramProgressReporter = nil
        activeTelegramTurnOrigin = nil
        resetTelegramRootResponseBlock()
    }

    // MARK: - Root response mirroring

    /// Aggregates one visible root response delta for the linked chat.
    ///
    /// Deltas are buffered by the turn reporter and published as a single
    /// message at the next tool boundary; nothing is sent while the response is
    /// still streaming.
    func appendTelegramRootResponseDelta(_ delta: String) async {
        guard !delta.isEmpty else {
            return
        }
        telegramRootResponseBlockHasContent = true
        guard !telegramRootResponseBlockIsSuppressed,
              let reporter = activeTelegramProgressReporter else {
            return
        }
        await reporter.appendAgentResponseDelta(delta)
    }

    /// Publishes the aggregated root response at a tool-call boundary.
    ///
    /// The boundary proves the response complete: the model stopped writing and
    /// started a tool. The overview barrier runs first so sub-agent and Task
    /// sections already rendered enter the ordered channel ahead of this
    /// response instead of being overtaken by it.
    func publishTelegramRootResponseAtToolBoundary() async {
        let wasSuppressed = telegramRootResponseBlockIsSuppressed
        telegramRootResponseBlockHasContent = false
        telegramRootResponseBlockIsSuppressed = false
        guard let reporter = activeTelegramProgressReporter else {
            return
        }
        guard !wasSuppressed else {
            await reporter.discardPendingAgentResponse()
            return
        }
        guard await reporter.hasPendingAgentResponse else {
            return
        }
        await renderCoordinator.waitForOverviewMirrorsToDrain()
        guard let current = activeTelegramProgressReporter,
              current === reporter else {
            // Telegram was turned off while the barrier was draining; the
            // buffered text belongs to a channel that no longer exists.
            return
        }
        if await current.publishPendingAgentResponseAtBoundary() {
            telegramDidPublishIntermediateRootResponse = true
        }
    }

    /// Returns the text to mirror as the turn's final response.
    ///
    /// A turn's response text accumulates every assistant block it produced,
    /// including the intermediate responses already mirrored at their tool
    /// boundaries. Mirroring it verbatim would repeat them, so once such a
    /// response was published the trailing block aggregated since the last
    /// boundary — the final response itself — is mirrored instead.
    func telegramMirroredFinalResponseText(fallback: String) async -> String {
        guard telegramDidPublishIntermediateRootResponse,
              let reporter = activeTelegramProgressReporter else {
            return fallback
        }
        let trailing = await reporter.pendingAgentResponseText()
        return trailing.isEmpty ? fallback : trailing
    }

    /// Marks the streaming root response as unmirrorable, when one is in flight.
    private func suppressTelegramRootResponseBlockIfStreaming() {
        guard telegramRootResponseBlockHasContent else {
            return
        }
        telegramRootResponseBlockIsSuppressed = true
    }

    private func resetTelegramRootResponseBlock() {
        telegramRootResponseBlockHasContent = false
        telegramRootResponseBlockIsSuppressed = false
        telegramDidPublishIntermediateRootResponse = false
    }

    /// Returns the authorization handler for a turn whose progress is mirrored
    /// to Telegram.
    ///
    /// Both routes gate exactly the terminal authorizer's set. The terminal and
    /// linked Telegram chat are asked concurrently, regardless of where the turn
    /// originated, and the first explicit decision resolves the request.
    func telegramToolAuthorizationHandler(
        for origin: TerminalPromptOrigin
    ) -> AgentToolAuthorizationHandler? {
        guard telegramOutgoingChatID(for: origin) != nil else {
            return nil
        }
        return { [weak self] request in
            guard let self else {
                return false
            }
            return await self.authorizeTelegramToolRequest(request, origin: origin)
        }
    }

    func authorizeTelegramToolRequest(
        _ request: AgentToolAuthorizationRequest,
        origin: TerminalPromptOrigin
    ) async -> Bool {
        guard LocalExecPermissionAuthorizer.gatedToolNames.contains(request.toolName) else {
            return true
        }

        guard let chatID = telegramOutgoingChatID(for: origin) else {
            await writeFailureMessage(
                "ZenCODE: Telegram cannot request permission for \(request.toolName); the operation was denied.\n"
            )
            return false
        }

        let terminalAlreadyAuthorized = await permissionAuthorizer.isAlreadyAuthorized(request)
        let telegramAlreadyAuthorized = await telegramPermissionBroker.isAlreadyAuthorized(request)
        if terminalAlreadyAuthorized || telegramAlreadyAuthorized {
            return true
        }
        await writeSystemMessage(Self.telegramPermissionPendingText(for: request))

        let winningResult = await withTaskGroup(
            of: TerminalTelegramAuthorizationChannelResult.self,
            returning: TerminalTelegramAuthorizationChannelResult?.self
        ) { group in
            group.addTask { [permissionAuthorizer] in
                .terminal(await permissionAuthorizer.authorizationOutcome(for: request))
            }
            group.addTask { [weak self, telegramPermissionBroker] in
                let outcome = await telegramPermissionBroker.authorize(
                    request,
                    chatID: chatID
                ) { [weak self] message in
                    await self?.sendTelegramTurnMessage(.authorization(message), to: chatID) ?? false
                }
                return .telegram(outcome)
            }

            while let result = await group.next() {
                switch result {
                case let .terminal(outcome):
                    switch outcome {
                    case .allowedOnce, .allowedAlways, .denied:
                        group.cancelAll()
                        return result
                    case .unavailable, .cancelled:
                        continue
                    }
                case let .telegram(outcome):
                    switch outcome {
                    case .notRequired, .allowedOnce, .allowedAlways, .denied:
                        group.cancelAll()
                        return result
                    case .timedOut, .undeliverable, .cancelled:
                        continue
                    }
                }
            }
            return nil
        }

        switch winningResult {
        case let .terminal(outcome):
            let approved = outcome.isApproved
            await sendTelegramTurnMessage(
                .authorization(
                    approved
                        ? "✅ Permission granted in the terminal for \(request.toolName). Continuing."
                        : "⛔ Permission denied in the terminal for \(request.toolName)."
                ),
                to: chatID
            )
            return approved
        case let .telegram(outcome):
            if outcome == .allowedAlways {
                await permissionAuthorizer.recordAlwaysAuthorization(for: request)
            }
            await writeTelegramPermissionOutcome(outcome, request: request)
            return outcome.isApproved
        case nil:
            await writeFailureMessage(
                "ZenCODE: no authorization channel could resolve \(request.toolName); the operation was denied.\n"
            )
            return false
        }
    }

    private static func telegramPermissionPendingText(
        for request: AgentToolAuthorizationRequest
    ) -> String {
        """

        Permission required: \(request.title)
        Approve or deny in the terminal, or use /allow, /always or /deny in the linked chat.

        """
    }

    private func writeTelegramPermissionOutcome(
        _ outcome: TerminalTelegramPermissionOutcome,
        request: AgentToolAuthorizationRequest
    ) async {
        switch outcome {
        case .notRequired:
            // A previous decision already covered the request; nothing was asked.
            break
        case .allowedOnce, .allowedAlways:
            await writeSystemMessage(
                "Telegram approved \(request.toolName).\n"
            )
        case .denied:
            await writeSystemMessage(
                "Telegram denied \(request.toolName).\n"
            )
        case .timedOut:
            await writeFailureMessage(
                "ZenCODE: Telegram permission for \(request.toolName) timed out; the operation was denied.\n"
            )
        case .undeliverable:
            await writeFailureMessage(
                "ZenCODE: the Telegram permission request for \(request.toolName) could not be delivered; the operation was denied.\n"
            )
        case .cancelled:
            break
        }
    }

    func handleTelegramPermissionResponseIfNeeded(
        _ text: String,
        chatID: Int64
    ) async -> Bool {
        let result = await telegramPermissionBroker.handleMessage(text, chatID: chatID)
        switch result {
        case .notHandled:
            return false
        case let .handled(reply):
            if let reply = reply?.nilIfBlank {
                await sendTelegramTurnMessage(.authorization(reply), to: chatID)
            }
            return true
        }
    }

    func sendTelegramSystemMessageIfLinked(_ message: String) async {
        guard let chatID = telegramLinkedChatID,
              telegramControlState.isActive else {
            return
        }
        await sendTelegramSystemMessage(message, to: chatID)
    }

    func sendTelegramSystemMessageIfLinked(
        _ message: String,
        origin: TerminalPromptOrigin
    ) async {
        guard let chatID = telegramOutgoingChatID(for: origin) else {
            return
        }
        await sendTelegramSystemMessage(message, to: chatID)
    }

    /// Publishes an authorization message on the ordered Telegram channel.
    ///
    /// While a mirrored turn is generating, its reporter owns the outgoing
    /// order. Bot control messages deliberately use `sendTelegramSystemMessage`
    /// instead.
    @discardableResult
    func sendTelegramTurnMessage(
        _ payload: TerminalTelegramTurnPayload,
        to chatID: Int64
    ) async -> Bool {
        guard telegramControlState.isActive,
              telegramLinkedChatID == chatID else {
            return false
        }
        if let reporter = activeTelegramProgressReporter, reporter.chatID == chatID {
            return await reporter.send(payload)
        }
        if let onDirectTelegramTurnMessage {
            return await onDirectTelegramTurnMessage(payload, chatID)
        }
        return await sendTelegramSystemMessage(payload.text, to: chatID)
    }

    func sendTelegramTurnMessageIfLinked(
        _ payload: TerminalTelegramTurnPayload,
        origin: TerminalPromptOrigin
    ) async {
        guard let chatID = telegramOutgoingChatID(for: origin) else {
            return
        }
        await sendTelegramTurnMessage(payload, to: chatID)
    }

    /// Returns the linked chat to use for outgoing messages, when Telegram
    /// remote control is active. Local prompts are forwarded to the linked
    /// chat so the session keeps replying on Telegram after `/telegram on`,
    /// even without an incoming Telegram request.
    func telegramOutgoingChatID(for origin: TerminalPromptOrigin) -> Int64? {
        guard telegramControlState.isActive,
              let linkedChatID = telegramLinkedChatID else {
            return nil
        }
        if let originChatID = origin.telegramChatID {
            return originChatID == linkedChatID ? linkedChatID : nil
        }
        return linkedChatID
    }

    /// Sends a message to a Telegram chat, reporting whether it was delivered.
    ///
    /// Delivery status is part of the contract: a permission request that never
    /// reached the chat must fail closed instead of holding the turn.
    @discardableResult
    func sendTelegramSystemMessage(_ message: String, to chatID: Int64) async -> Bool {
        if let onTelegramSystemMessage {
            return await onTelegramSystemMessage(message, chatID)
        }
        do {
            telegramControlState = try await telegramControlService.sendMessage(message, to: chatID)
            return true
        } catch {
            telegramControlState.lastError = error.localizedDescription
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            return false
        }
    }

    private func telegramStatusText() -> String {
        var lines = [
            "Telegram: \(telegramControlState.statusText)"
        ]
        if let botUsername = telegramControlState.botUsername?.nilIfBlank {
            lines.append("Bot: @\(botUsername)")
        }
        if let title = telegramLinkedChatTitle?.nilIfBlank {
            lines.append("Linked chat: \(title)")
        }
        if let error = telegramControlState.lastError?.nilIfBlank {
            lines.append("Last error: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    private func telegramRemoteStatusText() -> String {
        let agent = selectedAgent?.displayName ?? AgentProfileStore.developerAgentName
        let model = currentEffectiveModelID() ?? "default model"
        return "Session active.\nAgent: \(agent)\nModel: \(model)\nWorking directory: \(configuration.workingDirectory.path)"
    }

    private func telegramRemoteChangesText() -> String {
        guard let summary = lastFileChangeSummary else {
            return "No tracked file changes."
        }
        let title = summary.fileCount == 1
            ? "1 modified file"
            : "\(summary.fileCount) modified files"
        let entries = summary.entries
            .map(Self.renderFileChangeEntry)
            .joined(separator: "\n")
        return "\(title)  +\(summary.totalAdditions) -\(summary.totalDeletions)\n\(entries)"
    }

    func telegramRemoteHelpText() -> String {
        """
        Send a message to prompt the current ZenCODE TUI session.
        Live messages from agents are forwarded here; reply to one with text to answer its sender.
        A voice note cannot be a direct reply: send text, or record without replying to run an ordinary prompt.
        Remote commands: /status, /changes, /help, /plan <goal> and its subcommands, /goal <goal>, /review [focus].
        While /plan is asking questions, ordinary replies continue that same runtime discussion.
        While /goal is waiting for an answer, ordinary replies continue that same workflow task graph.
        Permission replies: /allow ID, /always ID, /deny ID.
        Gated operations (shell commands, deletions, git push/restore) are asked here.
        Turn Telegram off from the TUI with /telegram off.
        """
    }

    @discardableResult
    private func sendTelegramProgressMessage(_ message: String, to chatID: Int64) async -> Bool {
        guard telegramControlState.isActive,
              telegramLinkedChatID == chatID else {
            return false
        }
        return await sendTelegramSystemMessage(message, to: chatID)
    }

    func makeTelegramTurnProgressReporter(
        for origin: TerminalPromptOrigin
    ) -> TerminalTelegramTurnProgressReporter? {
        guard let chatID = telegramOutgoingChatID(for: origin) else {
            return nil
        }

        return TerminalTelegramTurnProgressReporter(chatID: chatID) { [weak self] message, chatID in
            await self?.sendTelegramProgressMessage(message, to: chatID) ?? false
        }
    }

}

