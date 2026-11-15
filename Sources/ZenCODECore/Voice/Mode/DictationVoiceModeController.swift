//
//  DictationVoiceModeController.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 23/10/26.
//

import Foundation

enum VoiceDictationEvent: Sendable, Equatable {
    /// A recognition result. `endsSegment` marks a final one, which closes
    /// the speech segment recognized since the previous final result: the
    /// next results hold only what is said after it, so the earlier words
    /// must be kept by the receiver.
    case partial(generation: UInt64, text: String, endsSegment: Bool)
    case ended(generation: UInt64)
}

enum VoiceDictationError: LocalizedError, Equatable {
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

/// Groups a burst of change notifications, e.g. the audio configuration
/// changes posted while headphones connect: each change waits a short
/// settling time, and only the last one of the burst then proceeds.
struct VoiceChangeSettler: Sendable, Equatable {
    private var latest: UInt64 = 0

    /// Records a change and returns its token.
    mutating func begin() -> UInt64 {
        latest &+= 1
        return latest
    }

    /// Whether no change was recorded after the one with `token`.
    func isLatest(_ token: UInt64) -> Bool {
        token == latest
    }
}

/// Decides what follows a restart of the voice device after an audio device
/// change: the engine may stop again right away, e.g. when it never stays
/// running on the new hardware, and restarting must not go on forever.
struct VoiceAudioRestartPolicy: Sendable, Equatable {
    enum Decision: Sendable, Equatable {
        /// The engine runs: listen again and tell the user.
        case announce
        /// The engine stopped again: show nothing, another restart follows.
        case retry
        /// The engine keeps stopping: give up.
        case fail
    }

    /// The restarts in a row after which the engine was stopped again.
    static let maximumConsecutiveAudioRestarts = 3

    private(set) var consecutiveAudioRestarts = 0

    /// Records a restart of the device and returns what follows it.
    /// `isEngineRunning` is whether the engine runs right after the restart.
    mutating func restarted(isEngineRunning: Bool) -> Decision {
        guard !isEngineRunning else {
            consecutiveAudioRestarts = 0
            return .announce
        }
        consecutiveAudioRestarts += 1
        return consecutiveAudioRestarts >= Self.maximumConsecutiveAudioRestarts ? .fail : .retry
    }

    mutating func reset() {
        consecutiveAudioRestarts = 0
    }
}

/// Owns the dictation voice loop of one interactive terminal on macOS:
/// microphone and speech permissions, continuous recognition split into
/// utterances, barge-in and spoken answers. Recognized utterances become
/// ordinary prompts; audio is never persisted.
actor DictationVoiceModeController: VoiceModeController {
    typealias Callbacks = VoiceModeCallbacks

    enum Phase: Sendable, Equatable {
        case idle
        case starting
        case listening
        case failed
        case stopped
    }

    /// Whether this platform can run dictation at all.
    static var isSupported: Bool {
        VoiceAudioDevice.isSupported && VoiceDictationRecognizer.isSupported
    }

    static let microphoneDeniedMessage = "ZenCODE: microphone access is not granted. Allow your terminal app under System Settings > Privacy & Security > Microphone, then run /voice on.\n"

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

    static let audioDeviceChangedMessage = "Voice: the audio device changed; listening again.\n"
    static let audioRestartFailedMessage = "ZenCODE: voice audio could not restart after the audio device changed: the audio engine keeps stopping. Run /voice on to retry.\n"
    /// Audio configuration changes this close together form one device change.
    static let audioChangeSettling = Duration.milliseconds(300)

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
    /// The reading voice chosen in `zen --setup` > Voice mode, if any.
    private let readingVoiceIdentifier: String?
    /// The options chosen in `zen --setup` > Voice mode.
    private let options: VoiceModeOptions
    private let device = VoiceAudioDevice()
    private var recognizer: VoiceDictationRecognizer?
    private var speaker: VoiceSpeaker?
    private var segmenter: VoiceDictationSegmenter
    /// Set in keyword send mode: speech waiting for the keyword.
    private var keywordCollector: VoiceKeywordCollector?
    /// The live-chat dialogue awaits a yes or no.
    private var isAwaitingShortAnswer = false
    /// Tells a yes or no said to a question that an answer has just replaced.
    private var strayAnswerGuard = VoiceStrayAnswerGuard()
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
    /// Whether the voice device last started with echo cancellation; `true`
    /// until it first starts.
    private var hasEchoCancellation = true
    /// Groups the audio configuration changes of one device change.
    private var audioChanges = VoiceChangeSettler()
    /// Limits the restarts in a row after which the audio engine stopped again.
    private var audioRestarts = VoiceAudioRestartPolicy()
    private(set) var phase: Phase = .idle
    /// A paused voice mode neither listens nor reads answers aloud.
    private(set) var isPaused = false

    init(
        languageCode: String,
        locale: Locale,
        readingVoiceIdentifier: String? = nil,
        options: VoiceModeOptions = VoiceModeOptions(),
        callbacks: Callbacks
    ) {
        self.languageCode = languageCode
        self.locale = locale
        self.readingVoiceIdentifier = readingVoiceIdentifier
        self.options = options
        self.segmenter = VoiceDictationSegmenter(silence: options.utteranceSilence)
        self.keywordCollector = options.sendKeyword.map(VoiceKeywordCollector.init)
        self.callbacks = callbacks
    }

    func start() async {
        guard phase == .idle || phase == .failed else {
            return
        }
        phase = .starting
        hasEchoCancellation = true
        audioRestarts.reset()
        guard VoiceAudioDevice.isSupported, VoiceDictationRecognizer.isSupported else {
            await fail("ZenCODE: \(VoiceDictationError.unsupportedPlatform.localizedDescription)\n")
            return
        }
        guard await VoiceAudioDevice.requestMicrophoneAccess() else {
            await fail(Self.microphoneDeniedMessage)
            return
        }
        guard await VoiceDictationRecognizer.requestAuthorization() else {
            await fail(Self.speechRecognitionDeniedMessage)
            return
        }
        guard phase == .starting else {
            return
        }

        let recognizer: VoiceDictationRecognizer
        do {
            let callbacks = callbacks
            recognizer = try await VoiceDictationRecognizer.make(locale: locale) { localeIdentifier in
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
            of: VoiceDictationEvent.self,
            bufferingPolicy: .unbounded
        )
        recognizer.setEventHandler { event in
            continuation.yield(event)
        }
        let device = device
        let localeIdentifier = recognizer.localeIdentifier
        let readingVoiceIdentifier = readingVoiceIdentifier
        let speaker = await MainActor.run {
            VoiceSpeaker(
                localeIdentifier: localeIdentifier,
                readingVoiceIdentifier: readingVoiceIdentifier,
                device: device
            )
        }
        guard phase == .starting else {
            recognizer.stop()
            continuation.finish()
            return
        }
        // A pause asked while starting keeps the microphone closed: resuming
        // starts the device.
        var echoCancellationNotice: String?
        if !isPaused {
            do {
                echoCancellationNotice = try startAudio(feeding: recognizer)
            } catch {
                recognizer.stop()
                continuation.finish()
                await fail("ZenCODE: voice audio could not start: \(error.localizedDescription)\n")
                return
            }
        }
        self.recognizer = recognizer
        self.speaker = speaker
        rapidEndings = 0
        if !isPaused {
            restartRecognition()
        }
        eventTask = Task(name: "ZenCODE.dictation-events") { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
        silenceTask = Task(name: "ZenCODE.dictation-silence") { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.silencePollInterval)
                await self?.tick()
            }
        }
        phase = .listening
        await callbacks.systemMessage(Self.listeningMessage(localeIdentifier: localeIdentifier))
        if let echoCancellationNotice {
            await callbacks.systemMessage(echoCancellationNotice)
        }
    }

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

    /// Pausing stops listening and stops the answer being read aloud, then
    /// stops the voice device, which releases the microphone; resuming starts
    /// it and listens again. Returns `false` when already in that state.
    @discardableResult
    func setPaused(_ paused: Bool) async -> Bool {
        guard paused != isPaused else {
            return false
        }
        isPaused = paused
        if paused {
            segmenter.reset()
            keywordCollector?.reset()
            await interruptPlayback()
            // Nothing is read aloud while paused: the device can stop. The
            // recognizer stays, so resuming opens a new session of it.
            if isPaused {
                stopAudio()
            }
            await publishDictation()
        } else if phase == .listening {
            rapidEndings = 0
            audioRestarts.reset()
            var echoCancellationNotice: String?
            if !isAudioRunning, let recognizer {
                do {
                    echoCancellationNotice = try startAudio(feeding: recognizer)
                } catch {
                    await fail("ZenCODE: voice audio could not start: \(error.localizedDescription)\n")
                    return true
                }
            }
            restartRecognition()
            if let echoCancellationNotice {
                await callbacks.systemMessage(echoCancellationNotice)
            }
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
        stopAudio()
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

    // MARK: - Audio

    /// Starts the voice device feeding `recognizer`, observing its audio
    /// configuration changes. Returns the notice to show when echo
    /// cancellation was active before and is not now.
    private func startAudio(feeding recognizer: VoiceDictationRecognizer) throws -> String? {
        let isEchoCancelling = try device.start(
            onSamples: { samples in
                recognizer.append(samples)
            },
            onConfigurationChange: { [weak self] in
                guard let self else {
                    return
                }
                Task(name: "ZenCODE.dictation-audio-change") {
                    await self.audioConfigurationChanged()
                }
            }
        )
        isAudioRunning = true
        let wasEchoCancelling = hasEchoCancellation
        hasEchoCancellation = isEchoCancelling
        return Self.echoCancellationLossNotice(
            wasActive: wasEchoCancelling,
            isActive: isEchoCancelling,
            outputDeviceName: device.outputDeviceName
        )
    }

    private func stopAudio() {
        guard isAudioRunning else {
            return
        }
        device.stop()
        isAudioRunning = false
    }

    /// The audio hardware changed, e.g. headphones were connected, and the
    /// engine stopped itself. A device change posts a burst of notifications:
    /// once it settles, only the last one, and only if the engine really
    /// stopped, stops the reading in progress, starts the device again, which
    /// installs the capture tap for the new input format, and opens a new
    /// recognition session. When the engine stops again right away, the device
    /// reports it and another restart follows, up to a limit.
    private func audioConfigurationChanged() async {
        let change = audioChanges.begin()
        try? await Task.sleep(for: Self.audioChangeSettling)
        guard isPendingAudioChange(change) else {
            return
        }
        await interruptPlayback()
        guard isPendingAudioChange(change), let recognizer else {
            return
        }
        stopAudio()
        let hadEchoCancellation = hasEchoCancellation
        let echoCancellationNotice: String?
        do {
            echoCancellationNotice = try startAudio(feeding: recognizer)
        } catch {
            await fail("ZenCODE: voice audio could not restart after the audio device changed: \(error.localizedDescription) Run /voice on to retry.\n")
            return
        }
        switch audioRestarts.restarted(isEngineRunning: !device.hasStoppedItself) {
        case .announce:
            restartRecognition()
            // The speech recognized before the change went with its session.
            await publishDictation()
            await callbacks.systemMessage(Self.audioDeviceChangedMessage)
            if let echoCancellationNotice {
                await callbacks.systemMessage(echoCancellationNotice)
            }
        case .retry:
            // The device reports the stopped engine, so another restart
            // follows; it reports the echo cancellation that was lost.
            hasEchoCancellation = hadEchoCancellation
        case .fail:
            await fail(Self.audioRestartFailedMessage)
        }
    }

    /// Whether the audio change with `token` is the last one and the device
    /// still has to start again: voice mode listens with the device running,
    /// and its engine stopped itself. A notification can arrive with the engine
    /// still running, e.g. shortly after voice processing was enabled.
    private func isPendingAudioChange(_ token: UInt64) -> Bool {
        audioChanges.isLatest(token)
            && phase == .listening
            && !isPaused
            && isAudioRunning
            && device.hasStoppedItself
    }

    // MARK: - Recognition

    private func handle(_ event: VoiceDictationEvent) async {
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
            let startedAt = segmenter.startedAt
            if let utterance = segmenter.takeUtterance() {
                if isStrayAnswer(utterance, startedAt: startedAt) {
                    // Said to a question an answer has replaced: not sent.
                    await publishDictation()
                } else if keywordCollector != nil {
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
        let startedAt = segmenter.startedAt
        if segmenter.endsWithClosedSegment, isStrayAnswer(segmenter.text, startedAt: startedAt) {
            // A yes or no to a question an answer has just replaced: dropped
            // in either send mode once the recognizer finalized it, so it is
            // neither sent nor left in the draft.
            restartRecognition()
            await publishDictation()
            return
        }
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
        // Pause mode. A bare yes or no the live-chat dialogue awaits does not
        // wait for the pause: it is sent once the recognizer finalized it, as
        // in keyword mode, so one still being recognized ("sì" on the way to
        // "sì, ma prima…") does not send.
        if segmenter.hasFinalizedAnswer(awaitingShortAnswer: isAwaitingShortAnswer),
           let answer = segmenter.takeUtterance() {
            restartRecognition()
            await sendAnswer(answer, at: now)
            return
        }
        if segmenter.isUtteranceComplete(at: now), let utterance = segmenter.takeUtterance() {
            // The session still reports the segment in progress: start a
            // fresh one before the next utterance.
            restartRecognition()
            if isStrayAnswer(utterance, startedAt: startedAt) {
                // The pause ended before the recognizer finalized it.
                await publishDictation()
            } else {
                await sendPauseUtterance(utterance, at: now)
            }
        }
    }

    /// Whether `speech`, whose first words were recognized at `startedAt`, is
    /// a yes or no said to a live-chat question that an answer has just
    /// replaced (see `VoiceStrayAnswerGuard`): it is dropped, never sent.
    /// After speech collected for the keyword it is ordinary text.
    private func isStrayAnswer(_ speech: String, startedAt: ContinuousClock.Instant?) -> Bool {
        guard keywordCollector?.pending.isEmpty ?? true else {
            return false
        }
        return strayAnswerGuard.isStrayAnswer(speech, startedAt: startedAt)
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
        if VoiceModeUtterance.isAwaitedAnswer(utterance, awaitingShortAnswer: isAwaitingShortAnswer) {
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
            let text = keywordCollector.map { VoiceModeSendKeyword.joined($0.pending, segmenter.text) }
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
        return VoiceEchoGuard.shouldDrop(
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
        stopAudio()
        segmenter.reset()
        keywordCollector?.reset()
        await reportSpeakingState()
        await publishDictation()
        await callbacks.failureMessage(message)
    }
}
