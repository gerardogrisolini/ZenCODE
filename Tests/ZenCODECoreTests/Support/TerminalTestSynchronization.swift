//
//  TerminalTestSynchronization.swift
//  ZenCODE
//

import Dispatch
import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Runs synchronous pipe/PTY fixtures off Swift's cooperative pool while
/// preserving Swift Testing's task-local context. Keep query arming and byte
/// production on the same executor rather than spending the CPR budget waiting
/// to dispatch the fixture's reader after the query was already armed.
struct TerminalBlockingTestScope: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await withTaskExecutorPreference(TerminalTestExecutor.shared) {
            try await function()
        }
    }
}

private final class TerminalTestExecutor: TaskExecutor {
    static let shared = TerminalTestExecutor()
    private let queue = DispatchQueue(
        label: "zencode.tests.terminal-blocking",
        qos: .userInitiated,
        attributes: .concurrent
    )

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        queue.async { [self] in
            unownedJob.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}

/// One-shot signal used to express happens-before between a thread running
/// outside the cooperative pool and an awaiting test.
///
/// Blocking terminal reads run on a dedicated dispatch queue, so a test cannot
/// order itself against them with `await` alone. Sleeping for "long enough"
/// instead makes the ordering probabilistic: the assertion then depends on the
/// machine's load, and the interleaving the test claims to cover (cancelling a
/// read that has already started) may silently degrade into the trivial one
/// (cancelling before it starts). `TerminalTestSignal` replaces that guesswork
/// with a real edge: the blocking side calls ``signal()`` at the point of
/// interest and the test's ``wait()`` cannot resume before it.
final class TerminalTestSignal: Sendable {
    private struct State {
        var isSignalled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// `true` once ``signal()`` has been called.
    var isSignalled: Bool {
        state.withLock { $0.isSignalled }
    }

    /// Latches the signal and releases every waiter. Safe to call from a
    /// blocking body on any thread, and idempotent.
    func signal() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isSignalled = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        // Resumed outside the lock: a resumed test task may immediately call
        // back into this signal.
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Suspends until the signal is latched. Registration happens under the
    /// same lock as ``signal()``, so a signal racing the suspension cannot be
    /// missed.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isAlreadySignalled = state.withLock { state -> Bool in
                if state.isSignalled {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if isAlreadySignalled {
                continuation.resume()
            }
        }
    }
}

/// Mutable boolean shared with blocking bodies running off the cooperative
/// pool. `Mutex` is noncopyable, so it is wrapped in a class reference that
/// several tasks and threads can capture.
final class TerminalTestFlag: Sendable {
    private let state = Mutex(false)

    init(_ initialValue: Bool = false) {
        state.withLock { $0 = initialValue }
    }

    var value: Bool {
        state.withLock { $0 }
    }

    func set(_ newValue: Bool) {
        state.withLock { $0 = newValue }
    }
}

/// Waits for the real CPR callback to finish, including release of deferred keys.
/// The deadline is a test watchdog, not a change to the report's own timeout.
/// Cancellation and a missing callback fail the test rather than hanging the suite.
func terminalWaitForCursorReport(_ reports: TerminalCursorReport) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while reports.isHoldingInput, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(!reports.isHoldingInput, "Cursor report delivery did not release input")
}

/// Suspends until `condition` holds, without assuming how long that takes.
///
/// Used to order a test against state published by a thread outside the
/// cooperative pool when no signal can be injected into the production code
/// path. Unlike a fixed sleep this cannot resume early, so the interleaving
/// under test is reached rather than hoped for; a condition that never becomes
/// true is caught by the suite's time limit instead of being papered over by a
/// timeout that continues the test with a false assumption.
func terminalWaitUntil(_ condition: @Sendable () -> Bool) async {
    while !condition() {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}
