//
//  ACPCloseQuiescenceTests.swift
//  ZenCODE
//
//  Coverage for the `session/close` quiescence contract:
//
//  * a prompt cancelled by `session/close` replies `stopReason: cancelled` and
//    flushes its buffered updates strictly before the close reply;
//  * no `session/update` for the closed session follows the close reply;
//  * the drain introduces no deadlock: a close with no in-flight prompt
//    answers immediately, `session/cancel` still answers while the cancelled
//    prompt unwinds, and a `shutdown()` landing inside the drain lets both
//    handlers finish without writing anything after the transport fence.
//
//  Interleavings are pinned with a gate on the backend's `sendPrompt` — a
//  genuinely suspending seam — never with sleeps. The ACP prompt wrapper task
//  is the one under test: the backend double ends the turn as cancelled once
//  the gate opens, exactly like a runtime that honours task cancellation.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

/// Collects every JSON-RPC message the bridge writes, keeping arrival order so
/// quiescence can be asserted as *ordering on the wire*, not just presence.
private final class CloseQuiescenceTransport: Sendable {
    private let messages = Mutex<[String]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            guard let text = String(data: data, encoding: .utf8) else {
                return
            }
            messages.withLock { $0.append(text) }
        }
    }

    var count: Int {
        messages.withLock { $0.count }
    }

    private var texts: [String] {
        messages.withLock { $0 }
    }

    private var decoded: [[String: Any]] {
        texts.compactMap { text in
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                return nil
            }
            return object as? [String: Any]
        }
    }

    /// Index of the first JSON-RPC reply carrying this id, optionally with this
    /// `stopReason` in its result.
    func responseIndex(id: Int, stopReason: String? = nil) -> Int? {
        decoded.firstIndex { message in
            guard let rawID = message["id"] as? NSNumber,
                  rawID.intValue == id,
                  message["result"] != nil || message["error"] != nil else {
                return false
            }
            guard let stopReason else {
                return true
            }
            let result = message["result"] as? [String: Any]
            return (result?["stopReason"] as? String) == stopReason
        }
    }

    private struct SessionUpdate {
        let sessionID: String
        let updateText: String
    }

    private var sessionUpdates: [SessionUpdate] {
        decoded.compactMap { message in
            guard message["method"] as? String == "session/update",
                  let params = message["params"] as? [String: Any],
                  let sessionID = params["sessionId"] as? String else {
                return nil
            }
            // The update subtree is re-serialized so a needle matches at any
            // nesting depth without depending on JSON escaping.
            let updateText = (try? JSONSerialization.data(withJSONObject: params["update"] ?? [:]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return SessionUpdate(sessionID: sessionID, updateText: updateText)
        }
    }

    /// Index of the first `session/update` notification for this session whose
    /// update payload contains `needle`, among *all* wire messages.
    func sessionUpdateIndex(sessionID: String, containing needle: String) -> Int? {
        var updateIndex = 0
        var wireIndex = 0
        for message in decoded {
            guard message["method"] as? String == "session/update",
                  let params = message["params"] as? [String: Any],
                  let updateSessionID = params["sessionId"] as? String else {
                continue
            }
            let updateText = (try? JSONSerialization.data(withJSONObject: params["update"] ?? [:]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if updateSessionID == sessionID {
                if updateText.contains(needle) {
                    return wireIndex
                }
                updateIndex += 1
            }
            wireIndex += 1
        }
        return nil
    }

    /// `session/update` notifications for this session at or after wire index
    /// `index`, i.e. everything the closed session emitted after that slot.
    func sessionUpdateCount(sessionID: String, from index: Int) -> Int {
        guard index < decoded.count else {
            return 0
        }
        return decoded[index...].filter { message in
            message["method"] as? String == "session/update"
                && (message["params"] as? [String: Any])?["sessionId"] as? String == sessionID
        }.count
    }
}

/// Gate that reports arrival, so a test can pin the prompt inside generation
/// and only then race the close against it.
private final class CloseQuiescenceGate: Sendable {
    private struct State {
        var isOpen = false
        var arrivals = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

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
struct ACPCloseQuiescenceTests {
    private static func makeConfiguration(appMode: Bool) throws -> AgentConfiguration {
        try AgentConfiguration(
            hostedModelID: "test-model",
            availableModels: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            runMode: .acp,
            workingDirectory: FileManager.default.temporaryDirectory,
            appMode: appMode
        )
    }

    private static func makeBridge(
        transport: CloseQuiescenceTransport,
        backend: CloseQuiescenceBackend,
        appMode: Bool = true
    ) throws -> ZenCODEACPBridge {
        ZenCODEACPBridge(
            configuration: try makeConfiguration(appMode: appMode),
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

    /// Yields until the predicate holds. Bounded, so a regression surfaces as a
    /// failed expectation instead of a hung test.
    private static func waitUntil(_ predicate: @Sendable () async -> Bool) async {
        for _ in 0 ..< 5000 {
            if await predicate() {
                return
            }
            await Task.yield()
        }
    }

    // MARK: - Ordering on the wire

    @Test
    func cancelledPromptRepliesAndFlushesItsUpdatesBeforeTheCloseReply() async throws {
        // The prompt is pinned inside generation, its turn content sitting in
        // the ACP prompt update buffer (app mode), when `session/close` lands.
        // The close must drain the cancelled prompt before answering: its
        // `cancelled` result and the buffered update flush belong on the wire
        // strictly before the close reply, and nothing about the closed session
        // may follow that reply.
        let transport = CloseQuiescenceTransport()
        let gate = CloseQuiescenceGate()
        let backend = CloseQuiescenceBackend(
            promptGate: gate,
            bufferedChunk: "buffered-before-close"
        )
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(1), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())

        let promptTask = Task {
            try await bridge.prompt(
                id: .number(2),
                params: ["sessionId": sessionID, "prompt": "long running"]
            )
        }
        await gate.waitUntilReached()

        let closeTask = Task {
            try await bridge.close(id: .number(3), params: ["sessionId": sessionID])
        }
        // The close drops the bridge session synchronously, but the wrapper
        // task cancel happens after the close's first suspension. Waiting for
        // the *runner* session to disappear pins the moment the cancellation
        // was already delivered, so opening the gate can no longer race it.
        await Self.waitUntil {
            guard await bridge.testHasSessionEntry(sessionID: sessionID) == false else {
                return false
            }
            return await bridge.testRunnerHasSessionEntry(sessionID: sessionID) == false
        }

        gate.open()
        try await closeTask.value
        _ = try? await promptTask.value

        let promptReplyIndex = try #require(
            transport.responseIndex(id: 2, stopReason: "cancelled")
        )
        let closeReplyIndex = try #require(transport.responseIndex(id: 3))
        #expect(promptReplyIndex < closeReplyIndex)

        let bufferedUpdateIndex = try #require(
            transport.sessionUpdateIndex(sessionID: sessionID, containing: "buffered-before-close")
        )
        #expect(bufferedUpdateIndex < closeReplyIndex)
        #expect(transport.sessionUpdateCount(sessionID: sessionID, from: closeReplyIndex) == 0)

        #expect(await bridge.testHasSessionEntry(sessionID: sessionID) == false)
        #expect(await bridge.testRunnerHasSessionEntry(sessionID: sessionID) == false)
    }

    // MARK: - No deadlock

    @Test
    func closeWithoutAnInFlightPromptAnswersImmediately() async throws {
        // Negative control for the drain: with no prompt in flight the close
        // must not gain an unconditional wait, or it would hang here.
        let transport = CloseQuiescenceTransport()
        let gate = CloseQuiescenceGate()
        let backend = CloseQuiescenceBackend(promptGate: gate, bufferedChunk: "unused")
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(1), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())

        try await bridge.close(id: .number(3), params: ["sessionId": sessionID])

        #expect(transport.responseIndex(id: 3) != nil)
        #expect(await bridge.testHasSessionEntry(sessionID: sessionID) == false)
    }

    @Test
    func aSessionRecreatedMidDrainDoesNotHoldTheCloseHostage() async throws {
        // The drain captured the handler set it must wait for. A racing
        // `session/load` that re-creates an entry with the same id — and a
        // prompt that starts under it — belongs to a newer incarnation, so the
        // close must still answer once only *its* handlers unwound.
        let transport = CloseQuiescenceTransport()
        let gate = CloseQuiescenceGate()
        let backend = CloseQuiescenceBackend(promptGate: gate, bufferedChunk: "unused")
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(1), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())

        let promptTask = Task {
            try await bridge.prompt(
                id: .number(2),
                params: ["sessionId": sessionID, "prompt": "long running"]
            )
        }
        await gate.waitUntilReached()

        let closeTask = Task {
            try await bridge.close(id: .number(3), params: ["sessionId": sessionID])
        }
        await Self.waitUntil {
            guard await bridge.testHasSessionEntry(sessionID: sessionID) == false else {
                return false
            }
            return await bridge.testRunnerHasSessionEntry(sessionID: sessionID) == false
        }

        // Re-create the same session id underneath the draining close and pin
        // a fresh prompt inside it; the close must not wait for this turn.
        await bridge.installTestSession(
            AgentCoreSessionConfiguration(
                sessionID: sessionID,
                modelID: "test-model",
                workingDirectory: FileManager.default.temporaryDirectory,
                systemPrompt: nil,
                cacheKey: nil,
                history: [],
                allowedToolNames: []
            )
        )
        let recreatedPromptTask = Task {
            try await bridge.prompt(
                id: .number(4),
                params: ["sessionId": sessionID, "prompt": "new incarnation"]
            )
        }
        await gate.waitUntilReached()

        gate.open()
        try await closeTask.value
        _ = try? await promptTask.value

        // The close answered without waiting for the recreated prompt, whose
        // reply may legitimately land after it.
        _ = try #require(transport.responseIndex(id: 3))
        #expect(transport.responseIndex(id: 2, stopReason: "cancelled") != nil)
        await Self.waitUntil { transport.responseIndex(id: 4) != nil }
        #expect(transport.responseIndex(id: 4) != nil)
        _ = try? await recreatedPromptTask.value
        #expect(transport.responseIndex(id: 2, stopReason: "cancelled") != nil)
        #expect(transport.responseIndex(id: 4) != nil)
        _ = try? await recreatedPromptTask.value
    }

    @Test
    func cancelStillAnswersWhileTheCancelledPromptUnwinds() async throws {
        // `session/cancel` keeps its own contract: it answers while the
        // cancelled prompt is still pinned in generation, the prompt then
        // unwinds with `cancelled`, and the session stays usable afterwards.
        let transport = CloseQuiescenceTransport()
        let gate = CloseQuiescenceGate()
        let backend = CloseQuiescenceBackend(
            promptGate: gate,
            bufferedChunk: "buffered-before-cancel"
        )
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(1), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())

        let promptTask = Task {
            try await bridge.prompt(
                id: .number(2),
                params: ["sessionId": sessionID, "prompt": "long running"]
            )
        }
        await gate.waitUntilReached()

        try await bridge.cancel(id: .number(4), params: ["sessionId": sessionID])
        #expect(transport.responseIndex(id: 4) != nil)

        gate.open()
        _ = try? await promptTask.value
        #expect(transport.responseIndex(id: 2, stopReason: "cancelled") != nil)

        // The session survives a cancel and immediately accepts a new turn.
        try await bridge.prompt(
            id: .number(5),
            params: ["sessionId": sessionID, "prompt": "after cancel"]
        )
        #expect(transport.responseIndex(id: 5, stopReason: "end_turn") != nil)
    }

    @Test
    func shutdownLandingInsideTheCloseDrainWritesNoLateReplyAndDeadlocksNothing() async throws {
        // The close is draining the cancelled prompt when `shutdown()` fences
        // the transport. Both handlers must still finish: the close is fenced
        // into silence, the prompt's late writes are dropped, and neither
        // waits forever on the other.
        let transport = CloseQuiescenceTransport()
        let gate = CloseQuiescenceGate()
        let backend = CloseQuiescenceBackend(
            promptGate: gate,
            bufferedChunk: "buffered-before-shutdown"
        )
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(1), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())

        let promptTask = Task {
            try await bridge.prompt(
                id: .number(2),
                params: ["sessionId": sessionID, "prompt": "long running"]
            )
        }
        await gate.waitUntilReached()

        let closeTask = Task {
            try await bridge.close(id: .number(3), params: ["sessionId": sessionID])
        }
        // Same pin as the ordering test: by the time the runner dropped the
        // session, the close already cancelled the prompt wrapper task and is
        // now (with the drain in place) waiting for the handler to unwind.
        await Self.waitUntil {
            guard await bridge.testHasSessionEntry(sessionID: sessionID) == false else {
                return false
            }
            return await bridge.testRunnerHasSessionEntry(sessionID: sessionID) == false
        }

        await bridge.shutdown()
        let writtenAtShutdown = transport.count

        gate.open()
        _ = try? await closeTask.value
        _ = try? await promptTask.value
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        #expect(transport.responseIndex(id: 3) == nil)
        #expect(transport.responseIndex(id: 2) == nil)
        #expect(transport.count == writtenAtShutdown)
    }
}

// MARK: - Backend double

/// Runtime backend whose `sendPrompt` can be pinned inside generation by a
/// gate. The turn emits its content *before* the gate — so in app mode it sits
/// in the ACP prompt update buffer until the final flush — and ends as
/// cancelled once the gate opens, mirroring a runtime that honours the
/// cancellation `session/close` and `session/cancel` mark the wrapper task with.
private actor CloseQuiescenceBackend: AgentRuntimeBackend {
    private let promptGate: CloseQuiescenceGate
    private let bufferedChunk: String
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]

    init(promptGate: CloseQuiescenceGate, bufferedChunk: String) {
        self.promptGate = promptGate
        self.bufferedChunk = bufferedChunk
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
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        await onEvent(.content(bufferedChunk))
        await promptGate.arriveAndWait()
        try Task.checkCancellation()
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

// MARK: - Test hooks

extension ZenCODEACPBridge {
    func testHasSessionEntry(sessionID: String) -> Bool {
        sessions[sessionID] != nil
    }

    func testRunnerHasSessionEntry(sessionID: String) async -> Bool {
        await sessionRunner.snapshotSession(id: sessionID) != nil
    }
}
