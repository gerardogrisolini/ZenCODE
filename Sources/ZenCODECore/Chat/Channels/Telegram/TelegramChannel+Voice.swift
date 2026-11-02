//
//  TelegramChannel+Voice.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Voice notes sent from Telegram: downloaded, transcribed, and run as a
/// prompt of the session.
extension TelegramChannel {
    /// How a voice transcription ended, when it was not cancelled.
    enum VoiceTranscriptionOutcome: Sendable, Equatable {
        /// The transcript, which runs as a prompt as it is.
        case success(String)
        /// The failure, as the operator reads it.
        case failure(String)
    }

    /// Whether voice transcription is configured in the settings.
    var isVoiceConfigured: Bool {
        AgentSettingsManifestStore.load()?.voice?.isConfigured == true
    }

    /// Starts downloading and transcribing a voice note received on
    /// `lease`; the transcript runs through
    /// ``voiceTranscriptionDidFinish(_:lease:)``.
    ///
    /// At most ``TerminalVoiceTranscriptionRegistry/maximumConcurrentTranscriptions``
    /// run at once, owned by ``voiceTranscriptions`` so a detach or
    /// ``cancelVoiceTranscriptions()`` cancels them. Whether the note is a
    /// direct reply to a shared-chat card is the ingress's decision, taken
    /// before it calls this.
    func handleVoiceMessage(
        _ voice: TerminalTelegramVoiceAttachment,
        lease: TerminalTelegramRouteLease
    ) async {
        if onTelegramWorkEffectForTesting?(.voiceTranscription) == true { return }
        guard let fence = wireFence(for: lease) else { return }
        let chatID = lease.key.chatID
        guard isVoiceConfigured else {
            await sendSystemMessage(
                AgentVoiceTranscriptionError.notEnabledMessage,
                to: chatID,
                lease: lease
            )
            return
        }

        // Bounded ownership: a burst of voice notes must not start an unbounded
        // number of concurrent downloads and transcriptions, and every started
        // task must be cancellable at teardown.
        let transcriptions = voiceTranscriptions
        guard let slot = transcriptions.reserveSlot() else {
            await sendSystemMessage(
                "Too many voice messages are being transcribed. Try again shortly.",
                to: chatID,
                lease: lease
            )
            return
        }

        let task = Task(name: "ZenCODE.Telegram.voice-transcription") { [weak self] in
            defer { transcriptions.release(slot) }
            guard let self else { return }
            let controlService = self.controlService
            // Presence for the transcription is scoped to its own lease: the
            // typing indicator covers the download+transcribe wait, and the
            // lease is released on every exit path (success, failure,
            // cancellation) so a dead session never keeps "typing".
            let presenceLease = await controlService.acquirePresenceLease(
                scope: .transcription(
                    chatID: chatID,
                    topicID: lease.effectiveMessageThreadID
                ),
                fence: fence
            )
            defer {
                if let presenceLease {
                    Task(name: "ZenCODE.Telegram.presence-release") {
                        await controlService.releasePresenceLease(presenceLease)
                    }
                }
            }
            do {
                let audio = try await controlService.downloadVoiceAudio(
                    voice, chatID: chatID, fence: fence
                )
                // Own cleanup immediately: cancellation can land after download
                // returns but before `transcribe` installs its own defer.
                defer { audio.cleanup() }
                try Task.checkCancellation()
                let transcript = try await AgentVoiceTranscriptionService()
                    .transcribe(audio)
                await self.voiceTranscriptionDidFinish(.success(transcript), lease: lease)
            } catch is CancellationError {
                // Teardown or an explicit cancel: nothing is reported.
                return
            } catch {
                await self.voiceTranscriptionDidFinish(
                    .failure(TerminalTelegramControlError.operatorDescription(error)),
                    lease: lease
                )
            }
        }
        transcriptions.register(task, for: slot)
    }

    /// Runs a finished transcription of a voice note received on `lease` as
    /// a prompt: at once when the session is free, else queued
    /// (``admitPrompt(_:lease:mode:kind:)`` with
    /// ``ChatQueuedPromptMode/directPrompt``); a full queue is told on the
    /// primary channel and in the chat with the terminal's text. A failure
    /// is presented on the primary channel and told to the chat.
    func voiceTranscriptionDidFinish(
        _ outcome: VoiceTranscriptionOutcome,
        lease: TerminalTelegramRouteLease
    ) async {
        switch outcome {
        case let .success(transcript):
            guard drivesSlot else { return }
            let prompt = ChatQueuedPrompt(text: transcript, origin: lease, mode: ChatQueuedPromptMode.directPrompt)
            if isSessionGenerating || activeTurnTask != nil || !promptQueue.isEmpty {
                guard promptQueue.enqueue(prompt) else {
                    let message = "ZenCODE: prompt queue is full; voice prompt was not queued."
                    await presentNotice(message + "\n", channel: .failure)
                    await sendSystemMessageIfLinked(message, lease: lease)
                    return
                }
                startNextQueuedPromptIfNeeded()
                await synchronizeSharedChatConsumerBusyState()
            } else {
                await admitPrompt(transcript, lease: lease, mode: .directPrompt, kind: "voice prompt")
            }
        case let .failure(message):
            await presentNotice("ZenCODE: \(message)\n", channel: .failure)
            await sendSystemMessageIfLinked(
                "Voice transcription failed: \(message)",
                lease: lease
            )
        }
    }

    /// Cancels every voice transcription in flight, waits until each one has
    /// ended, and refuses new ones for good.
    ///
    /// ``detach()`` cancels the transcriptions too but lets a later
    /// ``attach()`` accept new ones; this is the teardown of the ingress,
    /// run when the channel stops reading the chat for good.
    func cancelVoiceTranscriptions() async {
        await voiceTranscriptions.cancelAllAndWait(shuttingDown: true)
    }
}
