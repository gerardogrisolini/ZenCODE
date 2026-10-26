//
//  MockDS4Engine.swift
//  ZenCODE
//
//  Scriptable `DS4Engine` for tests (no C, no model). Reusable by every DS4
//  backend test:
//
//    let engine = MockDS4Engine(configuration: config)
//    engine.enqueueGeneration(["Hel", "lo"], outcome: .stop)
//    let registry = DS4EngineRegistry(factory: MockDS4Engine.factory(recorder))
//
//  Behaviour
//  - Tokenization is deterministic: `MockDS4Engine.tokenCount(of:)` (one
//    token every 4 UTF-8 bytes, rounded up, plus a constant per operation; a
//    `.tokens` operation counts its ids).
//  - Sessions live in a real `DS4SessionPool` with the configuration's
//    `sessionCapacity` (LRU eviction, pinning as in the native engine).
//  - `sync` reports `cached` = tokens of the common operation prefix with the
//    session's previous sync (0 for a new or evicted session) and throws
//    `contextExhausted` when the prompt does not fit `info.contextSize`.
//  - `generate` emits the next scripted generation (or `defaultChunks`)
//    chunk by chunk through `onText`, one token per chunk. The ids are the
//    scripted `tokens` or, by default, the next values of a counter starting
//    at `firstGeneratedTokenID` (distinct for every token the engine emits);
//    they are returned in `DS4GenerateResult.tokens` and appended to the
//    session as a `.tokens` operation, like the native engine's transcript,
//    so the next sync reuses them when the prompt replays the same ids.
//    It honours `DS4EmitDecision.stop`
//    (`.callerStop`) and Task cancellation (`.cancelled`), optionally waits
//    on `generationGate` before the first chunk and sleeps `chunkDelay`
//    between chunks. `generationStarted` opens when a generation begins.
//  - Every call is recorded in `calls`; `close()` is idempotent.
//  - Images: a `.multimodalMessage` "encodes" each image file when it is
//    tokenized (`tokenCount`, `renderText`, `prepare`, `sync(transcript:)`),
//    recording it in `imageEncodes` and failing with `DS4EngineError.vision`
//    when the file is missing (the client deletes the files only after the
//    sync) or `failImageEncoding` is set. `prepare` + `sync(prepared:)` encode
//    once, like the native engine. Sessions compare images by content, not by
//    file name, as DS4 compares embedding fingerprints.
//  - `livePreparedCount` / `releasedPreparedCount` track the lifetime of the
//    prepared transcripts.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// One-shot async gate: `wait()` suspends until `open()` (cancellable).
final class MockDS4Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    init(isOpen: Bool = false) {
        state.withLock { $0.isOpen = isOpen }
    }

    var isOpen: Bool {
        state.withLock { $0.isOpen }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool? = state.withLock { state in
                    if state.isOpen {
                        return true
                    }
                    if Task.isCancelled {
                        return false
                    }
                    state.waiters[id] = continuation
                    return nil
                }
                switch resumeNow {
                case .some(true): continuation.resume()
                case .some(false): continuation.resume(throwing: CancellationError())
                case .none: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

final class MockDS4Engine: DS4Engine {
    enum Call: Sendable, Hashable {
        case tokenCount
        case prepare
        case renderText
        case thinkModeForContext(mode: Int32, contextSize: Int)
        case sync(sessionID: String, cached: Int, suffix: Int)
        case generate(sessionID: String)
        case stats(sessionID: String)
        case setPower(sessionID: String, percent: Int)
        case setSteeringFFN(sessionID: String, scale: Double)
        case saveCheckpoint(sessionID: String, url: URL)
        case loadCheckpoint(sessionID: String, url: URL)
        case releaseSession(String)
        case evicted(String)
        case close
    }

    /// One simulated image encode.
    struct ImageEncode: Sendable, Hashable {
        let path: String
        let byteCount: Int
        /// Permissions of the file's directory (octal), when readable.
        let directoryPermissions: Int?
    }

    /// Payload of a prepared transcript: counts its release.
    private final class PreparedPayload: DS4PreparedPayload {
        private let released = Mutex(false)
        private let onRelease: @Sendable () -> Void

        init(onRelease: @escaping @Sendable () -> Void) {
            self.onRelease = onRelease
        }

        var isReleased: Bool {
            released.withLock { $0 }
        }

        func release() {
            let first = released.withLock { released -> Bool in
                defer { released = true }
                return !released
            }
            if first {
                onRelease()
            }
        }
    }

    struct ScriptedGeneration: Sendable {
        var chunks: [String]
        /// Outcome when every chunk was emitted without a caller stop.
        var outcome: DS4GenerateOutcome = .stop
        /// Thrown instead of generating (after the gate, before any chunk).
        var error: DS4EngineError?
        /// Ids of the tokens, one per chunk. `nil`: fresh ids from the engine's counter.
        var tokens: [Int32]?
    }

    private struct SessionState {
        var operations: [DS4TranscriptOperation] = []
        var stats = DS4SessionStats.empty
        var hasImages = false
    }

    private struct State {
        var calls: [Call] = []
        var script: [ScriptedGeneration] = []
        var pool: DS4SessionPool<Int>
        var sessions: [String: SessionState] = [:]
        var nextHandle = 0
        var isClosed = false
        var checkpoints: [URL: [DS4TranscriptOperation]] = [:]
        var imageEncodes: [ImageEncode] = []
        var failImageEncoding = false
        var preparedCreated = 0
        var preparedReleased = 0
        var nextTokenID = MockDS4Engine.firstGeneratedTokenID
    }

    /// First id of the counter the mock draws generated token ids from.
    static let firstGeneratedTokenID: Int32 = 5_000

    static let checkpointMagic = Data("MOCKDS4KV1\n".utf8)

    let configuration: DS4EngineConfiguration
    let info: DS4EngineInfo
    let defaultChunks: [String]
    let syncDelay: Duration
    let chunkDelay: Duration
    /// When set, `generate` waits on it before emitting the first chunk.
    let generationGate: MockDS4Gate?
    /// Opened when a `generate` call starts.
    let generationStarted = MockDS4Gate()

    private let state: Mutex<State>
    private let instanceToken = DS4EngineInstanceToken.next()

    init(
        configuration: DS4EngineConfiguration,
        info: DS4EngineInfo? = nil,
        defaultChunks: [String] = ["mock ", "reply"],
        syncDelay: Duration = .zero,
        chunkDelay: Duration = .zero,
        generationGate: MockDS4Gate? = nil
    ) {
        self.configuration = configuration
        self.info = info ?? DS4EngineInfo(
            modelName: "mock-ds4",
            modelID: 41,
            routedQuantBits: 2,
            hasVision: false,
            toolSyntaxID: DS4EngineABI.ToolSyntax.dsml41,
            mtpDraftTokens: 1,
            contextSize: configuration.contextSize
        )
        self.defaultChunks = defaultChunks
        self.syncDelay = syncDelay
        self.chunkDelay = chunkDelay
        self.generationGate = generationGate
        self.state = Mutex(State(pool: DS4SessionPool(capacity: configuration.sessionCapacity)))
    }

    /// Registry factory calling `make` for each open (collect the engines
    /// there, delay, or throw an open error such as `instanceLocked`).
    static func factory(
        _ make: @escaping @Sendable (DS4EngineConfiguration) async throws -> MockDS4Engine
    ) -> DS4EngineRegistry.Factory {
        { configuration, _ in try await make(configuration) }
    }

    // MARK: Inspection

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    /// Live session IDs, least recently used first.
    var liveSessionIDs: [String] {
        state.withLock { $0.pool.sessionIDsByRecency }
    }

    /// Images "encoded" so far, in order.
    var imageEncodes: [ImageEncode] {
        state.withLock { $0.imageEncodes }
    }

    /// Makes every later image encode fail with `DS4EngineError.vision`.
    var failImageEncoding: Bool {
        get { state.withLock { $0.failImageEncoding } }
        set { state.withLock { $0.failImageEncoding = newValue } }
    }

    /// Prepared transcripts created and not released yet.
    var livePreparedCount: Int {
        state.withLock { $0.preparedCreated - $0.preparedReleased }
    }

    var releasedPreparedCount: Int {
        state.withLock { $0.preparedReleased }
    }

    func enqueueGeneration(_ chunks: [String], outcome: DS4GenerateOutcome = .stop) {
        state.withLock { $0.script.append(ScriptedGeneration(chunks: chunks, outcome: outcome)) }
    }

    func enqueueGeneration(_ generation: ScriptedGeneration) {
        state.withLock { $0.script.append(generation) }
    }

    // MARK: Tokenizer

    static func tokenCount(of operation: DS4TranscriptOperation) -> Int {
        func text(_ value: String) -> Int {
            (value.utf8.count + 3) / 4
        }
        switch operation {
        case .begin: return 1
        case .message(let role, let content): return 3 + text(role) + text(content)
        case .thinkPrefix: return 2
        case .assistantPrefix: return 2
        case .renderedChat(let value): return text(value)
        case .endOfSequence: return 1
        case .tokens(let ids): return ids.count
        case .multimodalMessage(let role, let parts, let images):
            return 3 + text(role) + parts.map(text).reduce(0, +) + 16 * images.count
        }
    }

    static func tokenCount(of transcript: [DS4TranscriptOperation]) -> Int {
        transcript.map(tokenCount(of:)).reduce(0, +)
    }

    static func render(_ transcript: [DS4TranscriptOperation]) -> String {
        transcript.map { operation in
            switch operation {
            case .begin: "<bos>"
            case .message(let role, let content): "<\(role)>\(content)"
            case .thinkPrefix(let mode): "<think:\(mode)>"
            case .assistantPrefix(let mode): "<assistant:\(mode)>"
            case .renderedChat(let text): text
            case .endOfSequence: "<eos>"
            case .tokens(let ids): "<tokens:" + ids.map(String.init).joined(separator: ",") + ">"
            case .multimodalMessage(let role, let parts, let images):
                "<\(role)>" + parts.joined(separator: "<image>") + "[\(images.count) image(s)]"
            }
        }.joined()
    }

    // MARK: DS4Engine

    /// Creates the session in the pool when needed, dropping evicted ones.
    private static func acquireSession(_ sessionID: String, in state: inout State) {
        let handle = state.nextHandle + 1
        state.nextHandle = handle
        var evicted: [String] = []
        // `create` never throws, so neither does `acquire`.
        _ = try? state.pool.acquire(
            sessionID,
            create: { handle },
            configure: { _, _ in },
            free: { id, _ in evicted.append(id) }
        )
        for id in evicted {
            state.sessions[id] = nil
            state.calls.append(.evicted(id))
        }
    }

    private func record(_ call: Call) throws {
        try state.withLock { state in
            guard !state.isClosed else {
                throw DS4EngineError.engineClosed
            }
            state.calls.append(call)
        }
    }

    private func validate(_ transcript: [DS4TranscriptOperation]) throws {
        for case .multimodalMessage(_, let parts, let images) in transcript {
            guard info.hasVision else {
                throw DS4EngineError.unsupported("the model has no vision projector")
            }
            guard parts.count == images.count + 1 else {
                throw DS4EngineError.invalidArgument("text parts must be images + 1")
            }
        }
    }

    /// Simulates `engine_vision_encode_file` for every image of `transcript`.
    private func encodeImages(in transcript: [DS4TranscriptOperation]) throws {
        for case .multimodalMessage(_, _, let images) in transcript {
            for file in images {
                if state.withLock({ $0.failImageEncoding }) {
                    throw DS4EngineError.vision("unsupported image format: \(file.lastPathComponent)")
                }
                guard let data = try? Data(contentsOf: file) else {
                    throw DS4EngineError.vision("cannot read image \(file.path)")
                }
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: file.deletingLastPathComponent().path
                )
                let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
                state.withLock {
                    $0.imageEncodes.append(ImageEncode(
                        path: file.path, byteCount: data.count, directoryPermissions: permissions
                    ))
                }
            }
        }
    }

    /// The operations with image files replaced by a fingerprint of their
    /// content, so sessions compare images like DS4 does.
    private static func fingerprinted(_ transcript: [DS4TranscriptOperation]) -> [DS4TranscriptOperation] {
        transcript.map { operation in
            guard case .multimodalMessage(let role, let parts, let images) = operation else {
                return operation
            }
            let fingerprints = images.map { file in
                URL(string: "mock-image:\((try? Data(contentsOf: file))?.hashValue ?? 0)")!
            }
            return .multimodalMessage(role: role, textParts: parts, imageFiles: fingerprints)
        }
    }

    func tokenCount(of transcript: [DS4TranscriptOperation]) async throws -> Int {
        try record(.tokenCount)
        try validate(transcript)
        try encodeImages(in: transcript)
        return Self.tokenCount(of: transcript)
    }

    func prepare(transcript: [DS4TranscriptOperation]) async throws -> DS4PreparedTranscript {
        try record(.prepare)
        try validate(transcript)
        try encodeImages(in: transcript)
        var total = 0
        let counts = transcript.map { operation -> Int in
            total += Self.tokenCount(of: operation)
            return total
        }
        state.withLock { $0.preparedCreated += 1 }
        let payload = PreparedPayload {
            self.state.withLock { $0.preparedReleased += 1 }
        }
        return DS4PreparedTranscript(
            operations: transcript,
            tokenCount: total,
            operationTokenCounts: counts,
            ownerToken: instanceToken,
            payload: payload
        )
    }

    func renderText(of transcript: [DS4TranscriptOperation]) async throws -> String {
        try record(.renderText)
        try validate(transcript)
        try encodeImages(in: transcript)
        return Self.render(transcript)
    }

    func thinkMode(parseLevel: String) -> Int32? {
        guard let level = Int32(parseLevel), (0...DS4EngineABI.ThinkMode.levelMax).contains(level) else {
            return nil
        }
        return DS4EngineABI.ThinkMode.levelBase + level
    }

    func thinkMode(forContext mode: Int32, contextSize: Int) async -> Int32 {
        try? record(.thinkModeForContext(mode: mode, contextSize: contextSize))
        // Mirrors DeepSeek V4: MAX needs at least 393216 tokens of context.
        return mode == DS4EngineABI.ThinkMode.max && contextSize < 393_216 ? DS4EngineABI.ThinkMode.high : mode
    }

    func sync(
        sessionID: String,
        transcript: [DS4TranscriptOperation],
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> DS4SyncResult {
        try Task.checkCancellation()
        try validate(transcript)
        try encodeImages(in: transcript)
        return try await syncEncoded(sessionID: sessionID, transcript: transcript, onProgress: onProgress)
    }

    func sync(
        sessionID: String,
        prepared: DS4PreparedTranscript,
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> DS4SyncResult {
        guard prepared.isOwned(byEngineWithToken: instanceToken),
              (prepared.payload as? PreparedPayload)?.isReleased == false else {
            return try await sync(sessionID: sessionID, transcript: prepared.operations, onProgress: onProgress)
        }
        try Task.checkCancellation()
        return try await syncEncoded(sessionID: sessionID, transcript: prepared.operations, onProgress: onProgress)
    }

    /// The sync proper, for a transcript whose images were already encoded.
    private func syncEncoded(
        sessionID: String,
        transcript: [DS4TranscriptOperation],
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> DS4SyncResult {
        let total = Self.tokenCount(of: transcript)
        guard total < info.contextSize else {
            throw DS4EngineError.contextExhausted(used: total, limit: info.contextSize)
        }
        if syncDelay > .zero {
            try await Task.sleep(for: syncDelay)
        }
        let result = try state.withLock { state -> DS4SyncResult in
            guard !state.isClosed else {
                throw DS4EngineError.engineClosed
            }
            Self.acquireSession(sessionID, in: &state)
            let previous = state.sessions[sessionID]?.operations ?? []
            let fingerprinted = Self.fingerprinted(transcript)
            let common = zip(previous, fingerprinted).prefix { $0 == $1 }.count
            let cached = Self.tokenCount(of: Array(transcript.prefix(common)))
            let result = DS4SyncResult(tokenCount: total, cached: cached, suffix: total - cached)
            var session = state.sessions[sessionID] ?? SessionState()
            session.operations = fingerprinted
            session.hasImages = transcript.contains {
                if case .multimodalMessage(_, _, let images) = $0 { return !images.isEmpty }
                return false
            }
            session.stats = DS4SessionStats(
                promptTokens: total, cachedTokens: cached, evaluatedTokens: total - cached,
                generatedTokens: 0, prefillSeconds: 0, generationSeconds: 0,
                prefillTokensPerSecond: 0, generationTokensPerSecond: 0,
                position: total, contextSize: info.contextSize
            )
            state.sessions[sessionID] = session
            state.pool.pin(sessionID)
            state.calls.append(.sync(sessionID: sessionID, cached: cached, suffix: total - cached))
            return result
        }
        onProgress("prefill", result.suffix, result.suffix)
        return result
    }

    func generate(
        sessionID: String,
        maxTokens: Int,
        thinkMode: Int32,
        sampling: DS4SamplingParameters,
        onText: @escaping @Sendable (String) -> DS4EmitDecision
    ) async throws -> DS4GenerateResult {
        let generation = try state.withLock { state -> ScriptedGeneration in
            guard !state.isClosed else {
                throw DS4EngineError.engineClosed
            }
            guard state.pool.existingHandle(for: sessionID) != nil else {
                throw DS4EngineError.sessionFailed("DS4 session '\(sessionID)' is not live: sync it first")
            }
            state.calls.append(.generate(sessionID: sessionID))
            return state.script.isEmpty
                ? ScriptedGeneration(chunks: defaultChunks)
                : state.script.removeFirst()
        }
        defer { state.withLock { $0.pool.unpin(sessionID) } }
        generationStarted.open()
        if let generationGate {
            do {
                try await generationGate.wait()
            } catch {
                return finishGeneration(sessionID: sessionID, outcome: .cancelled, text: "", tokens: [])
            }
        }
        if let error = generation.error {
            throw error
        }
        var text = ""
        var emitted = 0
        var outcome = generation.outcome
        var ids: [Int32] = []
        for chunk in generation.chunks {
            if Task.isCancelled {
                outcome = .cancelled
                break
            }
            if emitted >= maxTokens {
                outcome = .maxTokens
                break
            }
            if chunkDelay > .zero {
                try? await Task.sleep(for: chunkDelay)
                if Task.isCancelled {
                    outcome = .cancelled
                    break
                }
            }
            text += chunk
            emitted += 1
            ids.append(nextTokenID(scripted: generation.tokens, index: emitted - 1))
            if onText(chunk).contains(.stop) {
                outcome = .callerStop
                break
            }
        }
        return finishGeneration(sessionID: sessionID, outcome: outcome, text: text, tokens: ids)
    }

    private func nextTokenID(scripted: [Int32]?, index: Int) -> Int32 {
        if let scripted, index < scripted.count {
            return scripted[index]
        }
        return state.withLock { state in
            defer { state.nextTokenID += 1 }
            return state.nextTokenID
        }
    }

    private func finishGeneration(
        sessionID: String,
        outcome: DS4GenerateOutcome,
        text: String,
        tokens: [Int32]
    ) -> DS4GenerateResult {
        let stats = state.withLock { state -> DS4SessionStats in
            var session = state.sessions[sessionID] ?? SessionState()
            session.stats.generatedTokens = tokens.count
            session.stats.position += tokens.count
            // The native session transcript grows with the committed tokens.
            if !tokens.isEmpty, state.pool.contains(sessionID), state.sessions[sessionID] != nil {
                session.operations.append(.tokens(tokens))
            }
            state.sessions[sessionID] = session
            return session.stats
        }
        return DS4GenerateResult(outcome: outcome, text: text, tokens: tokens, stats: stats)
    }

    func stats(sessionID: String) async -> DS4SessionStats {
        state.withLock { state in
            state.calls.append(.stats(sessionID: sessionID))
            guard state.pool.contains(sessionID) else {
                return .empty
            }
            return state.sessions[sessionID]?.stats ?? .empty
        }
    }

    func liveSessionCount() async -> Int {
        state.withLock { $0.pool.count }
    }

    func setPower(sessionID: String, percent: Int) async throws {
        try record(.setPower(sessionID: sessionID, percent: percent))
        guard (1...100).contains(percent) else {
            throw DS4EngineError.invalidArgument("power must be between 1 and 100")
        }
        state.withLock { $0.pool.updateSettings(for: sessionID) { $0.powerPercent = percent } }
    }

    func setSteeringFFN(sessionID: String, scale: Double) async throws {
        try record(.setSteeringFFN(sessionID: sessionID, scale: scale))
        guard scale.isFinite, (-100.0...100.0).contains(scale) else {
            throw DS4EngineError.invalidArgument("steering scale must be between -100 and 100")
        }
        state.withLock { $0.pool.updateSettings(for: sessionID) { $0.steeringFFNScale = scale } }
    }

    /// Writes `checkpointMagic + trailer` to `url` and remembers the operations.
    func saveCheckpoint(sessionID: String, to url: URL, trailer: Data?) async throws -> DS4CheckpointSaveOutcome {
        try record(.saveCheckpoint(sessionID: sessionID, url: url))
        let session = try state.withLock { state -> SessionState in
            guard state.pool.contains(sessionID), let session = state.sessions[sessionID] else {
                throw DS4EngineError.sessionFailed("DS4 session '\(sessionID)' is not live")
            }
            return session
        }
        if session.hasImages {
            return .skippedVision
        }
        try (Self.checkpointMagic + (trailer ?? Data())).write(to: url, options: .atomic)
        state.withLock { $0.checkpoints[url] = session.operations }
        return .saved
    }

    func loadCheckpoint(sessionID: String, from url: URL) async throws -> Data? {
        try Task.checkCancellation()
        try record(.loadCheckpoint(sessionID: sessionID, url: url))
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DS4EngineError.io("cannot read \(url.path)")
        }
        guard data.starts(with: Self.checkpointMagic) else {
            throw DS4EngineError.kvIncompatible("not a mock DS4 checkpoint")
        }
        state.withLock { state in
            Self.acquireSession(sessionID, in: &state)
            var session = SessionState()
            session.operations = state.checkpoints[url] ?? []
            state.sessions[sessionID] = session
            state.pool.pin(sessionID)
        }
        let trailer = data.dropFirst(Self.checkpointMagic.count)
        return trailer.isEmpty ? nil : Data(trailer)
    }

    func releaseSession(_ sessionID: String) async {
        state.withLock { state in
            state.calls.append(.releaseSession(sessionID))
            _ = state.pool.remove(sessionID)
            state.sessions[sessionID] = nil
        }
    }

    func close() async {
        state.withLock { state in
            guard !state.isClosed else {
                return
            }
            _ = state.pool.removeAll()
            state.sessions.removeAll()
            state.calls.append(.close)
            state.isClosed = true
        }
    }
}

// MARK: - Factory

/// Registry factory for tests: counts opens, keeps the opened mocks in
/// order, can delay opens and fail the next ones with scripted errors.
final class MockDS4EngineFactory: Sendable {
    private struct State {
        var engines: [MockDS4Engine] = []
        var openCount = 0
        var failures: [DS4EngineError] = []
        var statusMessages: [String] = []
    }

    let openDelay: Duration
    private let makeEngine: @Sendable (DS4EngineConfiguration) -> MockDS4Engine
    private let state = Mutex(State())

    init(
        openDelay: Duration = .zero,
        makeEngine: @escaping @Sendable (DS4EngineConfiguration) -> MockDS4Engine = { MockDS4Engine(configuration: $0) }
    ) {
        self.openDelay = openDelay
        self.makeEngine = makeEngine
    }

    var engines: [MockDS4Engine] {
        state.withLock { $0.engines }
    }

    var openCount: Int {
        state.withLock { $0.openCount }
    }

    var statusMessages: [String] {
        state.withLock { $0.statusMessages }
    }

    /// The next open throws `error` (after `openDelay`).
    func failNextOpen(with error: DS4EngineError) {
        state.withLock { $0.failures.append(error) }
    }

    var factory: DS4EngineRegistry.Factory {
        { [self] configuration, onStatus in
            try await open(configuration, onStatus: onStatus)
        }
    }

    func open(
        _ configuration: DS4EngineConfiguration,
        onStatus: @escaping DS4EngineRegistry.StatusHandler
    ) async throws -> any DS4Engine {
        state.withLock { $0.openCount += 1 }
        if openDelay > .zero {
            try? await Task.sleep(for: openDelay)
        }
        if let failure = state.withLock({ $0.failures.isEmpty ? nil : $0.failures.removeFirst() }) {
            throw failure
        }
        let engine = makeEngine(configuration)
        state.withLock { $0.engines.append(engine) }
        let message = "opened \(configuration.modelPath ?? "mock")"
        state.withLock { $0.statusMessages.append(message) }
        await onStatus(message)
        return engine
    }
}

extension DS4EngineConfiguration {
    /// Configuration for tests (the library is never loaded by the mocks).
    static func mock(
        model: String = "/tmp/zencode-ds4-tests/model.gguf",
        contextSize: Int = 4096,
        sessionCapacity: Int = 2,
        extraOptions: [DS4EngineOption] = []
    ) -> DS4EngineConfiguration {
        DS4EngineConfiguration(
            libraryURL: URL(fileURLWithPath: "/tmp/zencode-ds4-tests/\(DS4EngineABI.libraryFileName)"),
            options: [DS4EngineOption(key: "model_path", value: model)] + extraOptions,
            contextSize: contextSize,
            sessionCapacity: sessionCapacity,
            buildHint: "Scripts/build-ds4-engine.sh --ds4-root /tmp/ds4"
        )
    }
}

/// Polls `condition` every few milliseconds; records an issue after `timeout`.
func ds4Eventually(
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
}
