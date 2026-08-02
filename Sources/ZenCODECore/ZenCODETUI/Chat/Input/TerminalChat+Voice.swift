//
//  TerminalChat+Voice.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation

extension TerminalChat {
    private static let voiceRecordingTailDuration: Duration = .milliseconds(350)

    func handleVoiceCommand(_ command: String) async {
        let argument = Self.slashCommandArguments(
            from: command,
            commandPrefix: "/voice"
        )
        guard argument.isEmpty else {
            await writeSystemMessage("Usage: /voice\n")
            return
        }

        guard stdinIsTerminal else {
            await writeFailureMessage("ZenCODE: /voice requires the interactive TUI.\n")
            return
        }

        guard activeVoiceRecordingSession == nil else {
            await writeSystemMessage("Voice recording is already active. Press Enter to stop.\n")
            return
        }

        do {
            activeVoiceRecordingSession = try await voiceRecordingService.startRecording()
            await interactiveReader.setPanelText("")
            await interactiveReader.setPanelOverlay(
                TerminalPanelModeOverride(
                    modeText: "Recording voice",
                    helpText: "Press Enter to stop · Esc cancel"
                ),
                isProcessing: true
            )
        } catch {
            await clearVoicePanelMode()
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    func stopVoiceRecordingAndTranscribe(
        eventQueue: TerminalChatEventQueue
    ) async -> Task<Void, Never> {
        do {
            await interactiveReader.setPanelText("")
            await interactiveReader.setPanelOverlay(
                TerminalPanelModeOverride(
                    modeText: "Finishing voice",
                    helpText: "Please wait"
                ),
                isProcessing: true
            )
            let audio = try await stopVoiceRecordingAfterTail()
            activeVoiceRecordingSession = nil
            await interactiveReader.setPanelOverlay(
                TerminalPanelModeOverride(
                    modeText: "Transcribing voice",
                    helpText: "Please wait"
                ),
                isProcessing: true
            )
            return transcribeVoiceAudio(audio, origin: .local, eventQueue: eventQueue)
        } catch {
            activeVoiceRecordingSession = nil
            await clearVoicePanelMode()
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            return Task(name: "ZenCODE.TUI.empty-voice-transcription") {}
        }
    }

    func cancelVoiceRecording() async {
        activeVoiceRecordingSession = nil
        voiceRecordingService.cancelRecording()
        await clearVoicePanelMode()
        await writeSystemMessage("Voice recording cancelled.\n")
    }

    func stopVoiceRecordingAndRunPromptBlocking() async {
        do {
            let audio = try await stopVoiceRecordingAfterTail()
            activeVoiceRecordingSession = nil
            await writeSystemMessage("Transcribing voice...\n")
            let transcript = try await AgentVoiceTranscriptionService()
                .transcribe(audio) { message in
                    await self.writeSystemMessage("Voice: \(message)\n")
                }
            let prompt = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                await writeFailureMessage("ZenCODE: Voice transcription returned no text.\n")
                return
            }
            await writeSubmittedPrompt(prompt)
            await runPromptBlocking(promptAttempt(prompt: prompt))
        } catch {
            activeVoiceRecordingSession = nil
            await clearVoicePanelMode()
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    private func stopVoiceRecordingAfterTail() async throws -> AgentVoiceAudioInput {
        // Keep recording briefly after Enter so a key press at the end of speech
        // cannot truncate the final phoneme before AVAudioRecorder is stopped.
        try? await Task.sleep(for: Self.voiceRecordingTailDuration)
        return try voiceRecordingService.stopRecording()
    }

    func clearVoicePanelMode() async {
        await interactiveReader.setPanelOverlay(nil, isProcessing: false)
    }

    func transcribeVoiceAudio(
        _ audio: AgentVoiceAudioInput,
        origin: TerminalPromptOrigin,
        eventQueue: TerminalChatEventQueue
    ) -> Task<Void, Never> {
        Task(name: "ZenCODE.TUI.voice-transcription") {
            do {
                let transcript = try await AgentVoiceTranscriptionService()
                    .transcribe(audio) { message in
                        eventQueue.send(
                            .voicePromptProgress(
                                TerminalVoicePromptProgress(
                                    origin: origin,
                                    message: message
                                )
                            )
                        )
                    }
                eventQueue.send(
                    .voicePromptCompleted(
                        TerminalVoicePromptResult(
                            origin: origin,
                            outcome: .success(transcript)
                        )
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                eventQueue.send(
                    .voicePromptCompleted(
                        TerminalVoicePromptResult(
                            origin: origin,
                            outcome: .failure(error.localizedDescription)
                        )
                    )
                )
            }
        }
    }
}
