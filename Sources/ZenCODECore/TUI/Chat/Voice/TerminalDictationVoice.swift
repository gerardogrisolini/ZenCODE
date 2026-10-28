//
//  TerminalDictationVoice.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 23/10/26.
//

import Foundation
import Synchronization
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

enum TerminalDictationEvent: Sendable, Equatable {
    /// A recognition result. `endsSegment` marks a final one, which closes
    /// the speech segment recognized since the previous final result: the
    /// next results hold only what is said after it, so the earlier words
    /// must be kept by the receiver.
    case partial(generation: UInt64, text: String, endsSegment: Bool)
    case ended(generation: UInt64)
}

enum TerminalDictationError: LocalizedError, Equatable {
    case unsupportedPlatform
    case unsupportedLanguage(String)
    /// The language's speech model could not be downloaded: the locale and
    /// the reason.
    case speechModelDownloadFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Voice mode requires macOS."
        case let .unsupportedLanguage(identifier):
            return "Speech recognition does not support \(identifier)."
        case let .speechModelDownloadFailed(identifier, detail):
            return "The speech recognition model for \(identifier) could not be downloaded (\(detail)). Check the network connection and run /voice on again."
        }
    }
}

#if canImport(Speech) && canImport(AVFoundation)
/// Continuous on-device speech recognition of the voice device's microphone
/// samples with `SpeechAnalyzer`. Each `restart()` opens a new analysis
/// session with a new generation, so events of a retired session are
/// recognisable as stale. `append` runs on the audio thread; it and the
/// controller's `restart` and `stop` touch the current session only under the
/// lock.
final class TerminalDictationRecognizer: @unchecked Sendable {
    static let isSupported = true

    /// The input of one analyzer, fed with the samples received while its
    /// generation is current.
    private struct Session {
        let generation: UInt64
        let input: AsyncStream<AnalyzerInput>.Continuation
        /// Finished when the session is retired: its analysis then ends.
        let retirement: AsyncStream<Void>.Continuation
        /// Converts the device's samples to the analyzer format, keeping its
        /// resampling state across buffers; `nil` when the formats match.
        let converter: AVAudioConverter?
    }

    private let lock = NSLock()
    private let model: AppleSpeechModel
    private let analyzerFormat: AVAudioFormat
    private var session: Session?
    private var generation: UInt64 = 0
    private var onEvent: (@Sendable (TerminalDictationEvent) -> Void)?
    /// The recognized locale in ICU form, e.g. `it_IT`.
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

    /// Resolves the model for `locale` and installs it when missing:
    /// `onDownload` receives the recognized locale before a download starts.
    static func make(
        locale: Locale,
        onDownload: @escaping @Sendable (_ localeIdentifier: String) async -> Void
    ) async throws -> TerminalDictationRecognizer {
        guard let model = await AppleSpeechModel.resolve(for: locale) else {
            throw TerminalDictationError.unsupportedLanguage(locale.identifier)
        }
        let localeIdentifier = model.locale.identifier(.icu)
        let module = model.makeModule(for: .live).module
        do {
            try await AppleSpeechModel.installAssets(for: [module]) {
                await onDownload(localeIdentifier)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TerminalDictationError.speechModelDownloadFailed(localeIdentifier, error.localizedDescription)
        }
        let deviceFormat = TerminalVoiceAudioDevice.sampleFormat
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module],
            considering: deviceFormat
        ) ?? deviceFormat
        return TerminalDictationRecognizer(
            model: model,
            analyzerFormat: analyzerFormat,
            localeIdentifier: localeIdentifier
        )
    }

    private init(model: AppleSpeechModel, analyzerFormat: AVAudioFormat, localeIdentifier: String) {
        self.model = model
        self.analyzerFormat = analyzerFormat
        self.localeIdentifier = localeIdentifier
    }

    func setEventHandler(_ handler: @escaping @Sendable (TerminalDictationEvent) -> Void) {
        lock.withLock { onEvent = handler }
    }

    /// Retires the current session and opens a new one. Samples appended
    /// from now on go to the new analyzer, buffered until it starts. The
    /// session's results become `.partial` events, followed by exactly one
    /// `.ended`.
    @discardableResult
    func restart() -> UInt64 {
        let module = model.makeModule(for: .live)
        let analyzer = SpeechAnalyzer(modules: [module.module], options: AppleSpeechModel.analyzerOptions)
        let (inputs, input) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        let (retirement, retirementContinuation) = AsyncStream.makeStream(of: Void.self)
        let converter = Self.makeConverter(to: analyzerFormat)
        let (retired, generation, handler) = lock.withLock {
            () -> (Session?, UInt64, (@Sendable (TerminalDictationEvent) -> Void)?) in
            let retired = session
            generation &+= 1
            session = Session(
                generation: generation,
                input: input,
                retirement: retirementContinuation,
                converter: converter
            )
            return (retired, generation, onEvent)
        }
        Self.retire(retired)

        let events = TerminalDictationSessionEvents(generation: generation, handler: handler)
        let results = module.results()
        let consumer = Task(name: "ZenCODE.TUI.dictation-results") {
            do {
                for try await result in results {
                    events.deliver(result)
                }
            } catch {
                // The analysis was retired or failed: the session ends.
            }
            events.end()
        }
        let format = analyzerFormat
        Task(name: "ZenCODE.TUI.dictation-analyzer") {
            do {
                // Prepared even when already retired: only an analyzer that
                // got ready ends its results when cancelled.
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: inputs)
                for await _ in retirement {}
            } catch {
                // Preparing or starting failed: the session ends now.
            }
            await analyzer.cancelAndFinishNow()
            // Ends the results even of an analyzer that never got ready.
            consumer.cancel()
        }
        return generation
    }

    /// Appends mono 24 kHz Float32 microphone samples to the current session,
    /// converted to the analyzer format. Called on the audio thread.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty,
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
        let format = analyzerFormat
        lock.withLock {
            guard let session else {
                return
            }
            let input: AVAudioPCMBuffer?
            if let converter = session.converter {
                input = Self.convert(buffer, with: converter, to: format)
            } else {
                input = buffer
            }
            if let input {
                session.input.yield(AnalyzerInput(buffer: input))
            }
        }
    }

    func stop() {
        let retired = lock.withLock { () -> Session? in
            let retired = session
            session = nil
            onEvent = nil
            generation &+= 1
            return retired
        }
        Self.retire(retired)
    }

    /// Ends a session's input and lets its analyzer task cancel the analysis,
    /// which ends the session's results.
    private static func retire(_ session: Session?) {
        guard let session else {
            return
        }
        session.input.finish()
        session.retirement.finish()
    }

    private static func makeConverter(to format: AVAudioFormat) -> AVAudioConverter? {
        let deviceFormat = TerminalVoiceAudioDevice.sampleFormat
        guard format != deviceFormat else {
            return nil
        }
        return AVAudioConverter(from: deviceFormat, to: format)
    }

    /// Converts one buffer with the session's converter, which keeps its
    /// resampling state for the next buffer. `nil` when nothing came out.
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        let feed = TerminalVoiceConverterFeed(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            feed.next(inputStatus)
        }
        guard status != .error, output.frameLength > 0 else {
            return nil
        }
        return output
    }
}

/// Delivers the events of one recognition session in order and ends it
/// exactly once: nothing is delivered after `.ended`.
private final class TerminalDictationSessionEvents: Sendable {
    private let generation: UInt64
    private let handler: Mutex<(@Sendable (TerminalDictationEvent) -> Void)?>

    init(generation: UInt64, handler: (@Sendable (TerminalDictationEvent) -> Void)?) {
        self.generation = generation
        self.handler = Mutex(handler)
    }

    func deliver(_ result: AppleSpeechResult) {
        handler.withLock { handler in
            handler?(.partial(generation: generation, text: result.text, endsSegment: result.isFinal))
        }
    }

    func end() {
        handler.withLock { handler in
            handler?(.ended(generation: generation))
            handler = nil
        }
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

    init(localeIdentifier: String, readingVoiceIdentifier: String?, device: TerminalVoiceAudioDevice) {
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

    /// The voice saved in `/setup` > Voice mode when it is installed and reads
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
#else
/// Dictation needs the Speech framework; elsewhere it never starts.
final class TerminalDictationRecognizer: Sendable {
    static let isSupported = false
    let localeIdentifier = ""

    static func requestAuthorization() async -> Bool {
        false
    }

    static func make(
        locale: Locale,
        onDownload: @escaping @Sendable (_ localeIdentifier: String) async -> Void
    ) async throws -> TerminalDictationRecognizer {
        throw TerminalDictationError.unsupportedPlatform
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

    init(localeIdentifier: String, readingVoiceIdentifier: String?, device: TerminalVoiceAudioDevice) {}

    func speak(_ text: String) {}

    func stop() {
        state.cancel()
    }
}
#endif

/// Owns the dictation voice loop of one interactive terminal on macOS:
/// microphone and speech permissions, continuous recognition split into
/// utterances, barge-in and spoken answers. Recognized utterances become
/// ordinary prompts; audio is never persisted.
actor TerminalDictationVoiceController: TerminalVoiceController {
    typealias Callbacks = TerminalVoiceCallbacks

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
    private static let silencePollInterval = Duration.milliseconds(200)

    static func listeningMessage(localeIdentifier: String) -> String {
        "Voice: listening (dictation, \(localeIdentifier), on-device). Speak or type; answers are read aloud. /voice pauses or resumes, /voice off stops.\n"
    }

    /// Shown before macOS downloads the language's speech model.
    static func downloadingMessage(localeIdentifier: String) -> String {
        "Voice: downloading the speech recognition model for \(localeIdentifier); macOS does this only the first time.\n"
    }

    private let callbacks: Callbacks
    nonisolated let languageCode: String
    private let locale: Locale
    /// The reading voice chosen in `/setup` > Voice mode, if any.
    private let readingVoiceIdentifier: String?
    /// The options chosen in `/setup` > Voice mode.
    private let options: TerminalVoiceOptions
    private let device = TerminalVoiceAudioDevice()
    private var recognizer: TerminalDictationRecognizer?
    private var speaker: TerminalVoiceSpeaker?
    private var segmenter: TerminalDictationSegmenter
    /// Set in keyword send mode: speech waiting for the keyword.
    private var keywordCollector: TerminalVoiceKeywordCollector?
    /// The live-chat dialogue awaits a yes or no.
    private var isAwaitingShortAnswer = false
    /// The dictation previewed in the prompt draft. Advances after every
    /// dictation sent and every discard, so the terminal ignores previews
    /// and sends of a dictation it already ended.
    private var dictationID: UInt64 = 1
    /// The preview last reported for `dictationID`.
    private var publishedDictation = ""
    /// A preview is being reported. Reports run one at a time, so they reach
    /// the terminal in order; the one in flight reports the latest text.
    private var isPublishingDictation = false
    private var generation: UInt64 = 0
    private var generationStartedAt = ContinuousClock.now
    private var rapidEndings = 0
    private var reportedSpeaking = false
    private var eventTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var isAudioRunning = false
    private(set) var phase: Phase = .idle
    /// A paused voice mode neither listens nor reads answers aloud.
    private(set) var isPaused = false

    init(
        languageCode: String,
        locale: Locale,
        readingVoiceIdentifier: String? = nil,
        options: TerminalVoiceOptions = TerminalVoiceOptions(),
        callbacks: Callbacks
    ) {
        self.languageCode = languageCode
        self.locale = locale
        self.readingVoiceIdentifier = readingVoiceIdentifier
        self.options = options
        self.segmenter = TerminalDictationSegmenter(silence: options.utteranceSilence)
        self.keywordCollector = options.sendKeyword.map(TerminalVoiceKeywordCollector.init)
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
            let callbacks = callbacks
            recognizer = try await TerminalDictationRecognizer.make(locale: locale) { localeIdentifier in
                await callbacks.systemMessage(Self.downloadingMessage(localeIdentifier: localeIdentifier))
            }
        } catch {
            guard phase == .starting else {
                return
            }
            await fail("ZenCODE: voice mode could not start: \(error.localizedDescription)\n")
            return
        }
        // The model may have been downloaded meanwhile: `/voice off` may have
        // stopped the controller.
        guard phase == .starting else {
            recognizer.stop()
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
        let readingVoiceIdentifier = readingVoiceIdentifier
        let speaker = await MainActor.run {
            TerminalVoiceSpeaker(
                localeIdentifier: localeIdentifier,
                readingVoiceIdentifier: readingVoiceIdentifier,
                device: device
            )
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
        await callbacks.systemMessage(Self.listeningMessage(localeIdentifier: localeIdentifier))
        if !hasEchoCancellation {
            await callbacks.systemMessage(Self.echoCancellationUnavailableMessage(
                outputDeviceName: device.outputDeviceName
            ))
        }
    }

    /// Reads an assistant answer or a plain text aloud, replacing anything
    /// still being spoken. Answers completed while paused are never read
    /// later.
    @discardableResult
    func speak(_ text: String, rendering: TerminalVoiceSpeechRendering) async -> Bool {
        guard phase == .listening, !isPaused, let speaker else {
            return false
        }
        let spoken: String
        switch rendering {
        case .answer:
            spoken = TerminalVoiceSpeechText.speakable(
                fromMarkdown: text,
                languageCode: languageCode
            )
        case .plainText:
            spoken = text
        }
        guard !spoken.isEmpty else {
            return false
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
            keywordCollector?.reset()
            await interruptPlayback()
            await publishDictation()
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
        keywordCollector?.reset()
        await reportSpeakingState()
        await publishDictation()
    }

    func setAwaitingShortAnswer(_ awaiting: Bool) {
        isAwaitingShortAnswer = awaiting
    }

    func discardDictation(through id: UInt64) async {
        guard id >= dictationID else {
            return
        }
        segmenter.reset()
        keywordCollector?.reset()
        dictationID = id &+ 1
        publishedDictation = ""
        // A session keeps reporting the segment in progress: without a fresh
        // one the discarded words would come back with the next partial result.
        if phase == .listening, !isPaused {
            restartRecognition()
        }
    }

    // MARK: - Recognition

    private func handle(_ event: TerminalDictationEvent) async {
        guard phase == .listening, !isPaused else {
            return
        }
        switch event {
        case let .partial(eventGeneration, text, endsSegment):
            guard eventGeneration == generation else {
                return
            }
            let now = ContinuousClock.now
            if isResidualEcho(text, at: now) {
                // The assistant's own voice leaked through: drop it.
                restartRecognition()
                await publishDictation()
                return
            }
            let hasSpeech = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasSpeech, speaker?.state.isSpeaking(at: now) == true {
                await interruptPlayback()
            }
            segmenter.observe(text, at: now, endsSegment: endsSegment)
            await publishDictation()

        case let .ended(eventGeneration):
            guard eventGeneration == generation else {
                return
            }
            let now = ContinuousClock.now
            if let utterance = segmenter.takeUtterance() {
                if keywordCollector != nil {
                    // The session ended on its own: the text waits for the
                    // keyword unless it already ends with it.
                    await receiveKeywordSpeech(utterance, at: now)
                } else {
                    await sendPauseUtterance(utterance, at: now)
                }
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
        await reportSpeakingState()
        guard phase == .listening, !isPaused else {
            return
        }
        let now = ContinuousClock.now
        if let collector = keywordCollector {
            // Keyword mode: silence never sends; a text ending with the
            // keyword (or a bare yes/no while one is awaited) does, once the
            // recognizer finalized the segment ending with it, so a word still
            // being recognized ("vai" on the way to "vaiolo") does not send.
            // The keyword alone sends the typed draft.
            if segmenter.endsWithClosedSegment,
               collector.peek(segmenter.text, awaitingShortAnswer: isAwaitingShortAnswer).sends,
               let speech = segmenter.takeUtterance() {
                restartRecognition()
                await receiveKeywordSpeech(speech, at: now)
            }
            return
        }
        if segmenter.isUtteranceComplete(at: now), let utterance = segmenter.takeUtterance() {
            // The session still reports the segment in progress: start a
            // fresh one before the next utterance.
            restartRecognition()
            await sendPauseUtterance(utterance, at: now)
        }
    }

    /// A finished segment in keyword send mode: sent on the keyword or as an
    /// awaited yes or no, otherwise collected and previewed.
    private func receiveKeywordSpeech(_ speech: String, at now: ContinuousClock.Instant) async {
        switch keywordCollector?.receive(speech, awaitingShortAnswer: isAwaitingShortAnswer) {
        case let .send(text):
            await sendDictation(text, at: now)
        case let .answer(text):
            await sendAnswer(text, at: now)
        case .collected, .nothing, nil:
            await publishDictation()
        }
    }

    /// A finished utterance in pause send mode.
    private func sendPauseUtterance(_ utterance: String, at now: ContinuousClock.Instant) async {
        if TerminalVoiceUtterance.isAwaitedAnswer(utterance, awaitingShortAnswer: isAwaitingShortAnswer) {
            await sendAnswer(utterance, at: now)
        } else {
            await sendDictation(utterance, at: now)
        }
    }

    /// Sends an awaited yes or no alone: only its preview leaves the draft,
    /// the typed text stays.
    private func sendAnswer(_ answer: String, at now: ContinuousClock.Instant) async {
        await publishDictation()
        guard !isResidualEcho(answer, at: now) else {
            return
        }
        await callbacks.utteranceRecognized(.answer(answer))
    }

    /// Sends the final words of the current dictation; the terminal sends
    /// them after the typed draft. A residual echo is not sent and its
    /// preview is removed.
    private func sendDictation(_ text: String, at now: ContinuousClock.Instant) async {
        guard !isResidualEcho(text, at: now) else {
            await publishDictation()
            return
        }
        let id = dictationID
        await callbacks.utteranceRecognized(.dictation(id: id, text: text))
        // A discard may have advanced the id while the send was delivered.
        dictationID = max(dictationID, id &+ 1)
        publishedDictation = ""
        // Speech recognized meanwhile starts the next dictation.
        await publishDictation()
    }

    /// Reports the speech recognized but not sent yet, previewed at the end
    /// of the prompt draft: the current utterance, after the speech
    /// collected for the keyword in keyword mode. Only changes are reported.
    private func publishDictation() async {
        guard !isPublishingDictation else {
            return
        }
        isPublishingDictation = true
        defer {
            isPublishingDictation = false
        }
        while true {
            let text = keywordCollector.map { TerminalVoiceSendKeyword.joined($0.pending, segmenter.text) }
                ?? segmenter.text
            guard text != publishedDictation else {
                return
            }
            publishedDictation = text
            await callbacks.dictationChanged(dictationID, text)
        }
    }

    /// Whether `text` is the assistant's own voice leaking through the
    /// microphone, during the reading or within its echo tail.
    private func isResidualEcho(_ text: String, at now: ContinuousClock.Instant) -> Bool {
        guard let state = speaker?.state, let reference = state.echoReference(at: now) else {
            return false
        }
        return TerminalVoiceEchoGuard.shouldDrop(
            text,
            spokenReference: reference,
            isSpeaking: state.isSpeaking(at: now)
        )
    }

    private func restartRecognition() {
        guard let recognizer else {
            return
        }
        segmenter.reset()
        generation = recognizer.restart()
        generationStartedAt = .now
    }

    /// Tells the terminal when reading aloud starts or ends, so `Esc` stops
    /// it. Polled by the silence task because the synthesizer reports the end
    /// of speech only through its played buffers.
    private func reportSpeakingState() async {
        let isSpeaking = speaker?.state.isSpeaking() ?? false
        guard isSpeaking != reportedSpeaking else {
            return
        }
        reportedSpeaking = isSpeaking
        await callbacks.speakingChanged(isSpeaking)
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
        keywordCollector?.reset()
        await reportSpeakingState()
        await publishDictation()
        await callbacks.failureMessage(message)
    }
}
