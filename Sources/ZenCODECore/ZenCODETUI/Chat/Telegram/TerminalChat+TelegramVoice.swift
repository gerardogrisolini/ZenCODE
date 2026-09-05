//
//  TerminalChat+TelegramVoice.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension TerminalChat {
    func handleTelegramVoiceMessage(
        _ voice: TerminalTelegramVoiceAttachment,
        origin: TerminalPromptOrigin,
        eventQueue: TerminalChatEventQueue,
        transcriptions: TerminalVoiceTranscriptionRegistry
    ) async {
        if onTelegramWorkEffectForTesting?(.voiceTranscription) == true { return }
        guard let chatID = origin.telegramChatID,
              let fence = telegramWireFence(for: origin) else { return }
        guard isVoiceConfigured() else {
            await sendTelegramSystemMessage(
                "Voice-message transcription is not configured. Run the /setup command in zen and enable voice-message transcription.",
                to: chatID,
                origin: origin
            )
            return
        }

        // Bounded ownership: a burst of voice notes must not start an unbounded
        // number of concurrent downloads and transcriptions, and every started
        // task must be cancellable at teardown.
        guard let slot = transcriptions.reserveSlot() else {
            await sendTelegramSystemMessage(
                "Too many voice messages are being transcribed. Try again shortly.",
                to: chatID,
                origin: origin
            )
            return
        }

        let task = Task(name: "ZenCODE.Telegram.voice-transcription") { [weak self] in
            defer { transcriptions.release(slot) }
            guard let self else { return }
            // Presence for the transcription is scoped to its own lease: the
            // typing indicator covers the download+transcribe wait, and the
            // lease is released on every exit path (success, failure,
            // cancellation) so a dead session never keeps "typing".
            let presenceLease = await self.telegramControlService.acquirePresenceLease(
                scope: .transcription(
                    chatID: chatID,
                    topicID: origin.telegramLease?.effectiveMessageThreadID
                ),
                fence: fence
            )
            defer {
                if let presenceLease {
                    Task(name: "ZenCODE.Telegram.presence-release") { [telegramControlService] in
                        await telegramControlService.releasePresenceLease(presenceLease)
                    }
                }
            }
            do {
                let audio = try await self.telegramControlService.downloadVoiceAudio(
                    voice, chatID: chatID, fence: fence
                )
                // Own cleanup immediately: cancellation can land after download
                // returns but before `transcribe` installs its own defer.
                defer { audio.cleanup() }
                try Task.checkCancellation()
                let transcript = try await AgentVoiceTranscriptionService()
                    .transcribe(audio)
                guard await eventQueue.sendWithBackpressure(
                    .voicePromptCompleted(
                        TerminalVoicePromptResult(
                            origin: origin,
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
                            origin: origin,
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
}
