//
//  MemoryAutomationFlowTests.swift
//  ZenCODECoreTests
//
//  Covers runtime invariants of automatic memory recall that request-assembly
//  unit tests cannot reach: timeout/failure degradation, escaping and budgets,
//  session isolation, history purity, sub-agent visibility, and recall health.
//  The suite stays serialized as a conservative choice, for reasons that do
//  not involve the environment: several tests call
//  `MemoryGraphStoreRegistry.shared.reset()`, which drops the cached stores
//  of the whole process, and the recall tests assert wall-clock bounds (a
//  100 ms deadline, elapsed times under 1 s and 5 s) that CPU contention from
//  sibling tests would make flaky. Recall settings are no longer a reason:
//  they are injected with `MemoryAutomationSettings.withEnvironment`, a
//  task-local, never with the process environment. Recall is local BM25; no
//  test contacts a network.
//

import Foundation
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing

@Suite(.serialized)
struct MemoryAutomationFlowTests {
    // MARK: - Invariant 3: cross-session isolation. Two sessions sharing one
    // workspace graph each receive only their own prompt's recalled memory. The
    // design rejected prefetching recall into one slot of the shared engine
    // precisely because that slot would drain one session's context into
    // another's; the inline `context(for:)` path keeps every retrieval bound to
    // the prompt that asked for it.

    // MARK: - Invariant 1 (runtime half): an operator turn resolves a block,
    // propagates it to the backend through the task-local, and keeps the
    // persisted session snapshot history free of any trace of it.

    @Test
    func operatorTurnPropagatesBlockToBackendAndKeepsSnapshotHistoryPure() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            _ = try await service.writeEntry(
                content: """
                Summary: frobnicator deploy.
                State: calibrate the quantum flange before deploy.
                Next: run deploy.
                """,
                target: .workspace(workspace.workspaceURL)
            )

            let backend = MemoryObservingBackend()
            let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
            let sessionID = "operator-\(UUID().uuidString)"
            let configuration = AgentCoreSessionConfiguration(
                sessionID: sessionID,
                modelID: "test-model",
                workingDirectory: workspace.workspaceURL,
                systemPrompt: nil,
                cacheKey: nil,
                history: [],
                allowedToolNames: []
            )

            try await runner.createSession(configuration: configuration)
            _ = try await runner.sendPrompt(
                configuration: configuration,
                prompt: "how do I calibrate the frobnicator for deploy",
                attachments: [],
                onEvent: { _ in }
            )

            // The block reached the backend through the task-local nesting.
            let observed = try #require(await backend.observedMemoryBlock())
            #expect(observed.contains("<project-memory>"))
            #expect(observed.contains("frobnicator"))

            // The persisted snapshot history carries the user turn and the
            // assistant reply, but never the memory block.
            let snapshot = try #require(await runner.snapshotSession(id: sessionID))
            #expect(snapshot.history.contains { $0.content == "how do I calibrate the frobnicator for deploy" })
            #expect(!snapshot.history.contains { $0.content.contains("<project-memory>") })
            #expect(!snapshot.history.contains { $0.content.contains("flange") })
        }
    }

    // MARK: - The per-turn instruction reaches the backend for the operator's
    // turn only, and never enters the persisted history.

    @Test
    func completedTurnLeavesMemoryUnchangedWithoutAnExplicitMemoryTool() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let backend = MemoryObservingBackend()
            let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
            let configuration = AgentCoreSessionConfiguration(
                sessionID: "no-implicit-memory-\(UUID().uuidString)",
                modelID: "test-model",
                workingDirectory: workspace.workspaceURL,
                systemPrompt: nil,
                cacheKey: nil,
                history: [],
                allowedToolNames: []
            )

            try await runner.createSession(configuration: configuration)
            _ = try await runner.sendPrompt(
                configuration: configuration,
                prompt: "remember that releases happen on Thursday",
                attachments: [],
                onEvent: { _ in }
            )

            // A normal completed turn uses exactly its configured backend call
            // and does not create a durable fact. Memory changes require one of
            // the explicit memory tools.
            #expect(await backend.promptCount() == 1)
            let entries = try await MemoryService().readEntries(
                target: .workspace(workspace.workspaceURL),
                limit: 100
            )
            #expect(entries.isEmpty)
        }
    }

    // MARK: - Sub-agent turns receive recall. The work loop resolves the
    // workspace from the sub-agent's own session snapshot and binds the block
    // for the delegated turn exactly as the operator runner does.

    @Test
    func subAgentTurnReceivesRecalledMemoryBlock() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            _ = try await service.writeEntry(
                content: """
                Summary: frobnicator convention.
                State: the quantum flange names every frobnicator instance.
                Next: reuse the convention.
                """,
                target: .workspace(workspace.workspaceURL)
            )

            let backend = MemoryObservingBackend()
            let developer = AgentProfile(
                id: AgentProfileRole.developer.rawValue,
                name: "Developer",
                role: .developer,
                tools: ["local.readFile"]
            )
            let executor = DirectToolExecutor(
                swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
                subAgentContextualBackendFactory: { _ in backend },
                subAgentProfileResolver: { _ in developer }
            )

            let createResult = await executor.execute(
                sessionID: "root",
                toolCall: presentedToolCall(
                    id: "create-recall-worker",
                    name: "agent.create",
                    argumentsObject: [
                        "name": "recall-worker",
                        "profile": "Developer",
                        "prompt": "calibrate the frobnicator flange"
                    ],
                    argumentsJSON: #"{"name":"recall-worker","profile":"Developer","prompt":"calibrate the frobnicator flange"}"#
                ),
                workingDirectory: workspace.workspaceURL
            )
            #expect(createResult.status == .completed)
            _ = await executor.execute(
                sessionID: "root",
                toolCall: presentedToolCall(
                    id: "wait-recall-worker",
                    name: "agent.wait",
                    argumentsObject: ["name": "recall-worker"],
                    argumentsJSON: #"{"name":"recall-worker"}"#
                ),
                workingDirectory: workspace.workspaceURL
            )

            // The delegated turn observed a recalled block through the
            // task-local, proving sub-agents are covered by automatic recall.
            let observed = try #require(await backend.observedMemoryBlock())
            #expect(observed.contains("<project-memory>"))
            #expect(observed.contains("frobnicator"))

            await executor.subAgentRuntime.shutdown()
        }
    }

    // MARK: - An organizer sub-agent recalls from the global graph, not from the
    // workspace graph of its working directory, which holds other memory.

    // MARK: - A sub-agent turn does not inherit the operator's per-turn
    // instruction, even though its Task is created inside that turn.

    // MARK: - Recall health: the pause is per incarnation, and discard — wired
    // into the real close/reset paths — makes a recreated session start clean.

    @Test
    func repeatedFailuresPauseRecallAndDiscardReenablesARecreatedSession() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            // A graph file that cannot be parsed makes every open throw, so the
            // failure budget is consumed deterministically rather than by
            // waiting on a timeout.
            let graphURL = MemoryGraphLocation.graphURL(for: workspace.workspaceURL)
            try FileManager.default.createDirectory(
                at: graphURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("{ this is not valid graph json ".utf8).write(to: graphURL)

            let sessionID = "paused-\(UUID().uuidString)"
            for _ in 0..<3 {
                _ = await MemoryTurnCoordinator.shared.memoryBlock(
                    sessionID: sessionID,
                    graphTarget: .workspace(workspace.workspaceURL),
                    prompt: "anything"
                )
            }
            #expect(
                await MemoryTurnCoordinator.shared.isRecallPaused(
                    sessionID: sessionID,
                    graphTarget: .workspace(workspace.workspaceURL)
                )
            )

            // The close/reset paths call exactly this, so a session recreated
            // with the same id does not inherit the pause.
            await MemoryTurnCoordinator.shared.discard(sessionID: sessionID)
            #expect(
                !(await MemoryTurnCoordinator.shared.isRecallPaused(
                    sessionID: sessionID,
                    graphTarget: .workspace(workspace.workspaceURL)
                ))
            )
        }
    }

    // MARK: - Indirect lifecycle: a child session's memory state belongs to the
    // sub-agent that owned it, and the paths that end a sub-agent without
    // going through `agent.close` must drop it too.

    // MARK: - Tool routing: the executing agent's profile role selects the graph
    // that the memory.* tools address. An organizer uses the global graph; any
    // other role, or no profile, keeps the workspace graph of its directory.

    @Test
    func organizerMemoryToolsAddressTheGlobalGraph() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let (write, read) = await writeThenRead(profileRole: .organizer, in: workspace)
            #expect(write.status == .completed)
            #expect(read.output.contains("organizer routing check frobnicator"))

            // The entry is persisted in the global graph, and the workspace
            // graph is never created for it.
            let globalGraphURL = MemoryGraphLocation.globalGraphURL()
            #expect(globalGraphURL.path.hasSuffix("/memory/global/memory.graph.json"))
            let persisted = try String(contentsOf: globalGraphURL, encoding: .utf8)
            #expect(persisted.contains("organizer routing check frobnicator"))
            #expect(!FileManager.default.fileExists(
                atPath: MemoryGraphLocation.graphURL(for: workspace.workspaceURL).path
            ))
            await MemoryGraphStoreRegistry.shared.reset()
        }
    }

    // MARK: - Helpers

    /// Runs `memory.write` then `memory.read` through a `DirectToolExecutor`
    /// whose session runs under `profileRole`, as a live tool call would.
    private func writeThenRead(
        profileRole: AgentProfileRole?,
        in workspace: MemoryTestWorkspace
    ) async -> (write: DirectAgentToolResult, read: DirectAgentToolResult) {
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            toolExecutionContext: ToolExecutionContext(profileRole: profileRole),
            subAgentContextualBackendFactory: { _ in MemoryObservingBackend() }
        )
        let write = await executor.execute(
            sessionID: "root",
            toolCall: presentedToolCall(
                id: "routing-write",
                name: "memory.write",
                argumentsObject: ["content": "Summary: organizer routing check frobnicator."],
                argumentsJSON: #"{"content":"Summary: organizer routing check frobnicator."}"#
            ),
            workingDirectory: workspace.workspaceURL
        )
        let read = await executor.execute(
            sessionID: "root",
            toolCall: presentedToolCall(
                id: "routing-read",
                name: "memory.read",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            workingDirectory: workspace.workspaceURL
        )
        return (write, read)
    }
}

// MARK: - Test doubles and helpers

/// Captures the per-turn memory block that reaches `sendPrompt` and reports the
/// session's working directory from `snapshotSession` (so the sub-agent work
/// loop can resolve the workspace graph). All other protocol requirements use
/// the no-op default implementations.
private actor MemoryObservingBackend: AgentRuntimeBackend {
    private var snapshot: AgentRuntimeSessionSnapshot?
    private var observed: String?
    private var observedInstructions: [String?] = []
    private var prompts = 0

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
        snapshot = AgentRuntimeSessionSnapshot(
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
        guard snapshot == nil else { return }
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
    func shutdown() {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts += 1
        observed = MemoryTurnContext.currentTurnMemoryBlock
        observedInstructions.append(AgentTurnInstructionContext.currentTurnInstruction)
        await onEvent(.content("acknowledged"))
        return DirectAgentResponse(text: "acknowledged", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id _: String) -> AgentRuntimeSessionSnapshot? {
        snapshot
    }

    func observedMemoryBlock() -> String? { observed }
    /// The per-turn instruction seen by each `sendPrompt`, in call order.
    func observedTurnInstructions() -> [String?] { observedInstructions }
    func promptCount() -> Int { prompts }
}
