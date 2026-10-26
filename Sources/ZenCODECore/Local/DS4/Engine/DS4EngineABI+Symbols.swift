//
//  DS4EngineABI+Symbols.swift
//  ZenCODE
//
//  Swift mirror of `zencode_ds4_abi.h` (ABI v2): one `@convention(c)`
//  typealias per exported function, the callback types and every constant.
//  `zen` never links DS4: `DS4EngineLibrary` resolves each symbol with
//  `dlsym` and casts it to these types, so a signature here must match the
//  header exactly. `DS4EngineLibraryTests` parses the header and fails when a
//  symbol or constant drifts.
//
//  C mapping: `void *` -> `UnsafeMutableRawPointer?`, `const char *` ->
//  `UnsafePointer<CChar>?`, `char *` -> `UnsafeMutablePointer<CChar>?`,
//  `size_t` -> `Int` (same width and calling convention as Swift's own import),
//  `int32_t` -> `Int32`, `uint64_t` -> `UInt64`, `double` -> `Double`.
//

import Foundation

extension DS4EngineABI {
    // MARK: Return codes

    static let ok: Int32 = 0
    /// `zencode_ds4_session_sync`: the cancel callback interrupted the prefill.
    static let syncInterrupted: Int32 = 2
    /// `zencode_ds4_session_kv_save`: nothing written (image-conditioned session).
    static let kvSkippedVision: Int32 = 1

    /// `zencode_ds4_session_generate` outcomes.
    enum GenerateOutcomeCode {
        static let stop: Int32 = 0
        static let maxTokens: Int32 = 1
        static let cancelled: Int32 = 2
        static let callerStop: Int32 = 3
    }

    /// Bit flags returned by the emit callback.
    enum EmitFlag {
        static let `continue`: Int32 = 0
        static let stop: Int32 = 1
        static let greedy: Int32 = 2
    }

    /// `ZENCODE_DS4_ERR_*` (negative return values).
    enum ErrorCode {
        static let invalidArgument: Int32 = -1
        static let outOfMemory: Int32 = -2
        static let invalidOption: Int32 = -3
        static let instanceLocked: Int32 = -4
        static let engineOpen: Int32 = -5
        static let session: Int32 = -6
        static let decode: Int32 = -7
        static let unsupported: Int32 = -8
        static let vision: Int32 = -9
        static let io: Int32 = -10
        static let kvInvalid: Int32 = -11
        static let kvIncompatible: Int32 = -12
        static let tensorParallel: Int32 = -13
        static let busy: Int32 = -14
    }

    /// `ZENCODE_DS4_THINK_*`: same values as `ds4_think_mode`. Explicit effort
    /// levels are `levelBase + level` with `level` in `0...levelMax`.
    enum ThinkMode {
        static let none: Int32 = 0
        static let high: Int32 = 1
        static let max: Int32 = 2
        static let low: Int32 = 3
        static let medium: Int32 = 4
        static let levelBase: Int32 = 1000
        static let levelMax: Int32 = 100
    }

    /// `ZENCODE_DS4_TOOL_SYNTAX_*` of the loaded model.
    enum ToolSyntax {
        static let dsml: Int32 = 0
        static let dsml41: Int32 = 1
        static let glm: Int32 = 2
        static let qwen: Int32 = 3
    }

    /// `ZENCODE_DS4_STAT_*` ids read with `zencode_ds4_stat`.
    enum StatID {
        static let promptTokens: Int32 = 0
        static let cachedTokens: Int32 = 1
        static let evaluatedTokens: Int32 = 2
        static let generatedTokens: Int32 = 3
        static let prefillSeconds: Int32 = 4
        static let generationSeconds: Int32 = 5
        static let prefillTokensPerSecond: Int32 = 6
        static let generationTokensPerSecond: Int32 = 7
        static let sessionPosition: Int32 = 8
        static let sessionContext: Int32 = 9
        static let count: Int32 = 10
    }

    // MARK: Callbacks

    /// `zencode_ds4_progress_fn(void *ud, const char *event, int current, int total)`.
    typealias ProgressFunction = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, Int32
    ) -> Void
    /// `zencode_ds4_cancel_fn(void *ud)`: non-zero cancels.
    typealias CancelFunction = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    /// `zencode_ds4_emit_fn(void *ud, const char *bytes, size_t len)`: returns `EmitFlag` bits.
    typealias EmitFunction = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int
    ) -> Int32

    // MARK: Library

    typealias AbiVersionFunction = @convention(c) () -> Int32
    typealias LastErrorFunction = @convention(c) () -> UnsafePointer<CChar>?
    typealias StringFreeFunction = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    typealias EngineOpenLogFunction = @convention(c) () -> UnsafePointer<CChar>?
    typealias ThinkModeParseLevelFunction = @convention(c) (UnsafePointer<CChar>?) -> Int32
    typealias ThinkModeForContextFunction = @convention(c) (Int32, Int32) -> Int32

    // MARK: Engine

    typealias EngineOpenFunction = @convention(c) (
        UnsafePointer<UnsafePointer<CChar>?>?, Int, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    ) -> Int32
    typealias EngineCloseFunction = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias EngineStringFunction = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
    typealias EngineInt32Function = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    // MARK: Token buffers

    typealias TokensNewFunction = @convention(c) () -> UnsafeMutableRawPointer?
    typealias HandleFreeFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias HandleInt32Function = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias TokensGetFunction = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    /// `zencode_ds4_tokens_push(void *tokens, int32_t token)`.
    typealias TokensPushFunction = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    typealias TokensCopyFunction = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias EngineTokensFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    typealias ChatAppendMessageFunction = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Int32
    typealias ChatAppendThinkModeFunction = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32
    ) -> Int32
    typealias TokenizeRenderedChatFunction = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<CChar>?
    ) -> Int32
    typealias RenderTokensTextFunction = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int>?
    ) -> UnsafeMutablePointer<CChar>?

    // MARK: Vision

    typealias VisionEncodeFileFunction = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?
    ) -> UnsafeMutableRawPointer?
    typealias ChatAppendMultimodalMessageFunction = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<CChar>?,
        UnsafePointer<UnsafePointer<CChar>?>?, Int,
        UnsafePointer<UnsafeMutableRawPointer?>?, Int
    ) -> Int32

    // MARK: Sessions

    typealias SessionCreateFunction = @convention(c) (
        UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    ) -> Int32
    typealias SessionWaitDistributedRouteFunction = @convention(c) (
        UnsafeMutableRawPointer?, ProgressFunction?, CancelFunction?, UnsafeMutableRawPointer?
    ) -> Int32
    typealias SessionSyncFunction = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, ProgressFunction?, CancelFunction?,
        UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?
    ) -> Int32
    typealias SessionSetPowerFunction = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    typealias SessionSetSteeringFunction = @convention(c) (UnsafeMutableRawPointer?, Double) -> Int32
    typealias SessionGenerateFunction = @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int32, Double, Int32, Double, Double, UInt64,
        EmitFunction?, CancelFunction?, UnsafeMutableRawPointer?
    ) -> Int32
    typealias StatFunction = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Double
    typealias SessionTranscriptAppendFunction = @convention(c) (
        UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?
    ) -> Int32

    // MARK: Disk KV checkpoints

    typealias SessionKVSaveFunction = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int
    ) -> Int32
    typealias SessionKVLoadFunction = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<Int>?
    ) -> Int32

    /// Every function exported by ABI v2, in header order. `DS4EngineSymbols`
    /// resolves exactly this list.
    static let symbolNames: [String] = [
        "zencode_ds4_abi_version",
        "zencode_ds4_last_error",
        "zencode_ds4_string_free",
        "zencode_ds4_engine_open_log",
        "zencode_ds4_think_mode_parse_level",
        "zencode_ds4_think_mode_for_context",
        "zencode_ds4_engine_open",
        "zencode_ds4_engine_close",
        "zencode_ds4_engine_last_error",
        "zencode_ds4_engine_model_name",
        "zencode_ds4_engine_model_id",
        "zencode_ds4_engine_routed_quant_bits",
        "zencode_ds4_engine_has_vision",
        "zencode_ds4_engine_tool_syntax",
        "zencode_ds4_engine_mtp_draft_tokens",
        "zencode_ds4_tokens_new",
        "zencode_ds4_tokens_free",
        "zencode_ds4_tokens_len",
        "zencode_ds4_tokens_get",
        "zencode_ds4_tokens_image_count",
        "zencode_ds4_tokens_copy",
        "zencode_ds4_tokens_push",
        "zencode_ds4_chat_begin",
        "zencode_ds4_chat_append_message",
        "zencode_ds4_chat_append_think_prefix",
        "zencode_ds4_chat_append_assistant_prefix",
        "zencode_ds4_tokenize_rendered_chat",
        "zencode_ds4_tokens_push_eos",
        "zencode_ds4_render_tokens_text",
        "zencode_ds4_engine_vision_encode_file",
        "zencode_ds4_vision_embedding_free",
        "zencode_ds4_chat_append_multimodal_message",
        "zencode_ds4_session_create",
        "zencode_ds4_session_free",
        "zencode_ds4_session_wait_distributed_route",
        "zencode_ds4_session_sync",
        "zencode_ds4_session_pos",
        "zencode_ds4_session_ctx",
        "zencode_ds4_session_set_power",
        "zencode_ds4_session_set_directional_steering_ffn",
        "zencode_ds4_session_generate",
        "zencode_ds4_stat",
        "zencode_ds4_session_transcript_len",
        "zencode_ds4_session_transcript_append_to",
        "zencode_ds4_session_kv_save",
        "zencode_ds4_session_kv_load"
    ]
}
