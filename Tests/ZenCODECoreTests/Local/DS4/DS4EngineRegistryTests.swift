//
//  DS4EngineRegistryTests.swift
//  ZenCODE
//
//  Registry semantics on `MockDS4Engine` (no C): one engine per process,
//  coalesced opens, identity switch after the turn in progress, FIFO
//  generation lease, instance-lock errors, shutdown; plus the mock contract
//  the DS4 backend tests rely on (common-prefix cache, LRU eviction,
//  caller stop, cancellation). Every test uses its own registry instance.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

private final class OrderRecorder: Sendable {
    private let state = Mutex<(order: [Int], active: Int, maxActive: Int)>(([], 0, 0))

    func enter(_ value: Int) {
        state.withLock { state in
            state.order.append(value)
            state.active += 1
            state.maxActive = max(state.maxActive, state.active)
        }
    }

    func leave() {
        state.withLock { $0.active -= 1 }
    }

    var order: [Int] {
        state.withLock { $0.order }
    }

    var maxActive: Int {
        state.withLock { $0.maxActive }
    }
}

private let noProgress: @Sendable (String, Int, Int) -> Void = { _, _, _ in }
private let greedy = DS4SamplingParameters(temperature: 0)

private func turn(_ engine: any DS4Engine, sessionID: String, prompt: String) async throws -> DS4GenerateResult {
    _ = try await engine.sync(
        sessionID: sessionID,
        transcript: [.begin, .message(role: "user", content: prompt), .assistantPrefix(mode: DS4EngineABI.ThinkMode.none)],
        onProgress: noProgress
    )
    return try await engine.generate(
        sessionID: sessionID,
        maxTokens: 256,
        thinkMode: DS4EngineABI.ThinkMode.none,
        sampling: greedy
    ) { _ in [] }
}

@Suite
struct DS4EngineRegistryTests {
    // MARK: Single engine

    @Test
    func sameIdentityReusesOneEngine() async throws {
        let factory = MockDS4EngineFactory()
        let registry = DS4EngineRegistry(factory: factory.factory)
        let configuration = DS4EngineConfiguration.mock()

        let first = try await registry.engine(for: configuration)
        let second = try await registry.engine(for: configuration)

        #expect(first === second)
        #expect(factory.openCount == 1)
        #expect(await registry.currentIdentity == configuration.identity)
    }

    @Test
    func concurrentOpensOfOneIdentityAreCoalesced() async throws {
        let factory = MockDS4EngineFactory(openDelay: .milliseconds(50))
        let registry = DS4EngineRegistry(factory: factory.factory)
        let configuration = DS4EngineConfiguration.mock()

        let identifiers = try await withThrowingTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<6 {
                group.addTask { ObjectIdentifier(try await registry.engine(for: configuration)) }
            }
            var identifiers: Set<ObjectIdentifier> = []
            for try await identifier in group {
                identifiers.insert(identifier)
            }
            return identifiers
        }

        #expect(identifiers.count == 1)
        #expect(factory.openCount == 1)
    }

    @Test
    func openStatusIsForwardedToTheCaller() async throws {
        let factory = MockDS4EngineFactory()
        let registry = DS4EngineRegistry(factory: factory.factory)
        let messages = Mutex<[String]>([])

        _ = try await registry.engine(for: .mock(model: "/m/a.gguf")) { message in
            messages.withLock { $0.append(message) }
        }

        #expect(messages.withLock { $0 } == ["opened /m/a.gguf"])
    }

    // MARK: Identity switch

    @Test
    func identityChangeClosesPreviousEngineAfterTheTurnInProgress() async throws {
        let gate = MockDS4Gate()
        let factory = MockDS4EngineFactory { MockDS4Engine(configuration: $0, generationGate: gate) }
        let registry = DS4EngineRegistry(factory: factory.factory)
        let configurationA = DS4EngineConfiguration.mock(model: "/m/a.gguf")
        let configurationB = DS4EngineConfiguration.mock(model: "/m/b.gguf")

        let lease = Task {
            try await registry.withGenerationLease(configuration: configurationA, sessionID: "s1") { engine in
                try await turn(engine, sessionID: "s1", prompt: "hello")
            }
        }
        await ds4Eventually { factory.engines.count == 1 }
        let engineA = try #require(factory.engines.first)
        try await engineA.generationStarted.wait()

        let switchTask = Task { try await registry.engine(for: configurationB) }
        await ds4Eventually { await registry.queuedLeaseCount == 1 }
        #expect(!engineA.isClosed)
        #expect(factory.openCount == 1)
        #expect(await registry.currentIdentity == configurationA.identity)

        gate.open()
        let result = try await lease.value
        let engineB = try await switchTask.value

        #expect(result.outcome == .stop)
        #expect(result.text == "mock reply")
        #expect(engineA.isClosed)
        #expect(engineB !== engineA)
        #expect(factory.openCount == 2)
        #expect(await registry.currentIdentity == configurationB.identity)
        let callsA = engineA.calls
        let generateIndex = try #require(callsA.firstIndex(of: .generate(sessionID: "s1")))
        let closeIndex = try #require(callsA.firstIndex(of: .close))
        #expect(generateIndex < closeIndex)
    }

    @Test
    func leaseOnANewIdentitySwitchesEngines() async throws {
        let factory = MockDS4EngineFactory()
        let registry = DS4EngineRegistry(factory: factory.factory)

        let first = try await registry.withGenerationLease(configuration: .mock(model: "/m/a.gguf"), sessionID: "s") { $0 }
        let second = try await registry.withGenerationLease(configuration: .mock(model: "/m/b.gguf"), sessionID: "s") { $0 }

        #expect(first !== second)
        #expect(factory.engines.map(\.isClosed) == [true, false])
    }

    // MARK: Generation lease

    @Test
    func generationLeasesRunOneAtATimeInArrivalOrder() async throws {
        let factory = MockDS4EngineFactory()
        let registry = DS4EngineRegistry(factory: factory.factory)
        let configuration = DS4EngineConfiguration.mock()
        let gate = MockDS4Gate()
        let recorder = OrderRecorder()

        let first = Task {
            try await registry.withGenerationLease(configuration: configuration, sessionID: "s0") { _ in
                recorder.enter(0)
                defer { recorder.leave() }
                try await gate.wait()
            }
        }
        await ds4Eventually { recorder.order == [0] }

        var waiting: [Task<Void, any Error>] = []
        for index in 1...4 {
            waiting.append(Task {
                try await registry.withGenerationLease(configuration: configuration, sessionID: "s\(index)") { _ in
                    recorder.enter(index)
                    defer { recorder.leave() }
                    try await Task.sleep(for: .milliseconds(5))
                }
            })
            await ds4Eventually { await registry.queuedLeaseCount == index }
        }
        #expect(await registry.activeLeaseSessionID == "s0")

        gate.open()
        try await first.value
        for task in waiting {
            try await task.value
        }

        #expect(recorder.order == [0, 1, 2, 3, 4])
        #expect(recorder.maxActive == 1)
        #expect(factory.openCount == 1)
        #expect(await registry.isGenerationLockHeld == false)
        #expect(await registry.activeLeaseSessionID == nil)
    }

    @Test
    func cancelledLeaseWaiterThrowsAndDoesNotBlockTheQueue() async throws {
        let registry = DS4EngineRegistry(factory: MockDS4EngineFactory().factory)
        let configuration = DS4EngineConfiguration.mock()
        let gate = MockDS4Gate()
        let recorder = OrderRecorder()

        let holder = Task {
            try await registry.withGenerationLease(configuration: configuration, sessionID: "holder") { _ in
                recorder.enter(0)
                try await gate.wait()
            }
        }
        await ds4Eventually { recorder.order == [0] }

        let cancelled = Task {
            try await registry.withGenerationLease(configuration: configuration, sessionID: "cancelled") { _ in
                recorder.enter(1)
            }
        }
        await ds4Eventually { await registry.queuedLeaseCount == 1 }
        let next = Task {
            try await registry.withGenerationLease(configuration: configuration, sessionID: "next") { _ in
                recorder.enter(2)
            }
        }
        await ds4Eventually { await registry.queuedLeaseCount == 2 }

        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await registry.queuedLeaseCount == 1)

        gate.open()
        try await holder.value
        try await next.value
        #expect(recorder.order == [0, 2])
    }

    @Test
    func failingLeaseBodyReleasesTheLock() async throws {
        let registry = DS4EngineRegistry(factory: MockDS4EngineFactory().factory)
        let configuration = DS4EngineConfiguration.mock()

        await #expect(throws: DS4EngineError.sessionFailed("boom")) {
            try await registry.withGenerationLease(configuration: configuration, sessionID: "s") { _ in
                throw DS4EngineError.sessionFailed("boom")
            }
        }
        let value = try await registry.withGenerationLease(configuration: configuration, sessionID: "s") { _ in 42 }

        #expect(value == 42)
        #expect(await registry.isGenerationLockHeld == false)
    }

    // MARK: Errors

    @Test
    func instanceLockErrorIsPropagatedAndNotCached() async throws {
        let factory = MockDS4EngineFactory()
        let registry = DS4EngineRegistry(factory: factory.factory)
        let configuration = DS4EngineConfiguration.mock()
        let libraryMessage = "another ds4 process is already running (pid 4242)"
        factory.failNextOpen(with: .instanceLocked(libraryMessage))

        let error = await #expect(throws: DS4EngineError.self) {
            _ = try await registry.engine(for: configuration)
        }
        #expect(error == .instanceLocked(libraryMessage))
        let description = error?.localizedDescription ?? ""
        #expect(description.contains(libraryMessage))
        #expect(description.contains("another DS4 process is using this model"))
        #expect(await registry.currentIdentity == nil)
        #expect(await registry.isGenerationLockHeld == false)

        let engine = try await registry.engine(for: configuration)
        #expect(factory.openCount == 2)
        #expect(engine === factory.engines.first)
    }

    @Test
    func coalescedWaitersShareTheOpenFailure() async throws {
        let factory = MockDS4EngineFactory(openDelay: .milliseconds(40))
        let registry = DS4EngineRegistry(factory: factory.factory)
        factory.failNextOpen(with: .openFailed("ds4_engine_open failed: bad tensor"))

        let results = await withTaskGroup(of: DS4EngineError?.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    do {
                        _ = try await registry.engine(for: .mock())
                        return nil
                    } catch {
                        return error as? DS4EngineError
                    }
                }
            }
            var results: [DS4EngineError?] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        #expect(results.allSatisfy { $0 == .openFailed("ds4_engine_open failed: bad tensor") })
        #expect(factory.openCount == 1)
    }

    // MARK: Sessions and shutdown

    @Test
    func releaseSessionForwardsToTheOpenEngine() async throws {
        let factory = MockDS4EngineFactory()
        let registry = DS4EngineRegistry(factory: factory.factory)
        let engine = try await registry.engine(for: .mock())
        _ = try await turn(engine, sessionID: "s1", prompt: "hi")

        await registry.releaseSession("s1")

        let mock = try #require(factory.engines.first)
        #expect(mock.calls.contains(.releaseSession("s1")))
        #expect(mock.liveSessionIDs.isEmpty)
        #expect(await engine.stats(sessionID: "s1") == .empty)
    }

    @Test
    func shutdownClosesTheEngineAndTheRegistryStaysUsable() async throws {
        let factory = MockDS4EngineFactory()
        let registry = DS4EngineRegistry(factory: factory.factory)
        let configuration = DS4EngineConfiguration.mock()
        let engine = try await registry.engine(for: configuration)
        _ = try await turn(engine, sessionID: "s1", prompt: "hi")

        await registry.shutdown()

        let mock = try #require(factory.engines.first)
        #expect(mock.isClosed)
        #expect(mock.liveSessionIDs.isEmpty)
        #expect(await registry.currentIdentity == nil)
        await #expect(throws: DS4EngineError.engineClosed) {
            _ = try await engine.tokenCount(of: [.begin])
        }

        let reopened = try await registry.engine(for: configuration)
        #expect(reopened !== engine)
        #expect(factory.openCount == 2)
    }

    @Test
    func shutdownDuringOpenDiscardsTheNewEngine() async throws {
        let factory = MockDS4EngineFactory(openDelay: .milliseconds(80))
        let registry = DS4EngineRegistry(factory: factory.factory)

        let opening = Task { try await registry.engine(for: .mock()) }
        await ds4Eventually { factory.openCount == 1 }
        await registry.shutdown()

        await #expect(throws: DS4EngineError.engineClosed) { _ = try await opening.value }
        #expect(factory.engines.first?.isClosed == true)
        #expect(await registry.currentIdentity == nil)
    }

    // MARK: closeIfIdle

    @Test
    func closeIfIdleWithoutAnEngineReturnsFalse() async {
        let factory = MockDS4EngineFactory()
        let registry = DS4EngineRegistry(factory: factory.factory)

        #expect(await registry.closeIfIdle() == false)
        #expect(factory.openCount == 0)
        #expect(await registry.isGenerationLockHeld == false)
    }

    @Test
    func closeIfIdleClosesAnEngineWithoutSessionsAndTheNextRequestReopensIt() async throws {
        let factory = MockDS4EngineFactory()
        let registry = DS4EngineRegistry(factory: factory.factory)
        let configuration = DS4EngineConfiguration.mock()
        let engine = try await registry.engine(for: configuration)

        #expect(await registry.closeIfIdle())

        let mock = try #require(factory.engines.first)
        #expect(mock.isClosed)
        #expect(await registry.currentIdentity == nil)
        #expect(await registry.isGenerationLockHeld == false)
        await #expect(throws: DS4EngineError.engineClosed) {
            _ = try await engine.tokenCount(of: [.begin])
        }

        let reopened = try await registry.engine(for: configuration)
        #expect(reopened !== engine)
        #expect(factory.openCount == 2)
        #expect(await registry.currentIdentity == configuration.identity)
    }

    @Test
    func closeIfIdleKeepsAnEngineWithALiveSessionUntilItIsReleased() async throws {
        let factory = MockDS4EngineFactory()
        let registry = DS4EngineRegistry(factory: factory.factory)
        let configuration = DS4EngineConfiguration.mock()
        let engine = try await registry.engine(for: configuration)
        _ = try await turn(engine, sessionID: "s1", prompt: "hi")
        let mock = try #require(factory.engines.first)

        #expect(await registry.closeIfIdle() == false)
        #expect(!mock.isClosed)
        #expect(await registry.currentIdentity == configuration.identity)
        #expect(factory.openCount == 1)

        await registry.releaseSession("s1")
        #expect(await registry.closeIfIdle())
        #expect(mock.isClosed)
        #expect(mock.liveSessionIDs.isEmpty)
    }

    @Test
    func closeIfIdleNeverWaitsForAnActiveLease() async throws {
        let factory = MockDS4EngineFactory()
        let registry = DS4EngineRegistry(factory: factory.factory)
        let configuration = DS4EngineConfiguration.mock()
        let gate = MockDS4Gate()
        let holder = Task {
            try await registry.withGenerationLease(configuration: configuration, sessionID: "holder") { _ in
                try await gate.wait()
            }
        }
        await ds4Eventually { await registry.activeLeaseSessionID == "holder" }
        let mock = try #require(factory.engines.first)

        #expect(await registry.closeIfIdle() == false)
        #expect(!mock.isClosed)
        #expect(await registry.currentIdentity == configuration.identity)

        gate.open()
        try await holder.value
        #expect(await registry.closeIfIdle())
        #expect(mock.isClosed)
    }

    @Test
    func closeIfIdleIsFalseWhileALeaseIsQueued() async throws {
        let factory = MockDS4EngineFactory()
        let registry = DS4EngineRegistry(factory: factory.factory)
        let configuration = DS4EngineConfiguration.mock()
        let gate = MockDS4Gate()
        let holder = Task {
            try await registry.withGenerationLease(configuration: configuration, sessionID: "holder") { _ in
                try await gate.wait()
            }
        }
        await ds4Eventually { await registry.activeLeaseSessionID == "holder" }
        let queued = Task {
            try await registry.withGenerationLease(configuration: configuration, sessionID: "queued") { _ in }
        }
        await ds4Eventually { await registry.queuedLeaseCount == 1 }
        let mock = try #require(factory.engines.first)

        #expect(await registry.closeIfIdle() == false)
        #expect(!mock.isClosed)

        gate.open()
        try await holder.value
        try await queued.value
        #expect(factory.openCount == 1)
        #expect(await registry.closeIfIdle())
        #expect(mock.isClosed)
    }

    @Test
    func closeIfIdleDuringAnOpenReturnsFalseAndTheOpenCompletes() async throws {
        let factory = MockDS4EngineFactory(openDelay: .milliseconds(80))
        let registry = DS4EngineRegistry(factory: factory.factory)
        let configuration = DS4EngineConfiguration.mock()
        let opening = Task { try await registry.engine(for: configuration) }
        await ds4Eventually { factory.openCount == 1 }

        #expect(await registry.closeIfIdle() == false)
        let engine = try await opening.value
        #expect(engine === factory.engines.first)
        #expect(await registry.currentIdentity == configuration.identity)
        #expect(factory.engines.first?.isClosed == false)
    }

    // MARK: Configuration

    @Test
    func identityCoversLibraryAndEffectiveOptions() {
        let base = DS4EngineConfiguration.mock(model: "/m/a.gguf", contextSize: 8192, sessionCapacity: 3)

        #expect(base.effectiveOptions.map(\.keyValue) == [
            "model_path=/m/a.gguf", "context_size=8192", "session_count=3"
        ])
        #expect(base.identity != DS4EngineConfiguration.mock(model: "/m/b.gguf", contextSize: 8192, sessionCapacity: 3).identity)
        #expect(base.identity != DS4EngineConfiguration.mock(model: "/m/a.gguf", contextSize: 4096, sessionCapacity: 3).identity)
        #expect(base.identity != DS4EngineConfiguration.mock(
            model: "/m/a.gguf", contextSize: 8192, sessionCapacity: 3,
            extraOptions: [DS4EngineOption(key: "backend", value: "cpu")]
        ).identity)
        #expect(base.identity == DS4EngineConfiguration.mock(model: "/m/a.gguf", contextSize: 8192, sessionCapacity: 3).identity)
        #expect(base.identity.hasPrefix("library=/tmp/zencode-ds4-tests/"))
    }

    @Test
    func explicitPlacementOptionsAreNotDuplicatedAndCapacityIsClamped() {
        let configuration = DS4EngineConfiguration.mock(
            contextSize: 8192,
            sessionCapacity: 42,
            extraOptions: [DS4EngineOption(key: "context_size", value: "16384")]
        )

        #expect(configuration.sessionCapacity == 8)
        #expect(configuration.effectiveOptions.filter { $0.key == "context_size" }.map(\.value) == ["16384"])
        #expect(configuration.effectiveOptions.last?.keyValue == "session_count=8")
        #expect(DS4EngineConfiguration.mock(sessionCapacity: 0).sessionCapacity == 1)
    }

    // MARK: Mock contract

    @Test
    func mockSyncReusesTheCommonPrefixAndEvictsLeastRecentlyUsedSessions() async throws {
        let engine = MockDS4Engine(configuration: .mock(sessionCapacity: 2))
        let firstTurn: [DS4TranscriptOperation] = [.begin, .message(role: "user", content: "hello there")]
        let secondTurn = firstTurn + [.message(role: "assistant", content: "hi"), .message(role: "user", content: "more")]

        let initial = try await engine.sync(sessionID: "a", transcript: firstTurn, onProgress: noProgress)
        let followUp = try await engine.sync(sessionID: "a", transcript: secondTurn, onProgress: noProgress)
        _ = try await engine.sync(sessionID: "b", transcript: firstTurn, onProgress: noProgress)
        _ = try await engine.sync(sessionID: "c", transcript: firstTurn, onProgress: noProgress)
        let rebuilt = try await engine.sync(sessionID: "a", transcript: secondTurn, onProgress: noProgress)

        #expect(initial == DS4SyncResult(tokenCount: MockDS4Engine.tokenCount(of: firstTurn), cached: 0, suffix: MockDS4Engine.tokenCount(of: firstTurn)))
        #expect(followUp.cached == MockDS4Engine.tokenCount(of: firstTurn))
        #expect(followUp.tokenCount == MockDS4Engine.tokenCount(of: secondTurn))
        #expect(engine.calls.contains(.evicted("a")))
        #expect(engine.calls.contains(.evicted("b")))
        #expect(rebuilt.cached == 0)
        #expect(engine.liveSessionIDs == ["c", "a"])
    }

    @Test
    func mockGenerationHonoursCallerStopMaxTokensAndContext() async throws {
        let engine = MockDS4Engine(configuration: .mock(contextSize: 64))
        _ = try await engine.sync(sessionID: "s", transcript: [.begin], onProgress: noProgress)
        engine.enqueueGeneration(["a", "b", "STOP", "c"])
        engine.enqueueGeneration(["x", "y", "z"])

        let stopped = try await engine.generate(sessionID: "s", maxTokens: 10, thinkMode: 0, sampling: greedy) { text in
            text == "STOP" ? .stop : []
        }
        let truncated = try await engine.generate(sessionID: "s", maxTokens: 2, thinkMode: 0, sampling: greedy) { _ in [] }

        #expect(stopped.outcome == .callerStop)
        #expect(stopped.text == "abSTOP")
        #expect(truncated.outcome == .maxTokens)
        #expect(truncated.text == "xy")
        await #expect(throws: DS4EngineError.contextExhausted(used: 64, limit: 64)) {
            _ = try await engine.sync(sessionID: "s", transcript: [.renderedChat(String(repeating: "abcd", count: 64))], onProgress: noProgress)
        }
        await #expect(throws: DS4EngineError.self) {
            _ = try await engine.generate(sessionID: "never-synced", maxTokens: 1, thinkMode: 0, sampling: greedy) { _ in [] }
        }
    }

    @Test
    func mockGenerationCancellationKeepsPartialText() async throws {
        let engine = MockDS4Engine(configuration: .mock(), chunkDelay: .milliseconds(10))
        _ = try await engine.sync(sessionID: "s", transcript: [.begin], onProgress: noProgress)
        engine.enqueueGeneration(Array(repeating: "t", count: 500))
        let firstChunk = MockDS4Gate()

        let generation = Task {
            try await engine.generate(sessionID: "s", maxTokens: 1000, thinkMode: 0, sampling: greedy) { _ in
                firstChunk.open()
                return []
            }
        }
        try await firstChunk.wait()
        generation.cancel()
        let result = try await generation.value

        #expect(result.outcome == .cancelled)
        #expect(!result.text.isEmpty)
        #expect(result.text.count < 500)
    }

    @Test
    func mockCheckpointsRoundTripTrailersAndRejectForeignFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds4-registry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = MockDS4Engine(configuration: .mock())
        let transcript: [DS4TranscriptOperation] = [.begin, .message(role: "user", content: "save me")]
        _ = try await engine.sync(sessionID: "s", transcript: transcript, onProgress: noProgress)
        let checkpoint = directory.appendingPathComponent("s.kv")
        let foreign = directory.appendingPathComponent("foreign.kv")
        try Data("not a checkpoint".utf8).write(to: foreign)

        let saved = try await engine.saveCheckpoint(sessionID: "s", to: checkpoint, trailer: Data("title".utf8))
        let trailer = try await engine.loadCheckpoint(sessionID: "restored", from: checkpoint)
        let resumed = try await engine.sync(sessionID: "restored", transcript: transcript, onProgress: noProgress)

        #expect(saved == .saved)
        #expect(trailer == Data("title".utf8))
        #expect(resumed.cached == resumed.tokenCount)
        await #expect(throws: DS4EngineError.kvIncompatible("not a mock DS4 checkpoint")) {
            _ = try await engine.loadCheckpoint(sessionID: "x", from: foreign)
        }
    }
}
