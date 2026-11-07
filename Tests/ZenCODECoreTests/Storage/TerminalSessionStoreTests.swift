//
//  TerminalSessionStoreTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite(.serialized)
struct TerminalSessionStoreTests {
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

        let fileURL = try TerminalSessionStore.save(
            session,
            supportDirectoryURL: supportDirectory
        )
        let storedData = try Data(contentsOf: fileURL)
        let storedPrefix = String(
            data: storedData.prefix(6),
            encoding: .utf8
        )

        #expect(fileURL.pathExtension == TerminalSessionStore.fileExtension)
        #expect(storedPrefix == "bplist")
        #expect(try TerminalSessionStore.load(from: fileURL) == session)
    }

    @Test
    func savesAndLoadsQueuedPlansInOrder() throws {
        let supportDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }
        func plan(_ goal: String, createdAt: TimeInterval) -> TerminalSessionPlan {
            TerminalSessionPlan(
                originalGoal: goal,
                consolidatedText: "\(goal). Implement and validate.",
                createdAt: Date(timeIntervalSince1970: createdAt),
                isApproved: false,
                points: [
                    TerminalSessionPlanPoint(id: "\(goal)-1", text: "Do \(goal)")
                ]
            )
        }
        let active = plan("First step", createdAt: 30)
        let queued = [plan("Second step", createdAt: 31), plan("Third step", createdAt: 32)]
        let session = sampleSession(
            name: "queued work",
            workingDirectory: supportDirectory.appendingPathComponent("Project"),
            activePlan: active,
            queuedPlans: queued
        )

        let fileURL = try TerminalSessionStore.save(
            session,
            supportDirectoryURL: supportDirectory
        )
        let loaded = try TerminalSessionStore.load(from: fileURL)

        #expect(loaded.version == TerminalSavedSession.currentVersion)
        #expect(loaded.activePlan == active)
        #expect(loaded.queuedPlans == queued)
        #expect(loaded == session)
    }

    @Test
    func sessionWithoutQueuedPlansEncodesNoKeyAndDecodesToNil() throws {
        let supportDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }
        let session = sampleSession(
            name: "no queue",
            workingDirectory: supportDirectory.appendingPathComponent("Project")
        )

        // A nil queue is omitted from the encoded form, so sessions saved
        // without a queue stay byte-compatible with files written before it.
        let encoded = try PropertyListEncoder().encode(session)
        let propertyList = try #require(
            try PropertyListSerialization.propertyList(
                from: encoded,
                format: nil
            ) as? [String: Any]
        )
        #expect(propertyList["queuedPlans"] == nil)

        let fileURL = try TerminalSessionStore.save(
            session,
            supportDirectoryURL: supportDirectory
        )
        let loaded = try TerminalSessionStore.load(from: fileURL)
        #expect(loaded.queuedPlans == nil)
        #expect(loaded == session)
    }

    @Test
    func decodesSnapshotWrittenBeforeQueuedPlansExisted() throws {
        let checkpointTreeData = try PropertyListEncoder().encode(
            SessionCheckpointTree.fromLinearHistory([], sessionID: "terminal-no-queue")
        )
        let checkpointTreeDict = try PropertyListSerialization.propertyList(
            from: checkpointTreeData,
            format: nil
        ) as! [String: Any]
        let propertyList: [String: Any] = [
            "version": TerminalSavedSession.currentVersion,
            "name": "no queue",
            "sessionID": "terminal-no-queue",
            "workingDirectoryPath": "/tmp/no-queue-project",
            "createdAt": Date(timeIntervalSince1970: 10),
            "savedAt": Date(timeIntervalSince1970: 20),
            "selectedTools": [],
            "selectedSkillIDs": [],
            "history": [],
            "checkpointTree": checkpointTreeDict,
            "activePlan": [
                "originalGoal": "Existing goal",
                "consolidatedText": "Existing consolidated plan",
                "createdAt": Date(timeIntervalSince1970: 15),
                "isApproved": true,
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )

        let decoded = try PropertyListDecoder().decode(TerminalSavedSession.self, from: data)

        #expect(decoded.activePlan?.originalGoal == "Existing goal")
        #expect(decoded.queuedPlans == nil)
    }

    @Test
    func savesAndLoadsTaskGraphSnapshot() throws {
        let supportDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let now = Date(timeIntervalSince1970: 40)
        let graph = TaskGraphSnapshot(
            id: "plan-test",
            source: .plan(planID: "plan-test"),
            state: .active,
            revision: 3,
            tasks: [
                TaskRecord(
                    id: "plan-test-1",
                    title: "Persist graph",
                    order: 1,
                    createdAt: now,
                    updatedAt: now
                )
            ],
            createdAt: now,
            updatedAt: now
        )
        let session = sampleSession(
            name: "task graph",
            workingDirectory: supportDirectory.appendingPathComponent("Project"),
            taskGraph: graph
        )

        let fileURL = try TerminalSessionStore.save(
            session,
            supportDirectoryURL: supportDirectory
        )
        let loaded = try TerminalSessionStore.load(from: fileURL)

        #expect(loaded.version == TerminalSavedSession.currentVersion)
        #expect(loaded.taskGraph == graph)
    }

    @Test
    func rejectsVersionThreeSnapshot() throws {
        let supportDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let fileURL = supportDirectory.appendingPathComponent("v3.session")
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        let propertyList: [String: Any] = [
            "version": 3,
            "name": "v3",
            "sessionID": "terminal-v3",
            "workingDirectoryPath": "/tmp/v3-project",
            "createdAt": Date(timeIntervalSince1970: 10),
            "savedAt": Date(timeIntervalSince1970: 20),
            "selectedTools": [],
            "selectedSkillIDs": [],
            "history": [],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
        try data.write(to: fileURL)

        #expect(throws: Error.self) {
            try TerminalSessionStore.load(from: fileURL)
        }
    }

    @Test
    func decodesLegacyPlanWithoutStructuredPoints() throws {
        let checkpointTreeData = try PropertyListEncoder().encode(
            SessionCheckpointTree.fromLinearHistory([], sessionID: "terminal-legacy-plan")
        )
        let checkpointTreeDict = try PropertyListSerialization.propertyList(
            from: checkpointTreeData,
            format: nil
        ) as! [String: Any]

        let legacyPropertyList: [String: Any] = [
            "version": TerminalSavedSession.currentVersion,
            "name": "legacy plan",
            "sessionID": "terminal-legacy-plan",
            "workingDirectoryPath": "/tmp/legacy-project",
            "createdAt": Date(timeIntervalSince1970: 10),
            "savedAt": Date(timeIntervalSince1970: 20),
            "selectedTools": [],
            "selectedSkillIDs": [],
            "history": [],
            "checkpointTree": checkpointTreeDict,
            "activePlan": [
                "originalGoal": "Legacy goal",
                "consolidatedText": "Legacy consolidated plan",
                "createdAt": Date(timeIntervalSince1970: 15),
                "isApproved": true,
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: legacyPropertyList,
            format: .binary,
            options: 0
        )

        let decoded = try PropertyListDecoder().decode(TerminalSavedSession.self, from: data)

        #expect(decoded.activePlan?.originalGoal == "Legacy goal")
        #expect(decoded.activePlan?.points == [])
        #expect(decoded.activePlan?.isApproved == true)
    }

    @Test
    func decodesLegacySnapshotWithoutActivePlan() throws {
        let checkpointTreeData = try PropertyListEncoder().encode(
            SessionCheckpointTree.fromLinearHistory([], sessionID: "terminal-legacy")
        )
        let checkpointTreeDict = try PropertyListSerialization.propertyList(
            from: checkpointTreeData,
            format: nil
        ) as! [String: Any]

        let legacyPropertyList: [String: Any] = [
            "version": TerminalSavedSession.currentVersion,
            "name": "legacy",
            "sessionID": "terminal-legacy",
            "workingDirectoryPath": "/tmp/legacy-project",
            "createdAt": Date(timeIntervalSince1970: 10),
            "savedAt": Date(timeIntervalSince1970: 20),
            "selectedTools": [],
            "selectedSkillIDs": [],
            "history": [],
            "checkpointTree": checkpointTreeDict,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: legacyPropertyList,
            format: .binary,
            options: 0
        )

        let decoded = try PropertyListDecoder().decode(TerminalSavedSession.self, from: data)

        #expect(decoded.name == "legacy")
        #expect(decoded.activePlan == nil)
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
        _ = try TerminalSessionStore.save(
            firstSession,
            supportDirectoryURL: supportDirectory
        )
        _ = try TerminalSessionStore.save(
            secondSession,
            supportDirectoryURL: supportDirectory
        )

        let listedSessions = try TerminalSessionStore.savedSessions(
            for: firstProject,
            supportDirectoryURL: supportDirectory
        )

        #expect(listedSessions.map(\.name) == ["first"])
    }

    @Test
    func migratesValidSessionFileWithNonCurrentName() throws {
        let supportDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let projectURL = supportDirectory
            .appendingPathComponent("Project", isDirectory: true)
        let session = sampleSession(
            name: "migrated session",
            workingDirectory: projectURL
        )
        let directoryURL = TerminalSessionStore.sessionsDirectoryURL(
            for: projectURL,
            supportDirectoryURL: supportDirectory
        )
        let sourceURL = directoryURL.appendingPathComponent("stored-record")
        let destinationURL = TerminalSessionStore.sessionFileURL(
            name: session.name,
            workingDirectory: projectURL,
            supportDirectoryURL: supportDirectory
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try PropertyListEncoder().encode(session).write(to: sourceURL)

        let sessions = try TerminalSessionStore.savedSessions(
            for: projectURL,
            supportDirectoryURL: supportDirectory
        )

        #expect(sessions == [session])
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))
        #expect(try TerminalSessionStore.load(from: destinationURL) == session)
    }

    @Test
    func keepsExistingCurrentSessionWhenMigratingWouldOverwriteIt() throws {
        let supportDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let projectURL = supportDirectory
            .appendingPathComponent("Project", isDirectory: true)
        let currentSession = sampleSession(
            name: "shared session",
            workingDirectory: projectURL
        )
        let candidateSession = TerminalSavedSession(
            name: currentSession.name,
            sessionID: "other-session",
            cacheKey: currentSession.cacheKey,
            workingDirectoryPath: currentSession.workingDirectoryPath,
            createdAt: currentSession.createdAt,
            savedAt: currentSession.savedAt.addingTimeInterval(1),
            modelID: currentSession.modelID,
            agentID: currentSession.agentID,
            agentName: currentSession.agentName,
            selectedTools: currentSession.selectedTools,
            selectedSkillIDs: currentSession.selectedSkillIDs,
            thinkingSelection: currentSession.thinkingSelection,
            contextWindow: currentSession.contextWindow,
            systemPrompt: currentSession.systemPrompt,
            history: currentSession.history,
            transcriptHistory: currentSession.transcriptHistory,
            activePlan: currentSession.activePlan,
            taskGraph: currentSession.taskGraph,
            checkpointTree: currentSession.checkpointTree
        )
        _ = try TerminalSessionStore.save(
            currentSession,
            supportDirectoryURL: supportDirectory
        )
        let directoryURL = TerminalSessionStore.sessionsDirectoryURL(
            for: projectURL,
            supportDirectoryURL: supportDirectory
        )
        let sourceURL = directoryURL.appendingPathComponent("alternate-record")
        try PropertyListEncoder().encode(candidateSession).write(to: sourceURL)

        let sessions = try TerminalSessionStore.savedSessions(
            for: projectURL,
            supportDirectoryURL: supportDirectory
        )
        let destinationURL = TerminalSessionStore.sessionFileURL(
            name: currentSession.name,
            workingDirectory: projectURL,
            supportDirectoryURL: supportDirectory
        )

        #expect(sessions == [currentSession])
        #expect(try TerminalSessionStore.load(from: destinationURL) == currentSession)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
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
        _ = try TerminalSessionStore.save(
            session,
            supportDirectoryURL: supportDirectory
        )

        let didDelete = try TerminalSessionStore.delete(
            name: "daily checkpoint",
            workingDirectory: projectURL,
            supportDirectoryURL: supportDirectory
        )
        let sessions = try TerminalSessionStore.savedSessions(
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
        let activePlan = TerminalSessionPlan(
            originalGoal: "Save through the runner",
            consolidatedText: "Persist all TUI session metadata.",
            createdAt: Date(timeIntervalSince1970: 15),
            isApproved: true
        )

        let savedSession = try await runner.saveSession(
            id: snapshot.sessionID,
            named: " snapshot save ",
            fallbackSnapshot: snapshot,
            fallbackCreatedAt: Date(timeIntervalSince1970: 10),
            modelID: "model-test",
            agentID: "developer",
            agentName: "Developer",
            selectedTools: ["shell"],
            selectedSkillIDs: ["skill-a"],
            thinkingSelection: nil,
            contextWindow: TerminalSavedSessionContextWindow(
                usedTokens: 32,
                maxTokens: 128,
                modelID: "model-test",
                isApproximate: true
            ),
            transcriptHistory: [
                AgentRuntimeMessage(role: .user, content: "visible ciao")
            ],
            activePlan: activePlan,
            checkpointTree: SessionCheckpointTree.fromLinearHistory(
                snapshot.history,
                sessionID: snapshot.sessionID
            ),
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
        #expect(savedSession.activePlan == activePlan)
        #expect(listedSessions.map(\.name) == ["snapshot save"])
    }

    @Test
    func filenameStemSanitizesSessionName() {
        #expect(
            TerminalSessionStore.filenameStem(for: " daily/checkpoint ") == "daily_checkpoint"
        )
        #expect(TerminalSessionStore.filenameStem(for: "///") == "session")
    }

    private func sampleSession(
        name: String,
        workingDirectory: URL,
        transcriptHistory: [AgentRuntimeMessage]? = nil,
        activePlan: TerminalSessionPlan? = nil,
        queuedPlans: [TerminalSessionPlan]? = nil,
        taskGraph: TaskGraphSnapshot? = nil
    ) -> TerminalSavedSession {
        TerminalSavedSession(
            name: name,
            sessionID: "terminal-test",
            cacheKey: "cache-test",
            workingDirectoryPath: workingDirectory.path,
            createdAt: Date(timeIntervalSince1970: 10),
            savedAt: Date(timeIntervalSince1970: 20),
            modelID: "model-test",
            agentID: "developer",
            agentName: "Developer",
            selectedTools: [
                "shell",
                TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools")
            ],
            selectedSkillIDs: ["skill-a"],
            thinkingSelection: "on",
            contextWindow: TerminalSavedSessionContextWindow(
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
            transcriptHistory: transcriptHistory,
            activePlan: activePlan,
            queuedPlans: queuedPlans,
            taskGraph: taskGraph,
            checkpointTree: SessionCheckpointTree.fromLinearHistory(
                transcriptHistory ?? [
                    AgentRuntimeMessage(role: .user, content: "ciao"),
                ],
                sessionID: "terminal-test"
            )
        )
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "terminal-session-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
    }
}
