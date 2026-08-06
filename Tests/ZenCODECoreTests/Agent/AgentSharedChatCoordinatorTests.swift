//
//  AgentSharedChatCoordinatorTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

/// Covers the Core-owned auto-trigger: monitoring, drain batching and the
/// single-flight idle/busy decision that used to live in the terminal loop.
@Suite
struct AgentSharedChatCoordinatorTests {
    // MARK: - Idle

    @Test
    func idleCoordinatorMessageStartsExactlyOneSyntheticTurn() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: room, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .seconds(60))
        let observation = await Observation.make(stream: coordinator.observe(roomID: room))

        try await chat.send(
            roomID: room,
            senderID: "planner",
            destination: .coordinator,
            text: "status ready"
        )
        await coordinator.poll(roomID: room)

        let events = await observation.wait(untilAtLeast: 3)
        let triggers = events.compactMap(\.autoTrigger)
        #expect(triggers.count == 1)
        let trigger = try #require(triggers.first)
        #expect(trigger.messages.map(\.text) == ["status ready"])
        #expect(trigger.prompt.contains("status ready"))
        #expect(trigger.prompt.contains("@planner"))
        #expect(events.contains { $0.renderedMessages?.map(\.text) == ["status ready"] })
        #expect(await coordinator.pendingMessageCount(roomID: room) == 0)
        #expect(await coordinator.activeAutoTriggerID(roomID: room) == trigger.id)
        await observation.cancel()
    }

    /// The monitor lives in the Core: no consumer polling call is made here.
    @Test
    func coreMonitorDrainsWithoutAnyConsumerPolling() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: room, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .milliseconds(20))
        let observation = await Observation.make(stream: coordinator.observe(roomID: room))

        try await chat.send(
            roomID: room,
            senderID: "planner",
            destination: .coordinator,
            text: "monitored by core"
        )

        let events = await observation.wait(untilAtLeast: 1) { $0.contains { $0.autoTrigger != nil } }
        #expect(events.compactMap(\.autoTrigger).count == 1)
        await observation.cancel()
    }

    // MARK: - Busy

    @Test
    func busyRoomQueuesMessagesInsteadOfStartingAConcurrentTurn() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: room, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .seconds(60))
        let observation = await Observation.make(stream: coordinator.observe(roomID: room))
        // A turn is already running for this room.
        await coordinator.noteTurnStarted(roomID: room)

        try await chat.send(
            roomID: room,
            senderID: "planner",
            destination: .coordinator,
            text: "while busy"
        )
        await coordinator.poll(roomID: room)

        var events = await observation.wait(untilAtLeast: 2)
        #expect(events.compactMap(\.autoTrigger).isEmpty)
        #expect(await coordinator.pendingMessageCount(roomID: room) == 1)

        // Ending the turn releases exactly one synthetic turn for the queue.
        await coordinator.noteTurnEnded(roomID: room)
        events = await observation.wait(untilAtLeast: 1) { $0.contains { $0.autoTrigger != nil } }
        let triggers = events.compactMap(\.autoTrigger)
        #expect(triggers.count == 1)
        #expect(triggers.first?.messages.map(\.text) == ["while busy"])
        #expect(await coordinator.pendingMessageCount(roomID: room) == 0)
        await observation.cancel()
    }

    @Test
    func consumerDeclaredBusyStateAlsoBlocksTheSyntheticTurn() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: room, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .seconds(60))
        let observation = await Observation.make(stream: coordinator.observe(roomID: room))
        await coordinator.setConsumerBusy(true, roomID: room)

        try await chat.send(
            roomID: room,
            senderID: "planner",
            destination: .coordinator,
            text: "queued behind operator work"
        )
        await coordinator.poll(roomID: room)
        var events = await observation.wait(untilAtLeast: 2)
        #expect(events.compactMap(\.autoTrigger).isEmpty)

        await coordinator.setConsumerBusy(false, roomID: room)
        events = await observation.wait(untilAtLeast: 1) { $0.contains { $0.autoTrigger != nil } }
        #expect(events.compactMap(\.autoTrigger).count == 1)
        await observation.cancel()
    }

    // MARK: - Burst

    @Test
    func burstIsBatchedIntoSequentialNonOverlappingTurns() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: room, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .seconds(60))
        // Queue the whole burst before the first drain so the batching bound is
        // observed on a full mailbox rather than on a partially filled one.
        for index in 0 ..< 7 {
            try await chat.send(
                roomID: room,
                senderID: "planner",
                destination: .coordinator,
                text: "burst \(index)"
            )
        }
        let observation = await Observation.make(stream: coordinator.observe(roomID: room))
        await coordinator.poll(roomID: room)

        var events = await observation.wait(untilAtLeast: 1) { $0.contains { $0.autoTrigger != nil } }
        var triggers = events.compactMap(\.autoTrigger)
        // Single flight: one batch is offered even though seven messages exist.
        #expect(triggers.count == 1)
        let first = try #require(triggers.first)
        #expect(first.messages.count == AgentSharedChat.maximumMessagesPerInjectedPrompt)
        #expect(first.messages.map(\.text) == (0 ..< 5).map { "burst \($0)" })
        #expect(await coordinator.pendingMessageCount(roomID: room) == 2)

        // The consumer takes the turn; nothing new is offered while it runs.
        await coordinator.resolveAutoTrigger(id: first.id, roomID: room, resolution: .started)
        await coordinator.noteTurnStarted(roomID: room)
        await coordinator.poll(roomID: room)
        events = await observation.snapshot()
        #expect(events.compactMap(\.autoTrigger).count == 1)

        await coordinator.noteTurnEnded(roomID: room)
        await coordinator.setConsumerBusy(false, roomID: room)
        events = await observation.wait(untilAtLeast: 2) { $0.compactMap(\.autoTrigger).count >= 2 }
        triggers = events.compactMap(\.autoTrigger)
        #expect(triggers.count == 2)
        #expect(triggers[1].messages.map(\.text) == ["burst 5", "burst 6"])
        #expect(triggers[0].id != triggers[1].id)
        #expect(await coordinator.pendingMessageCount(roomID: room) == 0)
        await observation.cancel()
    }

    // MARK: - Cancellation

    @Test
    func declinedTriggerIsRequeuedAndReofferedWithoutMessageLoss() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: room, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .seconds(60))
        let observation = await Observation.make(stream: coordinator.observe(roomID: room))

        try await chat.send(
            roomID: room,
            senderID: "planner",
            destination: .coordinator,
            text: "cancelled turn"
        )
        await coordinator.poll(roomID: room)
        var events = await observation.wait(untilAtLeast: 1) { $0.contains { $0.autoTrigger != nil } }
        let first = try #require(events.compactMap(\.autoTrigger).first)

        // The consumer turned out to be busy: declining must not drop the batch.
        await coordinator.setConsumerBusy(true, roomID: room)
        await coordinator.resolveAutoTrigger(id: first.id, roomID: room, resolution: .declined)
        #expect(await coordinator.pendingMessageCount(roomID: room) == 1)
        #expect(await coordinator.activeAutoTriggerID(roomID: room) == nil)
        #expect(await observation.snapshot().compactMap(\.autoTrigger).count == 1)

        await coordinator.setConsumerBusy(false, roomID: room)
        events = await observation.wait(untilAtLeast: 2) { $0.compactMap(\.autoTrigger).count >= 2 }
        let triggers = events.compactMap(\.autoTrigger)
        #expect(triggers.count == 2)
        #expect(triggers[1].messages.map(\.text) == ["cancelled turn"])
        #expect(triggers[1].id != first.id)
        await observation.cancel()
    }

    @Test
    func staleTriggerMustBeResolvedInItsOriginRoomToRequeueItsBatch() async throws {
        let retiredRoomID = "room-before-resume-\(UUID().uuidString)"
        let resumedRoomID = "room-after-resume-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: retiredRoomID, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .seconds(60))
        let observation = await Observation.make(stream: coordinator.observe(roomID: retiredRoomID))

        try await chat.send(
            roomID: retiredRoomID,
            senderID: "planner",
            destination: .coordinator,
            text: "preserve me across the session swap"
        )
        await coordinator.poll(roomID: retiredRoomID)
        let events = await observation.wait(untilAtLeast: 1) { $0.contains { $0.autoTrigger != nil } }
        let trigger = try #require(events.compactMap(\.autoTrigger).first)

        // Resolving an old trigger against the replacement room cannot consume
        // it. The TUI must use `trigger.roomID`, never its mutable current
        // session id, for this acknowledgement.
        await coordinator.resolveAutoTrigger(
            id: trigger.id,
            roomID: resumedRoomID,
            resolution: .declined
        )
        #expect(await coordinator.activeAutoTriggerID(roomID: retiredRoomID) == trigger.id)
        #expect(await coordinator.pendingMessageCount(roomID: retiredRoomID) == 0)

        // Hold the retired room busy so requeueing has a stable observable
        // state rather than immediately publishing a replacement trigger.
        await coordinator.setConsumerBusy(true, roomID: trigger.roomID)
        await coordinator.resolveAutoTrigger(
            id: trigger.id,
            roomID: trigger.roomID,
            resolution: .declined
        )
        #expect(await coordinator.activeAutoTriggerID(roomID: retiredRoomID) == nil)
        #expect(await coordinator.pendingMessageCount(roomID: retiredRoomID) == 1)
        await observation.cancel()
    }

    /// A consumer that acknowledges a trigger but never reports back must not
    /// stall the room: ending the resulting turn releases it automatically.
    @Test
    func startedTriggerIsReleasedWhenItsTurnEndsWithoutAConsumerReport() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: room, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .seconds(60))
        let observation = await Observation.make(stream: coordinator.observe(roomID: room))

        try await chat.send(
            roomID: room,
            senderID: "planner",
            destination: .coordinator,
            text: "first"
        )
        await coordinator.poll(roomID: room)
        var events = await observation.wait(untilAtLeast: 1) { $0.contains { $0.autoTrigger != nil } }
        let first = try #require(events.compactMap(\.autoTrigger).first)

        await coordinator.resolveAutoTrigger(id: first.id, roomID: room, resolution: .started)
        await coordinator.noteTurnStarted(roomID: room)
        try await chat.send(
            roomID: room,
            senderID: "planner",
            destination: .coordinator,
            text: "second"
        )
        await coordinator.poll(roomID: room)
        #expect(await observation.snapshot().compactMap(\.autoTrigger).count == 1)

        // No `setConsumerBusy(false)` here: the turn's end must free the room.
        await coordinator.noteTurnEnded(roomID: room)
        events = await observation.wait(untilAtLeast: 2) { $0.compactMap(\.autoTrigger).count >= 2 }
        let triggers = events.compactMap(\.autoTrigger)
        #expect(triggers.count == 2)
        #expect(triggers[1].messages.map(\.text) == ["second"])
        await observation.cancel()
    }

    // MARK: - Close

    @Test
    func stoppingObservationFinishesStreamsAndPreservesUndeliveredMessages() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: room, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .seconds(60))
        let observation = await Observation.make(stream: coordinator.observe(roomID: room))

        try await chat.send(
            roomID: room,
            senderID: "planner",
            destination: .coordinator,
            text: "survives close"
        )
        await coordinator.poll(roomID: room)
        _ = await observation.wait(untilAtLeast: 1) { $0.contains { $0.autoTrigger != nil } }

        await coordinator.stop(roomID: room)
        // The consumer's iteration ends instead of hanging on a closed session.
        #expect(await observation.waitUntilFinished())
        #expect(await coordinator.isMonitoring(roomID: room) == false)
        // The unresolved batch is preserved, not lost with the closed loop.
        #expect(await coordinator.pendingMessageCount(roomID: room) == 1)

        let resumed = await Observation.make(stream: coordinator.observe(roomID: room))
        let events = await resumed.wait(untilAtLeast: 2) { $0.contains { $0.autoTrigger != nil } }
        #expect(events.first?.renderedMessages?.map(\.text) == ["survives close"])
        #expect(events.compactMap(\.autoTrigger).first?.messages.map(\.text) == ["survives close"])
        await resumed.cancel()
    }

    // MARK: - No loop

    @Test
    func drainedRoomDoesNotLoopOrReemitTurns() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: room, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .seconds(60))
        let observation = await Observation.make(stream: coordinator.observe(roomID: room))

        try await chat.send(
            roomID: room,
            senderID: "planner",
            destination: .coordinator,
            text: "one shot"
        )
        await coordinator.poll(roomID: room)
        let events = await observation.wait(untilAtLeast: 1) { $0.contains { $0.autoTrigger != nil } }
        let trigger = try #require(events.compactMap(\.autoTrigger).first)
        await coordinator.resolveAutoTrigger(id: trigger.id, roomID: room, resolution: .started)
        await coordinator.noteTurnStarted(roomID: room)
        await coordinator.noteTurnEnded(roomID: room)
        await coordinator.setConsumerBusy(false, roomID: room)

        let baseline = await observation.snapshot().count
        for _ in 0 ..< 5 {
            await coordinator.poll(roomID: room)
        }
        #expect(await observation.snapshot().count == baseline)
        #expect(await observation.snapshot().compactMap(\.autoTrigger).count == 1)
        #expect(await coordinator.pendingMessageCount(roomID: room) == 0)
        await observation.cancel()
    }

    // MARK: - Core API for non-TUI consumers

    @Test
    func sessionRunnerPublishesAutoTriggersToAnyConsumer() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let backend = SharedChatRuntimeBackend()
        let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        )
        try await runner.createSession(configuration: configuration)
        // The transient bus lives inside the runtime backend, which the Core
        // resolves lazily; preloading installs it before the first drain.
        _ = try await runner.preloadModel(configuration: configuration, onEvent: { _ in })
        let observation = await Observation.make(
            stream: runner.observeSharedChat(rootSessionID: sessionID)
        )
        await backend.enqueueCoordinatorMessage(text: "from a delegated agent", roomID: sessionID)

        let events = await observation.wait(untilAtLeast: 1) { $0.contains { $0.autoTrigger != nil } }
        let trigger = try #require(events.compactMap(\.autoTrigger).first)
        #expect(trigger.prompt.contains("from a delegated agent"))

        // The same handshake is available without any terminal involvement.
        let claim = await runner.resolveSharedChatAutoTrigger(
            id: trigger.id,
            rootSessionID: sessionID,
            resolution: .started
        )
        #expect(claim == .acquired)
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: trigger.prompt,
            attachments: [],
            onEvent: { _ in }
        )
        await runner.setSharedChatConsumerBusy(false, rootSessionID: sessionID)
        #expect(await backend.promptCount() == 1)
        #expect(await backend.lastPrompt()?.contains("from a delegated agent") == true)

        await runner.stopSharedChatObservation(rootSessionID: sessionID)
        #expect(await observation.waitUntilFinished())
    }

    @Test
    func multipleHeadlessConsumersReceiveOneTriggerButOnlyClaimantStartsIt() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let backend = SharedChatRuntimeBackend()
        let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        )
        try await runner.createSession(configuration: configuration)
        _ = try await runner.preloadModel(configuration: configuration, onEvent: { _ in })
        let firstConsumer = await Observation.make(
            stream: runner.observeSharedChat(rootSessionID: sessionID)
        )
        let secondConsumer = await Observation.make(
            stream: runner.observeSharedChat(rootSessionID: sessionID)
        )
        await backend.enqueueCoordinatorMessage(text: "claim exactly once", roomID: sessionID)

        let firstEvents = await firstConsumer.wait(untilAtLeast: 1) {
            $0.contains { $0.autoTrigger != nil }
        }
        let secondEvents = await secondConsumer.wait(untilAtLeast: 1) {
            $0.contains { $0.autoTrigger != nil }
        }
        let firstTrigger = try #require(firstEvents.compactMap(\.autoTrigger).first)
        let secondTrigger = try #require(secondEvents.compactMap(\.autoTrigger).first)
        #expect(firstTrigger == secondTrigger)

        // Model the two independent headless event loops. The ordering is
        // intentionally unspecified: atomicity, rather than a preferred
        // subscriber, determines which one may send the coordinator prompt.
        func claimAndStart(_ trigger: AgentSharedChatAutoTrigger) async throws -> Bool {
            let claim = await runner.resolveSharedChatAutoTrigger(
                id: trigger.id,
                rootSessionID: trigger.roomID,
                resolution: .started
            )
            guard claim == .acquired else {
                return false
            }
            _ = try await runner.sendPrompt(
                configuration: configuration,
                prompt: trigger.prompt,
                attachments: [],
                onEvent: { _ in }
            )
            return true
        }

        async let firstStarted = claimAndStart(firstTrigger)
        async let secondStarted = claimAndStart(secondTrigger)
        let started = try await [firstStarted, secondStarted]
        #expect(started.filter { $0 }.count == 1)
        #expect(await backend.promptCount() == 1)
        #expect(await backend.lastPrompt()?.contains("claim exactly once") == true)

        await runner.stopSharedChatObservation(rootSessionID: sessionID)
        #expect(await firstConsumer.waitUntilFinished())
        #expect(await secondConsumer.waitUntilFinished())
    }

    @Test
    func runnerTurnTrackingKeepsSyntheticTurnsOutOfARunningPrompt() async throws {
        let sessionID = "session-\(UUID().uuidString)"
        let backend = SharedChatRuntimeBackend(blocksPrompt: true)
        let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        )
        try await runner.createSession(configuration: configuration)
        let observation = await Observation.make(
            stream: runner.observeSharedChat(rootSessionID: sessionID)
        )

        let promptTask = Task {
            _ = try? await runner.sendPrompt(
                configuration: configuration,
                prompt: "operator work",
                attachments: [],
                onEvent: { _ in }
            )
        }
        await backend.waitUntilPromptStarted()
        await backend.enqueueCoordinatorMessage(text: "arrived mid turn", roomID: sessionID)

        // The Core knows a turn is running even if no consumer declared it.
        let queued = await observation.wait(untilAtLeast: 1) { events in
            events.contains { $0.renderedMessages != nil }
        }
        #expect(queued.compactMap(\.autoTrigger).isEmpty)

        await backend.releasePrompt()
        _ = await promptTask.value
        let events = await observation.wait(untilAtLeast: 1) { $0.contains { $0.autoTrigger != nil } }
        #expect(events.compactMap(\.autoTrigger).count == 1)
        await observation.cancel()
    }

    // MARK: - Helpers

    private func makeChat(
        roomID: String,
        agents: [String]
    ) async throws -> AgentSharedChat {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: roomID)
        for agent in agents {
            _ = try await chat.registerAgent(id: agent, name: agent, roomID: roomID)
        }
        return chat
    }

    private func makeCoordinator(
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
                }
            ),
            pollInterval: pollInterval
        )
    }
}

private extension AgentSharedChatCoordinatorEvent {
    var autoTrigger: AgentSharedChatAutoTrigger? {
        guard case let .autoTrigger(trigger) = self else { return nil }
        return trigger
    }

    var renderedMessages: [AgentSharedChat.Message]? {
        guard case let .messages(messages) = self else { return nil }
        return messages
    }
}

/// Collects coordinator events without ever blocking a test forever: every wait
/// is bounded by a deadline and returns whatever has been observed so far.
private actor Observation {
    private var events: [AgentSharedChatCoordinatorEvent] = []
    private var isFinished = false
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
            await self?.markFinished()
        }
    }

    private func append(_ event: AgentSharedChatCoordinatorEvent) {
        events.append(event)
    }

    private func markFinished() {
        isFinished = true
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

    func waitUntilFinished(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if isFinished { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return isFinished
    }
}

/// Minimal runtime backend that owns a live shared-chat bus, so the Core API can
/// be exercised end to end without a model provider.
private actor SharedChatRuntimeBackend: AgentRuntimeBackend {
    private let chat = AgentSharedChat()
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var prompts: [String] = []
    private let blocksPrompt: Bool
    private var didStartPrompt = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(blocksPrompt: Bool = false) {
        self.blocksPrompt = blocksPrompt
    }

    func enqueueCoordinatorMessage(text: String, roomID: String) async {
        _ = try? await chat.registerCoordinator(roomID: roomID)
        _ = try? await chat.registerAgent(id: "agent-1", name: "planner", roomID: roomID)
        _ = try? await chat.send(
            roomID: roomID,
            senderID: "agent-1",
            destination: .coordinator,
            text: text
        )
    }

    func promptCount() -> Int { prompts.count }
    func lastPrompt() -> String? { prompts.last }

    func waitUntilPromptStarted() async {
        guard !didStartPrompt else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func releasePrompt() {
        isReleased = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations.removeAll()
    }

    private func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    // MARK: AgentRuntimeBackend

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

    func shutdown() async {
        sessions.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }

    func sharedChatParticipants(rootSessionID: String) async -> [AgentSharedChat.Participant] {
        await chat.participants(roomID: rootSessionID)
    }

    func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String
    ) async throws -> AgentSharedChat.Delivery {
        _ = try await chat.registerCoordinator(roomID: rootSessionID)
        return try await chat.send(
            roomID: rootSessionID,
            senderID: AgentSharedChat.coordinatorID(for: rootSessionID),
            destination: destination,
            text: text
        )
    }

    func drainCoordinatorSharedChatMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        await chat.drain(
            roomID: rootSessionID,
            participantID: AgentSharedChat.coordinatorID(for: rootSessionID),
            limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
        )
    }

    func sendPrompt(
        sessionID _: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        if blocksPrompt {
            didStartPrompt = true
            for continuation in startContinuations {
                continuation.resume()
            }
            startContinuations.removeAll()
            await waitForRelease()
        }
        return DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}
