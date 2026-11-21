//
//  AppleSpeechRecognition.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/10/26.
//

#if canImport(Speech)
import AVFoundation
import Foundation
import Speech

/// The on-device model that recognizes a language on macOS, shared by the
/// terminal's voice mode and the transcription of Telegram voice messages.
/// `SpeechTranscriber` is preferred; `DictationTranscriber` covers the
/// languages it does not support.
enum AppleSpeechModel: Sendable, Equatable {
    case speechTranscriber(Locale)
    case dictationTranscriber(Locale)

    /// What the recognition is for: live microphone dictation or a whole file.
    enum Usage: Sendable, Equatable {
        case live
        case file
    }

    /// Keeps the model loaded between the analyzers of one session.
    static let analyzerOptions = SpeechAnalyzer.Options(
        priority: .userInitiated,
        modelRetention: .lingering
    )

    /// The locale the model recognizes, as resolved by the Speech framework.
    var locale: Locale {
        switch self {
        case let .speechTranscriber(locale), let .dictationTranscriber(locale):
            return locale
        }
    }

    /// The model that recognizes `locale`, or `nil` when neither model
    /// supports it.
    static func resolve(for locale: Locale) async -> AppleSpeechModel? {
        let isSpeechTranscriberAvailable = SpeechTranscriber.isAvailable
        let speechTranscriberLocale = isSpeechTranscriberAvailable
            ? await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            : nil
        let dictationTranscriberLocale = speechTranscriberLocale == nil
            ? await DictationTranscriber.supportedLocale(equivalentTo: locale)
            : nil
        return resolve(
            speechTranscriberLocale: speechTranscriberLocale,
            dictationTranscriberLocale: dictationTranscriberLocale,
            isSpeechTranscriberAvailable: isSpeechTranscriberAvailable
        )
    }

    /// Prefers `SpeechTranscriber` when it is available and supports the
    /// language, otherwise `DictationTranscriber` when it supports it.
    static func resolve(
        speechTranscriberLocale: Locale?,
        dictationTranscriberLocale: Locale?,
        isSpeechTranscriberAvailable: Bool
    ) -> AppleSpeechModel? {
        if isSpeechTranscriberAvailable, let speechTranscriberLocale {
            return .speechTranscriber(speechTranscriberLocale)
        }
        if let dictationTranscriberLocale {
            return .dictationTranscriber(dictationTranscriberLocale)
        }
        return nil
    }

    /// A new module configured for `usage`. Live dictation reports volatile
    /// results and closes a segment at each pause; a file reports only final
    /// results.
    func makeModule(for usage: Usage) -> AppleSpeechModule {
        switch (self, usage) {
        case let (.speechTranscriber(locale), .live):
            return AppleSpeechModule(SpeechTranscriber(locale: locale, preset: .progressiveTranscription))
        case let (.speechTranscriber(locale), .file):
            return AppleSpeechModule(SpeechTranscriber(locale: locale, preset: .transcription))
        case let (.dictationTranscriber(locale), .live):
            // Without frequent finalization nothing is final before the end
            // of the input.
            return AppleSpeechModule(DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: []
            ))
        case let (.dictationTranscriber(locale), .file):
            return AppleSpeechModule(DictationTranscriber(locale: locale, preset: .longDictation))
        }
    }

    /// Downloads and installs what `modules` still miss; returns at once when
    /// everything is installed. `onDownload` runs before a download starts.
    /// Cancelling the calling task cancels the download and throws
    /// `CancellationError`.
    static func installAssets(
        for modules: [any SpeechModule],
        onDownload: @Sendable () async -> Void
    ) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            return
        }
        await onDownload()
        do {
            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: {
                request.progress.cancel()
            }
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}

/// One recognition result of a module, with its text as plain characters.
struct AppleSpeechResult: Sendable, Equatable {
    let text: String
    /// Final results close the text recognized since the previous final one;
    /// volatile results are replaced by the next result.
    let isFinal: Bool
}

/// A speech module for one analyzer together with its results, mapped to
/// `AppleSpeechResult` without exposing the module's concrete type.
struct AppleSpeechModule: Sendable {
    let module: any SpeechModule
    private let relay: @Sendable () -> AsyncThrowingStream<AppleSpeechResult, any Error>

    init(_ transcriber: SpeechTranscriber) {
        self.init(module: transcriber) { String($0.text.characters) }
    }

    init(_ transcriber: DictationTranscriber) {
        self.init(module: transcriber) { String($0.text.characters) }
    }

    private init<Module: SpeechModule>(
        module: Module,
        text: @escaping @Sendable (Module.Result) -> String
    ) {
        self.module = module
        relay = {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await result in module.results {
                            continuation.yield(AppleSpeechResult(text: text(result), isFinal: result.isFinal))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }
    }

    /// Starts relaying the module's results, in order. Call it once, before
    /// the analyzer starts; the stream ends with the analysis.
    func results() -> AsyncThrowingStream<AppleSpeechResult, any Error> {
        relay()
    }
}
#endif
