//
//  DS4EngineError.swift
//  ZenCODE
//
//  Errors of the in-process DS4 engine. Every `ZENCODE_DS4_ERR_*` code maps to
//  one case (see `init(code:message:)`), carrying the shim message read from
//  `zencode_ds4_engine_last_error` / `zencode_ds4_last_error` on the engine
//  thread. Library-level failures (`libraryUnavailable`, `abiMismatch`,
//  `missingSymbol`) carry the manual build command so the user can rebuild a
//  missing or stale `libzencode-ds4`.
//

import Foundation

enum DS4EngineError: LocalizedError, Sendable, Equatable {
    /// The dynamic library is missing or `dlopen` failed. `reason` names the
    /// path and the loader error, `hint` is the manual build command.
    case libraryUnavailable(reason: String, hint: String)
    /// The library reports a different `zencode_ds4_abi_version` (stale build).
    case abiMismatch(found: Int32, expected: Int32, hint: String)
    /// The library does not export a symbol of the expected ABI (stale or foreign build).
    case missingSymbol(String, hint: String)
    /// `ZENCODE_DS4_ERR_ENGINE_OPEN`: `ds4_engine_open` failed; the message
    /// includes the tail of the captured DS4 stderr.
    case openFailed(String)
    /// `ZENCODE_DS4_ERR_INSTANCE_LOCKED`: the DS4 instance lock is held by
    /// another process (ds4-server, ds4-agent, another ZenCODE) or by an
    /// engine already open in this process.
    case instanceLocked(String)
    /// The prompt does not fit the session context (DS4 needs one token of
    /// generation room: `used >= limit`).
    case contextExhausted(used: Int, limit: Int)
    /// `ZENCODE_DS4_ERR_SESSION`: session create / sync failure, or a call on
    /// a session that is not live.
    case sessionFailed(String)
    /// `ZENCODE_DS4_ERR_DECODE`: sampling / eval failure during generate.
    case decodeFailed(String)
    /// `ZENCODE_DS4_ERR_KV_INCOMPATIBLE`: checkpoint not usable by this engine/session.
    case kvIncompatible(String)
    /// `ZENCODE_DS4_ERR_KV_INVALID`: malformed or truncated checkpoint.
    case kvInvalid(String)
    /// `ZENCODE_DS4_ERR_UNSUPPORTED`: feature not supported by model/backend.
    case unsupported(String)
    /// `ZENCODE_DS4_ERR_INVALID_ARGUMENT`.
    case invalidArgument(String)
    /// `ZENCODE_DS4_ERR_INVALID_OPTION`: unknown/duplicated/invalid engine
    /// option, or a model/MTP/vision file that cannot be opened.
    case invalidOption(String)
    /// `ZENCODE_DS4_ERR_OUT_OF_MEMORY`.
    case outOfMemory(String)
    /// `ZENCODE_DS4_ERR_VISION`: image decode / encode / append failure.
    case vision(String)
    /// `ZENCODE_DS4_ERR_IO`: filesystem error.
    case io(String)
    /// `ZENCODE_DS4_ERR_TENSOR_PARALLEL`: TP leader bring-up failure.
    case tensorParallel(String)
    /// `ZENCODE_DS4_ERR_BUSY`: the engine still has live sessions.
    case busy(String)
    /// The engine was closed (shutdown or replaced by another configuration).
    case engineClosed

    /// Maps a negative `ZENCODE_DS4_ERR_*` return code to an error.
    init(code: Int32, message: String) {
        let text = message.isEmpty ? "unknown DS4 engine error (code \(code))" : message
        switch code {
        case DS4EngineABI.ErrorCode.invalidArgument: self = .invalidArgument(text)
        case DS4EngineABI.ErrorCode.outOfMemory: self = .outOfMemory(text)
        case DS4EngineABI.ErrorCode.invalidOption: self = .invalidOption(text)
        case DS4EngineABI.ErrorCode.instanceLocked: self = .instanceLocked(text)
        case DS4EngineABI.ErrorCode.engineOpen: self = .openFailed(text)
        case DS4EngineABI.ErrorCode.session: self = .sessionFailed(text)
        case DS4EngineABI.ErrorCode.decode: self = .decodeFailed(text)
        case DS4EngineABI.ErrorCode.unsupported: self = .unsupported(text)
        case DS4EngineABI.ErrorCode.vision: self = .vision(text)
        case DS4EngineABI.ErrorCode.io: self = .io(text)
        case DS4EngineABI.ErrorCode.kvInvalid: self = .kvInvalid(text)
        case DS4EngineABI.ErrorCode.kvIncompatible: self = .kvIncompatible(text)
        case DS4EngineABI.ErrorCode.tensorParallel: self = .tensorParallel(text)
        case DS4EngineABI.ErrorCode.busy: self = .busy(text)
        default: self = .sessionFailed("\(text) (unexpected DS4 return code \(code))")
        }
    }

    /// True when the library itself cannot be used and must be (re)built.
    var isLibraryUnavailable: Bool {
        buildHint != nil
    }

    /// Manual build command for library-level failures.
    var buildHint: String? {
        switch self {
        case .libraryUnavailable(_, let hint), .abiMismatch(_, _, let hint), .missingSymbol(_, let hint):
            hint
        default:
            nil
        }
    }

    static let instanceLockedSuggestion = "another DS4 process is using this model"

    var errorDescription: String? {
        switch self {
        case .libraryUnavailable(let reason, let hint):
            "The DS4 engine library is unavailable: \(reason). Rebuild it with: \(hint)"
        case .abiMismatch(let found, let expected, let hint):
            "The DS4 engine library reports ABI version \(found) but ZenCODE expects \(expected) "
                + "(stale build). Rebuild it with: \(hint)"
        case .missingSymbol(let name, let hint):
            "The DS4 engine library does not export \(name) (stale or foreign build). "
                + "Rebuild it with: \(hint)"
        case .openFailed(let message):
            "Unable to open the DS4 engine: \(message)"
        case .instanceLocked(let message):
            "DS4 instance lock is held (\(message)): \(Self.instanceLockedSuggestion). "
                + "Stop the other ds4-server/ds4-agent/ZenCODE session and retry."
        case .contextExhausted(let used, let limit):
            "The DS4 context is exhausted: the prompt needs \(used) tokens but the context holds "
                + "\(limit) (one token of generation room is required)."
        case .sessionFailed(let message):
            "DS4 session failure: \(message)"
        case .decodeFailed(let message):
            "DS4 generation failed: \(message)"
        case .kvIncompatible(let message):
            "The DS4 KV checkpoint is not compatible with this engine: \(message)"
        case .kvInvalid(let message):
            "The DS4 KV checkpoint is invalid: \(message)"
        case .unsupported(let message):
            "Not supported by this DS4 model or backend: \(message)"
        case .invalidArgument(let message):
            "Invalid DS4 engine argument: \(message)"
        case .invalidOption(let message):
            "Invalid DS4 engine option: \(message)"
        case .outOfMemory(let message):
            "DS4 engine out of memory: \(message)"
        case .vision(let message):
            "DS4 vision failure: \(message)"
        case .io(let message):
            "DS4 engine I/O error: \(message)"
        case .tensorParallel(let message):
            "DS4 tensor-parallel failure: \(message)"
        case .busy(let message):
            "The DS4 engine is busy: \(message)"
        case .engineClosed:
            "The DS4 engine was closed (shut down or replaced by another model configuration)."
        }
    }
}
