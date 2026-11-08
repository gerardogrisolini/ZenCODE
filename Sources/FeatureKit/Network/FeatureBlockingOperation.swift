//  Cancellation-aware offload of blocking work from async Swift code.

import Dispatch

/// Runs blocking work, such as a synchronous DNS lookup, off the cooperative
/// thread pool.
public enum FeatureBlockingOperation {
    /// Runs `operation` on a global dispatch queue (never on the cooperative
    /// thread pool) and returns its result, or throws `CancellationError` as
    /// soon as the calling task is cancelled, whichever comes first. The
    /// continuation is resumed exactly once.
    ///
    /// Cancellation abandons the operation rather than interrupting it: a
    /// blocking call keeps running on its dispatch thread and its late result
    /// is discarded. The helper does not check cancellation before starting
    /// the operation, does not apply a timeout, and does not interpret the
    /// result: callers keep their own policy and validation.
    public static func run<Value: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let box = FeatureSingleResumeBox<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                box.attach(continuation)
                DispatchQueue.global(qos: qos).async {
                    let result = Result<Value, Error> { try operation() }
                    box.resume(with: result)
                }
            }
        } onCancel: {
            box.resume(throwing: CancellationError())
        }
    }
}
