//
//  TelegramSessionCompanion+Egress.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

extension TelegramSessionCompanion {
    // MARK: - Route checks

    /// The linked chat outgoing messages for `origin` go to, while the link
    /// is active. Only a Telegram origin has one: a turn of the primary
    /// channel reaches the chat once ``attach()`` moved it onto the route.
    func outgoingChatID(for origin: TelegramTurnOrigin) -> Int64? {
        guard controlState.isActive, let lease = origin.lease else { return nil }
        return lease.key.chatID
    }

    /// Queue, start, and egress fence for a route-scoped turn: the link is
    /// active and the router still validates the origin's lease.
    func validateOrigin(_ origin: TelegramTurnOrigin) async -> Bool {
        guard let lease = origin.lease else { return false }
        guard controlState.isActive else { return false }
        return (try? await router.validate(lease)) != nil
    }

    /// The wire fence of `origin` for the control service's current
    /// lifecycle, or `nil` without a lease or a started lifecycle.
    func wireFence(for origin: TelegramTurnOrigin) -> TerminalTelegramWireFence? {
        guard let lease = origin.lease,
              let lifecycleEpoch = controlState.wireLifecycleEpoch else { return nil }
        return TerminalTelegramWireFence(
            lease: lease,
            lifecycleEpoch: lifecycleEpoch,
            validateLease: { [router] lease in
                try await router.validate(lease)
            }
        )
    }

    // MARK: - System messages

    /// Sends a bot-control message to the linked chat of `origin`, when its
    /// route is still valid.
    func sendSystemMessageIfLinked(
        _ message: String,
        origin: TelegramTurnOrigin
    ) async {
        guard await validateOrigin(origin),
              let chatID = outgoingChatID(for: origin) else {
            return
        }
        await sendSystemMessage(message, to: chatID, origin: origin)
    }

    /// Sends a message to a Telegram chat, reporting whether it was
    /// delivered.
    ///
    /// Delivery status is part of the contract: a permission request that
    /// never reached the chat must fail closed instead of holding the turn.
    @discardableResult
    func sendSystemMessage(
        _ message: String, to chatID: Int64, origin: TelegramTurnOrigin
    ) async -> Bool {
        guard let lease = origin.lease,
              lease.key.chatID == chatID,
              let fence = wireFence(for: origin),
              await validateOrigin(origin) else { return false }
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
            await channel?.presentCompanionNotice("ZenCODE: \(description)\n", channel: .failure)
            return false
        }
    }

    // MARK: - Turn messages

    /// Publishes a turn message on the ordered Telegram channel.
    ///
    /// While a mirrored turn is generating, its reporter owns the outgoing
    /// order. Bot-control messages deliberately use ``sendSystemMessage(_:to:origin:)``
    /// instead.
    @discardableResult
    func sendTurnMessage(
        _ payload: TerminalTelegramTurnPayload,
        to chatID: Int64,
        origin: TelegramTurnOrigin
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
        return await sendSystemMessage(payload.text, to: chatID, origin: origin)
    }

    /// Publishes a turn message to the linked chat of `origin`, when its
    /// route is still valid.
    func sendTurnMessageIfLinked(
        _ payload: TerminalTelegramTurnPayload,
        origin: TelegramTurnOrigin
    ) async {
        guard await validateOrigin(origin),
              let chatID = outgoingChatID(for: origin) else {
            return
        }
        await sendTurnMessage(payload, to: chatID, origin: origin)
    }

    // MARK: - Texts

    /// The `/telegram` status of the link, after reading the control
    /// service's current state. The primary channel writes it followed by a
    /// newline. In topic mode it names the session's topic.
    func statusText() async -> String {
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
        let agent = controller.selection.agent?.displayName ?? AgentProfileStore.developerAgentName
        let model = controller.currentEffectiveModelID() ?? "default model"
        return "Session active.\nAgent: \(agent)\nModel: \(model)\nWorking directory: \(controller.workingDirectory.path)"
    }

    /// The answer to the remote `/changes`.
    func remoteChangesText() -> String {
        guard let summary = controller.lastFileChangeSummary else {
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
    /// listing the commands of the companion's policy. A
    /// ``Policy/mirrorOnly`` companion says what it mirrors, what it
    /// accepts, and what is not available, in the words of
    /// ``mirrorOnlyRefusalText``.
    func remoteHelpText() -> String {
        switch configuration.policy {
        case .full:
            """
            Send a message to prompt the current ZenCODE \(configuration.primaryChannelDescription) session.
            Live messages from agents are forwarded here; reply to one with text to answer its sender.
            A voice note cannot be a direct reply: send text, or record without replying to run an ordinary prompt.
            Remote commands: \(Self.remoteCommandList(policy: configuration.policy)).
            /diff sends a file only after you confirm it with an explicit button; nothing is uploaded automatically.
            Documents and images you send are received selectively (text, markdown, csv, json, yaml, pdf, rtf, word, odt and images) and kept as private temporaries.
            While /plan is asking questions, ordinary replies continue that same runtime discussion.
            While /goal is waiting for an answer, ordinary replies continue that same workflow task graph.
            Permission replies: /allow ID, /always ID, /deny ID.
            Gated operations (shell commands, deletions, git push/restore) are asked here.
            """
        case .mirrorOnly:
            """
            Telegram mirrors the ZenCODE session driven by the \(configuration.primaryChannelDescription); send prompts there.
            Remote commands: \(Self.remoteCommandList(policy: configuration.policy)).
            /diff sends a file only after you confirm it with an explicit button; nothing is uploaded automatically.
            Permission replies: /allow ID, /always ID, /deny ID. Gated operations (shell commands, deletions, git push/restore) are asked here too.
            Prompts, voice notes, /plan, /goal, /review and /undo are not available from Telegram in this session.
            """
        }
    }

    /// The answer to everything a ``Policy/mirrorOnly`` companion refuses
    /// (prompts, voice notes, `/plan` `/goal` `/review`, replies to pending
    /// questions, `/undo`), and to a prompt the primary channel refuses. The
    /// one text for every refusal: the voice note handler and the remote
    /// commands use it.
    var mirrorOnlyRefusalText: String {
        "ZenCODE: this session is driven by the \(configuration.primaryChannelDescription); send prompts there. From Telegram you can use /help, /status, /changes, /diff and /chat, and answer permission requests with /allow, /always or /deny."
    }

    /// The remote commands `policy` accepts, as the remote `/help` lists
    /// them. ``Policy/full`` lists the registry's commands in registry
    /// order, then the coordinator workflow families, the same sources as
    /// the published `setMyCommands` menu, so the list never drifts from it.
    /// ``Policy/mirrorOnly`` lists only the registry commands it accepts
    /// (no `/undo`, no workflow families), in the order of
    /// ``mirrorOnlyRefusalText``, so its help, its refusal and this list
    /// name them alike.
    nonisolated static func remoteCommandList(policy: Policy) -> String {
        switch policy {
        case .full:
            let remoteCommands = TerminalTelegramCommandRegistry.commands.map { "/\($0.name)" }
            let workflowCommands = CoordinatorCommandFamily.allCases.map { family in
                switch family {
                case .plan: "/plan <goal> (or save|load|list|delete|status|approve|clear)"
                case .goal: "/goal <goal>"
                case .review: "/review [focus]"
                }
            }
            return (remoteCommands + workflowCommands).joined(separator: ", ")
        case .mirrorOnly:
            let accepted: [TerminalTelegramRemoteCommand] = [.help, .status, .changes, .diff, .chat]
            return accepted
                .compactMap { command in
                    TerminalTelegramCommandRegistry.commands
                        .first { $0.command == command }
                        .map { "/\($0.name)" }
                }
                .joined(separator: ", ")
        }
    }
}
