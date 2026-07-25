//
//  ACPShutdownCloseOutputTests.swift
//  ZenCODE
//
//  Coverage for the shutdown/close contract asserted on the bytes the bridge
//  actually hands to the transport, not on internal flags:
//
//  * an in-flight prompt emits no update, result or error after `shutdown()`,
//    and a prompt arriving afterwards is abandoned without an error response;
//  * `session/close` invalidates the lifecycle operations bound to that exact
//    session incarnation, so a late `set_model` / `set_config_option` cannot
//    answer success for a session the host already closed;
//  * an operation fenced by `shutdown()` does not rebuild the backend.
//
//  Every interleaving is pinned with gates placed on genuinely suspending
//  seams (`sendPrompt`, `preloadModel`, `shutdown`), never with sleeps.
//  Nothing here copies, mutates or restores source files.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing

/// Collects every JSON-RPC message the bridge writes, so assertions run against
/// the real wire output of `ACPWriter`.
private final class RecordingTransport: Sendable {
    private let messages = Mutex<[String]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            guard let text = String(data: data, encoding: .utf8) else {
                return
            }
            self.messages.withLock { $0.append(text) }
        }
    }

    var all: [String] {
        messages.withLock { $0 }
    }

    /// Decoded messages, so id/error assertions do not depend on how numbers
    /// happen to be rendered in the JSON text.
    private var decoded: [[String: Any]] {
        all.compactMap { text in
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                return nil
            }
            return object as? [String: Any]
        }
    }

    /// Replies carrying this JSON-RPC id.
    func responses(id: Int) -> [[String: Any]] {
        decoded.filter { message in
            guard let rawID = message["id"] as? NSNumber else {
                return false
            }
            return rawID.intValue == id
        }
    }

    /// Messages that carry a JSON-RPC `error` member.
    var errors: [[String: Any]] {
        decoded.filter { $0["error"] != nil }
    }

    func containing(_ needle: String) -> [String] {
        all.filter { $0.contains(needle) }
    }
}

/// Gate that reports arrival, so a test can pin production code at an exact
/// suspension point and only then run the racing operation.
private final class OutputFenceGate: Sendable {
    private struct State {
        var isOpen = false
        var arrivals = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var arrivals: Int {
        state.withLock { $0.arrivals }
    }

    func arriveAndWait() async {
        let pendingArrivals = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.arrivals += 1
            let pending = state.arrivalWaiters
            state.arrivalWaiters.removeAll()
            return pending
        }
        for waiter in pendingArrivals {
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

    func waitUntilReached() async {
        if state.withLock({ $0.arrivals > 0 }) {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.arrivals > 0 {
                    return true
                }
                state.arrivalWaiters.append(continuation)
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
struct ACPShutdownCloseOutputTests {
    private static func makeConfiguration() throws -> AgentConfiguration {
        try AgentConfiguration(
            hostedModelID: "test-model",
            availableModels: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                ),
                AgentSettingsModelManifest(
                    id: "other-model",
                    kind: .remoteAPI,
                    modelID: "local/other-model"
                )
            ],
            runMode: .acp,
            workingDirectory: FileManager.default.temporaryDirectory
        )
    }

    private static func makeBridge(
        transport: RecordingTransport,
        backend: OutputFenceBackend,
        createdBackends: ACPLifecycleCounter? = nil
    ) throws -> ZenCODEACPBridge {
        ZenCODEACPBridge(
            configuration: try makeConfiguration(),
            writer: ACPWriter(sink: transport.sink),
            backendFactory: { _, _ in
                createdBackends?.increment()
                return backend
            },
            xcodeIsRunning: { false }
        )
    }

    private static func sessionParams() -> [String: Any] {
        [
            "cwd": FileManager.default.temporaryDirectory.path,
            "allowedTools": [String]()
        ]
    }

    // MARK: - In-flight prompt

    @Test
    func inFlightPromptEmitsNothingOnTheTransportAfterShutdown() async throws {
        // The prompt is pinned inside generation, having already emitted one
        // event. `shutdown()` latches while it is still suspended; only then is
        // generation released, so everything the prompt does afterwards (its
        // late event, its update flush, its `stopReason` result) happens on a
        // transport that must already be closed.
        let transport = RecordingTransport()
        let promptGate = OutputFenceGate()
        let backend = OutputFenceBackend(
            promptGate: promptGate,
            eventsBeforeGate: ["before-shutdown"],
            eventsAfterGate: ["after-shutdown"]
        )
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(1), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())

        let promptTask = Task {
            try await bridge.prompt(
                id: .number(2),
                params: ["sessionId": sessionID, "prompt": "hello"]
            )
        }
        await promptGate.waitUntilReached()

        // Everything written before the fence is legitimate and must survive.
        #expect(!transport.containing("before-shutdown").isEmpty)
        let messagesBeforeShutdown = transport.all.count

        await bridge.shutdown()
        promptGate.open()
        _ = try? await promptTask.value

        #expect(transport.all.count == messagesBeforeShutdown)
        #expect(transport.containing("after-shutdown").isEmpty)
        #expect(transport.responses(id: 2).isEmpty)
        #expect(transport.containing("stopReason").isEmpty)
    }

    @Test
    func promptArrivingAfterShutdownWritesNoErrorResponse() async throws {
        // Routed through `handleMessage`, so this covers the real dispatch
        // path: the fence must be observed before the session lookup, or the
        // request is answered "unknown session" on a closed transport.
        let transport = RecordingTransport()
        let bridge = try Self.makeBridge(
            transport: transport,
            backend: OutputFenceBackend()
        )

        try await bridge.newSession(id: .number(3), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())

        await bridge.shutdown()

        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": 4,
            "method": "session/prompt",
            "params": ["sessionId": sessionID, "prompt": "hello"] as [String: Any]
        ])

        #expect(transport.responses(id: 4).isEmpty)
        #expect(transport.errors.isEmpty)
    }

    @Test
    func promptForUnknownSessionStillAnswersWithAnErrorWithoutShutdown() async throws {
        // Negative control: reordering the fence must not swallow ordinary
        // invalid-params errors while the transport is open.
        let transport = RecordingTransport()
        let bridge = try Self.makeBridge(
            transport: transport,
            backend: OutputFenceBackend()
        )

        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": 5,
            "method": "session/prompt",
            "params": ["sessionId": "missing-session", "prompt": "hello"] as [String: Any]
        ])

        #expect(transport.responses(id: 5).count == 1)
        #expect(transport.errors.count == 1)
    }

    // MARK: - close invalidates the lifecycle operations of one epoch

    @Test
    func setModelSuspendedInRunnerDoesNotAnswerAfterClose() async throws {
        // Switching model forces the runner to drop its current backend, and
        // that teardown is pinned. A `session/close` for the same incarnation
        // lands there; the stale `set_model` must not answer afterwards.
        let transport = RecordingTransport()
        let teardownGate = OutputFenceGate()
        let backend = OutputFenceBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(6), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())
        // Resolve the runtime backend so the model switch really tears one down.
        try await bridge.prompt(
            id: .number(7),
            params: ["sessionId": sessionID, "prompt": "warm up"]
        )
        await backend.setShutdownGate(teardownGate)

        let setModelTask = Task {
            try await bridge.setModel(
                id: .number(8),
                params: ["sessionId": sessionID, "modelId": "other-model"]
            )
        }
        await teardownGate.waitUntilReached()

        try await bridge.close(id: .number(9), params: ["sessionId": sessionID])
        teardownGate.open()
        _ = try? await setModelTask.value

        // The close was answered; the stale set was not.
        #expect(transport.responses(id: 9).count == 1)
        #expect(transport.responses(id: 8).isEmpty)
        #expect(await bridge.testHasSession(sessionID: sessionID) == false)
        // The stale set re-created the session inside the runner while it was
        // suspended; the fence must have undone that, leaving no orphan.
        #expect(await bridge.testRunnerHasSession(sessionID: sessionID) == false)
    }

    @Test
    func setConfigOptionSuspendedInRunnerDoesNotAnswerAfterClose() async throws {
        let transport = RecordingTransport()
        let teardownGate = OutputFenceGate()
        let backend = OutputFenceBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(10), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())
        try await bridge.prompt(
            id: .number(11),
            params: ["sessionId": sessionID, "prompt": "warm up"]
        )
        await backend.setShutdownGate(teardownGate)

        let setConfigTask = Task {
            try await bridge.setConfigOption(
                id: .number(12),
                params: [
                    "sessionId": sessionID,
                    "configId": "model",
                    "value": "other-model"
                ]
            )
        }
        await teardownGate.waitUntilReached()

        let configOptionsBeforeClose = transport.containing("configOptions").count
        try await bridge.close(id: .number(13), params: ["sessionId": sessionID])
        teardownGate.open()
        _ = try? await setConfigTask.value

        #expect(transport.responses(id: 13).count == 1)
        #expect(transport.responses(id: 12).isEmpty)
        #expect(transport.containing("configOptions").count == configOptionsBeforeClose)
    }

    @Test
    func closeDoesNotInvalidateLifecycleWorkOfAnotherSession() async throws {
        // Negative control for the epoch scoping: closing one session must not
        // fence a concurrent `set_model` that belongs to a different session.
        let transport = RecordingTransport()
        let teardownGate = OutputFenceGate()
        let backend = OutputFenceBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(14), params: Self.sessionParams())
        let firstSessionID = try #require(await bridge.testAnySessionID())
        try await bridge.newSession(id: .number(15), params: Self.sessionParams())
        let secondSessionID = try #require(
            await bridge.testSessionIDs().first { $0 != firstSessionID }
        )
        try await bridge.prompt(
            id: .number(16),
            params: ["sessionId": secondSessionID, "prompt": "warm up"]
        )
        await backend.setShutdownGate(teardownGate)

        let setModelTask = Task {
            try await bridge.setModel(
                id: .number(17),
                params: ["sessionId": secondSessionID, "modelId": "other-model"]
            )
        }
        await teardownGate.waitUntilReached()

        try await bridge.close(id: .number(18), params: ["sessionId": firstSessionID])
        teardownGate.open()
        try await setModelTask.value

        #expect(transport.responses(id: 17).count == 1)
        #expect(await bridge.testHasSession(sessionID: secondSessionID))
    }

    @Test
    func closeInvalidatesOnlyTheBoundOperationsOfTheClosedIncarnation() async throws {
        // Direct coverage of the primitive the restore fast path and both
        // setters rely on: binding an operation to one incarnation, and having
        // `session/close` invalidate exactly that binding.
        let transport = RecordingTransport()
        let bridge = try Self.makeBridge(
            transport: transport,
            backend: OutputFenceBackend()
        )

        try await bridge.newSession(id: .number(19), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())
        let epoch = try #require(await bridge.testSessionEpoch(sessionID: sessionID))

        let boundOperation = try await bridge.registerLifecycleOperation()
        await bridge.bindLifecycleOperation(
            boundOperation,
            sessionID: sessionID,
            epoch: epoch
        )
        let unboundOperation = try await bridge.registerLifecycleOperation()
        #expect(await bridge.isLifecycleOperationLive(boundOperation))
        #expect(await bridge.isLifecycleOperationLive(unboundOperation))

        try await bridge.close(id: .number(20), params: ["sessionId": sessionID])

        #expect(await bridge.isLifecycleOperationLive(boundOperation) == false)
        // Work that is not tied to the closed incarnation keeps running.
        #expect(await bridge.isLifecycleOperationLive(unboundOperation))
    }

    // MARK: - Stale work rebuilds nothing

    @Test
    func preloadFencedByShutdownWritesNoResult() async throws {
        let transport = RecordingTransport()
        let preloadGate = OutputFenceGate()
        let createdBackends = ACPLifecycleCounter()
        let backend = OutputFenceBackend(preloadGate: preloadGate)
        let bridge = try Self.makeBridge(
            transport: transport,
            backend: backend,
            createdBackends: createdBackends
        )

        let preloadTask = Task {
            try await bridge.preloadModel(id: .number(21), params: [:])
        }
        await preloadGate.waitUntilReached()
        let backendsBeforeShutdown = createdBackends.value

        await bridge.shutdown()
        preloadGate.open()
        _ = try? await preloadTask.value

        #expect(createdBackends.value == backendsBeforeShutdown)
        #expect(transport.responses(id: 21).isEmpty)
    }

    @Test
    func runnerDoesNotRebuildBackendForAnOperationFencedByShutdown() async throws {
        // A `createSession` that must swap runtimes is pinned inside the
        // teardown of the outgoing backend. `shutdown()` lands there. When the
        // operation resumes it must fail instead of looping and building a
        // replacement backend for a runtime nobody drives anymore.
        let creations = ACPLifecycleCounter()
        let teardownGate = OutputFenceGate()
        let backend = OutputFenceBackend()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in
                creations.increment()
                return backend
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        )

        // Resolve a first backend so the model switch below really tears one down.
        _ = try await runner.preloadModel(configuration: configuration, onEvent: { _ in })
        #expect(creations.value == 1)
        await backend.setShutdownGate(teardownGate)

        let switchTask = Task {
            try await runner.createSession(
                configuration: configuration.withModelID("other-model")
            )
        }
        await teardownGate.waitUntilReached()

        await runner.shutdown()
        teardownGate.open()

        await #expect(throws: (any Error).self) {
            try await switchTask.value
        }
        // No replacement backend was built for the fenced operation.
        #expect(creations.value == 1)
    }

    @Test
    func fencedOperationRegistersNoACPProvidedMCPServer() async throws {
        // With a fenced token the loop must return before touching the first
        // definition, so no MCP server is connected or appended after shutdown.
        let transport = RecordingTransport()
        let bridge = try Self.makeBridge(
            transport: transport,
            backend: OutputFenceBackend()
        )
        let params: [String: Any] = [
            "mcpServers": [
                [
                    "name": "unreachable-server",
                    "command": "/nonexistent/zencode-test-mcp-server",
                    "args": [String]()
                ] as [String: Any]
            ]
        ]

        let operation = try await bridge.registerLifecycleOperation()
        await bridge.shutdown()

        let descriptors = await bridge.registerACPProvidedMCPServers(
            from: params,
            operation: operation
        )

        #expect(descriptors.isEmpty)
        #expect(await bridge.testKnownMCPToolDescriptorsAreEmpty())
    }
}

// MARK: - Backend double

/// Runtime backend whose genuinely suspending entry points (`sendPrompt`,
/// `preloadModel`, `shutdown`) can each be pinned by a gate, so a racing
/// shutdown or close lands at an exact suspension point.
///
/// `createSession` and `snapshotSession` are synchronous protocol requirements
/// and therefore cannot host a gate; the tests pin the teardown seam instead.
private actor OutputFenceBackend: AgentRuntimeBackend {
    private let promptGate: OutputFenceGate?
    private let preloadGate: OutputFenceGate?
    private let eventsBeforeGate: [String]
    private let eventsAfterGate: [String]
    private var shutdownGate: OutputFenceGate?
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]

    init(
        promptGate: OutputFenceGate? = nil,
        preloadGate: OutputFenceGate? = nil,
        eventsBeforeGate: [String] = [],
        eventsAfterGate: [String] = []
    ) {
        self.promptGate = promptGate
        self.preloadGate = preloadGate
        self.eventsBeforeGate = eventsBeforeGate
        self.eventsAfterGate = eventsAfterGate
    }

    func setShutdownGate(_ gate: OutputFenceGate?) {
        shutdownGate = gate
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
        await shutdownGate?.arriveAndWait()
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
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        for text in eventsBeforeGate {
            await onEvent(.content(text))
        }
        await promptGate?.arriveAndWait()
        for text in eventsAfterGate {
            await onEvent(.content(text))
        }
        return DirectAgentResponse(
            text: "done",
            stopReason: "end_turn",
            modelID: "test-model"
        )
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}

extension ZenCODEACPBridge {
    func testSessionIDs() -> [String] {
        Array(sessions.keys)
    }

    func testSessionEpoch(sessionID: String) -> UInt64? {
        sessions[sessionID]?.epoch
    }

    func testKnownMCPToolDescriptorsAreEmpty() async -> Bool {
        await sessionRunner.knownMCPToolDescriptors().isEmpty
    }

    func testRunnerHasSession(sessionID: String) async -> Bool {
        await sessionRunner.snapshotSession(id: sessionID) != nil
    }
}
