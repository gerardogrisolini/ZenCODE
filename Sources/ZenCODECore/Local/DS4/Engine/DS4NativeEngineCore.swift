//
//  DS4NativeEngineCore.swift
//  ZenCODE
//
//  Thread-confined state of `DS4NativeEngine`: the C engine handle, the
//  session pool and every shim call. Only ever used from the engine's
//  `DS4EngineThread` (hence `@unchecked Sendable`: it is handed to the thread,
//  never shared). C handles never leave this type.
//

import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Cancellation flag set by `withTaskCancellationHandler` and polled by the
/// DS4 cancel callback on the engine thread.
final class DS4CancellationFlag: Sendable {
    private let state = Atomic<Bool>(false)

    func cancel() {
        state.store(true, ordering: .relaxed)
    }

    var isCancelled: Bool {
        state.load(ordering: .relaxed)
    }
}

/// `void *ud` of the C callbacks for one shim call (engine thread only).
final class DS4NativeCallbackContext {
    let cancelFlag: DS4CancellationFlag
    private let onProgress: (@Sendable (String, Int, Int) -> Void)?
    private let onText: (@Sendable (String) -> DS4EmitDecision)?
    private var decoder = DS4UTF8StreamDecoder()
    private(set) var text = ""

    init(
        cancelFlag: DS4CancellationFlag,
        onProgress: (@Sendable (String, Int, Int) -> Void)? = nil,
        onText: (@Sendable (String) -> DS4EmitDecision)? = nil
    ) {
        self.cancelFlag = cancelFlag
        self.onProgress = onProgress
        self.onText = onText
    }

    fileprivate func progress(event: String, current: Int, total: Int) {
        onProgress?(event, current, total)
    }

    fileprivate func emit(_ bytes: UnsafeBufferPointer<UInt8>) -> Int32 {
        let chunk = decoder.consume(bytes)
        text += chunk
        return onText?(chunk).rawValue ?? DS4EngineABI.EmitFlag.continue
    }

    /// Flushes undecodable trailing bytes after generation (result ignored).
    fileprivate func finishText() {
        let tail = decoder.finish()
        guard !tail.isEmpty else {
            return
        }
        text += tail
        _ = onText?(tail)
    }

    fileprivate func withUserData<Result>(_ body: (UnsafeMutableRawPointer) throws -> Result) rethrows -> Result {
        try withExtendedLifetime(self) {
            try body(Unmanaged.passUnretained(self).toOpaque())
        }
    }

    fileprivate static func from(_ userData: UnsafeMutableRawPointer?) -> DS4NativeCallbackContext? {
        userData.map { Unmanaged<DS4NativeCallbackContext>.fromOpaque($0).takeUnretainedValue() }
    }
}

/// C callbacks of the shim (capture-free, so they convert to C function pointers).
private enum DS4NativeCallbacks {
    static let progress: DS4EngineABI.ProgressFunction = { userData, event, current, total in
        DS4NativeCallbackContext.from(userData)?.progress(
            event: event.map { String(cString: $0) } ?? "",
            current: Int(current),
            total: Int(total)
        )
    }

    static let cancel: DS4EngineABI.CancelFunction = { userData in
        DS4NativeCallbackContext.from(userData)?.cancelFlag.isCancelled == true ? 1 : 0
    }

    static let emit: DS4EngineABI.EmitFunction = { userData, bytes, length in
        guard let context = DS4NativeCallbackContext.from(userData) else {
            return DS4EngineABI.EmitFlag.continue
        }
        guard let bytes, length > 0 else {
            return context.emit(UnsafeBufferPointer(start: nil, count: 0))
        }
        let start = UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self)
        return context.emit(UnsafeBufferPointer(start: start, count: length))
    }
}

final class DS4NativeEngineCore: @unchecked Sendable {
    struct OpenResult: @unchecked Sendable {
        let core: DS4NativeEngineCore
        let info: DS4EngineInfo
        /// Last non-empty lines of the DS4 stderr captured by `engine_open`.
        let logLines: [String]
    }

    /// Lines of the open log forwarded to the status callback.
    static let forwardedLogLines = 16

    private let symbols: DS4EngineSymbols
    private let contextSize: Int
    private let hasVision: Bool
    private var engine: UnsafeMutableRawPointer?
    private var pool: DS4SessionPool<UnsafeMutableRawPointer>

    private init(
        symbols: DS4EngineSymbols,
        engine: UnsafeMutableRawPointer,
        contextSize: Int,
        sessionCapacity: Int,
        hasVision: Bool
    ) {
        self.symbols = symbols
        self.engine = engine
        self.contextSize = contextSize
        self.hasVision = hasVision
        self.pool = DS4SessionPool(capacity: sessionCapacity)
    }

    // MARK: Open / close

    /// `zencode_ds4_engine_open` with the configuration's effective options.
    static func open(symbols: DS4EngineSymbols, configuration: DS4EngineConfiguration) throws -> OpenResult {
        var handle: UnsafeMutableRawPointer?
        let options = configuration.effectiveOptions.map(\.keyValue)
        let rc = withCStringArray(options) { values, count in
            symbols.engineOpen(values, count, &handle)
        }
        let log = cString(symbols.engineOpenLog())
        let logLines = log
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard rc == DS4EngineABI.ok, let handle else {
            var message = cString(symbols.lastError())
            if let lastLine = logLines.last, !message.contains(lastLine) {
                message += message.isEmpty ? lastLine : " (last DS4 output: \(lastLine))"
            }
            throw DS4EngineError(code: rc == DS4EngineABI.ok ? DS4EngineABI.ErrorCode.engineOpen : rc, message: message)
        }

        func value(_ function: DS4EngineABI.EngineInt32Function) throws -> Int32 {
            let result = function(handle)
            if result < 0 {
                throw DS4EngineError(code: result, message: cString(symbols.engineLastError(handle)))
            }
            return result
        }
        do {
            let info = DS4EngineInfo(
                modelName: cString(symbols.engineModelName(handle)),
                modelID: try value(symbols.engineModelID),
                routedQuantBits: try value(symbols.engineRoutedQuantBits),
                hasVision: try value(symbols.engineHasVision) != 0,
                toolSyntaxID: try value(symbols.engineToolSyntax),
                mtpDraftTokens: try value(symbols.engineMTPDraftTokens),
                contextSize: configuration.contextSize
            )
            let core = DS4NativeEngineCore(
                symbols: symbols,
                engine: handle,
                contextSize: configuration.contextSize,
                sessionCapacity: configuration.sessionCapacity,
                hasVision: info.hasVision
            )
            return OpenResult(core: core, info: info, logLines: Array(logLines.suffix(forwardedLogLines)))
        } catch {
            _ = symbols.engineClose(handle)
            throw error
        }
    }

    var isOpen: Bool {
        engine != nil
    }

    /// Frees every session, then closes the engine. Idempotent.
    func close() {
        for session in pool.removeAll() {
            symbols.sessionFree(session)
        }
        guard let engine else {
            return
        }
        // Every session was freed above, so ERR_BUSY cannot happen.
        _ = symbols.engineClose(engine)
        self.engine = nil
    }

    // MARK: Errors

    private func requireEngine() throws -> UnsafeMutableRawPointer {
        guard let engine else {
            throw DS4EngineError.engineClosed
        }
        return engine
    }

    /// Error for a failed call: engine-bound message first, thread-local one as fallback.
    private func failure(_ code: Int32) -> DS4EngineError {
        var message = engine.map { cString(symbols.engineLastError($0)) } ?? ""
        if message.isEmpty {
            message = cString(symbols.lastError())
        }
        return DS4EngineError(code: code, message: message)
    }

    private func check(_ rc: Int32) throws {
        if rc < 0 {
            throw failure(rc)
        }
    }

    // MARK: Transcript

    /// Builds a token buffer from `transcript` (caller frees it with
    /// `tokensFree`). `afterEachOperation` runs after every operation with the
    /// buffer (token count per operation).
    private func makeTokens(
        _ transcript: [DS4TranscriptOperation],
        afterEachOperation: ((UnsafeMutableRawPointer) throws -> Void)? = nil
    ) throws -> UnsafeMutableRawPointer {
        let engine = try requireEngine()
        guard let tokens = symbols.tokensNew() else {
            throw DS4EngineError.outOfMemory("cannot allocate a DS4 token buffer")
        }
        do {
            for operation in transcript {
                try append(operation, to: tokens, engine: engine)
                try afterEachOperation?(tokens)
            }
            return tokens
        } catch {
            symbols.tokensFree(tokens)
            throw error
        }
    }

    private func append(
        _ operation: DS4TranscriptOperation,
        to tokens: UnsafeMutableRawPointer,
        engine: UnsafeMutableRawPointer
    ) throws {
        switch operation {
        case .begin:
            try check(symbols.chatBegin(engine, tokens))
        case .message(let role, let content):
            try check(role.withCString { role in
                content.withCString { content in
                    symbols.chatAppendMessage(engine, tokens, role, content)
                }
            })
        case .thinkPrefix(let mode):
            try check(symbols.chatAppendThinkPrefix(engine, tokens, mode))
        case .assistantPrefix(let mode):
            try check(symbols.chatAppendAssistantPrefix(engine, tokens, mode))
        case .renderedChat(let text):
            try check(text.withCString { symbols.tokenizeRenderedChat(engine, tokens, $0) })
        case .endOfSequence:
            try check(symbols.tokensPushEOS(engine, tokens))
        case .tokens(let ids):
            for id in ids {
                try check(symbols.tokensPush(tokens, id))
            }
        case .multimodalMessage(let role, let textParts, let imageFiles):
            try appendMultimodal(role: role, textParts: textParts, imageFiles: imageFiles, to: tokens, engine: engine)
        }
    }

    private func appendMultimodal(
        role: String,
        textParts: [String],
        imageFiles: [URL],
        to tokens: UnsafeMutableRawPointer,
        engine: UnsafeMutableRawPointer
    ) throws {
        guard textParts.count == imageFiles.count + 1 else {
            throw DS4EngineError.invalidArgument(
                "a multimodal message needs \(imageFiles.count + 1) text parts for \(imageFiles.count) image(s), got \(textParts.count)"
            )
        }
        var embeddings: [UnsafeMutableRawPointer?] = []
        defer {
            for embedding in embeddings {
                symbols.visionEmbeddingFree(embedding)
            }
        }
        for file in imageFiles {
            guard let embedding = file.path.withCString({ symbols.engineVisionEncodeFile(engine, $0) }) else {
                let message = cString(symbols.engineLastError(engine))
                throw hasVision
                    ? DS4EngineError.vision(message.isEmpty ? "cannot encode \(file.path)" : message)
                    : DS4EngineError.unsupported(message.isEmpty ? "the model has no vision projector" : message)
            }
            embeddings.append(embedding)
        }
        let rc = role.withCString { role in
            withCStringArray(textParts) { parts, partCount in
                embeddings.withUnsafeBufferPointer { images in
                    symbols.chatAppendMultimodalMessage(
                        engine, tokens, role, parts, partCount, images.baseAddress, images.count
                    )
                }
            }
        }
        try check(rc)
    }

    func tokenCount(of transcript: [DS4TranscriptOperation]) throws -> Int {
        let tokens = try makeTokens(transcript)
        defer { symbols.tokensFree(tokens) }
        let count = symbols.tokensLen(tokens)
        try check(count)
        return Int(count)
    }

    /// Tokenizes `transcript` and keeps the buffer (with the embeddings of its
    /// images) in the returned transcript, together with the token count after
    /// each operation. The buffer is freed through `thread` when the
    /// transcript is released.
    func prepare(
        _ transcript: [DS4TranscriptOperation],
        ownerToken: UInt64,
        thread: DS4EngineThread
    ) throws -> DS4PreparedTranscript {
        var counts: [Int] = []
        counts.reserveCapacity(transcript.count)
        let symbols = symbols
        let tokens = try makeTokens(transcript) { tokens in
            let count = symbols.tokensLen(tokens)
            if count < 0 {
                throw self.failure(count)
            }
            counts.append(Int(count))
        }
        let buffer = DS4NativeTokenBuffer(
            handle: tokens,
            free: { handle in symbols.tokensFree(handle.raw) },
            submit: { job in thread.submit(job) }
        )
        return DS4PreparedTranscript(
            operations: transcript,
            tokenCount: counts.last ?? 0,
            operationTokenCounts: counts,
            ownerToken: ownerToken,
            payload: buffer
        )
    }

    func renderText(of transcript: [DS4TranscriptOperation]) throws -> String {
        let engine = try requireEngine()
        let tokens = try makeTokens(transcript)
        defer { symbols.tokensFree(tokens) }
        var length = 0
        guard let text = symbols.renderTokensText(engine, tokens, &length) else {
            throw failure(DS4EngineABI.ErrorCode.invalidArgument)
        }
        defer { symbols.stringFree(text) }
        return text.withMemoryRebound(to: UInt8.self, capacity: length) {
            String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)
        }
    }

    func thinkMode(forContext mode: Int32, contextSize: Int) -> Int32 {
        let result = symbols.thinkModeForContext(mode, Int32(clamping: contextSize))
        return result < 0 ? mode : result
    }

    // MARK: Sessions

    private func session(_ sessionID: String) throws -> UnsafeMutableRawPointer {
        let engine = try requireEngine()
        return try pool.acquire(
            sessionID,
            create: {
                var session: UnsafeMutableRawPointer?
                let rc = symbols.sessionCreate(engine, Int32(clamping: contextSize), &session)
                guard rc == DS4EngineABI.ok, let session else {
                    throw failure(rc < 0 ? rc : DS4EngineABI.ErrorCode.session)
                }
                return session
            },
            configure: { session, settings in
                if let percent = settings.powerPercent {
                    try check(symbols.sessionSetPower(session, Int32(percent)))
                }
                if let scale = settings.steeringFFNScale {
                    try check(symbols.sessionSetDirectionalSteeringFFN(session, scale))
                }
            },
            free: { [symbols] _, session in
                symbols.sessionFree(session)
            }
        ).handle
    }

    private func liveSession(_ sessionID: String) throws -> UnsafeMutableRawPointer {
        _ = try requireEngine()
        guard let session = pool.existingHandle(for: sessionID) else {
            throw DS4EngineError.sessionFailed(
                "DS4 session '\(sessionID)' is not live (never synced, evicted or released): sync it first"
            )
        }
        return session
    }

    func sync(
        sessionID: String,
        transcript: [DS4TranscriptOperation],
        context: DS4NativeCallbackContext
    ) throws -> DS4SyncResult {
        if context.cancelFlag.isCancelled {
            throw CancellationError()
        }
        let tokens = try makeTokens(transcript)
        defer { symbols.tokensFree(tokens) }
        return try sync(sessionID: sessionID, tokens: tokens, context: context)
    }

    /// `sync` for a transcript tokenized by `prepare`: the buffer stays owned
    /// by `buffer`.
    func sync(
        sessionID: String,
        buffer: DS4NativeTokenBuffer,
        context: DS4NativeCallbackContext
    ) throws -> DS4SyncResult {
        if context.cancelFlag.isCancelled {
            throw CancellationError()
        }
        guard let tokens = buffer.liveHandle else {
            throw DS4EngineError.invalidArgument("the prepared transcript was already released")
        }
        return try sync(sessionID: sessionID, tokens: tokens, context: context)
    }

    private func sync(
        sessionID: String,
        tokens: UnsafeMutableRawPointer,
        context: DS4NativeCallbackContext
    ) throws -> DS4SyncResult {
        let count = symbols.tokensLen(tokens)
        try check(count)
        guard Int(count) < contextSize else {
            throw DS4EngineError.contextExhausted(used: Int(count), limit: contextSize)
        }
        let session = try session(sessionID)
        var cached: Int32 = 0
        var suffix: Int32 = 0
        let rc = context.withUserData { userData in
            symbols.sessionSync(
                session, tokens, DS4NativeCallbacks.progress, DS4NativeCallbacks.cancel, userData,
                &cached, &suffix
            )
        }
        guard rc == DS4EngineABI.ok else {
            pool.unpin(sessionID)
            if rc == DS4EngineABI.syncInterrupted {
                throw CancellationError()
            }
            throw failure(rc < 0 ? rc : DS4EngineABI.ErrorCode.session)
        }
        pool.pin(sessionID)
        return DS4SyncResult(tokenCount: Int(count), cached: Int(cached), suffix: Int(suffix))
    }

    func generate(
        sessionID: String,
        maxTokens: Int,
        thinkMode: Int32,
        sampling: DS4SamplingParameters,
        context: DS4NativeCallbackContext
    ) throws -> DS4GenerateResult {
        let session = try liveSession(sessionID)
        defer { pool.unpin(sessionID) }
        // The transcript grows only by the tokens this call commits.
        let transcriptStart = max(0, symbols.sessionTranscriptLen(session))
        let rc = context.withUserData { userData in
            symbols.sessionGenerate(
                session,
                Int32(clamping: max(0, maxTokens)),
                thinkMode,
                sampling.temperature,
                sampling.topK,
                sampling.topP,
                sampling.minP,
                sampling.seed,
                DS4NativeCallbacks.emit,
                DS4NativeCallbacks.cancel,
                userData
            )
        }
        context.finishText()
        let outcome: DS4GenerateOutcome
        switch rc {
        case DS4EngineABI.GenerateOutcomeCode.stop: outcome = .stop
        case DS4EngineABI.GenerateOutcomeCode.maxTokens: outcome = .maxTokens
        case DS4EngineABI.GenerateOutcomeCode.cancelled: outcome = .cancelled
        case DS4EngineABI.GenerateOutcomeCode.callerStop: outcome = .callerStop
        default: throw failure(rc < 0 ? rc : DS4EngineABI.ErrorCode.decode)
        }
        return DS4GenerateResult(
            outcome: outcome,
            text: context.text,
            tokens: committedTokens(of: session, from: transcriptStart),
            stats: stats(of: session)
        )
    }

    /// The ids the session transcript gained since `start`
    /// (`session_transcript_append_to` into a scratch buffer, then
    /// `tokens_len` / `tokens_get`). Empty when the transcript cannot be read:
    /// the caller then replays the generated text instead of the ids.
    private func committedTokens(of session: UnsafeMutableRawPointer, from start: Int32) -> [Int32] {
        guard let scratch = symbols.tokensNew() else {
            return []
        }
        defer { symbols.tokensFree(scratch) }
        guard symbols.sessionTranscriptAppendTo(session, start, scratch) >= 0 else {
            return []
        }
        let count = symbols.tokensLen(scratch)
        guard count > 0 else {
            return []
        }
        var ids: [Int32] = []
        ids.reserveCapacity(Int(count))
        for index in 0..<count {
            let id = symbols.tokensGet(scratch, index)
            guard id >= 0 else {
                return []
            }
            ids.append(id)
        }
        return ids
    }

    private func stats(of session: UnsafeMutableRawPointer) -> DS4SessionStats {
        func value(_ id: Int32) -> Double {
            max(0, symbols.stat(session, id))
        }
        return DS4SessionStats(
            promptTokens: Int(value(DS4EngineABI.StatID.promptTokens)),
            cachedTokens: Int(value(DS4EngineABI.StatID.cachedTokens)),
            evaluatedTokens: Int(value(DS4EngineABI.StatID.evaluatedTokens)),
            generatedTokens: Int(value(DS4EngineABI.StatID.generatedTokens)),
            prefillSeconds: value(DS4EngineABI.StatID.prefillSeconds),
            generationSeconds: value(DS4EngineABI.StatID.generationSeconds),
            prefillTokensPerSecond: value(DS4EngineABI.StatID.prefillTokensPerSecond),
            generationTokensPerSecond: value(DS4EngineABI.StatID.generationTokensPerSecond),
            position: Int(value(DS4EngineABI.StatID.sessionPosition)),
            contextSize: Int(value(DS4EngineABI.StatID.sessionContext))
        )
    }

    func stats(sessionID: String) -> DS4SessionStats {
        guard isOpen, let session = pool.peekHandle(for: sessionID) else {
            return .empty
        }
        return stats(of: session)
    }

    /// Sessions alive in the pool (0 once the engine is closed).
    var liveSessionCount: Int {
        isOpen ? pool.count : 0
    }

    func setPower(sessionID: String, percent: Int) throws {
        _ = try requireEngine()
        guard (1...100).contains(percent) else {
            throw DS4EngineError.invalidArgument("power must be between 1 and 100, got \(percent)")
        }
        if let session = pool.peekHandle(for: sessionID) {
            try check(symbols.sessionSetPower(session, Int32(percent)))
        }
        pool.updateSettings(for: sessionID) { $0.powerPercent = percent }
    }

    func setSteeringFFN(sessionID: String, scale: Double) throws {
        _ = try requireEngine()
        guard scale.isFinite, (-100.0...100.0).contains(scale) else {
            throw DS4EngineError.invalidArgument("steering scale must be between -100 and 100, got \(scale)")
        }
        if let session = pool.peekHandle(for: sessionID) {
            try check(symbols.sessionSetDirectionalSteeringFFN(session, scale))
        }
        pool.updateSettings(for: sessionID) { $0.steeringFFNScale = scale }
    }

    func saveCheckpoint(sessionID: String, to url: URL, trailer: Data?) throws -> DS4CheckpointSaveOutcome {
        let session = try liveSession(sessionID)
        let rc = url.path.withCString { path in
            guard let trailer, !trailer.isEmpty else {
                return symbols.sessionKVSave(session, path, nil, 0)
            }
            return trailer.withUnsafeBytes { bytes in
                symbols.sessionKVSave(
                    session, path, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count
                )
            }
        }
        switch rc {
        case DS4EngineABI.ok: return .saved
        case DS4EngineABI.kvSkippedVision: return .skippedVision
        default: throw failure(rc < 0 ? rc : DS4EngineABI.ErrorCode.io)
        }
    }

    func loadCheckpoint(sessionID: String, from url: URL, context: DS4NativeCallbackContext) throws -> Data? {
        if context.cancelFlag.isCancelled {
            throw CancellationError()
        }
        let session = try session(sessionID)
        let routeRC = context.withUserData { userData in
            symbols.sessionWaitDistributedRoute(
                session, DS4NativeCallbacks.progress, DS4NativeCallbacks.cancel, userData
            )
        }
        guard routeRC == DS4EngineABI.ok else {
            pool.unpin(sessionID)
            if routeRC == DS4EngineABI.syncInterrupted {
                throw CancellationError()
            }
            throw failure(routeRC < 0 ? routeRC : DS4EngineABI.ErrorCode.session)
        }
        var trailer: UnsafeMutablePointer<CChar>?
        var trailerLength = 0
        let rc = url.path.withCString { symbols.sessionKVLoad(session, $0, &trailer, &trailerLength) }
        defer { symbols.stringFree(trailer) }
        guard rc == DS4EngineABI.ok else {
            pool.unpin(sessionID)
            throw failure(rc < 0 ? rc : DS4EngineABI.ErrorCode.kvInvalid)
        }
        pool.pin(sessionID)
        return trailer.map { Data(bytes: $0, count: trailerLength) }
    }

    func releaseSession(_ sessionID: String) {
        if let session = pool.remove(sessionID) {
            symbols.sessionFree(session)
        }
    }
}

/// Copy of a borrowed C string ("" for NULL).
fileprivate func cString(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
}

/// Calls `body` with a C array of NUL-terminated copies of `strings`.
fileprivate func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) throws -> Result
) rethrows -> Result {
    let copies = strings.map { strdup($0) }
    defer {
        for copy in copies {
            free(copy)
        }
    }
    let pointers = copies.map { UnsafePointer($0) }
    return try pointers.withUnsafeBufferPointer { buffer in
        try body(buffer.baseAddress, buffer.count)
    }
}
