//
//  AgentCoreSessionRunnerTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing

@Suite
struct AgentCoreSessionRunnerTests {
    @Test
    func fencedHistoryReplacementCannotMutateARecreatedSession() async throws {
        let backend = CapturingAgentRuntimeBackend()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend }
        )
        let sessionID = "session-fenced-\(UUID().uuidString)"
        let oldConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: "old",
            cacheKey: "old-cache",
            history: [AgentRuntimeMessage(role: .user, content: "old")],
            allowedToolNames: []
        )
        try await runner.createSession(configuration: oldConfiguration)
        let oldGeneration = try #require(
            await runner.currentSessionGeneration(for: sessionID)
        )

        await runner.closeSession(id: sessionID)
        let newHistory = [AgentRuntimeMessage(role: .user, content: "new incarnation")]
        let newConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: "new",
            cacheKey: "new-cache",
            history: newHistory,
            allowedToolNames: []
        )
        try await runner.createSession(configuration: newConfiguration)

        #expect(!(await runner.replaceSessionHistory(
            id: sessionID,
            history: [AgentRuntimeMessage(role: .assistant, content: "stale")],
            expectedSessionGeneration: oldGeneration
        )))
        #expect(await runner.snapshotSession(id: sessionID)?.history == newHistory)
    }

    @Test
    func failedPromptPublishesRecoveredSessionSnapshot() async throws {
        let backend = CapturingAgentRuntimeBackend(
            promptEvents: [.content("partial answer")],
            sendPromptError: SyntheticPromptError()
        )
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        )
        let snapshotCollector = SnapshotCollector()
        var didThrow = false

        do {
            _ = try await runner.sendPrompt(
                configuration: configuration,
                prompt: "hello",
                attachments: [],
                onEvent: { event in
                    await snapshotCollector.record(event)
                }
            )
        } catch is SyntheticPromptError {
            didThrow = true
        }

        let snapshots = await snapshotCollector.snapshots()
        let outcomes = await snapshotCollector.outcomes()
        #expect(didThrow)
        #expect(snapshots.count == 1)
        #expect(outcomes == [.failed(message: "Synthetic prompt failed.")])
        let history = try #require(snapshots.first?.history)
        #expect(history.count == 2)
        #expect(history[safe: 0]?.role == .user)
        #expect(history[safe: 0]?.content == "hello")
        #expect(history[safe: 1]?.role == .assistant)
        #expect(history[safe: 1]?.content == "partial answer")
        #expect(await runner.snapshotSession(id: sessionID)?.history == history)
        #expect(await backend.lastCreatedHistory() == history)
    }

    @Test
    func toolResultsPersistModelOutputInRecoveredHistory() async throws {
        let recorder = AgentCorePromptTurnRecorder(
            initialSnapshot: AgentRuntimeSessionSnapshot(
                sessionID: "session-tool-output",
                modelID: "test-model",
                workingDirectoryPath: "/tmp/project",
                systemPrompt: nil,
                cacheKey: nil,
                history: [],
                allowedToolNames: ["local.readFile"],
                thinkingSelection: nil,
                preserveThinking: false
            ),
            prompt: "read file",
            attachments: []
        )
        let toolCall = DirectAgentToolCall(
            id: "call_read",
            name: "local.readFile",
            argumentsObject: ["path": "big.swift"],
            argumentsJSON: #"{"path":"big.swift"}"#
        )

        await recorder.record(.toolCallStarted(toolCall))
        await recorder.record(.toolCallCompleted(
            toolCall,
            DirectAgentToolResult(
                output: "full output shown in UI",
                summary: "read big.swift",
                modelOutput: "compact output sent back to the model",
                attachments: [
                    AgentRuntimeAttachment(
                        kind: .image,
                        data: Data([0x89, 0x50, 0x4E, 0x47]),
                        contentType: "image/png",
                        originalFilename: "tool-output.png"
                    )
                ]
            )
        ))

        let history = await recorder.snapshot().history
        let toolMessage = try #require(history.last)
        #expect(toolMessage.role == .tool)
        #expect(toolMessage.content == "compact output sent back to the model")
        #expect(toolMessage.toolCallID == "call_read")
        #expect(toolMessage.toolName == "local.readFile")
        #expect(toolMessage.attachments.count == 1)
        #expect(toolMessage.attachments.first?.data == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    /// The calls of one round are dispatched one after the other, each start
    /// followed by its completion. They are one assistant message, as the
    /// backend stores the round; the model writing again starts the next one.
    @Test
    func aRoundWithSeveralToolCallsIsRecordedAsOneAssistantMessage() async throws {
        let recorder = AgentCorePromptTurnRecorder(
            initialSnapshot: AgentRuntimeSessionSnapshot(
                sessionID: "session-tool-round",
                modelID: "test-model",
                workingDirectoryPath: "/tmp/project",
                systemPrompt: nil,
                cacheKey: nil,
                history: [],
                allowedToolNames: ["local.readFile"],
                thinkingSelection: nil,
                preserveThinking: false
            ),
            prompt: "read files",
            attachments: []
        )
        func toolCall(_ id: String) -> DirectAgentToolCall {
            DirectAgentToolCall(
                id: id,
                name: "local.readFile",
                argumentsObject: ["path": "\(id).swift"],
                argumentsJSON: #"{"path":"\#(id).swift"}"#
            )
        }
        func result(_ text: String) -> DirectAgentToolResult {
            DirectAgentToolResult(output: text, summary: text, modelOutput: text)
        }

        await recorder.record(.thought("Two files."))
        await recorder.record(.content("Reading."))
        await recorder.record(.toolCallStarted(toolCall("a")))
        await recorder.record(.toolCallCompleted(toolCall("a"), result("A")))
        await recorder.record(.toolCallStarted(toolCall("b")))
        await recorder.record(.toolCallCompleted(toolCall("b"), result("B")))
        await recorder.record(.thought("One more."))
        await recorder.record(.toolCallStarted(toolCall("c")))
        await recorder.record(.toolCallCompleted(toolCall("c"), result("C")))
        await recorder.record(.content("Done."))

        let history = await recorder.snapshot().history
        #expect(history.map(\.role) == [.user, .assistant, .tool, .tool, .assistant, .tool, .assistant])
        #expect(history[1].content == "Reading.")
        #expect(history[1].reasoningContent == "Two files.")
        #expect(history[1].toolCalls.map(\.id) == ["a", "b"])
        #expect(history[2].toolCallID == "a")
        #expect(history[3].toolCallID == "b")
        #expect(history[4].reasoningContent == "One more.")
        #expect(history[4].toolCalls.map(\.id) == ["c"])
        #expect(history[5].toolCallID == "c")
        #expect(history[6].content == "Done.")
        #expect(history[6].toolCalls.isEmpty)
    }

    @Test
    func cancelPromptBySessionIDInterruptsDelegatedAgents() async throws {
        let backend = CapturingAgentRuntimeBackend()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        )

        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "start delegated work",
            attachments: []
        ) { _ in }
        await runner.cancelPrompt(sessionID: sessionID)

        let interruptedRoots = await backend.interruptedRootSessionIDs()
        #expect(interruptedRoots == [sessionID])
    }

    @Test
    func compactSessionForcesRuntimeCompactionAndCachesSnapshot() async throws {
        let backend = CapturingAgentRuntimeBackend()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend }
        )
        let sessionID = "session-\(UUID().uuidString)"
        var history: [AgentRuntimeMessage] = []
        for index in 0..<8 {
            history.append(
                AgentRuntimeMessage(
                    role: .user,
                    content: "Older request \(index) " + String(repeating: "details ", count: 80)
                )
            )
            history.append(
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "Older response \(index) " + String(repeating: "answer ", count: 80)
                )
            )
        }
        history.append(AgentRuntimeMessage(role: .user, content: "Newest request"))
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: "System instructions.",
            cacheKey: "cache-key",
            history: history,
            allowedToolNames: [],
            configuredContextWindowLimit: 1_000
        )

        try await runner.createSession(configuration: configuration)
        _ = try await runner.preloadModel(configuration: configuration, onEvent: { _ in })
        let result = try await runner.compactSession(id: sessionID, force: true)

        let compaction = try #require(result)
        #expect(compaction.wasCompacted)
        #expect(compaction.snapshot.systemPrompt?.contains(AgentConversationCompactionSupport.memorySummaryHeader) == true)
        #expect(compaction.snapshot.history.count < history.count)
        #expect(await runner.snapshotSession(id: sessionID)?.history == compaction.snapshot.history)
        #expect(await backend.lastCreatedHistory() == compaction.snapshot.history)
    }
    @Test
    func backendRebuildPreservesTasksButSessionResetDiscardsThem() async throws {
        let backend = CapturingAgentRuntimeBackend()
        let taskOrchestrator = SessionTaskOrchestrator()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend },
            taskOrchestrator: taskOrchestrator,
            taskGraphStore: nil
        )
        let sessionID = "session-\(UUID().uuidString)"
        let workingDirectory = FileManager.default.temporaryDirectory
        let firstConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "model-a",
            workingDirectory: workingDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["tasks.list"]
        )
        let secondConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "model-b",
            workingDirectory: workingDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["tasks.list"]
        )

        try await runner.createSession(configuration: firstConfiguration)
        _ = try await taskOrchestrator.createGraph(
            sessionID: sessionID,
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "task-a", title: "A")]
        )
        try await runner.createSession(configuration: secondConfiguration)
        _ = try await runner.preloadModel(
            configuration: secondConfiguration,
            onEvent: { _ in }
        )
        #expect(try await runner.taskGraphSnapshot(sessionID: sessionID)?.tasks.map(\.id) == ["task-a"])

        await runner.rebuildSession(id: sessionID)
        #expect(try await runner.taskGraphSnapshot(sessionID: sessionID)?.tasks.map(\.id) == ["task-a"])
        #expect(await backend.interruptedRootSessionIDs().isEmpty)

        await runner.resetSession(id: sessionID)
        #expect(try await runner.taskGraphSnapshot(sessionID: sessionID) == nil)
        let interruptedRoots = await backend.interruptedRootSessionIDs()
        #expect(interruptedRoots == [sessionID])
    }

    @Test
    func taskGraphSurvivesSessionCloseAndBackendRecreation() async throws {
        let backend = CapturingAgentRuntimeBackend()
        let taskOrchestrator = SessionTaskOrchestrator()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend },
            taskOrchestrator: taskOrchestrator,
            taskGraphStore: nil
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "model-a",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["tasks.list"]
        )

        try await runner.createSession(configuration: configuration)
        _ = try await taskOrchestrator.createGraph(
            sessionID: sessionID,
            id: "preserved-graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "task-a", title: "A")]
        )

        await runner.closeSession(id: sessionID)
        #expect(
            try await runner.taskGraphSnapshot(sessionID: sessionID)?.tasks.map(\.id)
                == ["task-a"]
        )

        await runner.shutdownBackendKeepingExternalTools()
        try await runner.createSession(configuration: configuration)
        #expect(
            try await runner.taskGraphSnapshot(sessionID: sessionID)?.tasks.map(\.id)
                == ["task-a"]
        )
    }
}

private struct SyntheticPromptError: Error, LocalizedError {
    var errorDescription: String? {
        "Synthetic prompt failed."
    }
}

private actor SnapshotCollector {
    private var values: [AgentRuntimeSessionSnapshot] = []
    private var outcomeValues: [DirectAgentTurnOutcome] = []

    func record(_ event: DirectAgentEvent) {
        if case let .sessionSnapshot(snapshot) = event {
            values.append(snapshot)
        }
        if case let .turnEnded(outcome) = event {
            outcomeValues.append(outcome)
        }
    }

    func snapshots() -> [AgentRuntimeSessionSnapshot] {
        values
    }

    func outcomes() -> [DirectAgentTurnOutcome] {
        outcomeValues
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
