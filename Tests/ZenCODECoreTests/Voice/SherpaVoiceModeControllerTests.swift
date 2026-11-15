//
//  SherpaVoiceModeControllerTests.swift
//  ZenCODECoreTests
//
//  Drives the Linux voice controller with shell scripts that mimic the two
//  sherpa-onnx programs, so process handling is verified on every platform
//  without audio hardware.
//

import Foundation
import Testing
@testable import ZenCODECore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Sherpa-onnx voice controller", .serialized)
struct SherpaVoiceModeControllerTests {
    // MARK: - Pure helpers

    @Test
    func longAnswersAreCappedOnACharacterBoundary() {
        let limit = SherpaVoiceModeController.maximumSpokenBytes
        #expect(SherpaVoiceModeController.cappedForArgument("breve") == "breve")
        let capped = SherpaVoiceModeController.cappedForArgument(String(repeating: "è", count: limit))
        #expect(capped.utf8.count <= limit)
        #expect(capped.utf8.count > limit - 2)
        #expect(capped.allSatisfy { $0 == "è" })
    }

    @Test
    func invocationUsesTheSilenceGapAndKeepsAudioOffDisk() throws {
        let voice = try #require(SherpaOnnxVoiceCatalog.voices(forLanguage: "it").first)
        let root = URL(fileURLWithPath: "/opt/voice")
        let paths = SherpaOnnxRuntimePaths(
            recognizerProgram: root.appendingPathComponent("bin/asr"),
            synthesizerProgram: root.appendingPathComponent("bin/tts"),
            voiceActivityModel: root.appendingPathComponent("silero_vad.onnx"),
            encoder: root.appendingPathComponent("p/encoder.int8.onnx"),
            decoder: root.appendingPathComponent("p/decoder.int8.onnx"),
            joiner: root.appendingPathComponent("p/joiner.int8.onnx"),
            recognizerTokens: root.appendingPathComponent("p/tokens.txt"),
            voice: voice,
            voiceModel: root.appendingPathComponent("v/voice.onnx"),
            voiceTokens: root.appendingPathComponent("v/tokens.txt"),
            voiceDataDirectory: root.appendingPathComponent("v/espeak-ng-data")
        )
        let invocation = SherpaVoiceModeController.invocation(for: paths)
        #expect(invocation.recognizerArguments.contains("--silero-vad-min-silence-duration=5"))
        // The pause chosen in zen --setup > Voice mode replaces the default.
        let options = VoiceModeOptions(voice: AgentVoiceSettingsManifest(utteranceSilenceSeconds: 8))
        #expect(
            SherpaVoiceModeController.invocation(
                for: paths,
                utteranceSilenceSeconds: String(options.utteranceSilenceSeconds)
            ).recognizerArguments.contains("--silero-vad-min-silence-duration=8")
        )
        #expect(invocation.recognizerArguments.contains("--silero-vad-max-speech-duration=60"))
        #expect(invocation.recognizerArguments.contains("--model-type=nemo_transducer"))
        #expect(invocation.recognizerArguments.contains("--encoder=/opt/voice/p/encoder.int8.onnx"))
        #expect(invocation.recognizerArguments.last == "default")
        #expect(invocation.synthesizerArguments.contains("--output-filename=/dev/null"))
        #expect(invocation.synthesizerArguments.contains("--vits-data-dir=/opt/voice/v/espeak-ng-data"))
    }

    // MARK: - Process handling

    /// In pause mode an awaited yes or no is sent alone, and the dictation
    /// id advances only with the dictations sent.
    @Test
    func pauseModeSendsAnAwaitedAnswerAloneAndEverySegmentAsADictation() async throws {
        let fixture = try Fixture()
        try fixture.queueUtterances(["sì", "Ciao zen", "Come va"])
        let controller = fixture.makeController()
        await controller.setAwaitingShortAnswer(true)
        await controller.start()

        #expect(await waitUntil {
            await fixture.events.utterances == [
                .answer("sì"),
                .dictation(id: 1, text: "Ciao zen"),
                .dictation(id: 2, text: "Come va")
            ]
        })
        await controller.stop()
        #expect(await fixture.events.previews.isEmpty)
        #expect(await fixture.events.failures.isEmpty)
    }

    /// Keyword mode previews the speech collected for the keyword. A discard
    /// of an older dictation changes nothing; a discard of the current one
    /// forgets its speech without a preview, and the keyword alone then sends
    /// an empty dictation (the typed draft) under the next id.
    @Test
    func keywordModePreviewsCollectedSpeechAndNumbersItsDictations() async throws {
        let fixture = try Fixture()
        try fixture.queueUtterances(["Apri il progetto", "e compila, vai", "Prova"])
        let controller = fixture.makeController(sendKeyword: "vai")
        await controller.start()

        #expect(await waitUntil {
            await fixture.events.previews == [
                Preview(id: 1, text: "Apri il progetto"),
                Preview(id: 2, text: "Prova")
            ]
        })
        #expect(await fixture.events.utterances == [.dictation(id: 1, text: "Apri il progetto e compila")])

        // Stale: dictation 1 was sent already, "Prova" stays collected.
        await controller.discardDictation(through: 1)
        try await fixture.relaunchRecognizer(of: controller, hearing: ["vai"])
        #expect(await waitUntil { await fixture.events.utterances.last == .dictation(id: 2, text: "Prova") })

        try await fixture.relaunchRecognizer(of: controller, hearing: ["Scartato"])
        #expect(await waitUntil { await fixture.events.previews.last == Preview(id: 3, text: "Scartato") })
        await controller.discardDictation(through: 3)
        try await fixture.relaunchRecognizer(of: controller, hearing: ["vai"])
        #expect(await waitUntil { await fixture.events.utterances.last == .dictation(id: 4, text: "") })

        try await fixture.relaunchRecognizer(of: controller, hearing: ["Resto"])
        #expect(await waitUntil { await fixture.events.previews.last == Preview(id: 5, text: "Resto") })
        // Stopping removes the preview.
        await controller.stop()
        #expect(await fixture.events.previews == [
            Preview(id: 1, text: "Apri il progetto"),
            Preview(id: 2, text: "Prova"),
            Preview(id: 3, text: "Scartato"),
            Preview(id: 5, text: "Resto"),
            Preview(id: 5, text: "")
        ])
        #expect(await fixture.events.utterances == [
            .dictation(id: 1, text: "Apri il progetto e compila"),
            .dictation(id: 2, text: "Prova"),
            .dictation(id: 4, text: "")
        ])
        #expect(await fixture.events.failures.isEmpty)
    }

    @Test
    func escapeInterruptsReadingAndTurnsTheMicrophoneBackOn() async throws {
        let fixture = try Fixture(readingSeconds: "30")
        let controller = fixture.makeController()
        await controller.start()
        #expect(await waitUntil { await controller.phase == .listening })

        await controller.speak("Una risposta molto lunga", rendering: .answer)
        #expect(await waitUntil { await fixture.events.speaking == [true] })
        #expect(await controller.isSpeaking)

        let interruptedAt = ContinuousClock.now
        await controller.interruptPlayback()
        #expect(await waitUntil { await fixture.events.speaking == [true, false] })
        #expect(interruptedAt.duration(to: .now) < .seconds(5))
        #expect(await waitUntil { fixture.recognizerLaunches == 2 })
        await controller.stop()
        #expect(await fixture.events.failures.isEmpty)
    }

    @Test
    func pauseStopsListeningAndReadingUntilResumed() async throws {
        let fixture = try Fixture()
        let controller = fixture.makeController()
        await controller.start()
        #expect(await waitUntil { await controller.phase == .listening })

        #expect(await controller.setPaused(true))
        #expect(await controller.setPaused(true) == false)
        #expect(await controller.speak("Non letto", rendering: .answer) == false)
        #expect(await controller.speak("Non letto", rendering: .plainText) == false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.synthesizerCalls.isEmpty)

        #expect(await controller.setPaused(false))
        #expect(await waitUntil { fixture.recognizerLaunches == 2 })
        await controller.stop()
        #expect(await controller.isActive == false)
    }

    @Test
    func aRecognizerThatCannotStartReportsItsLastDiagnostic() async throws {
        let fixture = try Fixture(recognizerFails: true)
        let controller = fixture.makeController()
        await controller.start()

        #expect(await waitUntil { await !fixture.events.failures.isEmpty })
        let failure = try #require(await fixture.events.failures.first)
        #expect(failure.contains("speech recognition could not start: Cannot open device default."))
        #expect(await controller.isActive == false)
    }

    /// The end of a reading is reported before the microphone turns back on,
    /// and the terminal may start another reading in between (the next
    /// live-chat announcement): the microphone must stay off until that one
    /// ends too.
    @Test
    func aReadingStartedAsThePreviousOneEndsKeepsTheMicrophoneOff() async throws {
        // The second reading outlasts the check made while it runs, even on a
        // slow runner where a short one could end and turn the microphone on.
        let fixture = try Fixture(readingSeconds: "0.3", laterReadingSeconds: "3")
        let controller = fixture.makeController()
        await controller.start()
        #expect(await waitUntil { await controller.phase == .listening })
        #expect(fixture.recognizerLaunches == 1)

        let events = fixture.events
        await events.setSpeakingHook { isSpeaking in
            // Only at the end of the first reading.
            guard !isSpeaking, await events.speaking == [true, false] else { return }
            await controller.speak("Seconda", rendering: .plainText)
        }
        #expect(await controller.speak("Prima", rendering: .plainText))
        #expect(await waitUntil { await fixture.events.speaking == [true, false, true] })
        #expect(await controller.isSpeaking)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.recognizerLaunches == 1)

        #expect(await waitUntil { await fixture.events.speaking == [true, false, true, false] })
        #expect(await waitUntil { fixture.recognizerLaunches == 2 })
        #expect(fixture.synthesizerCalls.count == 2)
        await controller.stop()
        #expect(await fixture.events.failures.isEmpty)
    }

    @Test
    func aReadingFailureIsReportedAndListeningResumes() async throws {
        let fixture = try Fixture(synthesizerFails: true)
        let controller = fixture.makeController()
        await controller.start()
        #expect(await waitUntil { await controller.phase == .listening })

        await controller.speak("Ciao", rendering: .answer)
        #expect(await waitUntil { await fixture.events.failures.contains { $0.contains("could not be read aloud: bad model.") } })
        #expect(await waitUntil { await fixture.events.speaking == [true, false] })
        #expect(await waitUntil { fixture.recognizerLaunches == 2 })
        #expect(await controller.isActive)
        await controller.stop()
    }

    /// A failed launch of the next reading ends the one it replaced: the
    /// speaking state is cleared and what the microphone hears is sent.
    @Test
    func aReadingThatCannotLaunchEndsTheReadingItReplaced() async throws {
        let fixture = try Fixture(readingSeconds: "30")
        let controller = fixture.makeController()
        await controller.start()
        #expect(await waitUntil { await controller.phase == .listening })
        #expect(await controller.speak("Prima", rendering: .plainText))
        #expect(await waitUntil { await fixture.events.speaking == [true] })
        // The first reading must be running its program before the program
        // is removed: a shell that has not opened it yet would fail on its
        // own and report a failure of its own.
        #expect(await waitUntil { FileManager.default.fileExists(atPath: fixture.synthesizer.path + ".pid") })

        try FileManager.default.removeItem(at: fixture.synthesizer)
        try fixture.queueUtterance("Ciao zen")
        #expect(await controller.speak("Seconda", rendering: .plainText) == false)
        #expect(await fixture.events.failures.count == 1)
        #expect(await fixture.events.failures.first?.contains("the answer could not be read aloud") == true)
        #expect(await fixture.events.speaking == [true, false])
        #expect(await controller.isSpeaking == false)
        #expect(await waitUntil { await fixture.events.utterances == [.dictation(id: 1, text: "Ciao zen")] })
        #expect(fixture.recognizerLaunches == 2)
        await controller.stop()
    }

    // MARK: - Robustness

    /// A stop that comes while the loading notice is reported leaves the
    /// recognizer unlaunched.
    @Test
    func aStopDuringTheLoadingNoticeLaunchesNoRecognizer() async throws {
        let fixture = try Fixture()
        let controller = fixture.makeController()
        await fixture.events.setSystemHook { _ in
            await controller.stop()
        }
        await controller.start()

        try await Task.sleep(for: .milliseconds(300))
        #expect(await fixture.events.systemMessages == ["Voice: loading the speech recognizer...\n"])
        #expect(fixture.recognizerLaunches == 0)
        #expect(await controller.phase == .stopped)
        #expect(await fixture.events.failures.isEmpty)
    }

    @Test
    func aRecognizerThatNeverStartsFailsAfterTheStartTimeout() async throws {
        let fixture = try Fixture(recognizerNeverStarts: true)
        let controller = fixture.makeController(recognizerStartTimeout: .seconds(2))
        await controller.start()
        #expect(await waitUntil { fixture.recognizerProcessID != nil })
        let processID = try #require(fixture.recognizerProcessID)

        #expect(await waitUntil { await !fixture.events.failures.isEmpty })
        #expect(await fixture.events.failures == [
            "ZenCODE: speech recognition could not start: no answer from the recognizer after 2 seconds. Run /voice on to retry.\n"
        ])
        #expect(await controller.isActive == false)
        #expect(await fixture.events.listening == [false])
        #expect(await waitUntil { !isProcessRunning(processID) })
        #expect(fixture.recognizerLaunches == 1)
    }

    /// The start timeout holds for every launch, also the one that turns
    /// the microphone back on after a reading.
    @Test
    func aRecognizerRelaunchedAfterAReadingIsTimedToo() async throws {
        let fixture = try Fixture()
        let controller = fixture.makeController(recognizerStartTimeout: .seconds(2))
        await controller.start()
        #expect(await waitUntil { await controller.phase == .listening })

        try fixture.silenceRecognizer()
        #expect(await controller.speak("Ok", rendering: .plainText))
        #expect(await waitUntil { fixture.recognizerLaunches == 2 })
        #expect(await waitUntil { await !fixture.events.failures.isEmpty })
        #expect(await fixture.events.failures == [
            "ZenCODE: speech recognition could not start: no answer from the recognizer after 2 seconds. Run /voice on to retry.\n"
        ])
        #expect(await controller.isActive == false)
    }

    /// `false` while the recognizer loads, `true` once it printed `Started`,
    /// `false` again while a reading or a pause turns the microphone off.
    @Test
    func listeningIsReportedFromStartedUntilTheMicrophoneTurnsOff() async throws {
        let fixture = try Fixture()
        let controller = fixture.makeController(recognizerStartTimeout: .seconds(1))
        await controller.start()
        #expect(await waitUntil { await fixture.events.listening == [false, true] })
        #expect(await controller.phase == .listening)
        // `Started` ended the start timeout.
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(await controller.isActive)
        #expect(await fixture.events.failures.isEmpty)

        #expect(await controller.speak("Ok", rendering: .plainText))
        #expect(await waitUntil { await fixture.events.listening == [false, true, false] })
        // The recognizer loads again after the reading, then listens.
        #expect(await waitUntil { await fixture.events.speaking == [true, false] })
        #expect(await waitUntil { await fixture.events.listening == [false, true, false, true] })
        #expect(fixture.recognizerLaunches == 2)

        #expect(await controller.setPaused(true))
        #expect(await waitUntil { await fixture.events.listening == [false, true, false, true, false] })
        #expect(await controller.setPaused(false))
        #expect(await waitUntil { await fixture.events.listening == [false, true, false, true, false, true] })
        await controller.stop()
        #expect(await waitUntil { await fixture.events.listening == [false, true, false, true, false, true, false] })
        #expect(await fixture.events.failures.isEmpty)
    }

    @Test
    func stopWaitsForARecognizerThatIgnoresSIGTERM() async throws {
        let fixture = try Fixture(recognizerIgnoresTermination: true)
        let controller = fixture.makeController()
        await controller.start()
        #expect(await waitUntil { await controller.phase == .listening })
        let processID = try #require(fixture.recognizerProcessID)
        #expect(isProcessRunning(processID))

        let stoppedAt = ContinuousClock.now
        await controller.stop()
        #expect(!isProcessRunning(processID))
        #expect(stoppedAt.duration(to: .now) < .seconds(5))
        #expect(await controller.isActive == false)
    }

    /// The fake synthesizer always ignores SIGTERM.
    @Test
    func stopWaitsForAReadingThatIgnoresSIGTERM() async throws {
        let fixture = try Fixture(readingSeconds: "30")
        let controller = fixture.makeController()
        await controller.start()
        #expect(await waitUntil { await controller.phase == .listening })
        #expect(await controller.speak("Una risposta molto lunga", rendering: .answer))
        #expect(await waitUntil { fixture.synthesizerProcessID != nil })
        let processID = try #require(fixture.synthesizerProcessID)
        #expect(isProcessRunning(processID))

        await controller.stop()
        #expect(!isProcessRunning(processID))
        #expect(await fixture.events.speaking == [true, false])
    }

    // MARK: - Support

    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }
}

/// Whether `processID` still runs. A child that exited but was not reaped
/// yet (a zombie) no longer runs; on Linux `/proc` tells it apart.
private func isProcessRunning(_ processID: pid_t) -> Bool {
    guard kill(processID, 0) == 0 else {
        return false
    }
    #if os(Linux)
    if let status = try? String(contentsOfFile: "/proc/\(processID)/status", encoding: .utf8),
       let state = status.split(separator: "\n").first(where: { $0.hasPrefix("State:") }) {
        let fields = state.split(whereSeparator: { $0.isWhitespace })
        return fields.count < 2 || !["Z", "X", "x"].contains(fields[1])
    }
    #endif
    return true
}

private struct Preview: Sendable, Equatable {
    let id: UInt64
    let text: String
}

private actor VoiceEventRecorder {
    var systemMessages: [String] = []
    var failures: [String] = []
    var utterances: [VoiceModeUtterance] = []
    var previews: [Preview] = []
    var speaking: [Bool] = []
    var listening: [Bool] = []
    private var speakingHook: (@Sendable (Bool) async -> Void)?
    private var systemHook: (@Sendable (String) async -> Void)?

    func system(_ text: String) async {
        systemMessages.append(text)
        await systemHook?(text)
    }

    func failure(_ text: String) { failures.append(text) }
    func utterance(_ utterance: VoiceModeUtterance) { utterances.append(utterance) }
    func preview(_ id: UInt64, _ text: String) { previews.append(Preview(id: id, text: text)) }
    func listeningChanged(_ value: Bool) { listening.append(value) }

    func speakingChanged(_ value: Bool) async {
        speaking.append(value)
        await speakingHook?(value)
    }

    /// Runs inside the controller's `speakingChanged` callback, i.e. while
    /// the controller is suspended reporting the change.
    func setSpeakingHook(_ hook: @escaping @Sendable (Bool) async -> Void) {
        speakingHook = hook
    }

    /// Runs inside the controller's `systemMessage` callback.
    func setSystemHook(_ hook: @escaping @Sendable (String) async -> Void) {
        systemHook = hook
    }
}

/// Two fake programs in a private directory. Each logs its launches and
/// writes its process id; the recognizer prints sherpa-onnx style startup
/// lines and an optional queued utterance, the synthesizer logs its
/// arguments and "reads" for a while.
private struct Fixture {
    let directory: URL
    let events = VoiceEventRecorder()

    var recognizer: URL { directory.appendingPathComponent("asr.sh") }
    var synthesizer: URL { directory.appendingPathComponent("tts.sh") }

    /// `readingSeconds` is the length of the first reading and, unless
    /// `laterReadingSeconds` is given, of every later one.
    init(
        readingSeconds: String = "0.2",
        laterReadingSeconds: String? = nil,
        recognizerFails: Bool = false,
        recognizerNeverStarts: Bool = false,
        recognizerIgnoresTermination: Bool = false,
        synthesizerFails: Bool = false
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-sherpa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(
            """
            #!/bin/sh
            echo launch >> "$0.log"
            # Like a child of the TUI, ignore SIGTERM when asked; the process id
            # is written after, so a test that reads it stops a program that
            # ignores SIGTERM already.
            if [ -f "$0.ignore-term" ]; then trap '' TERM; fi
            echo $$ > "$0.pid"
            echo "VadModelConfig(silero_vad=SileroVadModelConfig(min_silence_duration=2.5))" >&2
            echo " 1: a configuration line before startup is not a result" >&2
            if [ -f "$0.fail" ]; then echo "Cannot open device default" >&2; exit 1; fi
            # A recognizer stuck loading never prints the startup line.
            if [ -f "$0.silent" ]; then exec sleep 30; fi
            echo "Started. Please speak" >&2
            # Take the queue before printing it: the test queues the next
            # launch's speech as soon as it sees this one's, and a late removal
            # would delete it.
            if [ -f "$0.utterance" ]; then mv -f "$0.utterance" "$0.heard"; while IFS= read -r line; do echo " 0: $line" >&2; done < "$0.heard"; fi
            exec sleep 30
            """,
            to: recognizer
        )
        try write(
            """
            #!/bin/sh
            printf '%s|' "$@" >> "$0.log"; printf '\\n' >> "$0.log"
            echo "Generating..." >&2
            if [ -f "$0.fail" ]; then echo "bad model" >&2; exit 3; fi
            # Like a child of the TUI, ignore SIGTERM: stopping must escalate.
            trap '' TERM
            echo $$ > "$0.pid"
            if [ "$(grep -c '' "$0.log")" -gt 1 ]; then exec sleep \(laterReadingSeconds ?? readingSeconds); fi
            exec sleep \(readingSeconds)
            """,
            to: synthesizer
        )
        if recognizerFails {
            try Data().write(to: URL(fileURLWithPath: recognizer.path + ".fail"))
        }
        if recognizerNeverStarts {
            try silenceRecognizer()
        }
        if recognizerIgnoresTermination {
            try Data().write(to: URL(fileURLWithPath: recognizer.path + ".ignore-term"))
        }
        if synthesizerFails {
            try Data().write(to: URL(fileURLWithPath: synthesizer.path + ".fail"))
        }
    }

    func makeController(
        sendKeyword: String? = nil,
        recognizerStartTimeout: Duration = SherpaVoiceModeController.defaultRecognizerStartTimeout
    ) -> SherpaVoiceModeController {
        let events = events
        return SherpaVoiceModeController(
            invocation: .init(
                recognizerProgram: recognizer,
                recognizerArguments: ["default"],
                synthesizerProgram: synthesizer,
                synthesizerArguments: ["--output-filename=/dev/null"]
            ),
            voiceName: "paola (it_IT)",
            languageCode: "it",
            sendKeyword: sendKeyword.flatMap(VoiceModeSendKeyword.init),
            recognizerStartTimeout: recognizerStartTimeout,
            callbacks: VoiceModeCallbacks(
                systemMessage: { await events.system($0) },
                failureMessage: { await events.failure($0) },
                utteranceRecognized: { await events.utterance($0) },
                dictationChanged: { await events.preview($0, $1) },
                speakingChanged: { await events.speakingChanged($0) },
                listeningChanged: { await events.listeningChanged($0) }
            )
        )
    }

    /// The next recognizer launches never print the startup line.
    func silenceRecognizer() throws {
        try Data().write(to: URL(fileURLWithPath: recognizer.path + ".silent"))
    }

    func queueUtterance(_ text: String) throws {
        try queueUtterances([text])
    }

    /// Segments the next recognizer launch prints, one per line.
    func queueUtterances(_ texts: [String]) throws {
        let lines = texts.map { $0 + "\n" }.joined()
        try Data(lines.utf8).write(to: URL(fileURLWithPath: recognizer.path + ".utterance"))
    }

    /// Makes the recognizer print `texts`: a short reading turns the
    /// microphone off and launches a new recognizer when it ends, without
    /// touching the speech collected for the keyword (pausing would).
    func relaunchRecognizer(of controller: SherpaVoiceModeController, hearing texts: [String]) async throws {
        let launches = recognizerLaunches
        try queueUtterances(texts)
        #expect(await controller.speak("Ok", rendering: .plainText))
        let deadline = ContinuousClock.now + .seconds(10)
        while recognizerLaunches == launches, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(recognizerLaunches == launches + 1)
    }

    var recognizerLaunches: Int {
        logLines(of: recognizer).count
    }

    var synthesizerCalls: [String] {
        logLines(of: synthesizer)
    }

    /// The process id of the last recognizer launched, once it is written.
    var recognizerProcessID: pid_t? {
        processID(of: recognizer)
    }

    /// The process id of the last reading, once it ignores SIGTERM.
    var synthesizerProcessID: pid_t? {
        processID(of: synthesizer)
    }

    private func processID(of program: URL) -> pid_t? {
        let text = (try? String(contentsOfFile: program.path + ".pid", encoding: .utf8)) ?? ""
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func logLines(of program: URL) -> [String] {
        let log = (try? String(contentsOfFile: program.path + ".log", encoding: .utf8)) ?? ""
        return log.split(separator: "\n").map(String.init)
    }

    private func write(_ script: String, to url: URL) throws {
        try Data((script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
