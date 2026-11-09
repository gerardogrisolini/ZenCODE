//  Single-resume bridge from callbacks or blocking work to async Swift code.

import Synchronization

/// Thread-safe single-shot holder that bridges a callback or a blocking
/// operation to a `CheckedContinuation`.
///
/// The first result wins, whichever arrives first: an operation result, a
/// timeout, or a cancellation error. A result that arrives before
/// ``attach(_:)`` is kept and delivered on attach; every later result is
/// ignored, so the continuation is resumed exactly once. The box only
/// sequences resumes: it does not start, time out, or cancel any work.
public final class FeatureSingleResumeBox<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Value, Error>?
        var pending: Result<Value, Error>?
        var isResumed = false
    }

    private let state = Mutex(State())

    public init() {}

    /// Registers the continuation to resume. If a result already arrived, the
    /// continuation is resumed immediately with it.
    public func attach(_ continuation: CheckedContinuation<Value, Error>) {
        let early: Result<Value, Error>? = state.withLock { state in
            if let pending = state.pending {
                state.pending = nil
                state.isResumed = true
                return pending
            }
            state.continuation = continuation
            return nil
        }
        if let early {
            continuation.resume(with: early)
        }
    }

    /// Delivers `result` unless a previous result was already delivered or
    /// stored; in that case the call is ignored.
    public func resume(with result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>? = state.withLock { state in
            guard !state.isResumed else { return nil }
            if let continuation = state.continuation {
                state.continuation = nil
                state.isResumed = true
                return continuation
            }
            if state.pending == nil {
                state.pending = result
            }
            return nil
        }
        if let continuation {
            continuation.resume(with: result)
        }
    }

    public func resume(returning value: Value) {
        resume(with: .success(value))
    }

    public func resume(throwing error: Error) {
        resume(with: .failure(error))
    }
}
