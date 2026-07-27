//
//  RemoteTransportLifetime.swift
//  ZenCODE
//
//  Internal lifetime token for the cross-platform SwiftNIO transport.
//

import Foundation
import Synchronization

/// Internal lifetime token shared by a public transport handle and the scoped
/// NIO run-task that drives its driver actor.
///
/// The public handle (`RemoteHTTPBody` / `RemoteHTTPStreamingResponse` /
/// `RemoteSSEEventStream` and their iterators, or `RemoteWebSocketConnection`)
/// retains this token. The run-task does not: it captures only the driver actor
/// and a weak reference back to this token. When the last handle copy is
/// released the token is deallocated, which closes the channel lease, cancels
/// the run-task and asks the driver to abandon any continuation-based waiter it
/// is parked on. That unblocks the run-task so the
/// `NIOAsyncChannel.executeThenClose` scope can complete and the driver can be
/// released even when the consumer dropped the stream without draining it.
///
/// A channel closure observed while a handle is still alive is deliberately
/// NOT translated into an early teardown here: the NIO inbound iterator remains
/// the sole authority for distinguishing a clean end-of-stream from a framing
/// or Content-Length truncation error. Re-introducing a `channel.closeFuture`
/// monitor would mask such errors (the earlier P1 regression).
final class RemoteTransportLifetimeToken: Sendable {
    private let lease: RemoteChannelLease
    private let state = Mutex(State.idle)

    init(lease: RemoteChannelLease) {
        self.lease = lease
    }

    /// Records the run-task and the driver-abandoning teardown. Called once,
    /// immediately after the run-task is started. Safe against the run-task
    /// finishing first or the token already being invalidated.
    func install(
        runTask: Task<Void, Never>,
        teardown: @escaping @Sendable () async -> Void
    ) {
        let installAfterFinish = state.withLock { state in
            switch state {
            case .idle:
                state = .armed(runTask: runTask, teardown: teardown)
                return false
            case .armed:
                // Defensive: installing twice is a programmer error. Ignore it
                // rather than orphaning the first run-task.
                return false
            case .finished:
                return true
            }
        }
        if installAfterFinish {
            // The run already finished or the token was invalidated before
            // install completed. Tear the supplied task down immediately so its
            // driver is not left retained.
            runTask.cancel()
            Task(name: "Remote transport late lifetime teardown") {
                await teardown()
            }
        }
    }

    /// Called by the run-task (through a weak reference) once
    /// `executeThenClose` has returned. Natural completion needs no teardown:
    /// the channel scope already closed the channel and released the driver.
    func runDidFinish() {
        state.withLock { state in
            switch state {
            case .idle, .armed:
                state = .finished
            case .finished:
                break
            }
        }
    }

    /// Closes the lease, cancels the run-task and runs the driver teardown.
    /// Idempotent; used by intermediate error/timeout/cancellation paths before
    /// a handle is returned, and again from `deinit` when the last handle is
    /// released.
    func invalidate() {
        performTeardown()
    }

    private func performTeardown() {
        let action = state.withLock { state -> TeardownAction in
            switch state {
            case .idle:
            // No run-task/teardown installed yet. Close the lease now; a later
            // install() will tear down whatever it receives.
                state = .finished
                return .closeOnly
            case .armed(let runTask, let teardown):
                state = .finished
                return .cancel(runTask: runTask, teardown: teardown)
            case .finished:
                return .none
            }
        }
        switch action {
        case .closeOnly:
            lease.close()
        case let .cancel(runTask, teardown):
            lease.close()
            // Cancelling the run-task alone does not resume the driver's
            // continuation-based waiters (they use `CheckedContinuation`), so
            // the teardown must abandon them before the task can complete.
            runTask.cancel()
            Task(name: "Remote transport lifetime teardown") {
                await teardown()
            }
        case .none:
            break
        }
    }

    deinit {
        performTeardown()
    }

    private enum State {
        case idle
        case armed(runTask: Task<Void, Never>, teardown: @Sendable () async -> Void)
        case finished
    }

    private enum TeardownAction {
        case none
        case closeOnly
        case cancel(runTask: Task<Void, Never>, teardown: @Sendable () async -> Void)
    }
}
