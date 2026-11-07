//
//  ACPDelegatedToolPresentationTests.swift
//  ZenCODE
//
//  The delegated agents' tool calls on the ACP wire, now that the session
//  host routes them to the session's controller and the prompt's presenter
//  renders them: a `tool_call` when one starts and a `tool_call_update` when
//  it completes, identified by agent and call and titled with the agent's
//  name, once per call and phase in a prompt, in the order they happened,
//  never for another session's agent and never outside a prompt.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

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

private extension ZenCODEACPBridge {
    /// The working directory of the live session `sessionID`.
    func delegatedToolTestCWD(sessionID: String) -> String? {
        sessions[sessionID]?.cwd
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ACPDelegatedToolPresentationTests {
    private static func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-delegated-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
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

    /// The payload the delegated `event` must produce: the coordinator's
    /// canonical tool update with the agent's id and name.
    private static func expectedUpdate(_ event: DirectSubAgentToolEvent, cwd: String) -> JSONValue {
        let workingDirectory = URL(fileURLWithPath: cwd)
        var update: [String: Any]
        switch event.lifecycle {
        case .started:
            update = ZenCODEACPBridge.toolCallCreateUpdate(for: event.toolCall, workingDirectory: workingDirectory)
        case let .completed(result):
            update = ZenCODEACPBridge.toolCallCompletionUpdate(
                for: event.toolCall, result: result, workingDirectory: workingDirectory
            )
        }
        update["toolCallId"] = "acp:tool:\(event.agentID):\(event.toolCall.id)"
        update["title"] = "\(event.agentName) — \(ZenCODEACPBridge.toolTitle(for: event.toolCall))"
        return JSONValue.acpValue(from: update)
    }

    @Test func delegatedToolCallsReachTheOwningPromptOncePerPhaseAndNeverOutsideIt() async throws {
        let workspace = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
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

        let write = DirectAgentToolCall(
            id: "call-1", name: "local.writeFile",
            argumentsObject: ["path": "Delegated.swift", "content": "let value = 2\n"],
            argumentsJSON: #"{"path":"Delegated.swift","content":"let value = 2\n"}"#
        )
        let started = DirectSubAgentToolEvent(
            agentID: "worker-1", agentName: "Worker", toolCall: write,
            lifecycle: .started, rootSessionID: sessionID
        )
        let completed = DirectSubAgentToolEvent(
            agentID: "worker-1", agentName: "Worker", toolCall: write,
            lifecycle: .completed(DirectAgentToolResult(
                output: "Updated", summary: "Updated",
                fileChanges: [OperationFileChange(path: "Delegated.swift", oldText: nil, newText: "let value = 2\n")]
            )),
            rootSessionID: sessionID
        )
        let foreign = DirectSubAgentToolEvent(
            agentID: "worker-2", agentName: "Other", toolCall: write,
            lifecycle: .started, rootSessionID: "another-session"
        )
        await backend.setScript { _, handler in
            // Each phase is sent once per prompt, whatever the runtime repeats;
            // another session's agent never reaches this prompt.
            await handler?(started)
            await handler?(started)
            await handler?(foreign)
            await handler?(completed)
            await handler?(completed)
        }
        try await bridge.prompt(id: .number(2), params: ["sessionId": sessionID, "prompt": "first"])

        let firstPrompt = Self.delegatedUpdates(output)
        #expect(firstPrompt.count == 2)
        #expect(firstPrompt.first == Self.expectedUpdate(started, cwd: cwd))
        #expect(firstPrompt.last == Self.expectedUpdate(completed, cwd: cwd))
        #expect(firstPrompt.first?.objectValue?["sessionUpdate"] == .string("tool_call"))
        #expect(firstPrompt.last?.objectValue?["sessionUpdate"] == .string("tool_call_update"))
        #expect(firstPrompt.first?.objectValue?["title"]?.acpStringValue?.hasPrefix("Worker — ") == true)
        // The delegated calls precede the root text streamed after them.
        let all = Self.updates(output)
        let completedIndex = try #require(all.firstIndex(of: Self.expectedUpdate(completed, cwd: cwd)))
        let rootTextIndex = try #require(all.firstIndex {
            $0.objectValue?["content"]?.objectValue?["text"] == .string("root text")
        })
        #expect(completedIndex < rootTextIndex)

        // Outside a prompt nothing is presented.
        await backend.setScript(nil)
        await backend.emit(completed)
        #expect(Self.delegatedUpdates(output).count == 2)

        // A new prompt presents the same call again, once.
        await backend.setScript { _, handler in
            await handler?(started)
            await handler?(started)
        }
        try await bridge.prompt(id: .number(3), params: ["sessionId": sessionID, "prompt": "second"])
        let afterSecond = Self.delegatedUpdates(output)
        #expect(afterSecond.count == 3)
        #expect(afterSecond.last == Self.expectedUpdate(started, cwd: cwd))
        await bridge.shutdown()
    }
}
