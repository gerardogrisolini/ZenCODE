import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
@TerminalChatActor
struct TerminalChatArtifactCompletionTests {
    @Test(arguments: ["local.write", "local.writeFile"], [DirectAgentToolResult.Status.completed, .failed])
    nonisolated func rootWriteCompletesBeforeItsLiveArtifact(
        toolName: String,
        status: DirectAgentToolResult.Status
    ) async throws {
        try await exerciseCompletion(toolName: toolName, status: status, delegated: false)
    }

    @Test(arguments: ["local.write", "local.writeFile"], [DirectAgentToolResult.Status.completed, .failed])
    nonisolated func delegatedWriteReplacesPendingOverviewWhenPublishingLiveArtifact(
        toolName: String,
        status: DirectAgentToolResult.Status
    ) async throws {
        try await exerciseCompletion(toolName: toolName, status: status, delegated: true)
    }

    @Test
    func delegatedArtifactPreservesTranscriptWhenOverviewOwnershipIsUnsafe() async {
        let capture = PrimaryScreenCapture(rows: 40, columns: 100)
        let screen = capture.screen()
        screen.commitFooter(
            geometry: .init(rows: 40, columns: 100), reservedRows: 4,
            sequence: "\u{1B}[40;1HSTATUS| ready"
        )
        screen.positionOutputForTesting(row: 1)
        let renderer = makeRenderer(clock: ArtifactCompletionClock())
        await renderer.usePrimaryScreenForTesting(screen)
        _ = await renderer.renderSubAgentOverview(
            signature: "unsafe-pending", text: "\nPending local.writeFile ⏳\n",
            force: false, rememberSignature: true, overviewBatchID: "worker-wave",
            maximumInPlaceRows: 36
        )
        // An external diagnostic invalidates the receipt without updating the
        // coordinator's write sequence. Never erase it with the old anchor.
        screen.append("DIAGNOSTIC| must survive\n")
        await renderer.writeSubAgentFileArtifactMessage(
            "**added `Completed.swift`**  +1 -0\n",
            maximumInPlaceRows: 36
        )
        let output = capture.history + "\n" + capture.visible
        #expect(output.contains("DIAGNOSTIC| must survive"))
        #expect(output.contains("Pending local.writeFile ⏳"))
        #expect(output.contains("added Completed.swift"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
    }

    private nonisolated func exerciseCompletion(
        toolName: String,
        status: DirectAgentToolResult.Status,
        delegated: Bool
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-completion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await AppStorageDirectory.withSupportDirectoryURL(directory.appendingPathComponent("support")) {
            try await Task(name: "ZenCODE.Tests.artifact-completion") { @TerminalChatActor in
                let clock = ArtifactCompletionClock()
                let capture = PrimaryScreenCapture(rows: 40, columns: 100)
                let screen = capture.screen()
                screen.commitFooter(
                    geometry: .init(rows: 40, columns: 100), reservedRows: 4,
                    sequence: "\u{1B}[37;1HPROMPT| draft\u{1B}[40;1HSTATUS| ready"
                )
                screen.positionOutputForTesting(row: 1)
                screen.append("PERMANENT| earlier transcript\n")
                let renderer = makeRenderer(clock: clock)
                await renderer.usePrimaryScreenForTesting(screen)
                let backend = ArtifactCompletionBackend(
                    directory: directory, toolName: toolName, status: status,
                    delegated: delegated, clock: clock
                )
                let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
                let terminal = TerminalChat(
                    configuration: try AgentConfiguration(
                        hostedModelID: "test-model", availableAgents: AgentProfileStore.defaultProfiles(),
                        availableModels: [AgentSettingsModelManifest(
                            id: "test-model", kind: .remoteAPI, modelID: "local/test-model"
                        )],
                        workingDirectory: directory
                    ),
                    stdinIsTerminal: false, sessionRunner: runner,
                    telegramTransportFactory: nil, renderCoordinator: renderer
                )
                await backend.setProbes(
                    started: {
                        let output = capture.history + "\n" + capture.visible
                        #expect(output.contains(toolName))
                        #expect(output.contains("⏳"))
                        if delegated {
                            #expect(await renderer.snapshot().activeSubAgentOverviewRowCount > 0)
                        } else {
                            #expect(await renderer.snapshot().activeToolCallID != nil)
                        }
                    },
                    completed: { @TerminalChatActor call, result in
                        // Observe the real physical transcript while generation
                        // is still running, rather than concatenating writes
                        // (which would include rows already erased in the TTY).
                        let output = capture.history + "\n" + capture.visible
                        #expect(output.contains("PERMANENT| earlier transcript"))
                        #expect(output.contains("PROMPT| draft"))
                        #expect(output.contains("STATUS| ready"))
                        #expect(!output.contains("⏳"))
                        #expect(output.components(separatedBy: toolName).count - 1 == 1)
                        let completionRows = output.components(separatedBy: "\n")
                            .filter { $0.contains("✅") || $0.contains("⚠️") }
                        #expect(completionRows.count == 1)
                        let row = try #require(completionRows.first)
                        #expect(row.contains(status == .completed ? "✅" : "⚠️"))
                        #expect(row.contains("1.20s"))
                        #expect(output.components(separatedBy: "1 │ +let completed = 42").count - 1 == 1)
                        #expect(!output.contains("generation ended"))
                        #expect(await terminal.fileArtifactHistory.snapshot().isEmpty)
                        #expect(await renderer.snapshot().activeToolCallID == nil)

                        // An already published artifact must not clear a live
                        // overview or disturb its clock/status presentation.
                        let bytesBeforeDuplicate = capture.bytes
                        let context = try #require(terminal.activeFileArtifactTurn)
                        await terminal.publishLiveFileArtifacts(
                            result, callID: call.id,
                            agentID: delegated ? "worker" : nil, context: context
                        )
                        #expect(capture.bytes == bytesBeforeDuplicate)
                    }
                )
                let success = try await terminal.generateResponse(attempt: TerminalPromptAttempt(
                    prompt: "write the file", attachments: [], origin: .local,
                    locksResponseLanguage: false, purpose: .normal
                ))
                #expect(success.response.text == "generation ended")
                #expect(await backend.didProbeCompletion())
                let output = capture.history + "\n" + capture.visible
                #expect(!output.contains("⏳"))
                #expect(output.components(separatedBy: "1 │ +let completed = 42").count - 1 == 1)
                #expect(terminal.activeFileArtifactTurn == nil)
                await runner.shutdown()
            }.value
        }
    }

    private func makeRenderer(clock: ArtifactCompletionClock) -> TerminalChatRenderCoordinator {
        TerminalChatRenderCoordinator(
            stdinIsTerminal: false, standardOutput: nil, standardError: nil,
            standardOutputIsTerminal: true, standardErrorIsTerminal: true,
            cursorTopology: .shared, capturesWrites: true, streamingFlushDelay: nil,
            toolNow: { clock.now }, columnWidthProvider: { 100 }
        )
    }
}

private final class ArtifactCompletionClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(by duration: Duration) { instant.withLock { $0 = $0.advanced(by: duration) } }
}

private actor ArtifactCompletionBackend: AgentRuntimeBackend {
    private let directory: URL
    private let toolName: String
    private let status: DirectAgentToolResult.Status
    private let delegated: Bool
    private let clock: ArtifactCompletionClock
    private let overviewBatchID = UUID()
    private var currentCall: DirectAgentToolCall?
    private var rootSessionID = "default"
    private var handler: DirectSubAgentToolEventHandler?
    private var startedProbe: (@Sendable () async throws -> Void)?
    private var completedProbe: (@Sendable (DirectAgentToolCall, DirectAgentToolResult) async throws -> Void)?
    private var probedCompletion = false

    init(
        directory: URL, toolName: String, status: DirectAgentToolResult.Status,
        delegated: Bool, clock: ArtifactCompletionClock
    ) {
        self.directory = directory
        self.toolName = toolName
        self.status = status
        self.delegated = delegated
        self.clock = clock
    }

    func setProbes(
        started: @escaping @Sendable () async throws -> Void,
        completed: @escaping @Sendable (DirectAgentToolCall, DirectAgentToolResult) async throws -> Void
    ) {
        startedProbe = started
        completedProbe = completed
    }
    func didProbeCompletion() -> Bool { probedCompletion }
    func updateSubAgentToolEventHandler(_ handler: DirectSubAgentToolEventHandler?) { self.handler = handler }
    func createSession(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func createSessionIfNeeded(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func updateSessionOptions(id: String, systemPrompt: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func closeSession(id: String) {}
    func shutdown() {}
    func preloadModel(onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String { "test-model" }
    func activeToolDescriptors() -> [DirectToolDescriptor] { [] }

    func subAgentSnapshots() -> [DirectSubAgentRuntime.AgentSnapshot] {
        guard delegated, let call = currentCall else { return [] }
        return [.init(
            id: "worker", rootSessionID: rootSessionID, name: "worker", role: "file writer",
            overviewBatchID: overviewBatchID, isInCurrentOverviewWave: true,
            status: .running, pending: true,
            currentToolName: call.name, currentToolTarget: "Completed.swift",
            latestOutput: nil, latestError: nil, createdAt: .now, updatedAt: .now
        )]
    }

    func sendPrompt(
        sessionID: String, prompt: String, attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        rootSessionID = sessionID
        // Both legacy and canonical names carry the same descriptor-owned
        // presentation; content is an argument, not a source-preview renderer.
        let presentation = DirectToolCatalog.baseDescriptors.first { $0.name == "local.writeFile" }?.presentation
        let call = presentedToolCall(
            id: "completed-write", name: toolName,
            argumentsObject: ["path": "Completed.swift", "content": "let completed = 42\n"],
            argumentsJSON: #"{"path":"Completed.swift","content":"let completed = 42\n"}"#,
            presentation: presentation
        )
        if delegated {
            currentCall = call
            await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .started))
        } else {
            await onEvent(.toolCallStarted(call))
        }
        try await startedProbe?()
        clock.advance(by: .milliseconds(1_200))
        // A failed write can still have changed a file before its later step
        // failed. Keep actual disk mutation and captured evidence consistent.
        try Data("let completed = 42\n".utf8).write(to: directory.appendingPathComponent("Completed.swift"))
        let result = DirectAgentToolResult(
            output: status == .completed ? "Updated" : "Tool error: stopped after writing",
            summary: "Updated", status: status,
            fileChanges: [.init(path: "Completed.swift", oldText: nil, newText: "let completed = 42\n")]
        )
        if delegated {
            await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .completed(result)))
        } else {
            await onEvent(.toolCallCompleted(call, result))
        }
        try await completedProbe?(call, result)
        probedCompletion = true
        await onEvent(.content("generation ended"))
        return DirectAgentResponse(text: "generation ended", stopReason: "end_turn", modelID: "test-model")
    }
}
