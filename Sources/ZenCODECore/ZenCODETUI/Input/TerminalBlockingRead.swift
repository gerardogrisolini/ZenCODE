//
//  TerminalBlockingRead.swift
//  ZenCODE
//

import Dispatch
import Foundation
import Synchronization

/// Cooperative cancellation flag observed by a blocking terminal read.
///
/// The blocking side of a terminal read runs outside the Swift concurrency
/// cooperative pool, where `Task.isCancelled` is always `false`. A token is
/// therefore handed to the blocking body so it can poll for cancellation at its
/// own read timeout granularity and unwind instead of blocking forever.
public final class TerminalBlockingReadToken: Sendable {
    private struct State {
        var isCancelled = false
        var isResolved = false
    }

    private let state = Mutex(State())

    public init() {}

    public func cancel() {
        state.withLock { $0.isCancelled = true }
    }

    public func isCancelled() -> Bool {
        state.withLock { $0.isCancelled }
    }

    /// `true` once a blocking body has committed an outcome through
    /// ``resolve(_:)``. Exposed for tests that pin the linearization point.
    var isResolved: Bool {
        state.withLock { $0.isResolved }
    }

    /// Atomically decides what a finished blocking body may publish.
    ///
    /// Reading `isCancelled()` and publishing the result as two separate steps
    /// leaves a window in which a cancellation lands between them: the read is
    /// then reported as cancelled by the token, yet still delivers the key it
    /// happened to have in hand. Taking the decision under the very lock that
    /// ``cancel()`` uses collapses that window into a single linearization
    /// point, so either the cancellation precedes the outcome (nothing is
    /// published) or it follows a committed result. A key produced during
    /// teardown can no longer slip out.
    func resolve<Value: Sendable>(_ value: Value?) -> Value? {
        state.withLock { state in
            state.isResolved = true
            return state.isCancelled ? nil : value
        }
    }
}

/// Bridges a blocking terminal read into Swift concurrency without occupying an
/// actor or a cooperative worker thread.
///
/// Two properties matter for the TUI runtime:
///
/// * **No cooperative thread is blocked.** POSIX terminal reads block the
///   calling thread. Running them on the cooperative pool (directly, or through
///   `Task.detached`, which also uses that pool) starves rendering, the status
///   bar, and every background refresh task. The blocking body therefore runs on
///   a dedicated dispatch queue.
/// * **Cancellation resumes exactly once, and only once the terminal is
///   quiescent.** Cancellation *signals* the token; it never completes the
///   `await` on its own. The continuation is resumed by the blocking body's own
///   completion, so when the caller's `await` returns, the worker has already
///   left `body`: it restored raw mode, released the TTY, and can no longer
///   consume a byte. Resuming on cancellation instead would let the caller
///   restore termios and start a second reader while the first is still inside
///   `poll`/`read`. The two would fight over the same descriptor, the old worker
///   would steal a keystroke meant for the new prompt, and its `defer`red
///   `restoreRawMode()` would clobber the new reader's terminal state. The
///   body's late result is still discarded on cancellation, so a key pressed
///   during teardown never takes effect.
enum TerminalBlockingRead {
    /// Dedicated queue for blocking terminal reads. Kept separate from
    /// `DispatchQueue.global()` so a long-lived interactive read cannot occupy a
    /// shared global worker that other subsystems rely on.
    private static let queue = DispatchQueue(
        label: "zencode.terminal.blocking-read",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Resume-once owner for a checked continuation.
    private final class ResumeOnceBox<Value: Sendable>: Sendable {
        private let state: Mutex<CheckedContinuation<Value?, Never>?>

        init(_ continuation: CheckedContinuation<Value?, Never>) {
            state = Mutex(continuation)
        }

        /// Resumes the awaiting task if it has not been resumed yet.
        /// Returns whether this call performed the resume.
        @discardableResult
        func finish(_ value: Value?) -> Bool {
            let continuation = state.withLock { stored -> CheckedContinuation<Value?, Never>? in
                let continuation = stored
                stored = nil
                return continuation
            }
            guard let continuation else {
                return false
            }
            continuation.resume(returning: value)
            return true
        }
    }

    /// Runs `body` off the cooperative executor and returns its result.
    ///
    /// `body` receives a cancellation token it **must** poll while blocking, and
    /// must return promptly once the token is set, releasing raw mode and the
    /// TTY on its way out. On cancellation the awaiting task resumes with `nil`
    /// only after `body` has returned, so the terminal is provably free.
    static func run<Value: Sendable>(
        _ body: @escaping @Sendable (TerminalBlockingReadToken) -> Value?
    ) async -> Value? {
        let token = TerminalBlockingReadToken()
        return await run(token: token, body)
    }

    /// Variant that accepts an externally owned token, so a caller can cancel
    /// the blocking body from another code path (for example a panel loop that
    /// is being stopped) in addition to task cancellation.
    static func run<Value: Sendable>(
        token: TerminalBlockingReadToken,
        _ body: @escaping @Sendable (TerminalBlockingReadToken) -> Value?
    ) async -> Value? {
        // Only a task that was already cancelled may bypass the body: it was
        // stopped before it ever reached the bridge, so nothing was acquired
        // and the quiescence guarantee is vacuous. An externally cancelled
        // token must *not* short-circuit: the body still has to run so it can
        // observe the cancellation, unwind on its own, and resume the
        // continuation through its own completion — otherwise the caller's
        // `await` would return before the body released the terminal.
        if Task.isCancelled {
            token.cancel()
            return nil
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                let resumeBox = ResumeOnceBox(continuation)
                queue.async {
                    // A cancellation raised between the guard above and this
                    // dispatch is not lost: `body` polls the token and returns
                    // at once, which resumes the awaiting task below.
                    let value = body(token)
                    // Reaching here means the blocking body has unwound: raw
                    // mode is restored and no read is in flight. Resuming only
                    // now is what makes an awaited cancellation a quiescence
                    // guarantee rather than a mere notification.
                    //
                    // A result produced after cancellation is discarded: the
                    // caller has already stopped caring (panel teardown, a
                    // cancelled turn), and delivering it would surface a
                    // keystroke that must no longer take effect. The discard
                    // decision is taken inside the token so a cancellation
                    // racing this line cannot land between "is it cancelled?"
                    // and "publish".
                    resumeBox.finish(token.resolve(value))
                }
            }
        } onCancel: {
            // Signal only. Completing the continuation here would hand the
            // terminal back to the caller while this read still owns it.
            token.cancel()
        }
    }
}
