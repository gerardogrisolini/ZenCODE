//
//  ACPDelegatedToolPresentationTests.swift
//  ZenCODE
//
//  The delegated agents' tool calls on the ACP wire. As `codex-acp` does
//  without a sub-agent contract, they are not presented in the session that
//  owns the agent: the client sees the agent as one tool call. A call that
//  asks the operator's consent is the exception: its permission stays on the
//  root session and refers to a call the client knows, announced by a
//  `tool_call` right before the `session/request_permission`, and the call
//  always reaches a final state: `failed` when the operator refuses or
//  dismisses the request, `in_progress` and then the ordinary completion when
//  the operator allows it, inside a prompt, outside one, and after its
//  cancellation. No title names the agent; the permission's content does.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore
import ZenCODERuntime

/// A backend whose turns run a script with the sub-agent tool event handler
/// the runner handed it, then stream one content chunk and answer.
private actor DelegatedToolBackend: AgentRuntimeBackend {
    typealias Script = @Sendable (_ sessionID: String, _ handler: DirectSubAgentToolEventHandler?) async -> Void

    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var handler: DirectSubAgentToolEventHandler?
    private var script: Script?

    func setScript(_ script: Script?) {
        self.script = script
    }

    /// Emits `event` through the handler, as a sub-agent outside a prompt does.
    func emit(_ event: DirectSubAgentToolEvent) async {
        await handler?(event)
    }

    func updateSubAgentToolEventHandler(_ handler: DirectSubAgentToolEventHandler?) {
        self.handler = handler
    }

    func createSession(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
                       cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {
        sessions[id] = .init(sessionID: id, workingDirectoryPath: cwd, systemPrompt: systemPrompt,
                            cacheKey: cacheKey, history: history, allowedToolNames: allowedToolNames,
                            thinkingSelection: thinkingSelection, preserveThinking: preserveThinking)
    }
    func createSessionIfNeeded(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
                               cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {
        guard sessions[id] == nil else { return }
        createSession(id: id, cwd: cwd, systemPrompt: systemPrompt, history: history, cacheKey: cacheKey,
                      allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection, preserveThinking: preserveThinking)
    }
    func updateSessionOptions(id: String, systemPrompt: String?, allowedToolNames: Set<String>?,
                              thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func closeSession(id: String) { sessions.removeValue(forKey: id) }
    func shutdown() async { sessions.removeAll() }
    func preloadModel(onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String { "test-model" }
    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }
    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? { sessions[id] }

    func sendPrompt(sessionID: String, prompt: String, attachments: [AgentRuntimeAttachment],
                    onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> DirectAgentResponse {
        await script?(sessionID, handler)
        await onEvent(.content("root text"))
        return .init(text: "root text", stopReason: "end_turn", modelID: "test-model")
    }
}

/// The messages the bridge wrote, decoded, in order.
private final class WireLog: Sendable {
    let messages = Mutex<[JSONValue]>([])
}

/// A value a backend script sets, for the test to read afterwards.
private final class ScriptValue<Value: Sendable>: Sendable {
    let value: Mutex<Value>

    init(_ value: Value) {
        self.value = Mutex(value)
    }

    func set(_ newValue: Value) {
        value.withLock { $0 = newValue }
    }

    func get() -> Value {
        value.withLock { $0 }
    }
}

private extension ZenCODEACPBridge {
    /// The working directory of the live session `sessionID`.
    func delegatedToolTestCWD(sessionID: String) -> String? {
        sessions[sessionID]?.cwd
    }
}

/// An ACP bridge over a ``DelegatedToolBackend``, with one live session.
private struct DelegatedToolHarness {
    let bridge: ZenCODEACPBridge
    let backend: DelegatedToolBackend
    let output: WireLog
    let sessionID: String
    let cwd: String
}

@Suite(.timeLimit(.minutes(1)))
struct ACPDelegatedToolPresentationTests {
    private static func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-delegated-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    /// Runs `body` in a fresh workspace with a throwaway support directory, so
    /// consent never reads or writes the real application state.
    private static func withHarness(
        _ body: (DelegatedToolHarness) async throws -> Void
    ) async throws {
        let workspace = try makeWorkspace()
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-delegated-tools-support-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: support)
        }
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let output = WireLog()
            let backend = DelegatedToolBackend()
            let configuration = try AgentConfiguration(
                hostedModelID: "test-model",
                availableModels: [.init(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")],
                runMode: .acp, workingDirectory: workspace, appMode: false
            )
            let bridge = ZenCODEACPBridge(configuration: configuration, writer: ACPWriter { data in
                if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    output.messages.withLock { $0.append(value) }
                }
            }, backendFactory: { _, _ in backend })
            try await bridge.newSession(id: .number(1), params: ["cwd": workspace.path, "allowedTools": [String]()])
            let sessionID = try #require(await bridge.testAnySessionID())
            let cwd = try #require(await bridge.delegatedToolTestCWD(sessionID: sessionID))
            try await body(DelegatedToolHarness(
                bridge: bridge, backend: backend, output: output, sessionID: sessionID, cwd: cwd
            ))
            await bridge.shutdown()
        }
    }

    /// The `session/update` payloads written so far, in order.
    private static func updates(_ output: WireLog) -> [JSONValue] {
        output.messages.withLock { values in
            values.compactMap { message in
                guard message.objectValue?["method"] == .string("session/update") else { return nil }
                return message.objectValue?["params"]?.objectValue?["update"]
            }
        }
    }

    /// The updates of delegated tool calls (`acp:tool:` ids), in order.
    private static func delegatedUpdates(_ output: WireLog) -> [JSONValue] {
        updates(output).filter {
            $0.objectValue?["toolCallId"]?.acpStringValue?.hasPrefix("acp:tool:") == true
        }
    }

    /// The delegated wire in order: each delegated update as its kind (and its
    /// status, for a `tool_call_update`), each permission request as its
    /// method.
    private static func delegatedWire(_ output: WireLog) -> [String] {
        output.messages.withLock { values in
            values.compactMap { message in
                let object = message.objectValue
                if object?["method"] == .string("session/request_permission") {
                    return "session/request_permission"
                }
                guard object?["method"] == .string("session/update"),
                      let update = object?["params"]?.objectValue?["update"]?.objectValue,
                      update["toolCallId"]?.acpStringValue?.hasPrefix("acp:tool:") == true,
                      let kind = update["sessionUpdate"]?.acpStringValue else { return nil }
                guard kind == "tool_call_update" else { return kind }
                return "\(kind):\(update["status"]?.acpStringValue ?? "-")"
            }
        }
    }

    /// The first `session/request_permission` written, once it is.
    private static func permissionRequest(_ output: WireLog) async -> JSONValue? {
        for _ in 0..<4_000 {
            let request = output.messages.withLock { values in
                values.first { $0.objectValue?["method"] == .string("session/request_permission") }
            }
            if let request { return request }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    /// The client's answer to `request`: the option `optionID`, or the
    /// cancellation ACP defines when `optionID` is `nil`.
    private static func answer(_ request: JSONValue, optionID: String?) throws -> JSONValue {
        let id = try #require(request.objectValue?["id"])
        let outcome: JSONValue = if let optionID {
            .object(["outcome": .string("selected"), "optionId": .string(optionID)])
        } else {
            .object(["outcome": .string("cancelled")])
        }
        return .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": .object(["outcome": outcome]),
        ])
    }

    /// A delegated shell request of the agent `worker-1`, named `Worker` by
    /// the runner, for the call `call-1` of the session `sessionID`.
    private static func shellRequest(sessionID: String, cwd: String) -> AgentToolAuthorizationRequest {
        AgentToolAuthorizationRequest(
            sessionID: "worker-private-session",
            toolCallID: "call-1",
            toolName: "local.exec",
            title: "Run swift",
            kind: "execute",
            command: "swift build --product delegated-\(UUID().uuidString)",
            workingDirectory: cwd,
            delegatedIdentity: .init(agentID: "worker-1", rootSessionID: sessionID)
        ).namingDelegatedAgent("Worker")
    }

    private static let execCall = DirectAgentToolCall(
        id: "call-1", name: "local.exec",
        argumentsObject: ["command": "swift build"],
        argumentsJSON: #"{"command":"swift build"}"#
    )

    private static func started(_ sessionID: String) -> DirectSubAgentToolEvent {
        DirectSubAgentToolEvent(
            agentID: "worker-1", agentName: "Worker", toolCall: execCall,
            lifecycle: .started, rootSessionID: sessionID
        )
    }

    private static func completed(_ sessionID: String, status: DirectAgentToolResult.Status = .completed) -> DirectSubAgentToolEvent {
        DirectSubAgentToolEvent(
            agentID: "worker-1", agentName: "Worker", toolCall: execCall,
            lifecycle: .completed(DirectAgentToolResult(
                output: "Build complete!", summary: "Build complete!", status: status,
                elapsed: .milliseconds(1_250)
            )),
            rootSessionID: sessionID
        )
    }

    /// No delegated update carries a title naming the agent.
    private static func expectNoAgentInTitles(_ output: WireLog) {
        let titles = output.messages.withLock { values in
            values.compactMap { message -> String? in
                let params = message.objectValue?["params"]?.objectValue
                return params?["update"]?.objectValue?["title"]?.acpStringValue
                    ?? params?["toolCall"]?.objectValue?["title"]?.acpStringValue
            }
        }
        for title in titles {
            #expect(!title.contains("Worker"))
            #expect(!title.contains("[agent"))
            #expect(!title.contains(" — "))
        }
    }

    // MARK: - Without consent

    @Test func delegatedToolCallsWithoutConsentWriteNothingInTheSession() async throws {
        try await Self.withHarness { harness in
            let write = DirectAgentToolCall(
                id: "call-1", name: "local.write",
                argumentsObject: ["path": "Delegated.swift", "content": "let value = 2\n"],
                argumentsJSON: #"{"path":"Delegated.swift","content":"let value = 2\n"}"#
            )
            let started = DirectSubAgentToolEvent(
                agentID: "worker-1", agentName: "Worker", toolCall: write,
                lifecycle: .started, rootSessionID: harness.sessionID
            )
            let completed = DirectSubAgentToolEvent(
                agentID: "worker-1", agentName: "Worker", toolCall: write,
                lifecycle: .completed(DirectAgentToolResult(
                    output: "Updated", summary: "Updated",
                    fileChanges: [OperationFileChange(path: "Delegated.swift", oldText: nil, newText: "let value = 2\n")],
                    elapsed: .milliseconds(1_250)
                )),
                rootSessionID: harness.sessionID
            )
            await harness.backend.setScript { _, handler in
                await handler?(started)
                await handler?(completed)
            }
            try await harness.bridge.prompt(id: .number(2), params: ["sessionId": harness.sessionID, "prompt": "first"])

            // Inside the prompt nothing of the agent's calls is presented, and
            // the prompt goes on as before.
            #expect(Self.delegatedUpdates(harness.output).isEmpty)
            #expect(Self.updates(harness.output).contains {
                $0.objectValue?["content"]?.objectValue?["text"] == .string("root text")
            })

            // Nor outside one.
            await harness.backend.setScript(nil)
            await harness.backend.emit(started)
            await harness.backend.emit(completed)
            #expect(Self.delegatedUpdates(harness.output).isEmpty)
        }
    }

    // MARK: - With consent

    /// Inside a prompt: the `tool_call` comes before the permission, the
    /// allowed call goes `in_progress`, and its completion closes it with the
    /// ordinary completing update. The `started` event writes nothing, and a
    /// repeated completion writes nothing either.
    @Test func anAllowedDelegatedPermissionAnnouncesItsCallAndTheCompletionClosesIt() async throws {
        try await Self.withHarness { harness in
            let request = Self.shellRequest(sessionID: harness.sessionID, cwd: harness.cwd)
            let approved = ScriptValue<Bool?>(nil)
            let bridge = harness.bridge
            let output = harness.output
            let sessionID = harness.sessionID
            await harness.backend.setScript { _, handler in
                await handler?(Self.started(sessionID))
                let authorization = Task { await bridge.permissionBroker.authorize(request) }
                guard let permission = await Self.permissionRequest(output),
                      let answer = try? Self.answer(permission, optionID: "allow_once") else {
                    Issue.record("No permission request was written.")
                    authorization.cancel()
                    return
                }
                await bridge.permissionBroker.handleResponse(answer)
                approved.set(await authorization.value)
                await handler?(Self.completed(sessionID))
                await handler?(Self.completed(sessionID))
            }
            try await bridge.prompt(id: .number(2), params: ["sessionId": sessionID, "prompt": "build"])

            #expect(approved.get() == true)
            #expect(Self.delegatedWire(output) == [
                "tool_call", "session/request_permission",
                "tool_call_update:in_progress", "tool_call_update:completed",
            ])

            let delegated = Self.delegatedUpdates(output)
            let announcement = try #require(delegated.first?.objectValue)
            #expect(announcement["toolCallId"] == .string("acp:tool:worker-1:call-1"))
            #expect(announcement["title"] == .string(request.command))
            #expect(announcement["name"] == .string("local.exec"))
            #expect(announcement["kind"] == .string("execute"))
            #expect(announcement["status"] == .string("pending"))
            #expect(announcement["content"] == .array([]))
            #expect(announcement["rawInput"] == .object([
                "command": .string(request.command),
                "workingDirectory": .string(harness.cwd),
                "description": .string("Run shell command in \(harness.cwd)"),
            ]))
            #expect(announcement["_meta"] == nil)

            // The permission refers to the call announced, on the root session,
            // and names the agent in its content.
            let permission = try #require(await Self.permissionRequest(output)?.objectValue?["params"]?.objectValue)
            #expect(permission["sessionId"] == .string(sessionID))
            let toolCall = try #require(permission["toolCall"]?.objectValue)
            #expect(toolCall["toolCallId"] == announcement["toolCallId"])
            #expect(toolCall["title"] == announcement["title"])
            let text = toolCall["content"]?.arrayValue?.first?.objectValue?["content"]?.objectValue?["text"]?.acpStringValue
            #expect(text?.hasPrefix("Requested by Worker\n\n") == true)

            let completion = try #require(delegated.last?.objectValue)
            #expect(completion["toolCallId"] == .string("acp:tool:worker-1:call-1"))
            #expect(completion["title"] == nil)
            #expect(completion["content"]?.arrayValue?.isEmpty == false)
            Self.expectNoAgentInTitles(output)

            // The prompt's own content follows the delegated call.
            let all = Self.updates(output)
            let completionIndex = try #require(all.lastIndex {
                $0.objectValue?["toolCallId"] == .string("acp:tool:worker-1:call-1")
            })
            let rootTextIndex = try #require(all.firstIndex {
                $0.objectValue?["content"]?.objectValue?["text"] == .string("root text")
            })
            #expect(completionIndex < rootTextIndex)
        }
    }

    /// Outside a prompt (the agent keeps working after the prompt ended), the
    /// session's own presenter closes the allowed call; a failed tool closes
    /// it as `failed`.
    @Test func anAllowedDelegatedPermissionOutsideAPromptIsClosedByItsCompletion() async throws {
        try await Self.withHarness { harness in
            // A first prompt installs the routing of the delegated events.
            try await harness.bridge.prompt(id: .number(2), params: ["sessionId": harness.sessionID, "prompt": "start"])
            let request = Self.shellRequest(sessionID: harness.sessionID, cwd: harness.cwd)
            let broker = await harness.bridge.permissionBroker
            let authorization = Task { await broker.authorize(request) }
            let permission = try #require(await Self.permissionRequest(harness.output))
            #expect(Self.delegatedWire(harness.output) == ["tool_call", "session/request_permission"])
            await broker.handleResponse(try Self.answer(permission, optionID: "allow_once"))
            #expect(await authorization.value == true)
            #expect(Self.delegatedWire(harness.output).last == "tool_call_update:in_progress")

            await harness.backend.emit(Self.started(harness.sessionID))
            await harness.backend.emit(Self.completed(harness.sessionID, status: .failed))
            await harness.backend.emit(Self.completed(harness.sessionID))
            #expect(Self.delegatedWire(harness.output) == [
                "tool_call", "session/request_permission",
                "tool_call_update:in_progress", "tool_call_update:failed",
            ])
            Self.expectNoAgentInTitles(harness.output)
        }
    }

    /// A refusal, and a dismissal, end the announced call as `failed` right
    /// away; the completion of the refused tool writes nothing more.
    @Test(arguments: ["reject_once", nil] as [String?])
    func aRefusedOrDismissedDelegatedPermissionFailsItsCall(optionID: String?) async throws {
        try await Self.withHarness { harness in
            try await harness.bridge.prompt(id: .number(2), params: ["sessionId": harness.sessionID, "prompt": "start"])
            let request = Self.shellRequest(sessionID: harness.sessionID, cwd: harness.cwd)
            let broker = await harness.bridge.permissionBroker
            let authorization = Task { await broker.authorize(request) }
            let permission = try #require(await Self.permissionRequest(harness.output))
            await broker.handleResponse(try Self.answer(permission, optionID: optionID))
            #expect(await authorization.value == false)

            await harness.backend.emit(Self.completed(harness.sessionID, status: .failed))
            #expect(Self.delegatedWire(harness.output) == [
                "tool_call", "session/request_permission", "tool_call_update:failed",
            ])
            Self.expectNoAgentInTitles(harness.output)
        }
    }

    /// A prompt cancelled while the agent's permission waits does not take the
    /// call's final state with it: the call allowed after the cancel is still
    /// closed by its completion, although the cancelled prompt presents
    /// nothing any more.
    @Test func aDelegatedCallAllowedAfterThePromptWasCancelledIsStillClosed() async throws {
        try await Self.withHarness { harness in
            let request = Self.shellRequest(sessionID: harness.sessionID, cwd: harness.cwd)
            let approved = ScriptValue<Bool?>(nil)
            let cancelled = ScriptValue(false)
            let bridge = harness.bridge
            let output = harness.output
            let sessionID = harness.sessionID
            await harness.backend.setScript { sessionID, handler in
                let authorization = Task { await bridge.permissionBroker.authorize(request) }
                guard let permission = await Self.permissionRequest(output),
                      let answer = try? Self.answer(permission, optionID: "allow_once") else {
                    Issue.record("No permission request was written.")
                    authorization.cancel()
                    return
                }
                do {
                    try await bridge.cancel(id: nil, params: ["sessionId": sessionID])
                    cancelled.set(true)
                } catch {
                    Issue.record("session/cancel failed: \(error)")
                }
                await bridge.permissionBroker.handleResponse(answer)
                approved.set(await authorization.value)
                await handler?(Self.completed(sessionID))
            }
            try await bridge.prompt(id: .number(2), params: ["sessionId": sessionID, "prompt": "cancel me"])

            #expect(cancelled.get())
            #expect(approved.get() == true)
            #expect(Self.delegatedWire(output) == [
                "tool_call", "session/request_permission",
                "tool_call_update:in_progress", "tool_call_update:completed",
            ])
        }
    }

    /// The call belongs to the incarnation that announced it: once the session
    /// is closed, the answer to its permission writes nothing for it.
    @Test func aClosedSessionReceivesNoUpdateOfItsDelegatedCall() async throws {
        try await Self.withHarness { harness in
            let request = Self.shellRequest(sessionID: harness.sessionID, cwd: harness.cwd)
            let broker = await harness.bridge.permissionBroker
            let authorization = Task { await broker.authorize(request) }
            let permission = try #require(await Self.permissionRequest(harness.output))
            try await harness.bridge.close(id: .number(3), params: ["sessionId": harness.sessionID])
            await broker.handleResponse(try Self.answer(permission, optionID: "reject_once"))
            #expect(await authorization.value == false)
            #expect(Self.delegatedWire(harness.output) == ["tool_call", "session/request_permission"])
        }
    }

    // MARK: - Presenters

    /// The prompt's presenter hands the completions of delegated calls to the
    /// bridge, which closes only the calls a permission announced, and writes
    /// nothing itself, a start included.
    @Test
    func thePromptPresenterWritesNoDelegatedCallItself() async {
        let output = WireLog()
        let handed = ScriptValue<[String]>([])
        let presenter = ACPPromptPresenter(
            sessionID: "delegated-session",
            workspaceURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true),
            writer: ACPWriter(sink: { data in
                if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    output.messages.withLock { $0.append(value) }
                }
            }),
            updatePipeline: nil,
            ensureTasklessObserver: {},
            completeDelegatedToolCall: { event in
                handed.value.withLock { $0.append(event.toolCall.id) }
            }
        )
        await presenter.presentSubAgentToolEvent(Self.started("delegated-session"))
        await presenter.presentSubAgentToolEvent(Self.completed("delegated-session"))

        #expect(Self.updates(output).isEmpty)
        #expect(handed.get() == ["call-1"])
    }

    /// A completion of a call the client never saw — the turn was cancelled
    /// before it was shown — writes the creation first: an update the client
    /// cannot relate to a call is one it cannot render.
    @Test
    func aCompletionOfAToolCallTheClientNeverSawWritesItsCreationFirst() async {
        let output = WireLog()
        let presenter = ACPPromptPresenter(
            sessionID: "late-tool-session",
            workspaceURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true),
            writer: ACPWriter(sink: { data in
                if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    output.messages.withLock { $0.append(value) }
                }
            }),
            updatePipeline: nil,
            ensureTasklessObserver: {},
            completeDelegatedToolCall: { _ in }
        )
        let call = DirectAgentToolCall(
            id: "call-late",
            name: "local.write",
            argumentsObject: ["path": "Late.swift", "content": "let late = true\n"],
            argumentsJSON: #"{"path":"Late.swift","content":"let late = true\n"}"#
        )
        let result = DirectAgentToolResult(
            output: "Updated",
            summary: "Updated",
            fileChanges: [],
            elapsed: nil
        )

        await presenter.presentToolCallCompleted(call, result: result)

        let updates = Self.updates(output)
        #expect(updates.compactMap { $0.objectValue?["sessionUpdate"]?.acpStringValue }
            == ["tool_call", "tool_call_update"])
        #expect(updates.allSatisfy { $0.objectValue?["toolCallId"]?.acpStringValue == "call-late" })

        // A completion of a call the client already saw adds only the update
        // after its creation.
        let shown = WireLog()
        let shownPresenter = ACPPromptPresenter(
            sessionID: "shown-tool-session",
            workspaceURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true),
            writer: ACPWriter(sink: { data in
                if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    shown.messages.withLock { $0.append(value) }
                }
            }),
            updatePipeline: nil,
            ensureTasklessObserver: {},
            completeDelegatedToolCall: { _ in }
        )
        await shownPresenter.presentToolCallStarted(call)
        await shownPresenter.presentToolCallCompleted(call, result: result)
        #expect(Self.updates(shown).compactMap { $0.objectValue?["sessionUpdate"]?.acpStringValue }
            == ["tool_call", "tool_call_update"])
    }
}
