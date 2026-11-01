//
//  TelegramSessionCompanion+Voice.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Voice notes sent from Telegram: downloaded, transcribed, and run as a
/// prompt of the primary channel.
extension TelegramSessionCompanion {
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
    /// `origin`'s route; the transcript reaches the primary channel through
    /// ``voiceTranscriptionDidFinish(_:lease:)``.
    ///
    /// A ``Policy/mirrorOnly`` companion refuses the note with
    /// ``mirrorOnlyRefusalText`` before anything is downloaded. Otherwise
    /// at most ``TerminalVoiceTranscriptionRegistry/maximumConcurrentTranscriptions``
    /// run at once, owned by ``voiceTranscriptions`` so a detach or
    /// ``cancelVoiceTranscriptions()`` cancels them. Whether the note is a
    /// direct reply to a shared-chat card is the ingress's decision, taken
    /// before it calls this.
    func handleVoiceMessage(
        _ voice: TerminalTelegramVoiceAttachment,
        origin: TelegramTurnOrigin
    ) async {
        // Refused before the test seam and before any download: a mirror-only
        // companion never reads the audio.
        guard configuration.policy == .full else {
            if let chatID = origin.lease?.key.chatID {
                await sendSystemMessage(mirrorOnlyRefusalText, to: chatID, origin: origin)
            }
            return
        }
        if onTelegramWorkEffectForTesting?(.voiceTranscription) == true { return }
        guard let lease = origin.lease,
              let fence = wireFence(for: origin) else { return }
        let chatID = lease.key.chatID
        guard isVoiceConfigured else {
            await sendSystemMessage(
                AgentVoiceTranscriptionError.notEnabledMessage,
                to: chatID,
                origin: origin
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
                origin: origin
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

    /// Hands a finished transcription of a voice note received on `lease` to
    /// the primary channel, as the terminal's panel loop handles a completed
    /// voice prompt.
    ///
    /// A transcript is queued with
    /// ``TelegramCompanionChannel/enqueueTelegramPrompt(_:lease:mode:)`` as a
    /// ``ChatQueuedPromptMode/directPrompt``. A channel whose queue is full
    /// says so with the terminal's text, on the primary channel and in the
    /// chat; a channel that refuses the prompt is answered in the chat with
    /// ``mirrorOnlyRefusalText``. A failure is presented on the primary
    /// channel and told to the chat. Without a channel nothing is reported.
    func voiceTranscriptionDidFinish(
        _ outcome: VoiceTranscriptionOutcome,
        lease: TerminalTelegramRouteLease
    ) async {
        guard let channel else { return }
        let origin = TelegramTurnOrigin.telegram(lease)
        switch outcome {
        case let .success(transcript):
            switch await channel.enqueueTelegramPrompt(
                transcript, lease: lease, mode: .directPrompt
            ) {
            case .queued:
                break
            case .queueFull:
                let message = "ZenCODE: prompt queue is full; voice prompt was not queued."
                await channel.presentCompanionNotice(message + "\n", channel: .failure)
                await sendSystemMessageIfLinked(message, origin: origin)
            case .refused:
                await sendSystemMessageIfLinked(mirrorOnlyRefusalText, origin: origin)
            }
        case let .failure(message):
            await channel.presentCompanionNotice("ZenCODE: \(message)\n", channel: .failure)
            await sendSystemMessageIfLinked(
                "Voice transcription failed: \(message)",
                origin: origin
            )
        }
    }

    /// Cancels every voice transcription in flight, waits until each one has
    /// ended, and refuses new ones for good.
    ///
    /// ``detach()`` cancels the transcriptions too but lets a later
    /// ``attach()`` accept new ones; this is the teardown of the ingress. The
    /// channel that reads the Telegram ingress calls it when it stops
    /// reading, where the terminal's panel loop cancels its transcriptions
    /// today: when the loop ends, and when the panel cannot start.
    func cancelVoiceTranscriptions() async {
        await voiceTranscriptions.cancelAllAndWait(shuttingDown: true)
    }
}
