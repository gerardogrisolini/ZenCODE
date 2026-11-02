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
    /// the link and writes the activation text again, as before. Only the
    /// interactive input loop hands its slot over (its event queue is
    /// ``loopEventQueue``): the line-by-line fallback, which neither reserves
    /// its prompts in the host nor takes a turn over, refuses it.
    func startTelegramControl() async {
        guard loopEventQueue != nil else {
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

    /// `/telegram off`: takes the slot back and renders the catch-up before
    /// anything more of the turn in progress (see
    /// ``ChatSessionHost/deactivateTelegram(in:presentingCatchUp:)``). A turn
    /// still running from Telegram is adopted: the loop treats it as its own
    /// from now on (``takeAdoptedTurnIfNeeded()``) and its ending reaches
    /// the loop as a generation completion. Without a Telegram channel (no
    /// `/telegram on` ever ran) it tells the link stopped, as the channel
    /// tells it when it detaches.
    func stopTelegramControl() async {
        guard sessionHost.telegramChannel(in: terminalSlotID) != nil else {
            await writeSystemMessage(TelegramChannel.stoppedNoticeText)
            return
        }
        let wasGenerating = sessionHost.incarnation(in: terminalSlotID)?.activePromptID != nil
        let wasDriving = sessionHost.activeChannel(in: terminalSlotID) == .telegram
        if wasDriving, wasGenerating {
            hasAdoptedTelegramTurn = true
        }
        _ = await sessionHost.deactivateTelegram(in: terminalSlotID) { [weak self] catchUp in
            await self?.renderTelegramCatchUp(catchUp)
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

    /// Whether the terminal may act on input that is never a line that takes
    /// the slot back (a dictation, a live mention by voice, a shortcut, a
    /// turn about to start): only while the terminal drives its slot. A
    /// refused input is answered with the dormant text and runs nothing.
    func admitTerminalInput() async -> Bool {
        guard sessionHost.activeChannel(in: terminalSlotID) == .primary else {
            await writeFailureMessage(ChatSlotAdmission.dormantRefusalText)
            return false
        }
        return true
    }

    /// Stops the turn the terminal adopted from Telegram (Esc), which runs
    /// without a task of the loop: the slot's channel cancels it while its
    /// reservation is still the session's
    /// (``ChatSessionHost/stopTelegramTurnIfReserved(_:in:)``), and the
    /// cancelled ending reaches the loop as a generation completion.
    func stopAdoptedTurn() async {
        guard let promptID = sessionHost.activePromptID(in: terminalSlotID) else { return }
        await sessionHost.stopTelegramTurnIfReserved(promptID, in: terminalSlotID)
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
        let live = catchUp.liveAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.savedSessionHistoryHasVisibleContent(messages) {
            await renderSavedSessionHistory(messages, title: title)
        } else if catchUp.incarnationChanged || !live.isEmpty {
            // Nothing to replay, but a new session or a response in progress
            // still goes under the title.
            await writeSystemMessage("\n\(title)\n")
        }
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
    /// generation completion, or, without a loop (the line-by-line fallback,
    /// which refuses `/telegram on` and so never hands its slot over, or a
    /// loop that already ended), presented at once.
    func presentAdoptedTurnEnding(_ ending: ChatTurnEnding) async {
        let result = await generationResult(for: ending)
        if let loopEventQueue {
            // Delivered from a task of its own, as the loop delivers the end
            // of its own turns: the turn's task is cancelled when the turn is
            // stopped (Esc), and a cancelled send would lose the completion
            // and leave the loop generating.
            let delivery = Task.detached(name: "ZenCODE.TUI.adopted-turn-ending-delivery") {
                await loopEventQueue.sendWithBackpressure(.generationCompleted(result))
            }
            _ = await delivery.value
        } else {
            await finishPromptResult(result)
        }
    }

    /// The ending of a turn the terminal ran, which the channel that drives
    /// the slot now presents: the terminal itself through
    /// ``finishPromptResult(_:)``, or Telegram when the slot was handed over
    /// while the turn ran. Returns whether the terminal presented it.
    @discardableResult
    func presentOwnTurnEnding(_ result: TerminalChatGenerationResult) async -> Bool {
        guard sessionHost.activeChannel(in: terminalSlotID) == .telegram else {
            await finishPromptResult(result)
            return true
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
        return false
    }
}
