//
//  ACPShutdownFenceTests.swift
//  ZenCODE
//
//  Coverage for the ACP shutdown fence: lifecycle requests (`session/new`,
//  `session/load`, `session/resume`, `model/preload`, `session/cancel`,
//  `session/close`) must not create sessions or backends, and must not answer
//  on the transport, once `shutdown()` has latched.
//
//  All tests drive the real production handlers on a real `ZenCODEACPBridge`.
//  Nothing here mutates, copies or restores source files; the in-flight
//  suspension is produced by a gated backend double, which is the same seam the
//  existing lifecycle tests already use.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

/// One-shot gate that also reports when production code reached it, so a test
/// can pin a handler at an exact suspension point instead of sleeping.
private final class ShutdownFenceGate: Sendable {
    private struct State {
        var isOpen = false
        var reachedCount = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var reachedCount: Int {
        state.withLock { $0.reachedCount }
    }

    /// Called from the gated backend: records arrival, then blocks until `open()`.
    func arriveAndWait() async {
        let reachedWaiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.reachedCount += 1
            let pending = state.reachedWaiters
            state.reachedWaiters.removeAll()
            return pending
        }
        for waiter in reachedWaiters {
            waiter.resume()
        }

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

    /// Suspends until production code entered the gate at least once.
    func waitUntilReached() async {
        if state.withLock({ $0.reachedCount > 0 }) {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.reachedCount > 0 {
                    return true
                }
                state.reachedWaiters.append(continuation)
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

@Suite(.timeLimit(.minutes(1)))
struct ACPShutdownFenceTests {
    private static func makeBridge(
        gate: ShutdownFenceGate? = nil,
        createdBackends: ACPLifecycleCounter? = nil
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
            writer: ACPWriter(),
            backendFactory: { _, _ in
                createdBackends?.increment()
                return ShutdownFenceBackend(preloadGate: gate)
            },
            xcodeIsRunning: { false }
        )
    }

    /// Params with an explicit empty allowlist and no MCP servers, so the
    /// handler performs no external discovery and stays deterministic.
    private static func sessionParams(sessionID: String? = nil) -> [String: Any] {
        var params: [String: Any] = [
            "cwd": FileManager.default.temporaryDirectory.path,
            "allowedTools": [String]()
        ]
        if let sessionID {
            params["sessionId"] = sessionID
        }
        return params
    }

    // MARK: - In-flight fence (real suspension inside a lifecycle handler)

    @Test
    func preloadSuspendedInBackendDoesNotAnswerAfterShutdown() async throws {
        // `model/preload` is the lifecycle handler whose runner call reaches the
        // injected backend, so it can be pinned at a real suspension point.
        // While it is parked inside the backend, `shutdown()` latches; the
        // handler must then abort at its post-await re-check.
        let gate = ShutdownFenceGate()
        let createdBackends = ACPLifecycleCounter()
        let bridge = try Self.makeBridge(gate: gate, createdBackends: createdBackends)

        let preloadTask = Task {
            try await bridge.preloadModel(id: .number(1), params: [:])
        }
        await gate.waitUntilReached()

        await bridge.shutdown()
        gate.open()

        await #expect(throws: (any Error).self) {
            try await preloadTask.value
        }
        #expect(gate.reachedCount == 1)
    }

    @Test
    func lifecycleOperationClaimedBeforeSuspensionIsInvalidatedByShutdown() async throws {
        // This is the exact contract every fenced handler relies on: it claims a
        // token before its first `await`, and re-checks the token after each
        // suspension that precedes a mutation or a runner call. A `shutdown()`
        // landing in between must invalidate the claim.
        let bridge = try Self.makeBridge()

        let token = try await bridge.registerLifecycleOperation()
        #expect(await bridge.isLifecycleOperationLive(token))

        await bridge.shutdown()

        #expect(await bridge.isLifecycleOperationLive(token) == false)
        await #expect(throws: (any Error).self) {
            try await bridge.ensureLifecycleOperationLive(token)
        }
        // And no new operation may be claimed at all.
        await #expect(throws: (any Error).self) {
            _ = try await bridge.registerLifecycleOperation()
        }
    }

    @Test
    func lifecycleOperationStaysLiveWithoutShutdown() async throws {
        // Negative control: the fence must not invalidate healthy operations,
        // otherwise the assertions above would pass for the wrong reason.
        let bridge = try Self.makeBridge()

        let first = try await bridge.registerLifecycleOperation()
        let second = try await bridge.registerLifecycleOperation()
        #expect(await bridge.isLifecycleOperationLive(first))
        #expect(await bridge.isLifecycleOperationLive(second))

        // Finishing one operation must not fence the other.
        await bridge.finishLifecycleOperation(first)
        #expect(await bridge.isLifecycleOperationLive(first) == false)
        #expect(await bridge.isLifecycleOperationLive(second))
    }

    // MARK: - session/new

    @Test
    func newSessionAfterShutdownCreatesNoSessionAndNoBackend() async throws {
        let createdBackends = ACPLifecycleCounter()
        let bridge = try Self.makeBridge(createdBackends: createdBackends)

        await bridge.shutdown()
        await #expect(throws: (any Error).self) {
            try await bridge.newSession(id: .number(2), params: Self.sessionParams())
        }

        #expect(await bridge.testSessionCount() == 0)
        #expect(createdBackends.value == 0)
    }

    // MARK: - session/load and session/resume

    @Test
    func loadSessionAfterShutdownCreatesNoSessionAndNoBackend() async throws {
        let createdBackends = ACPLifecycleCounter()
        let bridge = try Self.makeBridge(createdBackends: createdBackends)
        let sessionID = "session-\(UUID().uuidString)"

        await bridge.shutdown()
        await #expect(throws: (any Error).self) {
            try await bridge.loadSession(
                id: .number(3),
                params: Self.sessionParams(sessionID: sessionID)
            )
        }

        #expect(await bridge.testHasSession(sessionID: sessionID) == false)
        #expect(await bridge.testSessionCount() == 0)
        #expect(createdBackends.value == 0)
    }

    @Test
    func resumeSessionAfterShutdownCreatesNoSessionAndNoBackend() async throws {
        let createdBackends = ACPLifecycleCounter()
        let bridge = try Self.makeBridge(createdBackends: createdBackends)
        let sessionID = "session-\(UUID().uuidString)"

        await bridge.shutdown()
        await #expect(throws: (any Error).self) {
            try await bridge.resumeSession(
                id: .number(4),
                params: Self.sessionParams(sessionID: sessionID)
            )
        }

        #expect(await bridge.testHasSession(sessionID: sessionID) == false)
        #expect(await bridge.testSessionCount() == 0)
        #expect(createdBackends.value == 0)
    }

    @Test
    func restoreOfAnExistingSessionAfterShutdownIsRejected() async throws {
        // `restoreSession` has an early-return branch for an already-live
        // session that replays history and answers. Shutdown drops the session
        // table, so this must fail instead of replaying onto a closed transport.
        let bridge = try Self.makeBridge()

        try await bridge.newSession(id: .number(5), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())

        await bridge.shutdown()
        await #expect(throws: (any Error).self) {
            try await bridge.loadSession(
                id: .number(6),
                params: Self.sessionParams(sessionID: sessionID)
            )
        }
        #expect(await bridge.testSessionCount() == 0)
    }

    // MARK: - Other lifecycle handlers

    @Test
    func promptCancelAndCloseAreRejectedAfterShutdown() async throws {
        let bridge = try Self.makeBridge()

        try await bridge.newSession(id: .number(7), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())
        #expect(await bridge.testHasSession(sessionID: sessionID))

        await bridge.shutdown()

        await #expect(throws: (any Error).self) {
            try await bridge.cancel(id: .number(8), params: ["sessionId": sessionID])
        }
        await #expect(throws: (any Error).self) {
            try await bridge.close(id: .number(9), params: ["sessionId": sessionID])
        }
        await #expect(throws: (any Error).self) {
            try await bridge.prompt(
                id: .number(10),
                params: ["sessionId": sessionID, "prompt": "hello"]
            )
        }
        #expect(await bridge.testSessionCount() == 0)
    }

    @Test
    func setModelAndSetConfigOptionAreRejectedAfterShutdown() async throws {
        let bridge = try Self.makeBridge()

        try await bridge.newSession(id: .number(11), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())

        await bridge.shutdown()

        await #expect(throws: (any Error).self) {
            try await bridge.setModel(
                id: .number(12),
                params: ["sessionId": sessionID, "modelId": "test-model"]
            )
        }
        await #expect(throws: (any Error).self) {
            try await bridge.setConfigOption(
                id: .number(13),
                params: [
                    "sessionId": sessionID,
                    "configId": "model",
                    "value": "test-model"
                ]
            )
        }
        #expect(await bridge.testSessionCount() == 0)
    }

    @Test
    func preloadAfterShutdownBuildsNoBackend() async throws {
        let createdBackends = ACPLifecycleCounter()
        let bridge = try Self.makeBridge(createdBackends: createdBackends)

        await bridge.shutdown()
        await #expect(throws: (any Error).self) {
            try await bridge.preloadModel(id: .number(14), params: [:])
        }

        #expect(createdBackends.value == 0)
    }

    // MARK: - Negative controls (the fence must not break the normal path)

    @Test
    func newSessionWithoutShutdownStillPublishesTheSession() async throws {
        let bridge = try Self.makeBridge()

        try await bridge.newSession(id: .number(15), params: Self.sessionParams())

        #expect(await bridge.testSessionCount() == 1)
        let sessionID = try #require(await bridge.testAnySessionID())
        #expect(await bridge.testHasSession(sessionID: sessionID))
    }

    @Test
    func restoreWithoutShutdownStillPublishesTheSession() async throws {
        let bridge = try Self.makeBridge()
        let sessionID = "session-\(UUID().uuidString)"

        try await bridge.resumeSession(
            id: .number(16),
            params: Self.sessionParams(sessionID: sessionID)
        )

        #expect(await bridge.testHasSession(sessionID: sessionID))
        #expect(await bridge.testSessionCount() == 1)
    }

    @Test
    func closeWithoutShutdownStillRemovesOnlyThatSession() async throws {
        let bridge = try Self.makeBridge()

        try await bridge.newSession(id: .number(17), params: Self.sessionParams())
        try await bridge.newSession(id: .number(18), params: Self.sessionParams())
        #expect(await bridge.testSessionCount() == 2)

        let sessionID = try #require(await bridge.testAnySessionID())
        try await bridge.close(id: .number(19), params: ["sessionId": sessionID])

        #expect(await bridge.testHasSession(sessionID: sessionID) == false)
        #expect(await bridge.testSessionCount() == 1)
    }

    @Test
    func shutdownIsIdempotent() async throws {
        let bridge = try Self.makeBridge()

        try await bridge.newSession(id: .number(20), params: Self.sessionParams())
        await bridge.shutdown()
        await bridge.shutdown()

        #expect(await bridge.testSessionCount() == 0)
    }
}

/// Backend double whose `preloadModel` can be pinned by a gate. Only that call
/// is gated, so the suspension lands inside the lifecycle handler's runner call.
private actor ShutdownFenceBackend: AgentRuntimeBackend {
    private let preloadGate: ShutdownFenceGate?
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]

    init(preloadGate: ShutdownFenceGate? = nil) {
        self.preloadGate = preloadGate
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
        await preloadGate?.arriveAndWait()
        return "test-model"
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
        DirectAgentResponse(
            text: "",
            stopReason: "end_turn",
            modelID: "test-model"
        )
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}

extension ZenCODEACPBridge {
    func testSessionCount() -> Int {
        sessions.count
    }

    func testAnySessionID() -> String? {
        sessions.keys.first
    }
}
