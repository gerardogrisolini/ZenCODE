//
//  SharedChatEndToEndTests.swift
//  ZenCODE
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

/// End-to-end coverage of the shared-chat path with real components and a mock
/// model backend. The bus (`AgentSharedChat`), the child executor
/// (`DirectToolExecutor` with a borrowed `agent.message` surface), the runtime
/// (`DirectSubAgentRuntime`) and the coordinator
/// (`AgentSharedChatCoordinator`) are all real: only the model backend is
/// replaced. These tests demonstrate the actual delivery path, not isolated
/// helpers:
///
/// - a child executor's borrowed `agent.message` to the coordinator is observed
///   exactly once and produces no new tool call;
/// - a direct bus message (not the `agent.message` tool) wakes a task-bound
///   standby agent and the backend receives the next prompt;
/// - a message to a running agent is processed as the next serial turn, without
///   any tool boundary;
/// - agent→agent traffic is rendered but never auto-triggers the coordinator;
/// - two active observations each receive the same `Message.id` exactly once.
@Suite
struct SharedChatEndToEndTests {

    // MARK: - 1. Child executor → coordinator via borrowed agent.message

    /// The child's `agent.message` tool call executes through the borrowed
    /// sub-agent executor (the real parent-runtime bridge), lands in the
    /// coordinator mailbox exactly once, and is observed as a single `.messages`
    /// event plus exactly one synthetic auto-trigger. No new tool call is
    /// produced: the child mailbox stays empty and the transcript contains a
    /// single message addressed only to the coordinator.
    @Test
    func childBorrowedAgentMessageToCoordinatorIsObservedExactlyOnceWithoutNewToolCall() async throws {
        let room = "room-\(UUID().uuidString)"
        let workingDirectory = try Self.temporaryDirectory(named: "SharedChatE2E-child")
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let backend = EndToEndRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in Self.developerProfile }
        )
        defer { Task { await runtime.shutdown() } }
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("child"),
                "profile": .string("Developer"),
                "prompt": .string("Do the work"),
            ],
            workingDirectory: workingDirectory,
            parentAllowedToolNames: nil,
            rootSessionID: room
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])
        let child = try #require(await runtime.snapshots().first)
        let chat = await runtime.sharedChat

        // The coordinator observes the very same bus the runtime registered the
        // child on. Attach the real observation directly: exact-once delivery
        // is a Core contract, not something a warm-up observer or TUI dedup may
        // establish on its behalf.
        let coordinator = Self.makeCoordinator(chat: chat, pollInterval: .seconds(60))
        defer { Task { await coordinator.stopAll() } }
        let subscription = await coordinator.observeSubscription(roomID: room)
        let observation = await Observation.make(stream: subscription.events)

        // The child executor borrows the parent runtime's coordination surface:
        // exactly the bridge a real delegated backend receives through
        // `updateBorrowedSubAgentToolExecutor`.
        let callCounter = ToolCallCounter()
        let childExecutor = DirectToolExecutor(
            borrowedSubAgentToolExecutor: { toolCall in
                await callCounter.record()
                return try await runtime.executeBorrowedSubAgentTool(
                    senderID: child.id,
                    rootSessionID: room,
                    toolCall: toolCall
                )
            },
            subAgentContextualBackendFactory: { _ in backend }
        )
        let result = await childExecutor.execute(
            sessionID: "\(child.id)_session",
            toolCall: Self.e2eToolCall(
                name: "agent.message",
                arguments: ["to": "coordinator", "message": "hello from child"]
            ),
            workingDirectory: workingDirectory,
            allowedToolNames: ["agent.message"]
        )
        #expect(result.status == .completed)
        #expect(result.output.contains("Delivered live message"))
        #expect(await callCounter.count == 1)

        await coordinator.poll(roomID: room)
        let events = await observation.wait(untilAtLeast: 2) { collected in
            collected.contains {
                $0.renderedMessages?.contains { $0.text == "hello from child" } == true
            } && collected.compactMap(\.autoTrigger).count == 1
        }
        // Exactly one `.messages` event carries the child's message, once.
        #expect(events.compactMap(\.renderedMessages).flatMap { $0 }
            .filter { $0.text == "hello from child" }.count == 1)
        // One synthetic coordinator turn, no more: the room is single-flight.
        #expect(events.compactMap(\.autoTrigger).count == 1)
        #expect(await coordinator.pendingMessageCount(roomID: room) == 0)

        // No new tool call: the child's mailbox is empty and the transcript
        // contains exactly the message the child sent, addressed only to the
        // coordinator.
        #expect(await chat.drain(roomID: room, participantID: child.id).isEmpty)
        let transcript = await chat.messages(roomID: room)
        #expect(transcript.count == 1)
        #expect(transcript.first?.recipientIDs == [AgentSharedChat.coordinatorID(for: room)])
        #expect(transcript.first?.sender.id == child.id)

        // Re-reading the complete transcript must remain raw-event idempotent.
        await coordinator.poll(roomID: room)
        let finalEvents = await observation.snapshot()
        #expect(finalEvents.compactMap(\.renderedMessages).flatMap { $0 }
            .filter { $0.text == "hello from child" }.count == 1)
        #expect(finalEvents.compactMap(\.autoTrigger).count == 1)

        await observation.cancel()
    }

    // MARK: - 2. Direct bus message wakes a task-bound standby agent

    /// A message delivered through `AgentSharedChat` directly — not through the
    /// `agent.message` tool (`messageAgents`) — wakes a task-bound agent parked
    /// in standby: its registered wake-up callback drains the mailbox and the
    /// work loop sends the shared-chat prompt to the backend as the next turn.
    @Test
    func directBusMessageWakesTaskBoundStandbyAgentAndBackendReceivesNextPrompt() async throws {
        let root = "root-\(UUID().uuidString)"
        let workingDirectory = try Self.temporaryDirectory(named: "SharedChatE2E-standby")
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: root,
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
        let backend = EndToEndRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in Self.developerProfile }
        )
        defer { Task { await runtime.shutdown() } }
        let chat = await runtime.sharedChat
        await runtime.installTaskOrchestrator(orchestrator)
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("standby-worker"),
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
                "prompt": .string("Do the work"),
            ],
            workingDirectory: workingDirectory,
            parentAllowedToolNames: nil,
            rootSessionID: root
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])
        let agentID = try #require(
            await runtime.snapshots().first { $0.name == "standby-worker" }?.id
        )
        try await Self.waitForAgentStatus(agentID: agentID, runtime: runtime) { $0 == .standby }
        try await backend.waitUntilPromptCount(1)

        // Direct bus delivery, from the coordinator identity: no tool call, no
        // `messageAgents` bridge.
        let delivery = try await chat.send(
            roomID: root,
            senderID: AgentSharedChat.coordinatorID(for: root),
            destination: .direct([agentID]),
            text: "wake up standby"
        )
        #expect(delivery.recipients.map(\.id) == [agentID])

        // The standby agent's wake-up callback drained the mailbox and the work
        // loop answered with a serial turn: the backend records the next prompt.
        try await backend.waitUntilPromptCount(2)
        let secondPrompt = await backend.prompt(at: 1)
        #expect(secondPrompt?.contains("wake up standby") == true)
        #expect(secondPrompt?.contains("[Live chat messages]") == true)
        #expect(await chat.drain(roomID: root, participantID: agentID).isEmpty)
    }

    // MARK: - 3. Message to a running agent → next serial turn, no tool call

    /// A message delivered to an agent whose turn is in flight is drained and
    /// queued as a pending prompt. It is answered by the next serial turn the
    /// moment the current one ends — never deferred to a future tool call.
    @Test
    func messageToRunningAgentIsProcessedInNextSerialTurnWithoutToolCall() async throws {
        let root = "root-\(UUID().uuidString)"
        let workingDirectory = try Self.temporaryDirectory(named: "SharedChatE2E-serial")
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let backend = EndToEndRuntimeBackend()
        await backend.setBlocking(true)
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in Self.developerProfile }
        )
        defer { Task { await runtime.shutdown() } }
        let chat = await runtime.sharedChat
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("serial-worker"),
                "profile": .string("Developer"),
                "prompt": .string("Initial"),
            ],
            workingDirectory: workingDirectory,
            parentAllowedToolNames: nil,
            rootSessionID: root
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])
        let agentID = try #require(
            await runtime.snapshots().first { $0.name == "serial-worker" }?.id
        )
        // The initial prompt is in flight: the agent is `.running`.
        try await backend.waitUntilPromptCount(1)

        // Deliver directly through the bus while the turn is in flight.
        let delivery = try await chat.send(
            roomID: root,
            senderID: AgentSharedChat.coordinatorID(for: root),
            destination: .direct([agentID]),
            text: "queued while running"
        )
        #expect(delivery.recipients.map(\.id) == [agentID])
        // No tool call and no immediate prompt: the in-flight turn is still
        // running, so the message is parked for the next serial turn.
        #expect(await backend.promptCount() == 1)

        // The current turn ends; the queued message becomes the next prompt.
        await backend.releasePrompt()
        try await backend.waitUntilPromptCount(2)
        let secondPrompt = await backend.prompt(at: 1)
        #expect(secondPrompt?.contains("queued while running") == true)
        #expect(secondPrompt?.contains("[Live chat messages]") == true)
        #expect(await chat.drain(roomID: root, participantID: agentID).isEmpty)

        // Let the second turn finish so shutdown is clean.
        await backend.releasePrompt()
    }

    // MARK: - 4. Agent→agent is rendered, never auto-triggers the coordinator

    /// A message from one agent to another never enters the coordinator mailbox.
    /// The coordinator still emits it as a `.messages` event for display, but
    /// must not mint a synthetic coordinator turn for a message it was not a
    /// recipient of.
    @Test
    func agentToAgentMessageIsRenderedWithoutCoordinatorAutoTrigger() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: room)
        _ = try await chat.registerAgent(id: "alpha", name: "alpha", roomID: room)
        _ = try await chat.registerAgent(id: "beta", name: "beta", roomID: room)
        let coordinator = Self.makeCoordinator(chat: chat, pollInterval: .seconds(60))
        defer { Task { await coordinator.stopAll() } }
        let subscription = await coordinator.observeSubscription(roomID: room)
        let observation = await Observation.make(stream: subscription.events)

        try await chat.send(
            roomID: room,
            senderID: "alpha",
            destination: .direct(["beta"]),
            text: "hey beta, what do you think?"
        )
        await coordinator.poll(roomID: room)

        let events = await observation.wait(untilAtLeast: 1) { collected in
            collected.contains {
                $0.renderedMessages?.contains { $0.text == "hey beta, what do you think?" } == true
            }
        }
        let rendered = events.compactMap(\.renderedMessages).flatMap { $0 }
        #expect(rendered.contains { $0.text == "hey beta, what do you think?" })
        // The raw coordinator stream itself is exactly once; the UI is not
        // needed to collapse a replay/poll overlap.
        #expect(rendered.filter { $0.text == "hey beta, what do you think?" }.count == 1)

        // No coordinator turn: the message never entered the coordinator
        // mailbox, so there is nothing to auto-trigger on.
        #expect(events.compactMap(\.autoTrigger).isEmpty)
        #expect(await coordinator.activeAutoTrigger(roomID: room) == nil)
        #expect(await coordinator.pendingMessageCount(roomID: room) == 0)

        await observation.cancel()
    }

    // MARK: - 5. Two active observations each get the same Message.id once

    /// Two active observations attached to the same room each receive the same
    /// `Message.id` exactly once. They are attached before the message without
    /// a warm-up observer: delivery is accounted independently by the Core.
    @Test
    func twoActiveObservationsEachReceiveTheSameMessageIDExactlyOnce() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: room)
        _ = try await chat.registerAgent(id: "alpha", name: "alpha", roomID: room)
        let coordinator = Self.makeCoordinator(chat: chat, pollInterval: .seconds(60))
        defer { Task { await coordinator.stopAll() } }
        let firstSubscription = await coordinator.observeSubscription(roomID: room)
        let first = await Observation.make(stream: firstSubscription.events)
        let secondSubscription = await coordinator.observeSubscription(roomID: room)
        let second = await Observation.make(stream: secondSubscription.events)

        let delivery = try await chat.send(
            roomID: room,
            senderID: "alpha",
            destination: .coordinator,
            text: "observed once by each"
        )
        let messageID = delivery.message.id
        await coordinator.poll(roomID: room)

        let firstEvents = await first.wait(untilAtLeast: 1) { collected in
            collected.contains {
                $0.renderedMessages?.contains { $0.id == messageID } == true
            }
        }
        let secondEvents = await second.wait(untilAtLeast: 1) { collected in
            collected.contains {
                $0.renderedMessages?.contains { $0.id == messageID } == true
            }
        }
        #expect(Self.countOccurrences(of: messageID, in: firstEvents) == 1)
        #expect(Self.countOccurrences(of: messageID, in: secondEvents) == 1)

        // A second complete transcript pass must remain raw-event idempotent.
        await coordinator.poll(roomID: room)
        #expect(Self.countOccurrences(of: messageID, in: await first.snapshot()) == 1)
        #expect(Self.countOccurrences(of: messageID, in: await second.snapshot()) == 1)

        await first.cancel()
        await second.cancel()
    }

    // MARK: - Helpers

    private static let developerProfile = AgentProfile(
        id: "dev",
        name: "Developer",
        tools: []
    )

    private static func makeCoordinator(
        chat: AgentSharedChat,
        pollInterval: Duration
    ) -> AgentSharedChatCoordinator {
        AgentSharedChatCoordinator(
            source: AgentSharedChatCoordinator.Source(
                drainCoordinatorMessages: { roomID in
                    await chat.drain(
                        roomID: roomID,
                        participantID: AgentSharedChat.coordinatorID(for: roomID),
                        limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
                    )
                },
                participants: { roomID in
                    await chat.participants(roomID: roomID)
                },
                allRoomMessages: { roomID in
                    await chat.messages(roomID: roomID)
                }
            ),
            pollInterval: pollInterval
        )
    }

    private static func countOccurrences(
        of messageID: UUID,
        in events: [AgentSharedChatCoordinatorEvent]
    ) -> Int {
        events.compactMap { event in
            guard case let .messages(messages) = event else { return 0 }
            return messages.filter { $0.id == messageID }.count
        }
        .reduce(0, +)
    }

    private static func e2eToolCall(
        name: String,
        arguments: [String: Any]
    ) -> DirectAgentToolCall {
        let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return DirectAgentToolCall(
            id: UUID().uuidString,
            name: name,
            argumentsObject: arguments,
            argumentsJSON: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        )
    }

    private static func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

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

// MARK: - Event helpers

private extension AgentSharedChatCoordinatorEvent {
    var renderedMessages: [AgentSharedChat.Message]? {
        guard case let .messages(messages) = self else { return nil }
        return messages
    }

    var autoTrigger: AgentSharedChatAutoTrigger? {
        guard case let .autoTrigger(trigger) = self else { return nil }
        return trigger
    }
}

/// Collects coordinator events without ever blocking a test forever: every wait
/// is bounded by a deadline and returns whatever has been observed so far.
private actor Observation {
    private var events: [AgentSharedChatCoordinatorEvent] = []
    private var task: Task<Void, Never>?

    static func make(
        stream: AsyncStream<AgentSharedChatCoordinatorEvent>
    ) async -> Observation {
        let observation = Observation()
        await observation.start(stream: stream)
        return observation
    }

    private func start(stream: AsyncStream<AgentSharedChatCoordinatorEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                await self?.append(event)
            }
        }
    }

    private func append(_ event: AgentSharedChatCoordinatorEvent) {
        events.append(event)
    }

    func snapshot() -> [AgentSharedChatCoordinatorEvent] {
        events
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func wait(
        untilAtLeast count: Int,
        timeout: Duration = .seconds(5),
        satisfying predicate: (@Sendable ([AgentSharedChatCoordinatorEvent]) -> Bool)? = nil
    ) async -> [AgentSharedChatCoordinatorEvent] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let current = events
            if current.count >= count, predicate?(current) ?? true {
                return current
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return events
    }
}

/// Counts borrowed-tool executions from a child executor.
private actor ToolCallCounter {
    private var executions = 0

    func record() {
        executions += 1
    }

    var count: Int { executions }
}

// MARK: - Minimal mock backend

/// Minimal backend that records every prompt and can block `sendPrompt` on
/// demand, so tests can hold an agent in `.running` or park it in standby
/// without a model provider. Mirrors the patterns used by
/// ``SharedChatInlineDeliveryTests`` and ``DirectSubAgentRuntimeTests``.
private actor EndToEndRuntimeBackend: AgentRuntimeBackend {
    private var prompts: [String] = []
    private var shouldBlock = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor?

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

    func executeBorrowedSubAgentTool(_ toolCall: AgentBorrowedToolCall) async throws -> String {
        guard let borrowedSubAgentToolExecutor else {
            throw DirectSubAgentBackendFactoryError.unavailable
        }
        return try await borrowedSubAgentToolExecutor(toolCall)
    }

    private func waitForRelease() async {
        guard shouldBlock else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    // MARK: AgentRuntimeBackend

    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

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

    func updateBorrowedSubAgentToolExecutor(_ executor: AgentBorrowedToolExecutor?) async {
        borrowedSubAgentToolExecutor = executor
    }

    func closeSession(id _: String) async {}

    func shutdown() async {
        releasePrompt()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }

    func sendPrompt(
        sessionID _: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        await waitForRelease()
        return DirectAgentResponse(
            text: "done",
            stopReason: "stop",
            modelID: "test-model"
        )
    }
}
