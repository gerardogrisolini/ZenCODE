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
    /// Sent to the model with every prompt while voice mode listens (see
    /// ``voiceTurnInstruction()``). English on purpose: the language of the
    /// answer is already handled by the system prompt.
    static let voiceTurnInstruction = "Voice mode is on: the user is listening and your final answer is read aloud. Answer in short sentences. While you work, briefly comment on what you are doing as you do it. Keep any format the request requires."

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
    private func activeVoiceController() async -> (any TerminalVoiceController)? {
        guard let controller = voiceController, await controller.isActive else {
            return nil
        }
        return controller
    }

    /// The instruction that goes out with a prompt: ``voiceTurnInstruction``
    /// while voice mode listens (running and not paused), otherwise `nil`. It
    /// is evaluated for every prompt, so `/voice pause`, `/voice resume` and
    /// `/voice off` take effect from the next one. The runtime merges it into
    /// the outgoing copy of the user message only (see
    /// ``AgentTurnInstructionContext``): it never enters history or snapshots.
    func voiceTurnInstruction() async -> String? {
        guard let controller = await activeVoiceController(),
              await !controller.isPaused else {
            return nil
        }
        return Self.voiceTurnInstruction
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
        // A failed controller is replaced, so the language, the reading
        // voice and the options are read again.
        await stopVoiceMode()
        let manifest = AgentSettingsManifestStore.load()
        let languageCode = VoiceLanguage.resolvedCode(manifest: manifest)
        let controller: any TerminalVoiceController
        switch TerminalVoicePlatform.makeController(
            languageCode: languageCode,
            readingVoiceIdentifier: manifest?.voice?.macOSVoiceIdentifier,
            options: TerminalVoiceOptions(voice: manifest?.voice),
            callbacks: voiceCallbacks(eventQueue: eventQueue)
        ) {
        case let .ready(ready):
            controller = ready
        case let .unavailable(message):
            await writeFailureMessage(message)
            return
        }
        voiceController = controller
        // An edit that turns the dictation shown in the draft into ordinary
        // text makes voice forget what it accumulated for it.
        interactiveReader.setVoiceDictationEndedHandler { id in
            Task(name: "ZenCODE.TUI.voice-discard-dictation") {
                await controller.discardDictation(through: id)
            }
        }
        // Starting may wait on the system permission prompts or on loading
        // the speech models; never hold the terminal event loop on it. The
        // controller reports when it listens.
        Task(name: "ZenCODE.TUI.voice-start") {
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
        if paused {
            await cancelVoiceChatDialogue()
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
        await cancelVoiceChatDialogue()
        guard let controller = voiceController else {
            return
        }
        voiceController = nil
        await controller.stop()
        interactiveReader.setVoiceDictationEndedHandler(nil)
        await interactiveReader.setPanelSpeaking(false)
    }

    /// Reads a completed answer aloud while voice mode runs and is not paused.
    /// An answer that starts takes precedence over the live-chat dialogue (see
    /// `TerminalVoiceChatDialogue.answerReadingStarted`); one that does not
    /// start, because voice mode is paused or the answer has nothing to say,
    /// leaves the dialogue as it is. Returns whether the reading started.
    func speakVoiceResponse(_ response: String) async -> Bool {
        guard let voiceController else {
            return false
        }
        let started = await voiceController.speak(response, rendering: .answer)
        if started {
            cancelVoiceDialogueDeadline()
            voiceChatDialogue.answerReadingStarted()
            await syncVoiceDialogueAnswerState()
        }
        return started
    }

    /// Stops the answer being read aloud, e.g. after Esc. On Linux this also
    /// turns the microphone back on. The live-chat dialogue and its queue are
    /// dropped: nothing is announced retroactively.
    func interruptVoicePlayback() async {
        await cancelVoiceChatDialogue()
        await voiceController?.interruptPlayback()
    }

    /// Forgets the spoken live-chat question and every queued announcement.
    func cancelVoiceChatDialogue() async {
        cancelVoiceDialogueDeadline()
        voiceChatDialogue.cancelAll()
        await syncVoiceDialogueAnswerState()
    }

    /// Tells the controller whether the dialogue awaits a yes or no, so
    /// keyword send mode lets a bare answer through. Called after every
    /// dialogue transition.
    func syncVoiceDialogueAnswerState() async {
        await voiceController?.setAwaitingShortAnswer(voiceChatDialogue.isAwaitingAffirmation)
    }

    /// Stops waiting for the answer to a spoken question.
    func cancelVoiceDialogueDeadline() {
        voiceDialogueDeadlineTask?.cancel()
        voiceDialogueDeadlineTask = nil
    }

    private func voiceCallbacks(
        eventQueue: TerminalChatEventQueue
    ) -> TerminalVoiceCallbacks {
        let reader = interactiveReader
        return TerminalVoiceCallbacks(
            systemMessage: { [weak self] text in
                await self?.writeSystemMessage(text)
            },
            failureMessage: { [weak self] text in
                await self?.writeFailureMessage(text)
            },
            utteranceRecognized: { utterance in
                let text: String?
                switch utterance {
                case let .dictation(id, dictated):
                    // The whole visible draft: typed text, then the dictation.
                    text = reader.takeVoiceDictation(id: id, text: dictated)
                case let .answer(answer):
                    text = answer
                }
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                _ = await eventQueue.sendWithBackpressure(.voiceUtterance(text))
            },
            dictationChanged: { id, text in
                // Straight to the reader, not through the event queue: a
                // preview must reach the draft before the send that takes it,
                // and it is reported from inside `setPaused` and `stop`, which
                // the runtime loop itself awaits, so waiting for a full queue
                // could block its only consumer.
                reader.setVoiceDictation(id: id, text: text)
            },
            speakingChanged: { isSpeaking in
                await reader.setPanelSpeaking(isSpeaking)
                // Reported from inside `speak`, `interruptPlayback`, `setPaused`
                // and `stop`, which the runtime loop itself awaits: waiting here
                // for a full queue would block its only consumer. Only a full
                // queue is retried, from a task of its own.
                if eventQueue.offer(.voiceSpeakingChanged(isSpeaking)) == .rejectedFull {
                    Task(name: "ZenCODE.TUI.voice-speaking-changed") {
                        _ = await eventQueue.sendWithBackpressure(.voiceSpeakingChanged(isSpeaking))
                    }
                }
            }
        )
    }

    /// A dictated utterance that is not part of the live-chat dialogue is
    /// handled like a typed line, so it also answers a pending plan or
    /// workflow question and queues while a turn runs. Text that would read
    /// as a slash command is always sent as a plain prompt.
    nonisolated static func dictatedPromptEvent(for utterance: String) -> TerminalChatRuntimeEvent {
        if utterance.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            return .voicePromptCompleted(
                TerminalVoicePromptResult(origin: .local, outcome: .success(utterance))
            )
        }
        return .input(.submitted(utterance))
    }
}
