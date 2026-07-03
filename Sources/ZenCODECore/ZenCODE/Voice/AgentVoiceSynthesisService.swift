//
//  AgentVoiceSynthesisService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation
import Synchronization

public typealias AgentVoiceSynthesisProgress = AgentVoiceToolProgress

public struct AgentVoiceSpokenText: Equatable, Sendable {
    public let text: String
    public let isShortened: Bool
}

public enum AgentVoiceSpokenTextFormatter {
    public static let defaultCharacterLimit = 1_200

    public static func prepare(
        _ text: String,
        characterLimit: Int = Self.defaultCharacterLimit
    ) -> AgentVoiceSpokenText {
        let normalizedOriginal = normalizedSpeechText(text)
        let speechText = normalizedSpeechText(
            removeMarkdownNoise(from: text)
        ).nilIfBlank ?? normalizedOriginal
        let limit = max(80, characterLimit)
        guard speechText.count > limit else {
            return AgentVoiceSpokenText(text: speechText, isShortened: speechText != normalizedOriginal)
        }

        return AgentVoiceSpokenText(
            text: truncatedAtSpeechBoundary(speechText, limit: limit),
            isShortened: true
        )
    }

    private static func removeMarkdownNoise(from text: String) -> String {
        var outputLines: [String] = []
        var isInsideCodeBlock = false
        for line in text.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") {
                isInsideCodeBlock.toggle()
                continue
            }
            guard !isInsideCodeBlock else {
                continue
            }
            outputLines.append(line)
        }

        var cleaned = outputLines.joined(separator: "\n")
        cleaned = cleaned.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "`", with: "")
        return cleaned
    }

    private static func normalizedSpeechText(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map(cleanSpeechLine)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanSpeechLine(_ line: String) -> String {
        var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix("#") {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for marker in ["- ", "* ", "+ ", "> "] where cleaned.hasPrefix(marker) {
            cleaned.removeFirst(marker.count)
            break
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncatedAtSpeechBoundary(_ text: String, limit: Int) -> String {
        let limitIndex = text.index(text.startIndex, offsetBy: limit)
        let prefix = text[..<limitIndex]
        let minimumBoundaryDistance = limit / 2
        let boundaryIndex = prefix.indices.reversed().first { index in
            let distance = text.distance(from: text.startIndex, to: index)
            guard distance >= minimumBoundaryDistance else {
                return false
            }
            return ".!?".contains(prefix[index])
        } ?? prefix.indices.reversed().first { index in
            let distance = text.distance(from: text.startIndex, to: index)
            return distance >= minimumBoundaryDistance && prefix[index].isWhitespace
        }

        let truncated: String
        if let boundaryIndex {
            let endIndex = text.index(after: boundaryIndex)
            truncated = String(text[..<endIndex])
        } else {
            truncated = String(prefix)
        }
        let trimmed = truncated.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.last.map({ ".!?".contains($0) }) == true {
            return trimmed
        }
        return "\(trimmed)..."
    }
}

public struct AgentVoiceSynthesisOutput: Equatable, Sendable {
    public let fileURL: URL
    public let filename: String
    public let contentType: String
    public let removeAfterUse: Bool

    public init(
        fileURL: URL,
        filename: String? = nil,
        contentType: String = "audio/mp4",
        removeAfterUse: Bool = false
    ) {
        self.fileURL = fileURL
        self.filename = filename?.nilIfBlank ?? fileURL.lastPathComponent.nilIfBlank ?? "speech.m4a"
        self.contentType = contentType
        self.removeAfterUse = removeAfterUse
    }

    public func cleanup() {
        guard removeAfterUse else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

public actor AgentVoiceSynthesisService {
    private let settings: AgentVoiceSettingsManifest?

    public nonisolated static var isSupported: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    public init(
        settings: AgentVoiceSettingsManifest? = AgentSettingsManifestStore.load()?.voice
    ) {
        self.settings = settings
    }

    public func synthesize(
        _ text: String,
        progress: AgentVoiceSynthesisProgress? = nil
    ) async throws -> AgentVoiceSynthesisOutput {
        let speechText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speechText.isEmpty else {
            throw AgentVoiceSynthesisError.emptyText
        }
        guard Self.isSupported else {
            throw AgentVoiceSynthesisError.unsupportedPlatform
        }
        guard let settings, settings.isConfigured else {
            throw AgentVoiceSynthesisError.missingConfiguration
        }

        #if os(macOS)
        await progress?("Synthesizing speech")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-speech-\(UUID().uuidString)")
            .appendingPathExtension("caf")

        try await AgentVoiceSpeechWriter.write(
            text: speechText,
            language: settings.language,
            speaker: settings.speaker,
            to: outputURL
        )

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw AgentVoiceSynthesisError.missingOutput(outputURL.path)
        }
        return AgentVoiceSynthesisOutput(
            fileURL: outputURL,
            filename: outputURL.lastPathComponent,
            contentType: "audio/x-caf",
            removeAfterUse: true
        )
        #else
        throw AgentVoiceSynthesisError.unsupportedPlatform
        #endif
    }
}

public enum AgentVoiceSynthesisError: LocalizedError, Sendable, Equatable {
    case unsupportedPlatform
    case missingConfiguration
    case emptyText
    case missingOutput(String)
    case synthesisFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Voice output is available only on macOS."
        case .missingConfiguration:
            return "Voice output is not configured. Run zen --setup and enable voice tools."
        case .emptyText:
            return "Voice output needs text to speak."
        case let .missingOutput(path):
            return "Voice synthesis did not produce an audio file: \(path)"
        case let .synthesisFailed(detail):
            return "Voice synthesis failed: \(detail)"
        }
    }
}

#if os(macOS)
import AVFoundation

private enum AgentVoiceSpeechWriter {
    static func write(
        text: String,
        language: String?,
        speaker: String?,
        to outputURL: URL
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let synthesizer = AVSpeechSynthesizer()
            let utterance = AVSpeechUtterance(string: text)
            if let voice = resolveVoice(speaker: speaker, language: language) {
                utterance.voice = voice
            }

            let resumeState = SynthesisResumeGuard()
            var audioFile: AVAudioFile?

            synthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                    return
                }
                if pcmBuffer.frameLength == 0 {
                    // End-of-stream marker.
                    if resumeState.consume() {
                        if audioFile == nil {
                            continuation.resume(throwing: AgentVoiceSynthesisError.synthesisFailed(
                                "No audio was produced."
                            ))
                        } else {
                            continuation.resume(returning: ())
                        }
                    }
                    return
                }

                do {
                    if audioFile == nil {
                        audioFile = try AVAudioFile(
                            forWriting: outputURL,
                            settings: pcmBuffer.format.settings,
                            commonFormat: pcmBuffer.format.commonFormat,
                            interleaved: pcmBuffer.format.isInterleaved
                        )
                    }
                    try audioFile?.write(from: pcmBuffer)
                } catch {
                    if resumeState.consume() {
                        continuation.resume(throwing: AgentVoiceSynthesisError.synthesisFailed(
                            error.localizedDescription
                        ))
                    }
                }
            }
        }
    }

    private static func resolveVoice(
        speaker: String?,
        language: String?
    ) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let speaker = speaker?.nilIfBlank,
           let match = voices.first(where: {
               $0.name.caseInsensitiveCompare(speaker) == .orderedSame
           }) {
            return match
        }
        if let language = language?.nilIfBlank {
            let prefix = language.lowercased()
            if let match = voices.first(where: {
                $0.language.lowercased().hasPrefix(prefix)
            }) {
                return match
            }
            return AVSpeechSynthesisVoice(language: language)
        }
        return nil
    }
}

private final class SynthesisResumeGuard: Sendable {
    private let didResume = Mutex(false)

    func consume() -> Bool {
        didResume.withLock { didResume in
            guard !didResume else { return false }
            didResume = true
            return true
        }
    }
}
#endif
