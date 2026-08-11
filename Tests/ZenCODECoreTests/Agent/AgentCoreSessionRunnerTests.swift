//
//  AgentCoreSessionRunnerTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing

@Suite
struct AgentCoreSessionRunnerTests {
    @Test
    func updateSessionOptionsPropagatesSystemPrompt() async throws {
        let backend = CapturingAgentRuntimeBackend()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let workingDirectory = FileManager.default.temporaryDirectory
        let initialConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: workingDirectory,
            systemPrompt: "Memory tools: enabled.",
            cacheKey: nil,
            history: [],
            allowedToolNames: ["memory.read"]
        )
        let updatedConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: workingDirectory,
            systemPrompt: "Memory tools are unavailable.",
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        )

        try await runner.createSession(configuration: initialConfiguration)
        _ = try await runner.sendPrompt(
            configuration: initialConfiguration,
            prompt: "hello",
            attachments: [],
            onEvent: { _ in }
        )
        try await runner.updateSessionOptions(configuration: updatedConfiguration)

        #expect(await backend.lastUpdatedSystemPrompt() == "Memory tools are unavailable.")
        #expect(await backend.lastUpdatedAllowedToolNames() == [])
    }

    @Test
    func replaceSessionHistoryUpdatesSnapshotAndRuntimeBackend() async throws {
        let backend = CapturingAgentRuntimeBackend()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: "system",
            cacheKey: "cache",
            history: [AgentRuntimeMessage(role: .user, content: "old")],
            allowedToolNames: ["agent.create"]
        )
        let replacement = [
            AgentRuntimeMessage(role: .user, content: "plan request"),
            AgentRuntimeMessage(role: .assistant, content: "Planner-authored plan"),
        ]

        try await runner.createSession(configuration: configuration)
        _ = try await runner.preloadModel(configuration: configuration, onEvent: { _ in })
        #expect(await runner.replaceSessionHistory(id: sessionID, history: replacement))

        #expect(await runner.snapshotSession(id: sessionID)?.history == replacement)
        #expect(await backend.lastCreatedHistory() == replacement)
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

    @Test
    func cancelPromptBySessionIDPublishesCancelledOutcome() async throws {
        let backend = BlockingAgentRuntimeBackend()
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

        let stream = await runner.streamPrompt(
            "please stop",
            configuration: configuration
        )
        let consumer = Task {
            do {
                for try await event in stream {
                    await snapshotCollector.record(event)
                }
            } catch is CancellationError {
            } catch {
            }
        }

        await backend.waitUntilPromptStarted()
        await runner.cancelPrompt(sessionID: sessionID)
        await consumer.value

        let snapshots = await snapshotCollector.snapshots()
        let outcomes = await snapshotCollector.outcomes()
        #expect(snapshots.count == 1)
        #expect(outcomes == [.cancelled])
        let history = try #require(snapshots.first?.history)
        #expect(history.count == 1)
        #expect(history[safe: 0]?.role == .user)
        #expect(history[safe: 0]?.content == "please stop")
        #expect(await runner.snapshotSession(id: sessionID)?.history == history)
    }

    @Test
    func sendPromptWiresSessionLeaseBeforeStartingTheNextBackendTurn() async throws {
        let backend = BlockingAgentRuntimeBackend()
        let queued = RunnerLeaseQueueObserver()
        let lease = AgentSessionTurnLease { sessionID in
            queued.recordEnqueue(for: sessionID)
        }
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend },
            taskGraphStore: nil,
            sessionTurnLease: lease
        )
        let sessionID = "session-lease-wiring-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        )

        let first = Task {
            try await runner.sendPrompt(configuration: configuration, prompt: "first", attachments: [], onEvent: { _ in })
        }
        await backend.waitUntilPromptStarted()
        let second = Task {
            try await runner.sendPrompt(configuration: configuration, prompt: "second", attachments: [], onEvent: { _ in })
        }
        await queued.waitForEnqueueCount(1, sessionID: sessionID)
        #expect(await backend.promptStartCount() == 1)

        first.cancel()
        do {
            _ = try await first.value
            Issue.record("The cancelled first turn unexpectedly completed.")
        } catch is CancellationError {
        }
        await backend.waitUntilPromptStarted(count: 2)
        #expect(await backend.promptStartCount() == 2)
        second.cancel()
        do {
            _ = try await second.value
            Issue.record("The cancelled second turn unexpectedly completed.")
        } catch is CancellationError {
        }
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
    func compactSessionUsesRuntimeContextWindowOverrideWhenConfigurationHasNoLimit() async throws {
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
            allowedToolNames: []
        )

        try await runner.createSession(configuration: configuration)
        _ = try await runner.preloadModel(configuration: configuration, onEvent: { _ in })
        let result = try await runner.compactSession(
            id: sessionID,
            force: true,
            maxTokensOverride: 1_000
        )

        let compaction = try #require(result)
        #expect(compaction.wasCompacted)
        #expect(compaction.maxTokens == 1_000)
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
    func sessionCloseAndRecreationPreserveTaskGraphForRuntimeSetup() async throws {
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
            id: "setup-preserved-graph",
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

    @Test
    func runtimeSetupResetsFullAccessModeToStandard() async {
        let runner = AgentCoreSessionRunner(taskGraphStore: nil)

        #expect(await runner.toggleLocalExecAccessMode() == .fullAccess)
        await runner.resetLocalExecAccessMode()
        #expect(await runner.localExecAccessMode() == .standard)
    }

    @Test
    func localExecAccessModeRoutesDefaultAndPerPromptAuthorization() async throws {
        let defaultAuthorizer = AuthorizationRecorder(decision: false)
        let promptAuthorizer = AuthorizationRecorder(decision: false)
        let approvingPromptAuthorizer = AuthorizationRecorder(decision: true)
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await defaultAuthorizer.authorize(request)
            },
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec", "local.readFile"]
        )

        try await runner.createSession(configuration: configuration)
        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "default",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [false])
        #expect(await defaultAuthorizer.toolNames() == ["local.exec"])

        #expect(await runner.toggleLocalExecAccessMode() == .fullAccess)
        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "full access local exec",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [true])
        #expect(await defaultAuthorizer.toolNames() == ["local.exec"])

        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.readFile")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "full access other tool",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [false])
        #expect(await defaultAuthorizer.toolNames() == ["local.exec", "local.readFile"])

        #expect(await runner.toggleLocalExecAccessMode() == .standard)
        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "default restored",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [false])
        #expect(await defaultAuthorizer.toolNames() == ["local.exec", "local.readFile", "local.exec"])

        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "default per-prompt",
            attachments: [],
            authorizeTool: { request in
                await approvingPromptAuthorizer.authorize(request)
            },
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [true])
        #expect(await approvingPromptAuthorizer.toolNames() == ["local.exec"])
        #expect(await defaultAuthorizer.toolNames() == ["local.exec", "local.readFile", "local.exec"])

        #expect(await runner.toggleLocalExecAccessMode() == .fullAccess)
        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec.foo"),
            Self.authorizationRequest(sessionID: sessionID, toolName: " local.exec"),
            Self.authorizationRequest(sessionID: sessionID, toolName: "LOCAL.EXEC")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "near-canonical names",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [false, false, false])
        #expect(
            await defaultAuthorizer.toolNames().suffix(3)
                == ["local.exec.foo", " local.exec", "LOCAL.EXEC"]
        )

        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec"),
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.readFile")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "per-prompt",
            attachments: [],
            authorizeTool: { request in
                await promptAuthorizer.authorize(request)
            },
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [true, false])
        #expect(await promptAuthorizer.toolNames() == ["local.readFile"])
    }

    @Test
    func fullAccessDoesNotOverrideDirectToolAllowlist() async throws {
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-full-access-allowlist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let markerURL = rootURL.appendingPathComponent("should-not-exist")
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: rootURL,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec"]
        )

        try await runner.createSession(configuration: configuration)
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "initialize backend",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(await runner.toggleLocalExecAccessMode() == .fullAccess)
        let authorizationHandler = try #require(backendBox.authorizationHandler())
        let executor = DirectToolExecutor(
            authorizationHandler: authorizationHandler,
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { CapturingAgentRuntimeBackend() }
        )
        let command = "touch '\(markerURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        let toolCall = DirectAgentToolCall(
            id: "blocked-local-exec",
            name: "local.exec",
            argumentsObject: ["command": command],
            argumentsJSON: #"{"command":"blocked"}"#
        )

        let result = await executor.execute(
            sessionID: sessionID,
            toolCall: toolCall,
            workingDirectory: rootURL,
            allowedToolNames: ["local.readFile"]
        )

        #expect(result.status == .permissionDenied)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test
    func localExecAccessModeSurvivesOptionUpdateAndSessionRebuild() async throws {
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let baseConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec"]
        )
        let updatedConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: "updated",
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec", "local.readFile"]
        )

        try await runner.createSession(configuration: baseConfiguration)
        #expect(await runner.toggleLocalExecAccessMode() == .fullAccess)
        try await runner.updateSessionOptions(configuration: updatedConfiguration)
        #expect(await runner.localExecAccessMode() == .fullAccess)

        await runner.rebuildSession(id: sessionID)
        #expect(await runner.localExecAccessMode() == .fullAccess)
        try await runner.createSession(configuration: updatedConfiguration)
        #expect(await runner.localExecAccessMode() == .fullAccess)
    }

    @Test
    func delegatedRequestReachesOperatorEvenWithoutLiveTurn() async throws {
        // The case the fix targets: a delegated sub-agent outlives the turn that
        // spawned it, so its consent request must still reach the operator even
        // when no turn is in flight, and the operator's decision must be honoured
        // both on approval and on denial.
        let approvingOperator = AuthorizationRecorder(decision: true)
        let denyingOperator = AuthorizationRecorder(decision: false)
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec"]
        )

        try await runner.createSession(configuration: configuration)
        // Warm-up turn with no requests: it only creates the backend and
        // registers an approving operator handler for the session.
        backendBox.setAuthorizationRequests([])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "warm up",
            attachments: [],
            authorizeTool: { request in await approvingOperator.authorize(request) },
            onEvent: { _ in }
        )

        // `authorizationHandler()` is the runner's stable authorizeTool closure,
        // independent of any single turn. Capturing it and driving it directly
        // is exactly what a delegated sub-agent's executor does — and, crucially,
        // it runs *after* sendPrompt returned, so the per-turn handler entry has
        // already been removed by the `defer`. This is the most faithful way to
        // model "no turn in flight" with this backend: by the time `await
        // sendPrompt` resolves the turn has fully completed, so no sleep is
        // needed and the assertion is deterministic.
        let authorize = try #require(backendBox.authorizationHandler())

        // The request's own session is a bogus sub-agent session and carries no
        // turn id, so the turn-scoped path could never match it. Routing must
        // succeed purely on the runtime-minted delegation identity.
        let approved = await authorize(
            Self.authorizationRequest(
                sessionID: "sub-agent-private-session",
                toolName: "local.exec",
                delegatedIdentity: .init(agentID: "delegated-approver", rootSessionID: sessionID)
            )
        )
        #expect(approved == true)
        #expect(await approvingOperator.toolNames() == ["local.exec"])

        // A second turn swaps in a denying operator; the captured closure is the
        // same object, proving the request is answered by the session-scoped
        // handler that survives across turns — not by a per-turn entry.
        backendBox.setAuthorizationRequests([])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "deny handler",
            attachments: [],
            authorizeTool: { request in await denyingOperator.authorize(request) },
            onEvent: { _ in }
        )
        let denied = await authorize(
            Self.authorizationRequest(
                sessionID: "sub-agent-private-session",
                toolName: "local.delete",
                delegatedIdentity: .init(agentID: "delegated-denyer", rootSessionID: sessionID)
            )
        )
        #expect(denied == false)
        #expect(await denyingOperator.toolNames() == ["local.delete"])
    }

    @Test
    func delegatedRequestWithUnknownRootSessionIsDeniedAndUnseen() async throws {
        // An unknown root session names no operator this runner owns, so the
        // request must fail closed — even when a default authorizer would have
        // approved it. Neither the per-session handler nor the default is ever
        // consulted.
        let defaultAuthorizer = AuthorizationRecorder(decision: true)
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await defaultAuthorizer.authorize(request)
            },
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec"]
        )

        try await runner.createSession(configuration: configuration)
        backendBox.setAuthorizationRequests([])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "warm up",
            attachments: [],
            onEvent: { _ in }
        )
        let authorize = try #require(backendBox.authorizationHandler())

        let result = await authorize(
            Self.authorizationRequest(
                sessionID: "sub-agent-private-session",
                toolName: "local.exec",
                delegatedIdentity: .init(agentID: "stranger", rootSessionID: "session-unknown-to-runner")
            )
        )
        #expect(result == false)
        #expect(await defaultAuthorizer.toolNames() == [])
    }

    @Test
    func nonDelegatedRequestRoutingIsUnchanged() async throws {
        // Regression guard for the original turn-scoped path: a plain request
        // (no delegation identity) is approved when its session matches the live
        // turn, and denied — without consulting the handler — when the session
        // is foreign to that turn.
        let authorizer = AuthorizationRecorder(decision: true)
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await authorizer.authorize(request)
            },
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec"]
        )

        try await runner.createSession(configuration: configuration)

        // Matching session + live turn: reaches the handler, approved.
        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "match",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [true])
        #expect(await authorizer.toolNames() == ["local.exec"])

        // Foreign session while the turn is live: denied, handler untouched.
        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: "session-not-this-turn", toolName: "local.delete")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "mismatch",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [false])
        #expect(await authorizer.toolNames() == ["local.exec"])
    }

    @Test
    func fullAccessShortCircuitsDelegatedRequestsForGatedTools() async throws {
        // The full-access bypass must cover delegated requests on gated tools
        // too, so a sub-agent never blocks on a dialog the operator has already
        // globally waived.
        let operatorHandler = AuthorizationRecorder(decision: false)
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await operatorHandler.authorize(request)
            },
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec"]
        )

        try await runner.createSession(configuration: configuration)
        backendBox.setAuthorizationRequests([])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "warm up",
            attachments: [],
            onEvent: { _ in }
        )
        let authorize = try #require(backendBox.authorizationHandler())

        #expect(await runner.toggleLocalExecAccessMode() == .fullAccess)

        let result = await authorize(
            Self.authorizationRequest(
                sessionID: "sub-agent-private-session",
                toolName: "local.exec",
                delegatedIdentity: .init(agentID: "delegated-runner", rootSessionID: sessionID)
            )
        )
        // Auto-approved by full access; the operator would have denied, proving
        // the short-circuit fired before the delegated branch could ask.
        #expect(result == true)
        #expect(await operatorHandler.toolNames() == [])
    }

    @Test
    func delegatedRequestTitleNamesAgentWhilePlainTitleIsPreserved() async throws {
        // Presentation only: a delegated request is shown with the agent's
        // identity in the title, while a plain (non-delegated) request keeps its
        // title verbatim. Only `title` changes — never the routing fields.
        let operatorHandler = AuthorizationRecorder(decision: true)
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await operatorHandler.authorize(request)
            },
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec"]
        )

        try await runner.createSession(configuration: configuration)
        backendBox.setAuthorizationRequests([])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "warm up",
            attachments: [],
            onEvent: { _ in }
        )
        let authorize = try #require(backendBox.authorizationHandler())

        // The fake backend exposes no sub-agent snapshots, so name resolution
        // falls back to the agent id — which is exactly the "identifies the
        // agent" contract under test.
        _ = await authorize(
            Self.authorizationRequest(
                sessionID: "sub-agent-private-session",
                toolName: "local.exec",
                delegatedIdentity: .init(agentID: "researcher-7", rootSessionID: sessionID)
            )
        )
        let delegatedRequests = await operatorHandler.recordedRequests()
        #expect(delegatedRequests.count == 1)
        #expect(delegatedRequests[0].title.contains("researcher-7"))
        #expect(delegatedRequests[0].title.hasPrefix("[agent "))
        // The original title survives after the prefix.
        #expect(delegatedRequests[0].title.hasSuffix("local.exec"))
        #expect(delegatedRequests[0].toolName == "local.exec")

        // Plain (non-delegated) regression: the title is handed through verbatim.
        let plainAuthorizer = AuthorizationRecorder(decision: true)
        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "plain",
            attachments: [],
            authorizeTool: { request in await plainAuthorizer.authorize(request) },
            onEvent: { _ in }
        )
        let plainRequests = await plainAuthorizer.recordedRequests()
        #expect(plainRequests.count == 1)
        #expect(plainRequests[0].title == "local.exec")
    }

    private static func authorizationRequest(
        sessionID: String,
        toolName: String,
        delegatedIdentity: AgentToolAuthorizationRequest.DelegatedIdentity? = nil
    ) -> AgentToolAuthorizationRequest {
        AgentToolAuthorizationRequest(
            sessionID: sessionID,
            toolCallID: UUID().uuidString,
            toolName: toolName,
            title: toolName,
            kind: "execute",
            command: "echo test",
            workingDirectory: "/tmp",
            delegatedIdentity: delegatedIdentity
        )
    }
}

private actor AuthorizationRecorder {
    private let decision: Bool
    private var requests: [AgentToolAuthorizationRequest] = []

    init(decision: Bool) {
        self.decision = decision
    }

    func authorize(_ request: AgentToolAuthorizationRequest) -> Bool {
        requests.append(request)
        return decision
    }

    func toolNames() -> [String] {
        requests.map(\.toolName)
    }

    /// Full recorded requests, used to assert presentation-only fields such as
    /// the operator-facing title.
    func recordedRequests() -> [AgentToolAuthorizationRequest] {
        requests
    }
}

private final class AuthorizationBackendBox: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AgentToolAuthorizationRequest] = []
    private var results: [Bool] = []
    private var capturedAuthorizationHandler: AgentToolAuthorizationHandler?

    func makeBackend(
        handler: AgentToolAuthorizationHandler?
    ) -> AuthorizationInvokingBackend {
        lock.lock()
        capturedAuthorizationHandler = handler
        lock.unlock()
        return AuthorizationInvokingBackend(handler: handler, box: self)
    }

    func authorizationHandler() -> AgentToolAuthorizationHandler? {
        lock.lock()
        defer { lock.unlock() }
        return capturedAuthorizationHandler
    }

    func setAuthorizationRequests(_ requests: [AgentToolAuthorizationRequest]) {
        lock.lock()
        self.requests = requests
        lock.unlock()
    }

    func authorizationRequests() -> [AgentToolAuthorizationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func setAuthorizationResults(_ results: [Bool]) {
        lock.lock()
        self.results = results
        lock.unlock()
    }

    func lastAuthorizationResults() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}

private actor AuthorizationInvokingBackend: AgentRuntimeBackend {
    private let handler: AgentToolAuthorizationHandler?
    private let box: AuthorizationBackendBox
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]

    init(handler: AgentToolAuthorizationHandler?, box: AuthorizationBackendBox) {
        self.handler = handler
        self.box = box
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
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}
    func shutdown() async { sessions.removeAll() }
    func preloadModel(onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String {
        "test-model"
    }
    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        var results: [Bool] = []
        for template in box.authorizationRequests() {
            // Production tool executors create authorization requests while the
            // prompt's TaskLocal turn is active. Rebuild the recorded template
            // here so the fixture exercises the same turn-bound routing.
            // Carry the delegation identity through so a delegated template
            // exercises the delegated routing branch just like production.
            let request = AgentToolAuthorizationRequest(
                sessionID: template.sessionID,
                toolCallID: template.toolCallID,
                toolName: template.toolName,
                title: template.title,
                kind: template.kind,
                command: template.command,
                workingDirectory: template.workingDirectory,
                delegatedIdentity: template.delegatedIdentity
            )
            results.append(await handler?(request) ?? true)
        }
        box.setAuthorizationResults(results)
        return DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}

private actor CapturingAgentRuntimeBackend: AgentRuntimeBackend {
    private var updatedSystemPrompt: String?
    private var updatedAllowedToolNames: Set<String>?
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var createdHistories: [[AgentRuntimeMessage]] = []
    private var interruptedRoots: [String] = []
    private let promptEvents: [DirectAgentEvent]
    private let sendPromptError: Error?

    init(
        promptEvents: [DirectAgentEvent] = [],
        sendPromptError: Error? = nil
    ) {
        self.promptEvents = promptEvents
        self.sendPromptError = sendPromptError
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
        createdHistories.append(history)
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
        guard sessions[id] == nil else {
            return
        }
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
        id _: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        updatedSystemPrompt = systemPrompt
        updatedAllowedToolNames = allowedToolNames
    }

    func updateBorrowedSubAgentToolExecutor(
        _: AgentBorrowedToolExecutor?
    ) async {}

    func updateToolProviders(_: [AgentToolProvider]) async {}

    func closeSession(id _: String) {}

    func shutdown() async {
        sessions.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        []
    }

    func interruptSubAgents(rootSessionID: String) async -> Int {
        interruptedRoots.append(rootSessionID)
        return 0
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        for event in promptEvents {
            await onEvent(event)
        }
        if let sendPromptError {
            throw sendPromptError
        }
        return DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }

    func lastUpdatedSystemPrompt() -> String? {
        updatedSystemPrompt
    }

    func lastUpdatedAllowedToolNames() -> Set<String>? {
        updatedAllowedToolNames
    }

    func lastCreatedHistory() -> [AgentRuntimeMessage]? {
        createdHistories.last
    }

    func interruptedRootSessionIDs() -> [String] {
        interruptedRoots
    }
}

private actor BlockingAgentRuntimeBackend: AgentRuntimeBackend {
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var promptStarts = 0
    private var startContinuations: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

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
        guard sessions[id] == nil else {
            return
        }
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
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}

    func shutdown() async {
        sessions.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        promptStarts += 1
        let ready = startContinuations.enumerated().filter { promptStarts >= $0.element.count }
        for index in ready.map(\.offset).reversed() {
            startContinuations.remove(at: index).continuation.resume()
        }

        try await Task.sleep(for: .seconds(30))
        return DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }

    func waitUntilPromptStarted(count: Int = 1) async {
        guard promptStarts < count else {
            return
        }

        await withCheckedContinuation { continuation in
            startContinuations.append((count, continuation))
        }
    }

    func promptStartCount() -> Int { promptStarts }
}

private final class RunnerLeaseQueueObserver: Sendable {
    private struct State {
        var counts: [String: Int] = [:]
        var waiters: [(sessionID: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    func recordEnqueue(for sessionID: String) {
        let ready: [CheckedContinuation<Void, Never>] = state.withLock { state in
            state.counts[sessionID, default: 0] += 1
            let count = state.counts[sessionID, default: 0]
            let ready = state.waiters.enumerated().filter {
                $0.element.sessionID == sessionID && count >= $0.element.count
            }
            for index in ready.map(\.offset).reversed() {
                state.waiters.remove(at: index)
            }
            return ready.map(\.element.continuation)
        }
        ready.forEach { $0.resume() }
    }

    func waitForEnqueueCount(_ count: Int, sessionID: String) async {
        guard !state.withLock({ $0.counts[sessionID, default: 0] >= count }) else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state -> Bool in
                guard state.counts[sessionID, default: 0] < count else { return true }
                state.waiters.append((sessionID, count, continuation))
                return false
            }
            if shouldResume { continuation.resume() }
        }
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
