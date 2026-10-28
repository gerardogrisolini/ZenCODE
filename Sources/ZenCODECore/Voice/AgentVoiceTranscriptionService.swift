//
//  AgentVoiceTranscriptionService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation
import ToolCore
#if canImport(Speech)
import AVFoundation
import Speech
#endif

public typealias AgentVoiceTranscriptionProgress = @Sendable (String) async -> Void

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
    /// Language of the macOS recognizer, e.g. `it`. Linux recognizes the
    /// spoken language by itself.
    private let languageCode: String
    /// The sherpa-onnx files of `/setup` > Voice mode that transcribe on Linux.
    private let voiceInstallation: SherpaOnnxVoiceInstallation

    /// Reads the voice settings and the response language from `manifest`,
    /// by default the saved settings.
    public init(
        manifest: AgentSettingsManifest? = AgentSettingsManifestStore.load()
    ) {
        self.init(
            settings: manifest?.voice,
            languageCode: VoiceLanguage.resolvedCode(manifest: manifest)
        )
    }

    public init(
        settings: AgentVoiceSettingsManifest?,
        languageCode: String
    ) {
        self.init(
            settings: settings,
            languageCode: languageCode,
            voiceInstallation: .standard()
        )
    }

    init(
        settings: AgentVoiceSettingsManifest?,
        languageCode: String,
        voiceInstallation: SherpaOnnxVoiceInstallation
    ) {
        self.settings = settings
        self.languageCode = languageCode
        self.voiceInstallation = voiceInstallation
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

        let locale = Self.locale(for: languageCode)
        guard let model = await AppleSpeechModel.resolve(for: locale) else {
            throw AgentVoiceTranscriptionError.unsupportedLanguage(locale.identifier)
        }
        let module = model.makeModule(for: .file)
        do {
            try await AppleSpeechModel.installAssets(for: [module.module]) {
                await progress?("Downloading the speech recognition model")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentVoiceTranscriptionError.speechModelDownloadFailed(
                language: model.locale.identifier,
                detail: error.localizedDescription
            )
        }

        await progress?("Transcribing audio")
        let transcript = try await Self.recognize(fileURL: audio.fileURL, module: module)
        let output = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw AgentVoiceTranscriptionError.emptyTranscript
        }
        return output
        #elseif os(Linux)
        await progress?("Transcribing audio")
        let transcriber = try SherpaOnnxFileTranscriber.make(
            installation: voiceInstallation,
            audio: audio
        )
        return try await transcriber.transcribe(audio)
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

    /// Transcribes the whole file on the Mac: the final results, trimmed and
    /// joined by a space. Cancelling the calling task cancels the analysis
    /// and throws `CancellationError`.
    private static func recognize(
        fileURL: URL,
        module: AppleSpeechModule
    ) async throws -> String {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw AgentVoiceTranscriptionError.recognitionFailed(error.localizedDescription)
        }
        let analyzer = SpeechAnalyzer(modules: [module.module], options: AppleSpeechModel.analyzerOptions)
        let results = module.results()
        let collector = Task { () throws -> [String] in
            var texts: [String] = []
            do {
                for try await result in results where result.isFinal {
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        texts.append(text)
                    }
                }
            } catch is CancellationError {
                // The analysis was cancelled: an empty file, or the caller.
            }
            return texts
        }

        do {
            // Cancelled before it got ready, an analyzer never ends its
            // results: cancellation is honored once it is prepared.
            try await analyzer.prepareToAnalyze(in: nil)
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                collector.cancel()
                Task {
                    await analyzer.cancelAndFinishNow()
                }
            }
            let texts = try await collector.value
            try Task.checkCancellation()
            return texts.joined(separator: " ")
        } catch {
            // Also ends the results of an analyzer that never got ready.
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw AgentVoiceTranscriptionError.recognitionFailed(error.localizedDescription)
        }
    }
    #endif

    /// Maps a voice language code to the recognizer locale. Platform neutral:
    /// the terminal's dictation mode resolves its language with it as well.
    static func locale(for language: String?) -> Locale {
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
}

public enum AgentVoiceTranscriptionError: LocalizedError, Sendable, Equatable {
    case missingConfiguration
    case missingAudioFile(String)
    case emptyTranscript
    case unsupportedPlatform
    case unsupportedLanguage(String)
    case speechModelDownloadFailed(language: String, detail: String)
    case authorizationDenied
    case recognitionFailed(String)

    /// Telegram is paired but its voice-message transcription is off, e.g.
    /// on Linux settings saved before transcription existed there. Saving the
    /// Telegram section again turns it on without a new pairing.
    public static let notEnabledMessage = "Voice-message transcription is off. Run /setup in zen and open the Telegram section again (you can keep the current pairing) to turn it on."

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return Self.notEnabledMessage
        case let .missingAudioFile(path):
            return "Voice audio file does not exist: \(path)"
        case .emptyTranscript:
            return "Voice transcription returned no text."
        case .unsupportedPlatform:
            return "Voice input is available only on macOS and Linux."
        case let .unsupportedLanguage(identifier):
            return "Voice transcription does not support the language \(identifier)."
        case let .speechModelDownloadFailed(language, detail):
            return "The speech recognition model for \(language) could not be downloaded (\(detail)). Check the network connection and send the voice message again."
        case .authorizationDenied:
            return "Speech recognition permission was denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case let .recognitionFailed(detail):
            return "Voice transcription failed: \(detail)"
        }
    }
}
