//
//  DS4Runtime.swift
//  ZenCODE
//

import DS4RuntimeShim
import Foundation

struct DS4RuntimeOptions: Sendable {
    enum Backend: String, Sendable {
        case metal
        case cuda
        case cpu

        var cValue: zencode_ds4_backend {
            switch self {
            case .metal:
                return ZENCODE_DS4_BACKEND_METAL
            case .cuda:
                return ZENCODE_DS4_BACKEND_CUDA
            case .cpu:
                return ZENCODE_DS4_BACKEND_CPU
            }
        }
    }

    let ds4Root: URL
    let libraryURL: URL
    let modelURL: URL
    let mtpURL: URL?
    let backend: Backend
    let contextWindow: Int
    let nThreads: Int
    let prefillChunk: UInt32
    let mtpDraftTokens: Int
    let mtpMargin: Float
    let powerPercent: Int
    let ssdStreamingCacheExperts: UInt32
    let ssdStreamingCacheBytes: UInt64
    let ssdStreamingPreloadExperts: UInt32
    let ssdStreaming: Bool
    let ssdStreamingCold: Bool
    let quality: Bool
    let maxOutputTokens: Int?
    let temperature: Float
    let topK: Int
    let topP: Float
    let minP: Float
    let seed: UInt64

    var modelID: String {
        modelURL.path
    }
}

struct DS4GenerationResult: Sendable {
    let rawText: String
    let stats: zencode_ds4_generation_stats
}

enum DS4RuntimeError: LocalizedError {
    case openFailed(String)
    case sessionFailed(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Unable to open DS4 runtime: \(message)"
        case .sessionFailed(let message):
            return "Unable to create DS4 session: \(message)"
        case .generationFailed(let message):
            return "DS4 generation failed: \(message)"
        }
    }
}

final class DS4Engine {
    private var pointer: OpaquePointer?
    let options: DS4RuntimeOptions

    init(options: DS4RuntimeOptions) throws {
        self.options = options
        var opened: OpaquePointer?
        let message = Self.withErrorBuffer { errorBuffer, errorLength in
            options.ds4Root.path.withCString { root in
                options.libraryURL.path.withCString { library in
                    options.modelURL.path.withCString { model in
                        withOptionalCString(options.mtpURL?.path) { mtp in
                            var cOptions = zencode_ds4_engine_options()
                            cOptions.ds4_root = root
                            cOptions.library_path = library
                            cOptions.model_path = model
                            cOptions.mtp_path = mtp
                            cOptions.backend = options.backend.cValue
                            cOptions.n_threads = Int32(options.nThreads)
                            cOptions.prefill_chunk = options.prefillChunk
                            cOptions.mtp_draft_tokens = Int32(options.mtpDraftTokens)
                            cOptions.mtp_margin = options.mtpMargin
                            cOptions.power_percent = Int32(options.powerPercent)
                            cOptions.ssd_streaming_cache_experts = options.ssdStreamingCacheExperts
                            cOptions.ssd_streaming_cache_bytes = options.ssdStreamingCacheBytes
                            cOptions.ssd_streaming_preload_experts = options.ssdStreamingPreloadExperts
                            cOptions.ssd_streaming = options.ssdStreaming
                            cOptions.ssd_streaming_cold = options.ssdStreamingCold
                            cOptions.quality = options.quality
                            return zencode_ds4_engine_open(
                                &cOptions,
                                &opened,
                                errorBuffer,
                                errorLength
                            )
                        }
                    }
                }
            }
        }
        guard message.returnCode == 0, let opened else {
            throw DS4RuntimeError.openFailed(message.error)
        }
        pointer = opened
    }

    deinit {
        if let pointer {
            zencode_ds4_engine_close(pointer)
        }
    }

    func createSession(contextWindow: Int) throws -> DS4Session {
        guard let pointer else {
            throw DS4RuntimeError.sessionFailed("engine already closed")
        }
        var session: OpaquePointer?
        let message = Self.withErrorBuffer { errorBuffer, errorLength in
            zencode_ds4_session_create(
                pointer,
                Int32(contextWindow),
                &session,
                errorBuffer,
                errorLength
            )
        }
        guard message.returnCode == 0, let session else {
            throw DS4RuntimeError.sessionFailed(message.error)
        }
        return DS4Session(pointer: session)
    }

    var modelName: String? {
        guard let pointer,
              let cString = zencode_ds4_engine_model_name(pointer) else {
            return nil
        }
        return String(cString: cString)
    }

    fileprivate static func withErrorBuffer(
        _ body: (UnsafeMutablePointer<CChar>, Int) throws -> Int32
    ) rethrows -> (returnCode: Int32, error: String) {
        var buffer = [CChar](repeating: 0, count: 512)
        let returnCode = try buffer.withUnsafeMutableBufferPointer { pointer in
            try body(pointer.baseAddress!, pointer.count)
        }
        let error = buffer.withUnsafeBufferPointer { pointer in
            String(cString: pointer.baseAddress!)
        }
        return (returnCode, error.isEmpty ? "unknown error" : error)
    }
}

final class DS4Session: @unchecked Sendable {
    private var pointer: OpaquePointer?

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        if let pointer {
            zencode_ds4_session_free(pointer)
        }
    }

    func reset() {
        guard let pointer else { return }
        zencode_ds4_session_reset(pointer)
    }

    func appendMessage(role: String, content: String) {
        guard let pointer else { return }
        role.withCString { rolePointer in
            content.withCString { contentPointer in
                zencode_ds4_session_append_message(
                    pointer,
                    rolePointer,
                    contentPointer
                )
            }
        }
    }

    func appendEOS() {
        guard let pointer else { return }
        zencode_ds4_session_append_eos(pointer)
    }

    func generate(
        prompt: String?,
        maxTokens: Int,
        temperature: Float,
        topK: Int,
        topP: Float,
        minP: Float,
        seed: UInt64,
        thinkMode: zencode_ds4_think_mode
    ) throws -> DS4GenerationResult {
        guard let pointer else {
            throw DS4RuntimeError.generationFailed("session already closed")
        }

        let collector = DS4ChunkCollector()
        var stats = zencode_ds4_generation_stats()
        let userData = Unmanaged.passUnretained(collector).toOpaque()
        let message = DS4Engine.withErrorBuffer { errorBuffer, errorLength in
            let generate: (UnsafePointer<CChar>?) -> Int32 = { promptPointer in
                zencode_ds4_session_generate(
                    pointer,
                    promptPointer,
                    Int32(maxTokens),
                    temperature,
                    Int32(topK),
                    topP,
                    minP,
                    seed,
                    thinkMode,
                    ds4ChunkCollectorCallback,
                    userData,
                    &stats,
                    errorBuffer,
                    errorLength
                )
            }
            guard let prompt else {
                return generate(nil)
            }
            return prompt.withCString { generate($0) }
        }
        guard message.returnCode == 0 else {
            throw DS4RuntimeError.generationFailed(message.error)
        }
        return DS4GenerationResult(
            rawText: String(decoding: collector.data, as: UTF8.self),
            stats: stats
        )
    }

    var transcriptLength: Int {
        guard let pointer else { return 0 }
        return Int(zencode_ds4_session_transcript_len(pointer))
    }

    var sessionPosition: Int {
        guard let pointer else { return 0 }
        return Int(zencode_ds4_session_pos(pointer))
    }

    var contextWindow: Int {
        guard let pointer else { return 0 }
        return Int(zencode_ds4_session_ctx(pointer))
    }
}

private final class DS4ChunkCollector {
    var data = Data()
}

private let ds4ChunkCollectorCallback: zencode_ds4_emit_fn = { userData, bytes, length in
    guard let userData, let bytes, length > 0 else {
        return
    }
    let collector = Unmanaged<DS4ChunkCollector>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let buffer = UnsafeBufferPointer(
        start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self),
        count: length
    )
    collector.data.append(buffer)
}

private func withOptionalCString<Result>(
    _ value: String?,
    _ body: (UnsafePointer<CChar>?) throws -> Result
) rethrows -> Result {
    guard let value else {
        return try body(nil)
    }
    return try value.withCString { pointer in
        try body(pointer)
    }
}
