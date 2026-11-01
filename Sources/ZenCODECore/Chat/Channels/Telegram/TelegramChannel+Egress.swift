//
//  TelegramChannel+Egress.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

extension TelegramChannel {
    // MARK: - Route checks

    /// The linked chat outgoing messages on `lease` go to, while the link is
    /// active.
    func outgoingChatID(for lease: TerminalTelegramRouteLease) -> Int64? {
        guard controlState.isActive else { return nil }
        return lease.key.chatID
    }

    /// Queue, start, and egress fence for a route-scoped send: the link is
    /// active and the router still validates `lease`.
    func validateLease(_ lease: TerminalTelegramRouteLease) async -> Bool {
        guard controlState.isActive else { return false }
        return (try? await router.validate(lease)) != nil
    }

    /// The wire fence of `lease` for the control service's current
    /// lifecycle, or `nil` without a started lifecycle.
    func wireFence(for lease: TerminalTelegramRouteLease) -> TerminalTelegramWireFence? {
        guard let lifecycleEpoch = controlState.wireLifecycleEpoch else { return nil }
        return TerminalTelegramWireFence(
            lease: lease,
            lifecycleEpoch: lifecycleEpoch,
            validateLease: { [router] lease in
                try await router.validate(lease)
            }
        )
    }

    // MARK: - System messages

    /// Sends a bot-control message to the linked chat on `lease`, when the
    /// route is still valid.
    func sendSystemMessageIfLinked(
        _ message: String,
        lease: TerminalTelegramRouteLease
    ) async {
        guard await validateLease(lease),
              let chatID = outgoingChatID(for: lease) else {
            return
        }
        await sendSystemMessage(message, to: chatID, lease: lease)
    }

    /// Sends a bot-control message on the link's route, when the link is
    /// active: the texts of the session outside a turn's reporter (a notice,
    /// the handover context).
    func sendSessionText(_ text: String) async {
        guard let lease = activeRouteLease,
              let message = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            return
        }
        await sendSystemMessageIfLinked(message, lease: lease)
    }

    /// Sends a message to a Telegram chat, reporting whether it was
    /// delivered.
    ///
    /// Delivery status is part of the contract: a permission request that
    /// never reached the chat must fail closed instead of holding the turn.
    @discardableResult
    func sendSystemMessage(
        _ message: String, to chatID: Int64, lease: TerminalTelegramRouteLease
    ) async -> Bool {
        guard lease.key.chatID == chatID,
              let fence = wireFence(for: lease),
              await validateLease(lease) else { return false }
        return await sendSystemMessage(
            message, to: chatID, topicID: lease.effectiveMessageThreadID, fence: fence
        )
    }

    /// Sends a message under `fence`. A failure is recorded as the control
    /// state's `lastError` and presented on the primary channel.
    @discardableResult
    func sendSystemMessage(
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
            controlState = try await controlService.sendMessage(
                message, to: chatID, topicID: topicID, fence: fence
            )
            return true
        } catch {
            let description = TerminalTelegramControlError.operatorDescription(error)
            controlState.lastError = description
            await presentNotice("ZenCODE: \(description)\n", channel: .failure)
            return false
        }
    }

    // MARK: - Turn messages

    /// Publishes a turn message on the ordered Telegram channel.
    ///
    /// While a turn is generating, its reporter owns the outgoing order.
    /// Bot-control messages deliberately use ``sendSystemMessage(_:to:lease:)``
    /// instead.
    @discardableResult
    func sendTurnMessage(
        _ payload: TerminalTelegramTurnPayload,
        to chatID: Int64,
        lease: TerminalTelegramRouteLease
    ) async -> Bool {
        guard controlState.isActive else {
            return false
        }
        if let reporter = activeProgressReporter, reporter.chatID == chatID {
            return await reporter.send(payload)
        }
        if let onDirectTelegramTurnMessage {
            return await onDirectTelegramTurnMessage(payload, chatID)
        }
        return await sendSystemMessage(payload.text, to: chatID, lease: lease)
    }

    /// Publishes a turn message to the linked chat on `lease`, when the
    /// route is still valid.
    func sendTurnMessageIfLinked(
        _ payload: TerminalTelegramTurnPayload,
        lease: TerminalTelegramRouteLease
    ) async {
        guard await validateLease(lease),
              let chatID = outgoingChatID(for: lease) else {
            return
        }
        await sendTurnMessage(payload, to: chatID, lease: lease)
    }

    // MARK: - Handover context

    /// How many transcript entries the chat receives as context when the
    /// slot is handed to Telegram: the last prompts and responses, enough to
    /// read the conversation's thread without replaying it. Thoughts and
    /// tool calls are left out.
    public static let handoverContextEntryCount = 6

    /// Sends the context of the handover to the linked chat: the last
    /// ``handoverContextEntryCount`` entries of `transcript` (prompts and
    /// assistant text only), each as a compact message, then the assistant
    /// text still streaming, if any, marked as in progress. Nothing is sent
    /// for an empty transcript.
    func sendHandoverContext(transcript: [ChatTurnEntry], liveAssistantText: String) async {
        guard let lease = activeRouteLease else { return }
        let entries = transcript.suffix(Self.handoverContextEntryCount)
        var lines: [String] = []
        for entry in entries {
            switch entry.kind {
            case let .userPrompt(text, _, _):
                lines.append("👤 \(Self.contextText(text))")
            case let .assistantText(text):
                lines.append("🤖 \(Self.contextText(text))")
            default:
                continue
            }
        }
        let live = liveAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty {
            lines.append("🤖 (in progress) \(Self.contextText(live))")
        }
        guard !lines.isEmpty else { return }
        let header = lines.count == 1 ? "Last message of the session:" : "Last \(lines.count) messages of the session:"
        await sendSystemMessageIfLinked(([header] + lines).joined(separator: "\n\n"), lease: lease)
    }

    /// One entry of the handover context: trimmed, bounded so the context
    /// stays a few screens at most, with an ellipsis where it was cut.
    nonisolated static func contextText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 600
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    // MARK: - Texts

    /// The `/telegram` status of the link, after reading the control
    /// service's current state. The primary channel writes it followed by a
    /// newline. In topic mode it names the session's topic.
    public func statusText() async -> String {
        controlState = await controlService.currentState()
        return Self.statusText(
            controlState: controlState, linkedChatTitle: linkedChatTitle,
            topicName: sessionTopic?.name
        )
    }

    /// The `/telegram` status text for `controlState`, the linked chat's
    /// title, and the name of the session's topic in topic mode (`nil` in
    /// legacy mode, where the text is the terminal's).
    nonisolated static func statusText(
        controlState: TerminalTelegramControlState,
        linkedChatTitle: String?,
        topicName: String? = nil
    ) -> String {
        var lines = [
            "Telegram: \(controlState.statusText)"
        ]
        if let botUsername = controlState.botUsername?.nilIfBlank {
            lines.append("Bot: @\(botUsername)")
        }
        if let title = linkedChatTitle?.nilIfBlank {
            lines.append("Linked chat: \(title)")
        }
        if let topicName = topicName?.nilIfBlank {
            lines.append("Topic: \(topicName)")
        }
        if let error = controlState.pollError?.nilIfBlank {
            lines.append("Polling error: \(error)")
        }
        if let error = controlState.commandMenuError?.nilIfBlank {
            lines.append("Command menu error: \(error)")
        }
        if let error = controlState.lastError?.nilIfBlank {
            lines.append("Last error: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    /// The answer to the remote `/status`.
    func remoteStatusText() -> String {
        let agent = controller?.selection.agent?.displayName ?? AgentProfileStore.developerAgentName
        let model = controller?.currentEffectiveModelID() ?? "default model"
        return "Session active.\nAgent: \(agent)\nModel: \(model)\nWorking directory: \(workingDirectory.path)"
    }

    /// The answer to the remote `/changes`.
    func remoteChangesText() -> String {
        guard let summary = controller?.lastFileChangeSummary else {
            return "No tracked file changes."
        }
        let title = summary.fileCount == 1
            ? "1 modified file"
            : "\(summary.fileCount) modified files"
        let entries = summary.entries
            .map(TurnFileChangeSummaryPresentation.entry)
            .joined(separator: "\n")
        return "\(title)  +\(summary.totalAdditions) -\(summary.totalDeletions)\n\(entries)"
    }

    /// The answer to the remote `/help`, naming the primary channel and
    /// listing the remote commands.
    func remoteHelpText() -> String {
        """
        Send a message to prompt the current ZenCODE \(primaryChannelDescription) session.
        Live messages from agents are forwarded here; reply to one with text to answer its sender.
        A voice note cannot be a direct reply: send text, or record without replying to run an ordinary prompt.
        Remote commands: \(Self.remoteCommandList()).
        /diff sends a file only after you confirm it with an explicit button; nothing is uploaded automatically.
        Documents and images you send are received selectively (text, markdown, csv, json, yaml, pdf, rtf, word, odt and images) and kept as private temporaries.
        While /plan is asking questions, ordinary replies continue that same runtime discussion.
        While /goal is waiting for an answer, ordinary replies continue that same workflow task graph.
        Permission replies: /allow ID, /always ID, /deny ID.
        Gated operations (shell commands, deletions, git push/restore) are asked here.
        """
    }

    /// The remote commands, as the remote `/help` lists them: the registry's
    /// commands in registry order, then the coordinator workflow families,
    /// the same sources as the published `setMyCommands` menu, so the list
    /// never drifts from it.
    nonisolated static func remoteCommandList() -> String {
        let remoteCommands = TerminalTelegramCommandRegistry.commands.map { "/\($0.name)" }
        let workflowCommands = CoordinatorCommandFamily.allCases.map { family in
            switch family {
            case .plan: "/plan <goal> (or save|load|list|delete|status|approve|clear)"
            case .goal: "/goal <goal>"
            case .review: "/review [focus]"
            }
        }
        return (remoteCommands + workflowCommands).joined(separator: ", ")
    }
}
