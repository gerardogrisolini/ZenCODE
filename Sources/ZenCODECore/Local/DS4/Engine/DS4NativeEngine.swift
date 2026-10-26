//
//  DS4NativeEngine.swift
//  ZenCODE
//
//  `DS4Engine` backed by `libzencode-ds4`: every C call runs on one dedicated
//  `DS4EngineThread` in FIFO order (open included), the caller awaits it
//  through a checked continuation. C handles stay inside
//  `DS4NativeEngineCore`. Task cancellation sets a `DS4CancellationFlag`
//  (Synchronization.Atomic) polled by the DS4 cancel callback.
//

import Foundation

final class DS4NativeEngine: DS4Engine {
    let info: DS4EngineInfo
    let configuration: DS4EngineConfiguration
    private let library: DS4EngineLibrary
    private let thread: DS4EngineThread
    private let core: DS4NativeEngineCore
    /// Identifies this instance in the transcripts it prepares.
    private let instanceToken = DS4EngineInstanceToken.next()

    private init(
        info: DS4EngineInfo,
        configuration: DS4EngineConfiguration,
        library: DS4EngineLibrary,
        thread: DS4EngineThread,
        core: DS4NativeEngineCore
    ) {
        self.info = info
        self.configuration = configuration
        self.library = library
        self.thread = thread
        self.core = core
    }

    deinit {
        // Not closed explicitly: free the sessions and the engine on its
        // thread after the queued jobs, then let the thread exit.
        thread.submit { [core] in core.close() }
        thread.stop()
    }

    /// Loads the library of `configuration` and opens the engine on a new
    /// engine thread. Before the open `onStatus` receives a short notice,
    /// afterwards the last lines of the DS4 open log. Not cancellable (DS4
    /// cannot interrupt a model load).
    ///
    /// - Throws: library errors (`libraryUnavailable`, `abiMismatch`,
    ///   `missingSymbol`), `instanceLocked`, `invalidOption`, `openFailed`
    ///   (with the DS4 stderr tail), ...
    static func open(
        configuration: DS4EngineConfiguration,
        onStatus: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> DS4NativeEngine {
        let library = try DS4EngineLibrary.load(at: configuration.libraryURL, buildHint: configuration.buildHint)
        return try await open(configuration: configuration, library: library, onStatus: onStatus)
    }

    static func open(
        configuration: DS4EngineConfiguration,
        library: DS4EngineLibrary,
        onStatus: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> DS4NativeEngine {
        if let modelPath = configuration.modelPath {
            await onStatus("Opening DS4 engine for \(URL(fileURLWithPath: modelPath).lastPathComponent)")
        }
        let thread = DS4EngineThread(name: "ZenCODE DS4 engine")
        let symbols = library.symbols
        let opened: DS4NativeEngineCore.OpenResult
        do {
            opened = try await withCheckedThrowingContinuation { continuation in
                let accepted = thread.submit {
                    continuation.resume(with: Result {
                        try DS4NativeEngineCore.open(symbols: symbols, configuration: configuration)
                    })
                }
                if !accepted {
                    continuation.resume(throwing: DS4EngineError.engineClosed)
                }
            }
        } catch {
            thread.stop()
            throw error
        }
        for line in opened.logLines {
            await onStatus(line)
        }
        return DS4NativeEngine(
            info: opened.info,
            configuration: configuration,
            library: library,
            thread: thread,
            core: opened.core
        )
    }

    // MARK: Thread hops

    /// Runs `body` on the engine thread; throws `engineClosed` when the
    /// thread no longer accepts jobs.
    private func perform<Value: Sendable>(
        _ body: @escaping @Sendable (DS4NativeEngineCore) throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let accepted = thread.submit { [core] in
                continuation.resume(with: Result { try body(core) })
            }
            if !accepted {
                continuation.resume(throwing: DS4EngineError.engineClosed)
            }
        }
    }

    /// `perform` with a cancellation flag set when the calling task is cancelled.
    private func performCancellable<Value: Sendable>(
        _ body: @escaping @Sendable (DS4NativeEngineCore, DS4CancellationFlag) throws -> Value
    ) async throws -> Value {
        let flag = DS4CancellationFlag()
        return try await withTaskCancellationHandler {
            try await perform { core in try body(core, flag) }
        } onCancel: {
            flag.cancel()
        }
    }

    // MARK: DS4Engine

    func tokenCount(of transcript: [DS4TranscriptOperation]) async throws -> Int {
        try await perform { core in try core.tokenCount(of: transcript) }
    }

    func prepare(transcript: [DS4TranscriptOperation]) async throws -> DS4PreparedTranscript {
        let ownerToken = instanceToken
        let thread = thread
        return try await perform { core in
            try core.prepare(transcript, ownerToken: ownerToken, thread: thread)
        }
    }

    func renderText(of transcript: [DS4TranscriptOperation]) async throws -> String {
        try await perform { core in try core.renderText(of: transcript) }
    }

    func thinkMode(parseLevel: String) -> Int32? {
        library.thinkMode(parseLevel: parseLevel)
    }

    func thinkMode(forContext mode: Int32, contextSize: Int) async -> Int32 {
        (try? await perform { core in core.thinkMode(forContext: mode, contextSize: contextSize) }) ?? mode
    }

    func sync(
        sessionID: String,
        transcript: [DS4TranscriptOperation],
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> DS4SyncResult {
        try await performCancellable { core, flag in
            let context = DS4NativeCallbackContext(cancelFlag: flag, onProgress: onProgress)
            return try core.sync(sessionID: sessionID, transcript: transcript, context: context)
        }
    }

    func sync(
        sessionID: String,
        prepared: DS4PreparedTranscript,
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> DS4SyncResult {
        guard prepared.isOwned(byEngineWithToken: instanceToken),
              let buffer = prepared.payload as? DS4NativeTokenBuffer,
              !buffer.isReleased else {
            // Prepared by another engine instance (or already released): the
            // token ids are not ours, tokenize the operations again.
            return try await sync(sessionID: sessionID, transcript: prepared.operations, onProgress: onProgress)
        }
        return try await performCancellable { core, flag in
            let context = DS4NativeCallbackContext(cancelFlag: flag, onProgress: onProgress)
            return try core.sync(sessionID: sessionID, buffer: buffer, context: context)
        }
    }

    func generate(
        sessionID: String,
        maxTokens: Int,
        thinkMode: Int32,
        sampling: DS4SamplingParameters,
        onText: @escaping @Sendable (String) -> DS4EmitDecision
    ) async throws -> DS4GenerateResult {
        try await performCancellable { core, flag in
            let context = DS4NativeCallbackContext(cancelFlag: flag, onText: onText)
            return try core.generate(
                sessionID: sessionID,
                maxTokens: maxTokens,
                thinkMode: thinkMode,
                sampling: sampling,
                context: context
            )
        }
    }

    func stats(sessionID: String) async -> DS4SessionStats {
        (try? await perform { core in core.stats(sessionID: sessionID) }) ?? .empty
    }

    func liveSessionCount() async -> Int {
        (try? await perform { core in core.liveSessionCount }) ?? 0
    }

    func setPower(sessionID: String, percent: Int) async throws {
        try await perform { core in try core.setPower(sessionID: sessionID, percent: percent) }
    }

    func setSteeringFFN(sessionID: String, scale: Double) async throws {
        try await perform { core in try core.setSteeringFFN(sessionID: sessionID, scale: scale) }
    }

    func saveCheckpoint(sessionID: String, to url: URL, trailer: Data?) async throws -> DS4CheckpointSaveOutcome {
        try await perform { core in try core.saveCheckpoint(sessionID: sessionID, to: url, trailer: trailer) }
    }

    func loadCheckpoint(sessionID: String, from url: URL) async throws -> Data? {
        try await performCancellable { core, flag in
            try core.loadCheckpoint(sessionID: sessionID, from: url, context: DS4NativeCallbackContext(cancelFlag: flag))
        }
    }

    func releaseSession(_ sessionID: String) async {
        try? await perform { core in core.releaseSession(sessionID) }
    }

    func close() async {
        try? await perform { core in core.close() }
        thread.stop()
    }
}
