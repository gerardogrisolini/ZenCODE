//
//  SharedChatInlineDeliveryTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore
import ToolCore

/// Covers the priority shared-chat delivery contract. A coordinator or delegated
/// agent already in a turn receives pending messages in the model-facing result
/// of its next tool call.
///
/// If the coordinator turn ends without another tool call, its normal synthetic
/// turn remains the fallback.
@Suite(.timeLimit(.minutes(1)))
struct SharedChatInlineDeliveryTests {

    // MARK: - DirectToolExecutor: coordinator inline delivery

    @Test(arguments: ["success", "authorizationDenied", "genericError"])
    func executorDeliversExactlyOneMailboxBatchPerResultBranch(branch: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inline-branches-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            let room = "branch-\(UUID().uuidString)"
            let chat = AgentSharedChat()
            _ = try await chat.registerCoordinator(roomID: room)
            _ = try await chat.registerAgent(id: "alpha", name: "alpha", roomID: room)
            let executor = DirectToolExecutor(
                authorizationHandler: { _ in false },
                swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
                sharedChat: chat,
                sharedChatRootSessionID: room,
                subAgentContextualBackendFactory: { _ in InlineDeliveryTestBackend() }
            )
            let toolCall: DirectAgentToolCall
            let expectedStatus: DirectAgentToolResult.Status
            switch branch {
            case "success":
                toolCall = DirectAgentToolCall(
                    id: branch, name: "local.pwd", argumentsObject: [:], argumentsJSON: "{}"
                )
                expectedStatus = .completed
            case "authorizationDenied":
                toolCall = DirectAgentToolCall(
                    id: branch, name: "local.exec",
                    argumentsObject: ["command": "whoami"],
                    argumentsJSON: #"{"command":"whoami"}"#
                )
                expectedStatus = .permissionDenied
            default:
                // Missing required arguments fail in dispatch, not authorization.
                toolCall = DirectAgentToolCall(
                    id: branch, name: "local.readFile", argumentsObject: [:], argumentsJSON: "{}"
                )
                expectedStatus = .failed
            }
            let base = await executor.execute(
                sessionID: room, toolCall: toolCall, workingDirectory: directory
            )
            #expect(base.status == expectedStatus)
            #expect(base.output.hasPrefix("Tool error:") == (branch == "genericError"))
            let baseElapsed = try #require(base.elapsed)
            #expect(baseElapsed >= .zero)

            let batchSize = AgentSharedChat.maximumMessagesPerInjectedPrompt
            for index in 0...batchSize {
                try await chat.send(
                    roomID: room, senderID: "alpha", destination: .coordinator,
                    text: "mailbox-marker-\(index)-end"
                )
            }
            let first = await executor.execute(
                sessionID: room, toolCall: toolCall, workingDirectory: directory
            )
            #expect(first.output == base.output)
            #expect(first.summary == base.summary)
            #expect(first.status == base.status)
            #expect(first.attachments == base.attachments)
            #expect(first.modelOutput.hasPrefix(base.modelOutput + "\n\n"))
            for index in 0..<batchSize {
                #expect(first.modelOutput.components(separatedBy: "mailbox-marker-\(index)-end").count == 2)
            }
            #expect(!first.modelOutput.contains("mailbox-marker-\(batchSize)-end"))
            // The inline delivery rebuilds the result: it keeps the time the
            // executor measured for the call.
            let firstElapsed = try #require(first.elapsed)
            #expect(firstElapsed >= .zero)

            // A second call must see exactly the one message left by the first drain.
            let second = await executor.execute(
                sessionID: room, toolCall: toolCall, workingDirectory: directory
            )
            #expect(second.output == base.output)
            #expect(second.summary == base.summary)
            #expect(second.modelOutput.components(separatedBy: "mailbox-marker-\(batchSize)-end").count == 2)
            #expect(!second.modelOutput.contains("mailbox-marker-0-end"))
            #expect(await chat.drain(
                roomID: room, participantID: AgentSharedChat.coordinatorID(for: room)
            ).isEmpty)
            let third = await executor.execute(
                sessionID: room, toolCall: toolCall, workingDirectory: directory
            )
            #expect(third.modelOutput == base.modelOutput)
        }
    }

    @Test
    func isolatedExecutorLeavesPendingMailboxUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inline-isolated-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            let room = "isolated-\(UUID().uuidString)"
            let chat = AgentSharedChat()
            _ = try await chat.registerCoordinator(roomID: room)
            _ = try await chat.registerAgent(id: "alpha", name: "alpha", roomID: room)
            let executor = DirectToolExecutor(
                swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
                sharedChat: chat,
                sharedChatRootSessionID: room,
                subAgentContextualBackendFactory: { _ in InlineDeliveryTestBackend() }
            )
            try await chat.send(
                roomID: room, senderID: "alpha", destination: .coordinator,
                text: "pending during isolation"
            )
            let result = await MemoryConsolidationContext.$isIsolated.withValue(true) {
                await executor.execute(
                    sessionID: room,
                    toolCall: DirectAgentToolCall(
                        id: "isolated", name: "local.pwd", argumentsObject: [:], argumentsJSON: "{}"
                    ),
                    workingDirectory: directory
                )
            }
            #expect(result.status == .permissionDenied)
            #expect(result.output == "Tools unavailable.")
            #expect(result.summary == result.output)
            #expect(result.modelOutput == result.output)
            #expect(result.attachments.isEmpty)
            #expect(result.elapsed == nil)
            let pending = await chat.drain(
                roomID: room, participantID: AgentSharedChat.coordinatorID(for: room)
            )
            #expect(pending.map(\.text) == ["pending during isolation"])
        }
    }

    @Test
    func delegatedAgentExecutorInjectsMailboxIntoCurrentModelTurn() async throws {
        let room = "agent-inline-room-\(UUID().uuidString)"
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: room)
        _ = try await chat.registerAgent(id: "worker", name: "worker", roomID: room)
        let executor = DirectToolExecutor(
            authorizationHandler: { _ in false },
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            sharedChat: chat,
            sharedChatSenderID: "worker",
            sharedChatRootSessionID: room,
            subAgentContextualBackendFactory: { _ in InlineDeliveryTestBackend() }
        )
        try await chat.send(
            roomID: room,
            senderID: AgentSharedChat.coordinatorID(for: room),
            destination: .direct(["worker"]),
            text: "reply before continuing your current work"
        )

        let result = await executor.execute(
            sessionID: "worker-session",
            toolCall: DirectAgentToolCall(
                id: "agent-exec",
                name: "local.exec",
                argumentsObject: ["command": "whoami"],
                argumentsJSON: #"{"command":"whoami"}"#
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        #expect(!result.output.contains("reply before continuing"))
        #expect(result.modelOutput.contains("reply before continuing your current work"))
        #expect(result.modelOutput.contains("Reply NOW"))
        #expect(result.modelOutput.contains("After replying, resume the work you were doing."))
        #expect(await chat.drain(roomID: room, participantID: "worker").isEmpty)
    }

    // MARK: - Sub-agent delivery: drain while running

    /// A message delivered to an idle agent (no turn in flight) is drained and
    /// queued as a pending prompt immediately, exactly as before.
    @Test
    func idleAgentQueuesMessageAsPendingPromptAsBefore() async throws {
        let root = "idle-root-\(UUID().uuidString)"
        let backend = InlineDeliveryTestBackend()
        await backend.setBlocking(true)
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in
                AgentProfile(id: AgentProfileRole.developer.rawValue, name: "Developer", role: .developer, tools: [])
            }
        )
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("idle-worker"),
                "profile": .string("Developer"),
                "prompt": .string("Initial")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-idle-\(UUID().uuidString)"),
            parentAllowedToolNames: nil,
            rootSessionID: root
        )
        let agentID = try #require(
            await runtime.snapshots().first { $0.name == "idle-worker" }?.id
        )
        // Let the initial prompt start, then release it so the agent settles
        // back to idle before the shared-chat message arrives.
        await backend.waitUntilPromptCount(1)
        await backend.releasePrompt()
        await runtime.waitForInlineDeliveryWorkLoop(agentID: agentID)
        #expect(await runtime.snapshots().first { $0.id == agentID }?.status == .idle)

        // The agent is idle; the coordinator sends a direct message. The
        // mailbox is drained and a prompt is queued, which the work loop picks
        // up immediately.
        _ = try await runtime.messageSharedChat(
            arguments: [
                "id": .string(agentID),
                "message": .string("queued for the idle agent")
            ],
            rootSessionID: root,
            parentAllowedToolNames: nil
        )
        // The shared-chat prompt reached the backend, proving it was queued.
        await backend.waitUntilPromptCount(2)
        let lastPrompt = await backend.prompt(at: 1)
        #expect(lastPrompt?.contains("queued for the idle agent") == true)

        await backend.releasePrompt()
        await runtime.shutdown()
    }
}

private extension DirectSubAgentRuntime {
    /// Replaces the runtime's wake-up callback with the same drain task plus a
    /// test-only completion signal. The signal fires after the drain returns,
    /// including its single-flight cleanup in `defer`, rather than when the
    /// callback merely schedules the task.
    func installMailboxDrainCompletion(
        for agentID: String,
        completion: MailboxDrainCompletion
    ) async throws {
        guard let agent = agents[agentID] else {
            throw DirectSubAgentRuntimeError.agentNotFound(agentID)
        }
        let runtime = self
        _ = try await sharedChat.registerAgent(
            id: agent.id,
            name: agent.name,
            roomID: agent.rootSessionID,
            onMessageAvailable: {
                Task(name: "ZenCODE.tests.shared-chat.agent-drain") {
                    await runtime.drainSharedChatMailbox(for: agentID)
                    await completion.markCompleted()
                }
            }
        )
    }

    /// The record owns exactly one work-loop task. Awaiting that task establishes
    /// the transition after a released prompt without guessing how long actor
    /// scheduling will take under parallel test load.
    func waitForInlineDeliveryWorkLoop(agentID: String) async {
        guard let task = agents[agentID]?.runTask else { return }
        await task.value
    }
}

/// One-shot completion edge from the callback-owned mailbox-drain task to the
/// test. Actor isolation makes either ordering safe: a completion recorded
/// before `waitForCompletion()` is retained, otherwise the waiter is resumed by
/// the drain's post-return signal.
private actor MailboxDrainCompletion {
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitForCompletion() async {
        guard !completed else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func markCompleted() {
        guard !completed else { return }
        completed = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

// MARK: - Minimal mock backend

/// Minimal backend that records every prompt and can block `sendPrompt` on
/// demand. Mirrors the pattern of ``SharedChatBoundsTestBackend`` and
/// ``TestAgentRuntimeBackend`` already used in the test target; kept private to
/// this file because the existing helpers are file-scoped.
private actor InlineDeliveryTestBackend: AgentRuntimeBackend {
    private var prompts: [String] = []
    private var shouldBlock = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var promptCountWaiters: [PromptCountWaiter] = []

    private struct PromptCountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    func setBlocking(_ value: Bool) {
        shouldBlock = value
    }

    func promptCount() -> Int { prompts.count }

    func prompt(at index: Int) -> String? {
        guard index >= 0, index < prompts.count else { return nil }
        return prompts[index]
    }

    /// A prompt is the delivery boundary this suite observes. Registering the
    /// waiter in the same actor that appends it makes the edge race-free without
    /// using a wall-clock polling budget.
    func waitUntilPromptCount(
        _ count: Int
    ) async {
        guard prompts.count < count else { return }
        await withCheckedContinuation { continuation in
            promptCountWaiters.append(
                PromptCountWaiter(count: count, continuation: continuation)
            )
        }
    }

    func releasePrompt() {
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations.removeAll()
    }

    // MARK: AgentRuntimeBackend

    func createSession(
        id: String, cwd: String, systemPrompt: String?,
        history: [AgentRuntimeMessage], cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {}

    func createSessionIfNeeded(
        id: String, cwd: String, systemPrompt: String?,
        history: [AgentRuntimeMessage], cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        createSession(
            id: id, cwd: cwd, systemPrompt: systemPrompt,
            history: history, cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id: String, systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {}

    func installTaskOrchestrator(_ orchestrator: SessionTaskOrchestrator) async {}

    func closeSubAgent(id: String) async -> Bool {
        releasePrompt()
        return false
    }

    func interruptSubAgents(rootSessionID: String) async -> Int { 0 }

    func updateBorrowedSubAgentToolExecutor(_ executor: AgentBorrowedToolExecutor?) async {}
    func updateToolProviders(_ providers: [AgentToolProvider], sessionID: String?) async {}
    func closeSession(id: String) async {}

    func shutdown() async {
        releasePrompt()
    }

    func compactSession(id: String, force: Bool) async -> AgentRuntimeSessionCompactionResult? {
        nil
    }

    func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] { [] }

    func sharedChatParticipants(rootSessionID: String) async -> [AgentSharedChat.Participant] { [] }

    func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String,
        messageID: UUID
    ) async throws -> AgentSharedChat.Delivery {
        throw DirectSubAgentBackendFactoryError.unavailable
    }

    func drainCoordinatorSharedChatMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] { [] }

    func sharedChatTranscriptMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] { [] }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        resumePromptCountWaiters()
        if shouldBlock {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                releaseContinuations.append(continuation)
            }
        }
        return DirectAgentResponse(text: "done", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? { nil }

    private func resumePromptCountWaiters() {
        let ready = promptCountWaiters.filter { prompts.count >= $0.count }
        promptCountWaiters.removeAll { prompts.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
