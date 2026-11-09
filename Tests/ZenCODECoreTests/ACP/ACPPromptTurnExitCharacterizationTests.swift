//
//  ACPPromptTurnExitCharacterizationTests.swift
//  ZenCODE
//
//  Characterization of the exits of an ACP `session/prompt` turn, written
//  before the turn was split into phases: for every exit, the exact messages
//  of the prompt on the wire (its session updates, then its reply), whether
//  the reservation is still held while the reply is written (a reply and
//  then the release, or the release and then the error the request answers),
//  and that the session accepts a new prompt afterwards. A cancel concurrent
//  with the registration of the turn's task always ends the prompt
//  `cancelled` and leaves the session free.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

/// Records every JSON-RPC message the bridge writes, and can hold the writer
/// on the first message that matches a predicate until the test releases it.
private final class PromptExitTransport: Sendable {
    private struct Hold: Sendable {
        let matches: @Sendable (JSONValue) -> Bool
        let reached: ACPLifecycleGate
        let release: DispatchSemaphore
    }

    private struct State {
        var messages: [JSONValue] = []
        var hold: Hold?
    }

    private let state = Mutex(State())

    var sink: ACPWriter.Sink {
        { [self] data in
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return
            }
            let hold = state.withLock { state -> Hold? in
                state.messages.append(message)
                guard let hold = state.hold, hold.matches(message) else {
                    return nil
                }
                state.hold = nil
                return hold
            }
            if let hold {
                hold.reached.open()
                hold.release.wait()
            }
        }
    }

    var count: Int {
        state.withLock { $0.messages.count }
    }

    /// Holds the writer, inside the write, on the next message that matches.
    func holdWriter(
        when matches: @escaping @Sendable (JSONValue) -> Bool
    ) -> (reached: ACPLifecycleGate, release: DispatchSemaphore) {
        let hold = Hold(matches: matches, reached: ACPLifecycleGate(), release: DispatchSemaphore(value: 0))
        state.withLock { $0.hold = hold }
        return (hold.reached, hold.release)
    }

    /// The replies to request `id`.
    func replies(to id: Int) -> [JSONValue] {
        state.withLock { $0.messages }.filter { Self.isReply($0, to: id) }
    }

    /// What request `id` put on the wire from message `start` on: the
    /// session updates of `sessionID` and the request's own reply, in wire
    /// order. Replies to other requests (a racing `session/cancel`) are left
    /// out.
    func trace(of id: Int, sessionID: String, from start: Int = 0) -> [String] {
        let messages = state.withLock { $0.messages }
        return messages.dropFirst(start).compactMap { message in
            if Self.isReply(message, to: id) {
                return Self.describeReply(message)
            }
            guard let object = message.objectValue,
                  object["method"]?.stringValue == "session/update",
                  let params = object["params"]?.objectValue,
                  params["sessionId"]?.stringValue == sessionID,
                  let update = params["update"]?.objectValue else {
                return nil
            }
            let kind = update["sessionUpdate"]?.stringValue ?? "?"
            if kind == "user_message_chunk" || kind == "agent_message_chunk",
               let text = update["content"]?.objectValue?["text"]?.stringValue {
                return "\(kind): \(text)"
            }
            return kind
        }
    }

    static func isReply(_ message: JSONValue, to id: Int) -> Bool {
        guard let object = message.objectValue, object["method"] == nil else {
            return false
        }
        return object["id"] == .number(Double(id))
    }

    static func describeReply(_ message: JSONValue) -> String {
        let object = message.objectValue ?? [:]
        if let error = object["error"]?.objectValue {
            let code = Int(error["code"]?.numberValue ?? 0)
            return "error \(code): \(error["message"]?.stringValue ?? "")"
        }
        if let stopReason = object["result"]?.objectValue?["stopReason"]?.stringValue {
            return "stopReason: \(stopReason)"
        }
        return "result"
    }
}

private struct PromptExitBackendFailure: LocalizedError {
    var errorDescription: String? { "the backend failed the turn" }
}

/// A backend that answers `done`, pins the prompts that contain `pinned`
/// until they are cancelled, and fails the prompts that contain `explode`.
private actor PromptExitBackend: AgentRuntimeBackend {
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private(set) var prompts: [String] = []
    let pinStarted = ACPLifecycleGate()
    private let pinFinish = ACPLifecycleGate()

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
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        if prompt.contains("explode") {
            throw PromptExitBackendFailure()
        }
        if prompt.contains("pinned") {
            pinStarted.open()
            try await pinFinish.waitCancelling()
            try Task.checkCancellation()
        }
        return DirectAgentResponse(text: "done", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}

extension ZenCODEACPBridge {
    /// The prompt the host holds reserved on the live incarnation of
    /// `sessionID`.
    fileprivate func promptExitReservedPromptID(sessionID: String) async -> UUID? {
        guard let session = sessions[sessionID] else { return nil }
        return await host.liveIncarnation(in: session.slotID, epoch: session.epoch)?.activePromptID
    }

    /// Whether the bridge still has a turn task registered for `sessionID`.
    fileprivate func promptExitHasActivePromptTask(sessionID: String) -> Bool {
        sessions[sessionID]?.activePromptTask != nil
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ACPPromptTurnExitCharacterizationTests {
    private struct Fixture {
        let bridge: ZenCODEACPBridge
        let transport: PromptExitTransport
        let backend: PromptExitBackend
        let sessionID: String
    }

    /// A bridge with one session that already ran a first prompt, so the
    /// turns below no longer present the session's commands and its initial
    /// configuration.
    private static func makeFixture() async throws -> Fixture {
        let transport = PromptExitTransport()
        let backend = PromptExitBackend()
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableModels: [
                AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")
            ],
            runMode: .acp,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let bridge = ZenCODEACPBridge(
            configuration: configuration,
            writer: ACPWriter(sink: transport.sink),
            backendFactory: { _, _ in backend }
        )
        let sessionID = "acp-prompt-exit-\(UUID().uuidString)"
        await bridge.installTestSession(AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        ))
        let fixture = Fixture(bridge: bridge, transport: transport, backend: backend, sessionID: sessionID)
        await send(fixture, id: 1, text: "warm up")
        #expect(transport.trace(of: 1, sessionID: sessionID).last == "stopReason: end_turn")
        return fixture
    }

    private static func send(_ fixture: Fixture, id: Int, text: String) async {
        await fixture.bridge.handleMessage([
            "jsonrpc": "2.0", "id": id, "method": "session/prompt",
            "params": ["sessionId": fixture.sessionID, "prompt": text] as [String: Any],
        ])
    }

    /// The session is free again: nothing is reserved or registered, and a
    /// new prompt runs to `end_turn`.
    private static func expectSessionAcceptsANewPrompt(_ fixture: Fixture, id: Int) async {
        #expect(await fixture.bridge.promptExitReservedPromptID(sessionID: fixture.sessionID) == nil)
        #expect(await !fixture.bridge.promptExitHasActivePromptTask(sessionID: fixture.sessionID))
        await send(fixture, id: id, text: "after the exit")
        #expect(fixture.transport.trace(of: id, sessionID: fixture.sessionID).last == "stopReason: end_turn")
    }

    // MARK: - Exits before routing

    @Test
    func aPromptWithoutTextOrAttachmentsAnswersInvalidParamsAfterReleasingTheReservation() async throws {
        let fixture = try await Self.makeFixture()
        let start = fixture.transport.count
        let hold = fixture.transport.holdWriter { PromptExitTransport.isReply($0, to: 2) }
        let prompt = Task { await Self.send(fixture, id: 2, text: "   ") }
        await hold.reached.wait()
        // The reservation is already released when the error is written.
        #expect(await fixture.bridge.promptExitReservedPromptID(sessionID: fixture.sessionID) == nil)
        hold.release.signal()
        await prompt.value

        #expect(fixture.transport.trace(of: 2, sessionID: fixture.sessionID, from: start) == [
            "error -32602: session/prompt requires prompt text or attachments."
        ])
        #expect(await fixture.backend.prompts == ["warm up"])
        await Self.expectSessionAcceptsANewPrompt(fixture, id: 3)
        await fixture.bridge.shutdown()
    }

    // MARK: - Exits of the routing phase

    @Test
    func anImmediateCommandAnswersItsTextThenEndTurnWhileTheReservationIsStillHeld() async throws {
        let fixture = try await Self.makeFixture()
        let start = fixture.transport.count
        let hold = fixture.transport.holdWriter { PromptExitTransport.isReply($0, to: 2) }
        let prompt = Task { await Self.send(fixture, id: 2, text: "/review") }
        await hold.reached.wait()
        // The stop reason is written first, the reservation released after.
        #expect(await fixture.bridge.promptExitReservedPromptID(sessionID: fixture.sessionID) != nil)
        hold.release.signal()
        await prompt.value

        #expect(fixture.transport.trace(of: 2, sessionID: fixture.sessionID, from: start) == [
            "user_message_chunk: /review",
            "session_info_update",
            "agent_message_chunk: ZenCODE: /review requires the sub-agent tools in this ACP session.",
            "stopReason: end_turn",
        ])
        #expect(await fixture.backend.prompts == ["warm up"])
        await Self.expectSessionAcceptsANewPrompt(fixture, id: 3)
        await fixture.bridge.shutdown()
    }

    @Test
    func aCancelThatLandsBeforeTheRoutingEndsThePromptCancelledWithoutRunningTheModel() async throws {
        let fixture = try await Self.makeFixture()
        let start = fixture.transport.count
        let sessionID = fixture.sessionID
        // Hold the writer on the prompt's own echo: the prompt holds its
        // reservation and has not routed yet.
        let hold = fixture.transport.holdWriter { message in
            message.objectValue?["params"]?.objectValue?["update"]?.objectValue?["sessionUpdate"]
                == .string("user_message_chunk")
        }
        let prompt = Task { await Self.send(fixture, id: 2, text: "never routed") }
        await hold.reached.wait()
        #expect(await fixture.bridge.promptExitReservedPromptID(sessionID: sessionID) != nil)
        let cancel = Task {
            try await fixture.bridge.cancel(id: .number(50), params: ["sessionId": sessionID])
        }
        for _ in 0 ..< 2_000 {
            if await fixture.bridge.promptExitReservedPromptID(sessionID: sessionID) == nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await fixture.bridge.promptExitReservedPromptID(sessionID: sessionID) == nil)
        hold.release.signal()
        await prompt.value
        try await cancel.value

        #expect(fixture.transport.trace(of: 2, sessionID: sessionID, from: start) == [
            "user_message_chunk: never routed",
            "session_info_update",
            "stopReason: cancelled",
        ])
        #expect(fixture.transport.replies(to: 50).count == 1)
        #expect(await fixture.backend.prompts == ["warm up"])
        await Self.expectSessionAcceptsANewPrompt(fixture, id: 3)
        await fixture.bridge.shutdown()
    }

    // MARK: - Exits of the turn

    @Test
    func aCompletedTurnSettlesThenAnswersItsStopReasonWhileTheReservationIsStillHeld() async throws {
        let fixture = try await Self.makeFixture()
        let start = fixture.transport.count
        let hold = fixture.transport.holdWriter { PromptExitTransport.isReply($0, to: 2) }
        let prompt = Task { await Self.send(fixture, id: 2, text: "hello") }
        await hold.reached.wait()
        #expect(await fixture.bridge.promptExitReservedPromptID(sessionID: fixture.sessionID) != nil)
        hold.release.signal()
        await prompt.value

        #expect(fixture.transport.trace(of: 2, sessionID: fixture.sessionID, from: start) == [
            "user_message_chunk: hello",
            "session_info_update",
            "stopReason: end_turn",
        ])
        #expect(await fixture.backend.prompts == ["warm up", "hello"])
        await Self.expectSessionAcceptsANewPrompt(fixture, id: 3)
        await fixture.bridge.shutdown()
    }

    @Test
    func aTurnCancelledDuringGenerationSettlesThenAnswersCancelled() async throws {
        let fixture = try await Self.makeFixture()
        let start = fixture.transport.count
        let prompt = Task { await Self.send(fixture, id: 2, text: "pinned turn") }
        await fixture.backend.pinStarted.wait()
        try await fixture.bridge.cancel(id: .number(50), params: ["sessionId": fixture.sessionID])
        await prompt.value

        #expect(fixture.transport.trace(of: 2, sessionID: fixture.sessionID, from: start) == [
            "user_message_chunk: pinned turn",
            "session_info_update",
            "stopReason: cancelled",
        ])
        #expect(fixture.transport.replies(to: 50).count == 1)
        await Self.expectSessionAcceptsANewPrompt(fixture, id: 3)
        await fixture.bridge.shutdown()
    }

    @Test
    func aFailedTurnReleasesTheReservationBeforeTheErrorReply() async throws {
        let fixture = try await Self.makeFixture()
        let start = fixture.transport.count
        let hold = fixture.transport.holdWriter { PromptExitTransport.isReply($0, to: 2) }
        let prompt = Task { await Self.send(fixture, id: 2, text: "explode") }
        await hold.reached.wait()
        // The reservation is released first, then the error is the reply.
        #expect(await fixture.bridge.promptExitReservedPromptID(sessionID: fixture.sessionID) == nil)
        hold.release.signal()
        await prompt.value

        #expect(fixture.transport.trace(of: 2, sessionID: fixture.sessionID, from: start) == [
            "user_message_chunk: explode",
            "session_info_update",
            "error -32603: the backend failed the turn",
        ])
        await Self.expectSessionAcceptsANewPrompt(fixture, id: 3)
        await fixture.bridge.shutdown()
    }

    // MARK: - Cancel concurrent with the registration of the turn's task

    /// The cancel is dispatched after a growing busy wait (20 µs more at each
    /// attempt, up to about 1 ms), so across the attempts it can land before
    /// the reservation, during the routing, between the last check of the
    /// reservation and the registration of the turn's task, or during the
    /// generation. Which of these exits an attempt takes depends on the
    /// scheduler, and the test does not observe it. Wherever it lands the
    /// prompt answers `cancelled` exactly once and leaves nothing reserved or
    /// registered.
    @Test
    func aCancelConcurrentWithTheTurnTaskRegistrationAlwaysEndsThePromptCancelled() async throws {
        let fixture = try await Self.makeFixture()
        let sessionID = fixture.sessionID
        for attempt in 0 ..< 48 {
            let id = 100 + attempt
            let start = fixture.transport.count
            let prompt = Task { await Self.send(fixture, id: id, text: "pinned turn \(attempt)") }
            // A busy wait, not a sleep: the prompt advances on other threads
            // meanwhile, and a sleep is too coarse for the window.
            let deadline = ContinuousClock.now.advanced(by: .microseconds(attempt * 20))
            while ContinuousClock.now < deadline {}
            var cancelID = 100_000 + attempt * 1_000
            try await fixture.bridge.cancel(id: .number(Double(cancelID)), params: ["sessionId": sessionID])
            // A cancel that landed before the reservation cancelled nothing:
            // cancel again until the prompt answers.
            while fixture.transport.replies(to: id).isEmpty {
                try await Task.sleep(for: .milliseconds(2))
                cancelID += 1
                try await fixture.bridge.cancel(id: .number(Double(cancelID)), params: ["sessionId": sessionID])
            }
            await prompt.value

            let trace = fixture.transport.trace(of: id, sessionID: sessionID, from: start)
            #expect(fixture.transport.replies(to: id).count == 1)
            #expect(trace.last == "stopReason: cancelled")
            #expect(trace.first == "user_message_chunk: pinned turn \(attempt)")
            #expect(await fixture.bridge.promptExitReservedPromptID(sessionID: sessionID) == nil)
            #expect(await !fixture.bridge.promptExitHasActivePromptTask(sessionID: sessionID))
        }
        await Self.expectSessionAcceptsANewPrompt(fixture, id: 3)
        await fixture.bridge.shutdown()
    }
}
