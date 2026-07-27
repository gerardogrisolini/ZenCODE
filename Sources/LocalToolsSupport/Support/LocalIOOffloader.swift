//
//  LocalIOOffloader.swift
//  LocalToolsSupport
//
//  Offloads integral, blocking file/text I/O away from Swift's cooperative
//  concurrency thread pool and honors cooperative Task cancellation.
//

import Foundation

/// Runs blocking, integral file/text I/O off the cooperative thread pool and
/// honors cooperative `Task` cancellation.
///
/// `DirectToolExecutor` invokes the core local file/text tools `async`, but
/// their work is fundamentally blocking: `String(contentsOf:)`, `Data(contentsOf:)`,
/// `String.write(to:)`, `FileHandle`, and `FileManager` directory operations all
/// perform synchronous syscalls. Running those on Swift's cooperative thread
/// pool is unsafe: the pool only keeps as many threads as CPU cores, so a
/// handful of concurrent large reads/writes can stall every other `async` task
/// in the process — including unrelated actor work.
///
/// `Task.detached` is *not* a remedy here: a detached task still executes on the
/// very same cooperative pool, so it does not actually offload the blocking
/// syscall — it only hides it behind a new task. This helper instead hops the
/// blocking work onto a dedicated GCD concurrent queue (whose thread count can
/// grow to absorb blocking calls) and bridges the result back through a
/// continuation.
///
/// A blocking syscall in flight cannot be interrupted, so cancellation is
/// honored at the boundaries this helper controls: the operation fails fast with
/// `CancellationError` when the surrounding task is already cancelled before the
/// work is scheduled, and callers that loop over many files/edits should call
/// `try Task.checkCancellation()` between iterations.
enum LocalIOOffloader {
    /// Dedicated, overcommit-friendly concurrent queue for integral blocking
    /// file/text I/O. GCD manages its own elastic thread pool, unlike the
    /// fixed-size cooperative pool, so blocking syscalls cannot starve it.
    private static let ioQueue = DispatchQueue(
        label: "com.zencode.local-tools.io",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Runs `operation` on the dedicated I/O queue, returning its result.
    ///
    /// Fails fast with `CancellationError` when the surrounding `Task` is
    /// already cancelled, so cancelled tool calls never occupy an I/O thread.
    static func run<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        // Boundary cancellation check: avoid even scheduling the blocking work
        // (and occupying a GCD thread) when the caller already gave up.
        try Task.checkCancellation()

        let value = try await withCheckedThrowingContinuation { continuation in
            Self.ioQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch is CancellationError {
                    continuation.resume(throwing: CancellationError())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        // A task can be cancelled while the blocking syscall is in flight. Do
        // not turn that cancellation into a successful tool result just because
        // the syscall happened to complete before the continuation resumed.
        try Task.checkCancellation()
        return value
    }
}
