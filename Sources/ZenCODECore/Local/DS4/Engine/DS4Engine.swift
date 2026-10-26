//
//  DS4Engine.swift
//  ZenCODE
//
//  Testable abstraction of the in-process DS4 engine. `DS4NativeEngine` is the
//  real implementation (C shim loaded with dlopen, every call on one dedicated
//  thread); tests use `MockDS4Engine`. Engines are obtained from
//  `DS4EngineRegistry`, which keeps at most one engine open per process.
//
//  Model of a turn (what callers do, inside a generation lease):
//    1. build the full prompt as `[DS4TranscriptOperation]` (begin, messages,
//       assistant/think prefix);
//    2. `sync(sessionID:transcript:)` - the engine tokenizes the operations on
//       its thread and reuses the longest prefix already in the session KV.
//       A caller that also needs the token count first (compaction policy)
//       uses `prepare(transcript:)` + `sync(sessionID:prepared:)` instead, so
//       the operations - and the images of multimodal messages, which are
//       encoded while tokenizing - are processed once;
//    3. `generate(sessionID:...)` - tokens stream through `onText`; afterwards
//       the session transcript also contains the generated tokens, so the
//       next turn's sync reuses them through the common prefix - provided
//       the next prompt replays them as the same ids: the result carries the
//       committed ids (`DS4GenerateResult.tokens`) and the caller renders
//       them back as `DS4TranscriptOperation.tokens` (re-tokenizing the
//       generated text may split it differently and lose the reuse).
//

import Foundation

// MARK: - Configuration

/// One `key=value` option of `zencode_ds4_engine_open` (see the key list in
/// `zencode_ds4_abi.h`). `extra_arg` may repeat; any other key must be unique.
struct DS4EngineOption: Sendable, Hashable {
    let key: String
    let value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    /// The `"key=value"` string passed to the shim.
    var keyValue: String {
        "\(key)=\(value)"
    }
}

/// Everything needed to open an engine. Built by the backend from the model
/// manifest (mapping owned by the DS4 backend factory); the registry only
/// compares `identity`.
struct DS4EngineConfiguration: Sendable, Hashable {
    /// Allowed values of `sessionCapacity` (manifest `engineSessions`).
    static let sessionCapacityRange = 1...8

    /// Absolute URL of `libzencode-ds4.{dylib,so}`.
    let libraryURL: URL
    /// Engine options in order (order matters for `extra_arg`). Paths must be
    /// absolute (`model_path`, `mtp_path`, ...).
    let options: [DS4EngineOption]
    /// Context size of every session created by the engine.
    let contextSize: Int
    /// Maximum number of live DS4 sessions (LRU eviction beyond it), clamped
    /// to `sessionCapacityRange`.
    let sessionCapacity: Int
    /// Manual build command shown when the library is missing or stale.
    let buildHint: String

    init(
        libraryURL: URL,
        options: [DS4EngineOption],
        contextSize: Int,
        sessionCapacity: Int,
        buildHint: String
    ) {
        self.libraryURL = libraryURL
        self.options = options
        self.contextSize = max(1, contextSize)
        self.sessionCapacity = min(
            max(sessionCapacity, Self.sessionCapacityRange.lowerBound),
            Self.sessionCapacityRange.upperBound
        )
        self.buildHint = buildHint
    }

    /// Options actually passed to `zencode_ds4_engine_open`: `options` plus the
    /// placement hints `context_size=<contextSize>` and
    /// `session_count=<sessionCapacity>` when `options` does not set them.
    var effectiveOptions: [DS4EngineOption] {
        var result = options
        let keys = Set(options.map(\.key))
        if !keys.contains("context_size") {
            result.append(DS4EngineOption(key: "context_size", value: String(contextSize)))
        }
        if !keys.contains("session_count") {
            result.append(DS4EngineOption(key: "session_count", value: String(sessionCapacity)))
        }
        return result
    }

    /// Registry key: library path plus every effective option (model path,
    /// backend, context size, session count, tuning, extra args). Two
    /// configurations with the same identity share one open engine; a
    /// different identity closes the open engine and opens a new one.
    var identity: String {
        let library = libraryURL.standardizedFileURL.path
        return (["library=\(library)"] + effectiveOptions.map(\.keyValue)).joined(separator: "\n")
    }

    /// `model_path` option, when set (diagnostics only).
    var modelPath: String? {
        options.last { $0.key == "model_path" }?.value
    }
}

// MARK: - Transcript

/// One step of prompt construction, executed by the engine on its thread
/// against a fresh token buffer (each maps to one shim call).
enum DS4TranscriptOperation: Sendable, Hashable {
    /// `zencode_ds4_chat_begin`: BOS / chat-start sequence (start of a prompt).
    case begin
    /// `zencode_ds4_chat_append_message`: role is "system", "user", "assistant" or "tool".
    case message(role: String, content: String)
    /// `zencode_ds4_chat_append_think_prefix` (a `DS4EngineABI.ThinkMode` value).
    case thinkPrefix(mode: Int32)
    /// `zencode_ds4_chat_append_assistant_prefix` (a `DS4EngineABI.ThinkMode` value).
    case assistantPrefix(mode: Int32)
    /// `zencode_ds4_tokenize_rendered_chat`: already rendered chat text, special tokens included.
    case renderedChat(String)
    /// `zencode_ds4_tokens_push_eos`: EOS / end-of-turn token.
    case endOfSequence
    /// `zencode_ds4_tokens_push` for every id, in order: exact token ids
    /// replayed as they were sampled (`DS4GenerateResult.tokens`). Unlike
    /// `renderedChat`, nothing is tokenized, so a turn the engine generated
    /// keeps the split the model produced and stays a prefix of the live KV.
    case tokens([Int32])
    /// `zencode_ds4_chat_append_multimodal_message`: `textParts` alternate with
    /// `imageFiles` (`textParts.count == imageFiles.count + 1`); every image
    /// is encoded with `zencode_ds4_engine_vision_encode_file` while the
    /// operation runs (requires a vision projector).
    case multimodalMessage(role: String, textParts: [String], imageFiles: [URL])
}

// MARK: - Values

/// Properties of the open model, read once after `engine_open`.
struct DS4EngineInfo: Sendable, Hashable {
    let modelName: String
    /// Stable KV-compatibility model id.
    let modelID: Int32
    let routedQuantBits: Int32
    let hasVision: Bool
    /// `DS4EngineABI.ToolSyntax` value.
    let toolSyntaxID: Int32
    /// Effective MTP draft tokens (1 = no speculative decoding).
    let mtpDraftTokens: Int32
    /// Context size of the engine's sessions.
    let contextSize: Int

    /// Identity of the token ids this engine produces: they can be replayed
    /// (`DS4TranscriptOperation.tokens`) only by an engine with the same
    /// identity. Stored next to the ids as `DS4MessageKeys.rawTokensModel`.
    var tokenIdentity: String {
        "\(modelID)-\(routedQuantBits)-\(modelName)"
    }
}

/// Sampling of `zencode_ds4_session_generate`. `topK == 0` disables top-k,
/// `seed == 0` picks a random seed.
struct DS4SamplingParameters: Sendable, Hashable {
    var temperature: Double
    var topK: Int32
    var topP: Double
    var minP: Double
    var seed: UInt64

    init(temperature: Double, topK: Int32 = 0, topP: Double = 1, minP: Double = 0, seed: UInt64 = 0) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.seed = seed
    }
}

/// Value returned by `generate`'s `onText` callback for each committed token
/// (becomes the `ZENCODE_DS4_EMIT_*` flags). `[]` keeps generating normally.
struct DS4EmitDecision: OptionSet, Sendable, Hashable {
    let rawValue: Int32

    init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// Stop after this token (outcome `.callerStop`).
    static let stop = DS4EmitDecision(rawValue: DS4EngineABI.EmitFlag.stop)
    /// Sample the next token greedily (holds only while it keeps being returned).
    static let greedy = DS4EmitDecision(rawValue: DS4EngineABI.EmitFlag.greedy)
}

/// Result of a successful `sync`.
struct DS4SyncResult: Sendable, Hashable {
    /// Tokens of the full prompt.
    let tokenCount: Int
    /// Prompt tokens reused from the live KV.
    let cached: Int
    /// Prompt suffix evaluated by this sync.
    let suffix: Int
}

enum DS4GenerateOutcome: Sendable, Hashable {
    /// The model produced a stop token (never emitted).
    case stop
    /// `maxTokens` or the context room was reached.
    case maxTokens
    /// The calling `Task` was cancelled; the text produced so far is valid.
    case cancelled
    /// `onText` returned `.stop`.
    case callerStop
}

/// Statistics of a session (`zencode_ds4_stat`).
struct DS4SessionStats: Sendable, Hashable {
    var promptTokens: Int
    var cachedTokens: Int
    var evaluatedTokens: Int
    var generatedTokens: Int
    var prefillSeconds: Double
    var generationSeconds: Double
    var prefillTokensPerSecond: Double
    var generationTokensPerSecond: Double
    /// Live position (tokens in the KV).
    var position: Int
    /// Session context size.
    var contextSize: Int

    /// Stats of a session that is not live (never synced, evicted or released).
    static let empty = DS4SessionStats(
        promptTokens: 0, cachedTokens: 0, evaluatedTokens: 0, generatedTokens: 0,
        prefillSeconds: 0, generationSeconds: 0, prefillTokensPerSecond: 0,
        generationTokensPerSecond: 0, position: 0, contextSize: 0
    )
}

/// Result of `generate` (also for `.cancelled` / `.callerStop`).
struct DS4GenerateResult: Sendable, Hashable {
    let outcome: DS4GenerateOutcome
    /// Every decoded character passed to `onText`, in order.
    let text: String
    /// The ids of the tokens this call committed to the session, in order
    /// (the ones `text` was decoded from): no stop token and none of the
    /// speculative tokens rewound after a stop. Replaying them as
    /// `DS4TranscriptOperation.tokens` keeps the turn a prefix of the live KV.
    /// Empty when the engine cannot report them.
    let tokens: [Int32]
    let stats: DS4SessionStats

    init(outcome: DS4GenerateOutcome, text: String, tokens: [Int32] = [], stats: DS4SessionStats) {
        self.outcome = outcome
        self.text = text
        self.tokens = tokens
        self.stats = stats
    }
}

enum DS4CheckpointSaveOutcome: Sendable, Hashable {
    case saved
    /// Nothing written: the session holds image-conditioned state.
    case skippedVision
}

// MARK: - Engine

/// An open DS4 model. Implementations are thread-safe; calls touching the
/// model are serialized in arrival order (`DS4NativeEngine` runs them on one
/// dedicated thread).
///
/// Sessions: each ZenCODE `sessionID` maps to one DS4 session created lazily
/// by the first `sync` / `loadCheckpoint`. At most `sessionCapacity` sessions
/// stay live; beyond that the least recently used one is freed (its KV is
/// rebuilt from the common prefix at its next sync, so eviction only costs
/// prefill time). The session of the last successful `sync` /
/// `loadCheckpoint` is pinned until its `generate` returns: it is evicted only
/// when it is the sole candidate, which under the registry's generation lease
/// means its turn is already over. Power and steering values set with
/// `setPower` / `setSteeringFFN` are remembered per `sessionID` and reapplied
/// when the session is recreated after an eviction.
///
/// Concurrency: callers must run `sync` + `generate` (and checkpoint
/// save/load) of a turn inside `DS4EngineRegistry.withGenerationLease`, which
/// admits one turn at a time in FIFO order.
///
/// Cancellation: cancelling the calling `Task` sets an atomic flag polled by
/// the DS4 cancel callback. An interrupted `sync` (or `loadCheckpoint` while
/// waiting for a distributed route) throws `CancellationError`; a cancelled
/// `generate` returns outcome `.cancelled` (not an error) so the caller keeps
/// the partial text. Calls on a closed engine throw `DS4EngineError.engineClosed`.
protocol DS4Engine: AnyObject, Sendable {
    var info: DS4EngineInfo { get }

    /// Tokens of the prompt built from `transcript` (no session involved).
    func tokenCount(of transcript: [DS4TranscriptOperation]) async throws -> Int
    /// Tokenizes `transcript` once (images included) and keeps the result for
    /// `sync(sessionID:prepared:)`, so a round that counts its prompt and then
    /// syncs it does not encode the images twice. The caller owns the result
    /// and releases it (`DS4PreparedTranscript.release()`) when the sync that
    /// uses it ends. Throws as `tokenCount(of:)`; a failed image encode is
    /// `DS4EngineError.vision`.
    func prepare(transcript: [DS4TranscriptOperation]) async throws -> DS4PreparedTranscript
    /// The prompt built from `transcript` rendered back to text.
    func renderText(of transcript: [DS4TranscriptOperation]) async throws -> String

    /// Explicit effort "0"..."100" -> `ThinkMode.levelBase + level`, nil when invalid.
    func thinkMode(parseLevel: String) -> Int32?
    /// Effective think mode for a context size (`.max` degrades to `.high`
    /// below the model's minimum context). Unknown modes are returned unchanged.
    func thinkMode(forContext mode: Int32, contextSize: Int) async -> Int32

    /// Synchronizes the session KV with the prompt built from `transcript`,
    /// creating the session when needed. `onProgress(event, current, total)`
    /// is called synchronously on the engine thread during prefill. Throws
    /// `contextExhausted` when the prompt does not fit, `CancellationError`
    /// when interrupted (the KV may then hold only a prefix: sync again).
    func sync(
        sessionID: String,
        transcript: [DS4TranscriptOperation],
        onProgress: @escaping @Sendable (_ event: String, _ current: Int, _ total: Int) -> Void
    ) async throws -> DS4SyncResult

    /// `sync(sessionID:transcript:onProgress:)` for a transcript tokenized by
    /// `prepare`: nothing is tokenized (or encoded) again. A transcript
    /// prepared by another engine instance (the engine was replaced meanwhile)
    /// is tokenized again from its operations. Does not release `prepared`.
    func sync(
        sessionID: String,
        prepared: DS4PreparedTranscript,
        onProgress: @escaping @Sendable (_ event: String, _ current: Int, _ total: Int) -> Void
    ) async throws -> DS4SyncResult

    /// Generates up to `maxTokens` tokens (clamped to the context room) after
    /// a successful `sync` / `loadCheckpoint` of the same session.
    ///
    /// `onText` is called synchronously from the DS4 emit callback, on the
    /// engine thread, once per committed token with the text decoded at
    /// valid UTF-8 boundaries (an empty string when the token only carries a
    /// partial scalar: it is still called so the caller can return flags).
    /// Its result becomes the emit flags of that token. When generation ends
    /// with undecodable trailing bytes, `onText` receives them once more
    /// (with U+FFFD replacements) and its result is ignored.
    func generate(
        sessionID: String,
        maxTokens: Int,
        thinkMode: Int32,
        sampling: DS4SamplingParameters,
        onText: @escaping @Sendable (String) -> DS4EmitDecision
    ) async throws -> DS4GenerateResult

    /// Stats of a live session, `.empty` otherwise.
    func stats(sessionID: String) async -> DS4SessionStats
    /// Number of sessions alive in the engine pool (at most `sessionCapacity`).
    func liveSessionCount() async -> Int
    /// Power percentage (1...100) for future evaluation of the session.
    func setPower(sessionID: String, percent: Int) async throws
    /// Directional-steering FFN scale (-100...100) for future evaluation of the session.
    func setSteeringFFN(sessionID: String, scale: Double) async throws

    /// Saves the live KV of the session to `url` (atomic). `trailer` is opaque
    /// caller data stored after the payload.
    func saveCheckpoint(sessionID: String, to url: URL, trailer: Data?) async throws -> DS4CheckpointSaveOutcome
    /// Loads a checkpoint into the session (created when needed) and returns
    /// its trailer. Throws `kvIncompatible` / `kvInvalid`; after a failed load
    /// sync the session again.
    func loadCheckpoint(sessionID: String, from url: URL) async throws -> Data?

    /// Frees the DS4 session of `sessionID` and forgets its settings.
    func releaseSession(_ sessionID: String) async
    /// Frees every session, then closes the engine (idempotent).
    func close() async
}

// MARK: - Prepared transcripts

extension DS4Engine {
    /// Engines without a reusable tokenization (test doubles): counts the
    /// tokens and keeps only the operations; `sync(sessionID:prepared:)`
    /// tokenizes them again.
    func prepare(transcript: [DS4TranscriptOperation]) async throws -> DS4PreparedTranscript {
        DS4PreparedTranscript(operations: transcript, tokenCount: try await tokenCount(of: transcript))
    }

    func sync(
        sessionID: String,
        prepared: DS4PreparedTranscript,
        onProgress: @escaping @Sendable (_ event: String, _ current: Int, _ total: Int) -> Void
    ) async throws -> DS4SyncResult {
        try await sync(sessionID: sessionID, transcript: prepared.operations, onProgress: onProgress)
    }
}
