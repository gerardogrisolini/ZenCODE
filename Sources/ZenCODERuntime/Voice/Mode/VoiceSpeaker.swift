//
//  VoiceSpeaker.swift
//  ZenCODE
//
//  Speaks assistant answers with the system synthesizer through the voice
//  device, converting its buffers to the device samples, with the stub that
//  stays silent on platforms without Speech.
//

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(Speech) && canImport(AVFoundation)
/// Speaks assistant answers with the system synthesizer. Speech is rendered to
/// buffers and played through the voice device, so the engine's echo
/// cancellation hears it as its own output and the user can talk over it.
@MainActor
final class VoiceSpeaker {
    nonisolated let state = VoiceSpeechState()
    private let device: VoiceAudioDevice
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    init(localeIdentifier: String, readingVoiceIdentifier: String?, device: VoiceAudioDevice) {
        self.device = device
        voice = Self.preferredVoice(
            localeIdentifier: localeIdentifier,
            readingVoiceIdentifier: readingVoiceIdentifier
        )
    }

    func speak(_ text: String) {
        stop()
        let generation = state.begin(text: text)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.write(
            utterance,
            toBufferCallback: Self.bufferCallback(generation: generation, state: state, device: device)
        )
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        state.cancel()
    }

    /// Built outside the main actor: the synthesizer calls it on its own queue.
    private nonisolated static func bufferCallback(
        generation: UInt64,
        state: VoiceSpeechState,
        device: VoiceAudioDevice
    ) -> @Sendable (AVAudioBuffer) -> Void {
        let converter = VoiceSampleConverter()
        return { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                state.synthesisFinished(generation: generation)
                return
            }
            let samples = converter.convert(pcm)
            guard !samples.isEmpty, state.bufferScheduled(generation: generation) else {
                return
            }
            let scheduled = device.enqueuePlayback(samples) {
                state.bufferPlayed(generation: generation)
            }
            if !scheduled {
                state.bufferPlayed(generation: generation)
            }
        }
    }

    /// The voice saved in `zen --setup` > Voice mode when it is installed and reads
    /// the locale's language; otherwise the best installed non-novelty voice
    /// for the locale, preferring premium and enhanced voices.
    static func preferredVoice(
        localeIdentifier: String,
        readingVoiceIdentifier: String?
    ) -> AVSpeechSynthesisVoice? {
        let identifier = SystemSpeechVoiceCatalog.normalizedLocaleIdentifier(localeIdentifier)
        let choice = SystemSpeechVoiceCatalog.preferredVoice(
            savedIdentifier: readingVoiceIdentifier,
            localeIdentifier: identifier,
            installedVoices: SystemSpeechVoiceCatalog.installedVoices(),
            lookup: SystemSpeechVoiceCatalog.installedVoice(identifier:)
        )
        return choice.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
            ?? AVSpeechSynthesisVoice(language: identifier)
    }
}

/// Reuses one converter while consecutive buffers share a format.
private final class VoiceSampleConverter: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = VoiceAudioDevice.makeConverter(from: buffer.format)
        }
        guard let converter else {
            return []
        }
        return VoiceAudioDevice.monoSamples(from: buffer, converter: converter)
    }
}
#else
@MainActor
final class VoiceSpeaker {
    nonisolated let state = VoiceSpeechState()

    init(localeIdentifier: String, readingVoiceIdentifier: String?, device: VoiceAudioDevice) {}

    func speak(_ text: String) {}

    func stop() {
        state.cancel()
    }
}
#endif
