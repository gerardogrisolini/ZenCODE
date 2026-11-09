//
//  ZenWindowSession+Telegram.swift
//  ZenApp
//
//  `/telegram` in a window: the slot handed to Telegram and taken back,
//  and the turn from Telegram the window adopts.
//

import Foundation
import ToolCore
import ZenCODECore

extension ZenWindowSession {
    // MARK: - Telegram

    /// `/telegram`, `/telegram on`, and `/telegram off`, as the terminal runs
    /// them: the argument, in lowercase, asks for the link's status, hands
    /// the slot to Telegram, or takes it back; any other argument answers the
    /// usage.
    func runTelegramCommand(_ line: String) async {
        let argument = ChatCommandRegistry.arguments(
            from: line.trimmingCharacters(in: .whitespacesAndNewlines),
            commandPrefix: ZenAppCommands.telegram.command
        ).lowercased()
        switch argument {
        case "":
            let status = await sessionHost.telegramStatusText(in: slotID)
            await appendLocal(.local(text: Self.withoutTrailingNewlines(status), isFailure: false))
        case "on":
            await startTelegramControl()
        case "off":
            await stopTelegramControl()
        default:
            await appendLocal(.local(text: Self.telegramUsageText, isFailure: false))
        }
    }

    /// `/telegram on`: hands the slot to Telegram
    /// (``ZenWindowSteps/activateTelegram(in:slotID:notice:)``). The channel
    /// tells the window the link is active through its notice sink, installed
    /// before the first attach so the activation text is not lost; each notice
    /// lands as a row before the activation goes on, so the window's status
    /// line follows it. ``ZenLineRoute`` refuses it while the window runs a
    /// line, and a `/telegram on` while Telegram drives the slot never gets
    /// here: the host refuses it as a line of a dormant channel.
    private func startTelegramControl() async {
        let activation = await ZenWindowSteps.activateTelegram(
            in: sessionHost,
            slotID: slotID,
            notice: { [weak self] text, isFailure in
                await self?.presentTelegramNotice(text, isFailure: isFailure)
            }
        )
        guard !isClosed else { return }
        isDrivenFromTelegram = activation.isDriving
        if let failureText = activation.failureText {
            await appendLocal(.local(text: failureText, isFailure: true))
        }
        if !activation.wasDriving, activation.isDriving {
            await appendLocal(.local(text: Self.telegramDrivingStatusText, isFailure: false))
        }
    }

    /// `/telegram off`: takes the slot back
    /// (``ZenWindowSteps/deactivateTelegram(in:slotID:)``), with no catch-up:
    /// the window showed what the chat did, live. The channel tells the link
    /// stopped through its notice sink; without a Telegram channel (no
    /// `/telegram on` ever ran) the window tells it itself, as the channel
    /// does when it detaches. A turn from Telegram still running is adopted
    /// (``watchAdoptedTelegramTurn(_:)``); otherwise the queue drains once the
    /// line ends.
    private func stopTelegramControl() async {
        let deactivation = await ZenWindowSteps.deactivateTelegram(in: sessionHost, slotID: slotID, presenter: presenter)
        guard !isClosed else { return }
        isDrivenFromTelegram = deactivation.isDriving
        guard deactivation.hadChannel else {
            await appendLocal(.local(
                text: Self.withoutTrailingNewlines(TelegramChannel.stoppedNoticeText),
                isFailure: false
            ))
            return
        }
        if let promptID = deactivation.adoptedPromptID {
            watchAdoptedTelegramTurn(promptID)
        }
    }

    /// A text the slot's Telegram channel has for the window (the activation
    /// text, a poll-health notice, a failure, the stop text), as a row after
    /// what the window shows now: a failure row for the failure channel, a
    /// message row otherwise.
    private func presentTelegramNotice(_ text: String, isFailure: Bool) async {
        await appendLocal(.local(text: Self.withoutTrailingNewlines(text), isFailure: isFailure))
    }

    /// Refuses an action of the operator while Telegram drives the slot, with
    /// the dormant text, as the terminal refuses its input then; `true` when
    /// it refused.
    func refusedWhileDormant() -> Bool {
        guard isDrivenFromTelegram else { return false }
        appendLocalNow(.local(text: Self.dormantRefusalText, isFailure: true))
        return true
    }

    /// Adopts the turn from Telegram that reserved `promptID`, still running
    /// when `/telegram off` took the slot back: until its reservation is
    /// released the window treats it as its line (prompts queue, the commands
    /// that run while a prompt is generating run beside it, the shared chat
    /// sees the window busy), and Stop stops it through the channel. No event
    /// tells the release, and the snapshot may stop generating before the
    /// channel releases the prompt, so a task reads the reservation on the
    /// chat actor every ``adoptedTelegramTurnPollInterval``; once it is gone
    /// (released, cancelled, another session, a closed slot) the turn ends
    /// for the window (``adoptedTelegramTurnDidEnd(_:)``). For voice mode it
    /// is a turn of the window: its comments are read while it runs, and its
    /// final answer, presented to this window once the slot came back, when
    /// it ends.
    func watchAdoptedTelegramTurn(_ promptID: UUID) {
        guard !isClosed else { return }
        adoptedTelegramTurnTask?.cancel()
        adoptedTelegramPromptID = promptID
        sharedChatConsumerStateDidChange()
        let sessionHost = sessionHost
        let slotID = slotID
        let sleep = adoptedTelegramTurnSleep
        let presenter = presenter
        let voiceHost = voiceHost
        voiceHost.post(.turnStarted(host: voiceHost))
        adoptedTelegramTurnTask = Task { [weak self] in
            while await ZenWindowSteps.isReserved(promptID, in: sessionHost, slotID: slotID) {
                do {
                    try await sleep(Self.adoptedTelegramTurnPollInterval)
                } catch {
                    voiceHost.post(.turnEnded(finalAnswer: nil, host: voiceHost))
                    return
                }
            }
            let finalAnswer = await ZenWindowSteps.takeAdoptedFinalAnswer(from: presenter)
            voiceHost.post(.turnEnded(finalAnswer: Task.isCancelled ? nil : finalAnswer, host: voiceHost))
            guard !Task.isCancelled else { return }
            self?.adoptedTelegramTurnDidEnd(promptID)
        }
    }

    /// The adopted turn of `promptID` ended: the window is idle again unless
    /// a line runs, the queue drains, and its busy state is declared.
    private func adoptedTelegramTurnDidEnd(_ promptID: UUID) {
        guard adoptedTelegramPromptID == promptID else { return }
        adoptedTelegramPromptID = nil
        adoptedTelegramTurnTask = nil
        guard !isClosed else { return }
        drainQueueIfIdle()
        sharedChatConsumerStateDidChange()
    }
}
