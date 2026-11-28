//
//  ACPSessionPersistenceTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/11/26.
//
//  The conversation of an ACP session is saved as a saved session of its
//  project, marked as saved by ACP: `/sessions` lists, loads, and deletes it,
//  it survives a restart of `zen --acp`, `session/list` lists it, and
//  `session/delete` deletes it. A
//  restart is two bridges, one after the other, on the same UUID support
//  directory: the first one runs the session's turns and shuts down, the
//  second one is asked to restore the session with `session/load` or
//  `session/resume` carrying only `sessionId`, `cwd`, and `mcpServers`, as a
//  standard ACP client (Xcode) sends them.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

struct ACPSessionPersistenceTests {
    // MARK: - Saving

    /// After a turn the session is a saved session of its project, named
    /// after its first prompt and marked as saved by ACP; the saved-session
    /// index, which records the explicit saves, is not touched.
    @Test
    func aTurnSavesTheSessionAsAMarkedSavedSessionNamedAfterItsFirstPrompt() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let sessionID = try await Self.runFirstProcess(
                workspace: workspace,
                prompt: "What is the capital of Italy?",
                sessionParams: ["agentId": Self.customAgent.id, "modelId": Self.thinkingModel.id]
            )

            let saved = try TerminalSessionStore.savedSessions(for: workspace)
            #expect(saved.count == 1)
            let session = try #require(saved.first)
            #expect(session.name == "What is the capital of Italy?")
            #expect(session.sessionID == sessionID)
            #expect(session.autosaveChannel == TerminalSavedSession.acpAutosaveChannel)
            #expect(Self.conversation(session.history) == [
                "user: What is the capital of Italy?",
                "assistant: reply to: What is the capital of Italy?",
            ])
            // The dynamic context leading the runner's history is not saved.
            #expect(AgentRuntimeDynamicContext.context(from: session.history.first) == nil)
            #expect(session.transcriptHistory == nil)
            #expect(session.activePlan == nil)
            #expect(session.contextWindow == nil)
            #expect(session.modelID == Self.thinkingModel.id)
            #expect(session.agentID == Self.customAgent.id)
            #expect(session.agentName == Self.customAgent.name)
            // The profile's tools, as the terminal records them for the agent.
            #expect(session.selectedTools == Self.customAgent.tools)
            #expect(session.selectedSkillNames.isEmpty)
            #expect(session.checkpointTree.sessionID == sessionID)
            #expect(Self.conversation(session.checkpointTree.activeMessages) == Self.conversation(session.history))
            #expect(SavedSessionsStore().sessions().isEmpty)
        }
    }

    /// A session that never ran a turn leaves no saved session behind.
    @Test
    func aSessionWithoutTurnsSavesNothing() async throws {
        try await Self.withSupportDirectory { support, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)

            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: workspace))
            #expect(wire.sessionID(ofResponse: 1) != nil)
            await bridge.shutdown()

            #expect(!FileManager.default.fileExists(atPath: Self.sessionsDirectory(in: support).path))
        }
    }

    /// The name is chosen at the first save and kept: every later turn, and
    /// every turn after a restart, updates the same saved session, which keeps
    /// its creation date.
    @Test
    func theNameStaysTheSameAcrossTurnsAndAfterARestart() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: workspace))
            let sessionID = try #require(wire.sessionID(ofResponse: 1))
            await bridge.handleMessage(Self.promptRequest(id: 2, sessionID: sessionID, text: "First question"))
            let first = try #require(try TerminalSessionStore.savedSessions(for: workspace).first)
            await bridge.handleMessage(Self.promptRequest(id: 3, sessionID: sessionID, text: "Second question"))
            await bridge.shutdown()

            let afterTwoTurns = try TerminalSessionStore.savedSessions(for: workspace)
            #expect(afterTwoTurns.map(\.name) == ["First question"])
            #expect(afterTwoTurns.first?.history.count == 4)
            #expect(afterTwoTurns.first?.createdAt == first.createdAt)

            let restartedWire = ACPPersistenceWire()
            let restarted = try Self.makeBridge(wire: restartedWire, backend: ACPPersistenceBackend(), workspace: workspace)
            await restarted.handleMessage(Self.restoreRequest("session/load", id: 1, sessionID: sessionID, workspace: workspace))
            await restarted.handleMessage(Self.promptRequest(id: 2, sessionID: sessionID, text: "Third question"))
            #expect(restartedWire.stopReason(id: 2) == "end_turn")
            await restarted.shutdown()

            let afterRestart = try TerminalSessionStore.savedSessions(for: workspace)
            #expect(afterRestart.map(\.name) == ["First question"])
            #expect(afterRestart.first?.sessionID == sessionID)
            #expect(afterRestart.first?.history.count == 6)
            #expect(afterRestart.first?.createdAt == first.createdAt)
            #expect(afterRestart.first?.autosaveChannel == TerminalSavedSession.acpAutosaveChannel)
            // The tree of the restored file goes on from where it was.
            #expect(afterRestart.first?.checkpointTree.entries.count == 6)
        }
    }

    /// Two sessions that start with the same prompt are two saved sessions:
    /// the second one never overwrites the first one.
    @Test
    func twoSessionsWithTheSameFirstPromptGetDistinctNames() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: workspace))
            await bridge.handleMessage(Self.newSessionRequest(id: 2, workspace: workspace))
            let firstID = try #require(wire.sessionID(ofResponse: 1))
            let secondID = try #require(wire.sessionID(ofResponse: 2))

            await bridge.handleMessage(Self.promptRequest(id: 3, sessionID: firstID, text: "Same prompt"))
            await bridge.handleMessage(Self.promptRequest(id: 4, sessionID: secondID, text: "Same prompt"))
            await bridge.handleMessage(Self.promptRequest(id: 5, sessionID: firstID, text: "Again"))
            await bridge.shutdown()

            let saved = try TerminalSessionStore.savedSessions(for: workspace)
            let names = Dictionary(uniqueKeysWithValues: saved.map { ($0.sessionID, $0.name) })
            #expect(names == [firstID: "Same prompt", secondID: "Same prompt (2)"])
            #expect(saved.first { $0.sessionID == firstID }?.history.count == 4)
            #expect(saved.allSatisfy { $0.autosaveChannel == TerminalSavedSession.acpAutosaveChannel })
        }
    }

    /// A saved session the user saved with the name the first prompt gives
    /// is never overwritten by the save of an ACP session.
    @Test
    func aSessionTheUserSavedWithTheSameNameIsNotOverwritten() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let manual = Self.manualSession(name: "Same prompt", sessionID: "manual-session", workspace: workspace)
            _ = try TerminalSessionStore.save(manual)

            let sessionID = try await Self.runFirstProcess(workspace: workspace, prompt: "Same prompt")

            let saved = try TerminalSessionStore.savedSessions(for: workspace)
            #expect(saved.first { $0.name == "Same prompt" } == manual)
            let acp = try #require(saved.first { $0.sessionID == sessionID })
            #expect(acp.name == "Same prompt (2)")
            #expect(acp.autosaveChannel == TerminalSavedSession.acpAutosaveChannel)
        }
    }

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
            let result = try #require(wire.message(at: responseIndex)?["result"]?.objectValue)
            #expect(result["sessionId"] == nil)
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
    /// session is ignored.
    @Test
    func aNonEmptyClientHistoryWinsOverTheSavedSession() async throws {
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

    /// The model, the agent, and the thinking level the session had are
    /// restored with its conversation; `preserveThinking` is not saved, so
    /// without the client's value it is off again.
    @Test
    func theSavedModelAgentAndThinkingAreRestoredButNotPreserveThinking() async throws {
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
            #expect(!configuration.preserveThinking)
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

    // MARK: - Fixture

    static let plainModel = AgentSettingsModelManifest(
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

    static let customAgent = AgentProfile(
        id: "custom-agent",
        name: "Custom Agent",
        role: .developer,
        tools: ["files"]
    )

    /// The agent of the `/sessions` tests, one of the harness's profiles.
    static let harnessAgent = AgentProfile(
        id: "AAAAAAAA-0000-0000-0000-0000000000AC",
        name: "Persistence Reviewer",
        role: .reviewer,
        tools: ["files", "search"]
    )

    /// Runs `body` with a support directory and a workspace in a UUID
    /// directory, the support directory scoped to the task, then removes them.
    static func withSupportDirectory(
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
    static func makeBridge(
        wire: ACPPersistenceWire,
        backend: ACPPersistenceBackend,
        workspace: URL,
        models: [AgentSettingsModelManifest] = [plainModel, thinkingModel],
        setupRequired: Bool = false
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
            backendFactory: backend.factory,
            setupRequired: setupRequired
        )
    }

    /// A bridge with the models and the profiles of the `/sessions` tests'
    /// harness, in its workspace.
    static func makeHarnessBridge(wire: ACPPersistenceWire, workspace: URL) throws -> ZenCODEACPBridge {
        let configuration = try AgentConfiguration(
            hostedModelID: ChatTestFixtures.alpha.id,
            availableAgents: [ChatTestFixtures.developer, harnessAgent],
            availableModels: ChatTestFixtures.hostedModels,
            runMode: .acp,
            workingDirectory: workspace
        )
        return ZenCODEACPBridge(
            configuration: configuration,
            writer: ACPWriter(sink: wire.sink),
            backendFactory: ACPPersistenceBackend().factory
        )
    }

    /// The first process: `session/new` with `sessionParams`, one prompt,
    /// then the shutdown. Returns the session's id.
    static func runFirstProcess(
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

    /// A saved session the user saved with `/sessions`: no marker.
    static func manualSession(
        name: String,
        sessionID: String,
        workspace: URL,
        savedAt: TimeInterval = 2_000
    ) -> TerminalSavedSession {
        let history = [
            AgentRuntimeMessage(role: .user, content: "Saved by hand"),
            AgentRuntimeMessage(role: .assistant, content: "Kept"),
        ]
        return TerminalSavedSession(
            name: name,
            sessionID: sessionID,
            cacheKey: nil,
            workingDirectoryPath: workspace.path,
            createdAt: Date(timeIntervalSince1970: 1_000),
            savedAt: Date(timeIntervalSince1970: savedAt),
            modelID: plainModel.id,
            agentID: nil,
            agentName: nil,
            selectedTools: [],
            selectedSkillNames: [],
            thinkingSelection: nil,
            systemPrompt: nil,
            history: history,
            checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: sessionID)
        )
    }

    static func newSessionRequest(
        id: Int,
        workspace: URL,
        extraParams: [String: String] = [:]
    ) -> [String: Any] {
        var params: [String: Any] = ["cwd": workspace.path, "mcpServers": [] as [Any]]
        params.merge(extraParams) { _, new in new }
        return [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/new",
            "params": params,
        ]
    }

    /// `session/load` or `session/resume` as a standard client sends it.
    static func restoreRequest(
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

    static func promptRequest(id: Int, sessionID: String, text: String) -> [String: Any] {
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

    /// `session/delete` as ACP v1 specifies it: only the `sessionId`.
    static func deleteRequest(id: Int, sessionID: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/delete",
            "params": ["sessionId": sessionID] as [String: Any],
        ]
    }

    /// The directory of the saved sessions of every project.
    static func sessionsDirectory(in support: URL) -> URL {
        support.appendingPathComponent("sessions", isDirectory: true)
    }

    /// `history` without the session context that leads it, one
    /// `role: content` line per message.
    static func conversation(_ history: [AgentRuntimeMessage]) -> [String] {
        AgentRuntimeDynamicContext.separating(from: history).history.map {
            "\($0.role.rawValue): \($0.content)"
        }
    }
}
