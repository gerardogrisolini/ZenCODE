//
//  AgentCoreSessionRunnerTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
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
                modelOutput: "compact output sent back to the model"
            )
        ))

        let history = await recorder.snapshot().history
        let toolMessage = try #require(history.last)
        #expect(toolMessage.role == .tool)
        #expect(toolMessage.content == "compact output sent back to the model")
        #expect(toolMessage.toolCallID == "call_read")
        #expect(toolMessage.toolName == "local.readFile")
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

    private static func authorizationRequest(
        sessionID: String,
        toolName: String
    ) -> AgentToolAuthorizationRequest {
        AgentToolAuthorizationRequest(
            sessionID: sessionID,
            toolCallID: UUID().uuidString,
            toolName: toolName,
            title: toolName,
            kind: "execute",
            command: "echo test",
            workingDirectory: "/tmp"
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
        for request in box.authorizationRequests() {
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
    private var didStartPrompt = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

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
        didStartPrompt = true
        for continuation in startContinuations {
            continuation.resume()
        }
        startContinuations.removeAll()

        try await Task.sleep(for: .seconds(30))
        return DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }

    func waitUntilPromptStarted() async {
        guard !didStartPrompt else {
            return
        }

        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
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
