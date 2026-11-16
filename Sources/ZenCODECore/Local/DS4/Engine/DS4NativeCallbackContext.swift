//
//  DS4NativeCallbackContext.swift
//  ZenCODE
//
//  The C callbacks of the DS4 shim and their `void *ud` context: progress,
//  streamed text and the cancellation flag polled on the engine thread.
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
    func finishText() {
        let tail = decoder.finish()
        guard !tail.isEmpty else {
            return
        }
        text += tail
        _ = onText?(tail)
    }

    func withUserData<Result>(_ body: (UnsafeMutableRawPointer) throws -> Result) rethrows -> Result {
        try withExtendedLifetime(self) {
            try body(Unmanaged.passUnretained(self).toOpaque())
        }
    }

    fileprivate static func from(_ userData: UnsafeMutableRawPointer?) -> DS4NativeCallbackContext? {
        userData.map { Unmanaged<DS4NativeCallbackContext>.fromOpaque($0).takeUnretainedValue() }
    }
}

/// C callbacks of the shim (capture-free, so they convert to C function pointers).
enum DS4NativeCallbacks {
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
