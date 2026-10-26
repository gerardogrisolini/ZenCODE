//
//  DS4EngineLibrary.swift
//  ZenCODE
//
//  Loads `libzencode-ds4.{dylib,so}` with `dlopen(RTLD_NOW | RTLD_LOCAL)` and
//  resolves every ABI v2 symbol into `DS4EngineSymbols`. The library is never
//  unloaded once accepted: DS4 registers `atexit` handlers (instance lock) and
//  Metal/ObjC images cannot be unloaded anyway, so a library rebuilt at the
//  same path is picked up only by a new process. Rejected libraries (ABI
//  mismatch, missing symbol) are `dlclose`d.
//

import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Function pointers of every ABI v2 symbol. The pointers stay valid for the
/// process lifetime (the library is never unloaded). Engine-bound functions
/// must only be called on the engine thread of `DS4NativeEngine`.
struct DS4EngineSymbols: @unchecked Sendable {
    let abiVersion: DS4EngineABI.AbiVersionFunction
    let lastError: DS4EngineABI.LastErrorFunction
    let stringFree: DS4EngineABI.StringFreeFunction
    let engineOpenLog: DS4EngineABI.EngineOpenLogFunction
    let thinkModeParseLevel: DS4EngineABI.ThinkModeParseLevelFunction
    let thinkModeForContext: DS4EngineABI.ThinkModeForContextFunction
    let engineOpen: DS4EngineABI.EngineOpenFunction
    let engineClose: DS4EngineABI.EngineCloseFunction
    let engineLastError: DS4EngineABI.EngineStringFunction
    let engineModelName: DS4EngineABI.EngineStringFunction
    let engineModelID: DS4EngineABI.EngineInt32Function
    let engineRoutedQuantBits: DS4EngineABI.EngineInt32Function
    let engineHasVision: DS4EngineABI.EngineInt32Function
    let engineToolSyntax: DS4EngineABI.EngineInt32Function
    let engineMTPDraftTokens: DS4EngineABI.EngineInt32Function
    let tokensNew: DS4EngineABI.TokensNewFunction
    let tokensFree: DS4EngineABI.HandleFreeFunction
    let tokensLen: DS4EngineABI.HandleInt32Function
    let tokensGet: DS4EngineABI.TokensGetFunction
    let tokensImageCount: DS4EngineABI.HandleInt32Function
    let tokensCopy: DS4EngineABI.TokensCopyFunction
    let tokensPush: DS4EngineABI.TokensPushFunction
    let chatBegin: DS4EngineABI.EngineTokensFunction
    let chatAppendMessage: DS4EngineABI.ChatAppendMessageFunction
    let chatAppendThinkPrefix: DS4EngineABI.ChatAppendThinkModeFunction
    let chatAppendAssistantPrefix: DS4EngineABI.ChatAppendThinkModeFunction
    let tokenizeRenderedChat: DS4EngineABI.TokenizeRenderedChatFunction
    let tokensPushEOS: DS4EngineABI.EngineTokensFunction
    let renderTokensText: DS4EngineABI.RenderTokensTextFunction
    let engineVisionEncodeFile: DS4EngineABI.VisionEncodeFileFunction
    let visionEmbeddingFree: DS4EngineABI.HandleFreeFunction
    let chatAppendMultimodalMessage: DS4EngineABI.ChatAppendMultimodalMessageFunction
    let sessionCreate: DS4EngineABI.SessionCreateFunction
    let sessionFree: DS4EngineABI.HandleFreeFunction
    let sessionWaitDistributedRoute: DS4EngineABI.SessionWaitDistributedRouteFunction
    let sessionSync: DS4EngineABI.SessionSyncFunction
    let sessionPos: DS4EngineABI.HandleInt32Function
    let sessionCtx: DS4EngineABI.HandleInt32Function
    let sessionSetPower: DS4EngineABI.SessionSetPowerFunction
    let sessionSetDirectionalSteeringFFN: DS4EngineABI.SessionSetSteeringFunction
    let sessionGenerate: DS4EngineABI.SessionGenerateFunction
    let stat: DS4EngineABI.StatFunction
    let sessionTranscriptLen: DS4EngineABI.HandleInt32Function
    let sessionTranscriptAppendTo: DS4EngineABI.SessionTranscriptAppendFunction
    let sessionKVSave: DS4EngineABI.SessionKVSaveFunction
    let sessionKVLoad: DS4EngineABI.SessionKVLoadFunction

    /// Resolves every symbol of `DS4EngineABI.symbolNames` from `resolve`.
    init(resolve: (String) throws -> UnsafeMutableRawPointer) throws {
        func symbol<Function>(_ name: String, _: Function.Type = Function.self) throws -> Function {
            unsafeBitCast(try resolve(name), to: Function.self)
        }
        abiVersion = try symbol("zencode_ds4_abi_version")
        lastError = try symbol("zencode_ds4_last_error")
        stringFree = try symbol("zencode_ds4_string_free")
        engineOpenLog = try symbol("zencode_ds4_engine_open_log")
        thinkModeParseLevel = try symbol("zencode_ds4_think_mode_parse_level")
        thinkModeForContext = try symbol("zencode_ds4_think_mode_for_context")
        engineOpen = try symbol("zencode_ds4_engine_open")
        engineClose = try symbol("zencode_ds4_engine_close")
        engineLastError = try symbol("zencode_ds4_engine_last_error")
        engineModelName = try symbol("zencode_ds4_engine_model_name")
        engineModelID = try symbol("zencode_ds4_engine_model_id")
        engineRoutedQuantBits = try symbol("zencode_ds4_engine_routed_quant_bits")
        engineHasVision = try symbol("zencode_ds4_engine_has_vision")
        engineToolSyntax = try symbol("zencode_ds4_engine_tool_syntax")
        engineMTPDraftTokens = try symbol("zencode_ds4_engine_mtp_draft_tokens")
        tokensNew = try symbol("zencode_ds4_tokens_new")
        tokensFree = try symbol("zencode_ds4_tokens_free")
        tokensLen = try symbol("zencode_ds4_tokens_len")
        tokensGet = try symbol("zencode_ds4_tokens_get")
        tokensImageCount = try symbol("zencode_ds4_tokens_image_count")
        tokensCopy = try symbol("zencode_ds4_tokens_copy")
        tokensPush = try symbol("zencode_ds4_tokens_push")
        chatBegin = try symbol("zencode_ds4_chat_begin")
        chatAppendMessage = try symbol("zencode_ds4_chat_append_message")
        chatAppendThinkPrefix = try symbol("zencode_ds4_chat_append_think_prefix")
        chatAppendAssistantPrefix = try symbol("zencode_ds4_chat_append_assistant_prefix")
        tokenizeRenderedChat = try symbol("zencode_ds4_tokenize_rendered_chat")
        tokensPushEOS = try symbol("zencode_ds4_tokens_push_eos")
        renderTokensText = try symbol("zencode_ds4_render_tokens_text")
        engineVisionEncodeFile = try symbol("zencode_ds4_engine_vision_encode_file")
        visionEmbeddingFree = try symbol("zencode_ds4_vision_embedding_free")
        chatAppendMultimodalMessage = try symbol("zencode_ds4_chat_append_multimodal_message")
        sessionCreate = try symbol("zencode_ds4_session_create")
        sessionFree = try symbol("zencode_ds4_session_free")
        sessionWaitDistributedRoute = try symbol("zencode_ds4_session_wait_distributed_route")
        sessionSync = try symbol("zencode_ds4_session_sync")
        sessionPos = try symbol("zencode_ds4_session_pos")
        sessionCtx = try symbol("zencode_ds4_session_ctx")
        sessionSetPower = try symbol("zencode_ds4_session_set_power")
        sessionSetDirectionalSteeringFFN = try symbol("zencode_ds4_session_set_directional_steering_ffn")
        sessionGenerate = try symbol("zencode_ds4_session_generate")
        stat = try symbol("zencode_ds4_stat")
        sessionTranscriptLen = try symbol("zencode_ds4_session_transcript_len")
        sessionTranscriptAppendTo = try symbol("zencode_ds4_session_transcript_append_to")
        sessionKVSave = try symbol("zencode_ds4_session_kv_save")
        sessionKVLoad = try symbol("zencode_ds4_session_kv_load")
    }
}

/// A loaded and ABI-checked engine library.
final class DS4EngineLibrary: Sendable {
    /// Resolved path the library was loaded from.
    let path: String
    let abiVersion: Int32
    let symbols: DS4EngineSymbols

    private static let loaded = Mutex<[String: DS4EngineLibrary]>([:])

    private init(path: String, abiVersion: Int32, symbols: DS4EngineSymbols) {
        self.path = path
        self.abiVersion = abiVersion
        self.symbols = symbols
    }

    /// Loads (or returns the already loaded) library at `url`.
    ///
    /// - Throws: `DS4EngineError.libraryUnavailable` when the file is missing
    ///   or `dlopen` fails, `.abiMismatch` when `zencode_ds4_abi_version`
    ///   differs from `DS4EngineABI.expectedVersion`, `.missingSymbol` when an
    ///   ABI symbol is not exported. `buildHint` is the manual build command
    ///   included in each of them.
    static func load(at url: URL, buildHint: String) throws -> DS4EngineLibrary {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return try loaded.withLock { cache in
            if let library = cache[path] {
                return library
            }
            let library = try open(path: path, buildHint: buildHint)
            cache[path] = library
            return library
        }
    }

    private static func open(path: String, buildHint: String) throws -> DS4EngineLibrary {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw DS4EngineError.libraryUnavailable(
                reason: "\(DS4EngineABI.libraryFileName) not found at \(path)",
                hint: buildHint
            )
        }
        _ = dlerror()
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let loaderError = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            throw DS4EngineError.libraryUnavailable(
                reason: "cannot load \(path): \(loaderError)",
                hint: buildHint
            )
        }
        do {
            let resolve: (String) throws -> UnsafeMutableRawPointer = { name in
                guard let address = dlsym(handle, name) else {
                    throw DS4EngineError.missingSymbol(name, hint: buildHint)
                }
                return address
            }
            let versionFunction = unsafeBitCast(
                try resolve("zencode_ds4_abi_version"),
                to: DS4EngineABI.AbiVersionFunction.self
            )
            let version = versionFunction()
            guard version == DS4EngineABI.expectedVersion else {
                throw DS4EngineError.abiMismatch(
                    found: version,
                    expected: DS4EngineABI.expectedVersion,
                    hint: buildHint
                )
            }
            let symbols = try DS4EngineSymbols(resolve: resolve)
            return DS4EngineLibrary(path: path, abiVersion: version, symbols: symbols)
        } catch {
            dlclose(handle)
            throw error
        }
    }

    /// `zencode_ds4_think_mode_parse_level`: "0"..."100" ->
    /// `ThinkMode.levelBase + level`, nil when invalid. Pure function (its
    /// error buffer is thread-local), safe on any thread.
    func thinkMode(parseLevel text: String) -> Int32? {
        let mode = text.withCString { symbols.thinkModeParseLevel($0) }
        return mode < 0 ? nil : mode
    }
}
