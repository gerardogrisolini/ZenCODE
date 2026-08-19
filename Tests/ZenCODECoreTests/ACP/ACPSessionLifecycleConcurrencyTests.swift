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

final class ACPMultiSessionBackendFactory: Sendable {
    struct PromptObservation: Sendable, Equatable {
        let sessionID: String
        let modelID: String?
        let workingDirectoryPath: String
        let systemPrompt: String?
        let allowedToolNames: Set<String>?
        let history: [AgentRuntimeMessage]
        let prompt: String
        let output: String
    }

    private struct State {
        var configurations: [(modelID: String?, workingDirectoryPath: String)] = []
        var observations: [PromptObservation] = []
    }

    private let state = Mutex(State())

    fileprivate func makeBackend(configuration: AgentRuntimeConfiguration) -> ACPMultiSessionRuntimeBackend {
        state.withLock {
            $0.configurations.append((configuration.modelID, configuration.workingDirectory.path))
        }
        return ACPMultiSessionRuntimeBackend(
            modelID: configuration.modelID,
            workingDirectoryPath: configuration.workingDirectory.path,
            record: { [weak self] observation in
                self?.state.withLock { $0.observations.append(observation) }
            }
        )
    }

    var observations: [PromptObservation] {
        state.withLock { $0.observations }
    }

    var configurations: [(modelID: String?, workingDirectoryPath: String)] {
        state.withLock { $0.configurations }
    }
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
        backend: GatedRuntimeBackend,
        writer: ACPWriter = ACPWriter(sink: { _ in })
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
            // The default avoids interleaving JSON on process-wide stdout;
            // ordering tests inject an observable writer.
            writer: writer,
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

    @Test
    func interleavedACPSessionsKeepConfigurationHistorySnapshotsAndOutputAcrossBackendReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-multisession-\(UUID().uuidString)", isDirectory: true)
        let cwdA = root.appendingPathComponent("workspace-a", isDirectory: true)
        let cwdB = root.appendingPathComponent("workspace-b", isDirectory: true)
        let factory = ACPMultiSessionBackendFactory()
        let wire = Mutex<[JSONValue]>([])
        let writer = ACPWriter(sink: { data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                wire.withLock { $0.append(value) }
            }
        })
        let configuration = try AgentConfiguration(
            hostedModelID: "model-a",
            availableModels: [
                AgentSettingsModelManifest(id: "model-a", kind: .remoteAPI, modelID: "local/model-a"),
                AgentSettingsModelManifest(id: "model-b", kind: .remoteAPI, modelID: "local/model-b"),
            ],
            runMode: .acp,
            workingDirectory: root
        )
        let bridge = ZenCODEACPBridge(
            configuration: configuration,
            writer: writer,
            backendFactory: { runtimeConfiguration, _ in
                factory.makeBackend(configuration: runtimeConfiguration)
            }
        )
        let sessionA = AgentCoreSessionConfiguration(
            sessionID: "session-a",
            modelID: "model-a",
            workingDirectory: cwdA,
            systemPrompt: "system-a",
            cacheKey: "cache-a",
            history: [AgentRuntimeMessage(role: .user, content: "seed-a")],
            allowedToolNames: ["tool-a"]
        )
        let sessionB = AgentCoreSessionConfiguration(
            sessionID: "session-b",
            modelID: "model-b",
            workingDirectory: cwdB,
            systemPrompt: "system-b",
            cacheKey: "cache-b",
            history: [AgentRuntimeMessage(role: .user, content: "seed-b")],
            allowedToolNames: ["tool-b"]
        )
        await bridge.installTestSession(sessionA)
        await bridge.installTestSession(sessionB)

        // Two concurrently alive tasks model independent ACP clients. Explicit
        // gates interleave them as A -> B -> A without timing sleeps.
        let bMayPrompt = ACPLifecycleGate()
        let aMayPromptAgain = ACPLifecycleGate()
        async let clientA: Void = {
            try await bridge.prompt(id: .number(1), params: [
                "sessionId": sessionA.sessionID,
                "prompt": "a-one",
            ])
            bMayPrompt.open()
            await aMayPromptAgain.wait()
            try await bridge.prompt(id: .number(3), params: [
                "sessionId": sessionA.sessionID,
                "prompt": "a-two",
            ])
        }()
        async let clientB: Void = {
            await bMayPrompt.wait()
            try await bridge.prompt(id: .number(2), params: [
                "sessionId": sessionB.sessionID,
                "prompt": "b-one",
            ])
            aMayPromptAgain.open()
        }()
        _ = try await (clientA, clientB)

        let observations = factory.observations
        #expect(observations.map(\.sessionID) == ["session-a", "session-b", "session-a"])
        #expect(observations.map(\.modelID) == ["model-a", "model-b", "model-a"])
        #expect(observations.map(\.workingDirectoryPath) == [cwdA.path, cwdB.path, cwdA.path])
        #expect(observations[0].systemPrompt == "system-a")
        #expect(observations[1].systemPrompt == "system-b")
        #expect(observations[2].allowedToolNames == ["tool-a"])
        #expect(observations[2].history.map(\.content) == ["seed-a", "a-one", observations[0].output])
        #expect(!observations[2].history.contains { $0.content.contains("b-one") })

        let snapshotA = try #require(await bridge.sessionRunner.snapshotSession(id: sessionA.sessionID))
        let snapshotB = try #require(await bridge.sessionRunner.snapshotSession(id: sessionB.sessionID))
        #expect(snapshotA.workingDirectoryPath == cwdA.path)
        #expect(snapshotB.workingDirectoryPath == cwdB.path)
        #expect(snapshotA.history.map(\.content) == ["seed-a", "a-one", observations[0].output, "a-two", observations[2].output])
        #expect(snapshotB.history.map(\.content) == ["seed-b", "b-one", observations[1].output])
        #expect(!snapshotA.history.contains { $0.content.contains("b-one") })
        #expect(!snapshotB.history.contains { $0.content.contains("a-one") })

        let results = wire.withLock { values in
            values.compactMap { value -> (Int, String)? in
                guard let object = value.objectValue,
                      let id = object["id"]?.numberValue.map(Int.init),
                      let result = object["result"]?.objectValue,
                      let stopReason = result["stopReason"]?.stringValue else { return nil }
                return (id, stopReason)
            }
        }
        #expect(results.map(\.0) == [1, 2, 3])
        #expect(results.allSatisfy { $0.1 == "end_turn" })
        let outputUpdates = wire.withLock { values in
            values.compactMap { value -> (String, String)? in
                guard let object = value.objectValue,
                      object["method"] == .string("session/update"),
                      let params = object["params"]?.objectValue,
                      let sessionID = params["sessionId"]?.stringValue,
                      let update = params["update"]?.objectValue,
                      update["sessionUpdate"] == .string("agent_message_chunk"),
                      let text = update["content"]?.objectValue?["text"]?.stringValue,
                      text.hasPrefix("output[") else { return nil }
                return (sessionID, text)
            }
        }
        #expect(outputUpdates.map(\.0) == ["session-a", "session-b", "session-a"])
        #expect(outputUpdates.map(\.1) == observations.map(\.output))
        #expect(factory.configurations.map(\.modelID) == ["model-a", "model-b", "model-a"])
        #expect(await bridge.sessionRunner.taskOrchestrator.registeredSessionIDs() == ["session-a", "session-b"])
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
    func promptReservationRemainsHeldUntilFinalResultIsSent() async throws {
        let resultWriteStarted = ACPLifecycleGate()
        let resultWriteMayFinish = DispatchSemaphore(value: 0)
        let writer = ACPWriter(sink: { data in
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  value.objectValue?["id"] == .number(99) else {
                return
            }
            resultWriteStarted.open()
            resultWriteMayFinish.wait()
        })
        let backend = GatedRuntimeBackend()
        let bridge = try Self.makeBridge(backend: backend, writer: writer)
        let sessionID = "acp-result-order"
        await bridge.installTestSession(Self.makeConfiguration(sessionID: sessionID))

        let first = Task {
            try await bridge.prompt(id: .number(99), params: [
                "sessionId": sessionID,
                "prompt": "first",
            ])
        }
        await resultWriteStarted.wait()

        await #expect(throws: ACPError.self) {
            try await bridge.prompt(id: nil, params: [
                "sessionId": sessionID,
                "prompt": "must not overlap result delivery",
            ])
        }

        resultWriteMayFinish.signal()
        try await first.value
        #expect(await bridge.testActivePromptID(sessionID: sessionID) == nil)
    }

    @Test
    func closingSessionEvictsItsPermissionDecisions() async throws {
        let writerReference = Mutex<ACPWriter?>(nil)
        let writer = ACPWriter(sink: { data in
            guard let request = try? JSONDecoder().decode(JSONValue.self, from: data),
                  request.objectValue?["method"] == .string("session/request_permission"),
                  let id = request.objectValue?["id"],
                  let writer = writerReference.withLock({ $0 }) else {
                return
            }
            Task(name: "ACP.closePermissionFixture") {
                await writer.handleResponse(.object([
                    "id": id,
                    "result": .object(["optionId": .string("allow_always")]),
                ]))
            }
        })
        writerReference.withLock { $0 = writer }
        let bridge = try Self.makeBridge(
            backend: GatedRuntimeBackend(),
            writer: writer
        )
        let sessionID = "acp-permission-eviction"
        await bridge.installTestSession(Self.makeConfiguration(sessionID: sessionID))
        #expect(await bridge.permissionBroker.authorize(AgentToolAuthorizationRequest(
            sessionID: sessionID,
            toolCallID: "push",
            toolName: "git.push",
            title: "Push",
            kind: "destructive",
            command: "git push origin main",
            workingDirectory: "/tmp"
        )))
        #expect(
            await bridge.permissionBroker.cachedDecisionCount(sessionID: sessionID) == 1
        )

        try await bridge.close(id: nil, params: ["sessionId": sessionID])

        #expect(
            await bridge.permissionBroker.cachedDecisionCount(sessionID: sessionID) == 0
        )
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
        // Cancellation-aware: a real runtime unwinds a cancelled turn, and
        // `session/close` now waits for that unwind before answering, so the
        // double must not park forever on a gate the test has not opened.
        try await finishGate?.waitCancelling()
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

private actor ACPMultiSessionRuntimeBackend: AgentRuntimeBackend {
    private let modelID: String?
    private let workingDirectoryPath: String
    private let record: @Sendable (ACPMultiSessionBackendFactory.PromptObservation) -> Void
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]

    init(
        modelID: String?,
        workingDirectoryPath: String,
        record: @escaping @Sendable (ACPMultiSessionBackendFactory.PromptObservation) -> Void
    ) {
        self.modelID = modelID
        self.workingDirectoryPath = workingDirectoryPath
        self.record = record
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
        guard sessions[id] == nil else { return }
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
        id: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard let snapshot = sessions[id] else { return }
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id,
            workingDirectoryPath: snapshot.workingDirectoryPath,
            systemPrompt: systemPrompt,
            cacheKey: snapshot.cacheKey,
            history: snapshot.history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func closeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {
        sessions.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        modelID ?? "default"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        guard let snapshot = sessions[sessionID] else {
            throw ACPError.invalidParams("Backend replacement lost session \(sessionID)")
        }
        let output = "output[\(sessionID)|\(modelID ?? "default")|\(URL(fileURLWithPath: workingDirectoryPath).lastPathComponent)|\(prompt)]"
        record(ACPMultiSessionBackendFactory.PromptObservation(
            sessionID: sessionID,
            modelID: modelID,
            workingDirectoryPath: workingDirectoryPath,
            systemPrompt: snapshot.systemPrompt,
            allowedToolNames: snapshot.allowedToolNames,
            history: snapshot.history,
            prompt: prompt,
            output: output
        ))
        var history = snapshot.history
        history.append(AgentRuntimeMessage(role: .user, content: prompt))
        history.append(AgentRuntimeMessage(role: .assistant, content: output))
        sessions[sessionID] = AgentRuntimeSessionSnapshot(
            sessionID: sessionID,
            workingDirectoryPath: snapshot.workingDirectoryPath,
            systemPrompt: snapshot.systemPrompt,
            cacheKey: snapshot.cacheKey,
            history: history,
            allowedToolNames: snapshot.allowedToolNames,
            thinkingSelection: snapshot.thinkingSelection,
            preserveThinking: snapshot.preserveThinking
        )
        await onEvent(.content(output))
        return DirectAgentResponse(text: output, stopReason: "end_turn", modelID: modelID ?? "default")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
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
