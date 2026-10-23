//
//  SystemSpeechVoicePreview.swift
//  ZenCODE
//
//  The sample `/setup` > Voice mode plays on macOS so the operator can hear a
//  system voice before choosing it. The sample goes straight to the system
//  output with `AVSpeechSynthesizer.speak(_:)`: it never opens the
//  microphone, keeps no audio and returns at once, so the setup menu stays
//  usable while the voice reads. The setup stops the sample before playing
//  another one and when the operator leaves the preview.
//

#if os(macOS)
import AVFoundation
import Foundation

/// Plays voice samples; tests inject a recorder so they produce no audio.
protocol SpeechVoicePreviewPlaying: AnyObject {
    /// Starts reading `text` with the installed voice `voiceIdentifier`
    /// without waiting for the end. Returns `false` when the voice is no
    /// longer installed.
    func play(_ text: String, voiceIdentifier: String) -> Bool
    /// Stops the sample being read, if any.
    func stop()
}

enum SystemSpeechVoicePreview {
    /// A short sentence in the language of `voice` that says its name;
    /// English for the languages without a translation.
    static func sampleText(for voice: SystemSpeechVoice) -> String {
        switch SystemSpeechVoiceCatalog.languageCode(of: voice.language) {
        case "it":
            return "Ciao, sono \(voice.name). Questa è la mia voce."
        default:
            return "Hello, I'm \(voice.name). This is my voice."
        }
    }
}

/// Reads samples aloud with the system speech synthesizer.
final class SystemSpeechVoicePreviewPlayer: SpeechVoicePreviewPlaying {
    private let synthesizer = AVSpeechSynthesizer()

    func play(_ text: String, voiceIdentifier: String) -> Bool {
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) else {
            return false
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.speak(utterance)
        return true
    }

    /// Unconditional: right after `speak(_:)` the synthesizer may not report
    /// `isSpeaking` yet, and stopping also clears a queued sample.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
#endif
