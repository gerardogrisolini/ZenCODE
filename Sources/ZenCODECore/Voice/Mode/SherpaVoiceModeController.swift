//
//  SherpaVoiceModeController.swift
//  ZenCODE
//
//  Linux voice mode. Speech recognition and spoken answers run as the
//  downloaded sherpa-onnx command-line programs, never inside ZenCODE:
//  `sherpa-onnx-vad-alsa-offline-asr` listens on the default ALSA device and
//  prints one line per utterance after a silence gap, and
//  `sherpa-onnx-offline-tts-play-alsa` reads an answer aloud and exits.
//
//  Without built-in echo cancellation the microphone is off while an answer
//  is read: the recognizer is stopped before reading starts and relaunched
//  when the reading ends or `Esc` interrupts it. Audio never touches the disk.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One running external program. Standard output is discarded; standard
/// error is read on a dedicated thread and delivered as ordered lines,
/// followed by exactly one exit event once the program ended and its output
/// was drained.
final class VoiceModeProcess: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case line(String)
        case exited(status: Int32, signaled: Bool)
    }

    static let maximumLineBytes = 8 * 1_024

    let events: AsyncStream<Event>
    private let process: Process

    /// Joins the end of standard error with the process exit, so the exit
    /// event always follows every line.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: AsyncStream<Event>.Continuation
        private var readerFinished = false
        private var exit: Event?

        init(continuation: AsyncStream<Event>.Continuation) {
            self.continuation = continuation
        }

        func line(_ text: String) {
            continuation.yield(.line(text))
        }

        func finishReading() {
            let exit = lock.withLock { () -> Event? in
                readerFinished = true
                return self.exit
            }
            finishIfComplete(exit)
        }

        func processExited(_ event: Event) {
            let readerFinished = lock.withLock { () -> Bool in
                exit = event
                return self.readerFinished
            }
            if readerFinished {
                finishIfComplete(event)
            }
        }

        private func finishIfComplete(_ exit: Event?) {
            guard let exit else {
                return
            }
            continuation.yield(exit)
            continuation.finish()
        }
    }

    private final class ReadEnd: @unchecked Sendable {
        let handle: FileHandle

        init(handle: FileHandle) {
            self.handle = handle
        }
    }

    init(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        let (events, continuation) = AsyncStream.makeStream(
            of: Event.self,
            bufferingPolicy: .bufferingNewest(1_024)
        )
        let completion = Completion(continuation: continuation)
        process.terminationHandler = { finished in
            completion.processExited(.exited(
                status: finished.terminationStatus,
                signaled: finished.terminationReason == .uncaughtSignal
            ))
        }
        try process.run()

        let descriptor = errorPipe.fileHandleForReading.fileDescriptor
        // The reader thread owns the read end until EOF, so the descriptor
        // cannot be closed (and its number reused by the next program) while
        // it is still being read.
        let readEnd = ReadEnd(handle: errorPipe.fileHandleForReading)
        let reader = Thread {
            // `read(2)` returns whatever is available; FileHandle's
            // `read(upToCount:)` would wait for a full buffer or EOF and hold
            // back every utterance of a long-running recognizer.
            var buffer = [UInt8](repeating: 0, count: 4_096)
            var pending = Data()
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in
                    read(descriptor, raw.baseAddress, raw.count)
                }
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    break
                }
                pending.append(contentsOf: buffer[0..<count])
                while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineData = pending[pending.startIndex..<index]
                    pending = Data(pending[pending.index(after: index)...])
                    if !lineData.isEmpty {
                        completion.line(String(decoding: lineData, as: UTF8.self))
                    }
                }
                if pending.count > Self.maximumLineBytes {
                    completion.line(String(decoding: pending.prefix(Self.maximumLineBytes), as: UTF8.self))
                    pending.removeAll()
                }
            }
            if !pending.isEmpty {
                completion.line(String(decoding: pending, as: UTF8.self))
            }
            try? readEnd.handle.close()
            completion.finishReading()
        }
        reader.stackSize = 256 * 1_024
        reader.start()

        self.process = process
        self.events = events
    }

    /// Grace after SIGTERM before SIGKILL.
    static let terminationGrace = Duration.milliseconds(300)
    /// How long ``terminateAndWait()`` still waits for the exit after
    /// SIGKILL; with the grace, about a second in all.
    static let killedExitWait = Duration.milliseconds(700)
    private static let exitPollInterval = Duration.milliseconds(10)

    /// SIGTERM, then SIGKILL when the program is still running after a short
    /// grace: a child can inherit an ignored SIGTERM from the terminal's
    /// signal handling. The exit event still follows.
    func terminate() {
        guard process.isRunning else {
            return
        }
        process.terminate()
        Task(name: "ZenCODE.sherpa-voice-kill") { [self] in
            try? await Task.sleep(for: Self.terminationGrace)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// Like ``terminate()``, but returns once the program ended, or after
    /// about a second: ZenCODE may exit right after, and a program still
    /// waiting for its SIGKILL would outlive it with the microphone or the
    /// speaker open. The exit event still follows.
    func terminateAndWait() async {
        guard process.isRunning else {
            return
        }
        process.terminate()
        if await waitForExit(within: Self.terminationGrace) {
            return
        }
        kill(process.processIdentifier, SIGKILL)
        _ = await waitForExit(within: Self.killedExitWait)
    }

    /// Whether the program ended within `limit`. A cancelled wait ends at
    /// once, so a cancelled stop sends SIGKILL without the grace.
    private func waitForExit(within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while process.isRunning {
            guard ContinuousClock.now < deadline else {
                return false
            }
            do {
                try await Task.sleep(for: Self.exitPollInterval)
            } catch {
                return !process.isRunning
            }
        }
        return true
    }
}

actor SherpaVoiceModeController: VoiceModeController {
    /// Program paths and arguments; the answer text is appended after `--`.
    struct Invocation: Sendable, Equatable {
        let recognizerProgram: URL
        let recognizerArguments: [String]
        let synthesizerProgram: URL
        let synthesizerArguments: [String]
    }

    enum Phase: Sendable, Equatable {
        case idle
        case starting
        case listening
        case failed
        case stopped
    }

    /// Default silence that ends an utterance; matches the macOS dictation
    /// segmenter. `zen --setup` > Voice mode can change it.
    static let utteranceSilenceSeconds = "5"
    /// Long dictation stays one utterance instead of the 20 s default.
    static let maximumUtteranceSeconds = "60"
    /// Linux limits one argument to 128 KiB; longer answers are truncated.
    static let maximumSpokenBytes = 100_000
    static let maximumRapidRecognizerExits = 3
    static let rapidExitWindow = Duration.seconds(5)
    static let diagnosticLineCount = 40
    static let recognizerStartedPrefix = "Started"
    /// How long a launched recognizer may load before it prints `Started`.
    static let defaultRecognizerStartTimeout = Duration.seconds(60)

    static func listeningMessage(voice: String) -> String {
        "Voice: listening (sherpa-onnx, voice \(voice)). Speak or type; answers are read aloud with the microphone off, Esc stops reading. /voice pauses or resumes, /voice off stops.\n"
    }

    static func invocation(
        for paths: SherpaOnnxRuntimePaths,
        utteranceSilenceSeconds: String = utteranceSilenceSeconds
    ) -> Invocation {
        Invocation(
            recognizerProgram: paths.recognizerProgram,
            recognizerArguments: [
                "--silero-vad-model=\(paths.voiceActivityModel.path)",
                "--silero-vad-min-silence-duration=\(utteranceSilenceSeconds)",
                "--silero-vad-max-speech-duration=\(maximumUtteranceSeconds)",
                "--encoder=\(paths.encoder.path)",
                "--decoder=\(paths.decoder.path)",
                "--joiner=\(paths.joiner.path)",
                "--tokens=\(paths.recognizerTokens.path)",
                "--model-type=nemo_transducer",
                "default"
            ],
            synthesizerProgram: paths.synthesizerProgram,
            synthesizerArguments: [
                "--vits-model=\(paths.voiceModel.path)",
                "--vits-tokens=\(paths.voiceTokens.path)",
                "--vits-data-dir=\(paths.voiceDataDirectory.path)",
                // The program always writes a WAV file; keep audio off disk.
                "--output-filename=/dev/null"
            ]
        )
    }

    /// The text of a recognizer result line (`"%2d: %s"`), or `nil`.
    static func recognizedText(fromLine line: String) -> String? {
        let trimmed = line.drop { $0 == " " }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else {
            return nil
        }
        let rest = trimmed.dropFirst(digits.count)
        guard rest.first == ":" else {
            return nil
        }
        let text = rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Caps `text` at `maximumSpokenBytes` UTF-8 bytes on a character
    /// boundary.
    static func cappedForArgument(_ text: String) -> String {
        guard text.utf8.count > maximumSpokenBytes else {
            return text
        }
        var result = ""
        var bytes = 0
        for character in text {
            let size = character.utf8.count
            guard bytes + size <= maximumSpokenBytes else {
                break
            }
            result.append(character)
            bytes += size
        }
        return result
    }

    private let invocation: Invocation
    private let voiceName: String
    private let recognizerStartTimeout: Duration
    nonisolated let languageCode: String
    /// Set in keyword send mode: speech waiting for the keyword.
    private var keywordCollector: VoiceKeywordCollector?
    /// The live-chat dialogue awaits a yes or no.
    private var isAwaitingShortAnswer = false
    /// The dictation previewed in the prompt draft (keyword mode only).
    /// Advances after every dictation sent and every discard, so the
    /// terminal ignores previews and sends of a dictation it already ended.
    private var dictationID: UInt64 = 1
    /// The preview last reported for `dictationID`.
    private var publishedDictation = ""
    /// A preview is being reported. Reports run one at a time, so they reach
    /// the terminal in order; the one in flight reports the latest text.
    private var isPublishingDictation = false
    private let callbacks: VoiceModeCallbacks

    private(set) var phase: Phase = .idle
    private(set) var isPaused = false
    private(set) var isSpeaking = false

    private var recognizer: VoiceModeProcess?
    private var recognizerGeneration: UInt64 = 0
    private var recognizerStarted = false
    private var recognizerLaunchedAt = ContinuousClock.now
    private var rapidRecognizerExits = 0
    private var recognizerDiagnostics: [String] = []
    /// Fails voice mode when the running recognizer does not print
    /// `Started` within `recognizerStartTimeout`.
    private var recognizerStartDeadline: Task<Void, Never>?
    /// The value last reported with `listeningChanged`; `nil` until the
    /// first report, so the first one is never skipped.
    private var publishedListening: Bool?
    /// A listening change is being reported; see `publishListening()`.
    private var isPublishingListening = false

    private var synthesizer: VoiceModeProcess?
    private var synthesizerGeneration: UInt64 = 0
    private var synthesizerStopRequested = false
    private var synthesizerDiagnostics: [String] = []

    init(
        paths: SherpaOnnxRuntimePaths,
        options: VoiceModeOptions = VoiceModeOptions(),
        callbacks: VoiceModeCallbacks
    ) {
        self.init(
            invocation: Self.invocation(
                for: paths,
                utteranceSilenceSeconds: String(options.recognizerSilenceSeconds)
            ),
            voiceName: "\(paths.voice.speaker) (\(paths.voice.locale))",
            languageCode: paths.voice.languageCode,
            sendKeyword: options.sendKeyword,
            callbacks: callbacks
        )
    }

    init(
        invocation: Invocation,
        voiceName: String,
        languageCode: String,
        sendKeyword: VoiceModeSendKeyword? = nil,
        recognizerStartTimeout: Duration = SherpaVoiceModeController.defaultRecognizerStartTimeout,
        callbacks: VoiceModeCallbacks
    ) {
        self.invocation = invocation
        self.voiceName = voiceName
        self.recognizerStartTimeout = recognizerStartTimeout
        self.languageCode = languageCode
        self.keywordCollector = sendKeyword.map(VoiceKeywordCollector.init)
        self.callbacks = callbacks
    }

    var isActive: Bool {
        switch phase {
        case .idle, .starting, .listening:
            return true
        case .failed, .stopped:
            return false
        }
    }

    func start() async {
        guard phase == .idle || phase == .failed else {
            return
        }
        phase = .starting
        rapidRecognizerExits = 0
        await callbacks.systemMessage("Voice: loading the speech recognizer...\n")
        // A stop or a pause may have come while the notice was reported.
        guard phase == .starting, !isPaused else {
            return
        }
        await startRecognizer()
    }

    func stop() async {
        phase = .stopped
        let running = [retireRecognizer(), retireSynthesizer()].compactMap { $0 }
        keywordCollector?.reset()
        // ZenCODE may exit right after: wait until both programs ended, or a
        // child that ignores SIGTERM would outlive it with the microphone open.
        await withTaskGroup(of: Void.self) { group in
            for process in running {
                group.addTask {
                    await process.terminateAndWait()
                }
            }
        }
        await setSpeaking(false)
        await publishDictation()
        await publishListening()
    }

    /// Reads an answer or a plain text aloud with the microphone off. Returns
    /// `false` when nothing was started.
    @discardableResult
    func speak(_ text: String, rendering: VoiceModeSpeechRendering) async -> Bool {
        guard phase == .listening, !isPaused else {
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
        let capped = Self.cappedForArgument(spoken)
        guard !capped.isEmpty else {
            return false
        }
        // The microphone is off while the answer is read.
        stopRecognizer()
        stopSynthesizer()
        synthesizerGeneration &+= 1
        let generation = synthesizerGeneration
        synthesizerStopRequested = false
        synthesizerDiagnostics = []
        do {
            let process = try VoiceModeProcess(
                executable: invocation.synthesizerProgram,
                arguments: invocation.synthesizerArguments + ["--", capped]
            )
            synthesizer = process
            observe(process) { controller, event in
                await controller.handleSynthesizer(event, generation: generation)
            }
            await setSpeaking(true)
            await publishListening()
            return true
        } catch {
            await callbacks.failureMessage(
                "ZenCODE: the answer could not be read aloud: \(error.localizedDescription)\n"
            )
            // Reporting the failure suspends this actor: a stop, a pause or
            // another reading may have come meanwhile, and then owns the
            // speaking state and the microphone. Otherwise the reading this
            // one replaced is over, and its exit is no longer reported.
            if generation == synthesizerGeneration {
                await setSpeaking(false)
            }
            if generation == synthesizerGeneration, phase == .listening, !isPaused {
                await startRecognizer()
            }
            await publishListening()
            return false
        }
    }

    func interruptPlayback() async {
        guard let synthesizer else {
            return
        }
        synthesizerStopRequested = true
        // The exit event ends the reading and turns the microphone back on.
        synthesizer.terminate()
    }

    @discardableResult
    func setPaused(_ paused: Bool) async -> Bool {
        guard paused != isPaused else {
            return false
        }
        isPaused = paused
        if paused {
            keywordCollector?.reset()
            stopRecognizer()
            stopSynthesizer()
            await setSpeaking(false)
            await publishDictation()
            await publishListening()
        } else if phase == .starting || phase == .listening {
            rapidRecognizerExits = 0
            await startRecognizer()
        }
        return true
    }

    func setAwaitingShortAnswer(_ awaiting: Bool) {
        isAwaitingShortAnswer = awaiting
    }

    /// A segment already being recognized still arrives, as the start of
    /// the next dictation.
    func discardDictation(through id: UInt64) async {
        guard id >= dictationID else {
            return
        }
        keywordCollector?.reset()
        dictationID = id &+ 1
        publishedDictation = ""
    }

    // MARK: - Recognizer

    private func startRecognizer() async {
        guard recognizer == nil else {
            return
        }
        recognizerGeneration &+= 1
        let generation = recognizerGeneration
        recognizerStarted = false
        recognizerDiagnostics = []
        recognizerLaunchedAt = .now
        do {
            let process = try VoiceModeProcess(
                executable: invocation.recognizerProgram,
                arguments: invocation.recognizerArguments
            )
            recognizer = process
            observe(process) { controller, event in
                await controller.handleRecognizer(event, generation: generation)
            }
            scheduleRecognizerStartDeadline(generation: generation)
        } catch {
            await fail("ZenCODE: speech recognition could not start: \(error.localizedDescription) Run /voice on to retry.\n")
            return
        }
        // Loading the models: the microphone is not heard yet.
        await publishListening()
    }

    /// Retires and stops the running recognizer; its late events are
    /// ignored.
    private func stopRecognizer() {
        retireRecognizer()?.terminate()
    }

    /// Retires the running recognizer without stopping it; its late events
    /// are ignored.
    private func retireRecognizer() -> VoiceModeProcess? {
        recognizerGeneration &+= 1
        cancelRecognizerStartDeadline()
        defer {
            recognizer = nil
        }
        return recognizer
    }

    /// A recognizer that never prints `Started` would leave voice mode deaf
    /// and mute for good.
    private func scheduleRecognizerStartDeadline(generation: UInt64) {
        cancelRecognizerStartDeadline()
        let timeout = recognizerStartTimeout
        recognizerStartDeadline = Task(name: "ZenCODE.sherpa-voice-start-deadline") { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.recognizerStartTimedOut(generation: generation)
        }
    }

    private func cancelRecognizerStartDeadline() {
        recognizerStartDeadline?.cancel()
        recognizerStartDeadline = nil
    }

    private func recognizerStartTimedOut(generation: UInt64) async {
        guard generation == recognizerGeneration, recognizer != nil, !recognizerStarted else {
            return
        }
        recognizerStartDeadline = nil
        let seconds = recognizerStartTimeout.components.seconds
        await fail("ZenCODE: speech recognition could not start: no answer from the recognizer after \(seconds) seconds. Run /voice on to retry.\n")
    }

    private func handleRecognizer(_ event: VoiceModeProcess.Event, generation: UInt64) async {
        guard generation == recognizerGeneration else {
            return
        }
        switch event {
        case let .line(line):
            guard recognizerStarted else {
                appendDiagnostic(line, to: &recognizerDiagnostics)
                if line.hasPrefix(Self.recognizerStartedPrefix) {
                    recognizerStarted = true
                    cancelRecognizerStartDeadline()
                    if phase == .starting {
                        phase = .listening
                        await callbacks.systemMessage(Self.listeningMessage(voice: voiceName))
                    }
                    await publishListening()
                }
                return
            }
            if let text = Self.recognizedText(fromLine: line) {
                guard phase == .listening, !isPaused, !isSpeaking else {
                    return
                }
                if keywordCollector != nil {
                    // Keyword mode: segments wait, previewed in the draft,
                    // until one ends with the keyword.
                    switch keywordCollector!.receive(text, awaitingShortAnswer: isAwaitingShortAnswer) {
                    case let .send(utterance):
                        await sendDictation(utterance)
                    case let .answer(answer):
                        await callbacks.utteranceRecognized(.answer(answer))
                    case .collected, .nothing:
                        await publishDictation()
                    }
                } else if VoiceModeUtterance.isAwaitedAnswer(text, awaitingShortAnswer: isAwaitingShortAnswer) {
                    await callbacks.utteranceRecognized(.answer(text))
                } else {
                    // Pause mode: every segment is sent at once, with the
                    // typed draft.
                    await sendDictation(text)
                }
            } else {
                appendDiagnostic(line, to: &recognizerDiagnostics)
            }

        case let .exited(status, _):
            recognizer = nil
            cancelRecognizerStartDeadline()
            // Every path below reports that the microphone is not heard, after
            // the decision: an await before it would let a relaunch change
            // the state it reads.
            guard phase == .starting || phase == .listening, !isPaused, !isSpeaking else {
                await publishListening()
                return
            }
            let reason = Self.reason(status: status, diagnostics: recognizerDiagnostics)
            guard recognizerStarted else {
                await fail("ZenCODE: speech recognition could not start: \(reason) Run /voice on to retry.\n")
                return
            }
            if recognizerLaunchedAt.duration(to: .now) < Self.rapidExitWindow {
                rapidRecognizerExits += 1
            } else {
                rapidRecognizerExits = 0
            }
            guard rapidRecognizerExits < Self.maximumRapidRecognizerExits else {
                await fail("ZenCODE: speech recognition stopped repeatedly: \(reason) Run /voice on to retry.\n")
                return
            }
            await startRecognizer()
        }
    }

    // MARK: - Synthesizer

    /// Retires and stops the running synthesizer without turning the
    /// microphone on.
    private func stopSynthesizer() {
        retireSynthesizer()?.terminate()
    }

    /// Retires the running synthesizer without stopping it; its late events
    /// are ignored.
    private func retireSynthesizer() -> VoiceModeProcess? {
        synthesizerGeneration &+= 1
        defer {
            synthesizer = nil
        }
        return synthesizer
    }

    private func handleSynthesizer(_ event: VoiceModeProcess.Event, generation: UInt64) async {
        guard generation == synthesizerGeneration else {
            return
        }
        switch event {
        case let .line(line):
            appendDiagnostic(line, to: &synthesizerDiagnostics)
        case let .exited(status, _):
            synthesizer = nil
            if status != 0, !synthesizerStopRequested {
                let reason = Self.reason(status: status, diagnostics: synthesizerDiagnostics)
                await callbacks.failureMessage("ZenCODE: the answer could not be read aloud: \(reason)\n")
            }
            // Reporting the failure or the end of the reading suspends this
            // actor, and the terminal may start another reading meanwhile:
            // that reading then owns the speaking state and the microphone.
            guard generation == synthesizerGeneration else {
                return
            }
            await setSpeaking(false)
            guard generation == synthesizerGeneration, phase == .listening, !isPaused else {
                return
            }
            await startRecognizer()
        }
    }

    // MARK: - Support

    /// Sends the final words of the current dictation; the terminal sends
    /// them after the typed draft.
    private func sendDictation(_ text: String) async {
        let id = dictationID
        await callbacks.utteranceRecognized(.dictation(id: id, text: text))
        // A discard may have advanced the id while the send was delivered.
        dictationID = max(dictationID, id &+ 1)
        publishedDictation = ""
        await publishDictation()
    }

    /// Reports the speech collected for the keyword, previewed at the end of
    /// the prompt draft. Pause mode sends every segment at once and shows
    /// nothing. Only changes are reported.
    private func publishDictation() async {
        guard !isPublishingDictation else {
            return
        }
        isPublishingDictation = true
        defer {
            isPublishingDictation = false
        }
        while true {
            let text = keywordCollector?.pending ?? ""
            guard text != publishedDictation else {
                return
            }
            publishedDictation = text
            await callbacks.dictationChanged(dictationID, text)
        }
    }

    private func setSpeaking(_ speaking: Bool) async {
        guard speaking != isSpeaking else {
            return
        }
        isSpeaking = speaking
        await callbacks.speakingChanged(speaking)
    }

    /// The recognizer runs and printed `Started`: it hears the microphone.
    private var hearsMicrophone: Bool {
        recognizer != nil && recognizerStarted
    }

    /// Reports whether the recognizer hears the microphone: `false` while it
    /// loads and while it is stopped (reading, pause, stop, failure) or has
    /// exited. Only changes are reported, except the first value. Reports
    /// run one at a time, so they reach the session in order; the one in
    /// flight reports the latest state.
    private func publishListening() async {
        guard !isPublishingListening else {
            return
        }
        isPublishingListening = true
        defer {
            isPublishingListening = false
        }
        while true {
            let listening = hearsMicrophone
            guard listening != publishedListening else {
                return
            }
            publishedListening = listening
            await callbacks.listeningChanged(listening)
        }
    }

    private func observe(
        _ process: VoiceModeProcess,
        handler: @escaping @Sendable (SherpaVoiceModeController, VoiceModeProcess.Event) async -> Void
    ) {
        let events = process.events
        Task(name: "ZenCODE.sherpa-voice-events") { [weak self] in
            for await event in events {
                guard let self else {
                    return
                }
                await handler(self, event)
            }
        }
    }

    private func appendDiagnostic(_ line: String, to diagnostics: inout [String]) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return
        }
        diagnostics.append(trimmed)
        if diagnostics.count > Self.diagnosticLineCount {
            diagnostics.removeFirst(diagnostics.count - Self.diagnosticLineCount)
        }
    }

    /// The most recent error-like diagnostic, else the last one, else the
    /// exit status. sherpa-onnx follows an ALSA failure with usage hints, so
    /// the last line alone is rarely the cause.
    static func reason(status: Int32, diagnostics: [String]) -> String {
        let markers = ["unable", "error", "fail", "cannot", "can't", "no such", "not found", "invalid"]
        let informative = diagnostics.last { line in
            let lowercased = line.lowercased()
            return markers.contains { lowercased.contains($0) }
        }
        if let line = informative ?? diagnostics.last {
            let shown = line.count > 300 ? String(line.prefix(300)) + "…" : line
            return shown.hasSuffix(".") ? shown : shown + "."
        }
        return "the program exited with status \(status)."
    }

    private func fail(_ message: String) async {
        phase = .failed
        stopRecognizer()
        stopSynthesizer()
        keywordCollector?.reset()
        await setSpeaking(false)
        await publishDictation()
        await publishListening()
        await callbacks.failureMessage(message)
    }
}
