//
//  TerminalSherpaVoiceControllerTests.swift
//  ZenCODECoreTests
//
//  Drives the Linux voice controller with shell scripts that mimic the two
//  sherpa-onnx programs, so process handling is verified on every platform
//  without audio hardware.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Sherpa-onnx voice controller")
struct TerminalSherpaVoiceControllerTests {
    // MARK: - Pure helpers

    @Test
    func recognizerResultLinesAreParsed() {
        #expect(TerminalSherpaVoiceController.recognizedText(fromLine: " 0: Ciao zen") == "Ciao zen")
        #expect(TerminalSherpaVoiceController.recognizedText(fromLine: "12: Che ore sono?") == "Che ore sono?")
        #expect(TerminalSherpaVoiceController.recognizedText(fromLine: " 3: ") == nil)
        #expect(TerminalSherpaVoiceController.recognizedText(fromLine: "XRUN.") == nil)
        #expect(TerminalSherpaVoiceController.recognizedText(fromLine: "Started. Please speak") == nil)
        #expect(TerminalSherpaVoiceController.recognizedText(fromLine: "sample rate: 16000") == nil)
    }

    @Test
    func failureReasonPrefersTheErrorOverTrailingUsageHints() {
        // Real sherpa-onnx output without an audio device.
        let diagnostics = [
            "Recognizer created!",
            "ALSA lib pcm.c:2722:(snd_pcm_open_noupdate) Unknown PCM default",
            "Unable to open: default. No such file or directory",
            "Please use the command:",
            "arecord -l",
            "and if you want to select card 3 and device 0 on that card, please use:",
            "plughw:3,0"
        ]
        #expect(
            TerminalSherpaVoiceController.reason(status: 255, diagnostics: diagnostics)
                == "Unable to open: default. No such file or directory."
        )
        #expect(TerminalSherpaVoiceController.reason(status: 3, diagnostics: ["bad model"]) == "bad model.")
        #expect(TerminalSherpaVoiceController.reason(status: 3, diagnostics: []) == "the program exited with status 3.")
    }

    @Test
    func longAnswersAreCappedOnACharacterBoundary() {
        let limit = TerminalSherpaVoiceController.maximumSpokenBytes
        #expect(TerminalSherpaVoiceController.cappedForArgument("breve") == "breve")
        let capped = TerminalSherpaVoiceController.cappedForArgument(String(repeating: "è", count: limit))
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
        let invocation = TerminalSherpaVoiceController.invocation(for: paths)
        #expect(invocation.recognizerArguments.contains("--silero-vad-min-silence-duration=5"))
        // The pause chosen in /setup > Voice mode replaces the default.
        let options = TerminalVoiceOptions(voice: AgentVoiceSettingsManifest(utteranceSilenceSeconds: 8))
        #expect(
            TerminalSherpaVoiceController.invocation(
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

    @Test
    func recognizedUtterancesArriveOnlyAfterTheRecognizerStarted() async throws {
        let fixture = try Fixture()
        try fixture.queueUtterance("Ciao zen")
        let controller = fixture.makeController()
        await controller.start()

        #expect(await waitUntil { await fixture.events.systemMessages.contains { $0.hasPrefix("Voice: listening (sherpa-onnx") } })
        #expect(await waitUntil { await fixture.events.utterances == [.dictation(id: 1, text: "Ciao zen")] })
        #expect(await controller.phase == .listening)
        await controller.stop()
        #expect(await fixture.events.failures.isEmpty)
        // Pause mode sends every segment at once and previews nothing.
        #expect(await fixture.events.previews.isEmpty)
    }

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
    func readingTurnsTheMicrophoneOffAndBackOnWhenItEnds() async throws {
        let fixture = try Fixture(readingSeconds: "0.3")
        let controller = fixture.makeController()
        await controller.start()
        #expect(await waitUntil { await controller.phase == .listening })
        #expect(fixture.recognizerLaunches == 1)

        await controller.speak("**Ciao** a tutti")
        #expect(await waitUntil { await fixture.events.speaking == [true, false] })
        #expect(await waitUntil { fixture.recognizerLaunches == 2 })
        #expect(fixture.synthesizerCalls.last?.hasSuffix("--|Ciao a tutti.|") == true)
        await controller.stop()
        #expect(await fixture.events.failures.isEmpty)
    }

    @Test
    func escapeInterruptsReadingAndTurnsTheMicrophoneBackOn() async throws {
        let fixture = try Fixture(readingSeconds: "30")
        let controller = fixture.makeController()
        await controller.start()
        #expect(await waitUntil { await controller.phase == .listening })

        await controller.speak("Una risposta molto lunga")
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
        #expect(await controller.speak("Non letto") == false)
        #expect(await controller.speak("Non letto", rendering: .plainText) == false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.synthesizerCalls.isEmpty)

        #expect(await controller.setPaused(false))
        #expect(await waitUntil { fixture.recognizerLaunches == 2 })
        await controller.stop()
        #expect(await controller.isActive == false)
    }

    /// Live-chat texts are read whole and unchanged, while answers keep the
    /// final-sentences rule of long answers.
    @Test
    func plainTextIsReadWholeWhileAnswersKeepTheirTailRule() async throws {
        let fixture = try Fixture(readingSeconds: "0.2")
        let controller = fixture.makeController()
        await controller.start()
        #expect(await waitUntil { await controller.phase == .listening })
        #expect(controller.languageCode == "it")

        let sentence = "Questa frase riempie il messaggio. "
        let long = String(repeating: sentence, count: 1_000 / sentence.count + 1)
        #expect(long.count > 1_000)
        #expect(await controller.speak(long, rendering: .plainText))
        #expect(await controller.isSpeaking)
        #expect(await waitUntil { await fixture.events.speaking == [true, false] })
        #expect(fixture.synthesizerCalls.last?.hasSuffix("--|\(long)|") == true)

        #expect(await controller.speak("# Titolo\n\n" + long, rendering: .answer))
        #expect(await waitUntil { await fixture.events.speaking == [true, false, true, false] })
        let spokenAnswer = try #require(fixture.synthesizerCalls.last)
        #expect(spokenAnswer.contains(TerminalVoiceSpeechText.longAnswerNotice(languageCode: "it")))
        #expect(spokenAnswer.count < long.count)
        await controller.stop()
        #expect(await fixture.events.failures.isEmpty)
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

        await controller.speak("Ciao")
        #expect(await waitUntil { await fixture.events.failures.contains { $0.contains("could not be read aloud: bad model.") } })
        #expect(await waitUntil { await fixture.events.speaking == [true, false] })
        #expect(await waitUntil { fixture.recognizerLaunches == 2 })
        #expect(await controller.isActive)
        await controller.stop()
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

private struct Preview: Sendable, Equatable {
    let id: UInt64
    let text: String
}

private actor VoiceEventRecorder {
    var systemMessages: [String] = []
    var failures: [String] = []
    var utterances: [TerminalVoiceUtterance] = []
    var previews: [Preview] = []
    var speaking: [Bool] = []
    private var speakingHook: (@Sendable (Bool) async -> Void)?

    func system(_ text: String) { systemMessages.append(text) }
    func failure(_ text: String) { failures.append(text) }
    func utterance(_ utterance: TerminalVoiceUtterance) { utterances.append(utterance) }
    func preview(_ id: UInt64, _ text: String) { previews.append(Preview(id: id, text: text)) }

    func speakingChanged(_ value: Bool) async {
        speaking.append(value)
        await speakingHook?(value)
    }

    /// Runs inside the controller's `speakingChanged` callback, i.e. while
    /// the controller is suspended reporting the change.
    func setSpeakingHook(_ hook: @escaping @Sendable (Bool) async -> Void) {
        speakingHook = hook
    }
}

/// Two fake programs in a private directory. Each logs its launches; the
/// recognizer prints sherpa-onnx style startup lines and an optional queued
/// utterance, the synthesizer logs its arguments and "reads" for a while.
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
        synthesizerFails: Bool = false
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-sherpa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(
            """
            #!/bin/sh
            echo launch >> "$0.log"
            echo "VadModelConfig(silero_vad=SileroVadModelConfig(min_silence_duration=2.5))" >&2
            echo " 1: a configuration line before startup is not a result" >&2
            if [ -f "$0.fail" ]; then echo "Cannot open device default" >&2; exit 1; fi
            echo "Started. Please speak" >&2
            if [ -f "$0.utterance" ]; then while IFS= read -r line; do echo " 0: $line" >&2; done < "$0.utterance"; rm -f "$0.utterance"; fi
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
            if [ "$(grep -c '' "$0.log")" -gt 1 ]; then exec sleep \(laterReadingSeconds ?? readingSeconds); fi
            exec sleep \(readingSeconds)
            """,
            to: synthesizer
        )
        if recognizerFails {
            try Data().write(to: URL(fileURLWithPath: recognizer.path + ".fail"))
        }
        if synthesizerFails {
            try Data().write(to: URL(fileURLWithPath: synthesizer.path + ".fail"))
        }
    }

    func makeController(sendKeyword: String? = nil) -> TerminalSherpaVoiceController {
        let events = events
        return TerminalSherpaVoiceController(
            invocation: .init(
                recognizerProgram: recognizer,
                recognizerArguments: ["default"],
                synthesizerProgram: synthesizer,
                synthesizerArguments: ["--output-filename=/dev/null"]
            ),
            voiceName: "paola (it_IT)",
            languageCode: "it",
            sendKeyword: sendKeyword.flatMap(TerminalVoiceSendKeyword.init),
            callbacks: TerminalVoiceCallbacks(
                systemMessage: { await events.system($0) },
                failureMessage: { await events.failure($0) },
                utteranceRecognized: { await events.utterance($0) },
                dictationChanged: { await events.preview($0, $1) },
                speakingChanged: { await events.speakingChanged($0) }
            )
        )
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
    func relaunchRecognizer(of controller: TerminalSherpaVoiceController, hearing texts: [String]) async throws {
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

    private func logLines(of program: URL) -> [String] {
        let log = (try? String(contentsOfFile: program.path + ".log", encoding: .utf8)) ?? ""
        return log.split(separator: "\n").map(String.init)
    }

    private func write(_ script: String, to url: URL) throws {
        try Data((script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
