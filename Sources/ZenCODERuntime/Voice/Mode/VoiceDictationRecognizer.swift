//
//  VoiceDictationRecognizer.swift
//  ZenCODE
//
//  Continuous on-device speech recognition of the dictation voice mode, with
//  the stub that never starts on platforms without Speech.
//

import Foundation
import Synchronization
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

#if canImport(Speech) && canImport(AVFoundation)
/// Continuous on-device speech recognition of the voice device's microphone
/// samples with `SpeechAnalyzer`. Each `restart()` opens a new analysis
/// session with a new generation, so events of a retired session are
/// recognisable as stale. `append` runs on the audio thread; it and the
/// controller's `restart` and `stop` touch the current session only under the
/// lock.
final class VoiceDictationRecognizer: @unchecked Sendable {
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
    private var onEvent: (@Sendable (VoiceDictationEvent) -> Void)?
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
    ) async throws -> VoiceDictationRecognizer {
        guard let model = await AppleSpeechModel.resolve(for: locale) else {
            throw VoiceDictationError.unsupportedLanguage(locale.identifier)
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
            throw VoiceDictationError.speechModelDownloadFailed(localeIdentifier, error.localizedDescription)
        }
        let deviceFormat = VoiceAudioDevice.sampleFormat
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module],
            considering: deviceFormat
        ) ?? deviceFormat
        return VoiceDictationRecognizer(
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

    func setEventHandler(_ handler: @escaping @Sendable (VoiceDictationEvent) -> Void) {
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
            () -> (Session?, UInt64, (@Sendable (VoiceDictationEvent) -> Void)?) in
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

        let events = VoiceDictationSessionEvents(generation: generation, handler: handler)
        let results = module.results()
        let consumer = Task(name: "ZenCODE.dictation-results") {
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
        Task(name: "ZenCODE.dictation-analyzer") {
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
                  pcmFormat: VoiceAudioDevice.sampleFormat,
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
        let deviceFormat = VoiceAudioDevice.sampleFormat
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
        let feed = VoiceConverterFeed(buffer)
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
private final class VoiceDictationSessionEvents: Sendable {
    private let generation: UInt64
    private let handler: Mutex<(@Sendable (VoiceDictationEvent) -> Void)?>

    init(generation: UInt64, handler: (@Sendable (VoiceDictationEvent) -> Void)?) {
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
#else
/// Dictation needs the Speech framework; elsewhere it never starts.
final class VoiceDictationRecognizer: Sendable {
    static let isSupported = false
    let localeIdentifier = ""

    static func requestAuthorization() async -> Bool {
        false
    }

    static func make(
        locale: Locale,
        onDownload: @escaping @Sendable (_ localeIdentifier: String) async -> Void
    ) async throws -> VoiceDictationRecognizer {
        throw VoiceDictationError.unsupportedPlatform
    }

    func setEventHandler(_ handler: @escaping @Sendable (VoiceDictationEvent) -> Void) {}

    @discardableResult
    func restart() -> UInt64 {
        0
    }

    func append(_ samples: [Float]) {}

    func stop() {}
}
#endif
