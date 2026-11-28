//
//  SherpaVoiceModeControllerTests+Fixture.swift
//  ZenCODECoreTests
//
//  The fake sherpa-onnx programs, the event recorder and the preview value
//  that the Sherpa voice controller tests share, nested in the suite.
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

extension SherpaVoiceModeControllerTests {
    struct Preview: Sendable, Equatable {
        let id: UInt64
        let text: String
    }

    actor VoiceEventRecorder {
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
    struct Fixture {
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
            let deadline = ContinuousClock.now + .seconds(30)
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
}
