//
//  DS4NativeEngineTests.swift
//  ZenCODE
//
//  C-free parts of `DS4NativeEngine`: the per-engine session pool (LRU,
//  pinning, settings reapplied after eviction) with fake handles, and the
//  dedicated FIFO engine thread.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Fake session handles: records creations, configurations and frees.
private final class FakeSessions {
    var nextHandle = 0
    var created: [String] = []
    var configured: [(String, DS4SessionSettings)] = []
    var freed: [String] = []
    var failConfigure = false

    func acquire(_ sessionID: String, in pool: inout DS4SessionPool<Int>) throws -> (handle: Int, created: Bool) {
        try pool.acquire(
            sessionID,
            create: {
                nextHandle += 1
                created.append(sessionID)
                return nextHandle
            },
            configure: { _, settings in
                if failConfigure {
                    throw DS4EngineError.unsupported("power not supported")
                }
                configured.append((sessionID, settings))
            },
            free: { id, _ in freed.append(id) }
        )
    }
}

@Suite
struct DS4NativeEngineSessionPoolTests {
    @Test
    func fullPoolEvictsTheLeastRecentlyUsedSession() throws {
        var pool = DS4SessionPool<Int>(capacity: 2)
        let sessions = FakeSessions()
        _ = try sessions.acquire("a", in: &pool)
        _ = try sessions.acquire("b", in: &pool)
        _ = pool.existingHandle(for: "a")

        _ = try sessions.acquire("c", in: &pool)

        #expect(sessions.freed == ["b"])
        #expect(pool.sessionIDsByRecency == ["a", "c"])
        #expect(pool.count == 2)
    }

    @Test
    func pinnedSessionIsSkippedByLRU() throws {
        var pool = DS4SessionPool<Int>(capacity: 2)
        let sessions = FakeSessions()
        _ = try sessions.acquire("a", in: &pool)
        pool.pin("a")
        _ = try sessions.acquire("b", in: &pool)

        _ = try sessions.acquire("c", in: &pool)

        #expect(sessions.freed == ["b"])
        #expect(pool.pinnedSessionID == "a")
        #expect(pool.contains("a"))
    }

    @Test
    func settingsSurviveEvictionAndAreReappliedOnRecreation() throws {
        var pool = DS4SessionPool<Int>(capacity: 1)
        let sessions = FakeSessions()
        pool.updateSettings(for: "a") { $0.powerPercent = 50 }
        _ = try sessions.acquire("a", in: &pool)
        pool.updateSettings(for: "a") { $0.steeringFFNScale = -2 }
        _ = try sessions.acquire("b", in: &pool)

        _ = try sessions.acquire("a", in: &pool)

        #expect(sessions.created == ["a", "b", "a"])
        #expect(sessions.freed == ["a", "b"])
        #expect(sessions.configured.map(\.0) == ["a", "a"])
        #expect(sessions.configured.first?.1 == DS4SessionSettings(powerPercent: 50, steeringFFNScale: nil))
        #expect(sessions.configured.last?.1 == DS4SessionSettings(powerPercent: 50, steeringFFNScale: -2))
    }
}

@Suite
struct DS4NativeEngineThreadTests {
    private final class Log: Sendable {
        let entries = Mutex<[(Int, ObjectIdentifier, String?)]>([])
    }

    @Test
    func jobsRunInOrderOnOneDedicatedThread() async {
        // Linux rejects thread names longer than 15 bytes (pthread_setname_np),
        // so the test name stays within that limit on every platform.
        let thread = DS4EngineThread(name: "ds4-thread-test")
        let log = Log()
        let done = MockDS4Gate()

        for index in 0..<50 {
            thread.submit {
                log.entries.withLock { $0.append((index, ObjectIdentifier(Thread.current), Thread.current.name)) }
                if index == 49 {
                    done.open()
                }
            }
        }
        try? await done.wait()
        thread.stop()

        let entries = log.entries.withLock { $0 }
        #expect(entries.map(\.0) == Array(0..<50))
        #expect(Set(entries.map(\.1)).count == 1)
        #expect(entries.allSatisfy { $0.2 == "ds4-thread-test" })
    }

    @Test
    func stopRunsQueuedJobsThenRejectsNewOnes() async {
        let thread = DS4EngineThread(name: "ds4-stop-test")
        let ran = Mutex<[Int]>([])
        let release = DispatchSemaphore(value: 0)

        thread.submit { release.wait() }
        thread.submit { ran.withLock { $0.append(1) } }
        thread.stop()
        let accepted = thread.submit { ran.withLock { $0.append(2) } }
        release.signal()
        await ds4Eventually { thread.hasFinished }

        #expect(!accepted)
        #expect(ran.withLock { $0 } == [1])
    }
}
