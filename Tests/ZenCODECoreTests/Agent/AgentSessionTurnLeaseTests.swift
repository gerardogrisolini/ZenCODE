//
//  AgentSessionTurnLeaseTests.swift
//  ZenCODECoreTests
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing

@Suite
struct AgentSessionTurnLeaseTests {
    @Test
    func servesTwoAlreadyQueuedWaitersInFIFOOrder() async throws {
        let recorder = LeaseTestRecorder()
        let firstGate = LeaseTestGate()
        let secondGate = LeaseTestGate()
        let queued = LeaseTestQueueObserver()
        let observedLease = AgentSessionTurnLease { sessionID in
            queued.recordEnqueue(for: sessionID)
        }

        let first = Task {
            try await observedLease.withLease(sessionID: "shared") {
                await recorder.record("first")
                await firstGate.wait()
            }
        }
        await recorder.waitForCount(1)
        let second = Task {
            try await observedLease.withLease(sessionID: "shared") {
                await recorder.record("second")
                await secondGate.wait()
            }
        }
        await queued.waitForEnqueueCount(1, sessionID: "shared")
        let third = Task {
            try await observedLease.withLease(sessionID: "shared") {
                await recorder.record("third")
            }
        }
        await queued.waitForEnqueueCount(2, sessionID: "shared")

        await firstGate.open()
        await recorder.waitForCount(2)
        #expect(await recorder.entries() == ["first", "second"])
        await secondGate.open()
        try await first.value
        try await second.value
        try await third.value
        #expect(await recorder.entries() == ["first", "second", "third"])
    }

    @Test
    func allowsTurnsForDifferentSessionsToProceedConcurrently() async throws {
        let lease = AgentSessionTurnLease()
        let recorder = LeaseTestRecorder()
        let completionGate = LeaseTestGate()

        let first = Task {
            try await lease.withLease(sessionID: "first") {
                await recorder.record("first")
                await completionGate.wait()
            }
        }
        let second = Task {
            try await lease.withLease(sessionID: "second") {
                await recorder.record("second")
                await completionGate.wait()
            }
        }

        await recorder.waitForCount(2)
        await completionGate.open()
        try await first.value
        try await second.value
    }

    @Test
    func releasesLeaseAfterOperationError() async throws {
        let lease = AgentSessionTurnLease()
        let recorder = LeaseTestRecorder()

        do {
            try await lease.withLease(sessionID: "shared") {
                throw LeaseTestError.failed
            }
            Issue.record("Expected the lease operation to throw.")
        } catch LeaseTestError.failed {
        }

        try await lease.withLease(sessionID: "shared") {
            await recorder.record("after-error")
        }
        #expect(await recorder.entries() == ["after-error"])
    }

    @Test
    func removesCancelledWaiterAndDoesNotLeakLease() async throws {
        let queued = LeaseTestQueueObserver()
        let lease = AgentSessionTurnLease { sessionID in
            queued.recordEnqueue(for: sessionID)
        }
        let recorder = LeaseTestRecorder()
        let firstGate = LeaseTestGate()

        let first = Task {
            try await lease.withLease(sessionID: "shared") {
                await recorder.record("first")
                await firstGate.wait()
            }
        }
        await recorder.waitForCount(1)
        let cancelled = Task { () -> Bool in
            do {
                try await lease.withLease(sessionID: "shared") {
                    await recorder.record("cancelled")
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await queued.waitForEnqueueCount(1, sessionID: "shared")
        let following = Task {
            try await lease.withLease(sessionID: "shared") {
                await recorder.record("following")
            }
        }
        await queued.waitForEnqueueCount(2, sessionID: "shared")
        cancelled.cancel()
        #expect(await cancelled.value)
        await firstGate.open()
        try await first.value
        try await following.value

        #expect(await recorder.entries() == ["first", "following"])
    }
}

private enum LeaseTestError: Error {
    case failed
}

private actor LeaseTestRecorder {
    private var values: [String] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ value: String) {
        values.append(value)
        let ready = countWaiters.enumerated().filter { values.count >= $0.element.count }
        for index in ready.map(\.offset).reversed() {
            countWaiters.remove(at: index).continuation.resume()
        }
    }

    func entries() -> [String] {
        values
    }

    func waitForCount(_ count: Int) async {
        guard values.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }
}

private actor LeaseTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else {
            return
        }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// A synchronous enqueue hook records the exact instant the lease appends a
/// continuation.  This makes queue-dependent tests deterministic without
/// treating executor scheduling (`Task.yield`) as a synchronisation primitive.
private final class LeaseTestQueueObserver: Sendable {
    private struct State {
        var counts: [String: Int] = [:]
        var waiters: [(sessionID: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    func recordEnqueue(for sessionID: String) {
        let ready: [CheckedContinuation<Void, Never>] = state.withLock { state in
            state.counts[sessionID, default: 0] += 1
            let count = state.counts[sessionID, default: 0]
            let ready = state.waiters.enumerated().filter {
                $0.element.sessionID == sessionID && count >= $0.element.count
            }
            for index in ready.map(\.offset).reversed() {
                state.waiters.remove(at: index)
            }
            return ready.map(\.element.continuation)
        }
        ready.forEach { $0.resume() }
    }

    func waitForEnqueueCount(_ count: Int, sessionID: String) async {
        guard !state.withLock({ $0.counts[sessionID, default: 0] >= count }) else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state -> Bool in
                guard state.counts[sessionID, default: 0] < count else { return true }
                state.waiters.append((sessionID, count, continuation))
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }
}
