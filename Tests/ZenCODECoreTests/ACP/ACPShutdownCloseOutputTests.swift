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
//    answer success for a session the host already closed. Through the real
//    dispatcher the request is answered with a JSON-RPC error (the transport
//    is still open, and JSON-RPC requires a response); after `shutdown()`,
//    whose transport is closing, it is abandoned without any answer;
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
import ToolCore

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

    /// The `error` member of the single reply carrying this id, if any.
    func error(id: Int) -> [String: Any]? {
        responses(id: id).first?["error"] as? [String: Any]
    }

    /// Messages that carry a JSON-RPC `error` member.
    var errors: [[String: Any]] {
        decoded.filter { $0["error"] != nil }
    }

    func containing(_ needle: String) -> [String] {
        all.filter { $0.contains(needle) }
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
            }
        )
    }

    private static func sessionParams() -> [String: Any] {
        [
            "cwd": FileManager.default.temporaryDirectory.path,
            "allowedTools": [String]()
        ]
    }

    /// The JSON-RPC request a client writes, for `bridge.handleMessage`.
    private static func request(
        _ id: Int,
        _ method: String,
        _ params: [String: Any]
    ) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    /// What a request fenced by a `session/close` (or a replacement of the
    /// same id) is answered with.
    private static let closedOrReplacedMessage =
        "The session was closed or replaced before this request completed."

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

    // MARK: - close invalidates the lifecycle operations of one epoch

    @Test
    func setModelSuspendedInRunnerDoesNotAnswerAfterClose() async throws {
        // Switching model forces the runner to drop its current backend, and
        // that teardown is pinned. A `session/close` for the same incarnation
        // lands there; the stale `set_model` must not answer success
        // afterwards. The handler is called directly here, so it only throws:
        // the error response is the dispatcher's, covered by
        // `closeDuringASuspendedSetModelAnswersTheSetModelWithAnError`.
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

        // The close was answered; the direct handler wrote nothing.
        #expect(transport.responses(id: 9).count == 1)
        #expect(transport.responses(id: 8).isEmpty)
        #expect(await bridge.testHasSession(sessionID: sessionID) == false)
        // The stale set re-created the session inside the runner while it was
        // suspended; the fence must have undone that, leaving no orphan.
        #expect(await bridge.testRunnerHasSession(sessionID: sessionID) == false)
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

    // MARK: - A fenced request is answered while the transport is open

    @Test
    func closeDuringASuspendedSetModelAnswersTheSetModelWithAnError() async throws {
        // Routed through `handleMessage`, so the response (or its absence) is
        // the dispatcher's. The `set_model` is pinned in the teardown of the
        // outgoing backend; the `session/close` of its incarnation lands
        // there. The transport is still open, so JSON-RPC requires the
        // `set_model` to be answered, with an error, exactly once.
        let transport = RecordingTransport()
        let teardownGate = OutputFenceGate()
        let backend = OutputFenceBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(22), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())
        try await bridge.prompt(
            id: .number(23),
            params: ["sessionId": sessionID, "prompt": "warm up"]
        )
        await backend.setShutdownGate(teardownGate)

        let setModelTask = Task {
            await bridge.handleMessage(Self.request(
                24,
                "_zencode/session/set_model",
                ["sessionId": sessionID, "modelId": "other-model"]
            ))
        }
        await teardownGate.waitUntilReached()
        #expect(transport.responses(id: 24).isEmpty)

        await bridge.handleMessage(Self.request(
            25,
            "session/close",
            ["sessionId": sessionID]
        ))
        teardownGate.open()
        await setModelTask.value

        // The close was answered with a result.
        #expect(transport.responses(id: 25).count == 1)
        #expect(transport.error(id: 25) == nil)
        // The stale set was answered once, with an error and no result.
        let setModelResponses = transport.responses(id: 24)
        #expect(setModelResponses.count == 1)
        #expect(setModelResponses.first?["result"] == nil)
        let error = try #require(transport.error(id: 24))
        #expect((error["code"] as? NSNumber)?.intValue == -32602)
        #expect(error["message"] as? String == Self.closedOrReplacedMessage)
        // Nothing else failed, and no session survived, in the bridge or in
        // the runner (where the stale set had re-created it).
        #expect(transport.errors.count == 1)
        #expect(await bridge.testHasSession(sessionID: sessionID) == false)
        #expect(await bridge.testRunnerHasSession(sessionID: sessionID) == false)
    }

    @Test
    func closeDuringASuspendedSetConfigOptionAnswersTheRequestWithAnError() async throws {
        // Same as above for `session/set_config_option` (`configId: "model"`),
        // which shares the fence of `set_model`.
        let transport = RecordingTransport()
        let teardownGate = OutputFenceGate()
        let backend = OutputFenceBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(26), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())
        try await bridge.prompt(
            id: .number(27),
            params: ["sessionId": sessionID, "prompt": "warm up"]
        )
        await backend.setShutdownGate(teardownGate)

        let setConfigTask = Task {
            await bridge.handleMessage(Self.request(
                28,
                "session/set_config_option",
                ["sessionId": sessionID, "configId": "model", "value": "other-model"]
            ))
        }
        await teardownGate.waitUntilReached()
        #expect(transport.responses(id: 28).isEmpty)

        await bridge.handleMessage(Self.request(
            29,
            "session/close",
            ["sessionId": sessionID]
        ))
        teardownGate.open()
        await setConfigTask.value

        #expect(transport.responses(id: 29).count == 1)
        #expect(transport.error(id: 29) == nil)
        let setConfigResponses = transport.responses(id: 28)
        #expect(setConfigResponses.count == 1)
        #expect(setConfigResponses.first?["result"] == nil)
        let error = try #require(transport.error(id: 28))
        #expect((error["code"] as? NSNumber)?.intValue == -32602)
        #expect(error["message"] as? String == Self.closedOrReplacedMessage)
        #expect(transport.errors.count == 1)
        #expect(await bridge.testHasSession(sessionID: sessionID) == false)
        #expect(await bridge.testRunnerHasSession(sessionID: sessionID) == false)
    }

    @Test
    func shutdownDuringASuspendedSetModelWritesNothingToTheTransport() async throws {
        // Negative control: the same suspended `set_model`, fenced by a
        // `shutdown()` instead of a `session/close`. The transport is closing,
        // so the request is abandoned: no result and no error response.
        let transport = RecordingTransport()
        let teardownGate = OutputFenceGate()
        let backend = OutputFenceBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(30), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())
        try await bridge.prompt(
            id: .number(31),
            params: ["sessionId": sessionID, "prompt": "warm up"]
        )
        await backend.setShutdownGate(teardownGate)

        let setModelTask = Task {
            await bridge.handleMessage(Self.request(
                32,
                "_zencode/session/set_model",
                ["sessionId": sessionID, "modelId": "other-model"]
            ))
        }
        await teardownGate.waitUntilReached()
        let messagesBeforeShutdown = transport.all.count

        // `shutdown()` may itself wait on the pinned teardown, so it runs
        // beside the test; the fence latches before its first suspension.
        let shutdownTask = Task { await bridge.shutdown() }
        while await !bridge.isShutDown {
            await Task.yield()
        }
        teardownGate.open()
        await shutdownTask.value
        await setModelTask.value

        #expect(transport.all.count == messagesBeforeShutdown)
        #expect(transport.responses(id: 32).isEmpty)
        #expect(transport.errors.isEmpty)
    }

    @Test
    func theLifecycleFenceErrorAnswersWhileTheTransportIsOpenAndStaysSilentAfterShutdown() async throws {
        let bridge = try Self.makeBridge(
            transport: RecordingTransport(),
            backend: OutputFenceBackend()
        )

        // Open transport: a response is owed, so the failure is an ACP error.
        let openError = try #require(await bridge.lifecycleOperationFenceError() as? ACPError)
        #expect(openError.code == -32602)
        #expect(openError.message == Self.closedOrReplacedMessage)

        // Closing transport: the failure is the silent shutdown fence.
        await bridge.shutdown()
        #expect(await bridge.lifecycleOperationFenceError() is ACPShutdownFenceError)
    }

    // MARK: - A request that unwinds by cancellation

    @Test
    func aCancelledRequestThatIsNotAPromptAnswersAJSONRPCError() async throws {
        // Only `session/prompt` has a cancelled stop reason in ACP. A request
        // that unwinds by cancellation, here a preload whose model call was
        // cancelled, is a JSON-RPC cancellation error instead.
        let transport = RecordingTransport()
        let bridge = try Self.makeBridge(
            transport: transport,
            backend: OutputFenceBackend(preloadCancels: true)
        )

        await bridge.handleMessage(Self.request(33, "_zencode/model/preload", [:]))

        let responses = transport.responses(id: 33)
        #expect(responses.count == 1)
        #expect(responses.first?["result"] == nil)
        let error = try #require(transport.error(id: 33))
        #expect((error["code"] as? NSNumber)?.intValue == -32800)
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
    private let preloadCancels: Bool
    private let eventsBeforeGate: [String]
    private let eventsAfterGate: [String]
    private var shutdownGate: OutputFenceGate?
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]

    init(
        promptGate: OutputFenceGate? = nil,
        preloadGate: OutputFenceGate? = nil,
        preloadCancels: Bool = false,
        eventsBeforeGate: [String] = [],
        eventsAfterGate: [String] = []
    ) {
        self.promptGate = promptGate
        self.preloadGate = preloadGate
        self.preloadCancels = preloadCancels
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
        if preloadCancels {
            throw CancellationError()
        }
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
