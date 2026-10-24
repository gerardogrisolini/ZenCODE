//
//  SherpaOnnxFileTranscriber.swift
//  ZenCODE
//
//  Linux transcription of Telegram voice messages. The downloaded message is
//  decoded with `opusdec` (opus-tools), else `ffmpeg` — also when `opusdec`
//  fails on a file that is not really Ogg Opus — into a temporary
//  16 kHz mono WAV file; `sherpa-onnx-vad-with-offline-asr` then splits it on
//  silences with the Silero voice activity detector and recognizes each
//  segment with Parakeet TDT 0.6B v3 — the files installed by `/setup` >
//  Voice mode. Parakeet recognizes the spoken language by itself. Every
//  program runs as an external process, and the temporary WAV lives in a
//  private directory removed as soon as the transcription ends.
//

import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The program that turns a voice message into the WAV file the recognizer
/// reads: 16-bit PCM, mono, 16 kHz.
struct SherpaOnnxAudioDecoder: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case opusdec
        case ffmpeg
    }

    let kind: Kind
    let executable: URL

    /// A fixed search path, like `tar` and `bzip2`: the choice does not
    /// depend on `PATH`.
    static let searchDirectories = ["/usr/bin", "/bin", "/usr/local/bin"]

    /// `opusdec` decodes only Ogg Opus, the format of Telegram voice messages.
    static func isOggOpus(_ audio: AgentVoiceAudioInput) -> Bool {
        let contentType = audio.contentType?.lowercased() ?? ""
        if contentType.contains("ogg") || contentType.contains("opus") {
            return true
        }
        let fileExtension = URL(fileURLWithPath: audio.filename).pathExtension.lowercased()
        return ["oga", "ogg", "opus"].contains(fileExtension)
    }

    /// The installed decoders that can read `audio`, in order of preference:
    /// `opusdec` then `ffmpeg` for Ogg Opus, `ffmpeg` alone for anything else.
    static func candidates(
        for audio: AgentVoiceAudioInput,
        searchDirectories: [String] = Self.searchDirectories,
        fileManager: FileManager = .default
    ) -> [SherpaOnnxAudioDecoder] {
        let kinds: [Kind] = isOggOpus(audio) ? [.opusdec, .ffmpeg] : [.ffmpeg]
        return kinds.compactMap { kind in
            for directory in searchDirectories {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent(kind.rawValue)
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return SherpaOnnxAudioDecoder(kind: kind, executable: candidate)
                }
            }
            return nil
        }
    }

    /// `opusdec` when it is installed and `audio` is Ogg Opus, else `ffmpeg`;
    /// `nil` when neither is installed.
    static func available(
        for audio: AgentVoiceAudioInput,
        searchDirectories: [String] = Self.searchDirectories,
        fileManager: FileManager = .default
    ) -> SherpaOnnxAudioDecoder? {
        candidates(for: audio, searchDirectories: searchDirectories, fileManager: fileManager).first
    }

    func arguments(input: URL, output: URL) -> [String] {
        switch kind {
        case .opusdec:
            // A `.wav` output name selects a WAVE header, which opusdec
            // rewrites with the real sizes once decoding ends.
            return ["--quiet", "--rate", "16000", input.path, output.path]
        case .ffmpeg:
            // Bit-exact output without metadata keeps a plain PCM header.
            return [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-i", input.path,
                "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact",
                "-f", "wav", output.path
            ]
        }
    }
}

enum SherpaOnnxTranscriptionError: LocalizedError, Equatable {
    case missingDecoder(oggOpus: Bool)
    case decodingFailed(program: String, reason: String)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingDecoder(oggOpus: true):
            return "Transcribing voice messages needs opusdec (package opus-tools) or ffmpeg. Install one with your package manager and try again."
        case .missingDecoder(oggOpus: false):
            return "Transcribing this audio format needs ffmpeg. Install it with your package manager and try again."
        case let .decodingFailed(program, reason):
            return "\(program) could not decode the voice message: \(reason)"
        case let .recognitionFailed(reason):
            return "The speech recognizer failed: \(reason)"
        }
    }
}

struct SherpaOnnxFileTranscriber: Sendable {
    let paths: SherpaOnnxTranscriptionPaths
    let decoder: SherpaOnnxAudioDecoder
    /// Tried on the same input when `decoder` fails: `opusdec` fails on a
    /// `.ogg` that is Vorbis, or on an `audio/ogg` file that is not Opus.
    let fallbackDecoder: SherpaOnnxAudioDecoder?
    let temporaryDirectory: URL

    init(
        paths: SherpaOnnxTranscriptionPaths,
        decoder: SherpaOnnxAudioDecoder,
        fallbackDecoder: SherpaOnnxAudioDecoder? = nil,
        temporaryDirectory: URL
    ) {
        self.paths = paths
        self.decoder = decoder
        self.fallbackDecoder = fallbackDecoder
        self.temporaryDirectory = temporaryDirectory
    }

    /// The transcriber for `audio`, or why it cannot run: voice mode files
    /// missing (`SherpaOnnxVoiceInstallError`) or no decoder installed.
    static func make(
        installation: SherpaOnnxVoiceInstallation,
        audio: AgentVoiceAudioInput,
        searchDirectories: [String] = SherpaOnnxAudioDecoder.searchDirectories,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> SherpaOnnxFileTranscriber {
        let paths = try installation.transcriptionPaths().get()
        let decoders = SherpaOnnxAudioDecoder.candidates(
            for: audio,
            searchDirectories: searchDirectories
        )
        guard let decoder = decoders.first else {
            throw SherpaOnnxTranscriptionError.missingDecoder(
                oggOpus: SherpaOnnxAudioDecoder.isOggOpus(audio)
            )
        }
        return SherpaOnnxFileTranscriber(
            paths: paths,
            decoder: decoder,
            fallbackDecoder: decoders.dropFirst().first,
            temporaryDirectory: temporaryDirectory
        )
    }

    static func recognizerArguments(
        for paths: SherpaOnnxTranscriptionPaths,
        wave: URL
    ) -> [String] {
        [
            "--silero-vad-model=\(paths.voiceActivityModel.path)",
            "--encoder=\(paths.encoder.path)",
            "--decoder=\(paths.decoder.path)",
            "--joiner=\(paths.joiner.path)",
            "--tokens=\(paths.tokens.path)",
            "--model-type=nemo_transducer",
            wave.path
        ]
    }

    /// The recognized segments, printed one per line as
    /// `<start> -- <end>: <text>`, joined into one text.
    static func transcript(fromOutput output: String) -> String {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { segmentText(fromLine: $0) }
            .joined(separator: " ")
    }

    static func segmentText(fromLine line: Substring) -> String? {
        guard let separator = line.range(of: " -- "),
              let colon = line[separator.upperBound...].range(of: ":") else {
            return nil
        }
        let start = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        let end = line[separator.upperBound..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
        guard Double(start) != nil, Double(end) != nil else {
            return nil
        }
        let text = line[colon.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func transcribe(_ audio: AgentVoiceAudioInput) async throws -> String {
        let fileManager = FileManager.default
        let workDirectory = temporaryDirectory.appendingPathComponent(
            "ZenCODE-voice-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        defer {
            try? fileManager.removeItem(at: workDirectory)
        }
        let wave = workDirectory.appendingPathComponent("voice.wav")

        try await decode(audio, to: wave)
        try Task.checkCancellation()

        let recognized: SherpaOnnxProgramOutput
        do {
            recognized = try await SherpaOnnxProgramRunner.run(
                paths.program,
                arguments: Self.recognizerArguments(for: paths, wave: wave)
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            throw SherpaOnnxTranscriptionError.recognitionFailed(error.localizedDescription)
        }
        guard recognized.status == 0 else {
            throw SherpaOnnxTranscriptionError.recognitionFailed(recognized.failureReason)
        }
        let text = Self.transcript(
            fromOutput: String(decoding: recognized.standardOutput, as: UTF8.self)
        )
        guard !text.isEmpty else {
            throw AgentVoiceTranscriptionError.emptyTranscript
        }
        return text
    }

    /// Decodes `audio` into `wave` with `decoder`. When that fails and a
    /// fallback decoder is installed, the fallback decodes the same input into
    /// a clean `wave`. If both fail the error names the first decoder and
    /// adds the reason of the second one.
    func decode(_ audio: AgentVoiceAudioInput, to wave: URL) async throws {
        do {
            try await decode(audio, with: decoder, to: wave)
        } catch let first as SherpaOnnxTranscriptionError {
            guard let fallbackDecoder, case let .decodingFailed(program, firstReason) = first else {
                throw first
            }
            // A failed decoder can leave a partial file behind.
            try? FileManager.default.removeItem(at: wave)
            do {
                try await decode(audio, with: fallbackDecoder, to: wave)
            } catch let second as SherpaOnnxTranscriptionError {
                guard case let .decodingFailed(fallbackProgram, secondReason) = second else {
                    throw second
                }
                throw SherpaOnnxTranscriptionError.decodingFailed(
                    program: program,
                    reason: "\(firstReason); \(fallbackProgram) also failed: \(secondReason)"
                )
            }
        }
    }

    private func decode(
        _ audio: AgentVoiceAudioInput,
        with decoder: SherpaOnnxAudioDecoder,
        to wave: URL
    ) async throws {
        let decoded: SherpaOnnxProgramOutput
        do {
            decoded = try await SherpaOnnxProgramRunner.run(
                decoder.executable,
                arguments: decoder.arguments(input: audio.fileURL, output: wave)
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            throw SherpaOnnxTranscriptionError.decodingFailed(
                program: decoder.kind.rawValue,
                reason: error.localizedDescription
            )
        }
        guard decoded.status == 0 else {
            throw SherpaOnnxTranscriptionError.decodingFailed(
                program: decoder.kind.rawValue,
                reason: decoded.failureReason
            )
        }
        guard FileManager.default.fileExists(atPath: wave.path) else {
            throw SherpaOnnxTranscriptionError.decodingFailed(
                program: decoder.kind.rawValue,
                reason: "no audio was produced"
            )
        }
    }
}

/// A finished one-shot program.
struct SherpaOnnxProgramOutput: Sendable, Equatable {
    let status: Int32
    let standardOutput: Data
    /// The end of standard error, where the sherpa-onnx programs print their
    /// errors after a long configuration dump.
    let standardErrorTail: String

    /// The last line of standard error, else the exit status.
    var failureReason: String {
        let lastLine = standardErrorTail
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return lastLine ?? "exit status \(status)"
    }
}

/// Runs a program to completion off the cooperative thread pool. Cancelling
/// the calling task ends the program: SIGTERM, then SIGKILL after a short
/// grace, because a child can inherit the ignored SIGTERM of the terminal.
enum SherpaOnnxProgramRunner {
    static let maximumOutputBytes = 1 << 20
    static let errorTailBytes = 4_096
    static let terminationGrace = DispatchTimeInterval.milliseconds(300)

    static func run(_ executable: URL, arguments: [String]) async throws -> SherpaOnnxProgramOutput {
        let program = RunningProgram()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try runToCompletion(executable, arguments: arguments, program: program)
                    })
                }
            }
        } onCancel: {
            program.cancel()
        }
    }

    private static func runToCompletion(
        _ executable: URL,
        arguments: [String],
        program: RunningProgram
    ) throws -> SherpaOnnxProgramOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        guard try program.launch(process) else {
            throw CancellationError()
        }
        let output = PipeCollector(
            handle: outputPipe.fileHandleForReading,
            limit: maximumOutputBytes,
            keepsTail: false
        )
        let errors = PipeCollector(
            handle: errorPipe.fileHandleForReading,
            limit: errorTailBytes,
            keepsTail: true
        )
        process.waitUntilExit()
        let standardOutput = output.finish()
        let standardError = errors.finish()
        if program.wasCancelled {
            throw CancellationError()
        }
        return SherpaOnnxProgramOutput(
            status: process.terminationStatus,
            standardOutput: standardOutput,
            standardErrorTail: String(decoding: standardError, as: UTF8.self)
        )
    }

    /// The launched process, shared with the cancellation handler.
    private final class RunningProgram: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var isCancelled = false

        /// Launches `process` unless the task was cancelled first.
        func launch(_ process: Process) throws -> Bool {
            try lock.withLock {
                guard !isCancelled else {
                    return false
                }
                try process.run()
                self.process = process
                return true
            }
        }

        var wasCancelled: Bool {
            lock.withLock { isCancelled }
        }

        func cancel() {
            let process = lock.withLock { () -> Process? in
                isCancelled = true
                return self.process
            }
            guard let process, process.isRunning else {
                return
            }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + SherpaOnnxProgramRunner.terminationGrace) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }

    /// Drains a pipe on a dedicated thread until EOF, keeping at most
    /// `limit` bytes: the first ones, or the last ones with `keepsTail`.
    private final class PipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let finished = DispatchSemaphore(value: 0)
        private var data = Data()

        init(handle: FileHandle, limit: Int, keepsTail: Bool) {
            let thread = Thread { [self] in
                while let chunk = try? handle.read(upToCount: 16 * 1_024), !chunk.isEmpty {
                    lock.withLock {
                        if keepsTail {
                            data.append(chunk)
                            if data.count > limit {
                                data = Data(data.suffix(limit))
                            }
                        } else if data.count < limit {
                            data.append(chunk.prefix(limit - data.count))
                        }
                    }
                }
                try? handle.close()
                finished.signal()
            }
            thread.stackSize = 256 * 1_024
            thread.start()
        }

        /// Waits for EOF and returns the retained bytes.
        func finish() -> Data {
            finished.wait()
            return lock.withLock { data }
        }
    }
}
