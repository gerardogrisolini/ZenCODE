//
//  TerminalChat+TelegramEgress.swift
//  ZenCODE
//

import Foundation
import ToolCore

private enum TerminalTelegramAuthorizationChannelResult: Sendable {
    case terminal(LocalExecPermissionAuthorizer.AuthorizationOutcome)
    case telegram(TerminalTelegramPermissionOutcome)
}

extension TerminalChat {
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

    /// Cross-extension visibility: `/telegram` status in the lifecycle extension
    /// renders this text.
    func telegramStatusText() -> String {
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

    /// Cross-extension visibility: the ingress dispatcher mirrors `/status` and
    /// `/changes` through this text while the busy gate is open.
    func telegramRemoteStatusText() -> String {
        let agent = selectedAgent?.displayName ?? AgentProfileStore.developerAgentName
        let model = currentEffectiveModelID() ?? "default model"
        return "Session active.\nAgent: \(agent)\nModel: \(model)\nWorking directory: \(configuration.workingDirectory.path)"
    }

    /// Cross-extension visibility: the ingress dispatcher serves `/changes`.
    func telegramRemoteChangesText() -> String {
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
        return TerminalTelegramTurnProgressReporter(
            chatID: chatID,
            sendMessage: { [weak self] message, chatID in
                guard let self, await self.validateTelegramOrigin(origin) else { return false }
                return await self.sendTelegramProgressMessage(
                    message, to: chatID, topicID: topicID, fence: wireFence
                )
            },
            sendDraft: { [weak self] text, chatID, draftID in
                guard let self, await self.validateTelegramOrigin(origin) else {
                    throw CancellationError()
                }
                try await service.sendRichMessageDraftWithFallback(
                    text, to: chatID, draftID: draftID, fence: wireFence
                )
            },
            progressCards: cards,
            wireFence: wireFence,
            waitForWireQuiescence: { fence in
                await service.waitForWireQuiescence(fence: fence)
            }
        )
    }

}
