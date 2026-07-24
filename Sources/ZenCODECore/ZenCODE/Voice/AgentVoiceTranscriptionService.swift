//
//  AgentVoiceTranscriptionService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation
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

        // Coordinator that strongly retains the recognition task (SFSpeechRecognizer
        // only keeps a weak reference, so without retention the task is deallocated and
        // cancelled as soon as this closure returns, yielding an empty transcript).
        // It also serializes the continuation, the task and the terminal state in a
        // single mutex, guarantees exactly-once resume, propagates cooperative
        // cancellation to SFSpeechRecognitionTask.cancel(), and breaks the
        // holder<->task<->callback retain cycle on completion.
        let state = RecognitionContinuationState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, any Error>) in
                // install(continuation:) returns false when cancellation (or another
                // terminal outcome) already happened: the continuation is resumed
                // exactly once inside the call and no recognition task is created,
                // avoiding a clear-before-install / leaked-task race.
                guard state.install(continuation: continuation) else { return }

                let task = recognizer.recognitionTask(with: request) { result, error in
                    state.handleResult(result, error: error)
                }
                state.install(task: task)
            }
        } onCancel: {
            state.cancelAndFinish(throwing: CancellationError())
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

#if canImport(Speech)
/// Thread-safe coordinator for a single speech recognition continuation.
///
/// Owns the continuation, the retained `SFSpeechRecognitionTask`, and the terminal
/// state inside a single `Mutex`, guaranteeing exactly-once resume across the Speech
/// callback queue, the calling task, and cooperative cancellation. Resume calls and
/// `SFSpeechRecognitionTask.cancel()` are always performed outside the lock to keep
/// critical sections minimal and avoid reentrancy.
///
/// `@unchecked Sendable` is required because `SFSpeechRecognitionTask` is an
/// Objective-C type that is not itself `Sendable`; however every read and write of
/// the stored task and continuation is serialized through the mutex, so the
/// unchecked conformance is sound. (The previous `RecognitionTaskHolder` exposed the
/// same field as a plain `var` with no synchronization, which was a real data race.)
private final class RecognitionContinuationState: @unchecked Sendable {
    private enum Status: Sendable {
        /// Continuation not installed yet.
        case waitingForContinuation
        /// Continuation installed; recognition in progress.
        case active
        /// Terminal: an outcome has been delivered. No further action is allowed.
        case terminal
    }

    private struct Storage {
        var status: Status = .waitingForContinuation
        var continuation: CheckedContinuation<String, any Error>?
        var task: SFSpeechRecognitionTask?
        /// Cancellation arrived before the continuation was available. Stored so the
        /// subsequent `install(continuation:)` resumes immediately without creating a
        /// recognition task (cancel-before-install).
        var pendingCancellationError: (any Error)?
    }

    /// A resume operation extracted under the lock and executed after it returns.
    private enum PendingResume {
        case none
        case value(CheckedContinuation<String, any Error>, String)
        case thrown(CheckedContinuation<String, any Error>, any Error)

        func perform() {
            switch self {
            case .none:
                break
            case let .value(continuation, value):
                continuation.resume(returning: value)
            case let .thrown(continuation, error):
                continuation.resume(throwing: error)
            }
        }
    }

    // `SFSpeechRecognitionTask` is an Objective-C type that is not `Sendable`, so the
    // storage cannot satisfy `Mutex`'s `Sendable` requirement (nor the `sending`
    // semantics of `Mutex.withLock`). A manual `NSLock` serializes every read and
    // write of the task/continuation instead, making the unchecked `Sendable`
    // conformance sound. (The previous `RecognitionTaskHolder` exposed the same
    // field as a plain `var` with no synchronization, which was a real data race.)
    private let lock = NSLock()
    private var storage = Storage()

    /// Installs the continuation.
    ///
    /// - Returns: `true` when recognition should proceed (the caller must then create
    ///   the recognition task and call `install(task:)`). Returns `false` when the
    ///   operation already reached a terminal state before installation (e.g.
    ///   cancellation): the continuation is resumed exactly once inside this call and
    ///   no task must be created.
    func install(continuation: CheckedContinuation<String, any Error>) -> Bool {
        var pendingResume: PendingResume = .none
        lock.lock()
        var proceed = false
        switch storage.status {
        case .waitingForContinuation:
            if let error = storage.pendingCancellationError {
                // Cancel-before-install: resume immediately, never create a task.
                storage.status = .terminal
                storage.pendingCancellationError = nil
                pendingResume = .thrown(continuation, error)
                proceed = false
            } else {
                storage.status = .active
                storage.continuation = continuation
                proceed = true
            }
        case .active, .terminal:
            // Defensive: continuation handed over twice, or state already terminal.
            pendingResume = .thrown(continuation, CancellationError())
            proceed = false
        }
        lock.unlock()
        pendingResume.perform()
        return proceed
    }

    /// Installs the recognition task so it can be cancelled and its retain cycle
    /// broken on completion. If the state became terminal between
    /// `install(continuation:)` and this call (e.g. cancellation arrived), the task
    /// is cancelled to avoid a leaked or lingering recognition.
    func install(task: SFSpeechRecognitionTask) {
        var taskToCancel: SFSpeechRecognitionTask?
        lock.lock()
        switch storage.status {
        case .active, .waitingForContinuation:
            storage.task = task
        case .terminal:
            taskToCancel = task
        }
        lock.unlock()
        taskToCancel?.cancel()
    }

    /// Handles a recognition callback. Only the first final outcome (error or final
    /// result) resumes the continuation; non-final partial results and any callback
    /// received after a terminal state are ignored.
    func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        let isFinal = error != nil || (result?.isFinal ?? false)
        guard isFinal else { return }

        var pendingResume: PendingResume = .none
        lock.lock()
        if storage.status == .active {
            storage.status = .terminal
            if let continuation = storage.continuation {
                // Drop the references to break the holder<->task<->callback retain cycle.
                storage.continuation = nil
                storage.task = nil
                if let error {
                    pendingResume = .thrown(
                        continuation,
                        AgentVoiceTranscriptionError.recognitionFailed(error.localizedDescription)
                    )
                } else if let result {
                    pendingResume = .value(continuation, result.bestTranscription.formattedString)
                }
            }
        }
        lock.unlock()
        pendingResume.perform()
    }

    /// Cooperative cancellation handler. Atomically extracts the continuation and the
    /// recognition task (if any), cancels the Speech task, and resumes the
    /// continuation with `error` exactly once. If the continuation is not installed
    /// yet (cancel-before-install), the error is stashed and resumed by
    /// `install(continuation:)`.
    func cancelAndFinish(throwing error: any Error) {
        var pendingResume: PendingResume = .none
        var taskToCancel: SFSpeechRecognitionTask?
        lock.lock()
        switch storage.status {
        case .waitingForContinuation:
            // No continuation to resume yet; defer until install(continuation:).
            if storage.pendingCancellationError == nil {
                storage.pendingCancellationError = error
            }
        case .active:
            storage.status = .terminal
            if let continuation = storage.continuation {
                storage.continuation = nil
                pendingResume = .thrown(continuation, error)
            }
            taskToCancel = storage.task
            storage.task = nil
        case .terminal:
            break
        }
        lock.unlock()
        // Cancel the Speech task outside the lock; cancel() is safe to call from any
        // thread and the callback queue may re-enter the lock afterwards.
        taskToCancel?.cancel()
        pendingResume.perform()
    }
}
#endif

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
