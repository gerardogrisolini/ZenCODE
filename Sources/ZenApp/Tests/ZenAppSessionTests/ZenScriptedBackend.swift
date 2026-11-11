//
//  ZenScriptedBackend.swift
//  ZenAppSessionTests
//
//  The test doubles of the window tests: a scripted model backend, a gate a
//  step waits at, and bounded waits.
//

import Foundation
import Observation
import Synchronization
import Testing
import ToolCore
import ZenCODECore

/// Counts the changes Observation reports for what `read` reads, for as long
/// as the counter lives.
@MainActor
final class ZenObservationCounter {
    private(set) var count = 0
    private let read: @MainActor () -> Void

    init(_ read: @escaping @MainActor () -> Void) {
        self.read = read
        track()
    }

    private func track() {
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.count += 1
                self.track()
            }
        }
    }
}

/// The longest any wait of the tests lasts before it records an issue.
let zenTestDeadline: Duration = .seconds(10)

/// Polls `condition` until it holds or `timeout` passes; records an issue
/// naming `what` on timeout.
@discardableResult
func waitUntil(
    _ what: String,
    timeout: Duration = zenTestDeadline,
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if await condition() { return true }
    Issue.record("Timed out waiting until \(what)", sourceLocation: sourceLocation)
    return false
}

/// A gate a step passes only once the test opens it; the test can tell when
/// the step reached it. Every wait is bounded.
actor ZenGate {
    private var isOpen = false
    private(set) var reached = false

    func pass() async {
        reached = true
        let deadline = ContinuousClock.now + zenTestDeadline
        while !isOpen {
            guard ContinuousClock.now < deadline else {
                Issue.record("The gate was never opened")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func open() {
        isOpen = true
    }
}

/// What happened to a scripted backend and its held turn, in order. The
/// cancellation of a held turn is recorded synchronously, by the task that
/// cancels it.
final class ZenBackendLifecycle: Sendable {
    enum Event: Equatable, Sendable {
        /// The runner shut the backend down.
        case backendShutDown
        /// The task of a held turn was cancelled.
        case heldTurnCancelled
    }

    private let storage = Mutex<[Event]>([])

    var events: [Event] {
        storage.withLock { $0 }
    }

    func append(_ event: Event) {
        storage.withLock { $0.append(event) }
    }
}

/// A model backend that answers every prompt with one scripted block, can
/// hold a turn until the test releases it, and reports scripted sub-agents,
/// their transcripts, and their snapshots to the streams of
/// `subAgentSnapshotEvents(rootSessionID:)`. Its shared chat is a real room
/// bus, reached through the public bridge of a `DirectSubAgentRuntime` (the
/// operator's messages included), which the test drives through
/// ``sharedChat()``. Every wait is bounded.
actor ZenScriptedBackend: AgentRuntimeBackend {
    struct HoldTimedOut: Error {}

    /// One message the operator sent through the backend.
    struct SentSharedChatMessage: Equatable, Sendable {
        let text: String
        let destination: AgentSharedChat.Destination
        let rootSessionID: String
        let messageID: UUID
    }

    /// The shutdown of the backend and the cancellations of its held turns.
    nonisolated let lifecycle = ZenBackendLifecycle()
    /// The bridge to the shared chat; it never creates an agent.
    private let sharedChatRuntime = DirectSubAgentRuntime(
        backendFactory: { ZenScriptedBackend() },
        profileResolver: { _ in nil }
    )
    /// The messages the operator sent, in order.
    private(set) var sentSharedChatMessages: [SentSharedChatMessage] = []
    /// The error the next sends of the operator fail with, when set.
    private var sharedChatSendError: AgentSharedChat.Error?

    private(set) var prompts: [String] = []
    /// The per-turn instruction each prompt went out with
    /// (`AgentTurnInstructionContext`), in the order of ``prompts``.
    private(set) var turnInstructions: [String?] = []
    /// The attachments of each prompt, in the order of ``prompts``.
    private(set) var attachments: [[AgentRuntimeAttachment]] = []
    /// The system prompts the sessions were created or updated with.
    private(set) var systemPrompts: [String] = []
    /// The sessions explicitly created by the runner.
    private(set) var createdSessionIDs: [String] = []
    /// How many times the model was preloaded.
    private(set) var preloadCount = 0
    /// How many times the live backend supplied its tool descriptors.
    private(set) var toolDescriptorReadCount = 0
    private var scriptedToolDescriptors: [DirectToolDescriptor] = []
    private var scripts: [String: [DirectAgentEvent]] = [:]
    private var subAgents: [DirectSubAgentRuntime.AgentSnapshot] = []
    private var subAgentTranscripts: [String: ChatSubAgentTranscript] = [:]
    private var snapshotObservers: [UUID: (rootSessionID: String, continuation: AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>.Continuation)] = [:]
    /// The streams of sub-agent snapshots handed out.
    private(set) var snapshotSubscriptionCount = 0
    /// The streams of sub-agent snapshots still observed.
    var snapshotObserverCount: Int {
        snapshotObservers.count
    }
    /// The sub-agent transcripts read.
    private(set) var subAgentTranscriptReadCount = 0
    private var holdsNextTurn = false
    private(set) var isHolding = false
    private var released = false

    func hold() {
        holdsNextTurn = true
        released = false
    }

    func release() {
        released = true
    }

    /// Waits until a turn is held; `false`, with an issue, on timeout.
    @discardableResult
    func waitUntilHeld(sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        let deadline = ContinuousClock.now + zenTestDeadline
        while !isHolding {
            guard ContinuousClock.now < deadline else {
                Issue.record("No turn was held", sourceLocation: sourceLocation)
                return false
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func script(prompt: String, events: [DirectAgentEvent]) {
        scripts[prompt] = events
    }

    /// The sub-agents from now on, published to every snapshot stream of
    /// their root session.
    func setSubAgents(_ snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        subAgents = snapshots
        for observer in snapshotObservers.values {
            observer.continuation.yield(snapshots.filter { $0.rootSessionID == observer.rootSessionID })
        }
    }

    /// The transcript of the sub-agent `transcript.agentID`, read while the
    /// agent is one of the sub-agents of the root session asked.
    func setSubAgentTranscript(_ transcript: ChatSubAgentTranscript) {
        subAgentTranscripts[transcript.agentID] = transcript
    }

    func subAgentTranscript(agentID: String, rootSessionID: String) async -> ChatSubAgentTranscript? {
        subAgentTranscriptReadCount += 1
        guard subAgents.contains(where: { $0.id == agentID && $0.rootSessionID == rootSessionID }) else {
            return nil
        }
        return subAgentTranscripts[agentID]
    }

    /// The sub-agents of `rootSessionID` now and after every
    /// ``setSubAgents(_:)``, the newest only for a slow reader, until the
    /// reader cancels.
    func subAgentSnapshotEvents(rootSessionID: String) async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]> {
        snapshotSubscriptionCount += 1
        let (stream, continuation) = AsyncStream.makeStream(
            of: [DirectSubAgentRuntime.AgentSnapshot].self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        snapshotObservers[id] = (rootSessionID, continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSnapshotObserver(id) }
        }
        continuation.yield(subAgents.filter { $0.rootSessionID == rootSessionID })
        return stream
    }

    private func removeSnapshotObserver(_ id: UUID) {
        snapshotObservers[id] = nil
    }

    func createSession(
        id: String,
        cwd _: String,
        systemPrompt: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        createdSessionIDs.append(id)
        systemPrompts.append(systemPrompt ?? "")
    }

    func createSessionIfNeeded(
        id: String,
        cwd _: String,
        systemPrompt: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        createdSessionIDs.append(id)
        systemPrompts.append(systemPrompt ?? "")
    }

    func updateSessionOptions(
        id _: String,
        systemPrompt: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        systemPrompts.append(systemPrompt ?? "")
    }

    func closeSession(id _: String) {}

    func shutdown() async {
        lifecycle.append(.backendShutDown)
    }

    /// The error a scripted preload fails with.
    struct PreloadFailed: Error, LocalizedError {
        var errorDescription: String? { "Scripted preload failure" }
    }

    /// The gate the next preloads wait at, when set.
    private var preloadGate: ZenGate?
    /// How many of the next preloads fail.
    private var preloadFailures = 0

    /// Makes the next preloads wait at `gate`; `nil` lets them through.
    func holdPreloads(at gate: ZenGate?) {
        preloadGate = gate
    }

    /// Makes the next `count` preloads fail with ``PreloadFailed``.
    func failNextPreloads(_ count: Int) {
        preloadFailures = count
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        preloadCount += 1
        if let preloadGate {
            await preloadGate.pass()
        }
        if preloadFailures > 0 {
            preloadFailures -= 1
            throw PreloadFailed()
        }
        return "zen-app-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        toolDescriptorReadCount += 1
        return scriptedToolDescriptors
    }

    /// The descriptors this backend reports until the next call.
    func setToolDescriptors(_ descriptors: [DirectToolDescriptor]) {
        scriptedToolDescriptors = descriptors
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        subAgents
    }

    // MARK: Shared chat

    /// The room bus behind the backend's shared chat.
    func sharedChat() async -> AgentSharedChat {
        await sharedChatRuntime.sharedChat
    }

    /// Makes the next sends of the operator fail with `error`; `nil` lets them
    /// through again.
    func failSharedChatSends(with error: AgentSharedChat.Error?) {
        sharedChatSendError = error
    }

    func sharedChatParticipants(rootSessionID: String) async -> [AgentSharedChat.Participant] {
        await sharedChatRuntime.sharedChatParticipants(rootSessionID: rootSessionID)
    }

    func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String,
        messageID: UUID
    ) async throws -> AgentSharedChat.Delivery {
        sentSharedChatMessages.append(SentSharedChatMessage(
            text: text,
            destination: destination,
            rootSessionID: rootSessionID,
            messageID: messageID
        ))
        if let sharedChatSendError {
            throw sharedChatSendError
        }
        return try await sharedChatRuntime.sendSharedChatMessage(
            text: text,
            destination: destination,
            rootSessionID: rootSessionID,
            messageID: messageID
        )
    }

    func drainCoordinatorSharedChatMessages(rootSessionID: String) async -> [AgentSharedChat.Message] {
        await sharedChatRuntime.drainCoordinatorSharedChatMessages(rootSessionID: rootSessionID)
    }

    func sharedChatTranscriptMessages(rootSessionID: String) async -> [AgentSharedChat.Message] {
        await sharedChatRuntime.sharedChatTranscriptMessages(rootSessionID: rootSessionID)
    }

    func updateSharedChatMessageAvailableHandler(_ handler: (@Sendable (String) -> Void)?) async {
        await sharedChatRuntime.updateSharedChatMessageAvailableHandler(handler)
    }

    func sendPrompt(
        sessionID _: String,
        prompt: String,
        attachments promptAttachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        turnInstructions.append(AgentTurnInstructionContext.currentTurnInstruction)
        attachments.append(promptAttachments)
        let key = scripts.keys.first { prompt.contains($0) }
        if holdsNextTurn {
            holdsNextTurn = false
            isHolding = true
            defer { isHolding = false }
            let deadline = ContinuousClock.now + zenTestDeadline
            let lifecycle = lifecycle
            try await withTaskCancellationHandler {
                while !released {
                    guard ContinuousClock.now < deadline else {
                        Issue.record("A held turn was never released")
                        throw HoldTimedOut()
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
            } onCancel: {
                lifecycle.append(.heldTurnCancelled)
            }
        }
        if let key, let events = scripts[key] {
            for event in events {
                await onEvent(event)
            }
        }
        let name = key ?? prompt.components(separatedBy: .newlines).last ?? prompt
        let text = "Scripted answer to \(name)"
        await onEvent(.content(text))
        return DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "zen-app-model")
    }
}
