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

    func submittedTelegramLineAction(_ prompt: String) async -> TerminalSubmittedLineAction {
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
            return .runPrompt(prompt)
        }
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

        if let voice = message.voice {
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
            await sendTelegramTurnMessage(
                activationMessage,
                to: linkedChatID
            )
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
        resetMirroredOverviewSignatures()
        // Fence off any undelivered mirror notification from the previous
        // turn before the new turn's reporter exists: stale-epoch deliveries
        // are discarded instead of being adopted by the new reporter.
        currentTelegramMirrorEpoch = await renderCoordinator.advanceMirrorEpoch()
        synchronizeTelegramTurnProgressReporting()
    }

    /// Reconciles the current turn with the latest Telegram on/off state.
    /// Existing reporters are retained for the same chat so buffered narration
    /// and tool events keep their ordering across a repeated `/telegram on`.
    func synchronizeTelegramTurnProgressReporting() {
        guard let origin = activeTelegramTurnOrigin,
              let chatID = telegramOutgoingChatID(for: origin) else {
            activeTelegramProgressReporter = nil
            return
        }
        guard activeTelegramProgressReporter?.chatID != chatID else {
            return
        }
        activeTelegramProgressReporter = makeTelegramTurnProgressReporter(for: origin)
    }

    func endTelegramTurnProgressReporting() {
        activeTelegramProgressReporter = nil
        activeTelegramTurnOrigin = nil
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
                    await self?.sendTelegramTurnMessage(message, to: chatID) ?? false
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
                approved
                    ? "✅ Permission granted in the terminal for \(request.toolName). Continuing."
                    : "⛔ Permission denied in the terminal for \(request.toolName).",
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
                await sendTelegramTurnMessage(reply, to: chatID)
            }
            return true
        }
    }

    func sendTelegramCompletionIfLinked(
        _ text: String,
        origin: TerminalPromptOrigin
    ) async {
        await sendTelegramSystemMessageIfLinked(
            "*ZenCODE completed*\n\n\(String(text.prefix(3_600)))",
            origin: origin
        )
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

    /// Publishes a turn-scoped message on the ordered Telegram channel.
    ///
    /// While a mirrored turn is generating, its reporter owns the outgoing
    /// order: enqueueing here keeps permission dialogue behind the tool call
    /// that raised it instead of racing the progress queue. Outside a turn
    /// there is no queue to preserve, so the message is sent directly.
    @discardableResult
    func sendTelegramTurnMessage(_ message: String, to chatID: Int64) async -> Bool {
        guard telegramControlState.isActive,
              telegramLinkedChatID == chatID else {
            return false
        }
        if let reporter = activeTelegramProgressReporter, reporter.chatID == chatID {
            return await reporter.send(message)
        }
        return await sendTelegramSystemMessage(message, to: chatID)
    }

    func sendTelegramTurnMessageIfLinked(
        _ message: String,
        origin: TerminalPromptOrigin
    ) async {
        guard let chatID = telegramOutgoingChatID(for: origin) else {
            return
        }
        await sendTelegramTurnMessage(message, to: chatID)
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

    private func telegramRemoteHelpText() -> String {
        """
        Send a message to prompt the current ZenCODE TUI session.
        Remote commands: /status, /changes, /help.
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

