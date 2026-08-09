//
//  SharedChatInlineDeliveryTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore
import ToolCore

/// Covers the shared-chat delivery contract after inline delivery was removed:
/// the executor never drains a mailbox or rewrites a tool result, and every
/// recipient — idle, running or standby — receives a live message as a serial
/// turn in its own work loop, queued by the mailbox drain, independent of any
/// future tool call. There is no post-delivery broadcast filter: every
/// participant the bus includes in a delivery receives its prompt.
///
/// The coordinator-room behaviour (the mailbox is drained even while a turn is
/// in flight, but the auto-trigger is held back until the room goes idle) is
/// covered by
/// ``AgentSharedChatCoordinatorTests/busyRoomDrainsMailboxToPendingButHoldsBackTriggerUntilTurnEnds()``.
@Suite(.timeLimit(.minutes(1)))
struct SharedChatInlineDeliveryTests {

    // MARK: - DirectToolExecutor: no mailbox drain, no modelOutput rewrite

    /// A tool call never touches the shared-chat mailbox: the result is returned
    /// byte-for-byte identical whether or not a message is waiting, and
    /// `modelOutput` always equals `output`. Delivery is now handled exclusively
    /// by the mailbox drain, not by the tool executor.
    @Test
    func executorDoesNotDrainMailboxOrModifyModelOutput() async throws {
        let room = "no-drain-room-\(UUID().uuidString)"
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: room)
        _ = try await chat.registerAgent(id: "alpha", name: "alpha", roomID: room)

        let executor = DirectToolExecutor(
            authorizationHandler: { _ in false },
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            sharedChat: chat,
            sharedChatSenderID: nil,
            sharedChatRootSessionID: room,
            subAgentContextualBackendFactory: { _ in InlineDeliveryTestBackend() }
        )

        let toolCall = DirectAgentToolCall(
            id: "exec",
            name: "local.exec",
            argumentsObject: ["command": "whoami"],
            argumentsJSON: #"{"command":"whoami"}"#
        )
        let workingDirectory = URL(fileURLWithPath: "/tmp")

        // Base case: empty mailbox.
        let base = await executor.execute(
            sessionID: room,
            toolCall: toolCall,
            workingDirectory: workingDirectory
        )
        #expect(base.modelOutput == base.output)

        // Put a message in the coordinator's mailbox.
        try await chat.send(
            roomID: room,
            senderID: "alpha",
            destination: .coordinator,
            text: "hello from alpha"
        )

        // The executor does not drain the mailbox: modelOutput stays equal to
        // output and the message is still sitting in the bus mailbox.
        let result = await executor.execute(
            sessionID: room,
            toolCall: toolCall,
            workingDirectory: workingDirectory
        )
        #expect(result.modelOutput == result.output)
        #expect(!result.modelOutput.contains("hello from alpha"))
        #expect(!result.modelOutput.contains("[Live chat messages"))
        let leftover = await chat.drain(
            roomID: room,
            participantID: AgentSharedChat.coordinatorID(for: room),
            limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
        )
        #expect(leftover.map(\.text) == ["hello from alpha"])
    }

    // MARK: - Sub-agent delivery: drain while running

    /// A message delivered to an agent whose turn is in flight (`.running`) is
    /// drained from the mailbox and queued as a pending prompt. The agent
    /// answers it as the next serial turn, the moment the current one ends —
    /// never deferred to a future tool call.
    @Test
    func runningAgentReceivesMessageAsQueuedPromptWhileTurnInFlight() async throws {
        let root = "running-root-\(UUID().uuidString)"
        let backend = InlineDeliveryTestBackend()
        await backend.setBlocking(true)
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in
                AgentProfile(id: "dev", name: "Developer", tools: [])
            }
        )
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("runner"),
                "profile": .string("Developer"),
                "prompt": .string("Initial")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-running-\(UUID().uuidString)"),
            parentAllowedToolNames: nil,
            rootSessionID: root
        )
        let agentID = try #require(
            await runtime.snapshots().first { $0.name == "runner" }?.id
        )
        // Wait until the initial prompt is in flight so the agent is .running.
        await backend.waitUntilPromptCount(1)
        let mailboxDrain = MailboxDrainCompletion()
        try await runtime.installMailboxDrainCompletion(
            for: agentID,
            completion: mailboxDrain
        )

        // The coordinator sends a direct message to the running agent. The
        // mailbox is drained even while running and the message is queued.
        let summary = try await runtime.messageSharedChat(
            arguments: [
                "id": .string(agentID),
                "message": .string("queued while running")
            ],
            rootSessionID: root,
            parentAllowedToolNames: nil
        )
        // The coordinator-facing summary states the message was delivered live.
        #expect(summary.contains("Delivered live message"))

        // `onMessageAvailable` starts its drain in an unstructured task. The
        // fixture signals only after that task returned from the mailbox drain,
        // establishing the happens-before edge required before inspecting it.
        await mailboxDrain.waitForCompletion()
        let mailboxLeftover = await runtime.sharedChat.drain(
            roomID: root,
            participantID: agentID,
            limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
        )
        #expect(mailboxLeftover.isEmpty)

        // Releasing the initial prompt lets the current turn end; the queued
        // message becomes the next prompt.
        await backend.releasePrompt()
        await backend.waitUntilPromptCount(2)
        let queuedPrompt = await backend.prompt(at: 1)
        #expect(queuedPrompt?.contains("queued while running") == true)

        await backend.releasePrompt()
        await runtime.shutdown()
    }

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
                AgentProfile(id: "dev", name: "Developer", tools: [])
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

    /// A message queued while the agent was running is processed as the next
    /// serial turn when the current one ends.
    @Test
    func messageToRunningAgentIsProcessedAfterTurnEnds() async throws {
        let root = "serial-root-\(UUID().uuidString)"
        let backend = InlineDeliveryTestBackend()
        await backend.setBlocking(true)
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in
                AgentProfile(id: "dev", name: "Developer", tools: [])
            }
        )
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("serial-worker"),
                "profile": .string("Developer"),
                "prompt": .string("Initial")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-serial-\(UUID().uuidString)"),
            parentAllowedToolNames: nil,
            rootSessionID: root
        )
        let agentID = try #require(
            await runtime.snapshots().first { $0.name == "serial-worker" }?.id
        )
        await backend.waitUntilPromptCount(1)

        // Message arrives while the agent is running → drained and queued.
        _ = try await runtime.messageSharedChat(
            arguments: [
                "id": .string(agentID),
                "message": .string("survive the running turn")
            ],
            rootSessionID: root,
            parentAllowedToolNames: nil
        )
        #expect(await backend.promptCount() == 1)

        // The turn ends. The work loop picks up the queued message as the next
        // serial turn.
        await backend.releasePrompt()
        await backend.waitUntilPromptCount(2)
        let queuedPrompt = await backend.prompt(at: 1)
        #expect(queuedPrompt?.contains("survive the running turn") == true)

        // The mailbox is now empty — the drain consumed it.
        let mailboxLeftover = await runtime.sharedChat.drain(
            roomID: root,
            participantID: agentID,
            limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
        )
        #expect(mailboxLeftover.isEmpty)

        await backend.releasePrompt()
        await runtime.shutdown()
    }

    // MARK: - Broadcast reaches standby residents

    /// A `peers`/`all` broadcast must reach a standby resident: with the
    /// post-delivery broadcast filter removed, every participant the bus
    /// includes in a delivery receives its serialized prompt through the
    /// mailbox/work loop — no tool boundary, no dropped broadcast. The standby
    /// agent answers it as its next serial turn.
    @Test
    func broadcastReachesStandbyResidentAsAQueuedPrompt() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "workflow",
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "task-a",
                    title: "Implement",
                    execution: TaskExecutionSpec(executor: .subAgent)
                )
            ]
        )
        let backend = InlineDeliveryTestBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in
                AgentProfile(id: "dev", name: "Developer", tools: [])
            }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("standby-worker"),
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
                "prompt": .string("Do the work")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-broadcast-\(UUID().uuidString)"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        let agentID = try #require(
            await runtime.snapshots().first { $0.name == "standby-worker" }?.id
        )
        // The attempt completed and the graph is still active, so the agent is
        // parked in standby with its initial prompt already consumed.
        await runtime.waitForInlineDeliveryWorkLoop(agentID: agentID)
        #expect(await runtime.snapshots().first { $0.id == agentID }?.status == .standby)
        await backend.waitUntilPromptCount(1)

        // The coordinator broadcasts to every active participant. The standby
        // resident is one of them, so it must receive the prompt — it is no
        // longer filtered out after `sharedChat.send` declared it delivered.
        let summary = try await runtime.messageSharedChat(
            arguments: [
                "to": .string("all"),
                "message": .string("broadcast reaches standby")
            ],
            rootSessionID: "root",
            parentAllowedToolNames: nil
        )
        #expect(summary.contains("Delivered live message"))

        // The broadcast became the standby agent's next serial turn, with the
        // mailbox drained (the work loop consumed it).
        await backend.waitUntilPromptCount(2)
        let broadcastPrompt = await backend.prompt(at: 1)
        #expect(broadcastPrompt?.contains("broadcast reaches standby") == true)
        let mailboxLeftover = await runtime.sharedChat.drain(
            roomID: "root",
            participantID: agentID,
            limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
        )
        #expect(mailboxLeftover.isEmpty)

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
        rootSessionID: String
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
