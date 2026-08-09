//
//  ACPSharedChatForwardingTests.swift
//  ZenCODE
//
//  Lifecycle coverage for the ACP shared-chat renderer, asserted on the bytes
//  the bridge actually hands to the transport:
//
//  * an `agent.message` sent through the shared bus reaches the ACP client as a
//    standard `agent_message_chunk`, while operator traffic — already rendered
//    by the host — is not echoed a second time;
//  * exactly one observer exists per session incarnation, even when several
//    starts race across the attach suspension;
//  * the renderer survives every `SessionState` rebuild (prompt refresh,
//    `set_model` commit), because it is owned by a registry rather than by the
//    session value those paths replace;
//  * `session/close` and `shutdown` stop it and wait for its quiescence, so
//    nothing is written for a session the host already dropped.
//
//  Ordering is pinned with delivery barriers (a later message observed on the
//  same pipeline, or an independent observation of the same room), never with
//  sleeps. Nothing here copies, mutates or restores source files.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

/// Collects every JSON-RPC message the bridge writes and decodes the
/// `session/update` notifications, so assertions run against real wire output.
private final class SharedChatRecordingTransport: Sendable {
    struct Update {
        let sessionID: String
        let kind: String
        let text: String
    }

    private let messages = Mutex<[String]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            guard let text = String(data: data, encoding: .utf8) else {
                return
            }
            messages.withLock { $0.append(text) }
        }
    }

    var all: [String] {
        messages.withLock { $0 }
    }

    var updates: [Update] {
        all.compactMap { text in
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "session/update",
                  let params = object["params"] as? [String: Any],
                  let sessionID = params["sessionId"] as? String,
                  let update = params["update"] as? [String: Any],
                  let kind = update["sessionUpdate"] as? String else {
                return nil
            }
            let content = update["content"] as? [String: Any]
            return Update(
                sessionID: sessionID,
                kind: kind,
                text: content?["text"] as? String ?? ""
            )
        }
    }

    func updates(withText text: String) -> [Update] {
        updates.filter { $0.text == text }
    }

    func containing(_ needle: String) -> [String] {
        all.filter { $0.contains(needle) }
    }
}

/// A lossless two-party barrier used to hold the bridge precisely between
/// publishing an attach reservation and invoking the runner attach operation.
private actor SharedChatAttachBarrier {
    private var didArrive = false
    private var isOpen = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func block() async {
        didArrive = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilBlocked() async {
        guard !didArrive else {
            return
        }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func open() {
        isOpen = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

/// Runtime backend with a controllable shared-chat transcript. The coordinator
/// reads it through `allRoomMessages`, which is the path agent-to-agent traffic
/// takes: no mailbox drain, so no synthetic turn is ever offered.
private actor SharedChatTestBackend: AgentRuntimeBackend {
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var transcripts: [String: [AgentSharedChat.Message]] = [:]
    /// Called on every transcript read, so a test can observe *when* the
    /// coordinator first reaches a room — that is, when its observer attached.
    private var transcriptReadProbe: (@Sendable (String) -> Void)?

    func append(_ message: AgentSharedChat.Message) {
        transcripts[message.roomID, default: []].append(message)
    }

    func setTranscriptReadProbe(_ probe: @escaping @Sendable (String) -> Void) {
        transcriptReadProbe = probe
    }

    func sharedChatTranscriptMessages(rootSessionID: String) -> [AgentSharedChat.Message] {
        transcriptReadProbe?(rootSessionID)
        return transcripts[rootSessionID] ?? []
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
        DirectAgentResponse(text: "done", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ACPSharedChatForwardingTests {
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
        transport: SharedChatRecordingTransport,
        backend: SharedChatTestBackend
    ) throws -> ZenCODEACPBridge {
        ZenCODEACPBridge(
            configuration: try makeConfiguration(),
            writer: ACPWriter(sink: transport.sink),
            backendFactory: { _, _ in backend }
        )
    }

    private static func sessionParams() -> [String: Any] {
        [
            "cwd": FileManager.default.temporaryDirectory.path,
            "allowedTools": [String]()
        ]
    }

    private static func message(
        roomID: String,
        senderName: String,
        kind: AgentSharedChat.ParticipantKind,
        text: String
    ) -> AgentSharedChat.Message {
        AgentSharedChat.Message(
            roomID: roomID,
            sender: AgentSharedChat.Participant(
                id: "\(kind.rawValue):\(senderName)",
                name: senderName,
                kind: kind
            ),
            recipientIDs: [AgentSharedChat.coordinatorID(for: roomID)],
            text: text
        )
    }

    /// Brings up a session whose runtime backend is resolved, which is what puts
    /// the shared-chat transcript within the coordinator's reach.
    private static func makeLiveSession(
        bridge: ZenCODEACPBridge,
        promptID: Int
    ) async throws -> String {
        try await bridge.newSession(id: .number(1), params: sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())
        try await bridge.prompt(
            id: .number(Double(promptID)),
            params: ["sessionId": sessionID, "prompt": "warm up"]
        )
        return sessionID
    }

    // MARK: - Forwarding

    @Test
    func agentMessageIsRenderedAsAStandardACPChunk() async throws {
        let transport = SharedChatRecordingTransport()
        let backend = SharedChatTestBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)
        let sessionID = try await Self.makeLiveSession(bridge: bridge, promptID: 2)

        await backend.append(
            Self.message(
                roomID: sessionID,
                senderName: "worker",
                kind: .agent,
                text: "task done"
            )
        )
        await terminalWaitUntil { !transport.updates(withText: "[worker] task done").isEmpty }

        let update = try #require(transport.updates(withText: "[worker] task done").first)
        #expect(update.sessionID == sessionID)
        #expect(update.kind == "agent_message_chunk")
        await bridge.shutdown()
    }

    @Test
    func operatorMessagesAreNotEchoedBackToTheClient() async throws {
        // The operator's text is the host's own prompt: the client rendered it
        // and the bridge already echoed it as a user chunk. Re-emitting it from
        // the shared transcript would show the same input twice.
        let transport = SharedChatRecordingTransport()
        let backend = SharedChatTestBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)
        let sessionID = try await Self.makeLiveSession(bridge: bridge, promptID: 2)

        // Appended first, so the agent message that follows it in the same
        // delivery batch is a barrier: once it is on the wire, the operator
        // message has already been through the renderer.
        await backend.append(
            Self.message(
                roomID: sessionID,
                senderName: "operator",
                kind: .operator,
                text: "warm up"
            )
        )
        await backend.append(
            Self.message(
                roomID: sessionID,
                senderName: "worker",
                kind: .agent,
                text: "on it"
            )
        )
        await terminalWaitUntil { !transport.updates(withText: "[worker] on it").isEmpty }

        #expect(transport.containing("[operator]").isEmpty)
        #expect(transport.updates.filter { $0.text == "warm up" && $0.kind == "user_message_chunk" }.count == 1)
        await bridge.shutdown()
    }

    // MARK: - Single flight

    @Test
    func concurrentStartsAttachExactlyOneObserver() async throws {
        // `startSharedChatForwarding` suspends inside the attach. Without a
        // reservation published before that suspension, every racing caller
        // would attach its own observer and the client would see each shared
        // message once per observer.
        let transport = SharedChatRecordingTransport()
        let backend = SharedChatTestBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)
        let sessionID = try await Self.makeLiveSession(bridge: bridge, promptID: 2)
        let epoch = try #require(await bridge.testSessionEpoch(sessionID: sessionID))
        let originalObservationID = try #require(
            await bridge.testSharedChatObservationID(sessionID: sessionID)
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 6 {
                group.addTask {
                    await bridge.startSharedChatForwarding(sessionID: sessionID, epoch: epoch)
                }
            }
        }
        // A second `session/load` for the same live session takes the fast path
        // and must not attach a second observer either.
        try await bridge.loadSession(id: .number(3), params: ["sessionId": sessionID])

        #expect(await bridge.testSharedChatForwarderCount() == 1)
        #expect(await bridge.testSharedChatObservationID(sessionID: sessionID) == originalObservationID)

        await backend.append(
            Self.message(roomID: sessionID, senderName: "worker", kind: .agent, text: "once")
        )
        await terminalWaitUntil { !transport.updates(withText: "[worker] once").isEmpty }
        // A later message delivered through the same pipeline bounds the wait:
        // any duplicate of the first one would already be on the wire.
        await backend.append(
            Self.message(roomID: sessionID, senderName: "worker", kind: .agent, text: "barrier")
        )
        await terminalWaitUntil { !transport.updates(withText: "[worker] barrier").isEmpty }

        #expect(transport.updates(withText: "[worker] once").count == 1)
        await bridge.shutdown()
    }

    // MARK: - Session state rebuilds

    @Test
    func rendererSurvivesEverySessionStateRebuild() async throws {
        // A prompt refreshes the session from the runner snapshot and a model
        // change commits a rebuilt session value. Both replace `SessionState`
        // wholesale, so a renderer stored inside it would be dropped without a
        // detach: the observer would leak and the client would go silent.
        let transport = SharedChatRecordingTransport()
        let backend = SharedChatTestBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)
        let sessionID = try await Self.makeLiveSession(bridge: bridge, promptID: 2)
        let originalObservationID = try #require(
            await bridge.testSharedChatObservationID(sessionID: sessionID)
        )

        try await bridge.prompt(
            id: .number(3),
            params: ["sessionId": sessionID, "prompt": "second turn"]
        )
        try await bridge.setModel(
            id: .number(4),
            params: ["sessionId": sessionID, "modelId": "other-model"]
        )
        try await bridge.setConfigOption(
            id: .number(5),
            params: ["sessionId": sessionID, "configId": "model", "value": "test-model"]
        )
        // A model change drops the runtime backend, so the transcript source is
        // only readable again once a prompt rebuilds it. The renderer itself is
        // expected to have survived all of the above untouched.
        try await bridge.prompt(
            id: .number(6),
            params: ["sessionId": sessionID, "prompt": "third turn"]
        )

        #expect(await bridge.testSharedChatObservationID(sessionID: sessionID) == originalObservationID)
        #expect(await bridge.testSharedChatForwarderCount() == 1)

        await backend.append(
            Self.message(
                roomID: sessionID,
                senderName: "worker",
                kind: .agent,
                text: "still rendering"
            )
        )
        await terminalWaitUntil {
            !transport.updates(withText: "[worker] still rendering").isEmpty
        }

        #expect(transport.updates(withText: "[worker] still rendering").count == 1)
        await bridge.shutdown()
    }

    // MARK: - Load and resume

    @Test
    func loadReplaysHistoryBeforeTheSharedChatTranscript() async throws {
        // The attach replays the room transcript, so attaching before the
        // history replay would interleave shared-chat chunks with the
        // conversation the host is rebuilding.
        let transport = SharedChatRecordingTransport()
        let backend = SharedChatTestBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)
        // A first session resolves the runtime backend, so the transcript of the
        // session loaded below is readable while it is being restored.
        _ = try await Self.makeLiveSession(bridge: bridge, promptID: 2)

        let loadedSessionID = "restored-acp-session"
        await backend.append(
            Self.message(
                roomID: loadedSessionID,
                senderName: "worker",
                kind: .agent,
                text: "agent note"
            )
        )
        // The coordinator can only read this room once its observer attached,
        // so the number of chunks already written when that first read happens
        // is a happens-before edge: attaching before the replay would observe a
        // transcript with none of the history on the wire yet.
        let chunksAtAttach = Mutex<Int?>(nil)
        await backend.setTranscriptReadProbe { roomID in
            guard roomID == loadedSessionID else {
                return
            }
            let written = transport.updates.filter { update in
                update.sessionID == loadedSessionID && update.kind.hasSuffix("_message_chunk")
            }.count
            chunksAtAttach.withLock { value in
                if value == nil {
                    value = written
                }
            }
        }
        try await bridge.loadSession(
            id: .number(3),
            params: [
                "sessionId": loadedSessionID,
                "cwd": FileManager.default.temporaryDirectory.path,
                "history": [
                    ["role": "user", "content": "first question"],
                    ["role": "assistant", "content": "first answer"]
                ]
            ]
        )
        await terminalWaitUntil { !transport.updates(withText: "[worker] agent note").isEmpty }

        // Both replayed history chunks were already on the wire when the room
        // was first read.
        #expect(try #require(chunksAtAttach.withLock { $0 }) == 2)
        let updates = transport.updates.filter { $0.sessionID == loadedSessionID }
        let lastHistoryIndex = try #require(updates.lastIndex { $0.text == "first answer" })
        let firstSharedChatIndex = try #require(updates.firstIndex { $0.text == "[worker] agent note" })
        #expect(lastHistoryIndex < firstSharedChatIndex)
        #expect(updates.filter { $0.text == "[worker] agent note" }.count == 1)
        await bridge.shutdown()
    }

    // MARK: - Teardown

    @Test
    func closeStopsTheRendererBeforeAnswering() async throws {
        let transport = SharedChatRecordingTransport()
        let backend = SharedChatTestBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)
        let sessionID = try await Self.makeLiveSession(bridge: bridge, promptID: 2)

        await backend.append(
            Self.message(
                roomID: sessionID,
                senderName: "worker",
                kind: .agent,
                text: "before close"
            )
        )
        await terminalWaitUntil { !transport.updates(withText: "[worker] before close").isEmpty }

        try await bridge.close(id: .number(3), params: ["sessionId": sessionID])
        #expect(await bridge.testSharedChatForwarderCount() == 0)
        #expect(await bridge.testHasSession(sessionID: sessionID) == false)

        await backend.append(
            Self.message(
                roomID: sessionID,
                senderName: "worker",
                kind: .agent,
                text: "after close"
            )
        )
        // Barrier: an independent observation of the same room proves the
        // message really is deliverable, so the absence of an ACP update is a
        // property of the teardown and not of a message that never arrived.
        await Self.waitForSharedChatDelivery(
            of: "after close",
            runner: bridge.sessionRunner,
            roomID: sessionID
        )

        #expect(transport.containing("after close").isEmpty)
        await bridge.shutdown()
    }

    @Test
    func shutdownStopsTheRendererAndWritesNothingAfterTheFence() async throws {
        let transport = SharedChatRecordingTransport()
        let backend = SharedChatTestBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)
        let sessionID = try await Self.makeLiveSession(bridge: bridge, promptID: 2)

        await backend.append(
            Self.message(
                roomID: sessionID,
                senderName: "worker",
                kind: .agent,
                text: "before shutdown"
            )
        )
        await terminalWaitUntil { !transport.updates(withText: "[worker] before shutdown").isEmpty }
        let messagesBeforeShutdown = transport.all.count

        await bridge.shutdown()
        #expect(await bridge.testSharedChatForwarderCount() == 0)

        await backend.append(
            Self.message(
                roomID: sessionID,
                senderName: "worker",
                kind: .agent,
                text: "after shutdown"
            )
        )
        // The renderer was awaited before `shutdown()` returned, so no further
        // scheduling can produce output; the writer fence is the second line of
        // defence and both are asserted on the byte count.
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(transport.all.count == messagesBeforeShutdown)
        #expect(transport.containing("after shutdown").isEmpty)
    }

    @Test
    func closeWaitsForAnAttachThatWasAlreadyReserved() async throws {
        let transport = SharedChatRecordingTransport()
        let backend = SharedChatTestBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)
        let sessionID = try await Self.makeLiveSession(bridge: bridge, promptID: 2)
        let epoch = try #require(await bridge.testSessionEpoch(sessionID: sessionID))
        await bridge.stopSharedChatForwarding(sessionID: sessionID)

        let barrier = SharedChatAttachBarrier()
        await bridge.testSetSharedChatAttachBarrier { await barrier.block() }
        let attach = Task {
            await bridge.startSharedChatForwarding(sessionID: sessionID, epoch: epoch)
        }
        await barrier.waitUntilBlocked()

        let didClose = Mutex(false)
        let close = Task {
            try await bridge.close(id: .number(3), params: ["sessionId": sessionID])
            didClose.withLock { $0 = true }
        }
        await Self.waitForNoSharedChatForwarder(bridge)
        #expect(!didClose.withLock { $0 })

        await barrier.open()
        _ = try await close.value
        await attach.value
        #expect(didClose.withLock { $0 })
        #expect(await bridge.testSharedChatForwarderCount() == 0)
    }

    @Test
    func shutdownWaitsForAnAttachThatWasAlreadyReserved() async throws {
        let transport = SharedChatRecordingTransport()
        let backend = SharedChatTestBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)
        let sessionID = try await Self.makeLiveSession(bridge: bridge, promptID: 2)
        let epoch = try #require(await bridge.testSessionEpoch(sessionID: sessionID))
        await bridge.stopSharedChatForwarding(sessionID: sessionID)

        let barrier = SharedChatAttachBarrier()
        await bridge.testSetSharedChatAttachBarrier { await barrier.block() }
        let attach = Task {
            await bridge.startSharedChatForwarding(sessionID: sessionID, epoch: epoch)
        }
        await barrier.waitUntilBlocked()

        let didShutDown = Mutex(false)
        let shutdown = Task {
            await bridge.shutdown()
            didShutDown.withLock { $0 = true }
        }
        await Self.waitForNoSharedChatForwarder(bridge)
        #expect(!didShutDown.withLock { $0 })

        await barrier.open()
        await shutdown.value
        await attach.value
        #expect(didShutDown.withLock { $0 })
        #expect(await bridge.testSharedChatForwarderCount() == 0)
    }

    private static func waitForNoSharedChatForwarder(_ bridge: ZenCODEACPBridge) async {
        while await bridge.testSharedChatForwarderCount() != 0 {
            await Task.yield()
        }
    }

    /// Suspends until the room really delivers `text` to a fresh observer.
    private static func waitForSharedChatDelivery(
        of text: String,
        runner: AgentCoreSessionRunner,
        roomID: String
    ) async {
        let observation = await runner.attachSharedChatObservation(rootSessionID: roomID)
        for await event in observation.events {
            guard case let .messages(messages) = event else {
                continue
            }
            if messages.contains(where: { $0.text == text }) {
                break
            }
        }
        await runner.detachSharedChatObservation(observation)
    }
}

extension ZenCODEACPBridge {
    func testSharedChatForwarderCount() -> Int {
        sharedChatForwarders.count
    }

    /// Observer identity of the renderer bound to this session, or `nil` while
    /// no renderer is published. Stable across `SessionState` rebuilds.
    func testSharedChatObservationID(sessionID: String) -> UUID? {
        sharedChatForwarders[sessionID]?.observation?.id
    }

    func testSetSharedChatAttachBarrier(
        _ barrier: @escaping @Sendable () async -> Void
    ) {
        sharedChatAttachBarrier = barrier
    }
}
