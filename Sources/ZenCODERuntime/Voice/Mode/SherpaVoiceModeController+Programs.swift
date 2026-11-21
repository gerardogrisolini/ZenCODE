//
//  SherpaVoiceModeController+Programs.swift
//  ZenCODE
//
//  The sherpa-onnx programs of Linux voice mode: their command lines, the
//  recognizer result lines, the cap on the spoken text, and the reason shown
//  when one fails.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension SherpaVoiceModeController {
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
}
