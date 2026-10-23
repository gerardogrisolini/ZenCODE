//
//  TerminalDictationVoice.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 23/10/26.
//

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

enum TerminalDictationEvent: Sendable, Equatable {
    case partial(generation: UInt64, text: String)
    case ended(generation: UInt64)
}

enum TerminalDictationError: LocalizedError, Equatable {
    case unsupportedPlatform
    case unsupportedLanguage(String)
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Voice mode requires macOS."
        case let .unsupportedLanguage(identifier):
            return "Speech recognition does not support \(identifier)."
        case .recognizerUnavailable:
            return "Speech recognition is currently unavailable."
        }
    }
}

#if canImport(Speech) && canImport(AVFoundation)
/// Continuous speech recognition fed with the voice device's microphone
/// samples. Each `restart()` opens a new request with a new generation, so
/// events of a retired request are recognisable as stale.
final class TerminalDictationRecognizer: @unchecked Sendable {
    static let isSupported = true

    private let lock = NSLock()
    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation: UInt64 = 0
    private var onEvent: (@Sendable (TerminalDictationEvent) -> Void)?
    let localeIdentifier: String

    static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            return status == .authorized
        default:
            return false
        }
    }

    init(locale: Locale) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TerminalDictationError.unsupportedLanguage(locale.identifier)
        }
        guard recognizer.isAvailable else {
            throw TerminalDictationError.recognizerUnavailable
        }
        // Results are delivered off the main queue; the controller orders them.
        let queue = OperationQueue()
        queue.name = "ZenCODE.TUI.dictation-recognition"
        queue.maxConcurrentOperationCount = 1
        recognizer.queue = queue
        self.recognizer = recognizer
        localeIdentifier = recognizer.locale.identifier
    }

    /// On-device recognition keeps the continuous microphone stream local.
    var usesOnDeviceRecognition: Bool {
        recognizer.supportsOnDeviceRecognition
    }

    func setEventHandler(_ handler: @escaping @Sendable (TerminalDictationEvent) -> Void) {
        lock.withLock { onEvent = handler }
    }

    /// Retires the current request and opens a new one.
    @discardableResult
    func restart() -> UInt64 {
        let previous = lock.withLock { () -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?, UInt64, (@Sendable (TerminalDictationEvent) -> Void)?) in
            let previous = (request, task)
            request = nil
            task = nil
            generation &+= 1
            return (previous.0, previous.1, generation, onEvent)
        }
        previous.0?.endAudio()
        previous.1?.cancel()

        let generation = previous.2
        let handler = previous.3
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation
        newRequest.addsPunctuation = true
        newRequest.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let newTask = recognizer.recognitionTask(with: newRequest) { result, error in
            if let result {
                handler?(.partial(
                    generation: generation,
                    text: result.bestTranscription.formattedString
                ))
            }
            if error != nil || result?.isFinal == true {
                handler?(.ended(generation: generation))
            }
        }
        let isCurrent = lock.withLock { () -> Bool in
            guard self.generation == generation else {
                return false
            }
            request = newRequest
            task = newTask
            return true
        }
        if !isCurrent {
            newRequest.endAudio()
            newTask.cancel()
        }
        return generation
    }

    /// Appends mono 24 kHz Float32 microphone samples to the open request.
    func append(_ samples: [Float]) {
        guard let request = lock.withLock({ request }),
              !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: TerminalVoiceAudioDevice.sampleFormat,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0] else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        request.append(buffer)
    }

    func stop() {
        let previous = lock.withLock { () -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            let previous = (request, task)
            request = nil
            task = nil
            onEvent = nil
            generation &+= 1
            return previous
        }
        previous.0?.endAudio()
        previous.1?.cancel()
    }
}

/// Reuses one converter while consecutive buffers share a format.
private final class TerminalVoiceSampleConverter: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = TerminalVoiceAudioDevice.makeConverter(from: buffer.format)
        }
        guard let converter else {
            return []
        }
        return TerminalVoiceAudioDevice.monoSamples(from: buffer, converter: converter)
    }
}

/// Speaks assistant answers with the system synthesizer. Speech is rendered to
/// buffers and played through the voice device, so the engine's echo
/// cancellation hears it as its own output and the user can talk over it.
@MainActor
final class TerminalVoiceSpeaker {
    nonisolated let state = TerminalVoiceSpeechState()
    private let device: TerminalVoiceAudioDevice
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    init(localeIdentifier: String, device: TerminalVoiceAudioDevice) {
        self.device = device
        voice = Self.preferredVoice(localeIdentifier: localeIdentifier)
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
        state: TerminalVoiceSpeechState,
        device: TerminalVoiceAudioDevice
    ) -> @Sendable (AVAudioBuffer) -> Void {
        let converter = TerminalVoiceSampleConverter()
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

    /// The best installed non-novelty voice for the locale, preferring
    /// premium and enhanced voices.
    private static func preferredVoice(localeIdentifier: String) -> AVSpeechSynthesisVoice? {
        let identifier = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        let language = identifier.split(separator: "-").first.map { String($0).lowercased() } ?? identifier
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let exact = voices.filter { $0.language.caseInsensitiveCompare(identifier) == .orderedSame }
        let candidates = exact.isEmpty
            ? voices.filter { $0.language.lowercased().hasPrefix(language + "-") }
            : exact
        return candidates.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: identifier)
    }
}
#else
/// Dictation needs the Speech framework; elsewhere it never starts.
final class TerminalDictationRecognizer: Sendable {
    static let isSupported = false
    let localeIdentifier = ""

    static func requestAuthorization() async -> Bool {
        false
    }

    init(locale: Locale) throws {
        throw TerminalDictationError.unsupportedPlatform
    }

    var usesOnDeviceRecognition: Bool {
        false
    }

    func setEventHandler(_ handler: @escaping @Sendable (TerminalDictationEvent) -> Void) {}

    @discardableResult
    func restart() -> UInt64 {
        0
    }

    func append(_ samples: [Float]) {}

    func stop() {}
}

@MainActor
final class TerminalVoiceSpeaker {
    nonisolated let state = TerminalVoiceSpeechState()

    init(localeIdentifier: String, device: TerminalVoiceAudioDevice) {}

    func speak(_ text: String) {}

    func stop() {
        state.cancel()
    }
}
#endif

/// Owns the dictation voice loop of one interactive terminal: microphone and
/// speech permissions, continuous recognition split into utterances, barge-in
/// and spoken answers. Recognized utterances become ordinary prompts; audio is
/// never persisted.
actor TerminalDictationVoiceController {
    struct Callbacks: Sendable {
        let systemMessage: @Sendable (String) async -> Void
        let failureMessage: @Sendable (String) async -> Void
        let utteranceRecognized: @Sendable (String) async -> Void
    }

    enum Phase: Sendable, Equatable {
        case idle
        case starting
        case listening
        case failed
        case stopped
    }

    /// Whether this platform can run dictation at all.
    static var isSupported: Bool {
        TerminalVoiceAudioDevice.isSupported && TerminalDictationRecognizer.isSupported
    }

    static let microphoneDeniedMessage = "ZenCODE: microphone access is not granted. Allow your terminal app under System Settings > Privacy & Security > Microphone, then run /voice on.\n"

    /// Shown when the voice device runs without echo cancellation because the
    /// current output cannot run voice processing.
    static func echoCancellationUnavailableMessage(outputDeviceName: String?) -> String {
        let output = outputDeviceName.map { "the current audio output (\($0))" }
            ?? "the current audio output"
        return "Voice: echo cancellation is unavailable with \(output); switch to a local output or use headphones so you can talk over the assistant without it hearing itself.\n"
    }

    static let speechRecognitionDeniedMessage = "ZenCODE: speech recognition is not allowed. Allow your terminal app under System Settings > Privacy & Security > Speech Recognition, then run /voice on.\n"
    static let maximumRapidEndings = 5
    /// Requests are renewed while idle to stay under the recognizer's
    /// per-request duration limit.
    static let idleRequestLifetime = Duration.seconds(50)
    private static let silencePollInterval = Duration.milliseconds(200)

    static func listeningMessage(localeIdentifier: String, onDevice: Bool) -> String {
        let place = onDevice ? "on-device" : "Apple servers"
        return "Voice: listening (dictation, \(localeIdentifier), \(place)). Speak or type; answers are read aloud. /voice pauses or resumes, /voice off stops.\n"
    }

    private let callbacks: Callbacks
    private let languageCode: String
    private let locale: Locale
    private let device = TerminalVoiceAudioDevice()
    private var recognizer: TerminalDictationRecognizer?
    private var speaker: TerminalVoiceSpeaker?
    private var segmenter = TerminalDictationSegmenter()
    private var generation: UInt64 = 0
    private var generationStartedAt = ContinuousClock.now
    private var rapidEndings = 0
    private var eventTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var isAudioRunning = false
    private(set) var phase: Phase = .idle
    /// A paused voice mode neither listens nor reads answers aloud.
    private(set) var isPaused = false

    init(languageCode: String, locale: Locale, callbacks: Callbacks) {
        self.languageCode = languageCode
        self.locale = locale
        self.callbacks = callbacks
    }

    func start() async {
        guard phase == .idle || phase == .failed else {
            return
        }
        phase = .starting
        guard TerminalVoiceAudioDevice.isSupported, TerminalDictationRecognizer.isSupported else {
            await fail("ZenCODE: \(TerminalDictationError.unsupportedPlatform.localizedDescription)\n")
            return
        }
        guard await TerminalVoiceAudioDevice.requestMicrophoneAccess() else {
            await fail(Self.microphoneDeniedMessage)
            return
        }
        guard await TerminalDictationRecognizer.requestAuthorization() else {
            await fail(Self.speechRecognitionDeniedMessage)
            return
        }
        guard phase == .starting else {
            return
        }

        let recognizer: TerminalDictationRecognizer
        do {
            recognizer = try TerminalDictationRecognizer(locale: locale)
        } catch {
            await fail("ZenCODE: voice mode could not start: \(error.localizedDescription)\n")
            return
        }
        let (events, continuation) = AsyncStream.makeStream(
            of: TerminalDictationEvent.self,
            bufferingPolicy: .unbounded
        )
        recognizer.setEventHandler { event in
            continuation.yield(event)
        }
        let device = device
        let localeIdentifier = recognizer.localeIdentifier
        let speaker = await MainActor.run {
            TerminalVoiceSpeaker(localeIdentifier: localeIdentifier, device: device)
        }
        let hasEchoCancellation: Bool
        do {
            hasEchoCancellation = try device.start(
                capturePaused: isPaused,
                onSamples: { samples in
                    recognizer.append(samples)
                }
            )
        } catch {
            recognizer.stop()
            continuation.finish()
            await fail("ZenCODE: voice audio could not start: \(error.localizedDescription)\n")
            return
        }
        guard phase == .starting else {
            recognizer.stop()
            continuation.finish()
            device.stop()
            return
        }
        isAudioRunning = true
        self.recognizer = recognizer
        self.speaker = speaker
        rapidEndings = 0
        if !isPaused {
            restartRecognition()
        }
        eventTask = Task(name: "ZenCODE.TUI.dictation-events") { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
        silenceTask = Task(name: "ZenCODE.TUI.dictation-silence") { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.silencePollInterval)
                await self?.tick()
            }
        }
        phase = .listening
        await callbacks.systemMessage(Self.listeningMessage(
            localeIdentifier: localeIdentifier,
            onDevice: recognizer.usesOnDeviceRecognition
        ))
        if !hasEchoCancellation {
            await callbacks.systemMessage(Self.echoCancellationUnavailableMessage(
                outputDeviceName: device.outputDeviceName
            ))
        }
    }

    /// Reads an assistant answer aloud, replacing anything still being spoken.
    /// Answers completed while paused are never read later.
    func speak(_ response: String) async {
        guard phase == .listening, !isPaused, let speaker else {
            return
        }
        let text = TerminalVoiceSpeechText.speakable(fromMarkdown: response, languageCode: languageCode)
        guard !text.isEmpty else {
            return
        }
        device.interruptPlayback()
        await speaker.speak(text)
    }

    /// Stops the answer being spoken, e.g. after Esc or barge-in.
    func interruptPlayback() async {
        await speaker?.stop()
        device.interruptPlayback()
    }

    /// `false` once the controller failed or was stopped; `/voice on` then
    /// starts a new one.
    var isActive: Bool {
        switch phase {
        case .idle, .starting, .listening:
            return true
        case .failed, .stopped:
            return false
        }
    }

    /// Pausing stops listening and stops the answer being read aloud;
    /// resuming listens again. Returns `false` when already in that state.
    @discardableResult
    func setPaused(_ paused: Bool) async -> Bool {
        guard paused != isPaused else {
            return false
        }
        isPaused = paused
        if isAudioRunning {
            device.setCapturePaused(paused)
        }
        if paused {
            segmenter.reset()
            await interruptPlayback()
        } else if phase == .listening {
            rapidEndings = 0
            restartRecognition()
        }
        return true
    }

    func stop() async {
        phase = .stopped
        eventTask?.cancel()
        eventTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        recognizer?.stop()
        recognizer = nil
        await speaker?.stop()
        speaker = nil
        if isAudioRunning {
            device.stop()
            isAudioRunning = false
        }
        segmenter.reset()
    }

    // MARK: - Recognition

    private func handle(_ event: TerminalDictationEvent) async {
        guard phase == .listening, !isPaused else {
            return
        }
        switch event {
        case let .partial(eventGeneration, text):
            guard eventGeneration == generation else {
                return
            }
            let now = ContinuousClock.now
            if let reference = speaker?.state.echoReference(at: now),
               TerminalVoiceEchoGuard.isLikelyEcho(text, of: reference) {
                // The assistant's own voice leaked through: drop it.
                restartRecognition()
                return
            }
            let hasSpeech = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasSpeech, speaker?.state.isSpeaking(at: now) == true {
                await interruptPlayback()
            }
            segmenter.observe(text, at: now)

        case let .ended(eventGeneration):
            guard eventGeneration == generation else {
                return
            }
            let now = ContinuousClock.now
            if let utterance = segmenter.takeUtterance() {
                await emit(utterance, at: now)
            }
            if generationStartedAt.duration(to: now) < .seconds(1) {
                rapidEndings += 1
            } else {
                rapidEndings = 0
            }
            guard rapidEndings < Self.maximumRapidEndings else {
                await fail("ZenCODE: speech recognition stopped repeatedly. Run /voice on to retry.\n")
                return
            }
            if rapidEndings > 0 {
                try? await Task.sleep(for: .milliseconds(250 * rapidEndings))
            }
            guard phase == .listening, !isPaused, eventGeneration == generation else {
                return
            }
            restartRecognition()
        }
    }

    private func tick() async {
        guard phase == .listening, !isPaused else {
            return
        }
        let now = ContinuousClock.now
        if segmenter.isUtteranceComplete(at: now), let utterance = segmenter.takeUtterance() {
            // A request's transcript is cumulative: start a fresh one before
            // the next utterance.
            restartRecognition()
            await emit(utterance, at: now)
        } else if !segmenter.hasPendingText,
                  generationStartedAt.duration(to: now) >= Self.idleRequestLifetime {
            restartRecognition()
        }
    }

    private func emit(_ utterance: String, at now: ContinuousClock.Instant) async {
        if let reference = speaker?.state.echoReference(at: now),
           TerminalVoiceEchoGuard.isLikelyEcho(utterance, of: reference) {
            return
        }
        await callbacks.utteranceRecognized(utterance)
    }

    private func restartRecognition() {
        guard let recognizer else {
            return
        }
        segmenter.reset()
        generation = recognizer.restart()
        generationStartedAt = .now
    }

    private func fail(_ message: String) async {
        phase = .failed
        eventTask?.cancel()
        eventTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        recognizer?.stop()
        recognizer = nil
        await speaker?.stop()
        speaker = nil
        if isAudioRunning {
            device.stop()
            isAudioRunning = false
        }
        segmenter.reset()
        await callbacks.failureMessage(message)
    }
}
