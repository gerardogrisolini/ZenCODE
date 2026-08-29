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
        origin: TerminalPromptOrigin
    ) async -> TerminalSubmittedLineAction {
        guard await validateTelegramOrigin(origin) else { return .continueChat }
        let prompt = Self.telegramCommandWithoutBotMention(prompt)
        switch TerminalTelegramRemoteCommand(text: prompt) {
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
        case .report:
            await handleTelegramReportRequest(origin: origin)
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

    /// Resolves the persisted route for this terminal instance. Authorization is
    /// entirely ACL/lifecycle based; ephemeral client state is never consulted.
    func telegramAuthorizedRoute(
        for message: TerminalTelegramIncomingMessage
    ) async -> TerminalTelegramRouteLease? {
        guard let settings = AgentSettingsManifestStore.load()?.telegram,
              settings.isConfigured else {
            // Source-compatible injected/test activation. Production `start()`
            // cannot reach an active state without persisted configuration.
            guard message.chatKind == .privateChat,
                  telegramLinkedChatID == message.chatID else { return nil }
            let route = AgentTelegramRouteManifest(
                chatID: message.chatID, ownerUserID: message.userID,
                roomID: sessionID, chatKind: .privateChat
            )
            await telegramSessionRouter.refresh(routes: [route], groupsEnabled: false)
            return try? await telegramSessionRouter.resolve(
                chatID: message.chatID, userID: message.userID,
                topicID: nil, chatKind: .privateChat
            )
        }
        guard settings.isRoutingSupported else { return nil }
        await telegramSessionRouter.refresh(
            routes: settings.routes, groupsEnabled: settings.groupsEnabled
        )
        if settings.routes.isEmpty {
            guard message.chatKind == .privateChat,
                  settings.linkedChatID == message.chatID else { return nil }
            return try? await telegramSessionRouter.claimLegacyPrivateRoute(
                chatID: message.chatID, userID: message.userID, roomID: "default"
            )
        }
        guard let lease = try? await telegramSessionRouter.resolve(
            chatID: message.chatID, userID: message.userID,
            topicID: message.topicID, chatKind: message.chatKind
        ), lease.key.roomID == sessionID || lease.key.roomID == "default" else { return nil }
        return lease
    }

    func handleTelegramMessage(
        _ message: TerminalTelegramIncomingMessage,
        queuedPrompts: inout TerminalQueuedPromptBuffer,
        eventQueue: TerminalChatEventQueue,
        transcriptions: TerminalVoiceTranscriptionRegistry
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
        // route). This value is an egress compatibility projection; ACL decisions
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
            await handleTelegramMentionPickerCallback(
                callbackData, chatID: message.chatID, origin: routeOrigin
            )
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

        if TerminalTelegramRemoteCommand(text: text) == .start {
            await sendTelegramSystemMessageIfLinked(
                "Telegram is already linked to this ZenCODE session. Send a prompt or /help.",
                origin: routeOrigin
            )
            return
        }

        if text == "@" {
            await handleTelegramMentionPickerRequest(
                chatID: message.chatID, origin: routeOrigin
            )
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

    // MARK: - Mention picker

    nonisolated static let telegramMentionPickerCallbackPrefix = "zencode:mention:"

    /// The Telegram Bot API has no typing events. A standalone `@` is therefore
    /// the explicit, non-ambiguous trigger for the discoverable mention picker.
    func handleTelegramMentionPickerRequest(
        chatID: Int64, origin: TerminalPromptOrigin? = nil
    ) async {
        let buttons = Self.telegramMentionPickerButtons(
            from: await sharedChatMentionSuggestions()
        )
        guard !buttons.isEmpty else { return }
        let markup = TerminalTelegramReplyMarkup.inlineKeyboard(buttons.map { [$0] })
        _ = await sendTelegramMentionPickerMessage(
            "Choose who to message. After selecting, reply to the next card with your message.",
            to: chatID,
            replyMarkup: markup,
            origin: origin
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

    func handleTelegramMentionPickerCallback(
        _ data: String, chatID: Int64, origin: TerminalPromptOrigin? = nil
    ) async {
        guard let lease = origin?.telegramLease,
              lease.key.chatID == chatID,
              (try? await telegramSessionRouter.validate(lease)) != nil else { return }
        guard data.hasPrefix(Self.telegramMentionPickerCallbackPrefix) else { return }
        let handle = String(data.dropFirst(Self.telegramMentionPickerCallbackPrefix.count))
        guard handle.utf8.count <= 48 else { return }
        let roster = await sessionRunner.sharedChatMentionRoster(rootSessionID: sessionID)
        guard case let .route(route) = Self.parseSharedChatMention(
            from: "@\(handle) selected",
            readableHandles: roster.handleMap
        ), await isCurrentSharedChatDirectDestination(route.destination) else {
            await sendTelegramSystemMessage(
                "ZenCODE message: that agent is no longer active. Open `@` again.",
                to: chatID,
                origin: .telegramLease(lease)
            )
            return
        }
        let receipt = await sendTelegramMentionPickerMessage(
            "Writing to @\(handle). Reply to this message with the content to send; it will not be treated as a normal prompt.",
            to: chatID,
            replyMarkup: .forceReply,
            origin: origin
        )
        guard let receipt else { return }
        await telegramSharedChatRelay.registerReplyTarget(
            Self.telegramMentionPickerReplyTarget(
                destination: route.destination, roomID: sessionID, chatID: chatID, handle: handle
            ),
            forTelegramMessageID: receipt,
            lease: lease
        )
    }

    private func sendTelegramMentionPickerMessage(
        _ text: String, to chatID: Int64, replyMarkup: TerminalTelegramReplyMarkup,
        origin: TerminalPromptOrigin? = nil
    ) async -> Int? {
        if let hook = onTelegramMentionPickerMessage { return await hook(text, chatID, replyMarkup) }
        guard let origin, let fence = telegramWireFence(for: origin) else { return nil }
        do {
            return try await telegramControlService.sendPlainMessageWithReceipt(
                text, to: chatID,
                topicID: origin.telegramLease?.effectiveMessageThreadID,
                replyMarkup: replyMarkup, fence: fence
            )
        }
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

    // MARK: - Secure artifacts

    /// Directories whose individually selected files may be exported to the
    /// linked chat. Deliberately narrow: the temporary artifact staging
    /// directory only. Nothing under the repository working directory is a
    /// member, so `/diff` and `/report` materialize a bounded excerpt into
    /// this staging area first and only that excerpt can ever be uploaded.
    nonisolated static var telegramArtifactPolicy: TerminalTelegramArtifactPolicy {
        TerminalTelegramArtifactPolicy(
            allowedDirectories: [Self.telegramArtifactStagingDirectory]
        )
    }

    /// Staging directory for outbound artifacts. Created 0700; excerpts are
    /// written 0600 and removed right after the upload (or refusal).
    nonisolated static var telegramArtifactStagingDirectory: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-telegram-artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return url
    }

    /// `/diff` materializes the session diff into a bounded staging file and
    /// asks for explicit consent. The repository itself is never uploaded:
    /// only this excerpt, only after confirmation.
    func handleTelegramDiffRequest(origin: TerminalPromptOrigin) async {
        guard let chatID = origin.telegramChatID else { return }
        guard let diffText = telegramSessionDiffText()?.nilIfBlank else {
            await sendTelegramSystemMessage(
                "ZenCODE message: no diff is available for this session yet.",
                to: chatID,
                origin: origin
            )
            return
        }
        guard diffText.utf8.count <= TerminalTelegramMultipartForm.maximumBodyBytes else {
            await sendTelegramSystemMessage(
                "ZenCODE message: the session diff exceeds the Telegram upload budget and cannot be sent.",
                to: chatID,
                origin: origin
            )
            return
        }
        let url = Self.telegramArtifactStagingDirectory
            .appendingPathComponent("session-\(sessionID.prefix(8))-\(UUID().uuidString).diff")
        do {
            try Self.writePrivateArtifact(diffText, to: url)
            await offerTelegramArtifact(
                TerminalTelegramArtifact(
                    fileURL: url,
                    filename: url.lastPathComponent,
                    contentType: "text/x-diff"
                ),
                chatID: chatID,
                summary: "Send the session diff as a document?",
                origin: origin
            )
        } catch {
            await sendTelegramSystemMessage(
                "ZenCODE message: the diff could not be prepared for upload.",
                to: chatID,
                origin: origin
            )
        }
    }

    /// `/report` offers the most recent report/log file found in the ZenCODE
    /// application support tree, after the policy validates it. No file is
    /// sent or read into memory before consent.
    func handleTelegramReportRequest(origin: TerminalPromptOrigin) async {
        guard let chatID = origin.telegramChatID else { return }
        guard let candidate = Self.latestTelegramReportCandidate(),
              let artifact = try? Self.telegramArtifactPolicy.validated(candidate) else {
            await sendTelegramSystemMessage(
                "ZenCODE message: no exportable report or log file was found.",
                to: chatID,
                origin: origin
            )
            return
        }
        await offerTelegramArtifact(
            artifact,
            chatID: chatID,
            summary: "Send “\(artifact.filename)” as a document?",
            origin: origin
        )
    }

    /// Sends the consent request with the two-button keyboard. The upload
    /// happens only through the explicit callback.
    private func offerTelegramArtifact(
        _ artifact: TerminalTelegramArtifact,
        chatID: Int64,
        summary: String,
        origin: TerminalPromptOrigin
    ) async {
        guard let lease = origin.telegramLease else {
            Self.removeStagedArtifact(at: artifact.fileURL)
            return
        }
        do {
            guard let offerID = try await telegramControlService.offerArtifactConsent(
                artifact: artifact,
                chatID: chatID,
                userID: telegramLinkedUserID ?? 0,
                routeLease: lease,
                cleanupAfterUse: Self.isTelegramStagedArtifact(artifact.fileURL)
            ) else {
                Self.removeStagedArtifact(at: artifact.fileURL)
                await sendTelegramSystemMessage(
                    "ZenCODE message: too many pending file requests. Confirm or cancel one first.",
                    to: chatID,
                origin: origin
                )
                return
            }
            let receipt = await sendTelegramArtifactConsentMessage(
                summary,
                to: chatID,
                replyMarkup: TerminalTelegramArtifactConsentKeyboard.markup(offerID: offerID),
                origin: origin
            )
            if receipt == nil {
                // The request never reached the chat: spend the offer so the
                // consent cannot be used later without a visible prompt.
                await telegramControlService.cancelArtifactConsent(
                    offerID: offerID, chatID: chatID
                )
            }
        } catch {
            await sendTelegramSystemMessage(
                "ZenCODE message: this file cannot be sent (\(error.localizedDescription)).",
                to: chatID,
                origin: origin
            )
        }
    }

    /// Handles the explicit Send/Cancel tap of an artifact consent offer.
    /// Returns `true` when the callback belonged to the consent flow.
    private func handleTelegramArtifactConsentCallback(
        _ data: String,
        message: TerminalTelegramIncomingMessage,
        origin: TerminalPromptOrigin
    ) async -> Bool {
        guard let consent = TerminalTelegramArtifactConsentKeyboard
            .action(fromCallbackData: data) else {
            return false
        }
        let offerID = consent.offerID
        guard let lease = origin.telegramLease,
              let fence = telegramWireFence(for: origin) else { return true }
        switch consent.action {
        case .cancel:
            await telegramControlService.cancelArtifactConsent(
                offerID: offerID, chatID: message.chatID
            )
            await sendTelegramSystemMessage(
                "ZenCODE message: file send cancelled.",
                to: message.chatID,
                origin: origin
            )
        case .send:
            // Capture the artifact before the offer is spent, so the staged
            // excerpt can be removed after the attempt either way.
            let stagedURL = await telegramControlService.pendingConsentArtifact(
                offerID: offerID, chatID: message.chatID
            )?.fileURL
            do {
                guard let messageID = try await telegramControlService
                    .sendArtifactWithConsent(
                        offerID: offerID,
                        chatID: message.chatID,
                        userID: message.userID,
                        routeLease: lease,
                        policy: Self.telegramArtifactPolicy,
                        topicID: lease.effectiveMessageThreadID,
                        fence: fence
                    ) else {
                    Self.removeStagedArtifact(at: stagedURL)
                    await sendTelegramSystemMessage(
                        "ZenCODE message: that confirmation expired or no longer matches the file. Ask again with /diff or /report.",
                        to: message.chatID,
                        origin: origin
                    )
                    return true
                }
                _ = messageID
                Self.removeStagedArtifact(at: stagedURL)
                await sendTelegramSystemMessage(
                    "ZenCODE message: file sent.",
                    to: message.chatID,
                    origin: origin
                )
            } catch {
                Self.removeStagedArtifact(at: stagedURL)
                await sendTelegramSystemMessage(
                    "ZenCODE message: the file could not be sent (\(error.localizedDescription)).",
                    to: message.chatID,
                    origin: origin
                )
            }
        }
        return true
    }

    /// Removes a staged outbound excerpt after its upload attempt. Only files
    /// inside the private staging directory are ever deleted: operator-owned
    /// report/log files under application support stay untouched.
    private nonisolated static func removeStagedArtifact(at url: URL?) {
        guard let url else { return }
        let staging = telegramArtifactStagingDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard target == staging || target.hasPrefix(staging + "/") else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private nonisolated static func isTelegramStagedArtifact(_ url: URL) -> Bool {
        let staging = telegramArtifactStagingDirectory
            .resolvingSymlinksInPath().standardizedFileURL.path
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        return target.hasPrefix(staging + "/")
    }

    /// Selective ingress: an admitted attachment is downloaded into the
    /// bounded 0600 store and acknowledged. The file is never opened by this
    /// path — the operator asks the agent to read it explicitly afterwards.
    private func handleTelegramInboundAttachment(
        _ attachment: TerminalTelegramInboundAttachment,
        message: TerminalTelegramIncomingMessage,
        origin: TerminalPromptOrigin
    ) async {
        guard let fence = telegramWireFence(for: origin) else { return }
        do {
            let stored = try await telegramControlService.receiveInboundAttachment(
                attachment, chatID: message.chatID, fence: fence
            )
            await sendTelegramSystemMessage(
                "ZenCODE message: received “\(stored.filename)” (\(stored.mimeType)). Ask the agent to read it by path when needed; it will be removed automatically.",
                to: message.chatID,
                origin: origin
            )
        } catch TerminalTelegramControlError.attachmentStoreBusy {
            await sendTelegramSystemMessage(
                "ZenCODE message: too many attachments are being received. Try again shortly.",
                to: message.chatID,
                origin: origin
            )
        } catch TerminalTelegramControlError.fileTooLarge(let limit) {
            await sendTelegramSystemMessage(
                TerminalTelegramInboundAttachmentGate.Refusal
                    .tooLarge(limit: limit).operatorMessage,
                to: message.chatID,
                origin: origin
            )
        } catch {
            await sendTelegramSystemMessage(
                "ZenCODE message: the attachment could not be received.",
                to: message.chatID,
                origin: origin
            )
        }
    }

    /// Bounded session diff text assembled from the per-file patches the
    /// session already holds, or `nil` when none exists. The excerpt is
    /// capped by the multipart budget so a giant working tree can never
    /// produce an unbounded artifact.
    private func telegramSessionDiffText() -> String? {
        guard let summary = lastFileChangeSummary, !summary.entries.isEmpty else {
            return nil
        }
        let budget = TerminalTelegramMultipartForm.maximumBodyBytes
        var lines: [String] = []
        var count = 0
        for entry in summary.entries {
            let patch = entry.patch?.nilIfBlank
                ?? "\(entry.status.rawValue) \(entry.path) (+\(entry.additions) -\(entry.deletions))"
            let block = patch.hasSuffix("\n") ? patch : patch + "\n"
            count += block.utf8.count
            if count > budget { break }
            lines.append(block)
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined()
    }

    private nonisolated static func writePrivateArtifact(
        _ text: String, to url: URL
    ) throws {
        let data = Data(text.utf8)
        let succeeded = FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        )
        guard succeeded else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Most recent exportable report/log candidate under application support.
    private nonisolated static func latestTelegramReportCandidate() -> TerminalTelegramArtifact? {
        let fileManager = FileManager.default
        let roots = [
            AppStorageDirectory.appSupportDirectoryURL(),
            fileManager.temporaryDirectory,
        ]
        let allowed = Set(["log", "txt", "md", "json"])
        var best: (url: URL, date: Date)?
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                ), values.isRegularFile == true,
                    allowed.contains(url.pathExtension.lowercased()) else {
                    continue
                }
                let date = values.contentModificationDate ?? .distantPast
                if best == nil || date > best!.date {
                    best = (url, date)
                }
            }
        }
        guard let best else { return nil }
        return TerminalTelegramArtifact(
            fileURL: best.url,
            filename: best.url.lastPathComponent
        )
    }

    /// Plain-text send with a reply markup, returning the receipt, so consent
    /// keyboards never inherit Markdown parsing from operator-typed names.
    private func sendTelegramArtifactConsentMessage(
        _ text: String,
        to chatID: Int64,
        replyMarkup: TerminalTelegramReplyMarkup,
        origin: TerminalPromptOrigin
    ) async -> Int? {
        if let onTelegramSystemMessage {
            _ = await onTelegramSystemMessage(text, chatID)
            return nil
        }
        guard let fence = telegramWireFence(for: origin) else { return nil }
        do {
            return try await telegramControlService.sendPlainMessageWithReceipt(
                text, to: chatID, topicID: origin.telegramLease?.effectiveMessageThreadID,
                replyMarkup: replyMarkup, fence: fence
            )
        } catch {
            telegramControlState.lastError = error.localizedDescription
            return nil
        }
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
        guard telegramControlState.isActive,
              telegramActiveRouteLease != nil || telegramLinkedChatID != nil else {
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
              let lease = telegramActiveRouteLease,
              lease.key.roomID == roomID,
              (try? await telegramSessionRouter.validate(lease)) != nil else {
            await telegramSharedChatRelay.deactivate()
            return
        }
        await telegramSharedChatRelay.activate(
            roomID: roomID,
            chatID: lease.key.chatID,
            lease: lease,
            repliesEnabled: readsTelegramIngress
        )
    }

    /// Delivers one relay card as plain text and returns its Telegram receipt.
    ///
    /// A failure is recorded on the control state but never written to the
    /// terminal: cards are asynchronous notifications, and a transient Telegram
    /// error must not inject noise into the operator's transcript.
    func sendTelegramSharedChatCard(
        _ text: String, to chatID: Int64,
        lease: TerminalTelegramRouteLease
    ) async -> Int? {
        guard telegramControlState.isActive,
              let lifecycleEpoch = telegramControlState.wireLifecycleEpoch else {
            return nil
        }
        guard lease.key.chatID == chatID,
              (try? await telegramSessionRouter.validate(lease)) != nil else { return nil }
        let fence = TerminalTelegramWireFence(
            lease: lease,
            lifecycleEpoch: lifecycleEpoch,
            validateLease: { [telegramSessionRouter] lease in
                try await telegramSessionRouter.validate(lease)
            }
        )
        do {
            return try await telegramControlService.sendPlainMessageWithReceipt(
                text,
                to: chatID,
                topicID: lease.effectiveMessageThreadID,
                fence: fence
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
              let lease = telegramActiveRouteLease,
              lease.key.chatID == message.chatID,
              let target = await telegramSharedChatRelay.replyTarget(
                  forTelegramMessageID: replyToMessageID,
                  chatID: message.chatID,
                  lease: lease
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
        message: TerminalTelegramIncomingMessage,
        origin: TerminalPromptOrigin
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
                to: message.chatID,
                origin: origin
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
                to: message.chatID,
                origin: origin
            )
        }
        return true
    }

    func handleTelegramVoiceMessage(
        _ voice: TerminalTelegramVoiceAttachment,
        origin: TerminalPromptOrigin,
        eventQueue: TerminalChatEventQueue,
        transcriptions: TerminalVoiceTranscriptionRegistry
    ) async {
        guard let chatID = origin.telegramChatID,
              let fence = telegramWireFence(for: origin) else { return }
        guard isVoiceConfigured() else {
            await sendTelegramSystemMessage(
                "Voice-message transcription is not configured. Run the /setup command in zen and enable voice-message transcription.",
                to: chatID,
                origin: origin
            )
            return
        }

        // Bounded ownership: a burst of voice notes must not start an unbounded
        // number of concurrent downloads and transcriptions, and every started
        // task must be cancellable at teardown.
        guard let slot = transcriptions.reserveSlot() else {
            await sendTelegramSystemMessage(
                "Too many voice messages are being transcribed. Try again shortly.",
                to: chatID,
                origin: origin
            )
            return
        }

        let task = Task(name: "ZenCODE.Telegram.voice-transcription") { [weak self] in
            defer { transcriptions.release(slot) }
            guard let self else { return }
            // Presence for the transcription is scoped to its own lease: the
            // typing indicator covers the download+transcribe wait, and the
            // lease is released on every exit path (success, failure,
            // cancellation) so a dead session never keeps "typing".
            let presenceLease = await self.telegramControlService.acquirePresenceLease(
                scope: .transcription(
                    chatID: chatID,
                    topicID: origin.telegramLease?.effectiveMessageThreadID
                ),
                fence: fence
            )
            defer {
                if let presenceLease {
                    Task(name: "ZenCODE.Telegram.presence-release") { [telegramControlService] in
                        await telegramControlService.releasePresenceLease(presenceLease)
                    }
                }
            }
            do {
                let audio = try await self.telegramControlService.downloadVoiceAudio(
                    voice, chatID: chatID, fence: fence
                )
                // Own cleanup immediately: cancellation can land after download
                // returns but before `transcribe` installs its own defer.
                defer { audio.cleanup() }
                try Task.checkCancellation()
                let transcript = try await AgentVoiceTranscriptionService()
                    .transcribe(audio)
                guard await eventQueue.sendWithBackpressure(
                    .voicePromptCompleted(
                        TerminalVoicePromptResult(
                            origin: origin,
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
                            origin: origin,
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
            telegramLinkedUserID = nil
            telegramControlState = try await telegramControlService.start()
            telegramActiveRouteLease = await telegramEgressRouteLease(
                settings: settings,
                linkedChatID: linkedChatID
            )
            if let lease = telegramActiveRouteLease {
                telegramLinkedUserID = lease.key.userID
                // A local turn that was already running while Telegram was off
                // must use the same validated lease as the next local turn.
                if activeTelegramTurnOrigin == .local {
                    activeTelegramTurnOrigin = .telegramLease(lease)
                }
            }
            telegramVoiceTranscriptions.resume()
            await synchronizeTelegramTurnProgressReporting()
            let chatTitle = telegramLinkedChatTitle?.nilIfBlank ?? "chat \(linkedChatID)"
            await writeSystemMessage(
                """
                Telegram remote control is active.
                Linked chat: \(chatTitle)

                """
            )
            // Legacy settings without an owner-bearing route remain fail-closed
            // until the first authorized ingress migrates their private binding.
        } catch {
            telegramControlState = await telegramControlService.currentState()
            telegramControlState.lastError = error.localizedDescription
            await synchronizeTelegramTurnProgressReporting()
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    /// Restores the owner-bearing route persisted by setup so `/telegram on`
    /// enables egress immediately, without requiring a fresh Telegram message.
    ///
    /// The route is resolved through the ACL authority rather than synthesized
    /// from `linkedChatID`; every later wire operation therefore retains the
    /// generation and lifecycle validation introduced by multi-session routing.
    func telegramEgressRouteLease(
        settings: AgentTelegramSettingsManifest,
        linkedChatID: Int64
    ) async -> TerminalTelegramRouteLease? {
        guard settings.isRoutingSupported else { return nil }
        await telegramSessionRouter.refresh(
            routes: settings.routes,
            groupsEnabled: settings.groupsEnabled
        )
        let candidates = settings.routes.filter {
            $0.chatID == linkedChatID
                && $0.topicID == nil
                && $0.lifecycle == .active
                && ($0.roomID == sessionID || $0.roomID == "default")
        }
        guard candidates.count == 1, let route = candidates.first else { return nil }
        return try? await telegramSessionRouter.resolve(
            chatID: route.chatID,
            userID: route.ownerUserID,
            topicID: nil,
            chatKind: route.chatKind
        )
    }

    func stopTelegramControl() async {
        // Disconnect the current turn before hopping to the service actor, so
        // events emitted while `stop()` is in flight cannot enqueue more output.
        telegramControlState.isActive = false
        await telegramVoiceTranscriptions.cancelAllAndWait()
        let validationTask = telegramRouteValidationTask
        telegramRouteValidationTask = nil
        validationTask?.cancel()
        await validationTask?.value
        let reporter = activeTelegramProgressReporter
        activeTelegramProgressReporter = nil
        if let reporter { await reporter.shutdown() }
        if let presence = activeTelegramPresenceLease {
            await telegramControlService.releasePresenceLease(presence)
            activeTelegramPresenceLease = nil
        }
        if let lease = activeTelegramTurnOrigin?.telegramLease {
            await telegramRouteRuntimeState.teardown(lease: lease)
        }
        // Unbind before stopping the transport so no card is queued for a chat
        // that is about to be released. The ledger is retained on purpose.
        await telegramSharedChatRelay.deactivate()
        telegramControlState = await telegramControlService.stop()
        telegramActiveRouteLease = nil
        telegramLinkedChatID = nil
        telegramLinkedChatTitle = nil
        telegramLinkedUserID = nil
        // Deterministic inbound-attachment teardown: every received temporary
        // is deleted and every pending upload consent is dropped.
        _ = await telegramControlService.cleanupInboundAttachments()
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
        let previousValidationTask = telegramRouteValidationTask
        telegramRouteValidationTask = nil
        previousValidationTask?.cancel()
        await previousValidationTask?.value
        await activeTelegramProgressReporter?.revokeAndWait()
        activeTelegramProgressReporter = nil
        activeTelegramTurnOrigin = origin
        resetTelegramRootResponseBlock()
        resetMirroredOverviewSignatures()
        // Fence off any undelivered mirror notification from the previous
        // turn before the new turn's reporter exists: stale-epoch deliveries
        // are discarded instead of being adopted by the new reporter.
        currentTelegramMirrorEpoch = await renderCoordinator.advanceMirrorEpoch()
        await synchronizeTelegramTurnProgressReporting()
        await beginTelegramTurnPresenceIfNeeded()
        if let lease = origin.telegramLease, let eventQueue = telegramRuntimeEventQueue {
            let router = telegramSessionRouter
            telegramRouteValidationTask = Task(name: "ZenCODE.Telegram.route-validation") {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                    guard (try? await router.validate(lease)) != nil else {
                        _ = await eventQueue.sendWithBackpressure(
                            .telegramRouteInvalidated(lease)
                        )
                        return
                    }
                }
            }
        }
    }

    /// Takes the lifecycle-safe typing lease for a mirrored turn. Presence is
    /// best-effort: a chat action that fails says nothing about the link or the
    /// turn, so failures are silent. The lease is released in
    /// `endTelegramTurnProgressReporting` and fenced by generation, so a
    /// renewal that wakes after teardown exits without touching the wire.
    private func beginTelegramTurnPresenceIfNeeded() async {
        guard let origin = activeTelegramTurnOrigin,
              await validateTelegramOrigin(origin),
              let chatID = telegramOutgoingChatID(for: origin),
              let fence = telegramWireFence(for: origin) else {
            return
        }
        activeTelegramPresenceLease = await telegramControlService.acquirePresenceLease(
            scope: .turn(
                chatID: chatID,
                topicID: origin.telegramLease?.effectiveMessageThreadID
            ),
            fence: fence
        )
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
    func synchronizeTelegramTurnProgressReporting() async {
        guard let origin = activeTelegramTurnOrigin,
              let chatID = telegramOutgoingChatID(for: origin) else {
            if activeTelegramProgressReporter != nil {
                suppressTelegramRootResponseBlockIfStreaming()
            }
            let retired = activeTelegramProgressReporter
            if let retired { await retired.revokeAndWait() }
            activeTelegramProgressReporter = nil
            return
        }
        guard activeTelegramProgressReporter?.chatID != chatID else {
            return
        }
        suppressTelegramRootResponseBlockIfStreaming()
        activeTelegramProgressReporter = makeTelegramTurnProgressReporter(for: origin)
    }

    func endTelegramTurnProgressReporting() async {
        let validationTask = telegramRouteValidationTask
        telegramRouteValidationTask = nil
        validationTask?.cancel()
        await validationTask?.value
        let retiredReporter = activeTelegramProgressReporter
        if let retiredReporter { await retiredReporter.revokeAndWait() }
        if let lease = activeTelegramPresenceLease {
            await telegramControlService.releasePresenceLease(lease)
        }
        activeTelegramPresenceLease = nil
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

        guard let lease = origin.telegramLease,
              let chatID = telegramOutgoingChatID(for: origin) else {
            await writeFailureMessage(
                "ZenCODE: Telegram cannot request permission for \(request.toolName); the operation was denied.\n"
            )
            return false
        }

        let terminalAlreadyAuthorized = await permissionAuthorizer.isAlreadyAuthorized(request)
        let telegramAlreadyAuthorized: Bool
        guard (try? await telegramSessionRouter.validate(lease)) != nil else { return false }
        telegramAlreadyAuthorized = await telegramPermissionBroker.isAlreadyAuthorized(
            request, lease: lease
        )
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
                let send: @Sendable (String) async -> Bool = { [weak self] message in
                    guard let self, await self.validateTelegramOrigin(origin) else { return false }
                    return await self.sendTelegramTurnMessage(
                        .authorization(message), to: chatID, origin: origin
                    )
                }
                let outcome: TerminalTelegramPermissionOutcome
                outcome = await telegramPermissionBroker.authorize(
                    request, lease: lease, sendMessage: send
                )
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
                to: chatID,
                origin: origin
            )
            return approved
        case let .telegram(outcome):
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
        lease: TerminalTelegramRouteLease
    ) async -> Bool {
        guard (try? await telegramSessionRouter.validate(lease)) != nil else { return true }
        let result = await telegramPermissionBroker.handleMessage(text, lease: lease)
        switch result {
        case .notHandled:
            return false
        case let .handled(reply):
            if let reply = reply?.nilIfBlank {
                await sendTelegramTurnMessage(
                    .authorization(reply), to: lease.key.chatID,
                    origin: .telegramLease(lease)
                )
            }
            return true
        }
    }

    func sendTelegramSystemMessageIfLinked(
        _ message: String,
        origin: TerminalPromptOrigin
    ) async {
        guard await validateTelegramOrigin(origin),
              let chatID = telegramOutgoingChatID(for: origin) else {
            return
        }
        await sendTelegramSystemMessage(
            message, to: chatID, origin: origin
        )
    }

    /// Publishes an authorization message on the ordered Telegram channel.
    ///
    /// While a mirrored turn is generating, its reporter owns the outgoing
    /// order. Bot control messages deliberately use `sendTelegramSystemMessage`
    /// instead.
    @discardableResult
    func sendTelegramTurnMessage(
        _ payload: TerminalTelegramTurnPayload,
        to chatID: Int64,
        origin: TerminalPromptOrigin
    ) async -> Bool {
        guard telegramControlState.isActive else {
            return false
        }
        if let reporter = activeTelegramProgressReporter, reporter.chatID == chatID {
            return await reporter.send(payload)
        }
        if let onDirectTelegramTurnMessage {
            return await onDirectTelegramTurnMessage(payload, chatID)
        }
        return await sendTelegramSystemMessage(payload.text, to: chatID, origin: origin)
    }

    func sendTelegramTurnMessageIfLinked(
        _ payload: TerminalTelegramTurnPayload,
        origin: TerminalPromptOrigin
    ) async {
        guard await validateTelegramOrigin(origin),
              let chatID = telegramOutgoingChatID(for: origin) else {
            return
        }
        await sendTelegramTurnMessage(payload, to: chatID, origin: origin)
    }

    /// Returns the linked chat to use for outgoing messages, when Telegram
    /// remote control is active. Local prompts are forwarded to the linked
    /// chat so the session keeps replying on Telegram after `/telegram on`,
    /// even without an incoming Telegram request.
    func telegramOutgoingChatID(for origin: TerminalPromptOrigin) -> Int64? {
        guard telegramControlState.isActive, let lease = origin.telegramLease else { return nil }
        return lease.key.chatID
    }

    /// Queue/start/egress fence for a route-scoped turn. Local and legacy
    /// origins retain their source-compatible behavior.
    func validateTelegramOrigin(_ origin: TerminalPromptOrigin) async -> Bool {
        guard let lease = origin.telegramLease else { return false }
        guard telegramControlState.isActive else { return false }
        return (try? await telegramSessionRouter.validate(lease)) != nil
    }

    func telegramWireFence(for origin: TerminalPromptOrigin) -> TerminalTelegramWireFence? {
        guard let lease = origin.telegramLease,
              let lifecycleEpoch = telegramControlState.wireLifecycleEpoch else { return nil }
        return TerminalTelegramWireFence(
            lease: lease,
            lifecycleEpoch: lifecycleEpoch,
            validateLease: { [telegramSessionRouter] lease in
                try await telegramSessionRouter.validate(lease)
            }
        )
    }

    /// Sends a message to a Telegram chat, reporting whether it was delivered.
    ///
    /// Delivery status is part of the contract: a permission request that never
    /// reached the chat must fail closed instead of holding the turn.
    @discardableResult
    func sendTelegramSystemMessage(
        _ message: String, to chatID: Int64, origin: TerminalPromptOrigin
    ) async -> Bool {
        guard let lease = origin.telegramLease,
              lease.key.chatID == chatID,
              let fence = telegramWireFence(for: origin),
              await validateTelegramOrigin(origin) else { return false }
        return await sendTelegramSystemMessage(
            message, to: chatID, topicID: lease.effectiveMessageThreadID, fence: fence
        )
    }

    @discardableResult
    func sendTelegramSystemMessage(
        _ message: String, to chatID: Int64, topicID: Int? = nil,
        fence: TerminalTelegramWireFence
    ) async -> Bool {
        if let onTelegramRoutedSystemMessage {
            return await onTelegramRoutedSystemMessage(message, chatID, topicID)
        }
        if let onTelegramSystemMessage {
            return await onTelegramSystemMessage(message, chatID)
        }
        do {
            telegramControlState = try await telegramControlService.sendMessage(
                message, to: chatID, topicID: topicID, fence: fence
            )
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
        Remote commands: /status, /changes, /diff, /report, /help, /plan <goal> and its subcommands, /goal <goal>, /review [focus].
        /diff and /report send a file only after you confirm it with an explicit button; nothing is uploaded automatically.
        Documents and images you send are received selectively (text, markdown, csv, json, yaml, pdf, rtf, word, odt and images) and kept as private temporaries.
        While /plan is asking questions, ordinary replies continue that same runtime discussion.
        While /goal is waiting for an answer, ordinary replies continue that same workflow task graph.
        Permission replies: /allow ID, /always ID, /deny ID.
        Gated operations (shell commands, deletions, git push/restore) are asked here.
        Turn Telegram off from the TUI with /telegram off.
        """
    }

    @discardableResult
    private func sendTelegramProgressMessage(
        _ message: String, to chatID: Int64, topicID: Int? = nil,
        fence: TerminalTelegramWireFence
    ) async -> Bool {
        guard telegramControlState.isActive else {
            return false
        }
        do {
            _ = try await telegramControlService.sendRichMessageWithFallback(
                message, to: chatID, topicID: topicID, fence: fence
            )
            return true
        } catch {
            return false
        }
    }

    func makeTelegramTurnProgressReporter(
        for origin: TerminalPromptOrigin
    ) -> TerminalTelegramTurnProgressReporter? {
        guard let lease = origin.telegramLease,
              let chatID = telegramOutgoingChatID(for: origin),
              let lifecycleEpoch = telegramControlState.wireLifecycleEpoch else {
            return nil
        }

        let service = telegramControlService
        let wireFence = TerminalTelegramWireFence(
            lease: lease,
            lifecycleEpoch: lifecycleEpoch,
            validateLease: { [telegramSessionRouter] lease in
                try await telegramSessionRouter.validate(lease)
            }
        )
        let topicID = origin.telegramLease?.effectiveMessageThreadID
            ?? origin.telegramRoute?.topicID
        let routeAllowsPrivateDraft = origin.telegramRoute.map { key in
            AgentSettingsManifestStore.load()?.telegram?.routes.first {
                $0.chatID == key.chatID && $0.topicID == key.topicID && $0.roomID == key.roomID
            }?.chatKind == .privateChat
        } ?? true
        let cards = TerminalTelegramProgressCardLedger(
            chatID: chatID,
            send: { [weak self] text, chatID in
                guard let self, await self.validateTelegramOrigin(origin) else {
                    throw CancellationError()
                }
                return try await service.sendPlainMessageWithReceipt(
                    text, to: chatID, topicID: topicID, fence: wireFence
                )
            },
            editText: { [weak self] text, chatID, messageID in
                guard let self, await self.validateTelegramOrigin(origin) else {
                    throw CancellationError()
                }
                try await service.editMessageText(
                    text, chatID: chatID, messageID: messageID, fence: wireFence
                )
            },
            editMarkup: { [weak self] markup, chatID, messageID in
                guard let self, await self.validateTelegramOrigin(origin) else {
                    throw CancellationError()
                }
                try await service.editMessageReplyMarkup(
                    markup, chatID: chatID, messageID: messageID, fence: wireFence
                )
            },
            delete: { [weak self] chatID, messageID in
                guard let self, await self.validateTelegramOrigin(origin) else {
                    throw CancellationError()
                }
                try await service.deleteMessage(
                    chatID: chatID, messageID: messageID, fence: wireFence
                )
            }
        )
        let sendDraft: (@Sendable (String, Int64, Int) async throws -> Void)?
        if routeAllowsPrivateDraft {
            sendDraft = { [weak self] text, chatID, draftID in
                guard let self, await self.validateTelegramOrigin(origin) else {
                    throw CancellationError()
                }
                try await service.sendRichMessageDraftWithFallback(
                    text, to: chatID, draftID: draftID, fence: wireFence
                )
            }
        } else {
            sendDraft = nil
        }
        return TerminalTelegramTurnProgressReporter(
            chatID: chatID,
            sendMessage: { [weak self] message, chatID in
                guard let self, await self.validateTelegramOrigin(origin) else { return false }
                return await self.sendTelegramProgressMessage(
                    message, to: chatID, topicID: topicID, fence: wireFence
                )
            },
            sendDraft: sendDraft,
            progressCards: cards,
            wireFence: wireFence,
            waitForWireQuiescence: { fence in
                await service.waitForWireQuiescence(fence: fence)
            }
        )
    }

}

