//
//  ZenCODEACPBridge+TelegramCommand.swift
//  ZenCODE
//
//  ACP answer to the /telegram command: status, on, and off for an ACP
//  session, with the texts of the activation and of the catch-up.
//

import Foundation
import ToolCore

// MARK: - /telegram

/// `/telegram`, `/telegram on`, and `/telegram off`: the terminal's command,
/// per ACP session, answered at once with the terminal's texts (without
/// their trailing newline, like every immediate ACP reply).
///
/// The command is visible while the settings enable Telegram, read again at
/// every use; otherwise every `/telegram` line is answered as an unknown
/// command, as the terminal does, instead of reaching the model. `on` hands
/// the session's slot to the linked chat, which drives it from then on
/// (``ChatSessionHost/activateTelegram(in:primaryChannelDescription:)``):
/// the editor's prompts are refused until `off` takes the slot back, whose
/// reply carries what the editor did not see. The notices the channel
/// presents while it attaches (a topic that could not be created, for one)
/// follow the activation text in the reply of `on`; ACP has no place for a
/// text outside a prompt's reply, so every other notice is dropped. The
/// link belongs to the session's slot and is never persisted: a session
/// loaded again needs `/telegram on` again.
///
/// The editor cannot take the slot back in the middle of a turn from
/// Telegram: that turn holds the slot's prompt reservation, so `/telegram
/// off`, like every `session/prompt`, is refused while it runs, with a text
/// that says so (``ZenCODEACPBridge/telegramTurnBusyMessage``); the editor
/// stops it with `session/cancel`, or waits for it to end, and the next
/// `/telegram off` catches up with it, the response in progress included.
/// The terminal, which runs its commands outside the reservation, adopts
/// such a turn instead.
extension ZenCODEACPBridge {
    static let telegramCommandToken = "/telegram"

    /// Whether the settings enable Telegram, so `/telegram` is announced and
    /// answered.
    static func isTelegramCommandVisible() -> Bool {
        AgentSettingsManifestStore.load()?.telegram?.isEnabled == true
    }

    /// The answer to the `/telegram` line `line` of the prompt that holds the
    /// reservation `promptID`.
    ///
    /// `on` hands the slot to Telegram and answers the activation text, with
    /// the notices of the attach after it; `off` takes it back and answers
    /// the stop text with the catch-up; without an argument the link's
    /// status is answered. Ends `cancelled` when the reservation is gone
    /// before the answer.
    func routeACPTelegramCommand(
        _ line: String,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async throws -> ACPCommandTurnRoute {
        guard Self.isTelegramCommandVisible() else {
            return .immediate(Self.acpImmediateText(ChatCommandRegistry.unknownCommandMessage(for: line)))
        }
        guard let session = await reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            throw CancellationError()
        }
        let argument = ChatCommandRegistry.arguments(
            from: line.trimmingCharacters(in: .whitespacesAndNewlines),
            commandPrefix: Self.telegramCommandToken
        )
        switch TerminalTelegramCommandAction(argument: argument) {
        case .status:
            return .immediate(await host.telegramStatusText(in: session.slotID))
        case .turnOn:
            // What the channel presents while it attaches (a topic it could
            // not create, for one) follows the activation text in the reply.
            let attachNotices: [String]
            do {
                attachNotices = try await host.activateTelegramCollectingNotices(
                    in: session.slotID, primaryChannelDescription: "editor"
                )
            } catch let error as TelegramChannelAttachError {
                return .immediate(Self.acpImmediateText(error.failureText))
            } catch ChatSessionHostError.shutDown, ChatSessionHostError.unknownSlot {
                throw CancellationError()
            }
            // A close or a shutdown that landed meanwhile ends the slot and
            // its channel, and the prompt ends `cancelled`.
            guard liveSession(id: sessionID, epoch: epoch) != nil else {
                throw CancellationError()
            }
            guard await reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil else {
                throw CancellationError()
            }
            // The activation notice itself is among them: the reply starts
            // with it once.
            let channel = await host.telegramChannel(in: session.slotID)
            let activationText = await Self.activationText(of: channel)
            let notices = attachNotices.filter { $0 != activationText }
            return .immediate(([activationText] + notices).joined(separator: "\n"))
        case .turnOff:
            let catchUp = await host.deactivateTelegram(in: session.slotID)
            var lines = ["Telegram remote control stopped."]
            if let catchUp {
                lines.append(contentsOf: Self.catchUpLines(catchUp))
            }
            return .immediate(lines.joined(separator: "\n"))
        case .usage:
            return .immediate("Usage: /telegram [on|off]")
        }
    }

    /// The reply to a `/telegram on` that handed the slot to `channel`: the
    /// text the channel presents on attaching, without its trailing newline.
    static func activationText(of channel: TelegramChannel?) async -> String {
        let title = await channel?.linkedChatTitle?.nilIfBlank
        let chatID = await channel?.linkedChatID
        let chatTitle = title ?? chatID.map { "chat \($0)" } ?? "chat"
        return "Telegram remote control is active.\nLinked chat: \(chatTitle)"
    }

    /// The catch-up of a `/telegram off` as reply lines: a heading that says
    /// whether the session changed or older entries were dropped, then the
    /// prompts and responses the editor did not see, and the response still
    /// in progress.
    static func catchUpLines(_ catchUp: ChatTelegramCatchUp) -> [String] {
        guard !catchUp.isEmpty else { return [] }
        var heading = "Catch-up from Telegram"
        if catchUp.incarnationChanged {
            heading += " (new session \(catchUp.sessionID))"
        }
        if catchUp.omittedOlderEntries {
            heading += " (older entries omitted)"
        }
        var lines = [heading + ":"]
        for entry in catchUp.entries {
            switch entry.kind {
            case let .userPrompt(text, _, _):
                lines.append("You: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            case let .assistantText(text):
                lines.append("ZenCODE: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            default:
                continue
            }
        }
        let live = catchUp.liveAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty {
            lines.append("ZenCODE (in progress): \(live)")
        }
        return lines
    }
}
