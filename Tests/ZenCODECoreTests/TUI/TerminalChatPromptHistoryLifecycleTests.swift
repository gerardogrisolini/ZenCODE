//
//  TerminalChatPromptHistoryLifecycleTests.swift
//  ZenCODETests
//
//  The terminal's prompt history across session changes, and the setup that
//  is no longer a command of the chat (`zen --setup` is its only way in).
//

import Foundation
import Testing
@testable import ZenCODECore

@ChatSessionActor
@Suite
struct TerminalChatPromptHistoryLifecycleTests {
    @Test
    func setupIsAnUnknownCommandInTheTerminal() async throws {
        for stdinIsTerminal in [true, false] {
            let chat = TerminalChat(
                configuration: try configuration(),
                stdinIsTerminal: stdinIsTerminal,
                telegramTransportFactory: nil,
                renderCoordinator: TerminalChatRenderCoordinator(
                    stdinIsTerminal: false,
                    standardOutput: nil,
                    standardError: nil,
                    // Not terminals: the failure message is written uncolored.
                    standardOutputIsTerminal: false,
                    standardErrorIsTerminal: false,
                    cursorTopology: nil,
                    capturesWrites: true,
                    streamingFlushDelay: nil,
                    columnWidthProvider: { 100 }
                )
            )
            for line in ["/setup", "/setup now"] {
                switch await chat.submittedLineAction(line) {
                case .continueChat:
                    break
                default:
                    Issue.record("Expected \(line) to leave the chat running (stdinIsTerminal: \(stdinIsTerminal))")
                }
            }
            let written = await chat.renderCoordinator.capturedWriteEvents().map(\.text).joined()
            #expect(written.components(separatedBy: ChatCommandRegistry.unknownCommandMessage(for: "/setup")).count == 3)
            await chat.sessionHost.shutdown()
        }
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
                selectedSkillNames: [], thinkingSelection: nil, systemPrompt: "Test",
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
        } catch {
            await chat.stopTaskGraphObserver()
            await runner.shutdown()
            throw error
        }
        await chat.stopTaskGraphObserver()
        await runner.shutdown()
    }

    @Test
    func aNewLaunchStartsWithAnEmptyPromptHistory() async throws {
        let chat = TerminalChat(configuration: try configuration(), stdinIsTerminal: true)
        #expect(chat.interactiveReader.commandHistory.isEmpty)
        #expect(chat.sessionID.hasPrefix("terminal-"))
        await chat.sessionHost.shutdown()
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
