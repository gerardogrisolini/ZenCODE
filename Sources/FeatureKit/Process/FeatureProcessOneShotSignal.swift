//
//  FeatureProcessOneShotSignal.swift
//  ZenCODE
//

import Foundation
import Synchronization

/// Cancellation-aware, race-safe one-shot signal shared by the one-shot process
/// runner and the persistent process session.
///
/// Both lifecycles need the same primitive: a value that is published at most
/// once (a process exit code, a termination request) and an arbitrary number of
/// waiters that must resume exactly once — including when the waiting task is
/// cancelled before or after its continuation was registered.
///
/// Every `wait()` registers its own continuation, so cancelling one waiter
/// resolves only that waiter: the signal itself is never "poisoned" and later
/// waits (for example a SIGTERM grace window followed by a post-SIGKILL reap)
/// still suspend until the value is really published. All state transitions run
/// under a `Mutex`, and continuations are always resumed outside the lock.
final class FeatureProcessOneShotSignal<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var value: Value?
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        var cancelledWaiters: Set<UUID> = []
    }

    private let state = Mutex(State())

    init() {}

    /// The published value, or `nil` while the signal is unresolved.
    var value: Value? {
        state.withLock { $0.value }
    }

    var isResolved: Bool {
        state.withLock { $0.value != nil }
    }

    /// Publishes `value` and resumes every pending waiter. Idempotent: a second
    /// call is ignored and returns `false`, and each continuation is resumed
    /// exactly once.
    @discardableResult
    func resolve(_ value: Value) -> Bool {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, Never>]? in
            guard state.value == nil else {
                return nil
            }
            state.value = value
            let pending = Array(state.waiters.values)
            state.waiters.removeAll()
            state.cancelledWaiters.removeAll()
            return pending
        }
        guard let continuations else {
            return false
        }
        for continuation in continuations {
            continuation.resume()
        }
        return true
    }

    /// Suspends until the signal is resolved or the calling task is cancelled.
    func wait() async {
        if isResolved { return }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                register(continuation, id: waiterID)
            }
        } onCancel: {
            cancelWaiter(waiterID)
        }
    }

    private func register(_ continuation: CheckedContinuation<Void, Never>, id: UUID) {
        let resumeImmediately = state.withLock { state -> Bool in
            if state.value != nil {
                return true
            }
            // Cancellation can be observed before the continuation exists; the
            // recorded ticket makes the late registration resume right away
            // instead of leaking a suspended waiter.
            if state.cancelledWaiters.remove(id) != nil {
                return true
            }
            state.waiters[id] = continuation
            return false
        }
        if resumeImmediately {
            continuation.resume()
        }
    }

    /// Resolves a single cancelled waiter. Other waiters and the signal's
    /// ability to publish a later real value are untouched.
    ///
    /// A ticket is recorded **only** while the signal is still unresolved. Once a
    /// value is published, `register` already resumes every late continuation on
    /// `value != nil`, and `resolve` has purged the ticket set: inserting there
    /// would store a UUID that can never be consumed again and would grow for the
    /// whole lifetime of the signal. This is exactly the resolve/cancel race,
    /// where `resolve` removes the waiter and resumes it while the cancellation
    /// handler fires concurrently for the same, already-resumed waiter.
    private func cancelWaiter(_ id: UUID) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard let pending = state.waiters.removeValue(forKey: id) else {
                if state.value == nil {
                    state.cancelledWaiters.insert(id)
                }
                return nil
            }
            return pending
        }
        continuation?.resume()
    }
}

extension FeatureProcessOneShotSignal {
    /// Test seam: number of continuations currently suspended on this signal.
    var pendingWaiterCountForTesting: Int {
        state.withLock { $0.waiters.count }
    }

    /// Test seam: number of cancellation tickets awaiting consumption by a late
    /// `register`. Must be zero once the signal is resolved.
    var cancellationTicketCountForTesting: Int {
        state.withLock { $0.cancelledWaiters.count }
    }

    /// Test seam: deterministically reproduces the resolve/cancel interleaving by
    /// invoking the cancellation handler for a waiter identity that is no longer
    /// registered.
    func simulateCancellationForTesting(waiterID: UUID) {
        cancelWaiter(waiterID)
    }
}

/// Exit-code signal for a spawned feature process.
typealias FeatureProcessExitSignal = FeatureProcessOneShotSignal<Int32>

/// Why a supervised feature process was asked to terminate before it exited on
/// its own. Typed so a truncation is never confused with a timeout.
enum FeatureProcessTerminationReason: Sendable {
    case stdoutLineLimit
    case outputByteLimit
}

/// One-shot termination request raised by an output reader and consumed by the
/// exit supervisor.
typealias FeatureProcessTerminationSignal = FeatureProcessOneShotSignal<FeatureProcessTerminationReason>

extension FeatureProcessOneShotSignal where Value == Int32 {
    /// `true` once an exit code has been observed for the owned process.
    var hasExited: Bool {
        isResolved
    }

    var exitCode: Int32? {
        value
    }

    /// Records the observed exit code. Idempotent.
    func finish(exitCode: Int32) {
        resolve(exitCode)
    }
}
