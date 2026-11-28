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
@testable import ZenCODERuntime
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Serialized: each case runs real child processes, and Foundation.Process exits are serviced process-wide.
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
        #expect(await waitUntil { await fixture.events.speaking.starts(with: [true, false, true]) })
        #expect(await controller.isSpeaking)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.recognizerLaunches == 1)

        #expect(await waitUntil { await fixture.events.speaking.starts(with: [true, false, true, false]) })
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
        #expect(await waitUntil { await fixture.events.speaking.starts(with: [true, false]) })
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
        #expect(await waitUntil { await fixture.events.speaking.starts(with: [true]) })
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
        #expect(await waitUntil { await fixture.events.speaking.starts(with: [true, false]) })
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
        // The recognizer sleeps for 30 s: finishing well before it shows stop escalated instead of waiting.
        #expect(stoppedAt.duration(to: .now) < .seconds(20))
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
        timeout: Duration = .seconds(30),
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
