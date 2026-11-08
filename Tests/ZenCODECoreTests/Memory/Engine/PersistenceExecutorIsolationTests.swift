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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite(.serialized)
struct PersistenceExecutorIsolationTests {
    /// How long the foreign holder keeps the graph lock.
    static let lockHold: TimeInterval = 3
    /// Upper bound for an unrelated task to start and finish while the lock is
    /// held. Generous against scheduling noise, well below `lockHold`.
    static let probeBudget: Duration = .seconds(1)
    /// Pause that gives every waiter time to reach its blocking `flock` before
    /// the second probe.
    static let settle: Duration = .milliseconds(500)

    /// Set by the holder when it releases the lock. The release runs on its
    /// own thread, so it never depends on the cooperative pool.
    private final class ReleaseFlag: Sendable {
        private let released = Atomic<Bool>(false)

        func set() { released.store(true, ordering: .releasing) }
        var isSet: Bool { released.load(ordering: .acquiring) }
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
        // scheduled there never ran.
        let release = ReleaseFlag()
        let releaser = Thread {
            Thread.sleep(forTimeInterval: Self.lockHold)
            release.set()
            _ = flock(holder, LOCK_UN)
            _ = close(holder)
        }
        releaser.start()

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

        // An unrelated task must start and finish promptly while the waiters
        // are blocked: right away, and again once they have all had time to
        // reach `flock`.
        let firstProbe = await Self.probe(release)
        #expect(
            firstProbe.latency < Self.probeBudget,
            "probe took \(firstProbe.latency) while \(count) persistences waited for the lock"
        )
        #expect(!firstProbe.lockReleased, "the probe ran only after the lock was released")

        let settleStart = ContinuousClock.now
        try await Task.sleep(for: Self.settle)
        let settled = ContinuousClock.now - settleStart
        #expect(
            settled < Self.settle + Self.probeBudget,
            "a \(Self.settle) sleep took \(settled) while the persistences waited for the lock"
        )
        let secondProbe = await Self.probe(release)
        #expect(
            secondProbe.latency < Self.probeBudget,
            "probe took \(secondProbe.latency) while \(count) persistences waited for the lock"
        )
        #expect(!secondProbe.lockReleased, "the probe ran only after the lock was released")
        // Nothing could commit while the holder kept the lock.
        #expect(!fileManager.fileExists(atPath: file.path) || release.isSet)

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
    private static func probe(_ release: ReleaseFlag) async -> (latency: Duration, lockReleased: Bool) {
        let created = ContinuousClock.now
        let ran = await Task { (ContinuousClock.now, release.isSet) }.value
        return (ran.0 - created, ran.1)
    }
}
