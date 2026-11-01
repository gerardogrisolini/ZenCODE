//
//  TerminalChat+Telegram.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// `/telegram` in the terminal: the slot's handover to Telegram and back.
///
/// `/telegram on` hands the terminal's slot to the linked chat
/// (``ChatSessionHost/activateTelegram(in:primaryChannelDescription:)``):
/// from then on the chat drives the session, the terminal shows a status
/// line and accepts only `/telegram`, `/telegram off` and `/exit` (see
/// ``ChatSessionHost/admitLine(_:in:)``), and the texts the channel has for
/// the terminal (the activation text, a poll-health notice, a failure)
/// arrive through ``TelegramChannel/noticeSink``. `/telegram off` takes the
/// slot back: the terminal renders what it did not see, as it renders a
/// restored transcript, and a turn still running from Telegram goes on in
/// the terminal, which adopts it.
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

    /// The status line the terminal shows once Telegram drives its slot.
    static let telegramDrivingStatusText =
        "Session driven from Telegram. Type /telegram off to take it back.\n"

    /// `/telegram on`: hands the slot to Telegram. The channel tells the
    /// terminal the link is active through its notice sink, installed before
    /// the first attach so the activation text is not lost, then the
    /// terminal writes its status line. A repeated `/telegram on` restarts
    /// the link and writes the activation text again, as before.
    func startTelegramControl() async {
        guard stdinIsTerminal else {
            await writeFailureMessage("ZenCODE: /telegram requires the interactive TUI.\n")
            return
        }
        guard isTelegramConfigured() else {
            await writeFailureMessage(Self.unknownCommandMessage(for: "/telegram"))
            return
        }
        let wasDriving = sessionHost.activeChannel(in: terminalSlotID) == .telegram
        installTelegramNoticeSinkIfNeeded()
        do {
            try await sessionHost.activateTelegram(in: terminalSlotID, primaryChannelDescription: "TUI")
        } catch let error as TelegramChannelAttachError {
            await writeFailureMessage(error.failureText)
            return
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            return
        }
        if !wasDriving, sessionHost.activeChannel(in: terminalSlotID) == .telegram {
            await writeSystemMessage(Self.telegramDrivingStatusText)
        }
    }

    /// `/telegram off`: takes the slot back and renders the catch-up. A turn
    /// still running from Telegram is adopted: the loop treats it as its own
    /// from now on (``takeAdoptedTurnIfNeeded()``) and its ending reaches
    /// the loop as a generation completion.
    func stopTelegramControl() async {
        let wasGenerating = sessionHost.incarnation(in: terminalSlotID)?.activePromptID != nil
        let wasDriving = sessionHost.activeChannel(in: terminalSlotID) == .telegram
        if wasDriving, wasGenerating {
            hasAdoptedTelegramTurn = true
        }
        let catchUp = await sessionHost.deactivateTelegram(in: terminalSlotID)
        if let catchUp {
            await renderTelegramCatchUp(catchUp)
        }
    }

    func printTelegramStatus() async {
        await writeSystemMessage(await sessionHost.telegramStatusText(in: terminalSlotID) + "\n")
    }

    /// Connects the channel's notices to the terminal's system and failure
    /// messages, once per channel; the channel is created now when the slot
    /// has none yet, so the first attach presents through it too.
    func installTelegramNoticeSinkIfNeeded() {
        guard let channel = sessionHost.telegramChannelCreatingIfNeeded(
            in: terminalSlotID, primaryChannelDescription: "TUI"
        ), channel.noticeSink == nil else { return }
        channel.noticeSink = { [weak self] text, noticeChannel in
            guard let self else { return }
            switch noticeChannel {
            case .system:
                await writeSystemMessage(text)
            case .failure:
                await writeFailureMessage(text)
            case .markdown:
                await writeMarkdownMessage(text)
            }
        }
    }

    /// Whether the terminal may run `line` now: not while Telegram drives
    /// the slot, except for the lines that take it back. A refused line is
    /// answered with the refusal text and runs nothing.
    func admitTerminalLine(_ line: String) async -> Bool {
        switch sessionHost.admitLine(line, in: terminalSlotID) {
        case .admitted:
            return true
        case let .refused(text):
            await writeFailureMessage(text)
            return false
        }
    }

    /// Whether a turn started from Telegram is running when the terminal
    /// takes the slot back: the loop marks itself generating and the turn's
    /// ending reaches it as a completion (``presentAdoptedTurnEnding(_:)``).
    /// Reading it clears it.
    func takeAdoptedTurnIfNeeded() -> Bool {
        defer { hasAdoptedTelegramTurn = false }
        return hasAdoptedTelegramTurn
    }

    // MARK: - Catch-up

    /// Renders the entries the terminal did not see while Telegram drove the
    /// slot, with the rendering of a restored transcript, under a title that
    /// says whether the session changed meanwhile and whether older entries
    /// were dropped, then the text of the block still streaming, so the
    /// terminal does not miss the beginning of the block it adopts.
    func renderTelegramCatchUp(_ catchUp: ChatTelegramCatchUp) async {
        var title = "Catch-up from Telegram"
        if catchUp.incarnationChanged {
            title += " (new session \(catchUp.sessionID))"
        }
        if catchUp.omittedOlderEntries {
            title += " (older entries omitted)"
        }
        title += ":"
        let messages = ChatTurnEntry.transcriptMessages(from: catchUp.entries)
        if catchUp.incarnationChanged, messages.isEmpty {
            await writeSystemMessage("\n\(title)\n")
        } else {
            await renderSavedSessionHistory(messages, title: title)
        }
        let live = catchUp.liveAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty {
            await writeSystemMessage("Response in progress so far:\n")
            await writeAssistantContent(live)
            await finishStreamingOutput()
        }
    }

    // MARK: - Turns from Telegram

    /// Moves the session's Telegram topic to the session the terminal's slot
    /// switched to (`/sessions new`, `/sessions load`), named after the saved
    /// session or, for a session never saved, as the channel names a new
    /// topic. Nothing happens without a channel or outside topic mode.
    func rebindTelegramTopicToCurrentSession() async {
        guard let channel = sessionHost.telegramChannel(in: terminalSlotID) else { return }
        let displayName = activeSavedSessionName?.nilIfBlank
            ?? TelegramChannel.defaultTopicName(
                workingDirectory: chatSession.workingDirectory,
                sessionID: sessionID
            )
        await channel.rebind(sessionID: sessionID, displayName: displayName)
    }

    /// The ending of a turn the terminal adopted (or of a Telegram turn that
    /// ended while the terminal drives the slot), as the loop's generation
    /// result, so the loop presents it exactly as the end of its own turns.
    func generationResult(for ending: ChatTurnEnding) async -> TerminalChatGenerationResult {
        switch ending.outcome {
        case let .completed(response):
            let finalAssistantContent = await activeAssistantOutput?.finalContent(
                fallback: response.text
            ) ?? response.text
            return .success(TerminalChatGenerationSuccess(
                response: response,
                origin: .local,
                fileChangeSummary: ending.fileChangeSummary,
                automaticallyCompletedPlan: ending.automaticallyCompletedPlan,
                finalAssistantContent: finalAssistantContent
            ))
        case let .failed(message):
            return .failure(TerminalChatGenerationFailure(
                message: message,
                isCancellation: false,
                origin: .local,
                fileChangeSummary: ending.fileChangeSummary
            ))
        case .cancelled:
            return .failure(TerminalChatGenerationFailure(
                message: "",
                isCancellation: true,
                origin: .local,
                fileChangeSummary: ending.fileChangeSummary
            ))
        }
    }

    /// The ending of a turn another channel ran, presented by the terminal
    /// because it drives the slot now: handed to the running loop as a
    /// generation completion, or, without a loop (the blocking fallback,
    /// which never hands its slot over), presented at once.
    func presentAdoptedTurnEnding(_ ending: ChatTurnEnding) async {
        let result = await generationResult(for: ending)
        if let loopEventQueue {
            _ = await loopEventQueue.sendWithBackpressure(.generationCompleted(result))
        } else {
            await finishPromptResult(result)
        }
    }

    /// The ending of a turn the terminal ran, which the channel that drives
    /// the slot now presents: the terminal itself through
    /// ``finishPromptResult(_:)``, or Telegram when the slot was handed over
    /// while the turn ran.
    func presentOwnTurnEnding(_ result: TerminalChatGenerationResult) async {
        guard sessionHost.activeChannel(in: terminalSlotID) == .telegram else {
            await finishPromptResult(result)
            return
        }
        let ending: ChatTurnEnding
        switch result {
        case let .success(success):
            ending = ChatTurnEnding(
                outcome: .completed(success.response),
                fileChangeSummary: success.fileChangeSummary,
                automaticallyCompletedPlan: success.automaticallyCompletedPlan
            )
        case let .failure(failure):
            ending = ChatTurnEnding(
                outcome: failure.isCancellation ? .cancelled : .failed(failure.message),
                fileChangeSummary: failure.fileChangeSummary
            )
        }
        await finishStreamingOutput()
        await quiesceTaskGraphObserverForTurnBoundary()
        await sessionHost.presentTurnEnding(ending, in: terminalSlotID)
        await startTaskGraphObserver()
    }
}
