//
//  ACPSessionPersistenceTests+Management.swift
//  ZenCODE
//
//  Tests of the other ways a saved ACP session is reached: restoring nothing,
//  turns from Telegram, the `/sessions` controller, and `session/delete`.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

extension ACPSessionPersistenceTests {
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
            let result = try #require(wire.message(at: responseIndex)?["result"]?.objectValue)
            #expect(result["sessionId"] == nil)
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

            let result = try #require(wire.result(id: 1))
            #expect(Set(result.keys) == Set([
                "protocolVersion",
                "agentCapabilities",
                "authMethods",
                "agentInfo",
                "_meta",
            ]))
            #expect(result["configOptions"] == nil)
            let capabilities = result["agentCapabilities"]?.objectValue
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

    /// ACP v1 puts `sessionId` in the response to `session/new`, but not in
    /// the responses to `session/load` or `session/resume`. The selected agent
    /// remains available as informational `_meta` without adding non-schema
    /// fields to those responses.
    @Test
    func sessionLifecycleResponseShapesFollowV1AndKeepAgentMetadata() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(
                wire: wire,
                backend: ACPPersistenceBackend(),
                workspace: workspace
            )

            await bridge.handleMessage(Self.newSessionRequest(
                id: 1,
                workspace: workspace,
                extraParams: ["agentId": Self.customAgent.id]
            ))
            let newResult = try #require(wire.result(id: 1))
            #expect(Set(newResult.keys) == Set(["sessionId", "modes", "configOptions", "_meta"]))
            let sessionID = try #require(wire.sessionID(ofResponse: 1))
            let newMeta = try #require(newResult["_meta"]?.objectValue)
            #expect(newMeta["models"] != nil)
            #expect(newMeta["agentId"] == .string(Self.customAgent.id))
            #expect(newMeta["agentName"] == .string(Self.customAgent.name))

            await bridge.handleMessage(Self.restoreRequest(
                "session/load",
                id: 2,
                sessionID: sessionID,
                workspace: workspace
            ))
            let loadResult = try #require(wire.result(id: 2))
            #expect(Set(loadResult.keys) == Set(["modes", "configOptions", "_meta"]))
            #expect(loadResult["sessionId"] == nil)
            let loadMeta = try #require(loadResult["_meta"]?.objectValue)
            #expect(loadMeta["models"] != nil)
            #expect(loadMeta["agentId"] == .string(Self.customAgent.id))
            #expect(loadMeta["agentName"] == .string(Self.customAgent.name))

            await bridge.handleMessage(Self.restoreRequest(
                "session/resume",
                id: 3,
                sessionID: sessionID,
                workspace: workspace
            ))
            let resumeResult = try #require(wire.result(id: 3))
            #expect(Set(resumeResult.keys) == Set(["modes", "configOptions", "_meta"]))
            #expect(resumeResult["sessionId"] == nil)
            let resumeMeta = try #require(resumeResult["_meta"]?.objectValue)
            #expect(resumeMeta["models"] != nil)
            #expect(resumeMeta["agentId"] == .string(Self.customAgent.id))
            #expect(resumeMeta["agentName"] == .string(Self.customAgent.name))

            #expect(await bridge.selectedAgentIDForTesting(sessionID: sessionID) == Self.customAgent.id)
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
    /// internal error, so the client learns it was not deleted. A read-only
    /// directory is what keeps the file; it does not keep it from a process
    /// whose privileges override the directory's permissions (root, as in the
    /// Linux CI container), where the deletion rightly succeeds, so the test
    /// runs only where it holds.
    @Test(.enabled(
        if: try ACPSessionPersistenceTests.readOnlyDirectoryKeepsItsFiles(),
        "A read-only directory does not keep its files from this process (root)."
    ))
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

    /// Whether this process cannot remove a file from a directory with mode
    /// `0o555`, the condition ``aDeletionThatCannotRemoveTheFileAnswersAnInternalError()``
    /// builds. It is tried on a file of a UUID directory rather than assumed:
    /// a superuser removes the file anyway.
    private static func readOnlyDirectoryKeepsItsFiles() throws -> Bool {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("acp-session-persistence-read-only-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("probe")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? fileManager.removeItem(at: directory)
        }
        try Data().write(to: file)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        do {
            try fileManager.removeItem(at: file)
            return false
        } catch {
            return true
        }
    }
}
