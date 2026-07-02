//
//  MLXTerminalSessionStoreTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite(.serialized)
struct MLXTerminalSessionStoreTests {
    @Test
    func savesBinarySessionForProject() throws {
        let supportDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let projectURL = supportDirectory
            .appendingPathComponent("Project A", isDirectory: true)
        let session = sampleSession(
            name: "daily checkpoint",
            workingDirectory: projectURL
        )

        let fileURL = try MLXTerminalSessionStore.save(
            session,
            supportDirectoryURL: supportDirectory
        )
        let storedData = try Data(contentsOf: fileURL)
        let storedPrefix = String(
            data: storedData.prefix(6),
            encoding: .utf8
        )

        #expect(fileURL.pathExtension == MLXTerminalSessionStore.fileExtension)
        #expect(storedPrefix == "bplist")
        #expect(try MLXTerminalSessionStore.load(from: fileURL) == session)
    }

    @Test
    func listsOnlySessionsForRequestedProject() throws {
        let supportDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let firstProject = supportDirectory
            .appendingPathComponent("First", isDirectory: true)
        let secondProject = supportDirectory
            .appendingPathComponent("Second", isDirectory: true)

        let firstSession = sampleSession(
            name: "first",
            workingDirectory: firstProject
        )
        let secondSession = sampleSession(
            name: "second",
            workingDirectory: secondProject
        )
        _ = try MLXTerminalSessionStore.save(
            firstSession,
            supportDirectoryURL: supportDirectory
        )
        _ = try MLXTerminalSessionStore.save(
            secondSession,
            supportDirectoryURL: supportDirectory
        )

        let listedSessions = try MLXTerminalSessionStore.savedSessions(
            for: firstProject,
            supportDirectoryURL: supportDirectory
        )

        #expect(listedSessions.map(\.name) == ["first"])
    }

    @Test
    func deletesSavedSessionByName() throws {
        let supportDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let projectURL = supportDirectory
            .appendingPathComponent("Project", isDirectory: true)
        let session = sampleSession(
            name: "daily checkpoint",
            workingDirectory: projectURL
        )
        _ = try MLXTerminalSessionStore.save(
            session,
            supportDirectoryURL: supportDirectory
        )

        let didDelete = try MLXTerminalSessionStore.delete(
            name: "daily checkpoint",
            workingDirectory: projectURL,
            supportDirectoryURL: supportDirectory
        )
        let sessions = try MLXTerminalSessionStore.savedSessions(
            for: projectURL,
            supportDirectoryURL: supportDirectory
        )

        #expect(didDelete)
        #expect(sessions.isEmpty)
    }

    @Test
    func agentCoreSessionRunnerSavesRuntimeSnapshot() async throws {
        let supportDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let runner = AgentCoreSessionRunner()
        let projectURL = supportDirectory
            .appendingPathComponent("Project", isDirectory: true)
        let snapshot = AgentRuntimeSessionSnapshot(
            sessionID: "agent-core-test",
            workingDirectoryPath: projectURL.path,
            systemPrompt: "System",
            cacheKey: "cache-test",
            history: [
                AgentRuntimeMessage(role: .user, content: "ciao"),
                AgentRuntimeMessage(role: .assistant, content: "ciao a te")
            ],
            allowedToolNames: ["local.exec"],
            thinkingSelection: .enabled,
            preserveThinking: true
        )

        let savedSession = try await runner.saveSession(
            id: snapshot.sessionID,
            named: " snapshot save ",
            fallbackSnapshot: snapshot,
            fallbackCreatedAt: Date(timeIntervalSince1970: 10),
            modelID: "model-test",
            agentID: "default",
            agentName: "Default",
            selectedTools: ["shell"],
            selectedSkillIDs: ["skill-a"],
            thinkingSelection: nil,
            contextWindow: MLXTerminalSavedSessionContextWindow(
                usedTokens: 32,
                maxTokens: 128,
                modelID: "model-test",
                isApproximate: true
            ),
            transcriptHistory: [
                AgentRuntimeMessage(role: .user, content: "visible ciao")
            ],
            supportDirectoryURL: supportDirectory
        )
        let listedSessions = try runner.savedSessions(
            for: projectURL,
            supportDirectoryURL: supportDirectory
        )

        #expect(savedSession.name == "snapshot save")
        #expect(savedSession.sessionID == "agent-core-test")
        #expect(savedSession.history.map(\.content) == ["ciao", "ciao a te"])
        #expect(savedSession.displayHistory.map(\.content) == ["visible ciao"])
        #expect(savedSession.thinkingSelection == AgentThinkingSelection.enabled.rawValue)
        #expect(listedSessions.map(\.name) == ["snapshot save"])
    }

    @Test
    func messageCountUsesTranscriptWhenAvailable() {
        let projectURL = temporaryDirectory()
            .appendingPathComponent("Project", isDirectory: true)
        let session = sampleSession(
            name: "compacted",
            workingDirectory: projectURL,
            transcriptHistory: [
                AgentRuntimeMessage(role: .user, content: "first"),
                AgentRuntimeMessage(role: .assistant, content: "first answer"),
                AgentRuntimeMessage(role: .user, content: "second"),
                AgentRuntimeMessage(role: .assistant, content: "second answer")
            ]
        )

        #expect(session.history.filter { $0.role != .system }.count == 3)
        #expect(session.messageCount == 4)
        #expect(session.displayHistory.map(\.content) == [
            "first",
            "first answer",
            "second",
            "second answer"
        ])
    }

    @Test
    func displayHistoryFallsBackToCompactionSummary() {
        let projectURL = temporaryDirectory()
            .appendingPathComponent("Project", isDirectory: true)
        let session = MLXTerminalSavedSession(
            name: "old compacted",
            sessionID: "terminal-test",
            cacheKey: "cache-test",
            workingDirectoryPath: projectURL.path,
            createdAt: Date(timeIntervalSince1970: 10),
            savedAt: Date(timeIntervalSince1970: 20),
            modelID: "model-test",
            agentID: "default",
            agentName: "Default",
            selectedTools: [],
            selectedSkillIDs: [],
            thinkingSelection: nil,
            systemPrompt: """
            Base prompt

            Conversation memory summary from earlier turns.
            Preserve the facts, decisions, files, code directions, and unresolved requests below as continuing context.
            User request: keep compacted sessions recoverable.
            """,
            history: [
                AgentRuntimeMessage(role: .user, content: "recent")
            ]
        )

        let displayHistory = TerminalChat.savedSessionDisplayHistory(session)

        #expect(displayHistory.count == 2)
        #expect(displayHistory[0].role == .assistant)
        #expect(displayHistory[0].content.contains("Restored compacted context"))
        #expect(displayHistory[0].content.contains("keep compacted sessions recoverable"))
        #expect(displayHistory[1].content == "recent")
    }

    @Test
    func filenameStemSanitizesSessionName() {
        #expect(
            MLXTerminalSessionStore.filenameStem(for: " daily/checkpoint ") == "daily_checkpoint"
        )
        #expect(MLXTerminalSessionStore.filenameStem(for: "///") == "session")
    }

    private func sampleSession(
        name: String,
        workingDirectory: URL,
        transcriptHistory: [AgentRuntimeMessage]? = nil
    ) -> MLXTerminalSavedSession {
        MLXTerminalSavedSession(
            name: name,
            sessionID: "terminal-test",
            cacheKey: "cache-test",
            workingDirectoryPath: workingDirectory.path,
            createdAt: Date(timeIntervalSince1970: 10),
            savedAt: Date(timeIntervalSince1970: 20),
            modelID: "model-test",
            agentID: "default",
            agentName: "Default",
            selectedTools: [
                "shell",
                TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools")
            ],
            selectedSkillIDs: ["skill-a"],
            thinkingSelection: "on",
            contextWindow: MLXTerminalSavedSessionContextWindow(
                usedTokens: 2_048,
                maxTokens: 65_536,
                modelID: "model-test",
                isApproximate: false
            ),
            systemPrompt: "System",
            history: [
                AgentRuntimeMessage(role: .user, content: "ciao"),
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [
                        AgentRuntimeToolCall(
                            id: "call_1",
                            name: "local.exec",
                            argumentsJSON: #"{"command":"pwd"}"#
                        )
                    ]
                ),
                AgentRuntimeMessage(
                    role: .tool,
                    content: "/tmp",
                    toolCallID: "call_1"
                )
            ],
            transcriptHistory: transcriptHistory
        )
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "mlx-terminal-session-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
    }
}
