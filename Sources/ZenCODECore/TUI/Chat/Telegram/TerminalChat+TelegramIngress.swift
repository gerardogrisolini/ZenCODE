//
//  TerminalChat+TelegramIngress.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

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
        origin: TerminalPromptOrigin
    ) async -> TerminalSubmittedLineAction {
        guard await validateTelegramOrigin(origin) else { return .continueChat }
        let prompt = Self.telegramCommandWithoutBotMention(prompt)
        let remoteInvocation = TerminalTelegramRemoteCommand.invocation(text: prompt)
        let remoteCommand = remoteInvocation?.command
        if let remoteInvocation, remoteInvocation.command != .start,
           CoordinatorCommandParser.isSlashCommand(prompt),
           !remoteInvocation.argument.isEmpty {
            let name = prompt.split(whereSeparator: \.isWhitespace).first
                .map { String($0).lowercased() } ?? prompt
            await sendTelegramSystemMessageIfLinked(
                "ZenCODE: \(name) does not accept arguments.", origin: origin
            )
            return .continueChat
        }
        // A plain-word alias ("status", "diff", "undo", ...) is ordinary text
        // while a conversation explicitly waits for the operator: the pending
        // reply wins, exactly as in the TUI, where those words are never
        // commands. Slash forms keep their command meaning.
        if remoteCommand != nil,
           !CoordinatorCommandParser.isSlashCommand(prompt),
           let action = await telegramPendingConversationReplyAction(prompt, origin: origin) {
            return action
        }
        switch remoteCommand {
        case .start:
            await sendTelegramSystemMessageIfLinked(
                "Telegram is already linked to this ZenCODE session. Send a prompt or /help.",
                origin: origin
            )
            return .continueChat
        case .help:
            await sendTelegramSystemMessageIfLinked(telegramRemoteHelpText(), origin: origin)
            return .continueChat
        case .status:
            await sendTelegramSystemMessageIfLinked(telegramRemoteStatusText(), origin: origin)
            return .continueChat
        case .chat:
            guard let chatID = origin.telegramLease?.key.chatID else { return .continueChat }
            await handleTelegramMentionPickerRequest(chatID: chatID, origin: origin)
            return .continueChat
        case .changes:
            await sendTelegramSystemMessageIfLinked(telegramRemoteChangesText(), origin: origin)
            return .continueChat
        case .undo:
            await sendTelegramSystemMessageIfLinked(
                "Use /undo in the TUI to revert file changes.", origin: origin
            )
            return .continueChat
        case .diff:
            await handleTelegramDiffRequest(origin: origin)
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
                    telegramOrigin: origin
                )
                return .continueChat
            case .missingText:
                await sendTelegramSystemMessageIfLinked(
                    "ZenCODE message: add a message after the live mention.", origin: origin
                )
                return .continueChat
            case .none:
                break
            }

            if !CoordinatorCommandParser.isSlashCommand(prompt),
               let action = await telegramPendingConversationReplyAction(prompt, origin: origin) {
                return action
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
                    await sendTelegramSystemMessageIfLinked(output, origin: origin)
                }
                return action
            }
            if CoordinatorCommandParser.isSlashCommand(prompt),
               TerminalTelegramPermissionBroker.permissionCommand(from: prompt) == nil {
                let token = prompt.split(whereSeparator: \.isWhitespace).first
                    .map(String.init) ?? prompt
                await sendTelegramSystemMessageIfLinked(
                    "ZenCODE: unknown command '\(token)'. Available commands: \(Self.telegramRemoteCommandList())",
                    origin: origin
                )
                return .continueChat
            }
            return .runPrompt(prompt)
        }
    }

    /// Routes a plain Telegram line to the conversation that is explicitly
    /// waiting for the operator, in the same order as the TUI: the Goal for
    /// `/plan approve`, then an open Planner question, then a `/goal` workflow
    /// awaiting the user. Returns `nil` when nothing is waiting.
    ///
    /// These handlers report through `writeSystemMessage`/`writeFailureMessage`,
    /// so their immediate output is captured and mirrored to the originating
    /// chat with the same rule used for coordinator commands; otherwise an
    /// approval failure would appear only in the TUI.
    private func telegramPendingConversationReplyAction(
        _ prompt: String,
        origin: TerminalPromptOrigin
    ) async -> TerminalSubmittedLineAction? {
        telegramImmediateCommandOutput = []
        var action = await handlePlanApprovalGoalReply(prompt)
        if action == nil {
            action = handlePlanBrainstormingReply(prompt)
        }
        if action == nil {
            // Same cross-surface rule as the TUI: a plain Telegram message
            // continues the open `/goal` workflow while the coordinator is
            // explicitly waiting for the user.
            action = await handleWorkflowContinuationReply(prompt)
        }
        let output = telegramImmediateCommandOutput?.joined(separator: "\n").nilIfBlank
        telegramImmediateCommandOutput = nil
        if case .continueChat = action, let output {
            await sendTelegramSystemMessageIfLinked(output, origin: origin)
        }
        return action
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
        transcriptions: TerminalVoiceTranscriptionRegistry,
        isSessionGenerating: Bool = false
    ) async -> Bool {
        let countBefore = queuedPrompts.count
        await handleTelegramMessage(
            message,
            queuedPrompts: &queuedPrompts,
            eventQueue: eventQueue,
            transcriptions: transcriptions,
            isSessionGenerating: isSessionGenerating
        )
        return queuedPrompts.count > countBefore
    }

    /// Resolves the persisted route for this terminal instance. Authorization is
    /// entirely owner/lifecycle based; ephemeral client state is never consulted.
    func telegramAuthorizedRoute(
        for message: TerminalTelegramIncomingMessage
    ) async -> TerminalTelegramRouteLease? {
        guard message.chatKind == .privateChat,
              let lease = try? await telegramSessionRouter.resolve(
                  chatID: message.chatID, userID: message.userID,
                  topicID: message.topicID
              ), lease.key.roomID == sessionID || lease.key.roomID == "default" else { return nil }
        return lease
    }

    func handleTelegramMessage(
        _ message: TerminalTelegramIncomingMessage,
        queuedPrompts: inout TerminalQueuedPromptBuffer,
        eventQueue: TerminalChatEventQueue,
        transcriptions: TerminalVoiceTranscriptionRegistry,
        isSessionGenerating: Bool = false
    ) async {
        // Stop-generation updates are consumed by the interactive runtime where
        // the correlated generation Task is owned; never reinterpret them as a
        // prompt in another consumer.
        guard message.stoppedMessageGenerationDraftID == nil else { return }
        guard telegramControlState.isActive else {
            return
        }

        guard let routeLease = await telegramAuthorizedRoute(for: message) else {
            // Fail closed and stay silent: disclosing whether another room/user
            // owns a route would itself leak cross-session state.
            return
        }
        // The active terminal owns only its room (or the setup-created default
        // route). This value is an egress compatibility projection; owner checks
        // above never depend on it.
        // Remember the authorized operator for outbound artifact consent binding.
        telegramLinkedUserID = message.userID
        telegramActiveRouteLease = routeLease
        await telegramSharedChatRelay.activate(
            roomID: routeLease.key.roomID,
            chatID: routeLease.key.chatID,
            lease: routeLease,
            repliesEnabled: readsTelegramIngress
        )
        let routeOrigin = TerminalPromptOrigin.telegramLease(routeLease)
        guard let ingressFence = telegramWireFence(for: routeOrigin) else { return }

        if let callbackQueryID = message.callbackQueryID,
           let callbackData = message.callbackData {
            await telegramControlService.answerCallbackQuery(
                callbackQueryID, chatID: message.chatID, fence: ingressFence
            )
            if await handleTelegramArtifactConsentCallback(
                callbackData, message: message, origin: routeOrigin
            ) {
                return
            }
            guard !isSessionGenerating
                || callbackData.hasPrefix(Self.telegramMentionPickerCallbackPrefix) else {
                await sendTelegramBusyMessage(origin: routeOrigin)
                return
            }
            await handleTelegramMentionPickerCallback(
                callbackData, chatID: message.chatID, origin: routeOrigin
            )
            return
        }

        // The runtime loop owns the generation Task and passes its serialized,
        // session-local state here. Keep owner resolution, lease capture and the
        // wire fence above the gate, then reject before attachment downloads,
        // voice transcription, command parsing or shared-chat publication.
        // Permission replies remain live because an active turn may be blocked
        // waiting for exactly this operator decision.
        if isSessionGenerating,
           let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           TerminalTelegramPermissionBroker.permissionCommand(from: text) != nil,
           await handleTelegramPermissionResponseIfNeeded(text, lease: routeLease) {
            return
        }
        if isSessionGenerating,
           let busyText = message.text.map(Self.telegramCommandWithoutBotMention),
           let invocation = TerminalTelegramRemoteCommand.invocation(text: busyText),
           invocation.argument.isEmpty {
            let isSlash = CoordinatorCommandParser.isSlashCommand(busyText)
            switch invocation.command {
            case .status:
                await sendTelegramSystemMessageIfLinked(
                    telegramRemoteStatusText(), origin: routeOrigin
                )
                return
            case .chat:
                await handleTelegramMentionPickerRequest(
                    chatID: message.chatID, origin: routeOrigin
                )
                return
            case .help where isSlash:
                await sendTelegramSystemMessageIfLinked(
                    telegramRemoteHelpText(), origin: routeOrigin
                )
                return
            case .changes where isSlash:
                await sendTelegramSystemMessageIfLinked(
                    telegramRemoteChangesText(), origin: routeOrigin
                )
                return
            default:
                break
            }
        }
        guard !isSessionGenerating else {
            await sendTelegramBusyMessage(origin: routeOrigin)
            return
        }

        if let attachment = message.attachment {
            await handleTelegramInboundAttachment(
                attachment, message: message, origin: routeOrigin
            )
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
                await sendTelegramSystemMessageIfLinked(
                    "ZenCODE message: replies to a live message must be text. Send your answer as text, or record a voice note without replying to run it as an ordinary prompt.",
                    origin: routeOrigin
                )
                return
            }
            await handleTelegramVoiceMessage(
                voice,
                origin: routeOrigin,
                eventQueue: eventQueue,
                transcriptions: transcriptions
            )
            return
        }

        let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }

        if await handleTelegramPermissionResponseIfNeeded(text, lease: routeLease) {
            return
        }

        let commandText = Self.telegramCommandWithoutBotMention(text)
        let invocation = TerminalTelegramRemoteCommand.invocation(text: commandText)
        // `/start` and `/chat` are answered before the prompt queue: they must
        // work even when the queue is full and must never be consumed as the
        // argument of a pending ForceReply command request. `/chat <text>`
        // falls through to the queued path, which rejects the argument.
        switch (invocation?.command, invocation?.argument.isEmpty) {
        case (.start?, _):
            await sendTelegramSystemMessageIfLinked(
                "Telegram is already linked to this ZenCODE session. Send a prompt or /help.",
                origin: routeOrigin
            )
            return
        case (.chat?, true?):
            await handleTelegramMentionPickerRequest(
                chatID: message.chatID, origin: routeOrigin
            )
            return
        default:
            break
        }

        if let coordinatorCommand = CoordinatorCommandParser.parse(commandText),
           coordinatorCommand.requiresArgument {
            await requestTelegramCommandArgument(
                commandText, chatID: message.chatID, lease: routeLease
            )
            return
        }

        if let completedCommand = consumeTelegramCommandArgumentReply(
            from: message, lease: routeLease
        ) {
            guard queuedPrompts.enqueue(
                TerminalQueuedPrompt(text: completedCommand, origin: .telegramLease(routeLease))
            ) else {
                await sendTelegramSystemMessageIfLinked(
                    "ZenCODE is busy and the prompt queue is full. Your command was not queued; try again after a running prompt completes.",
                    origin: routeOrigin
                )
                return
            }
            telegramRuntimeEventQueue = eventQueue
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
           await handleTelegramSharedChatReplyIfNeeded(
            text, message: message, origin: routeOrigin
           ) {
            return
        }

        guard (try? await telegramSessionRouter.validate(routeLease)) != nil else { return }
        guard queuedPrompts.enqueue(
            TerminalQueuedPrompt(text: text, origin: .telegramLease(routeLease))
        ) else {
            await sendTelegramSystemMessageIfLinked(
                "ZenCODE is busy and the prompt queue is full. Your prompt was not queued; try again after a running prompt completes.",
                origin: routeOrigin
            )
            return
        }
        telegramRuntimeEventQueue = eventQueue
    }

    /// A menu selection is delivered by Telegram as a bare message. Ask for the
    /// missing argument with a receipt-backed ForceReply, then accept only a
    /// reply to that exact receipt on its original route.
    private func requestTelegramCommandArgument(
        _ command: String, chatID: Int64, lease: TerminalTelegramRouteLease
    ) async {
        let prompt: String
        if command == "/plan" {
            prompt = "Enter the goal or subcommand for /plan (save, load, list, delete, status, approve, clear). Reply to this message; it will not be treated as a normal prompt."
        } else {
            prompt = "Enter the argument for \(command). Reply to this message; it will not be treated as a normal prompt."
        }
        let receipt = await sendTelegramReplyMarkupMessage(
            prompt, to: chatID, replyMarkup: .forceReply, origin: .telegramLease(lease)
        )
        guard let receipt else { return }
        // One unanswered command per route bounds this ledger even if an
        // operator repeatedly opens a parameterized menu command.
        telegramCommandReplyBindings = telegramCommandReplyBindings.filter {
            $0.value.lease != lease
        }
        telegramCommandReplyBindings[
            .init(chatID: chatID, receiptMessageID: receipt)
        ] = TerminalTelegramCommandReplyBinding(
            command: command, chatID: chatID, lease: lease
        )
    }

    private func consumeTelegramCommandArgumentReply(
        from message: TerminalTelegramIncomingMessage,
        lease: TerminalTelegramRouteLease
    ) -> String? {
        guard let receipt = message.replyToMessageID,
              let binding = telegramCommandReplyBindings[
                  .init(chatID: message.chatID, receiptMessageID: receipt)
              ],
              binding.chatID == message.chatID,
              binding.lease == lease,
              let argument = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !argument.isEmpty else {
            return nil
        }
        telegramCommandReplyBindings.removeValue(
            forKey: .init(chatID: message.chatID, receiptMessageID: receipt)
        )
        return "\(binding.command) \(argument)"
    }

    private func sendTelegramBusyMessage(origin: TerminalPromptOrigin) async {
        await sendTelegramSystemMessageIfLinked(
            "ZenCODE is busy generating a response in this session. This Telegram request was not queued; wait for the current response to finish and send it again.",
            origin: origin
        )
    }
}
