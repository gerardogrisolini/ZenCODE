//
//  MCPSingleFlightTests.swift
//  ZenCODE
//

@testable import FeatureMCPBridgeKit
import Foundation
import Synchronization
import Testing

/// Deterministic coverage for `MCPSingleFlight`, the coalescing primitive behind
/// HTTP `connect()` and browser OAuth. The gate lets each test drive the shared
/// operation to a precise point instead of relying on timing.
@Suite(.timeLimit(.minutes(1)))
struct MCPSingleFlightTests {
    /// One-shot async gate: `wait()` suspends until `open()` is called.
    private final class Gate: Sendable {
        private struct State {
            var isOpen = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }
        private let state = Mutex(State())

        func wait() async {
            if state.withLock({ $0.isOpen }) { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.isOpen { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.isOpen = true
                let pending = state.waiters
                state.waiters.removeAll()
                return pending
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    private final class Counter: Sendable {
        private let storage = Mutex(0)
        var value: Int { storage.withLock { $0 } }
        func increment() { storage.withLock { $0 += 1 } }
    }

    private static func waitUntilWaiterCount(
        _ expected: Int,
        in flight: MCPSingleFlight<Int>
    ) async -> Bool {
        for _ in 0..<20_000 {
            if flight.waiterCount == expected {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @Test
    func concurrentCallersShareASingleExecution() async throws {
        let flight = MCPSingleFlight<Int>()
        let gate = Gate()
        let leaderStarted = Gate()
        let invocations = Counter()

        async let first = flight.run {
            invocations.increment()
            leaderStarted.open()
            await gate.wait()
            return 7
        }
        await leaderStarted.wait()

        async let second = flight.run {
            invocations.increment()
            return 99
        }

        #expect(await Self.waitUntilWaiterCount(2, in: flight))
        gate.open()

        let results = try await [first, second]
        #expect(results == [7, 7])
        #expect(invocations.value == 1)
    }

    @Test
    func aCancelledJoinerDoesNotBlockTheRemainingCaller() async throws {
        let flight = MCPSingleFlight<Int>()
        let gate = Gate()

        let leader = Task {
            try await flight.run {
                await gate.wait()
                return 5
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let joiner = Task {
            try await flight.run { 0 }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        joiner.cancel()

        // The cancelled joiner must return immediately, while the shared work is
        // still suspended on the gate.
        do {
            _ = try await joiner.value
            Issue.record("Expected the cancelled joiner to throw.")
        } catch is CancellationError {
            // Expected.
        }

        gate.open()
        #expect(try await leader.value == 5)
    }

    @Test
    func cancellingEveryCallerCancelsTheSharedOperation() async throws {
        let flight = MCPSingleFlight<Int>()
        let observedCancellation = Counter()

        let caller = Task {
            try await flight.run {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    observedCancellation.increment()
                    throw error
                }
                return 1
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        caller.cancel()

        do {
            _ = try await caller.value
            Issue.record("Expected the cancelled single-flight caller to throw.")
        } catch is CancellationError {
            // Expected.
        }

        // The shared operation must not outlive its last caller.
        for _ in 0..<100 where observedCancellation.value == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(observedCancellation.value == 1)
        #expect(!flight.isRunning)
    }

    @Test
    func invalidationFencesALateResult() async throws {
        let flight = MCPSingleFlight<Int>()
        let gate = Gate()
        let applied = Counter()

        let caller = Task {
            try await flight.run {
                await gate.wait()
                applied.increment()
                return 42
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // Equivalent to disconnect() while the handshake is still running.
        flight.cancel()

        do {
            _ = try await caller.value
            Issue.record("Expected the invalidated single-flight caller to throw.")
        } catch is CancellationError {
            // Expected.
        }

        // Even if the shared operation now finishes, it must not be published.
        gate.open()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!flight.isRunning)
    }

    @Test
    func aNewFlightStartsAfterInvalidation() async throws {
        let flight = MCPSingleFlight<Int>()
        flight.cancel()

        let value = try await flight.run { 11 }

        #expect(value == 11)
        #expect(!flight.isRunning)
    }

    @Test
    func failuresPropagateToEveryJoinerAndClearTheFlight() async throws {
        struct SampleError: Error, Equatable {}

        let flight = MCPSingleFlight<Int>()
        let gate = Gate()

        async let first: Int = flight.run {
            await gate.wait()
            throw SampleError()
        }
        async let second: Int = {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return try await flight.run { throw SampleError() }
        }()

        try await Task.sleep(nanoseconds: 100_000_000)
        gate.open()

        var failures = 0
        do { _ = try await first } catch is SampleError { failures += 1 }
        do { _ = try await second } catch is SampleError { failures += 1 }

        #expect(failures == 2)
        #expect(!flight.isRunning)
    }
}
