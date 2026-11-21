//
//  AgentSharedChatCoordinatorTests+Support.swift
//  ZenCODE
//
//  Test doubles shared by the AgentSharedChatCoordinator tests: an event
//  observation collector and a Shared Chat runtime backend.
//

import Foundation
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing

extension AgentSharedChatCoordinatorTests {
    /// Collects coordinator events and resumes waiters only when the event sequence
    /// they assert actually arrives. This eliminates scheduler-dependent polling
    /// from the Shared Chat tests.
    actor Observation {
        private var events: [AgentSharedChatCoordinatorEvent] = []
        private var isFinished = false
        private var task: Task<Void, Never>?
        private var eventWaiters: [UUID: EventWaiter] = [:]
        private var finishWaiters: [CheckedContinuation<Void, Never>] = []

        private struct EventWaiter {
            let minimumCount: Int
            let predicate: @Sendable ([AgentSharedChatCoordinatorEvent]) -> Bool
            let continuation: CheckedContinuation<[AgentSharedChatCoordinatorEvent], Never>
        }

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
            resumeSatisfiedEventWaiters()
        }

        private func markFinished() {
            isFinished = true
            let eventWaiters = self.eventWaiters
            self.eventWaiters.removeAll()
            for waiter in eventWaiters.values {
                waiter.continuation.resume(returning: events)
            }
            let finishWaiters = self.finishWaiters
            self.finishWaiters.removeAll()
            for waiter in finishWaiters {
                waiter.resume()
            }
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
            satisfying predicate: (@Sendable ([AgentSharedChatCoordinatorEvent]) -> Bool)? = nil
        ) async -> [AgentSharedChatCoordinatorEvent] {
            let predicate = predicate ?? { _ in true }
            guard !(events.count >= count && predicate(events)) else {
                return events
            }
            guard !isFinished else {
                return events
            }
            return await withCheckedContinuation { continuation in
                eventWaiters[UUID()] = EventWaiter(
                    minimumCount: count,
                    predicate: predicate,
                    continuation: continuation
                )
            }
        }

        private func resumeSatisfiedEventWaiters() {
            let readyIDs = eventWaiters.compactMap { entry in
                let waiter = entry.value
                return events.count >= waiter.minimumCount && waiter.predicate(events)
                    ? entry.key
                    : nil
            }
            for id in readyIDs {
                guard let waiter = eventWaiters.removeValue(forKey: id) else { continue }
                waiter.continuation.resume(returning: events)
            }
        }

        func waitUntilFinished() async -> Bool {
            guard !isFinished else { return true }
            await withCheckedContinuation { continuation in
                finishWaiters.append(continuation)
            }
            return true
        }
    }
}

/// Minimal runtime backend that owns a live shared-chat bus, so the Core API can
/// be exercised end to end without a model provider.
actor SharedChatRuntimeBackend: AgentRuntimeBackend {
    private let chat = AgentSharedChat()
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var prompts: [String] = []
    private let blocksPrompt: Bool
    private let blocksSharedChatSend: Bool
    private let failsSharedChatSend: Bool
    private var didStartPrompt = false
    private var sharedChatMessageAvailableHandler: (@Sendable (String) -> Void)?
    private var didStartSharedChatSend = false
    private var sharedChatSendStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var sharedChatSendReleaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var isSharedChatSendReleased = false
    private var lastSharedChatMessageID: UUID?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(
        blocksPrompt: Bool = false,
        blocksSharedChatSend: Bool = false,
        failsSharedChatSend: Bool = false
    ) {
        self.blocksPrompt = blocksPrompt
        self.blocksSharedChatSend = blocksSharedChatSend
        self.failsSharedChatSend = failsSharedChatSend
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
    func recordedSharedChatMessageID() -> UUID? { lastSharedChatMessageID }

    func waitUntilSharedChatSendStarted() async {
        guard !didStartSharedChatSend else { return }
        await withCheckedContinuation { continuation in
            sharedChatSendStartContinuations.append(continuation)
        }
    }

    func releaseSharedChatSend() {
        isSharedChatSendReleased = true
        for continuation in sharedChatSendReleaseContinuations {
            continuation.resume()
        }
        sharedChatSendReleaseContinuations.removeAll()
    }

    private func waitForSharedChatSendRelease() async {
        guard !isSharedChatSendReleased else { return }
        await withCheckedContinuation { continuation in
            sharedChatSendReleaseContinuations.append(continuation)
        }
    }

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

    func updateSharedChatMessageAvailableHandler(
        _ handler: (@Sendable (String) -> Void)?
    ) {
        sharedChatMessageAvailableHandler = handler
    }

    func sharedChatParticipants(rootSessionID: String) async -> [AgentSharedChat.Participant] {
        await chat.participants(roomID: rootSessionID)
    }

    func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String,
        messageID: UUID
    ) async throws -> AgentSharedChat.Delivery {
        lastSharedChatMessageID = messageID
        if failsSharedChatSend {
            if blocksSharedChatSend {
                didStartSharedChatSend = true
                for continuation in sharedChatSendStartContinuations {
                    continuation.resume()
                }
                sharedChatSendStartContinuations.removeAll()
                await waitForSharedChatSendRelease()
            }
            throw AgentSharedChat.Error.unavailable
        }
        _ = try await chat.registerCoordinator(roomID: rootSessionID)
        let delivery = try await chat.sendFromOperator(
            roomID: rootSessionID,
            destination: destination,
            text: text,
            messageID: messageID
        )
        sharedChatMessageAvailableHandler?(rootSessionID)
        if blocksSharedChatSend {
            didStartSharedChatSend = true
            for continuation in sharedChatSendStartContinuations {
                continuation.resume()
            }
            sharedChatSendStartContinuations.removeAll()
            await waitForSharedChatSendRelease()
        }
        return delivery
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

    func sharedChatTranscriptMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        await chat.messages(roomID: rootSessionID)
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
