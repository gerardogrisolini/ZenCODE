//
//  AgentVoiceTranscriptionService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//
import Foundation
#if canImport(os)
import os
#endif
#if canImport(Speech)
import Speech
#endif

public typealias AgentVoiceToolProgress = @Sendable (String) async -> Void
public typealias AgentVoiceTranscriptionProgress = AgentVoiceToolProgress

public struct AgentVoiceAudioInput: Equatable, Sendable {
    public let fileURL: URL
    public let filename: String
    public let contentType: String?
    public let removeAfterUse: Bool

    public init(
        fileURL: URL,
        filename: String? = nil,
        contentType: String? = nil,
        removeAfterUse: Bool = false
    ) {
        self.fileURL = fileURL
        self.filename = filename?.nilIfBlank ?? fileURL.lastPathComponent.nilIfBlank ?? "voice.m4a"
        self.contentType = contentType?.nilIfBlank
        self.removeAfterUse = removeAfterUse
    }

    public func cleanup() {
        guard removeAfterUse else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

public actor AgentVoiceTranscriptionService {
    private let settings: AgentVoiceSettingsManifest?

    public init(
        settings: AgentVoiceSettingsManifest? = AgentSettingsManifestStore.load()?.voice
    ) {
        self.settings = settings
    }

    public func transcribe(
        _ audio: AgentVoiceAudioInput,
        progress: AgentVoiceTranscriptionProgress? = nil
    ) async throws -> String {
        defer {
            audio.cleanup()
        }

        guard let settings, settings.isConfigured else {
            throw AgentVoiceTranscriptionError.missingConfiguration
        }
        guard FileManager.default.fileExists(atPath: audio.fileURL.path) else {
            throw AgentVoiceTranscriptionError.missingAudioFile(audio.fileURL.path)
        }

        #if canImport(Speech)
        await progress?("Preparing speech recognizer")
        try await Self.requestAuthorization()

        let locale = Self.locale(for: settings.language)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw AgentVoiceTranscriptionError.unsupportedLanguage(locale.identifier)
        }
        guard recognizer.isAvailable else {
            throw AgentVoiceTranscriptionError.recognizerUnavailable
        }

        await progress?("Transcribing audio")
        let transcript = try await Self.recognize(
            fileURL: audio.fileURL,
            recognizer: recognizer
        )
        let output = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw AgentVoiceTranscriptionError.emptyTranscript
        }
        return output
        #else
        throw AgentVoiceTranscriptionError.unsupportedPlatform
        #endif
    }

    #if canImport(Speech)
    private static func requestAuthorization() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            guard status == .authorized else {
                throw AgentVoiceTranscriptionError.authorizationDenied
            }
        case .denied, .restricted:
            throw AgentVoiceTranscriptionError.authorizationDenied
        @unknown default:
            throw AgentVoiceTranscriptionError.authorizationDenied
        }
    }

    private static func recognize(
        fileURL: URL,
        recognizer: SFSpeechRecognizer
    ) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            let resumeState = ResumeGuard()
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if resumeState.consume() {
                        continuation.resume(throwing: AgentVoiceTranscriptionError.recognitionFailed(
                            error.localizedDescription
                        ))
                    }
                    return
                }
                guard let result, result.isFinal else {
                    return
                }
                if resumeState.consume() {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    private static func locale(for language: String?) -> Locale {
        guard let language = language?.nilIfBlank?.lowercased() else {
            return Locale(identifier: "en-US")
        }
        if let mapped = localeIdentifiersByLanguage[language] {
            return Locale(identifier: mapped)
        }
        return Locale(identifier: language)
    }

    private static let localeIdentifiersByLanguage: [String: String] = [
        "it": "it-IT",
        "en": "en-US",
        "es": "es-ES",
        "fr": "fr-FR",
        "de": "de-DE",
        "pt": "pt-BR",
        "ja": "ja-JP",
        "ko": "ko-KR",
        "zh": "zh-CN",
        "ru": "ru-RU"
    ]
    #endif
}

/// Ensures a single resume of the recognition continuation.
private final class ResumeGuard: Sendable {
    private let didResume = OSAllocatedUnfairLock(initialState: false)

    func consume() -> Bool {
        didResume.withLock { didResume in
            guard !didResume else { return false }
            didResume = true
            return true
        }
    }
}

public enum AgentVoiceTranscriptionError: LocalizedError, Sendable, Equatable {
    case missingConfiguration
    case missingAudioFile(String)
    case emptyTranscript
    case unsupportedPlatform
    case unsupportedLanguage(String)
    case recognizerUnavailable
    case authorizationDenied
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Voice input is not configured. Run zen --setup and enable voice input."
        case let .missingAudioFile(path):
            return "Voice audio file does not exist: \(path)"
        case .emptyTranscript:
            return "Voice transcription returned no text."
        case .unsupportedPlatform:
            return "Voice input is available only on Apple platforms."
        case let .unsupportedLanguage(identifier):
            return "Voice transcription does not support the language \(identifier)."
        case .recognizerUnavailable:
            return "The macOS speech recognizer is not available right now. Make sure the language is installed in System Settings."
        case .authorizationDenied:
            return "Speech recognition permission was denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case let .recognitionFailed(detail):
            return "Voice transcription failed: \(detail)"
        }
    }
}
