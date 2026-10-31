//
//  ChatSessionSavedSessionTests.swift
//  ZenCODE
//
//  Saved-session operations of the shared controller through the terminal
//  chat: a `.session` file written in the current format before the session
//  operations moved to `ChatSessionController` still lists and loads, and
//  deleting a saved session also removes its `sessions.json` index entry.
//

import Foundation
import Testing
@testable import ZenCODECore

@TerminalChatActor
@Suite("Saved-session operations", .serialized)
struct ChatSessionSavedSessionTests {
    private struct Environment {
        let root: URL
        let workspace: URL
        let support: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("zencode-saved-sessions-\(UUID().uuidString)", isDirectory: true)
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            support = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        var workspacePath: String {
            URL(fileURLWithPath: workspace.path).standardizedFileURL.path
        }

        func runner() -> AgentCoreSessionRunner {
            let backend = CapturingACPBackend()
            return AgentCoreSessionRunner(
                backendFactory: { _, _ in backend },
                taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: support)
            )
        }

        @TerminalChatActor
        func chat(runner: AgentCoreSessionRunner) throws -> TerminalChat {
            TerminalChat(
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
        }
    }

    /// Runs `body` on the chat actor with a private support directory (never
    /// the real `~/.zencode`) and a UUID-named temporary workspace.
    private nonisolated func withEnvironment(
        _ body: @escaping @Sendable @TerminalChatActor (Environment) async throws -> Void
    ) async throws {
        let environment = try Environment()
        defer { environment.remove() }
        try await AppStorageDirectory.withSupportDirectoryURL(environment.support) {
            try await Task(name: "ZenCODE.Tests.saved-session-operations") { @TerminalChatActor in
                try await body(environment)
            }.value
        }
    }

    /// Output of `body` (system and failure messages of the chat).
    private static func captureOutput(
        of chat: TerminalChat,
        _ body: () async throws -> Void
    ) async rethrows -> String {
        chat.telegramImmediateCommandOutput = []
        defer { chat.telegramImmediateCommandOutput = nil }
        try await body()
        return chat.telegramImmediateCommandOutput?.joined() ?? ""
    }

    // MARK: - Compatibility

    @Test
    nonisolated func aSessionFileWrittenBeforeTheMigrationStillLoads() async throws {
        try await withEnvironment { environment in
            let agent = try #require(AgentProfileStore.defaultProfiles().first)
            let literal = Self.currentFormatPropertyList(
                workingDirectoryPath: environment.workspacePath,
                agent: agent
            )

            // The literal holds exactly the keys the current encoder writes for
            // the same session, and decodes to it.
            let expected = Self.expectedSession(
                workingDirectoryPath: environment.workspacePath,
                agent: agent
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let encoded = try PropertyListSerialization.propertyList(
                from: try encoder.encode(expected),
                format: nil
            )
            #expect(Self.keyPaths(of: literal) == Self.keyPaths(of: encoded))

            let fileURL = TerminalSessionStore.sessionFileURL(
                name: "compat session",
                workingDirectory: environment.workspace
            )
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try PropertyListSerialization.data(
                fromPropertyList: literal,
                format: .binary,
                options: 0
            ).write(to: fileURL)

            let listed = try TerminalSessionStore.savedSessions(for: environment.workspace)
            #expect(listed == [expected])
            let saved = try #require(listed.first)

            let runner = environment.runner()
            let chat = try environment.chat(runner: runner)
            let output = try await Self.captureOutput(of: chat) {
                try await chat.loadSavedSession(saved)
            }

            #expect(output.contains("\nRestored transcript:\n"))
            #expect(output.contains("Loaded session: compat session (4 messages).\n"))
            #expect(chat.sessionID == "terminal-compat")
            #expect(chat.activeSavedSessionName == "compat session")
            #expect(chat.activeSessionCacheKey == "terminal:compat:cache")
            #expect(chat.activeSessionHistory == expected.history)
            #expect(chat.activeSessionTranscript == expected.transcriptHistory)
            #expect(chat.activeSessionSystemPromptOverride == "Saved system prompt.")
            #expect(chat.activeSessionDynamicContextOverride == "Project notes.")
            #expect(chat.activePlan == expected.activePlan)
            #expect(chat.activeCheckpointTree == expected.checkpointTree)
            #expect(chat.selectedAgent == agent)
            #expect(chat.manualModelIDOverride == "test-model")
            #expect(chat.manualThinkingSelectionOverride == .high)
            let restoredGraph = try await runner.taskGraphSnapshot(sessionID: chat.sessionID)
            #expect(restoredGraph?.id == "graph-compat")
            #expect(restoredGraph?.tasks.map(\.id) == ["plan-compat-1"])

            await chat.stopTaskGraphObserver()
            await runner.shutdown()
        }
    }

    // MARK: - Index

    @Test
    nonisolated func deletingASavedSessionRemovesItsIndexEntry() async throws {
        try await withEnvironment { environment in
            let runner = environment.runner()
            let chat = try environment.chat(runner: runner)
            try await chat.createCurrentSession(discoverExternalTools: false)
            _ = try await chat.preloadCurrentModel(emitStatus: false)
            await chat.saveCurrentSession(named: "indexed")
            #expect(SavedSessionsStore().sessions().map(\.sessionName) == ["indexed"])

            let outcome = try await chat.chatSession.deleteSavedSessions(names: ["indexed"])

            #expect(outcome.notices == [.sessionDeleted(name: "indexed")])
            #expect(chat.activeSavedSessionName == nil)
            #expect(try TerminalSessionStore.savedSessions(for: environment.workspace).isEmpty)
            #expect(SavedSessionsStore().sessions().isEmpty)

            await chat.stopTaskGraphObserver()
            await runner.shutdown()
        }
    }

    // MARK: - Fixtures

    private nonisolated static let createdAt = Date(timeIntervalSince1970: 1_000)
    private nonisolated static let savedAt = Date(timeIntervalSince1970: 2_000)

    /// A `.session` written in the current format (version 5), spelled out
    /// key by key as `TerminalSessionStore.save` writes it.
    private nonisolated static func currentFormatPropertyList(
        workingDirectoryPath: String,
        agent: AgentProfile
    ) -> [String: Any] {
        let user: [String: Any] = [
            "role": "user",
            "content": "Where is the bug?",
            "attachments": [Any](),
            "toolCalls": [Any](),
        ]
        let toolCall: [String: Any] = [
            "role": "assistant",
            "content": "Reading the parser.",
            "reasoningContent": "The parser looks suspicious.",
            "attachments": [Any](),
            "toolCalls": [
                ["id": "call-1", "name": "files.read", "argumentsJSON": "{\"path\":\"Parser.swift\"}"],
            ],
        ]
        let toolResult: [String: Any] = [
            "role": "tool",
            "content": "struct Parser {}",
            "attachments": [Any](),
            "toolCalls": [Any](),
            "toolCallID": "call-1",
            "toolName": "files.read",
        ]
        let answer: [String: Any] = [
            "role": "assistant",
            "content": "In the parser.",
            "attachments": [Any](),
            "toolCalls": [Any](),
        ]
        let messages = [user, toolCall, toolResult, answer]
        let entryIDs = ["a1b2c3d4", "b2c3d4e5", "c3d4e5f6", "d4e5f6a7"]
        var entries: [[String: Any]] = []
        for (offset, message) in messages.enumerated() {
            var entry: [String: Any] = [
                "id": entryIDs[offset],
                "timestamp": savedAt,
                "kind": ["message": ["_0": message]],
            ]
            if offset > 0 {
                entry["parentID"] = entryIDs[offset - 1]
            }
            entries.append(entry)
        }

        return [
            "version": 5,
            "name": "compat session",
            "sessionID": "terminal-compat",
            "cacheKey": "terminal:compat:cache",
            "workingDirectoryPath": workingDirectoryPath,
            "createdAt": createdAt,
            "savedAt": savedAt,
            "modelID": "test-model",
            "agentID": agent.id,
            "agentName": agent.name,
            "selectedTools": [Any](),
            "selectedSkillIDs": [Any](),
            "thinkingSelection": "high",
            "contextWindow": [
                "usedTokens": 1_200,
                "maxTokens": 8_000,
                "modelID": "local/test-model",
                "isApproximate": true,
            ],
            "systemPrompt": "Saved system prompt.",
            "dynamicContext": "Project notes.",
            "history": messages,
            "transcriptHistory": messages,
            "activePlan": [
                "id": "plan-compat",
                "originalGoal": "Fix the parser",
                "consolidatedText": "1. Read the parser.",
                "createdAt": createdAt,
                "isApproved": true,
                "points": [
                    [
                        "id": "plan-compat-1",
                        "text": "Read the parser",
                        "status": "pending",
                        "dependsOn": [Any](),
                        "hasExplicitDependencies": false,
                    ],
                ],
            ],
            "taskGraph": [
                "schemaVersion": 1,
                "id": "graph-compat",
                "source": ["kind": "plan", "planID": "plan-compat"],
                "state": "active",
                "revision": 2,
                "tasks": [
                    [
                        "id": "plan-compat-1",
                        "title": "Read the parser",
                        "order": 1,
                        "status": "pending",
                        "priority": "normal",
                        "dependsOn": [Any](),
                        "execution": ["executor": "coordinator", "fileScopes": [Any]()],
                        "acceptanceCriteria": [Any](),
                        "attempts": [Any](),
                        "revision": 1,
                        "complexity": 5,
                        "createdAt": createdAt,
                        "updatedAt": savedAt,
                    ],
                ],
                "createdAt": createdAt,
                "updatedAt": savedAt,
            ],
            "checkpointTree": [
                "version": 1,
                "sessionID": "terminal-compat",
                "entries": entries,
                "activeLeafID": entryIDs[entryIDs.count - 1],
            ],
        ]
    }

    /// The session ``currentFormatPropertyList(workingDirectoryPath:agent:)``
    /// stands for, built with the current initializers.
    private nonisolated static func expectedSession(
        workingDirectoryPath: String,
        agent: AgentProfile
    ) -> TerminalSavedSession {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Where is the bug?"),
            AgentRuntimeMessage(
                role: .assistant,
                content: "Reading the parser.",
                reasoningContent: "The parser looks suspicious.",
                toolCalls: [
                    AgentRuntimeToolCall(
                        id: "call-1",
                        name: "files.read",
                        argumentsJSON: "{\"path\":\"Parser.swift\"}"
                    ),
                ]
            ),
            AgentRuntimeMessage(
                role: .tool,
                content: "struct Parser {}",
                toolCallID: "call-1",
                toolName: "files.read"
            ),
            AgentRuntimeMessage(role: .assistant, content: "In the parser."),
        ]
        let entryIDs = ["a1b2c3d4", "b2c3d4e5", "c3d4e5f6", "d4e5f6a7"]
        let entries = messages.enumerated().map { offset, message in
            SessionCheckpointEntry(
                id: entryIDs[offset],
                parentID: offset > 0 ? entryIDs[offset - 1] : nil,
                timestamp: savedAt,
                kind: .message(message)
            )
        }
        return TerminalSavedSession(
            name: "compat session",
            sessionID: "terminal-compat",
            cacheKey: "terminal:compat:cache",
            workingDirectoryPath: workingDirectoryPath,
            createdAt: createdAt,
            savedAt: savedAt,
            modelID: "test-model",
            agentID: agent.id,
            agentName: agent.name,
            selectedTools: [],
            selectedSkillIDs: [],
            thinkingSelection: "high",
            contextWindow: TerminalSavedSessionContextWindow(
                usedTokens: 1_200,
                maxTokens: 8_000,
                modelID: "local/test-model",
                isApproximate: true
            ),
            systemPrompt: "Saved system prompt.",
            dynamicContext: "Project notes.",
            history: messages,
            transcriptHistory: messages,
            activePlan: TerminalSessionPlan(
                id: "plan-compat",
                originalGoal: "Fix the parser",
                consolidatedText: "1. Read the parser.",
                createdAt: createdAt,
                isApproved: true,
                points: [
                    TerminalSessionPlanPoint(id: "plan-compat-1", text: "Read the parser"),
                ]
            ),
            taskGraph: TaskGraphSnapshot(
                id: "graph-compat",
                source: .plan(planID: "plan-compat"),
                state: .active,
                revision: 2,
                tasks: [
                    TaskRecord(
                        id: "plan-compat-1",
                        title: "Read the parser",
                        order: 1,
                        createdAt: createdAt,
                        updatedAt: savedAt
                    ),
                ],
                createdAt: createdAt,
                updatedAt: savedAt
            ),
            checkpointTree: SessionCheckpointTree(
                sessionID: "terminal-compat",
                entries: entries,
                activeLeafID: entryIDs[entryIDs.count - 1]
            )
        )
    }

    /// Every dictionary key path of a property list (`a.b`, arrays as `[]`).
    private nonisolated static func keyPaths(of value: Any, prefix: String = "") -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set<String>()) { paths, element in
                let path = prefix.isEmpty ? element.key : "\(prefix).\(element.key)"
                paths.insert(path)
                paths.formUnion(keyPaths(of: element.value, prefix: path))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { paths, element in
                paths.formUnion(keyPaths(of: element, prefix: "\(prefix)[]"))
            }
        }
        return []
    }
}
