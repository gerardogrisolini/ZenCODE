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

@Suite(.serialized)
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

    // MARK: Sessions and shutdown

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

    // MARK: closeIfIdle

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

}
