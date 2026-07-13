//
//  TerminalChat+Telegram.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation

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
            writeSystemMessage("Usage: /telegram [on|off]\n")
        }
    }

    func submittedTelegramLineAction(_ prompt: String) -> TerminalSubmittedLineAction {
        switch TerminalTelegramRemoteCommand(text: prompt) {
        case .start:
            Task {
                await sendTelegramSystemMessageIfLinked(
                    "Telegram is already linked to this ZenCODE session. Send a prompt or /help."
                )
            }
            return .continueChat
        case .help:
            Task {
                await sendTelegramSystemMessageIfLinked(telegramRemoteHelpText())
            }
            return .continueChat
        case .status:
            Task {
                await sendTelegramSystemMessageIfLinked(telegramRemoteStatusText())
            }
            return .continueChat
        case .changes:
            Task {
                await sendTelegramSystemMessageIfLinked(telegramRemoteChangesText())
            }
            return .continueChat
        case .undo:
            Task {
                await sendTelegramSystemMessageIfLinked(
                    "Use /undo in the TUI to revert file changes."
                )
            }
            return .continueChat
        case .none:
            return .runPrompt(prompt)
        }
    }

    func startTelegramForwardingTask(
        eventQueue: TerminalChatEventQueue
    ) -> Task<Void, Never> {
        let service = telegramControlService
        return Task { [weak self] in
            for await message in service.incomingMessages {
                guard self != nil else {
                    return
                }
                eventQueue.send(.telegramMessage(message))
            }
        }
    }

    func handleTelegramMessage(
        _ message: TerminalTelegramIncomingMessage,
        isGenerating: Bool,
        queuedPrompts: inout [TerminalQueuedPrompt],
        eventQueue: TerminalChatEventQueue
    ) async {
        guard telegramControlState.isActive else {
            return
        }

        guard telegramLinkedChatID != nil else {
            await sendTelegramSystemMessage(
                "Telegram is not paired. Run zen --setup to pair this bot.",
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
                eventQueue: eventQueue
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
        await sendTelegramSystemMessage(
            isGenerating
                ? "Queued for the current ZenCODE session."
                : "Received. ZenCODE is working.",
            to: message.chatID
        )
    }

    func handleTelegramVoiceMessage(
        _ voice: TerminalTelegramVoiceAttachment,
        chatID: Int64,
        eventQueue: TerminalChatEventQueue
    ) async {
        guard isVoiceConfigured() else {
            await sendTelegramSystemMessage(
                "Voice input is not configured. Run zen --setup and enable voice input.",
                to: chatID
            )
            return
        }

        await sendTelegramSystemMessage("Voice received. Transcribing...", to: chatID)
        Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.telegramControlService.downloadVoiceAudio(voice)
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
    }

    func writeTelegramSubmittedPrompt(_ prompt: String) {
        let title = telegramLinkedChatTitle?.nilIfBlank ?? "Telegram"
        writeSystemMessage("\n\(title) sent a prompt:\n")
        writeSubmittedPrompt(prompt)
    }

    func startTelegramControl() async {
        guard stdinIsTerminal else {
            writeFailureMessage("ZenCODE: /telegram requires the interactive TUI.\n")
            return
        }
        guard isTelegramConfigured() else {
            writeFailureMessage(Self.unknownCommandMessage(for: "/telegram"))
            return
        }
        guard let settings = AgentSettingsManifestStore.load()?.telegram,
              let linkedChatID = settings.linkedChatID else {
            writeFailureMessage("ZenCODE: Telegram is not paired. Run zen --setup.\n")
            return
        }

        do {
            telegramLinkedChatID = linkedChatID
            telegramLinkedChatTitle = settings.linkedChatTitle
                        telegramControlState = try await telegramControlService.start()
            let chatTitle = telegramLinkedChatTitle?.nilIfBlank ?? "chat \(linkedChatID)"
            writeSystemMessage(
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
            writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    func stopTelegramControl() async {
        telegramControlState = await telegramControlService.stop()
        telegramLinkedChatID = nil
        telegramLinkedChatTitle = nil
        writeSystemMessage("Telegram remote control stopped.\n")
    }

    func printTelegramStatus() async {
        telegramControlState = await telegramControlService.currentState()
        writeSystemMessage(telegramStatusText() + "\n")
    }

    func telegramToolAuthorizationHandler(
        for origin: TerminalPromptOrigin
    ) -> AgentToolAuthorizationHandler? {
        guard origin.telegramChatID != nil else {
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
        guard request.toolName == "local.exec" else {
            return true
        }
        guard let chatID = origin.telegramChatID,
              telegramLinkedChatID == chatID,
              telegramControlState.isActive else {
            return false
        }

        return await telegramPermissionBroker.authorize(request, chatID: chatID) { [weak self] message in
            await self?.sendTelegramSystemMessage(message, to: chatID)
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
                await sendTelegramSystemMessage(reply, to: chatID)
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

    func sendTelegramSystemMessage(_ message: String, to chatID: Int64) async {
        do {
            telegramControlState = try await telegramControlService.sendMessage(message, to: chatID)
        } catch {
            telegramControlState.lastError = error.localizedDescription
            writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
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
        let agent = selectedAgent?.displayName ?? "Default"
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
            await self?.sendTelegramSystemMessage(message, to: chatID)
        }
    }

    func telegramTurnStartedMessage(prompt: String) -> String {
        guard let promptPreview = prompt.nilIfBlank else {
            return "*ZenCODE* is working…"
        }
        return "*ZenCODE* is working…\n\(Self.truncatedInline(promptPreview, limit: 300))"
    }

    func telegramToolStartedMessage(_ toolCall: DirectAgentToolCall) -> String {
        let kind = ToolCallPresentation.toolKind(for: toolCall.name)
        guard let target = ToolCallPresentation.displayToolTarget(for: toolCall)?.nilIfBlank else {
            return "🔧 \(kind)"
        }
        let fileName = URL(fileURLWithPath: target).lastPathComponent.nilIfBlank ?? target
        return "🔧 \(kind) · \(Self.truncatedInline(fileName, limit: 120))"
    }

    func telegramFileChangeSummaryMessage(_ summary: TurnFileChangeSummary) -> String {
        let title = summary.fileCount == 1
            ? "1 modified file"
            : "\(summary.fileCount) modified files"
        var lines = [
            "*File changes*",
            "\(title)  +\(summary.totalAdditions) -\(summary.totalDeletions)"
        ]
        let visibleEntries = summary.entries.prefix(12).map(Self.renderFileChangeEntry)
        lines.append(contentsOf: visibleEntries)
        if summary.entries.count > visibleEntries.count {
            lines.append("... \(summary.entries.count - visibleEntries.count) more")
        }
        lines.append(summary.canUndo ? "Use /undo in the TUI to revert." : "Undo is not available.")
        return lines.joined(separator: "\n")
    }

}

