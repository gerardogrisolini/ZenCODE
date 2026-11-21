//
//  PersistenceExecutorIsolationTests.swift
//  ZenCODECoreTests (memory engine)
//
//  A persistence waiting for the graph's `flock` must not park a worker of
//  Swift's cooperative pool. The lock is advisory and may be held by another
//  ZenCODE process for the whole duration of a long transaction; a waiter that
//  blocks a cooperative thread for that time starves every unrelated task once
//  enough waiters pile up. The waiters here contend with a holder that owns a
//  separate open file description of the lock file: `flock` excludes it
//  exactly as it would exclude another process.
//
//  The test never races a timer against scheduling latency. The holder keeps
//  the lock until the test itself asks for the release, after both probes
//  have run; a safety deadline far beyond the slowest passing timeline only
//  guarantees that a defective implementation ends the test instead of hanging
//  it. The decisive criterion is therefore whether the lock was still held
//  when each probe ran, which does not depend on how loaded the machine is.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite(.serialized)
struct PersistenceExecutorIsolationTests {
    /// Upper bound for an unrelated task to start and finish, and for a sleep
    /// to overshoot, while the lock is held. Only a sanity check on latency:
    /// the decisive criterion is that the lock is still held when a probe
    /// runs, so this is generous against scheduling noise under a loaded
    /// parallel run.
    static let probeBudget: Duration = .seconds(5)
    /// Pause that gives every waiter time to reach its blocking `flock` before
    /// the second probe.
    static let settle: Duration = .milliseconds(500)
    /// The slowest timeline that still passes: first probe, settle sleep and
    /// second probe, each taking the full budget it is allowed.
    static let slowestPassingTimeline: Duration = probeBudget * 3 + settle
    /// Safety net for the holder: it drops the lock on its own once this has
    /// elapsed, even if the test never asked for the release. It must exceed
    /// `slowestPassingTimeline`, so a passing run always releases the lock
    /// itself, after its probes. With the defective implementation the probes
    /// cannot start before this deadline, find the lock released, and fail.
    static let releaseDeadline: Duration = slowestPassingTimeline + .seconds(5)

    /// The release of the foreign lock: decided by the test, bounded by a
    /// deadline, observable by the probes. It is used from the holder's own
    /// thread, so it never depends on the cooperative pool.
    private final class LockRelease: Sendable {
        private let requested = DispatchSemaphore(value: 0)
        private let released = Atomic<Bool>(false)

        /// Lets the holder drop the lock. Signalling more than once, or after
        /// the deadline has passed, is harmless, so every exit path of the
        /// test can call it.
        func request() { requested.signal() }

        /// Blocks the calling thread until `request()` or `deadline`, then
        /// records that the lock is being released. Call it right before the
        /// unlock: any commit that follows the unlock sees the flag set.
        func waitAndMarkReleased(deadline: Duration) {
            let (seconds, attoseconds) = deadline.components
            let interval = Double(seconds) + Double(attoseconds) / 1e18
            _ = requested.wait(timeout: .now() + interval)
            released.store(true, ordering: .releasing)
        }

        var isReleased: Bool { released.load(ordering: .acquiring) }
    }

    @Test func lockWaitersLeaveTheCooperativePoolFree() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("memory-persistence-executor-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("memory.graph.json")

        // The holder: its own open file description of `<graph>.lock`.
        let holder = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(holder >= 0)
        guard flock(holder, LOCK_EX) == 0 else {
            _ = close(holder)
            Issue.record("could not take the graph lock")
            return
        }
        // Released from a dedicated thread, so this test never deadlocks,
        // whatever the implementation. Not from a global dispatch queue: once
        // every cooperative worker is parked in `flock`, Darwin can withhold a
        // thread from the constrained global queues as well, and a release
        // scheduled there never ran. The thread owns the descriptor from here
        // on and is the only place that closes it.
        let release = LockRelease()
        let deadline = Self.releaseDeadline
        let releaser = Thread {
            release.waitAndMarkReleased(deadline: deadline)
            _ = flock(holder, LOCK_UN)
            _ = close(holder)
        }
        releaser.start()
        // Whatever way the test is left from here on, `#require`, `return` or
        // a thrown error, the holder is told to let go, so the thread always
        // ends and the descriptor is always closed.
        defer { release.request() }

        // More waiters than the cooperative pool has workers. Each one is a
        // distinct persistence with its own lock descriptor, so all of them
        // wait on the holder at once instead of queueing behind one actor.
        let count = max(8, 2 * ProcessInfo.processInfo.activeProcessorCount)
        let operations = (0..<count).map { index in
            Task {
                let persistence = JSONMemoryPersistence(url: file)
                return try await persistence.transaction { graph in
                    graph.addMemory(EngineMemoryEntry(
                        id: "waiter-\(index)",
                        category: .fact,
                        content: "lock waiter \(index)"
                    ))
                }.didChange
            }
        }

        // An unrelated task must start and finish while the waiters are
        // blocked: right away, and again once they have all had time to
        // reach `flock`. The lock is still held in both cases, because only
        // this test releases it, after the second probe.
        let firstProbe = await Self.probe(release)
        #expect(
            !firstProbe.lockReleased,
            "the first probe ran only after the lock was released: \(count) persistences waiting for it kept the cooperative pool busy"
        )
        #expect(
            firstProbe.latency < Self.probeBudget,
            "probe took \(firstProbe.latency) while \(count) persistences waited for the lock"
        )

        let settleStart = ContinuousClock.now
        try await Task.sleep(for: Self.settle)
        let settled = ContinuousClock.now - settleStart
        #expect(
            settled < Self.settle + Self.probeBudget,
            "a \(Self.settle) sleep took \(settled) while the persistences waited for the lock"
        )
        let secondProbe = await Self.probe(release)
        #expect(
            !secondProbe.lockReleased,
            "the second probe ran only after the lock was released: \(count) persistences waiting for it kept the cooperative pool busy"
        )
        #expect(
            secondProbe.latency < Self.probeBudget,
            "probe took \(secondProbe.latency) while \(count) persistences waited for the lock"
        )
        // Nothing could commit while the holder kept the lock.
        #expect(!fileManager.fileExists(atPath: file.path) || release.isReleased)

        // Now the test lets the holder go.
        release.request()

        // Once released, every waiter commits its own entry.
        var changed = 0
        for operation in operations where try await operation.value {
            changed += 1
        }
        #expect(changed == count)
        let persisted = try await JSONMemoryPersistence(url: file).load()
        #expect(Set(persisted.memories.keys) == Set((0..<count).map { "waiter-\($0)" }))
    }

    /// Runs an unrelated unstructured task and reports how long it took from
    /// creation to completion, and whether the lock had already been released
    /// when its body ran.
    private static func probe(_ release: LockRelease) async -> (latency: Duration, lockReleased: Bool) {
        let created = ContinuousClock.now
        let ran = await Task { (ContinuousClock.now, release.isReleased) }.value
        return (ran.0 - created, ran.1)
    }
}
