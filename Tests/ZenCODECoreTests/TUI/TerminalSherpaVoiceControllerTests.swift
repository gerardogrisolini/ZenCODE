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
        #expect(invocation.recognizerArguments.contains("--silero-vad-min-silence-duration=2.5"))
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
        #expect(await waitUntil { await fixture.events.utterances == ["Ciao zen"] })
        #expect(await controller.phase == .listening)
        await controller.stop()
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
        await controller.speak("Non letto")
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

private actor VoiceEventRecorder {
    var systemMessages: [String] = []
    var failures: [String] = []
    var utterances: [String] = []
    var speaking: [Bool] = []

    func system(_ text: String) { systemMessages.append(text) }
    func failure(_ text: String) { failures.append(text) }
    func utterance(_ text: String) { utterances.append(text) }
    func speakingChanged(_ value: Bool) { speaking.append(value) }
}

/// Two fake programs in a private directory. Each logs its launches; the
/// recognizer prints sherpa-onnx style startup lines and an optional queued
/// utterance, the synthesizer logs its arguments and "reads" for a while.
private struct Fixture {
    let directory: URL
    let events = VoiceEventRecorder()

    var recognizer: URL { directory.appendingPathComponent("asr.sh") }
    var synthesizer: URL { directory.appendingPathComponent("tts.sh") }

    init(
        readingSeconds: String = "0.2",
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
            if [ -f "$0.utterance" ]; then echo " 0: $(cat "$0.utterance")" >&2; rm -f "$0.utterance"; fi
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

    func makeController() -> TerminalSherpaVoiceController {
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
            callbacks: TerminalVoiceCallbacks(
                systemMessage: { await events.system($0) },
                failureMessage: { await events.failure($0) },
                utteranceRecognized: { await events.utterance($0) },
                speakingChanged: { await events.speakingChanged($0) }
            )
        )
    }

    func queueUtterance(_ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: recognizer.path + ".utterance"))
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
