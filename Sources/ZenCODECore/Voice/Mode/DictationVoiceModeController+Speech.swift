//
//  DictationVoiceModeController+Speech.swift
//  ZenCODE
//
//  Reading aloud in dictation voice mode: answers and texts spoken, playback
//  interrupted, the speaking state reported, and the assistant's own voice
//  told apart from the user's.
//

import Foundation

extension DictationVoiceModeController {
    /// Reads an assistant answer or a plain text aloud, replacing anything
    /// still being spoken. Answers completed while paused are never read
    /// later.
    @discardableResult
    func speak(_ text: String, rendering: VoiceModeSpeechRendering) async -> Bool {
        guard phase == .listening, !isPaused, let speaker else {
            return false
        }
        let spoken: String
        switch rendering {
        case .answer:
            spoken = VoiceSpeechText.speakable(
                fromMarkdown: text,
                languageCode: languageCode
            )
        case .plainText:
            spoken = text
        }
        guard !spoken.isEmpty else {
            return false
        }
        if rendering == .answer {
            // Only a completed answer is read while a yes or no is awaited
            // (comments wait for an idle dialogue, and the dialogue's own
            // texts are plain): it takes the place of the question, so the
            // yes or no said to it must not become a prompt.
            strayAnswerGuard.answerReadingStarted(awaitingShortAnswer: isAwaitingShortAnswer, at: .now)
        }
        device.interruptPlayback()
        await speaker.speak(spoken)
        await reportSpeakingState()
        return true
    }

    /// `true` while an answer or a live-chat text is being read aloud.
    var isSpeaking: Bool {
        speaker?.state.isSpeaking() ?? false
    }

    /// Stops the answer being spoken, e.g. after Esc or barge-in.
    func interruptPlayback() async {
        await speaker?.stop()
        device.interruptPlayback()
        await reportSpeakingState()
    }

    /// Whether `text` is the assistant's own voice leaking through the
    /// microphone, during the reading or within its echo tail.
    func isResidualEcho(_ text: String, at now: ContinuousClock.Instant) -> Bool {
        guard let state = speaker?.state, let reference = state.echoReference(at: now) else {
            return false
        }
        return VoiceEchoGuard.shouldDrop(
            text,
            spokenReference: reference,
            isSpeaking: state.isSpeaking(at: now)
        )
    }

    /// Tells the terminal when reading aloud starts or ends, so `Esc` stops
    /// it. Polled by the silence task because the synthesizer reports the end
    /// of speech only through its played buffers.
    func reportSpeakingState() async {
        let isSpeaking = speaker?.state.isSpeaking() ?? false
        guard isSpeaking != reportedSpeaking else {
            return
        }
        reportedSpeaking = isSpeaking
        await callbacks.speakingChanged(isSpeaking)
    }
}
