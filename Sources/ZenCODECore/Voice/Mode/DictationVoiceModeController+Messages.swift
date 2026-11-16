//
//  DictationVoiceModeController+Messages.swift
//  ZenCODE
//
//  Whether dictation voice mode runs on this platform, and the messages it
//  shows while it starts and listens.
//

import Foundation

extension DictationVoiceModeController {
    /// Whether this platform can run dictation at all.
    static var isSupported: Bool {
        VoiceAudioDevice.isSupported && VoiceDictationRecognizer.isSupported
    }

    /// Shown when the voice device runs without echo cancellation because the
    /// current output cannot run voice processing.
    static func echoCancellationUnavailableMessage(outputDeviceName: String?) -> String {
        let output = outputDeviceName.map { "the current audio output (\($0))" }
            ?? "the current audio output"
        return "Voice: echo cancellation is unavailable with \(output); switch to a local output or use headphones so you can talk over the assistant without it hearing itself.\n"
    }

    /// The echo-cancellation notice after the voice device started: shown
    /// only when echo cancellation was active before and is not now. Before
    /// the device first starts it counts as active, so the first start
    /// reports a missing one.
    static func echoCancellationLossNotice(
        wasActive: Bool,
        isActive: Bool,
        outputDeviceName: String?
    ) -> String? {
        guard wasActive, !isActive else {
            return nil
        }
        return echoCancellationUnavailableMessage(outputDeviceName: outputDeviceName)
    }

    static func listeningMessage(localeIdentifier: String) -> String {
        "Voice: listening (dictation, \(localeIdentifier), on-device). Speak or type; answers are read aloud. /voice pauses or resumes, /voice off stops.\n"
    }

    /// Shown before macOS downloads the language's speech model.
    static func downloadingMessage(localeIdentifier: String) -> String {
        "Voice: downloading the speech recognition model for \(localeIdentifier); macOS does this only the first time.\n"
    }
}
