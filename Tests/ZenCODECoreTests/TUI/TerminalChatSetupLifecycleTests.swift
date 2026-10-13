//
//  TerminalChatSetupLifecycleTests.swift
//  ZenCODETests
//

import Foundation
import Testing
@testable import ZenCODECore

@TerminalChatActor
@Suite
struct TerminalChatSetupLifecycleTests {
    @Test
    func setupCommandIsVisibleAndUnavailableDuringGeneration() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false
        ).map(\.command)

        #expect(commands.contains("/setup"))
        #expect(TerminalChat.isKnownSlashCommand("/setup"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/setup"))
    }

    @Test
    func setupCommandRequestsRestartOnlyForInteractiveTerminal() async throws {
        let interactive = TerminalChat(
            configuration: try configuration(),
            stdinIsTerminal: true
        )
        switch await interactive.submittedLineAction("/setup") {
        case .requestSetup:
            break
        default:
            Issue.record("Expected /setup to request an interactive runtime restart")
        }

        let piped = TerminalChat(
            configuration: try configuration(),
            stdinIsTerminal: false
        )
        switch await piped.submittedLineAction("/setup") {
        case .continueChat:
            break
        default:
            Issue.record("Expected piped /setup to leave the chat running")
        }
    }

    @Test
    func runtimeSetupSnapshotRestoresConversationButNotConfigurationState() async throws {
        let oldHistory = [
            AgentRuntimeMessage(role: .user, content: "Before setup"),
            AgentRuntimeMessage(role: .assistant, content: "Still here")
        ]
        let transcript = oldHistory + [
            AgentRuntimeMessage(role: .system, content: "Visible status")
        ]
        let tree = SessionCheckpointTree.fromLinearHistory(
            transcript,
            sessionID: "terminal-existing"
        )
        let snapshot = TerminalChatResumeSnapshot(
            sessionID: "terminal-existing",
            cacheKey: "cache-existing",
            history: oldHistory,
            transcriptHistory: transcript,
            activePlan: nil,
            checkpointTree: tree,
            savedSessionName: "saved-before-setup"
        )
        let newConfiguration = try configuration(modelID: "provider/new-model")
        let chat = TerminalChat(
            configuration: newConfiguration,
            stdinIsTerminal: true,
            runtimeSetupResumeSnapshot: snapshot
        )

        chat.applyRuntimeSetupResumeSnapshotIfNeeded()

        #expect(chat.sessionID == "terminal-existing")
        #expect(chat.activeSessionCacheKey == "cache-existing")
        #expect(chat.activeSessionHistory == oldHistory)
        #expect(chat.activeSessionTranscript == transcript)
        #expect(chat.activeCheckpointTree == tree)
        #expect(chat.activeSavedSessionName == "saved-before-setup")
        #expect(chat.manualModelIDOverride == "provider/new-model")
        #expect(chat.activeSessionSystemPromptOverride == nil)
        #expect(chat.interactiveReader.commandHistory.isEmpty)
    }

    @Test
    func runtimeSetupRoundTripsPromptHistoryWithoutImportingConversationMessages() async throws {
        let original = TerminalChat(configuration: try configuration(), stdinIsTerminal: true)
        original.activeSessionHistory = [
            AgentRuntimeMessage(role: .user, content: "Conversation-only message")
        ]
        let inputs = (0..<205).map { "prompt \($0)" } + ["/new", "/sessions list", "/setup"]
        for line in inputs {
            original.interactiveReader.recordHistory(line)
        }
        let snapshot = await original.makeRuntimeSetupResumeSnapshot()
        #expect(snapshot.commandHistory == inputs)
        #expect(snapshot.history == original.activeSessionHistory)

        let resumed = TerminalChat(
            configuration: try configuration(modelID: "provider/new-model"),
            stdinIsTerminal: true,
            runtimeSetupResumeSnapshot: snapshot
        )
        #expect(resumed.interactiveReader !== original.interactiveReader)
        resumed.applyRuntimeSetupResumeSnapshotIfNeeded()
        #expect(resumed.interactiveReader.commandHistory == inputs)
        #expect(resumed.activeSessionHistory == original.activeSessionHistory)

        resumed.interactiveReader.recordHistory("after setup")
        resumed.interactiveReader.recordHistory("/setup")
        let nextSnapshot = await resumed.makeRuntimeSetupResumeSnapshot()
        let resumedAgain = TerminalChat(
            configuration: try configuration(),
            stdinIsTerminal: true,
            runtimeSetupResumeSnapshot: nextSnapshot
        )
        resumedAgain.applyRuntimeSetupResumeSnapshotIfNeeded()
        #expect(resumedAgain.interactiveReader.commandHistory == inputs + ["after setup", "/setup"])
        #expect(snapshot.commandHistory == inputs)
        #expect(original.interactiveReader.commandHistory == inputs)

        var editor = TerminalPromptEditor()
        let context = TerminalPromptEditorContext(
            history: resumedAgain.interactiveReader.commandHistory,
            suggestions: [TerminalCommandSuggestion(command: "/setup", summary: "configure zen")]
        )
        #expect(editor.apply(.up, context: context) == .changed)
        #expect(editor.apply(.enter, context: context) == .submitted("/setup"))

        // No resume snapshot is supplied on a new launch: neither conversation
        // history nor a prior reader can populate its prompt history.
        let freshLaunch = TerminalChat(configuration: try configuration(), stdinIsTerminal: true)
        freshLaunch.applyRuntimeSetupResumeSnapshotIfNeeded()
        #expect(freshLaunch.interactiveReader.commandHistory.isEmpty)
    }

    @Test
    func newAndLoadedConversationsKeepTheSameProcessPromptHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptHistoryLifecycle-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = CapturingACPBackend()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend },
            taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: root.appendingPathComponent("support"))
        )
        let chat = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "test-model",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [AgentSettingsModelManifest(
                    id: "test-model", kind: .remoteAPI, modelID: "local/test-model"
                )],
                workingDirectory: workspace
            ),
            stdinIsTerminal: false,
            sessionRunner: runner
        )
        let reader = chat.interactiveReader
        let inputs = ["before new", "/new"]
        inputs.forEach { reader.recordHistory($0) }
        let originalSessionID = chat.sessionID

        do {
            await chat.startNewSession()
            #expect(chat.sessionID != originalSessionID)
            _ = try #require(await runner.snapshotSession(id: chat.sessionID))
            #expect(chat.interactiveReader === reader)
            #expect(reader.commandHistory == inputs)

            reader.recordHistory("/sessions list")
            let savedHistory = [AgentRuntimeMessage(role: .user, content: "Saved conversation only")]
            let savedSession = TerminalSavedSession(
                name: "other-conversation", sessionID: "terminal-loaded", cacheKey: nil,
                workingDirectoryPath: workspace.path, createdAt: Date(), savedAt: Date(),
                modelID: "test-model", agentID: nil, agentName: nil, selectedTools: [],
                selectedSkillIDs: [], thinkingSelection: nil, systemPrompt: "Test",
                history: savedHistory,
                checkpointTree: SessionCheckpointTree.fromLinearHistory(
                    savedHistory, sessionID: "terminal-loaded"
                )
            )
            try await chat.loadSavedSession(savedSession)
            #expect(chat.sessionID == savedSession.sessionID)
            #expect(chat.activeSessionHistory == savedSession.history)
            #expect(chat.interactiveReader === reader)
            #expect(reader.commandHistory == inputs + ["/sessions list"])
            let setupSnapshot = await chat.makeRuntimeSetupResumeSnapshot()
            #expect(setupSnapshot.commandHistory == inputs + ["/sessions list"])
        } catch {
            await chat.stopTaskGraphObserver()
            await runner.shutdown()
            throw error
        }
        await chat.stopTaskGraphObserver()
        await runner.shutdown()
    }

    private func configuration(
        modelID: String = "provider/model"
    ) throws -> AgentConfiguration {
        try AgentConfiguration(
            hostedModelID: modelID,
            explicitModelID: modelID,
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [],
            workingDirectory: FileManager.default.temporaryDirectory
        )
    }
}
