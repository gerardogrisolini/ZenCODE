//
//  ACPSessionPersistenceTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/11/26.
//
//  The conversation of an ACP session survives a restart of `zen --acp`. A
//  restart is two bridges, one after the other, on the same UUID support
//  directory: the first one runs the session's turns and shuts down, the
//  second one is asked to restore the session with `session/load` or
//  `session/resume` carrying only `sessionId`, `cwd`, and `mcpServers`, as a
//  standard ACP client (Xcode) sends them. The tests use only the bridge's
//  wire and its test seams, never the store, so they also run, and fail,
//  against a bridge that keeps nothing.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

struct ACPSessionPersistenceTests {
    // MARK: - session/load and session/resume after a restart

    /// The defect a client hits after the agent restarted: `session/load`
    /// replays the earlier turn before its reply, and the next prompt reaches
    /// the model with the earlier conversation.
    @Test
    func sessionLoadAfterARestartReplaysTheSavedTurnAndTheNextPromptHasIt() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let sessionID = try await Self.runFirstProcess(workspace: workspace, prompt: "What is the capital of Italy?")

            let wire = ACPPersistenceWire()
            let backend = ACPPersistenceBackend()
            let bridge = try Self.makeBridge(wire: wire, backend: backend, workspace: workspace)
            await bridge.handleMessage(Self.restoreRequest("session/load", id: 1, sessionID: sessionID, workspace: workspace))

            let responseIndex = try #require(wire.index(ofResponse: 1))
            #expect(wire.message(at: responseIndex)?["result"]?.objectValue?["sessionId"]?.acpStringValue == sessionID)
            #expect(wire.chunks(before: responseIndex) == [
                .init(kind: "user_message_chunk", text: "What is the capital of Italy?"),
                .init(kind: "agent_message_chunk", text: "reply to: What is the capital of Italy?"),
            ])

            await bridge.handleMessage(Self.promptRequest(id: 2, sessionID: sessionID, text: "And of France?"))
            #expect(wire.stopReason(id: 2) == "end_turn")
            let observation = try #require(await backend.observations.last)
            #expect(observation.prompt == "And of France?")
            #expect(Self.conversation(observation.history) == [
                "user: What is the capital of Italy?",
                "assistant: reply to: What is the capital of Italy?",
            ])
            await bridge.shutdown()
        }
    }

    /// `session/resume` restores the same conversation without replaying it.
    @Test
    func sessionResumeAfterARestartRestoresTheConversationWithoutReplayingIt() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let sessionID = try await Self.runFirstProcess(workspace: workspace, prompt: "Remember the number 42.")

            let wire = ACPPersistenceWire()
            let backend = ACPPersistenceBackend()
            let bridge = try Self.makeBridge(wire: wire, backend: backend, workspace: workspace)
            await bridge.handleMessage(Self.restoreRequest("session/resume", id: 1, sessionID: sessionID, workspace: workspace))

            #expect(wire.index(ofResponse: 1) != nil)
            #expect(wire.message(at: wire.index(ofResponse: 1) ?? 0)?["error"] == nil)
            #expect(wire.chunks(before: wire.count).isEmpty)

            await bridge.handleMessage(Self.promptRequest(id: 2, sessionID: sessionID, text: "Which number?"))
            #expect(wire.stopReason(id: 2) == "end_turn")
            let observation = try #require(await backend.observations.last)
            #expect(Self.conversation(observation.history) == [
                "user: Remember the number 42.",
                "assistant: reply to: Remember the number 42.",
            ])
            await bridge.shutdown()
        }
    }

    /// A client that sends its own non-empty `history` keeps it: the saved
    /// conversation is ignored.
    @Test
    func aNonEmptyClientHistoryWinsOverTheSavedConversation() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let sessionID = try await Self.runFirstProcess(workspace: workspace, prompt: "Saved by the agent")

            let wire = ACPPersistenceWire()
            let backend = ACPPersistenceBackend()
            let bridge = try Self.makeBridge(wire: wire, backend: backend, workspace: workspace)
            var request = Self.restoreRequest("session/load", id: 1, sessionID: sessionID, workspace: workspace)
            var params = try #require(request["params"] as? [String: Any])
            params["history"] = [
                ["role": "user", "content": "Kept by the client"],
                ["role": "assistant", "content": "Client answer"],
            ] as [[String: Any]]
            request["params"] = params
            await bridge.handleMessage(request)

            let responseIndex = try #require(wire.index(ofResponse: 1))
            #expect(wire.chunks(before: responseIndex) == [
                .init(kind: "user_message_chunk", text: "Kept by the client"),
                .init(kind: "agent_message_chunk", text: "Client answer"),
            ])
            await bridge.handleMessage(Self.promptRequest(id: 2, sessionID: sessionID, text: "Next"))
            let observation = try #require(await backend.observations.last)
            #expect(Self.conversation(observation.history) == [
                "user: Kept by the client",
                "assistant: Client answer",
            ])
            await bridge.shutdown()
        }
    }

    // MARK: - The session's selections

    /// The model, the agent, the thinking level, and `preserveThinking` the
    /// session had are restored with its conversation.
    @Test
    func theSavedModelAgentThinkingAndPreserveThinkingAreRestored() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let sessionID = try await Self.runFirstProcess(
                workspace: workspace,
                prompt: "Think hard",
                sessionParams: [
                    "modelId": Self.thinkingModel.id,
                    "agentId": Self.customAgent.id,
                    "thinkingSelection": AgentThinkingSelection.high.rawValue,
                ],
                preserveThinking: true
            )

            let bridge = try Self.makeBridge(wire: ACPPersistenceWire(), backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.restoreRequest("session/load", id: 1, sessionID: sessionID, workspace: workspace))

            let configuration = try #require(await bridge.telegramTestConfiguration(sessionID: sessionID))
            #expect(configuration.modelID == Self.thinkingModel.id)
            #expect(configuration.agentID == Self.customAgent.id)
            #expect(await bridge.selectedAgentIDForTesting(sessionID: sessionID) == Self.customAgent.id)
            #expect(configuration.thinkingSelection == .high)
            #expect(configuration.preserveThinking)
            await bridge.shutdown()
        }
    }

    /// The client's `modelId` wins over the saved model; the saved agent is
    /// still restored.
    @Test
    func anExplicitClientModelWinsOverTheSavedOne() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let sessionID = try await Self.runFirstProcess(
                workspace: workspace,
                prompt: "Think hard",
                sessionParams: [
                    "modelId": Self.thinkingModel.id,
                    "agentId": Self.customAgent.id,
                    "thinkingSelection": AgentThinkingSelection.high.rawValue,
                ]
            )

            let bridge = try Self.makeBridge(wire: ACPPersistenceWire(), backend: ACPPersistenceBackend(), workspace: workspace)
            var request = Self.restoreRequest("session/load", id: 1, sessionID: sessionID, workspace: workspace)
            var params = try #require(request["params"] as? [String: Any])
            params["modelId"] = Self.plainModel.id
            request["params"] = params
            await bridge.handleMessage(request)

            let configuration = try #require(await bridge.telegramTestConfiguration(sessionID: sessionID))
            #expect(configuration.modelID == Self.plainModel.id)
            // The saved level is not one the client's model offers.
            #expect(configuration.thinkingSelection == nil)
            #expect(configuration.agentID == Self.customAgent.id)
            #expect(Self.conversation(configuration.history) == ["user: Think hard", "assistant: reply to: Think hard"])
            await bridge.shutdown()
        }
    }

    /// A saved model the catalog no longer offers gives way to the default.
    @Test
    func aSavedModelNoLongerInTheCatalogFallsBackToTheDefault() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let sessionID = try await Self.runFirstProcess(
                workspace: workspace,
                prompt: "Think hard",
                sessionParams: [
                    "modelId": Self.thinkingModel.id,
                    "thinkingSelection": AgentThinkingSelection.high.rawValue,
                ]
            )

            let bridge = try Self.makeBridge(
                wire: ACPPersistenceWire(),
                backend: ACPPersistenceBackend(),
                workspace: workspace,
                models: [Self.plainModel]
            )
            await bridge.handleMessage(Self.restoreRequest("session/load", id: 1, sessionID: sessionID, workspace: workspace))

            let configuration = try #require(await bridge.telegramTestConfiguration(sessionID: sessionID))
            #expect(configuration.modelID == Self.plainModel.id)
            #expect(configuration.thinkingSelection == nil)
            #expect(Self.conversation(configuration.history) == ["user: Think hard", "assistant: reply to: Think hard"])
            await bridge.shutdown()
        }
    }

    // MARK: - Nothing to restore, nothing to save

    /// A session id the agent never saw, without a `history`, is still a new
    /// empty session, answered with success, as before.
    @Test
    func anUnknownSessionWithoutARecordStartsEmpty() async throws {
        try await Self.withSupportDirectory { support, workspace in
            let wire = ACPPersistenceWire()
            let backend = ACPPersistenceBackend()
            let bridge = try Self.makeBridge(wire: wire, backend: backend, workspace: workspace)
            let sessionID = "acp-persistence-unknown-\(UUID().uuidString)"

            await bridge.handleMessage(Self.restoreRequest("session/load", id: 1, sessionID: sessionID, workspace: workspace))

            let responseIndex = try #require(wire.index(ofResponse: 1))
            #expect(wire.message(at: responseIndex)?["result"]?.objectValue?["sessionId"]?.acpStringValue == sessionID)
            #expect(wire.chunks(before: responseIndex).isEmpty)
            #expect(await bridge.telegramTestConfiguration(sessionID: sessionID)?.history.isEmpty == true)
            // Restoring creates no record.
            #expect(!FileManager.default.fileExists(atPath: Self.recordsDirectory(in: support).path))
            await bridge.shutdown()
        }
    }

    /// A session that never ran a turn leaves no record behind.
    @Test
    func aSessionWithoutTurnsSavesNothing() async throws {
        try await Self.withSupportDirectory { support, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)

            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: workspace))
            #expect(wire.sessionID(ofResponse: 1) != nil)
            await bridge.shutdown()

            #expect(!FileManager.default.fileExists(atPath: Self.recordsDirectory(in: support).path))
        }
    }

    // MARK: - Turns from Telegram

    /// A turn the linked Telegram chat runs on an ACP session is saved too:
    /// after a restart `session/load` replays it.
    @Test(.timeLimit(.minutes(2)))
    func aTurnFromTelegramIsSavedAndReplayedAfterARestart() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let sessionID = "acp-persistence-telegram-\(UUID().uuidString)"
            let fixture = try await ACPTelegramBridgeFixture.make(
                root: root,
                sessionIDs: [sessionID],
                transport: ACPTelegramScriptedTransport(botID: ACPTelegramTestSupport.uniqueBotID())
            )
            #expect(await fixture.turnTelegramOn(sessionID: sessionID, id: 1) != nil)
            #expect(await ACPTelegramTestSupport.waitUntil { await fixture.transport.pollCount > 0 })
            let sentBefore = await fixture.transport.sentMessages.count

            try await fixture.transport.deliver("Hello from Telegram")
            #expect(await ACPTelegramTestSupport.waitUntil {
                await fixture.transport.sentTexts.dropFirst(sentBefore).contains { $0.contains("ZenCODE completed") }
            })
            #expect(await fixture.backend.prompts == ["Hello from Telegram"])
            await fixture.bridge.shutdown()

            // The restart: a new bridge in the same support directory and
            // workspace, with no session.
            let restarted = try await ACPTelegramBridgeFixture.make(
                root: root,
                sessionIDs: [],
                transport: ACPTelegramScriptedTransport(botID: ACPTelegramTestSupport.uniqueBotID())
            )
            await restarted.loadSession(sessionID: sessionID, id: 1)
            #expect(restarted.wire.response(id: 1)?["result"] != nil)
            #expect(restarted.wire.updateTexts(kind: "user_message_chunk") == ["Hello from Telegram"])
            #expect(restarted.wire.updateTexts(kind: "agent_message_chunk") == ["reply"])
            await restarted.bridge.shutdown()
        }
    }

    // MARK: - Fixture

    private static let plainModel = AgentSettingsModelManifest(
        id: "plain-model",
        kind: .remoteAPI,
        modelID: "local/plain-model"
    )

    /// Offers `.off`, `.medium` (its default), and `.high`.
    private static let thinkingModel = AgentSettingsModelManifest(
        id: "thinking-model",
        kind: .remoteAPI,
        modelID: "local/thinking-model",
        provider: AgentRemoteProvider(
            name: "remote-server",
            baseURL: "http://127.0.0.1",
            modelID: "local/thinking-model"
        ),
        thinkingOptions: [.off, .medium, .high],
        defaultThinkingSelection: .medium
    )

    private static let customAgent = AgentProfile(
        id: "custom-agent",
        name: "Custom Agent",
        role: .developer,
        tools: []
    )

    /// Runs `body` with a support directory and a workspace in a UUID
    /// directory, the support directory scoped to the task, then removes them.
    private static func withSupportDirectory(
        _ body: (_ support: URL, _ workspace: URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-session-persistence-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            try await body(support, workspace)
        }
    }

    /// A bridge with hosted `models` (the first one the default) and the
    /// default profiles plus ``customAgent``, whose sessions run on `backend`.
    private static func makeBridge(
        wire: ACPPersistenceWire,
        backend: ACPPersistenceBackend,
        workspace: URL,
        models: [AgentSettingsModelManifest] = [plainModel, thinkingModel]
    ) throws -> ZenCODEACPBridge {
        let configuration = try AgentConfiguration(
            hostedModelID: models[0].id,
            availableAgents: AgentProfileStore.defaultProfiles() + [customAgent],
            availableModels: models,
            runMode: .acp,
            workingDirectory: workspace
        )
        return ZenCODEACPBridge(
            configuration: configuration,
            writer: ACPWriter(sink: wire.sink),
            backendFactory: backend.factory
        )
    }

    /// The first process: `session/new` with `sessionParams`, one prompt,
    /// then the shutdown. Returns the session's id.
    private static func runFirstProcess(
        workspace: URL,
        prompt: String,
        sessionParams: [String: String] = [:],
        preserveThinking: Bool? = nil
    ) async throws -> String {
        let wire = ACPPersistenceWire()
        let bridge = try makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
        var request = newSessionRequest(id: 1, workspace: workspace)
        var params = try #require(request["params"] as? [String: Any])
        params.merge(sessionParams) { _, new in new }
        if let preserveThinking {
            params["preserveThinking"] = preserveThinking
        }
        request["params"] = params
        await bridge.handleMessage(request)
        let sessionID = try #require(wire.sessionID(ofResponse: 1))
        await bridge.handleMessage(promptRequest(id: 2, sessionID: sessionID, text: prompt))
        #expect(wire.stopReason(id: 2) == "end_turn")
        await bridge.shutdown()
        return sessionID
    }

    private static func newSessionRequest(id: Int, workspace: URL) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/new",
            "params": ["cwd": workspace.path, "mcpServers": [] as [Any]] as [String: Any],
        ]
    }

    /// `session/load` or `session/resume` as a standard client sends it.
    private static func restoreRequest(
        _ method: String,
        id: Int,
        sessionID: String,
        workspace: URL
    ) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": [
                "sessionId": sessionID,
                "cwd": workspace.path,
                "mcpServers": [] as [Any],
            ] as [String: Any],
        ]
    }

    private static func promptRequest(id: Int, sessionID: String, text: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/prompt",
            "params": [
                "sessionId": sessionID,
                "prompt": [["type": "text", "text": text]] as [[String: Any]],
            ] as [String: Any],
        ]
    }

    /// The directory the session records would be in.
    private static func recordsDirectory(in support: URL) -> URL {
        support.appendingPathComponent("acp-sessions", isDirectory: true)
    }

    /// `history` without the session context that leads it, one
    /// `role: content` line per message.
    private static func conversation(_ history: [AgentRuntimeMessage]) -> [String] {
        AgentRuntimeDynamicContext.separating(from: history).history.map {
            "\($0.role.rawValue): \($0.content)"
        }
    }
}

// MARK: - Doubles

/// Every JSON-RPC message a bridge wrote, in order.
private final class ACPPersistenceWire: Sendable {
    struct Chunk: Equatable, Sendable {
        let kind: String
        let text: String
    }

    private let storage = Mutex<[JSONValue]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                storage.withLock { $0.append(value) }
            }
        }
    }

    var count: Int {
        storage.withLock { $0.count }
    }

    func message(at index: Int) -> [String: JSONValue]? {
        storage.withLock { index < $0.count ? $0[index].objectValue : nil }
    }

    func index(ofResponse id: Int) -> Int? {
        storage.withLock { messages in
            messages.firstIndex { message in
                let object = message.objectValue
                return object?["id"] == .number(Double(id)) && object?["method"] == nil
            }
        }
    }

    func sessionID(ofResponse id: Int) -> String? {
        index(ofResponse: id).flatMap { message(at: $0) }?["result"]?
            .objectValue?["sessionId"]?.acpStringValue
    }

    func stopReason(id: Int) -> String? {
        index(ofResponse: id).flatMap { message(at: $0) }?["result"]?
            .objectValue?["stopReason"]?.acpStringValue
    }

    /// The user and agent message chunks written before message `index`.
    func chunks(before index: Int) -> [Chunk] {
        storage.withLock { Array($0.prefix(index)) }.compactMap { message in
            guard let object = message.objectValue,
                  object["method"]?.acpStringValue == "session/update",
                  let update = object["params"]?.objectValue?["update"]?.objectValue,
                  let kind = update["sessionUpdate"]?.acpStringValue,
                  kind == "user_message_chunk" || kind == "agent_message_chunk",
                  let text = update["content"]?.objectValue?["text"]?.acpStringValue else {
                return nil
            }
            return Chunk(kind: kind, text: text)
        }
    }
}

/// A backend that keeps every session's history as a model does: a prompt
/// adds itself and its reply. It records the history each prompt arrived
/// with. One instance is one process's backend.
private actor ACPPersistenceBackend: AgentRuntimeBackend {
    struct Observation: Sendable {
        let prompt: String
        let history: [AgentRuntimeMessage]
    }

    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private(set) var observations: [Observation] = []

    nonisolated var factory: AgentRuntimeBackendFactory {
        { [self] _, _ in self }
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
        "persistence-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        let snapshot = sessions[sessionID]
        observations.append(Observation(prompt: prompt, history: snapshot?.history ?? []))
        let reply = "reply to: \(prompt)"
        if let snapshot {
            sessions[sessionID] = snapshot.replacingHistory(snapshot.history + [
                AgentRuntimeMessage(role: .user, content: prompt),
                AgentRuntimeMessage(role: .assistant, content: reply),
            ])
        }
        await onEvent(.content(reply))
        return DirectAgentResponse(text: reply, stopReason: "end_turn", modelID: "persistence-model")
    }
}
