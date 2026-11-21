//
//  DS4PreparedTranscript.swift
//  ZenCODE
//
//  A transcript tokenized once by an engine (`DS4Engine.prepare`) and then
//  reused by `DS4Engine.sync(sessionID:prepared:)`. A transcript with images
//  is expensive to tokenize (every image is encoded by the vision projector),
//  and a round both counts its tokens (compaction policy) and syncs them: the
//  prepared transcript keeps the native token buffer, which owns the encoded
//  embeddings, so each image is encoded once per round.
//
//  Ownership: the creator of a prepared transcript must `release()` it as soon
//  as the sync that uses it is over (successful or not). `release()` is
//  idempotent and does not wait: the native buffer is freed on the engine
//  thread. A transcript that is never released frees its buffer when it is
//  deallocated.
//

import Foundation
import Synchronization

/// Engine-private resource behind a prepared transcript (the native token
/// buffer with its vision spans).
protocol DS4PreparedPayload: AnyObject, Sendable {
    /// Frees the resource. Idempotent.
    func release()
}

/// Process-wide unique tokens identifying engine instances, so a prepared
/// transcript is never synced into an engine that did not produce it (a
/// replaced engine can reuse the address of the previous one).
enum DS4EngineInstanceToken {
    private static let counter = Atomic<UInt64>(0)

    static func next() -> UInt64 {
        counter.add(1, ordering: .relaxed).newValue
    }
}

final class DS4PreparedTranscript: Sendable {
    /// The operations that were tokenized. They stay available so an engine
    /// that cannot use the prepared payload (the engine was replaced between
    /// `prepare` and `sync`) tokenizes them again.
    let operations: [DS4TranscriptOperation]
    /// Tokens of the whole prompt.
    let tokenCount: Int
    /// `operationTokenCounts[i]` is the token count of the prompt made of
    /// `operations[0...i]`, when the engine recorded it (it saves tokenizing a
    /// prefix, and re-encoding its images, to locate a position in the prompt).
    let operationTokenCounts: [Int]?
    /// `DS4EngineInstanceToken` of the producing engine; 0 when the transcript
    /// carries no engine state.
    let ownerToken: UInt64
    let payload: (any DS4PreparedPayload)?

    init(
        operations: [DS4TranscriptOperation],
        tokenCount: Int,
        operationTokenCounts: [Int]? = nil,
        ownerToken: UInt64 = 0,
        payload: (any DS4PreparedPayload)? = nil
    ) {
        self.operations = operations
        self.tokenCount = tokenCount
        self.operationTokenCounts = operationTokenCounts
        self.ownerToken = ownerToken
        self.payload = payload
    }

    /// Tokens of the prompt made of the first `operationCount` operations, or
    /// `nil` when the engine did not record per-operation counts.
    func tokenCount(afterOperations operationCount: Int) -> Int? {
        guard let counts = operationTokenCounts,
              operationCount >= 0,
              operationCount <= counts.count else {
            return nil
        }
        return operationCount == 0 ? 0 : counts[operationCount - 1]
    }

    /// True when `token` is the instance token of the engine that prepared it.
    func isOwned(byEngineWithToken token: UInt64) -> Bool {
        ownerToken != 0 && ownerToken == token && payload != nil
    }

    /// Frees the engine-side resources. Idempotent; call it when the sync that
    /// uses this transcript has ended.
    func release() {
        payload?.release()
    }

    deinit {
        payload?.release()
    }
}

/// Native token buffer owned by a `DS4PreparedTranscript`. The handle is
/// freed through `free` on the engine thread (`submit`); when that thread no
/// longer accepts jobs the buffer is freed in place (a token buffer is
/// engine-independent storage).
final class DS4NativeTokenBuffer: DS4PreparedPayload, @unchecked Sendable {
    typealias Job = @Sendable () -> Void

    struct Handle: @unchecked Sendable {
        let raw: UnsafeMutableRawPointer
    }

    private let state: Mutex<Handle?>
    private let freeHandle: @Sendable (Handle) -> Void
    private let submit: @Sendable (@escaping Job) -> Bool

    init(
        handle: UnsafeMutableRawPointer,
        free freeHandle: @escaping @Sendable (Handle) -> Void,
        submit: @escaping @Sendable (@escaping Job) -> Bool
    ) {
        self.state = Mutex(Handle(raw: handle))
        self.freeHandle = freeHandle
        self.submit = submit
    }

    /// The live handle, `nil` once released. Only dereference it on the engine
    /// thread (releases are queued behind the job that uses it).
    var liveHandle: UnsafeMutableRawPointer? {
        let handle: Handle? = state.withLock { $0 }
        return handle?.raw
    }

    var isReleased: Bool {
        let handle: Handle? = state.withLock { $0 }
        return handle == nil
    }

    func release() {
        let taken = state.withLock { handle -> Handle? in
            defer { handle = nil }
            return handle
        }
        guard let taken else {
            return
        }
        let freeHandle = freeHandle
        if !submit({ freeHandle(taken) }) {
            freeHandle(taken)
        }
    }

    deinit {
        release()
    }
}
