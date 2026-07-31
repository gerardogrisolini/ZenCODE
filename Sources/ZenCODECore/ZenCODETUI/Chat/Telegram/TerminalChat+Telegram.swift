//
//  TerminalChat+Telegram.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    func handleTelegramCommand(_ command: String) async {
        let argument = String(command.dropFirst("/telegram".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

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
                guard eventQueue.send(.telegramMessage(message)) else {
                    // The runtime loop has finished; stop forwarding.
                    return
                }
            }
        }
    }

    func handleTelegramMessage(
        _ message: TerminalTelegramIncomingMessage,
        queuedPrompts: inout [TerminalQueuedPrompt],
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

        queuedPrompts.append(
            TerminalQueuedPrompt(text: text, origin: .telegram(chatID: message.chatID))
        )
    }

    func handleTelegramVoiceMessage(
        _ voice: TerminalTelegramVoiceAttachment,
        chatID: Int64,
        eventQueue: TerminalChatEventQueue,
        transcriptions: TerminalVoiceTranscriptionRegistry
    ) async {
        guard isVoiceConfigured() else {
            await sendTelegramSystemMessage(
                "Voice input is not configured. Run the /setup command in zen and enable voice input.",
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
                    .transcribe(audio) { message in
                        eventQueue.send(
                            .voicePromptProgress(
                                TerminalVoicePromptProgress(
                                    origin: .telegram(chatID: chatID),
                                    message: message
                                )
                            )
                        )
                    }
                eventQueue.send(
                    .voicePromptCompleted(
                        TerminalVoicePromptResult(
                            origin: .telegram(chatID: chatID),
                            outcome: .success(transcript)
                        )
                    )
                )
            } catch is CancellationError {
                // Teardown or an explicit cancel: the runtime loop is gone, so
                // no completion event is reported.
                return
            } catch {
                eventQueue.send(
                    .voicePromptCompleted(
                        TerminalVoicePromptResult(
                            origin: .telegram(chatID: chatID),
                            outcome: .failure(error.localizedDescription)
                        )
                    )
                )
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
            let chatTitle = telegramLinkedChatTitle?.nilIfBlank ?? "chat \(linkedChatID)"
            await writeSystemMessage(
                """
                Telegram remote control is active.
                Linked chat: \(chatTitle)

                """
            )
            await sendTelegramSystemMessage(
                """
                ZenCODE remote control is active. Send a prompt or /help to begin.
                """,
                to: linkedChatID
            )
        } catch {
            telegramControlState.lastError = error.localizedDescription
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    func stopTelegramControl() async {
        telegramControlState = await telegramControlService.stop()
        telegramLinkedChatID = nil
        telegramLinkedChatTitle = nil
        await writeSystemMessage("Telegram remote control stopped.\n")
    }

    func printTelegramStatus() async {
        telegramControlState = await telegramControlService.currentState()
        await writeSystemMessage(telegramStatusText() + "\n")
    }

    /// Returns the authorization handler for a turn whose progress is mirrored
    /// to Telegram.
    ///
    /// Both routes gate exactly the terminal authorizer's set, so a mirrored
    /// turn can never perform an operation a purely local turn would have to
    /// confirm. They differ only in who is asked:
    ///
    /// * a prompt that arrived from Telegram is answered on Telegram, and the
    ///   terminal only reports the pending request. Presenting the blocking
    ///   terminal dialog to an operator who is not at the machine is what left
    ///   the session waiting with nothing asked anywhere;
    /// * a prompt typed locally keeps the terminal dialog, and the linked chat
    ///   is told that the turn is waiting for a local decision instead of
    ///   appearing to stall.
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

        guard let remoteChatID = origin.telegramChatID else {
            return await authorizeLocalToolRequestMirroredToTelegram(
                request,
                origin: origin
            )
        }

        guard telegramLinkedChatID == remoteChatID,
              telegramControlState.isActive else {
            // The chat that submitted the prompt can no longer be asked, and
            // nobody is at the terminal for it: refuse instead of running an
            // unconfirmed gated operation.
            await writeFailureMessage(
                "ZenCODE: Telegram cannot request permission for \(request.toolName); the operation was denied.\n"
            )
            return false
        }

        return await authorizeRemoteToolRequest(request, chatID: remoteChatID)
    }

    /// Asks the Telegram chat that submitted the prompt.
    private func authorizeRemoteToolRequest(
        _ request: AgentToolAuthorizationRequest,
        chatID: Int64
    ) async -> Bool {
        if await telegramPermissionBroker.isAlreadyAuthorized(request) {
            return true
        }
        await writeSystemMessage(Self.telegramPermissionPendingText(for: request))

        let outcome = await telegramPermissionBroker.authorize(
            request,
            chatID: chatID
        ) { [weak self] message in
            await self?.sendTelegramTurnMessage(message, to: chatID) ?? false
        }

        await writeTelegramPermissionOutcome(outcome, request: request)
        return outcome.isApproved
    }

    /// Keeps the terminal dialog authoritative for a locally submitted prompt
    /// while telling the mirrored chat why the turn paused.
    private func authorizeLocalToolRequestMirroredToTelegram(
        _ request: AgentToolAuthorizationRequest,
        origin: TerminalPromptOrigin
    ) async -> Bool {
        guard !(await permissionAuthorizer.isAlreadyAuthorized(request)) else {
            return await permissionAuthorizer.authorize(request)
        }

        await sendTelegramTurnMessageIfLinked(
            """
            🔐 Permission required in the ZenCODE terminal
            \(request.title)

            Tool:
            \(request.toolName)

            Command:
            \(request.command)

            Waiting for the local operator to answer.
            """,
            origin: origin
        )
        let approved = await permissionAuthorizer.authorize(request)
        await sendTelegramTurnMessageIfLinked(
            approved
                ? "✅ Permission granted in the terminal for \(request.toolName). Continuing."
                : "⛔ Permission denied in the terminal for \(request.toolName).",
            origin: origin
        )
        return approved
    }

    private static func telegramPermissionPendingText(
        for request: AgentToolAuthorizationRequest
    ) -> String {
        """

        Telegram permission required: \(request.title)
        Waiting for /allow, /always or /deny in the linked chat.

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

    func makeTelegramTurnProgressReporter(
        for origin: TerminalPromptOrigin
    ) -> TerminalTelegramTurnProgressReporter? {
        guard let chatID = telegramOutgoingChatID(for: origin) else {
            return nil
        }

        return TerminalTelegramTurnProgressReporter(chatID: chatID) { [weak self] message, chatID in
            await self?.sendTelegramSystemMessage(message, to: chatID) ?? false
        }
    }

}

