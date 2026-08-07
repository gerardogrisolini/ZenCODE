//
//  SharedChatInlineDeliveryTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore
import ToolCore

/// Covers the priority inline delivery of shared-chat messages: a message that
/// arrives while a turn is in flight is injected into the ``DirectAgentToolResult/modelOutput``
/// of the first tool boundary, instead of being deferred to the end of the turn.
///
/// The hold-back side (the mailbox is not drained while the agent or the
/// coordinator room is busy) is tested here for the sub-agent runtime; the
/// coordinator-room hold-back is covered by
/// ``AgentSharedChatCoordinatorTests/busyRoomHoldsBackMailboxDrainUntilTurnEnds()``.
@Suite
struct SharedChatInlineDeliveryTests {

    // MARK: - DirectToolExecutor: modelOutput injection

    /// A tool call whose participant has messages waiting in the shared-chat
    /// mailbox returns a result whose `modelOutput` carries the inline delivery
    /// block, while `output`, `summary` and `status` are byte-for-byte identical
    /// to the same call against an empty mailbox.
    @Test
    func inlineDeliveryInjectsMessagesIntoModelOutputAndPreservesOutputFields() async throws {
        let room = "inline-room-\(UUID().uuidString)"
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: room)
        _ = try await chat.registerAgent(id: "alpha", name: "alpha", roomID: room)

        // The coordinator executor (senderID nil) reads the room's coordinator
        // mailbox.
        let executor = DirectToolExecutor(
            authorizationHandler: { _ in false },
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            sharedChat: chat,
            sharedChatSenderID: nil,
            sharedChatRootSessionID: room,
            subAgentContextualBackendFactory: { _ in InlineDeliveryTestBackend() }
        )

        let toolCall = DirectAgentToolCall(
            id: "denied-exec",
            name: "local.exec",
            argumentsObject: ["command": "whoami"],
            argumentsJSON: #"{"command":"whoami"}"#
        )
        let workingDirectory = URL(fileURLWithPath: "/tmp")

        // Base case: empty mailbox — modelOutput is untouched.
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

        // With a waiting message the inline block is appended to modelOutput,
        // but the visible panel fields stay identical to the base case.
        let injected = await executor.execute(
            sessionID: room,
            toolCall: toolCall,
            workingDirectory: workingDirectory
        )
        #expect(injected.output == base.output)
        #expect(injected.summary == base.summary)
        #expect(injected.status == base.status)
        #expect(injected.attachments == base.attachments)
        #expect(injected.modelOutput.contains("hello from alpha"))
        #expect(
            injected.modelOutput.contains(
                "[Live chat messages received while you were working]"
            )
        )
        // modelOutput grew beyond the plain output.
        #expect(injected.modelOutput != injected.output)
        // The mailbox was drained by the execution, so a second call is clean.
        let afterDrain = await executor.execute(
            sessionID: room,
            toolCall: toolCall,
            workingDirectory: workingDirectory
        )
        #expect(afterDrain.modelOutput == afterDrain.output)
    }

    // MARK: - Recipient identity

    /// A child executor (senderID valued) reads its own agent mailbox; the
    /// coordinator executor (senderID nil) reads the room's coordinator mailbox.
    /// Neither crosses over to the other participant's mailbox.
    @Test
    func childAndCoordinatorExecutorsReadTheirOwnMailboxes() async throws {
        let room = "identity-room-\(UUID().uuidString)"
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: room)
        _ = try await chat.registerAgent(id: "child", name: "child", roomID: room)
        let coordinatorID = AgentSharedChat.coordinatorID(for: room)

        let coordinatorExecutor = DirectToolExecutor(
            authorizationHandler: { _ in false },
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            sharedChat: chat,
            sharedChatSenderID: nil,
            sharedChatRootSessionID: room,
            subAgentContextualBackendFactory: { _ in InlineDeliveryTestBackend() }
        )
        let childExecutor = DirectToolExecutor(
            authorizationHandler: { _ in false },
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            sharedChat: chat,
            sharedChatSenderID: "child",
            sharedChatRootSessionID: room,
            subAgentContextualBackendFactory: { _ in InlineDeliveryTestBackend() }
        )

        let toolCall = DirectAgentToolCall(
            id: "denied-exec",
            name: "local.exec",
            argumentsObject: ["command": "true"],
            argumentsJSON: #"{"command":"true"}"#
        )
        let cwd = URL(fileURLWithPath: "/tmp")

        // A message from the coordinator to the child lands in the *child's*
        // mailbox, not the coordinator's. The coordinator executor sees nothing;
        // the child executor sees it.
        try await chat.send(
            roomID: room,
            senderID: coordinatorID,
            destination: .direct(["child"]),
            text: "for the child only"
        )
        let coordinatorResult = await coordinatorExecutor.execute(
            sessionID: room,
            toolCall: toolCall,
            workingDirectory: cwd
        )
        #expect(coordinatorResult.modelOutput == coordinatorResult.output)
        let childResult = await childExecutor.execute(
            sessionID: room,
            toolCall: toolCall,
            workingDirectory: cwd
        )
        #expect(childResult.modelOutput.contains("for the child only"))

        // A message from the child to the coordinator lands in the
        // *coordinator's* mailbox. The child executor (whose mailbox is now
        // empty after the drain above) sees nothing; the coordinator executor
        // sees it.
        try await chat.send(
            roomID: room,
            senderID: "child",
            destination: .coordinator,
            text: "for the coordinator only"
        )
        let childResult2 = await childExecutor.execute(
            sessionID: room,
            toolCall: toolCall,
            workingDirectory: cwd
        )
        #expect(childResult2.modelOutput == childResult2.output)
        let coordinatorResult2 = await coordinatorExecutor.execute(
            sessionID: room,
            toolCall: toolCall,
            workingDirectory: cwd
        )
        #expect(coordinatorResult2.modelOutput.contains("for the coordinator only"))
    }

    /// A message whose sender is the draining participant is dropped by the
    /// inline delivery filter, so a broadcast echo cannot loop the agent onto
    /// itself. The bus itself never delivers a self-addressed message through
    /// its public `send` API (every destination resolves with
    /// `$0.id != senderID`), so this guard is a defensive backstop. It is
    /// exercised implicitly by every test above — each relies on the filter to
    /// avoid re-injecting a participant's own messages — and verified here in
    /// the positive direction: a foreign sender IS delivered, and the drain is
    /// destructive so the same message cannot be re-read on the next tool call.
    @Test
    func foreignSenderIsDeliveredAndDrainIsDestructive() async throws {
        let room = "drain-room-\(UUID().uuidString)"
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: room)
        _ = try await chat.registerAgent(id: "sender", name: "sender", roomID: room)

        let executor = DirectToolExecutor(
            authorizationHandler: { _ in false },
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            sharedChat: chat,
            sharedChatSenderID: nil,
            sharedChatRootSessionID: room,
            subAgentContextualBackendFactory: { _ in InlineDeliveryTestBackend() }
        )
        let toolCall = DirectAgentToolCall(
            id: "denied-exec",
            name: "local.exec",
            argumentsObject: ["command": "true"],
            argumentsJSON: #"{"command":"true"}"#
        )
        let cwd = URL(fileURLWithPath: "/tmp")

        try await chat.send(
            roomID: room,
            senderID: "sender",
            destination: .coordinator,
            text: "legitimate message"
        )

        let result = await executor.execute(
            sessionID: room,
            toolCall: toolCall,
            workingDirectory: cwd
        )
        #expect(result.modelOutput.contains("legitimate message"))

        // The drain consumed the mailbox, so a second tool call sees nothing.
        let result2 = await executor.execute(
            sessionID: room,
            toolCall: toolCall,
            workingDirectory: cwd
        )
        #expect(result2.modelOutput == result2.output)
    }

    // MARK: - Sub-agent hold-back

    /// A message delivered to an agent whose turn is in flight (`.running`) is
    /// neither drained from the mailbox nor queued as a pending prompt. The
    /// agent's own executor will surface it inline at the next tool boundary.
    @Test
    func runningAgentHoldsBackMessageInMailboxWithoutQueuing() async throws {
        let root = "holdback-root-\(UUID().uuidString)"
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
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-inline-holdback-\(UUID().uuidString)"),
            parentAllowedToolNames: nil,
            rootSessionID: root
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])
        let agentID = try #require(
            await runtime.snapshots().first { $0.name == "runner" }?.id
        )
        // Wait until the initial prompt is in flight so the agent is .running.
        try await backend.waitUntilPromptCount(1)

        // The coordinator sends a direct message to the running agent. Because
        // the agent has a turn in flight, the coordinator→direct path leaves the
        // mailbox untouched (inline delivery) instead of draining and queuing.
        let summary = try await runtime.messageSharedChat(
            arguments: [
                "id": .string(agentID),
                "message": .string("held back while running")
            ],
            rootSessionID: root,
            parentAllowedToolNames: nil
        )
        // The coordinator-facing summary explicitly states that no prompt was
        // queued and the message was delivered live.
        #expect(summary.contains("delivered live"))
        #expect(summary.contains("no prompt was queued"))

        let snapshot = try #require(await runtime.snapshots().first { $0.id == agentID })
        #expect(snapshot.status == .running)
        // No additional prompt was queued: the backend still has only the
        // initial prompt.
        #expect(await backend.promptCount() == 1)
        // The message is still in the agent's mailbox, untouched.
        let leftover = await runtime.sharedChat.drain(
            roomID: root,
            participantID: agentID,
            limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
        )
        #expect(leftover.map(\.text) == ["held back while running"])

        // Clean up: the mailbox was drained above to verify the hold-back, so
        // there is nothing left for the end-of-turn rearm to queue. Release the
        // blocked initial prompt and shut down.
        await backend.releasePrompt()
        await runtime.shutdown()
    }

    /// A message delivered to an idle agent (no turn in flight) is drained and
    /// queued as a pending prompt, exactly as before the inline optimisation.
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
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-inline-idle-\(UUID().uuidString)"),
            parentAllowedToolNames: nil,
            rootSessionID: root
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])
        let agentID = try #require(
            await runtime.snapshots().first { $0.name == "idle-worker" }?.id
        )
        // Let the initial prompt start, then release it so the agent settles
        // back to idle before the shared-chat message arrives.
        try await backend.waitUntilPromptCount(1)
        await backend.releasePrompt()
        try await Self.waitForAgentStatus(agentID: agentID, runtime: runtime) { $0 == .idle }

        // The agent is idle; the coordinator sends a direct message. The old
        // behaviour must be preserved: the mailbox is drained and a prompt is
        // queued, which the work loop picks up immediately.
        _ = try await runtime.messageSharedChat(
            arguments: [
                "id": .string(agentID),
                "message": .string("queued for the idle agent")
            ],
            rootSessionID: root,
            parentAllowedToolNames: nil
        )
        // The shared-chat prompt reached the backend, proving it was queued and
        // not held back.
        try await backend.waitUntilPromptCount(2)
        let lastPrompt = await backend.prompt(at: 1)
        #expect(lastPrompt?.contains("queued for the idle agent") == true)

        await backend.releasePrompt()
        await runtime.shutdown()
    }

    /// A message held back while the agent was running becomes a queued prompt
    /// when the turn ends: the end-of-turn re-arm drains the leftover mailbox.
    @Test
    func heldBackMessageBecomesQueuedPromptWhenTurnEnds() async throws {
        let root = "noloss-root-\(UUID().uuidString)"
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
                "name": .string("noloss-worker"),
                "profile": .string("Developer"),
                "prompt": .string("Initial")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-inline-noloss-\(UUID().uuidString)"),
            parentAllowedToolNames: nil,
            rootSessionID: root
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])
        let agentID = try #require(
            await runtime.snapshots().first { $0.name == "noloss-worker" }?.id
        )
        try await backend.waitUntilPromptCount(1)

        // Message arrives while the agent is running → held back in the mailbox.
        _ = try await runtime.messageSharedChat(
            arguments: [
                "id": .string(agentID),
                "message": .string("survive the hold-back")
            ],
            rootSessionID: root,
            parentAllowedToolNames: nil
        )
        #expect(await backend.promptCount() == 1)

        // The turn ends. The work-loop exit path re-arms the drain, which finds
        // the leftover message and queues it as a prompt.
        await backend.releasePrompt()
        try await backend.waitUntilPromptCount(2)
        let queuedPrompt = await backend.prompt(at: 1)
        #expect(queuedPrompt?.contains("survive the hold-back") == true)

        // The mailbox is now empty — the re-arm drained it.
        let mailboxLeftover = await runtime.sharedChat.drain(
            roomID: root,
            participantID: agentID,
            limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
        )
        #expect(mailboxLeftover.isEmpty)

        await backend.releasePrompt()
        await runtime.shutdown()
    }

    // MARK: - Helpers

    /// Polls the runtime snapshots until the target agent satisfies the
    /// predicate, with the same bounded-wait discipline used by the coordinator
    /// test suite.
    private static func waitForAgentStatus(
        agentID: String,
        runtime: DirectSubAgentRuntime,
        timeout: Duration = .seconds(5),
        satisfying predicate: @Sendable @escaping (DirectSubAgentRuntime.Status) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let snapshot = await runtime.snapshots().first(where: { $0.id == agentID }),
               predicate(snapshot.status)
            {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = try #require(
            await runtime.snapshots().first(where: { $0.id == agentID })
        )
        Issue.record("Agent \(agentID) did not reach expected status; current: \(snapshot.status)")
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

    func setBlocking(_ value: Bool) {
        shouldBlock = value
    }

    func promptCount() -> Int { prompts.count }

    func prompt(at index: Int) -> String? {
        guard index >= 0, index < prompts.count else { return nil }
        return prompts[index]
    }

    /// Waits until at least `count` prompts have been recorded, with a bounded
    /// deadline so a stuck work loop fails the test rather than hanging it.
    func waitUntilPromptCount(
        _ count: Int,
        timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if prompts.count >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if prompts.count < count {
            Issue.record("Expected \(count) prompts, got \(prompts.count)")
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
        if shouldBlock {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                releaseContinuations.append(continuation)
            }
        }
        return DirectAgentResponse(text: "done", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? { nil }
}
