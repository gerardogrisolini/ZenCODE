import Foundation
import Testing
@testable import ZenCODECore

@Suite struct ConservativeMemoryLearningBackendTests {
    private func toolCall(id: String, name: String, args: [String: Any]) throws -> DirectAgentToolCall {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self)
        return DirectAgentToolCall(id: id, name: name, argumentsObject: args, argumentsJSON: json)
    }
    private func backend(_ mock: MemoryProposalMockBackend) async throws -> AgentCoreBackend {
        let configuration = AgentCoreSessionConfiguration(sessionID: "root", modelID: "same-model",
            workingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            systemPrompt: "User system instructions", cacheKey: "user-cache-key", history: [], allowedToolNames: ["memory.write"],
            maxToolRounds: 2, maxOutputTokens: 1024)
        let core = AgentCoreBackend(configuration: configuration.runtimeConfiguration, backendFactory: { config, _ in
            #expect(config.modelID == "same-model")
            #expect(config.maxOutputTokens == 1024)
            #expect(config.maxToolRounds == 2)
            return mock
        })
        await core.createSession(id: "root", cwd: configuration.workingDirectory.path,
            systemPrompt: "User system instructions", cacheKey: "user-cache-key", allowedToolNames: ["memory.write"])
        let response = try await core.sendPrompt(sessionID: "root", prompt: "normal", onEvent: { _ in })
        #expect(response.text == "normal response")
        return core
    }

    @Test func normalRunnerResponseWithoutEvidenceDoesNotRequestExtraction() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let mock = MemoryProposalMockBackend()
            let runner = AgentCoreSessionRunner(backendFactory: { _, _ in mock })
            let configuration = AgentCoreSessionConfiguration(sessionID: "root", modelID: "same-model",
                workingDirectory: workspace.workspaceURL, systemPrompt: nil, cacheKey: nil, history: [],
                allowedToolNames: ["memory.write"])
            let response = try await runner.sendPrompt(configuration: configuration, prompt: "hello", attachments: [], onEvent: { _ in })
            #expect(response.text == "normal response")
            #expect(await mock.requests.isEmpty)
            await runner.shutdown()
        }
    }

    @Test func readOnlyProfileSkipsExtractionEvenWithVerifiedDelta() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let fix = try toolCall(id: "fix", name: "local.editFile",
                args: ["path": "Sources/A.swift", "old": "a", "new": "b"])
            let verify = try toolCall(id: "verify", name: "swift.build",
                args: ["path": workspace.workspaceURL.path])
            let mock = MemoryProposalMockBackend(rootEvents: [
                .toolCallStarted(fix), .toolCallCompleted(fix, .init(output: "Updated.", summary: "Updated.")),
                .toolCallStarted(verify), .toolCallCompleted(verify, .init(output: "command: swift build\nstatus: success (exit 0)", summary: "Built."))
            ])
            let runner = AgentCoreSessionRunner(backendFactory: { _, _ in mock })
            let configuration = AgentCoreSessionConfiguration(sessionID: "root", modelID: "same-model",
                workingDirectory: workspace.workspaceURL, systemPrompt: nil, cacheKey: nil, history: [],
                allowedToolNames: ["memory.read", "memory.search"])
            let response = try await runner.sendPrompt(configuration: configuration, prompt: "fix", attachments: [], onEvent: { _ in })
            #expect(response.text == "normal response")
            #expect(await mock.requests.isEmpty)
            await runner.shutdown()
        }
    }

    @Test func isolatedRequestHasNoToolsHistoryRecallOrUserCacheAndCloses() async throws {
        let mock = MemoryProposalMockBackend()
        let core = try await backend(mock)
        let text = try await MemoryTurnContext.$currentTurnMemoryBlock.withValue("RECALLED SECRET CLAIM") {
            try await core.proposeMemory(parentSessionID: "root", prompt: "bounded evidence", systemPrompt: "extract only",
                permit: MemoryLearningPermit(), timeout: .seconds(1))
        }
        #expect(text == "null")
        let requests = await mock.requests
        #expect(requests.count == 1)
        #expect(requests[0].isolated)
        #expect(requests[0].recall == nil)
        #expect(requests[0].snapshot.allowedToolNames == [])
        #expect(requests[0].snapshot.history.isEmpty)
        #expect(requests[0].snapshot.cacheKey == nil)
        #expect(requests[0].snapshot.systemPrompt == "extract only")
        #expect(await mock.sessionIDs == ["root"])
        #expect(await core.snapshotSession(id: "root")?.cacheKey == "user-cache-key")
        await core.shutdown()
    }

    @Test func attemptedToolCallIsRejectedAndNotReturnedAsCandidate() async throws {
        let mock = MemoryProposalMockBackend(attemptTool: true)
        let core = try await backend(mock)
        await #expect(throws: CancellationError.self) {
            _ = try await core.proposeMemory(parentSessionID: "root", prompt: "evidence", systemPrompt: "extract",
                permit: MemoryLearningPermit())
        }
        #expect(await mock.sessionIDs == ["root"])
        await core.shutdown()
    }

    @Test func timeoutCancellationAndInvalidationJoinAndCleanUp() async throws {
        for mode in 0..<3 {
            let mock = MemoryProposalMockBackend(wait: true)
            let core = try await backend(mock)
            let permit = MemoryLearningPermit()
            let work = Task {
                try await core.proposeMemory(parentSessionID: "root", prompt: "evidence", systemPrompt: "extract",
                    permit: permit, timeout: .milliseconds(mode == 0 ? 20 : 1000))
            }
            while await mock.requests.isEmpty { await Task.yield() }
            if mode == 1 { work.cancel() }
            if mode == 2 { permit.invalidate(); await core.clearSession(id: "root") }
            do { _ = try await work.value; Issue.record("Expected cancelled extraction") } catch {}
            #expect(await mock.sessionIDs.allSatisfy { $0 == "root" })
            await core.shutdown()
        }
    }

    @Test func executorDeniesEvenForgedCallBeforeFilesystemSideEffects() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executor = DirectToolExecutor(subAgentBackendFactory: { MemoryProposalMockBackend() })
        let call = try toolCall(id: UUID().uuidString, name: "local.writeFile",
            args: ["path": path.path, "content": "must not exist"])
        let result = await MemoryConsolidationContext.$isIsolated.withValue(true) {
            await executor.execute(sessionID: "isolated", toolCall: call, workingDirectory: path.deletingLastPathComponent(), allowedToolNames: nil)
        }
        #expect(result.status == .permissionDenied)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
}

private actor MemoryProposalMockBackend: AgentRuntimeBackend {
    struct Request: Sendable {
        let snapshot: AgentRuntimeSessionSnapshot
        let isolated: Bool
        let recall: String?
        let prompt: String
    }
    var requests: [Request] = []
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    var sessionIDs: [String] { sessions.keys.sorted() }
    let attemptTool: Bool
    let wait: Bool
    let rootEvents: [DirectAgentEvent]
    let proposal: String
    init(attemptTool: Bool = false, wait: Bool = false, rootEvents: [DirectAgentEvent] = [], proposal: String = "null") {
        self.attemptTool = attemptTool; self.wait = wait; self.rootEvents = rootEvents
        self.proposal = proposal
    }
    func createSession(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?,
                       allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {
        sessions[id] = AgentRuntimeSessionSnapshot(sessionID: id, workingDirectoryPath: cwd,
            systemPrompt: systemPrompt, cacheKey: cacheKey, history: history, allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection, preserveThinking: preserveThinking)
    }
    func createSessionIfNeeded(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?,
                              allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {
        if sessions[id] == nil {
            createSession(id: id, cwd: cwd, systemPrompt: systemPrompt, history: history, cacheKey: cacheKey,
                allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection, preserveThinking: preserveThinking)
        }
    }
    func updateSessionOptions(id: String, systemPrompt: String?, allowedToolNames: Set<String>?,
                              thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func closeSession(id: String) async { sessions.removeValue(forKey: id) }
    func shutdown() async { sessions.removeAll() }
    func preloadModel(onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String { "same-model" }
    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }
    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] { [] }
    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? { sessions[id] }
    func sendPrompt(sessionID: String, prompt: String, attachments: [AgentRuntimeAttachment],
                    onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> DirectAgentResponse {
        guard let session = sessions[sessionID] else { throw CancellationError() }
        guard sessionID != "root" else {
            for event in rootEvents { await onEvent(event) }
            return .init(text: "normal response", stopReason: "stop", modelID: "same-model")
        }
        requests.append(Request(snapshot: session, isolated: MemoryConsolidationContext.isIsolated,
                                recall: MemoryTurnContext.currentTurnMemoryBlock, prompt: prompt))
        if attemptTool {
            await onEvent(.toolCallStarted(.init(id: "forged", name: "local.writeFile", argumentsObject: [:], argumentsJSON: "{}")))
        }
        while wait, sessions[sessionID] != nil { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
        if wait { throw CancellationError() }
        return .init(text: proposal, stopReason: "stop", modelID: "same-model")
    }
}

extension ConservativeMemoryLearningBackendTests {
    @Test func runnerRebuildPreservesExhaustedBudgetAndLogicalResetReleasesIt() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let mock = MemoryProposalMockBackend()
            let runner = AgentCoreSessionRunner(backendFactory: { _, _ in mock })
            let configuration = AgentCoreSessionConfiguration(sessionID: "root", modelID: "same-model",
                workingDirectory: workspace.workspaceURL, systemPrompt: nil, cacheKey: nil, history: [], allowedToolNames: ["memory.write"])
            _ = try await runner.sendPrompt(configuration: configuration, prompt: "hello", attachments: [], onEvent: { _ in })
            let original = try #require(await runner.memoryLearningPermits["root"])
            for _ in 0..<3 { #expect(original.reserve(event: UUID())) }
            await runner.rebuildSession(id: "root")
            _ = try await runner.sendPrompt(configuration: configuration, prompt: "hello", attachments: [], onEvent: { _ in })
            let rebuilt = try #require(await runner.memoryLearningPermits["root"])
            #expect(rebuilt !== original)
            #expect(!original.reserve(event: UUID()))
            #expect(!rebuilt.reserve(event: UUID()))
            try await runner.resetSessionThrowing(id: "root")
            #expect(await runner.memoryLearningPermits["root"] == nil)
            _ = try await runner.sendPrompt(configuration: configuration, prompt: "hello", attachments: [], onEvent: { _ in })
            let fresh = try #require(await runner.memoryLearningPermits["root"])
            #expect(fresh.reserve(event: UUID()))
            await runner.shutdown()
            #expect(!fresh.canPropose)
            #expect(await runner.memoryLearningPermits.isEmpty)
        }
    }

    @Test func runnerBackendChangeLeavesTwoReservationsAfterOneMutation() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let runner = AgentCoreSessionRunner(backendFactory: { _, _ in MemoryProposalMockBackend() })
            let originalConfig = AgentCoreSessionConfiguration(sessionID: "root", modelID: "first-model",
                workingDirectory: workspace.workspaceURL, systemPrompt: nil, cacheKey: nil, history: [], allowedToolNames: ["memory.write"])
            _ = try await runner.sendPrompt(configuration: originalConfig, prompt: "hello", attachments: [], onEvent: { _ in })
            let original = try #require(await runner.memoryLearningPermits["root"])
            #expect(original.reserve(event: UUID()))
            let replacementConfig = AgentCoreSessionConfiguration(sessionID: "root", modelID: "second-model",
                workingDirectory: workspace.workspaceURL, systemPrompt: nil, cacheKey: nil, history: [], allowedToolNames: ["memory.write"])
            _ = try await runner.sendPrompt(configuration: replacementConfig, prompt: "hello", attachments: [], onEvent: { _ in })
            let replacement = try #require(await runner.memoryLearningPermits["root"])
            #expect(replacement !== original)
            #expect(!original.reserve(event: UUID()))
            #expect(replacement.reserve(event: UUID()))
            #expect(replacement.reserve(event: UUID()))
            #expect(!replacement.reserve(event: UUID()))
            try await runner.closeSessionThrowing(id: "root")
            #expect(await runner.memoryLearningPermits["root"] == nil)
            #expect(!replacement.canPropose)
            await runner.shutdown()
        }
    }
}

extension ConservativeMemoryLearningBackendTests {
    @Test(arguments: ["lesson", "null", "already-noted"])
    func runnerConsolidatesVerifiedLessonWithoutContaminatingRoot(mode: String) async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            try await MemoryEmbedding.withProvider(LearningTestEmbeddingProvider()) {
                let source = workspace.workspaceURL.appendingPathComponent("Sources/Widget.swift")
                try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "let count = 0\n".write(to: source, atomically: true, encoding: .utf8)
                let graphURL = workspace.graphURL()
                let lesson = "Widget count starts at one; zero violates WidgetTests.testInitialCount."
                if mode == "already-noted" {
                    var graph = MemoryGraph()
                    graph.addMemory(EngineMemoryEntry(id: "manual-widget-count", category: .fact,
                        content: "Summary: \(lesson)\nNext: Sources/Widget.swift: retain the one-based counter."))
                    try await JSONMemoryPersistence(url: graphURL).save(graph)
                }
                // Empty args use the real Swift adapter's default session workspace.
                let failure = try toolCall(id: "widget-test-failure", name: "swift.test", args: [:])
                let fix = try toolCall(id: "widget-count-edit", name: "local.editFile",
                    args: ["path": "Sources/Widget.swift", "old": "let count = 0", "new": "let count = 1"])
                let verify = try toolCall(id: "widget-test-verification", name: "swift.test", args: [:])
                let failedOutput = """
                command: swift test
                status: failed (exit 1)
                exit_code: 1
                timed_out: false
                stdout_truncated: false
                stderr_truncated: false
                summary: WidgetTests.testInitialCount failed: expected count 1, got 0.
                """
                let passedOutput = """
                command: swift test
                status: passed (exit 0)
                exit_code: 0
                timed_out: false
                stdout_truncated: false
                stderr_truncated: false
                summary: WidgetTests.testInitialCount passed; 1 test, 0 failures.
                """
                let proposal = MemoryLearningProposal(kind: .lesson, content: lesson,
                    references: [failure.id, fix.id, verify.id], causeReferences: [fix.id],
                    prevention: "Sources/Widget.swift: retain the one-based counter.", existingID: nil)
                let proposalJSON = String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self)
                let mock = MemoryProposalMockBackend(rootEvents: [
                    .toolCallStarted(failure), .toolCallCompleted(failure, .init(output: failedOutput, summary: "Tests failed.")),
                    .toolCallStarted(fix), .toolCallCompleted(fix, .init(output: "Updated file. Replacements: 1.", summary: "Updated file.")),
                    .toolCallStarted(verify), .toolCallCompleted(verify, .init(output: passedOutput, summary: "Tests passed."))
                ], proposal: mode == "lesson" ? proposalJSON : "null")
                let registry = MemoryGraphStoreRegistry()
                let runner = AgentCoreSessionRunner(backendFactory: { _, _ in mock }, taskGraphStore: nil,
                    sessionTurnLease: AgentSessionTurnLease(), memoryGraphStoreRegistry: registry)
                let configuration = AgentCoreSessionConfiguration(sessionID: "root", modelID: "same-model",
                    workingDirectory: workspace.workspaceURL, systemPrompt: "Keep root instructions.", cacheKey: "root-cache",
                    history: [.init(role: .user, content: "Earlier root message.")],
                    allowedToolNames: ["swift.test", "local.editFile", "memory.write"])
                let response = try await runner.sendPrompt(configuration: configuration,
                    prompt: "Fix the initial Widget count regression.", attachments: [], onEvent: { _ in })
                #expect(response.text == "normal response")
                let requests = await mock.requests
                #expect(requests.count == 1)
                let request = try #require(requests.first)
                #expect(request.isolated)
                #expect(request.recall == nil)
                #expect(request.snapshot.allowedToolNames == [])
                #expect(request.snapshot.history.isEmpty)
                #expect(request.snapshot.cacheKey == nil)
                #expect(request.snapshot.systemPrompt == AgentCoreSessionRunner.memoryProposalInstructions)
                let input = try #require(try JSONSerialization.jsonObject(with: Data(request.prompt.utf8)) as? [String: Any])
                let evidence = try #require(input["evidence"] as? [[String: Any]])
                #expect(evidence.compactMap { $0["id"] as? String } == [failure.id, fix.id, verify.id])
                #expect(evidence.compactMap { $0["kind"] as? String } == ["failure", "correction", "verification"])
                #expect(evidence.compactMap { $0["location"] as? String } == [".", "Sources/Widget.swift", "."])
                #expect(evidence[1]["detail"] as? String == fix.argumentsJSON)
                let existing = try #require(input["existingForDedupOnly"] as? [[String: Any]])
                #expect(existing.compactMap { $0["id"] as? String } == (mode == "already-noted" ? ["manual-widget-count"] : []))
                #expect(await mock.sessionIDs == ["root"])
                let root = try #require(await mock.snapshotSession(id: "root"))
                #expect(root.cacheKey == "root-cache")
                #expect(root.systemPrompt == "Keep root instructions.")
                // The mock does not advance its own history, so the runner
                // restores the ordinary turn recorded from its tool events.
                // Only that turn may be added, never the isolated proposal.
                #expect(root.history.map(\.content) == [
                    "Earlier root message.",
                    "Fix the initial Widget count regression.",
                    "", failedOutput,
                    "", "Updated file. Replacements: 1.",
                    "", passedOutput
                ])
                #expect(root.history.compactMap(\.toolCallID) == [failure.id, fix.id, verify.id])
                #expect(root.history.flatMap(\.toolCalls).map(\.id) == [failure.id, fix.id, verify.id])
                // Load from disk, not the registry's in-memory snapshot.
                let persisted = try await JSONMemoryPersistence(url: graphURL).load()
                #expect(persisted.memories.count == (mode == "null" ? 0 : 1))
                if mode == "lesson" {
                    #expect(FileManager.default.fileExists(atPath: graphURL.path))
                    let entry = try #require(persisted.memories.values.first)
                    #expect(entry.content == "Summary: \(lesson)\nState: verified project lesson\nNext: Sources/Widget.swift: retain the one-based counter.\nSources: widget-test-failure@., widget-count-edit@Sources/Widget.swift, widget-test-verification@.")
                } else if mode == "already-noted" {
                    #expect(persisted.memories["manual-widget-count"]?.content == "Summary: \(lesson)\nNext: Sources/Widget.swift: retain the one-based counter.")
                }
                await runner.shutdown()
                await registry.reset()
            }
        }
    }
}

private struct LearningTestEmbeddingProvider: EmbeddingProvider {
    let modelID = "learning-test-embedding"
    func embed(_ text: String) async throws -> [Float] { [1, 0] }
}
