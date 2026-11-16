//
//  ACPSessionLifecycleConcurrencyTests+Support.swift
//  ZenCODE
//
//  Support types of the ACP lifecycle tests: the one-shot async gate, the
//  thread-safe counter, and the bridge hooks that read the live prompt and
//  session state.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

/// One-shot async gate: `wait()` suspends until `open()` is called. Lets each
/// test pin a backend at an exact point instead of relying on sleeps.
final class ACPLifecycleGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var cancellingWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    }

    private let state = Mutex(State())

    func wait() async {
        if state.withLock({ $0.isOpen }) {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.isOpen {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    var isOpen: Bool {
        state.withLock { $0.isOpen }
    }

    /// Waits like `wait()`, but abandons the wait as soon as the calling task
    /// is cancelled, throwing `CancellationError`.
    ///
    /// This mirrors a runtime backend that honours task cancellation: a turn
    /// parked in generation still unwinds promptly once `session/cancel` or
    /// `session/close` cancels it. `session/close` waits for that unwind
    /// before answering, so a double that ignores cancellation would deadlock
    /// the close against the test's own gate.
    func waitCancelling() async throws {
        if isOpen {
            return
        }
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let immediate: Result<Void, Error>? = state.withLock { state in
                    if state.isOpen {
                        return .success(())
                    }
                    guard !Task.isCancelled else {
                        return .failure(CancellationError())
                    }
                    state.cancellingWaiters[token] = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let abandoned = state.withLock { $0.cancellingWaiters.removeValue(forKey: token) }
            abandoned?.resume(throwing: CancellationError())
        }
    }

    func open() {
        let waiters = state.withLock { state -> (never: [CheckedContinuation<Void, Never>], throwing: [CheckedContinuation<Void, Error>]) in
            state.isOpen = true
            let pending = state.waiters
            state.waiters.removeAll()
            let pendingCancelling = Array(state.cancellingWaiters.values)
            state.cancellingWaiters.removeAll()
            return (pending, pendingCancelling)
        }
        for waiter in waiters.never {
            waiter.resume()
        }
        for waiter in waiters.throwing {
            waiter.resume(returning: ())
        }
    }
}

final class ACPLifecycleCounter: Sendable {
    private let storage = Mutex(0)
    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}

extension ZenCODEACPBridge {
    /// The prompt reserved on the live incarnation of `sessionID`, as the
    /// host holds it.
    func testActivePromptID(sessionID: String) async -> UUID? {
        guard let session = sessions[sessionID] else { return nil }
        return await host.liveIncarnation(in: session.slotID, epoch: session.epoch)?.activePromptID
    }

    func testHasSession(sessionID: String) -> Bool {
        sessions[sessionID] != nil
    }
}
