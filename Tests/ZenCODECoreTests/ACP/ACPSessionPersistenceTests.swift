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

    // MARK: - Nothing to restore

    /// A session id the agent never saw, without a `history`, is still a new
    /// empty session, answered with success, as before.
    @Test
    func anUnknownSessionWithoutASavedSessionStartsEmpty() async throws {
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
            // Restoring saves nothing.
            #expect(!FileManager.default.fileExists(atPath: Self.sessionsDirectory(in: support).path))
            await bridge.shutdown()
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

            let saved = try TerminalSessionStore.savedSessions(for: fixture.workingDirectory)
            #expect(saved.map(\.name) == ["Hello from Telegram"])
            #expect(saved.first?.sessionID == sessionID)
            #expect(saved.first?.autosaveChannel == TerminalSavedSession.acpAutosaveChannel)

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

    // MARK: - /sessions

    /// A session the bridge saved loads from `/sessions` as a usable session:
    /// its conversation, its id, its model and thinking level, its agent, and
    /// the tools and skills the terminal selects for that agent.
    @Test
    func theControllerLoadsASessionTheBridgeSaved() async throws {
        try await withChatHarness(catalog: .hosted(agents: [ChatTestFixtures.developer, Self.harnessAgent])) { harness in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeHarnessBridge(wire: wire, workspace: harness.workspace)
            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: harness.workspace, extraParams: [
                "agentId": Self.harnessAgent.id,
                "modelId": ChatTestFixtures.beta.id,
                "thinkingSelection": AgentThinkingSelection.high.rawValue,
            ]))
            let sessionID = try #require(wire.sessionID(ofResponse: 1))
            await bridge.handleMessage(Self.promptRequest(id: 2, sessionID: sessionID, text: "Review the parser"))
            await bridge.shutdown()
            let saved = try #require(try TerminalSessionStore.savedSessions(for: harness.workspace).first)

            let controller = harness.controller
            _ = try await controller.loadSavedSession(saved)

            #expect(controller.sessionID == sessionID)
            #expect(Self.conversation(controller.history) == [
                "user: Review the parser",
                "assistant: reply to: Review the parser",
            ])
            #expect(controller.savedSessionState.savedSessionName == "Review the parser")
            #expect(controller.selection.agent == Self.harnessAgent)
            #expect(controller.selection.modelIDOverride == ChatTestFixtures.beta.id)
            #expect(controller.selection.thinkingOverride == .high)
            let loadedToolKeys = controller.selection.toolKeys
            #expect(loadedToolKeys == ["files", "search"])
            #expect(controller.selection.skillNames.isEmpty)
            // The same selection the terminal makes for the agent.
            await controller.applyAgentProfile(Self.harnessAgent)
            #expect(controller.selection.toolKeys == loadedToolKeys)
        }
    }

    /// Deleting the session from `/sessions` deletes what the bridge saved: a
    /// later `session/load` of its id opens an empty session.
    @Test
    func deletingFromSessionsRemovesTheACPSessionAndALaterLoadStartsEmpty() async throws {
        try await withChatHarness(catalog: .hosted(agents: [ChatTestFixtures.developer, Self.harnessAgent])) { harness in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeHarnessBridge(wire: wire, workspace: harness.workspace)
            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: harness.workspace))
            let sessionID = try #require(wire.sessionID(ofResponse: 1))
            await bridge.handleMessage(Self.promptRequest(id: 2, sessionID: sessionID, text: "Delete me later"))
            await bridge.shutdown()
            #expect(try TerminalSessionStore.savedSessions(for: harness.workspace).map(\.name) == ["Delete me later"])

            let outcome = try await harness.controller.deleteSavedSessions(names: ["Delete me later"])
            #expect(outcome.notices == [.sessionDeleted(name: "Delete me later")])
            #expect(try TerminalSessionStore.savedSessions(for: harness.workspace).isEmpty)

            let restartedWire = ACPPersistenceWire()
            let restarted = try Self.makeHarnessBridge(wire: restartedWire, workspace: harness.workspace)
            await restarted.handleMessage(
                Self.restoreRequest("session/load", id: 1, sessionID: sessionID, workspace: harness.workspace)
            )
            let responseIndex = try #require(restartedWire.index(ofResponse: 1))
            #expect(restartedWire.message(at: responseIndex)?["error"] == nil)
            #expect(restartedWire.chunks(before: responseIndex).isEmpty)
            #expect(await restarted.telegramTestConfiguration(sessionID: sessionID)?.history.isEmpty == true)
            await restarted.shutdown()
        }
    }

    // MARK: - session/delete

    /// `initialize` declares `session/delete` and `session/list` next to
    /// `close` and `resume`.
    @Test
    func initializeDeclaresSessionDeleteAndList() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": ["protocolVersion": 1] as [String: Any],
            ])

            let capabilities = wire.result(id: 1)?["agentCapabilities"]?.objectValue
            #expect(capabilities?["loadSession"] == .bool(true))
            #expect(capabilities?["sessionCapabilities"] == .object([
                "close": .object([:]),
                "delete": .object([:]),
                "list": .object([:]),
                "resume": .object([:]),
            ]))
            await bridge.shutdown()
        }
    }

    /// `session/delete` of a session the process does not hold removes what
    /// ACP saved for its id, its DS4 checkpoint, and its index entry, and
    /// answers `{}`; what the user saved with the same id stays.
    @Test
    func deletingASessionThatIsNotLiveRemovesWhatACPSavedForIt() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let sessionID = try await Self.runFirstProcess(workspace: workspace, prompt: "Forget me")
            let saved = try #require(try TerminalSessionStore.savedSessions(for: workspace).first)
            let checkpointURL = TerminalSessionStore.engineCheckpointURL(name: saved.name, workingDirectory: workspace)
            try Data("kv".utf8).write(to: checkpointURL)
            try SavedSessionsStore().recordSavedSession(
                projectPath: workspace.path,
                sessionName: saved.name,
                sessionID: sessionID,
                savedAt: saved.savedAt
            )
            let manual = Self.manualSession(name: "Kept by the user", sessionID: sessionID, workspace: workspace)
            _ = try TerminalSessionStore.save(manual)

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.deleteRequest(id: 1, sessionID: sessionID))

            #expect(wire.result(id: 1) == [:])
            #expect(try TerminalSessionStore.savedSessions(for: workspace) == [manual])
            #expect(!FileManager.default.fileExists(atPath: checkpointURL.path))
            #expect(SavedSessionsStore().sessions().isEmpty)

            // Deleting it again succeeds silently.
            await bridge.handleMessage(Self.deleteRequest(id: 2, sessionID: sessionID))
            #expect(wire.result(id: 2) == [:])
            await bridge.shutdown()
        }
    }

    /// `session/delete` of a live session closes it as `session/close` does
    /// and deletes it: a prompt sent after it fails as after a close, and no
    /// save writes the session again.
    @Test
    func deletingALiveSessionClosesItAndNothingSavesItAgain() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: workspace))
            await bridge.handleMessage(Self.newSessionRequest(id: 2, workspace: workspace))
            let deletedID = try #require(wire.sessionID(ofResponse: 1))
            let closedID = try #require(wire.sessionID(ofResponse: 2))
            await bridge.handleMessage(Self.promptRequest(id: 3, sessionID: deletedID, text: "Deleted conversation"))
            await bridge.handleMessage(Self.promptRequest(id: 4, sessionID: closedID, text: "Closed conversation"))
            #expect(try TerminalSessionStore.savedSessions(for: workspace).count == 2)

            await bridge.handleMessage(Self.deleteRequest(id: 5, sessionID: deletedID))
            await bridge.handleMessage([
                "jsonrpc": "2.0",
                "id": 6,
                "method": "session/close",
                "params": ["sessionId": closedID] as [String: Any],
            ])
            #expect(wire.result(id: 5) == [:])
            #expect(wire.result(id: 6) == [:])
            #expect(await bridge.telegramTestConfiguration(sessionID: deletedID) == nil)

            await bridge.handleMessage(Self.promptRequest(id: 7, sessionID: deletedID, text: "After the delete"))
            await bridge.handleMessage(Self.promptRequest(id: 8, sessionID: closedID, text: "After the close"))
            let deletedError = try #require(wire.error(id: 7))
            #expect(deletedError == wire.error(id: 8))
            #expect(deletedError["code"] == .number(-32602))

            // `session/close` deletes nothing; `session/delete` left nothing.
            await bridge.shutdown()
            let saved = try TerminalSessionStore.savedSessions(for: workspace)
            #expect(saved.map(\.sessionID) == [closedID])
        }
    }

    /// A prompt still running when `session/delete` arrives is drained by the
    /// close, and the turn it ends saves nothing: once the reply is written,
    /// no file is left and none comes back.
    @Test(.timeLimit(.minutes(1)))
    func deletingASessionWhileAPromptRunsLeavesNoSavedSession() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let wire = ACPPersistenceWire()
            let gate = ACPPersistenceGate()
            let backend = ACPPersistenceBackend(gate: gate, gatedPrompt: "Slow question")
            let bridge = try Self.makeBridge(wire: wire, backend: backend, workspace: workspace)
            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: workspace))
            let sessionID = try #require(wire.sessionID(ofResponse: 1))
            await bridge.handleMessage(Self.promptRequest(id: 2, sessionID: sessionID, text: "First question"))
            #expect(try TerminalSessionStore.savedSessions(for: workspace).count == 1)

            let prompt = Task {
                await bridge.handleMessage(Self.promptRequest(id: 3, sessionID: sessionID, text: "Slow question"))
            }
            await gate.waitUntilReached()
            let deletion = Task {
                await bridge.handleMessage(Self.deleteRequest(id: 4, sessionID: sessionID))
            }
            // The delete dropped the session before it waits for the prompt.
            #expect(await ACPTelegramTestSupport.waitUntil {
                await bridge.telegramTestConfiguration(sessionID: sessionID) == nil
            })
            gate.open()
            await prompt.value
            await deletion.value

            #expect(wire.result(id: 4) == [:])
            #expect(try TerminalSessionStore.savedSessions(for: workspace).isEmpty)
            await bridge.shutdown()
            #expect(try TerminalSessionStore.savedSessions(for: workspace).isEmpty)
        }
    }

    /// An id with nothing saved and nothing live answers `{}`; a request
    /// without `sessionId` is invalid.
    @Test
    func deletingAnUnknownSessionSucceedsAndAMissingIdFails() async throws {
        try await Self.withSupportDirectory { support, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)

            await bridge.handleMessage(Self.deleteRequest(id: 1, sessionID: "acp-persistence-never-\(UUID().uuidString)"))
            await bridge.handleMessage([
                "jsonrpc": "2.0",
                "id": 2,
                "method": "session/delete",
                "params": [:] as [String: Any],
            ])

            #expect(wire.result(id: 1) == [:])
            #expect(wire.error(id: 2)?["code"] == .number(-32602))
            #expect(!FileManager.default.fileExists(atPath: Self.sessionsDirectory(in: support).path))
            await bridge.shutdown()
        }
    }

    /// A saved session that cannot be removed fails the request with an
    /// internal error, so the client learns it was not deleted.
    @Test
    func aDeletionThatCannotRemoveTheFileAnswersAnInternalError() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let sessionID = try await Self.runFirstProcess(workspace: workspace, prompt: "Locked")
            let directory = TerminalSessionStore.sessionsDirectoryURL(for: workspace)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            }

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.deleteRequest(id: 1, sessionID: sessionID))

            #expect(wire.error(id: 1)?["code"] == .number(-32603))
            #expect(wire.result(id: 1) == nil)
            await bridge.shutdown()
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            #expect(try TerminalSessionStore.savedSessions(for: workspace).map(\.sessionID) == [sessionID])
        }
    }

    // MARK: - session/list

    /// With nothing saved, `session/list` answers an empty list without
    /// `nextCursor`, with or without `cwd` and without `params`, and creates
    /// nothing; a `null` `cwd` or `cursor` is no filter and the first page.
    @Test
    func listingWithNothingSavedAnswersAnEmptyList() async throws {
        try await Self.withSupportDirectory { support, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)

            await bridge.handleMessage(Self.listRequest(id: 1))
            await bridge.handleMessage(Self.listRequest(id: 2, params: ["cwd": workspace.path]))
            await bridge.handleMessage(["jsonrpc": "2.0", "id": 3, "method": "session/list"])
            await bridge.handleMessage(Self.listRequest(id: 4, params: ["cwd": NSNull(), "cursor": NSNull()]))

            for id in 1...4 {
                #expect(wire.result(id: id) == ["sessions": .array([])])
            }
            #expect(!FileManager.default.fileExists(atPath: Self.sessionsDirectory(in: support).path))
            await bridge.shutdown()
        }
    }

    /// After a turn the session is listed with its id, the working directory
    /// it was saved in, the name its first prompt gave it as `title`, and the
    /// moment it was saved as `updatedAt`, in the format of
    /// `session_info_update`.
    @Test
    func aSavedTurnIsListedWithItsIdWorkingDirectoryTitleAndSaveTime() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let sessionID = try await Self.runFirstProcess(workspace: workspace, prompt: "What is the capital of Italy?")
            let saved = try #require(try TerminalSessionStore.savedSessions(for: workspace).first)

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.listRequest(id: 1))
            await bridge.handleMessage(Self.listRequest(id: 2, params: ["cwd": workspace.path]))

            let updatedAt = ISO8601DateFormatter().string(from: saved.savedAt)
            #expect(wire.result(id: 1) == ["sessions": .array([.object([
                "sessionId": .string(sessionID),
                "cwd": .string(saved.workingDirectoryPath),
                "title": .string("What is the capital of Italy?"),
                "updatedAt": .string(updatedAt),
            ])])])
            #expect(wire.result(id: 2) == ["sessions": .array([.object([
                "sessionId": .string(sessionID),
                "cwd": .string(workspace.path),
                "title": .string("What is the capital of Italy?"),
                "updatedAt": .string(updatedAt),
            ])])])
            let parsed = try #require(ISO8601DateFormatter().date(from: updatedAt))
            #expect(abs(parsed.timeIntervalSince(saved.savedAt)) < 1)
            await bridge.shutdown()
        }
    }

    /// The sessions the user saved with `/sessions` are not listed, even
    /// under the id of an ACP session, and the files ACP saved for one id
    /// give one entry: the most recently saved.
    @Test
    func explicitSavesAreNotListedAndAnIdIsListedOnceWithItsNewestSave() async throws {
        try await Self.withSupportDirectory { _, workspace in
            _ = try TerminalSessionStore.save(Self.manualSession(name: "Kept by the user", sessionID: "manual-only", workspace: workspace))
            _ = try TerminalSessionStore.save(Self.autosavedSession(name: "Older save", sessionID: "shared", workspace: workspace, savedAt: 100))
            _ = try TerminalSessionStore.save(Self.autosavedSession(name: "Newer save", sessionID: "shared", workspace: workspace, savedAt: 200))
            _ = try TerminalSessionStore.save(Self.manualSession(name: "Newest by hand", sessionID: "shared", workspace: workspace, savedAt: 300))

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.listRequest(id: 1))
            await bridge.handleMessage(Self.listRequest(id: 2, params: ["cwd": workspace.path]))

            for id in 1...2 {
                let sessions = try #require(Self.listedSessions(wire, id: id))
                #expect(sessions.map { $0["sessionId"]?.acpStringValue } == ["shared"])
                #expect(sessions.first?["title"] == .string("Newer save"))
                #expect(sessions.first?["updatedAt"] == .string(
                    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 200))
                ))
            }
            await bridge.shutdown()
        }
    }

    /// `cwd` lists the sessions saved in exactly that working directory: not
    /// those of another project, nor those of another folder with the same
    /// name, whose sessions share the project's directory. Without `cwd`
    /// every project is listed.
    @Test
    func theWorkingDirectoryFilterMatchesTheExactPath() async throws {
        try await Self.withSupportDirectory { support, _ in
            let root = support.deletingLastPathComponent()
            let alpha = try Self.makeDirectory(root, "first/Alpha")
            let beta = try Self.makeDirectory(root, "second/Beta")
            let sameA = try Self.makeDirectory(root, "a/Same")
            let sameB = try Self.makeDirectory(root, "b/Same")
            #expect(TerminalSessionStore.sessionsDirectoryURL(for: sameA) == TerminalSessionStore.sessionsDirectoryURL(for: sameB))
            for (sessionID, workspace) in [("alpha", alpha), ("beta", beta), ("same-a", sameA), ("same-b", sameB)] {
                _ = try TerminalSessionStore.save(Self.autosavedSession(name: sessionID, sessionID: sessionID, workspace: workspace))
            }

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: alpha)
            await bridge.handleMessage(Self.listRequest(id: 1, params: ["cwd": alpha.path]))
            await bridge.handleMessage(Self.listRequest(id: 2, params: ["cwd": beta.path]))
            await bridge.handleMessage(Self.listRequest(id: 3, params: ["cwd": sameA.path]))
            await bridge.handleMessage(Self.listRequest(id: 4, params: ["cwd": sameB.path + "/"]))
            await bridge.handleMessage(Self.listRequest(id: 5))
            await bridge.handleMessage(Self.listRequest(id: 6, params: ["cwd": root.appendingPathComponent("c/Same").path]))

            #expect(Self.listedIDs(wire, id: 1) == ["alpha"])
            #expect(Self.listedIDs(wire, id: 2) == ["beta"])
            #expect(Self.listedIDs(wire, id: 3) == ["same-a"])
            #expect(Self.listedIDs(wire, id: 4) == ["same-b"])
            // The `cwd` the client sent, as it sent it.
            #expect(Self.listedSessions(wire, id: 4)?.first?["cwd"] == .string(sameB.path + "/"))
            #expect(Self.listedIDs(wire, id: 5) == ["alpha", "beta", "same-a", "same-b"])
            #expect(Self.listedSessions(wire, id: 5)?.first { $0["sessionId"] == .string("same-b") }?["cwd"]
                == .string(Self.resolvedPath(sameB)))
            #expect(Self.listedIDs(wire, id: 6) == [])
            await bridge.shutdown()
        }
    }

    /// A `cwd` through a symbolic link lists the sessions saved there, which
    /// are saved under the resolved directory, as `session/new` and
    /// `session/load` resolve it: every entry carries the `cwd` the client
    /// sent, and `session/load` with it restores the conversation.
    @Test
    func aWorkingDirectoryThroughASymbolicLinkListsAndLoadsItsSessions() async throws {
        try await Self.withSupportDirectory { support, workspace in
            let link = support.deletingLastPathComponent().appendingPathComponent("linked-project", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: workspace)
            let resolvedPath = Self.resolvedPath(link)
            #expect(resolvedPath != link.path)
            #expect(resolvedPath == Self.resolvedPath(workspace))
            let sessionID = try await Self.runFirstProcess(workspace: link, prompt: "Through the link")
            #expect(try TerminalSessionStore.savedSessions(for: workspace).map(\.workingDirectoryPath) == [resolvedPath])

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: link)
            await bridge.handleMessage(Self.listRequest(id: 1, params: ["cwd": link.path]))
            await bridge.handleMessage(Self.listRequest(id: 2, params: ["cwd": workspace.path]))
            await bridge.handleMessage(Self.listRequest(id: 3))

            let entry = try #require(Self.listedSessions(wire, id: 1)?.first)
            #expect(Self.listedIDs(wire, id: 1) == [sessionID])
            #expect(entry["cwd"] == .string(link.path))
            #expect(Self.listedSessions(wire, id: 2)?.first?["cwd"] == .string(workspace.path))
            #expect(Self.listedSessions(wire, id: 3)?.first?["cwd"] == .string(resolvedPath))

            let cwd = try #require(entry["cwd"]?.acpStringValue)
            await bridge.handleMessage(Self.restoreRequest(
                "session/load",
                id: 4,
                sessionID: sessionID,
                workspace: URL(fileURLWithPath: cwd)
            ))
            let responseIndex = try #require(wire.index(ofResponse: 4))
            #expect(wire.chunks(before: responseIndex) == [
                .init(kind: "user_message_chunk", text: "Through the link"),
                .init(kind: "agent_message_chunk", text: "reply to: Through the link"),
            ])
            await bridge.shutdown()
        }
    }

    /// A `cwd` that is not a string with an absolute path, and a `cursor` that
    /// is not a string a reply gave, are invalid parameters.
    @Test
    func anInvalidWorkingDirectoryOrCursorIsInvalidParams() async throws {
        try await Self.withSupportDirectory { _, workspace in
            _ = try TerminalSessionStore.save(Self.autosavedSession(name: "Listed", sessionID: "listed", workspace: workspace))
            let badHex = Data(#"{"savedAt":"zzzzzzzzzzzzzzzz","sessionId":"listed"}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let invalidParams: [[String: JSONValue]] = [
                ["cwd": .string("relative/path")],
                ["cwd": .string("~/Projects")],
                ["cwd": .string("")],
                ["cwd": .number(42)],
                ["cwd": .object(["path": .string(workspace.path)])],
                ["cursor": .number(42)],
                ["cursor": .string("")],
                ["cursor": .string("not a cursor!")],
                ["cursor": .string("Zm9v")],
                ["cursor": .string(badHex)],
            ]

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            for (offset, params) in invalidParams.enumerated() {
                await bridge.handleMessage(Self.listRequest(id: offset + 1, params: params.mapValues(\.jsonObject)))
            }

            for id in 1...invalidParams.count {
                #expect(wire.error(id: id)?["code"] == .number(-32602), "request \(id)")
                #expect(wire.result(id: id) == nil, "request \(id)")
            }
            await bridge.shutdown()
        }
    }

    /// The most recently saved session comes first; sessions saved at the
    /// same moment come in ascending order of their id.
    @Test
    func theListIsOrderedByLastSaveThenBySessionID() async throws {
        try await Self.withSupportDirectory { _, workspace in
            for (sessionID, savedAt) in [("session-b", 300.0), ("session-c", 100.0), ("session-a", 300.0), ("session-d", 200.0)] {
                _ = try TerminalSessionStore.save(Self.autosavedSession(
                    name: "Name of \(sessionID)",
                    sessionID: sessionID,
                    workspace: workspace,
                    savedAt: savedAt
                ))
            }

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.listRequest(id: 1))

            #expect(Self.listedIDs(wire, id: 1) == ["session-a", "session-b", "session-d", "session-c"])
            #expect(wire.result(id: 1)?["nextCursor"] == nil)
            await bridge.shutdown()
        }
    }

    /// More than a page of sessions: pages of 50 with `nextCursor`, the last
    /// one without it, and walking them gives every session once, in order,
    /// also where sessions saved at the same moment, distinct only below the
    /// second, straddle the end of a page.
    @Test
    func pagesOfFiftyWalkEverySessionOnceInOrder() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let count = 120
            var expected: [(id: String, savedAt: Date)] = []
            for index in 0..<count {
                let sessionID = String(format: "paged-%03d", (index * 37) % count)
                // Three sessions per moment, the moments a microsecond apart.
                let savedAt = Date(timeIntervalSince1970: 1_700_000_000.25 + Double(index / 3) * 0.000_001)
                _ = try TerminalSessionStore.save(Self.autosavedSession(
                    name: "Paged \(sessionID)",
                    sessionID: sessionID,
                    workspace: workspace,
                    savedAt: savedAt.timeIntervalSince1970
                ))
                expected.append((sessionID, savedAt))
            }
            _ = try TerminalSessionStore.save(Self.manualSession(name: "Not listed", sessionID: "manual", workspace: workspace))
            let savedAtByID = Dictionary(uniqueKeysWithValues: try TerminalSessionStore.savedSessions(for: workspace).map {
                ($0.sessionID, $0.savedAt)
            })
            let expectedOrder = expected
                .map { (id: $0.id, savedAt: savedAtByID[$0.id] ?? $0.savedAt) }
                .sorted { $0.savedAt != $1.savedAt ? $0.savedAt > $1.savedAt : $0.id < $1.id }
                .map(\.id)

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            var walked: [String] = []
            var pageSizes: [Int] = []
            var cursor: String?
            var requestID = 0
            repeat {
                requestID += 1
                await bridge.handleMessage(Self.listRequest(
                    id: requestID,
                    params: cursor.map { ["cwd": workspace.path, "cursor": $0] } ?? ["cwd": workspace.path]
                ))
                let ids = try #require(Self.listedIDs(wire, id: requestID))
                walked += ids
                pageSizes.append(ids.count)
                cursor = wire.result(id: requestID)?["nextCursor"]?.acpStringValue
            } while cursor != nil && requestID < 10

            #expect(pageSizes == [50, 50, 20])
            #expect(walked == expectedOrder)
            #expect(Set(walked).count == count)

            // Without `cwd` the same walk.
            await bridge.handleMessage(Self.listRequest(id: 100))
            let firstPage = try #require(Self.listedIDs(wire, id: 100))
            #expect(firstPage == Array(expectedOrder.prefix(50)))
            let nextCursor = try #require(wire.result(id: 100)?["nextCursor"]?.acpStringValue)
            await bridge.handleMessage(Self.listRequest(id: 101, params: ["cursor": nextCursor]))
            #expect(Self.listedIDs(wire, id: 101) == Array(expectedOrder.dropFirst(50).prefix(50)))
            await bridge.shutdown()
        }
    }

    /// What is not a session file is not listed and fails nothing: an
    /// unreadable file, hidden and temporary files, DS4 checkpoints, a
    /// directory, and a file among the project directories.
    @Test
    func filesThatAreNotSessionsAreNotListed() async throws {
        try await Self.withSupportDirectory { support, workspace in
            let listed = Self.autosavedSession(name: "Listed", sessionID: "listed", workspace: workspace)
            _ = try TerminalSessionStore.save(listed)
            let directory = TerminalSessionStore.sessionsDirectoryURL(for: workspace)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let hidden = try encoder.encode(Self.autosavedSession(name: "Hidden", sessionID: "hidden", workspace: workspace))
            try Data("not a property list".utf8).write(to: directory.appendingPathComponent("broken.session"))
            try hidden.write(to: directory.appendingPathComponent(".hidden.session"))
            try hidden.write(to: directory.appendingPathComponent("pending.session.tmp"))
            try hidden.write(to: directory.appendingPathComponent("Listed.ds4kv"))
            try hidden.write(to: directory.appendingPathComponent("Listed.ds4kv.tmp.1"))
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("nested.session", isDirectory: true),
                withIntermediateDirectories: true
            )
            try hidden.write(to: Self.sessionsDirectory(in: support).appendingPathComponent("stray.session"))

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.listRequest(id: 1))
            await bridge.handleMessage(Self.listRequest(id: 2, params: ["cwd": workspace.path]))

            #expect(Self.listedIDs(wire, id: 1) == ["listed"])
            #expect(Self.listedIDs(wire, id: 2) == ["listed"])
            await bridge.shutdown()
        }
    }

    /// A session `session/delete` deleted is no longer listed; the others are.
    @Test
    func aSessionDeletedWithSessionDeleteIsNoLongerListed() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let deletedID = try await Self.runFirstProcess(workspace: workspace, prompt: "Delete me")
            let keptID = try await Self.runFirstProcess(workspace: workspace, prompt: "Keep me")

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.listRequest(id: 1))
            await bridge.handleMessage(Self.deleteRequest(id: 2, sessionID: deletedID))
            await bridge.handleMessage(Self.listRequest(id: 3))
            await bridge.handleMessage(Self.listRequest(id: 4, params: ["cwd": workspace.path]))

            #expect(Set(Self.listedIDs(wire, id: 1) ?? []) == [deletedID, keptID])
            #expect(wire.result(id: 2) == [:])
            #expect(Self.listedIDs(wire, id: 3) == [keptID])
            #expect(Self.listedIDs(wire, id: 4) == [keptID])
            await bridge.shutdown()
        }
    }

    /// A session deleted from `/sessions` is no longer listed.
    @Test
    func aSessionDeletedFromSessionsIsNoLongerListed() async throws {
        try await withChatHarness(catalog: .hosted(agents: [ChatTestFixtures.developer, Self.harnessAgent])) { harness in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeHarnessBridge(wire: wire, workspace: harness.workspace)
            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: harness.workspace))
            let sessionID = try #require(wire.sessionID(ofResponse: 1))
            await bridge.handleMessage(Self.promptRequest(id: 2, sessionID: sessionID, text: "Delete me from sessions"))
            await bridge.shutdown()

            let restartedWire = ACPPersistenceWire()
            let restarted = try Self.makeHarnessBridge(wire: restartedWire, workspace: harness.workspace)
            await restarted.handleMessage(Self.listRequest(id: 1))
            #expect(Self.listedIDs(restartedWire, id: 1) == [sessionID])

            let outcome = try await harness.controller.deleteSavedSessions(names: ["Delete me from sessions"])
            #expect(outcome.notices == [.sessionDeleted(name: "Delete me from sessions")])

            await restarted.handleMessage(Self.listRequest(id: 2))
            await restarted.handleMessage(Self.listRequest(id: 3, params: ["cwd": harness.workspace.path]))
            #expect(restartedWire.result(id: 2) == ["sessions": .array([])])
            #expect(restartedWire.result(id: 3) == ["sessions": .array([])])
            await restarted.shutdown()
        }
    }

    /// After a restart, the client lists the sessions and reopens one with
    /// the `sessionId` and `cwd` of its entry: `session/load` replays the
    /// conversation and the next prompt has it.
    @Test
    func aRestartedAgentListsTheSessionAndLoadsItFromItsEntry() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let sessionID = try await Self.runFirstProcess(workspace: workspace, prompt: "Remember the number 42.")

            let wire = ACPPersistenceWire()
            let backend = ACPPersistenceBackend()
            let bridge = try Self.makeBridge(wire: wire, backend: backend, workspace: workspace)
            await bridge.handleMessage(Self.listRequest(id: 1))
            let entry = try #require(Self.listedSessions(wire, id: 1)?.first)
            let listedID = try #require(entry["sessionId"]?.acpStringValue)
            let listedCwd = try #require(entry["cwd"]?.acpStringValue)
            #expect(listedID == sessionID)

            await bridge.handleMessage(Self.restoreRequest(
                "session/load",
                id: 2,
                sessionID: listedID,
                workspace: URL(fileURLWithPath: listedCwd)
            ))
            let responseIndex = try #require(wire.index(ofResponse: 2))
            #expect(wire.message(at: responseIndex)?["error"] == nil)
            #expect(wire.chunks(before: responseIndex) == [
                .init(kind: "user_message_chunk", text: "Remember the number 42."),
                .init(kind: "agent_message_chunk", text: "reply to: Remember the number 42."),
            ])
            await bridge.handleMessage(Self.promptRequest(id: 3, sessionID: listedID, text: "Which number?"))
            #expect(wire.stopReason(id: 3) == "end_turn")
            let observation = try #require(await backend.observations.last)
            #expect(Self.conversation(observation.history) == [
                "user: Remember the number 42.",
                "assistant: reply to: Remember the number 42.",
            ])
            await bridge.shutdown()
        }
    }

    /// `session/list` only reads: it opens no session, writes no file, and
    /// leaves a live session as it is, which is not listed before its first
    /// turn. Like `session/delete`, it answers on a bridge that still needs
    /// the setup, which refuses `session/new`.
    @Test
    func listingCreatesNothingAndNeedsNoConfiguration() async throws {
        try await Self.withSupportDirectory { support, workspace in
            _ = try TerminalSessionStore.save(Self.autosavedSession(name: "Listed", sessionID: "listed", workspace: workspace))
            _ = try TerminalSessionStore.save(Self.autosavedSession(name: "Deleted", sessionID: "deleted", workspace: workspace))

            let unconfiguredWire = ACPPersistenceWire()
            let unconfigured = try Self.makeBridge(
                wire: unconfiguredWire,
                backend: ACPPersistenceBackend(),
                workspace: workspace,
                setupRequired: true
            )
            let before = try Self.fileTree(support)
            await unconfigured.handleMessage(Self.listRequest(id: 1))
            await unconfigured.handleMessage(Self.listRequest(id: 2, params: ["cwd": workspace.path]))
            #expect(Self.listedIDs(unconfiguredWire, id: 1) == ["deleted", "listed"])
            #expect(Self.listedIDs(unconfiguredWire, id: 2) == ["deleted", "listed"])
            #expect(await unconfigured.sessionConfigurationsForTesting().isEmpty)
            #expect(try Self.fileTree(support) == before)
            await unconfigured.handleMessage(Self.deleteRequest(id: 3, sessionID: "deleted"))
            await unconfigured.handleMessage(Self.listRequest(id: 4))
            await unconfigured.handleMessage(Self.newSessionRequest(id: 5, workspace: workspace))
            #expect(unconfiguredWire.result(id: 3) == [:])
            #expect(Self.listedIDs(unconfiguredWire, id: 4) == ["listed"])
            #expect(unconfiguredWire.error(id: 5)?["code"] == .number(-32000))
            await unconfigured.shutdown()

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: workspace))
            let liveID = try #require(wire.sessionID(ofResponse: 1))
            let beforeListing = try Self.fileTree(support)
            await bridge.handleMessage(Self.listRequest(id: 2))
            #expect(Self.listedIDs(wire, id: 2) == ["listed"])
            #expect(await bridge.sessionConfigurationsForTesting().count == 1)
            #expect(await bridge.telegramTestConfiguration(sessionID: liveID)?.history.isEmpty == true)
            #expect(try Self.fileTree(support) == beforeListing)
            await bridge.handleMessage(Self.promptRequest(id: 3, sessionID: liveID, text: "Now listed"))
            await bridge.handleMessage(Self.listRequest(id: 4))
            #expect(Self.listedIDs(wire, id: 4) == [liveID, "listed"])
            await bridge.shutdown()
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
        tools: ["files"]
    )

    /// The agent of the `/sessions` tests, one of the harness's profiles.
    private static let harnessAgent = AgentProfile(
        id: "AAAAAAAA-0000-0000-0000-0000000000AC",
        name: "Persistence Reviewer",
        role: .reviewer,
        tools: ["files", "search"]
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
    private static func makeHarnessBridge(wire: ACPPersistenceWire, workspace: URL) throws -> ZenCODEACPBridge {
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

    /// A saved session the user saved with `/sessions`: no marker.
    private static func manualSession(
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

    /// A saved session ACP saved by itself, as the bridge writes it: marked,
    /// in the working directory `workspace` resolves to.
    private static func autosavedSession(
        name: String,
        sessionID: String,
        workspace: URL,
        savedAt: TimeInterval = 1_000
    ) -> TerminalSavedSession {
        let history = [
            AgentRuntimeMessage(role: .user, content: "Question of \(name)"),
            AgentRuntimeMessage(role: .assistant, content: "Answer of \(name)"),
        ]
        return TerminalSavedSession(
            name: name,
            sessionID: sessionID,
            cacheKey: nil,
            workingDirectoryPath: resolvedPath(workspace),
            createdAt: Date(timeIntervalSince1970: 500),
            savedAt: Date(timeIntervalSince1970: savedAt),
            modelID: plainModel.id,
            agentID: nil,
            agentName: nil,
            selectedTools: [],
            selectedSkillNames: [],
            thinkingSelection: nil,
            systemPrompt: nil,
            history: history,
            checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: sessionID),
            autosaveChannel: TerminalSavedSession.acpAutosaveChannel
        )
    }

    /// The working directory a session of `workspace` is saved in, resolved
    /// as `session/new` and `session/load` resolve the `cwd`.
    private static func resolvedPath(_ workspace: URL) -> String {
        AgentConfiguration.resolvedWorkingDirectory(rawValue: workspace.path, applyLaunchDirectoryFallback: false).path
    }

    /// Creates the directory `relativePath` under `root`.
    private static func makeDirectory(_ root: URL, _ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every file and directory under `root`, as paths relative to it.
    private static func fileTree(_ root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            return []
        }
        return Set(enumerator.compactMap { $0 as? String })
    }

    /// `session/list` with `params`.
    private static func listRequest(id: Int, params: [String: Any] = [:]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/list",
            "params": params,
        ]
    }

    /// The `sessions` of the reply to the `session/list` request `id`.
    private static func listedSessions(_ wire: ACPPersistenceWire, id: Int) -> [[String: JSONValue]]? {
        wire.result(id: id)?["sessions"]?.arrayValue?.compactMap(\.objectValue)
    }

    /// The `sessionId` of every session of the reply to the `session/list`
    /// request `id`, in order.
    private static func listedIDs(_ wire: ACPPersistenceWire, id: Int) -> [String]? {
        listedSessions(wire, id: id)?.compactMap { $0["sessionId"]?.acpStringValue }
    }

    private static func newSessionRequest(
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

    /// `session/delete` as ACP v1 specifies it: only the `sessionId`.
    private static func deleteRequest(id: Int, sessionID: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/delete",
            "params": ["sessionId": sessionID] as [String: Any],
        ]
    }

    /// The directory of the saved sessions of every project.
    private static func sessionsDirectory(in support: URL) -> URL {
        support.appendingPathComponent("sessions", isDirectory: true)
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

    /// The `result` of the response to request `id`, if it succeeded.
    func result(id: Int) -> [String: JSONValue]? {
        index(ofResponse: id).flatMap { message(at: $0) }?["result"]?.objectValue
    }

    /// The `error` of the response to request `id`, if it failed.
    func error(id: Int) -> [String: JSONValue]? {
        index(ofResponse: id).flatMap { message(at: $0) }?["error"]?.objectValue
    }

    func sessionID(ofResponse id: Int) -> String? {
        result(id: id)?["sessionId"]?.acpStringValue
    }

    func stopReason(id: Int) -> String? {
        result(id: id)?["stopReason"]?.acpStringValue
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

/// Holds a prompt inside the backend until the test opens it, and tells the
/// test when the prompt got there.
private final class ACPPersistenceGate: Sendable {
    private struct State {
        var isOpen = false
        var isReached = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func arriveAndWait() async {
        let reachedWaiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isReached = true
            defer { state.reachedWaiters.removeAll() }
            return state.reachedWaiters
        }
        for waiter in reachedWaiters { waiter.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                guard !state.isOpen else { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func waitUntilReached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                guard !state.isReached else { return true }
                state.reachedWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// A backend that keeps every session's history as a model does: a prompt
/// adds itself and its reply. It records the history each prompt arrived
/// with. One instance is one process's backend. The prompt `gatedPrompt`
/// waits at `gate` before it answers.
private actor ACPPersistenceBackend: AgentRuntimeBackend {
    struct Observation: Sendable {
        let prompt: String
        let history: [AgentRuntimeMessage]
    }

    private let gate: ACPPersistenceGate?
    private let gatedPrompt: String?
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private(set) var observations: [Observation] = []

    init(gate: ACPPersistenceGate? = nil, gatedPrompt: String? = nil) {
        self.gate = gate
        self.gatedPrompt = gatedPrompt
    }

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
        observations.append(Observation(prompt: prompt, history: sessions[sessionID]?.history ?? []))
        if let gate, prompt == gatedPrompt {
            await gate.arriveAndWait()
        }
        let reply = "reply to: \(prompt)"
        if let snapshot = sessions[sessionID] {
            sessions[sessionID] = snapshot.replacingHistory(snapshot.history + [
                AgentRuntimeMessage(role: .user, content: prompt),
                AgentRuntimeMessage(role: .assistant, content: reply),
            ])
        }
        await onEvent(.content(reply))
        return DirectAgentResponse(text: reply, stopReason: "end_turn", modelID: "persistence-model")
    }
}
