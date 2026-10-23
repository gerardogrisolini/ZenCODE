//
//  TerminalChat+Voice.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/09/26.
//

import Foundation

extension TerminalChat {
    static let voiceOffMessage = "ZenCODE: voice mode is off. Run /voice on to start it.\n"
    static let voiceRequiresInteractiveTerminalMessage = "ZenCODE: /voice is available only in the interactive terminal.\n"

    /// `/voice [on|off|pause|resume]`. Voice mode is independent of the active
    /// agent, survives agent and session switches, and lasts only for this TUI
    /// session.
    func handleVoiceCommand(_ command: String) async {
        let argument = Self.slashCommandArguments(from: command, commandPrefix: "/voice")
        switch TerminalVoiceCommandAction(argument: argument) {
        case .turnOn:
            await startVoiceMode()
        case .turnOff:
            await turnVoiceModeOff()
        case .pause:
            await setVoicePaused(true)
        case .resume:
            await setVoicePaused(false)
        case .togglePause:
            guard let controller = await activeVoiceController() else {
                await writeFailureMessage(Self.voiceOffMessage)
                return
            }
            await setVoicePaused(!(await controller.isPaused))
        case .usage:
            await writeSystemMessage(TerminalVoiceCommandAction.usageMessage)
        }
    }

    /// The running voice controller, or `nil` when voice mode is off or its
    /// controller failed.
    private func activeVoiceController() async -> TerminalDictationVoiceController? {
        guard let controller = dictationVoiceController, await controller.isActive else {
            return nil
        }
        return controller
    }

    private func startVoiceMode() async {
        if let controller = await activeVoiceController() {
            let state = await controller.isPaused ? " (paused). /voice resume resumes it" : ""
            await writeSystemMessage("Voice: already on\(state).\n")
            return
        }
        guard let eventQueue = voiceEventQueue else {
            await writeFailureMessage(Self.voiceRequiresInteractiveTerminalMessage)
            return
        }
        guard TerminalDictationVoiceController.isSupported else {
            await writeFailureMessage(
                "ZenCODE: \(TerminalDictationError.unsupportedPlatform.localizedDescription)\n"
            )
            return
        }
        // A failed controller is replaced, so the language is read again.
        await stopVoiceMode()
        let manifest = AgentSettingsManifestStore.load()
        let languageCode = TerminalVoiceLanguage.resolvedCode(
            voiceLanguage: manifest?.voice?.language,
            responseLanguage: manifest?.responseLanguage,
            systemLanguage: ResponseLanguageResolver.systemLanguageCode()
        )
        let controller = TerminalDictationVoiceController(
            languageCode: languageCode,
            locale: AgentVoiceTranscriptionService.locale(for: languageCode),
            callbacks: dictationVoiceCallbacks(eventQueue: eventQueue)
        )
        dictationVoiceController = controller
        // Starting may wait on the system permission prompts; never hold the
        // terminal event loop on them. The controller reports when it listens.
        Task(name: "ZenCODE.TUI.dictation-start") {
            await controller.start()
        }
    }

    private func turnVoiceModeOff() async {
        guard await activeVoiceController() != nil else {
            await stopVoiceMode()
            await writeSystemMessage("Voice: already off.\n")
            return
        }
        await stopVoiceMode()
        await writeSystemMessage("Voice: off.\n")
    }

    private func setVoicePaused(_ paused: Bool) async {
        guard let controller = await activeVoiceController() else {
            await writeFailureMessage(Self.voiceOffMessage)
            return
        }
        let changed = await controller.setPaused(paused)
        switch (paused, changed) {
        case (true, true):
            await writeSystemMessage("Voice: paused; not listening or reading answers aloud. /voice resumes it.\n")
        case (true, false):
            await writeSystemMessage("Voice: already paused.\n")
        case (false, true):
            await writeSystemMessage("Voice: resumed.\n")
        case (false, false):
            await writeSystemMessage("Voice: already listening.\n")
        }
    }

    func stopVoiceMode() async {
        guard let controller = dictationVoiceController else {
            return
        }
        dictationVoiceController = nil
        await controller.stop()
    }

    /// Reads a completed answer aloud while voice mode runs and is not paused.
    func speakVoiceResponse(_ response: String) async {
        await dictationVoiceController?.speak(response)
    }

    /// Stops assistant speech that is still playing, e.g. after Esc.
    func interruptVoicePlayback() async {
        await dictationVoiceController?.interruptPlayback()
    }

    private func dictationVoiceCallbacks(
        eventQueue: TerminalChatEventQueue
    ) -> TerminalDictationVoiceController.Callbacks {
        TerminalDictationVoiceController.Callbacks(
            systemMessage: { [weak self] text in
                await self?.writeSystemMessage(text)
            },
            failureMessage: { [weak self] text in
                await self?.writeFailureMessage(text)
            },
            utteranceRecognized: { utterance in
                _ = await eventQueue.sendWithBackpressure(
                    Self.dictatedPromptEvent(for: utterance)
                )
            }
        )
    }

    /// A dictated utterance is handled like a typed line, so it also answers
    /// a pending plan or workflow question and queues while a turn runs. Text
    /// that would read as a slash command is always sent as a plain prompt.
    nonisolated static func dictatedPromptEvent(for utterance: String) -> TerminalChatRuntimeEvent {
        if utterance.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            return .voicePromptCompleted(
                TerminalVoicePromptResult(origin: .local, outcome: .success(utterance))
            )
        }
        return .input(.submitted(utterance))
    }
}
