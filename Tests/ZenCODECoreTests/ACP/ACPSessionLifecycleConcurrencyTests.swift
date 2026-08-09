//
//  ACPSessionLifecycleConcurrencyTests.swift
//  ZenCODE
//
//  Deterministic coverage for the ACP/AgentCore lifecycle fences: backend
//  single-flight, atomic per-session prompt reservation, and the rule that a
//  closed or shut-down session is never resurrected by late work.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing

/// One-shot async gate: `wait()` suspends until `open()` is called. Lets each
/// test pin a backend at an exact point instead of relying on sleeps.
final class ACPLifecycleGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
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

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            let pending = state.waiters
            state.waiters.removeAll()
            return pending
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

final class ACPLifecycleCounter: Sendable {
    private let storage = Mutex(0)
    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}

@Suite(.timeLimit(.minutes(1)))
struct ACPSessionLifecycleConcurrencyTests {
    private static func makeConfiguration(
        sessionID: String
    ) -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        )
    }

    private static func makeBridge(
        backend: GatedRuntimeBackend
    ) throws -> ZenCODEACPBridge {
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableModels: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            runMode: .acp,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        return ZenCODEACPBridge(
            configuration: configuration,
            // These tests assert bridge and runner state, not transport bytes.
            // Avoid interleaving JSON on the process-wide stdout across cases.
            writer: ACPWriter(sink: { _ in }),
            backendFactory: { _, _ in backend }
        )
    }

    // MARK: - Backend single-flight

    @Test
    func concurrentPromptsCreateExactlyOneBackend() async throws {
        // Each AgentCoreBackend calls the factory once when it first resolves a
        // runtime backend, so the factory count is exactly the number of
        // AgentCoreBackend instances the runner put to work.
        let creations = ACPLifecycleCounter()
        let release = ACPLifecycleGate()
        let backend = GatedRuntimeBackend(finishGate: release)
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in
                creations.increment()
                return backend
            }
        )
        let configuration = Self.makeConfiguration(
            sessionID: "session-\(UUID().uuidString)"
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 6 {
                group.addTask {
                    _ = try? await runner.sendPrompt(
                        configuration: configuration,
                        prompt: "hello",
                        attachments: [],
                        onEvent: { _ in }
                    )
                }
            }
            release.open()
            await group.waitForAll()
        }

        #expect(creations.value == 1)
        #expect(await backend.promptCount() == 6)
    }

    @Test
    func concurrentPreloadAndPromptShareOneBackend() async throws {
        let creations = ACPLifecycleCounter()
        let release = ACPLifecycleGate()
        let backend = GatedRuntimeBackend(finishGate: release)
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in
                creations.increment()
                return backend
            }
        )
        let configuration = Self.makeConfiguration(
            sessionID: "session-\(UUID().uuidString)"
        )

        async let created: Void = try runner.createSession(configuration: configuration)
        async let preloaded = runner.preloadModel(
            configuration: configuration,
            onEvent: { _ in }
        )
        async let prompted = runner.sendPrompt(
            configuration: configuration,
            prompt: "hello",
            attachments: [],
            onEvent: { _ in }
        )
        release.open()
        _ = try await created
        _ = try await preloaded
        _ = try await prompted

        #expect(creations.value == 1)
    }

    @Test
    func backendIsRebuiltAfterShutdown() async throws {
        let creations = ACPLifecycleCounter()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in
                creations.increment()
                return GatedRuntimeBackend()
            }
        )
        let configuration = Self.makeConfiguration(
            sessionID: "session-\(UUID().uuidString)"
        )

        _ = try await runner.preloadModel(configuration: configuration, onEvent: { _ in })
        await runner.shutdown()
        _ = try await runner.preloadModel(configuration: configuration, onEvent: { _ in })

        #expect(creations.value == 2)
    }

    // MARK: - Late session recovery after close / rebuild

    @Test
    func closedSessionIsNotRestoredByLatePromptFinalization() async throws {
        let promptStarted = ACPLifecycleGate()
        let promptMayFinish = ACPLifecycleGate()
        let backend = GatedRuntimeBackend(
            startGate: promptStarted,
            finishGate: promptMayFinish,
            // Return no snapshot so finalizeTurn takes the "recorded snapshot"
            // path that would otherwise recreate the backend session.
            providesSnapshots: false
        )
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = Self.makeConfiguration(sessionID: sessionID)

        try await runner.createSession(configuration: configuration)
        let promptTask = Task {
            try await runner.sendPrompt(
                configuration: configuration,
                prompt: "hello",
                attachments: [],
                onEvent: { _ in }
            )
        }

        await promptStarted.wait()
        await runner.closeSession(id: sessionID)
        promptMayFinish.open()
        _ = try? await promptTask.value

        // The turn finished after the close: neither the snapshot cache nor the
        // backend session may be repopulated for the dead session.
        #expect(await runner.snapshotSession(id: sessionID) == nil)
        #expect(
            await backend.createdSessionIDs().filter { $0 == sessionID }.count == 1
        )
    }

    @Test
    func rebuiltSessionIsNotRestoredByLatePromptFinalization() async throws {
        let promptStarted = ACPLifecycleGate()
        let promptMayFinish = ACPLifecycleGate()
        let backend = GatedRuntimeBackend(
            startGate: promptStarted,
            finishGate: promptMayFinish,
            providesSnapshots: false
        )
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = Self.makeConfiguration(sessionID: sessionID)

        try await runner.createSession(configuration: configuration)
        let promptTask = Task {
            try await runner.sendPrompt(
                configuration: configuration,
                prompt: "hello",
                attachments: [],
                onEvent: { _ in }
            )
        }

        await promptStarted.wait()
        await runner.rebuildSession(id: sessionID)
        promptMayFinish.open()
        _ = try? await promptTask.value

        #expect(await runner.snapshotSession(id: sessionID) == nil)
    }

    @Test
    func liveSessionStillCachesItsTurnSnapshot() async throws {
        // Negative control: without an intervening close, the same fenced path
        // must still cache the turn snapshot as before.
        let backend = GatedRuntimeBackend(providesSnapshots: false)
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = Self.makeConfiguration(sessionID: sessionID)

        try await runner.createSession(configuration: configuration)
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "hello",
            attachments: [],
            onEvent: { _ in }
        )

        let snapshot = try #require(await runner.snapshotSession(id: sessionID))
        #expect(snapshot.history.contains { $0.role == .user && $0.content == "hello" })
    }

    // MARK: - ACP prompt reservation

    @Test
    func concurrentACPPromptsReserveTheSessionExactlyOnce() async throws {
        let promptStarted = ACPLifecycleGate()
        let promptMayFinish = ACPLifecycleGate()
        let backend = GatedRuntimeBackend(
            startGate: promptStarted,
            finishGate: promptMayFinish
        )
        let bridge = try Self.makeBridge(backend: backend)
        let sessionID = "acp-session-1"
        await bridge.installTestSession(
            Self.makeConfiguration(sessionID: sessionID)
        )

        let first = Task {
            try await bridge.prompt(id: nil, params: [
                "sessionId": sessionID,
                "prompt": "first"
            ])
        }

        // Pin the first prompt inside the backend before dispatching the
        // second one: it now holds the reservation and stays suspended on
        // `promptMayFinish`. Dispatching both tasks and opening the gate right
        // away would be a race, because `Task` does not start its body
        // synchronously. On a slow runner the first prompt could complete and
        // release the reservation before the second one even began, which is
        // correct sequential behaviour but proves nothing about concurrent
        // reservation.
        await promptStarted.wait()

        let second = Task {
            try await bridge.prompt(id: nil, params: [
                "sessionId": sessionID,
                "prompt": "second"
            ])
        }

        var rejections = 0
        do {
            try await second.value
        } catch let error as ACPError {
            #expect(error.message.contains("already running"))
            rejections += 1
        } catch {
            Issue.record("Unexpected prompt error: \(error)")
        }

        promptMayFinish.open()
        do {
            try await first.value
        } catch {
            Issue.record("Unexpected prompt error: \(error)")
        }

        #expect(rejections == 1)
        #expect(await backend.promptCount() == 1)
        #expect(await bridge.testActivePromptID(sessionID: sessionID) == nil)
    }

    @Test
    func promptReservationIsReleasedAfterCompletion() async throws {
        let backend = GatedRuntimeBackend()
        let bridge = try Self.makeBridge(backend: backend)
        let sessionID = "acp-session-2"
        await bridge.installTestSession(
            Self.makeConfiguration(sessionID: sessionID)
        )

        try await bridge.prompt(id: nil, params: [
            "sessionId": sessionID,
            "prompt": "first"
        ])
        #expect(await bridge.testActivePromptID(sessionID: sessionID) == nil)

        // A second, sequential prompt must be accepted again.
        try await bridge.prompt(id: nil, params: [
            "sessionId": sessionID,
            "prompt": "second"
        ])
        #expect(await backend.promptCount() == 2)
        #expect(await bridge.testActivePromptID(sessionID: sessionID) == nil)
    }

    @Test
    func cancelClearsReservationAndLatePromptDoesNotReviveIt() async throws {
        let promptStarted = ACPLifecycleGate()
        let promptMayFinish = ACPLifecycleGate()
        let backend = GatedRuntimeBackend(
            startGate: promptStarted,
            finishGate: promptMayFinish
        )
        let bridge = try Self.makeBridge(backend: backend)
        let sessionID = "acp-session-3"
        await bridge.installTestSession(
            Self.makeConfiguration(sessionID: sessionID)
        )

        let promptTask = Task {
            try await bridge.prompt(id: nil, params: [
                "sessionId": sessionID,
                "prompt": "long running"
            ])
        }
        await promptStarted.wait()
        try await bridge.cancel(id: nil, params: ["sessionId": sessionID])
        #expect(await bridge.testActivePromptID(sessionID: sessionID) == nil)

        promptMayFinish.open()
        _ = try? await promptTask.value
        #expect(await bridge.testActivePromptID(sessionID: sessionID) == nil)

        // The session is still usable after a cancel.
        try await bridge.prompt(id: nil, params: [
            "sessionId": sessionID,
            "prompt": "after cancel"
        ])
    }

    @Test
    func closedACPSessionIsNotRecreatedByLatePromptCompletion() async throws {
        let promptStarted = ACPLifecycleGate()
        let promptMayFinish = ACPLifecycleGate()
        let backend = GatedRuntimeBackend(
            startGate: promptStarted,
            finishGate: promptMayFinish
        )
        let bridge = try Self.makeBridge(backend: backend)
        let sessionID = "acp-session-4"
        await bridge.installTestSession(
            Self.makeConfiguration(sessionID: sessionID)
        )

        let promptTask = Task {
            try await bridge.prompt(id: nil, params: [
                "sessionId": sessionID,
                "prompt": "long running"
            ])
        }
        await promptStarted.wait()
        try await bridge.close(id: nil, params: ["sessionId": sessionID])
        promptMayFinish.open()
        _ = try? await promptTask.value

        #expect(await bridge.sessionConfigurationsForTesting().isEmpty)
        #expect(await bridge.testHasSession(sessionID: sessionID) == false)
    }

    @Test
    func shutdownIsIdempotentAndFencesLatePromptCompletion() async throws {
        let promptStarted = ACPLifecycleGate()
        let promptMayFinish = ACPLifecycleGate()
        let backend = GatedRuntimeBackend(
            startGate: promptStarted,
            finishGate: promptMayFinish
        )
        let bridge = try Self.makeBridge(backend: backend)
        let sessionID = "acp-session-5"
        await bridge.installTestSession(
            Self.makeConfiguration(sessionID: sessionID)
        )

        let promptTask = Task {
            try await bridge.prompt(id: nil, params: [
                "sessionId": sessionID,
                "prompt": "long running"
            ])
        }
        await promptStarted.wait()
        await bridge.shutdown()
        // A second shutdown must be a no-op, not a second teardown.
        await bridge.shutdown()
        promptMayFinish.open()
        _ = try? await promptTask.value

        #expect(await bridge.sessionConfigurationsForTesting().isEmpty)
        #expect(await bridge.isShutDown)
    }

    @Test
    func promptIsRejectedForUnknownSessionWithoutMutatingState() async throws {
        let bridge = try Self.makeBridge(backend: GatedRuntimeBackend())

        await #expect(throws: ACPError.self) {
            try await bridge.prompt(id: nil, params: [
                "sessionId": "missing-session",
                "prompt": "hello"
            ])
        }
        #expect(await bridge.sessionConfigurationsForTesting().isEmpty)
    }
}

// MARK: - Gated backend

/// Runtime backend whose `sendPrompt` can be pinned open by gates so lifecycle
/// races (close / cancel / shutdown during generation) are deterministic.
private actor GatedRuntimeBackend: AgentRuntimeBackend {
    private let startGate: ACPLifecycleGate?
    private let finishGate: ACPLifecycleGate?
    private let providesSnapshots: Bool
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var createdIDs: [String] = []
    private var prompts = 0

    init(
        startGate: ACPLifecycleGate? = nil,
        finishGate: ACPLifecycleGate? = nil,
        providesSnapshots: Bool = true
    ) {
        self.startGate = startGate
        self.finishGate = finishGate
        self.providesSnapshots = providesSnapshots
    }

    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        createdIDs.append(id)
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id,
            workingDirectoryPath: cwd,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard sessions[id] == nil else {
            return
        }
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {
        sessions.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts += 1
        startGate?.open()
        await finishGate?.wait()
        try Task.checkCancellation()
        return DirectAgentResponse(
            text: "",
            stopReason: "end_turn",
            modelID: "test-model"
        )
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        guard providesSnapshots else {
            return nil
        }
        return sessions[id]
    }

    func createdSessionIDs() -> [String] {
        createdIDs
    }

    func promptCount() -> Int {
        prompts
    }
}

extension ZenCODEACPBridge {
    func testActivePromptID(sessionID: String) -> UUID? {
        sessions[sessionID]?.activePromptID
    }

    func testHasSession(sessionID: String) -> Bool {
        sessions[sessionID] != nil
    }
}
