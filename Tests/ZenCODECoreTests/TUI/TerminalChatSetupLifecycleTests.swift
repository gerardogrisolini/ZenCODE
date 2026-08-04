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
