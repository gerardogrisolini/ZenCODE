//
//  SherpaOnnxFileTranscriberTests.swift
//  ZenCODECoreTests
//
//  Linux transcription of Telegram voice messages. Shell scripts stand in
//  for the decoder and the sherpa-onnx recognizer, so the process handling,
//  output parsing, cleanup and cancellation run on every platform without
//  audio files or models.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Sherpa-onnx file transcriber")
struct SherpaOnnxFileTranscriberTests {
    // MARK: - Installation

    @Test
    func transcriptionNeedsTheRecognizerFilesButNoVoice() throws {
        let runtime = try #require(SherpaOnnxVoiceCatalog.runtime)
        let installation = SherpaOnnxVoiceInstallation(
            directoryURL: Self.uniqueDirectory().appendingPathComponent("voice", isDirectory: true)
        )
        #expect(installation.transcriptionPaths() == .failure(.notInstalled))

        let fileManager = FileManager.default
        let bin = installation.installedURL(for: runtime).appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        let program = bin.appendingPathComponent("sherpa-onnx-vad-with-offline-asr")
        try Data("#!/bin/sh\n".utf8).write(to: program)
        let recognizer = installation.installedURL(for: SherpaOnnxVoiceCatalog.recognizer)
        try fileManager.createDirectory(at: recognizer, withIntermediateDirectories: true)
        for name in ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"] {
            try Data().write(to: recognizer.appendingPathComponent(name))
        }
        try Data().write(to: installation.installedURL(for: SherpaOnnxVoiceCatalog.voiceActivityDetector))

        // The program must be executable.
        #expect(installation.transcriptionPaths() == .failure(.unexpectedLayout(runtime.fileName)))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)

        let paths = try installation.transcriptionPaths().get()
        #expect(paths.program == program)
        #expect(paths.encoder == recognizer.appendingPathComponent("encoder.int8.onnx"))
        #expect(paths.tokens == recognizer.appendingPathComponent("tokens.txt"))
        #expect(paths.voiceActivityModel.lastPathComponent == "silero_vad.onnx")
        // Voice mode itself still needs a Piper voice.
        #expect(installation.runtimePaths() == .failure(.notInstalled))
    }

    // MARK: - Decoder

    @Test
    func opusdecIsPreferredForOggOpusThenFfmpeg() throws {
        let directory = Self.uniqueDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let opusdec = directory.appendingPathComponent("opusdec")
        let ffmpeg = directory.appendingPathComponent("ffmpeg")
        try Self.writeScript("#!/bin/sh\n", to: opusdec)
        try Self.writeScript("#!/bin/sh\n", to: ffmpeg)
        let search = [directory.path]
        let voiceNote = Self.audio(named: "voice.oga")

        #expect(SherpaOnnxAudioDecoder.available(for: voiceNote, searchDirectories: search)
            == SherpaOnnxAudioDecoder(kind: .opusdec, executable: opusdec))
        // Every installed decoder is a candidate, in order of preference.
        #expect(SherpaOnnxAudioDecoder.candidates(for: voiceNote, searchDirectories: search)
            == [
                SherpaOnnxAudioDecoder(kind: .opusdec, executable: opusdec),
                SherpaOnnxAudioDecoder(kind: .ffmpeg, executable: ffmpeg)
            ])
        // A content type is enough to recognize Ogg Opus.
        let typed = Self.audio(named: "file_7", contentType: "audio/ogg")
        #expect(SherpaOnnxAudioDecoder.available(for: typed, searchDirectories: search)?.kind == .opusdec)
        // opusdec decodes only Ogg Opus.
        let mp3 = Self.audio(named: "voice.mp3", contentType: "audio/mpeg")
        #expect(SherpaOnnxAudioDecoder.available(for: mp3, searchDirectories: search)?.kind == .ffmpeg)
        #expect(SherpaOnnxAudioDecoder.candidates(for: mp3, searchDirectories: search).map(\.kind) == [.ffmpeg])

        try FileManager.default.removeItem(at: opusdec)
        #expect(SherpaOnnxAudioDecoder.available(for: voiceNote, searchDirectories: search)
            == SherpaOnnxAudioDecoder(kind: .ffmpeg, executable: ffmpeg))
        #expect(SherpaOnnxAudioDecoder.candidates(for: voiceNote, searchDirectories: search).map(\.kind) == [.ffmpeg])

        try FileManager.default.removeItem(at: ffmpeg)
        #expect(SherpaOnnxAudioDecoder.available(for: voiceNote, searchDirectories: search) == nil)
        #expect(SherpaOnnxAudioDecoder.candidates(for: voiceNote, searchDirectories: search).isEmpty)
        #expect(SherpaOnnxAudioDecoder.searchDirectories == ["/usr/bin", "/bin", "/usr/local/bin"])
    }

    // MARK: - Recognizer output

    @Test
    func segmentsAreJoinedAndOtherLinesIgnored() {
        let output = """
        0.000 -- 2.340: Ciao a tutti.
        Resampling done
        2.900 -- 5.100: Come va?
        7.000 -- 7.400:\u{20}
        not -- a: segment
        """
        #expect(SherpaOnnxFileTranscriber.transcript(fromOutput: output) == "Ciao a tutti. Come va?")
        #expect(SherpaOnnxFileTranscriber.transcript(fromOutput: "") == "")
        // A colon inside the text is kept.
        #expect(SherpaOnnxFileTranscriber.segmentText(fromLine: "1.5 -- 3.25: Ore 10:30") == "Ore 10:30")
    }

    @Test
    func recognizerRunsParakeetWithTheVoiceActivityDetector() {
        let root = URL(fileURLWithPath: "/opt/voice")
        let paths = SherpaOnnxTranscriptionPaths(
            program: root.appendingPathComponent("bin/sherpa-onnx-vad-with-offline-asr"),
            voiceActivityModel: root.appendingPathComponent("silero_vad.onnx"),
            encoder: root.appendingPathComponent("p/encoder.int8.onnx"),
            decoder: root.appendingPathComponent("p/decoder.int8.onnx"),
            joiner: root.appendingPathComponent("p/joiner.int8.onnx"),
            tokens: root.appendingPathComponent("p/tokens.txt")
        )
        #expect(SherpaOnnxFileTranscriber.recognizerArguments(for: paths, wave: URL(fileURLWithPath: "/tmp/w/voice.wav")) == [
            "--silero-vad-model=/opt/voice/silero_vad.onnx",
            "--encoder=/opt/voice/p/encoder.int8.onnx",
            "--decoder=/opt/voice/p/decoder.int8.onnx",
            "--joiner=/opt/voice/p/joiner.int8.onnx",
            "--tokens=/opt/voice/p/tokens.txt",
            "--model-type=nemo_transducer",
            "/tmp/w/voice.wav"
        ])
    }

    // MARK: - Running the programs

    @Test
    func transcribesThroughDecoderAndRecognizerAndRemovesTheWave() async throws {
        let fixture = try TranscriberFixture()
        try fixture.setRecognizerOutput("0.000 -- 1.900: Apri il file README.\n2.400 -- 4.000: Grazie.\n")
        let text = try await fixture.transcriber.transcribe(fixture.audio)
        #expect(text == "Apri il file README. Grazie.")

        let decoderArguments = try fixture.arguments(of: fixture.decoder)
        #expect(decoderArguments.prefix(4) == ["--quiet", "--rate", "16000", fixture.audio.fileURL.path])
        let wave = try #require(decoderArguments.last)
        #expect(wave.hasSuffix("/voice.wav"))
        // The recognizer read the decoded file, which is gone afterwards.
        #expect(try fixture.arguments(of: fixture.recognizer).last == wave)
        #expect(try fixture.workDirectories().isEmpty)
    }

    @Test
    func decoderFailuresAreReportedWithTheirLastErrorLine() async throws {
        let fixture = try TranscriberFixture()
        try fixture.mark(fixture.decoder, "fail")
        await #expect(throws: SherpaOnnxTranscriptionError.decodingFailed(program: "opusdec", reason: "Failed to open voice.oga")) {
            try await fixture.transcriber.transcribe(fixture.audio)
        }
        #expect(SherpaOnnxTranscriptionError.decodingFailed(program: "opusdec", reason: "Failed to open voice.oga").localizedDescription
            == "opusdec could not decode the voice message: Failed to open voice.oga")
        #expect(!FileManager.default.fileExists(atPath: fixture.recognizer.path + ".args"))
        #expect(try fixture.workDirectories().isEmpty)

        let silent = try TranscriberFixture()
        try silent.mark(silent.decoder, "silent")
        await #expect(throws: SherpaOnnxTranscriptionError.decodingFailed(program: "opusdec", reason: "no audio was produced")) {
            try await silent.transcriber.transcribe(silent.audio)
        }
    }

    // MARK: - ffmpeg fallback

    @Test
    func ffmpegDecodesTheSameInputWhenOpusdecFails() async throws {
        let fixture = try TranscriberFixture(withFfmpeg: true)
        try fixture.mark(fixture.decoder, "fail")
        // opusdec leaves a partial file behind: ffmpeg must not find it.
        try fixture.mark(fixture.decoder, "partial")
        try fixture.setRecognizerOutput("0.000 -- 1.500: Apri il file README.\n")
        let text = try await fixture.transcriber.transcribe(fixture.audio)
        #expect(text == "Apri il file README.")

        let opusdecArguments = try fixture.arguments(of: fixture.decoder)
        #expect(opusdecArguments.prefix(4) == ["--quiet", "--rate", "16000", fixture.audio.fileURL.path])
        let wave = try #require(opusdecArguments.last)
        let ffmpegArguments = try fixture.arguments(of: fixture.ffmpeg)
        #expect(ffmpegArguments == SherpaOnnxAudioDecoder(kind: .ffmpeg, executable: fixture.ffmpeg)
            .arguments(input: fixture.audio.fileURL, output: URL(fileURLWithPath: wave)))
        #expect(!FileManager.default.fileExists(atPath: fixture.ffmpeg.path + ".stale"))
        // The recognizer read what ffmpeg wrote, and nothing is left behind.
        #expect(try fixture.arguments(of: fixture.recognizer).last == wave)
        #expect(try fixture.workDirectories().isEmpty)

        // An opusdec that exits cleanly without audio counts as a failure too.
        let silent = try TranscriberFixture(withFfmpeg: true)
        try silent.mark(silent.decoder, "silent")
        try silent.setRecognizerOutput("0.000 -- 1.500: Grazie.\n")
        #expect(try await silent.transcriber.transcribe(silent.audio) == "Grazie.")
        #expect(FileManager.default.fileExists(atPath: silent.ffmpeg.path + ".args"))
        #expect(try silent.workDirectories().isEmpty)
    }

    @Test
    func recognizerFailuresAndEmptyResultsAreReported() async throws {
        let failing = try TranscriberFixture()
        try failing.mark(failing.recognizer, "fail")
        await #expect(throws: SherpaOnnxTranscriptionError.recognitionFailed("Failed to read the wave file")) {
            try await failing.transcriber.transcribe(failing.audio)
        }
        #expect(try failing.workDirectories().isEmpty)

        let empty = try TranscriberFixture()
        await #expect(throws: AgentVoiceTranscriptionError.emptyTranscript) {
            try await empty.transcriber.transcribe(empty.audio)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingStopsARecognizerThatIgnoresSIGTERM() async throws {
        let fixture = try TranscriberFixture()
        try fixture.mark(fixture.recognizer, "hang")
        let transcriber = fixture.transcriber
        let audio = fixture.audio
        let task = Task { try await transcriber.transcribe(audio) }
        while !FileManager.default.fileExists(atPath: fixture.recognizer.path + ".args") {
            try await Task.sleep(for: .milliseconds(20))
        }
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(started.duration(to: .now) < .seconds(10))
        #expect(try fixture.workDirectories().isEmpty)
    }

    // MARK: - Service

    @Test
    func transcriptionNeedsTelegramTranscriptionToBeOn() async throws {
        let fixture = try TranscriberFixture()
        let service = AgentVoiceTranscriptionService(
            settings: AgentVoiceSettingsManifest(enabled: false),
            languageCode: "it"
        )
        await #expect(throws: AgentVoiceTranscriptionError.missingConfiguration) {
            try await service.transcribe(fixture.audio)
        }
        #expect(AgentVoiceTranscriptionError.missingConfiguration.localizedDescription
            == AgentVoiceTranscriptionError.notEnabledMessage)
    }

    // MARK: - Support

    static func uniqueDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-transcriber-\(UUID().uuidString)", isDirectory: true)
    }

    static func audio(named name: String, contentType: String? = nil) -> AgentVoiceAudioInput {
        AgentVoiceAudioInput(
            fileURL: URL(fileURLWithPath: "/tmp").appendingPathComponent(name),
            filename: name,
            contentType: contentType
        )
    }

    static func writeScript(_ script: String, to url: URL) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

/// A fake `opusdec` and recognizer in a private directory, plus a private
/// temporary directory for the transcriber's work files, and optionally a
/// fake `ffmpeg` as the fallback decoder. Marker files beside each script
/// (`<script>.<name>`) select a behaviour; each script records its arguments
/// in `<script>.args`, and a decoder that finds its output file already there
/// records it in `<script>.stale`.
private struct TranscriberFixture {
    let directory: URL
    let temporaryDirectory: URL
    let audio: AgentVoiceAudioInput
    let hasFfmpeg: Bool

    var decoder: URL { directory.appendingPathComponent("opusdec") }
    var ffmpeg: URL { directory.appendingPathComponent("ffmpeg") }
    var recognizer: URL { directory.appendingPathComponent("sherpa-onnx-vad-with-offline-asr") }

    var transcriber: SherpaOnnxFileTranscriber {
        let model = directory.appendingPathComponent("model", isDirectory: true)
        return SherpaOnnxFileTranscriber(
            paths: SherpaOnnxTranscriptionPaths(
                program: recognizer,
                voiceActivityModel: model.appendingPathComponent("silero_vad.onnx"),
                encoder: model.appendingPathComponent("encoder.int8.onnx"),
                decoder: model.appendingPathComponent("decoder.int8.onnx"),
                joiner: model.appendingPathComponent("joiner.int8.onnx"),
                tokens: model.appendingPathComponent("tokens.txt")
            ),
            decoder: SherpaOnnxAudioDecoder(kind: .opusdec, executable: decoder),
            fallbackDecoder: hasFfmpeg ? SherpaOnnxAudioDecoder(kind: .ffmpeg, executable: ffmpeg) : nil,
            temporaryDirectory: temporaryDirectory
        )
    }

    init(withFfmpeg: Bool = false) throws {
        hasFfmpeg = withFfmpeg
        let root = SherpaOnnxFileTranscriberTests.uniqueDirectory()
        directory = root.appendingPathComponent("bin", isDirectory: true)
        temporaryDirectory = root.appendingPathComponent("tmp", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let voiceNote = root.appendingPathComponent("voice.oga")
        try Data("OggS".utf8).write(to: voiceNote)
        audio = AgentVoiceAudioInput(fileURL: voiceNote, filename: "voice.oga", contentType: "audio/ogg")

        try SherpaOnnxFileTranscriberTests.writeScript(
            Self.decoderScript(failure: "Failed to open voice.oga"),
            to: decoder
        )
        if withFfmpeg {
            try SherpaOnnxFileTranscriberTests.writeScript(
                Self.decoderScript(failure: "Invalid data found when processing input"),
                to: ffmpeg
            )
        }
        try SherpaOnnxFileTranscriberTests.writeScript(
            """
            #!/bin/sh
            printf '%s\\n' "$@" > "$0.args"
            for last; do :; done
            echo "VadModelConfig(silero_vad=SileroVadModelConfig(min_silence_duration=0.5))" >&2
            echo "Started" >&2
            test -f "$last" || { echo "missing wave" >&2; exit 2; }
            if [ -f "$0.hang" ]; then trap '' TERM; exec sleep 30; fi
            if [ -f "$0.fail" ]; then echo "Failed to read the wave file" >&2; exit 255; fi
            if [ -f "$0.output" ]; then cat "$0.output"; fi
            exit 0
            """,
            to: recognizer
        )
    }

    func mark(_ script: URL, _ name: String) throws {
        try Data().write(to: URL(fileURLWithPath: script.path + "." + name))
    }

    /// A decoder whose output file is its last argument. `fail` exits with
    /// `failure` on standard error, after writing a partial file with
    /// `partial`; `silent` exits cleanly without writing.
    private static func decoderScript(failure: String) -> String {
        """
        #!/bin/sh
        printf '%s\\n' "$@" > "$0.args"
        for last; do :; done
        if [ -e "$last" ]; then : > "$0.stale"; fi
        if [ -f "$0.fail" ]; then
            if [ -f "$0.partial" ]; then printf 'RIFF' > "$last"; fi
            echo "Decoding..." >&2; echo "\(failure)" >&2; exit 1
        fi
        if [ -f "$0.silent" ]; then exit 0; fi
        printf 'RIFF' > "$last"
        """
    }

    func setRecognizerOutput(_ output: String) throws {
        try Data(output.utf8).write(to: URL(fileURLWithPath: recognizer.path + ".output"))
    }

    func arguments(of script: URL) throws -> [String] {
        try String(contentsOfFile: script.path + ".args", encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }

    /// Work directories the transcriber left behind.
    func workDirectories() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
    }
}
