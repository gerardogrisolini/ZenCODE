//
//  TerminalChat+InputLoop+SharedChat.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// Keeps exactly one live shared-chat observation attached for the blocking
/// input fallback.
///
/// A stream can finish because a backend was replaced while retaining the same
/// root session id. That fallback parks inside `readLine` for an unbounded time,
/// so recovery lives on the producer path: the task consuming the stream
/// re-attaches when it ends without cancellation, independent of input.
/// Every dependency is injected so recovery, room-change, cancellation and
/// retry pacing can be exercised end to end.
actor TerminalSharedChatObservationSupervisor {
    struct Environment: Sendable {
        var attach: @Sendable (String) async -> AgentSharedChatCoordinator.Observation
        var detach: @Sendable (AgentSharedChatCoordinator.Observation) async -> Void
        var handleEvent: @Sendable (
            AgentSharedChatCoordinatorEvent,
            AgentSharedChatCoordinator.Observation
        ) async -> Void
        /// Cooperative pause applied only when a replacement stream ends
        /// without ever delivering an event. A backend that keeps closing the
        /// stream immediately then degrades to a bounded retry instead of a hot
        /// attach loop, while a healthy stream re-attaches without delay.
        var backoff: @Sendable (Int) async -> Void = { attempt in
            let milliseconds = min(2_000, 50 << min(max(0, attempt - 1), 5))
            try? await Task.sleep(for: .milliseconds(milliseconds))
        }
    }

    private let environment: Environment
    private var roomID: String
    private var current: (
        observation: AgentSharedChatCoordinator.Observation,
        task: Task<Void, Never>
    )?
    /// Retires an in-flight attach or a late stream completion whose binding
    /// was already replaced by a room change, a teardown, or a newer recovery.
    private var generation = 0
    private var emptyRestartCount = 0
    private var isStopped = false
    /// Automatic re-attachments performed after a non-cancelled end.
    private(set) var recoveryCount = 0

    init(roomID: String, environment: Environment) {
        self.roomID = roomID
        self.environment = environment
    }

    func start() async {
        guard !isStopped, current == nil else { return }
        await bind()
    }

    /// Observation currently attached, for callers that must address the live
    /// observer identity. `nil` only while a replacement is being attached.
    func currentObservation() -> AgentSharedChatCoordinator.Observation? {
        current?.observation
    }

    /// Follows a `/new` or `/resume` room swap. Same-room ends are already
    /// repaired by the producer path, so this stays a pure room-change hook.
    func follow(roomID newRoomID: String) async {
        guard !isStopped else { return }
        guard newRoomID != roomID || current == nil else { return }
        roomID = newRoomID
        emptyRestartCount = 0
        await teardownCurrent()
        await bind()
    }

    /// Local teardown. Cancellation is not a reason to attach a replacement, so
    /// this permanently retires the supervisor.
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        await teardownCurrent()
    }

    private func bind() async {
        guard !isStopped, current == nil else { return }
        generation += 1
        let generation = self.generation
        let roomID = self.roomID
        let environment = self.environment
        let observation = await environment.attach(roomID)
        guard !isStopped, generation == self.generation else {
            // A stop or a room change landed while attaching: release the
            // subscription instead of leaking it into a retired generation.
            await environment.detach(observation)
            return
        }
        current = (
            observation,
            Task(name: "ZenCODE.TUI.blocking-shared-chat-events") { [weak self] in
                var didHandleEvent = false
                for await event in observation.events {
                    if Task.isCancelled { break }
                    didHandleEvent = true
                    await environment.handleEvent(event, observation)
                }
                guard !Task.isCancelled else { return }
                await self?.observationDidEnd(
                    generation: generation,
                    didHandleEvent: didHandleEvent
                )
            }
        )
    }

    /// Producer-side repair for a stream that finished on its own.
    private func observationDidEnd(generation: Int, didHandleEvent: Bool) async {
        guard !isStopped, generation == self.generation, let ended = current else {
            return
        }
        // Release the finished subscription before attaching its replacement so
        // the Core never sees two observers for this one terminal.
        current = nil
        await environment.detach(ended.observation)
        guard !isStopped, generation == self.generation else { return }
        if didHandleEvent {
            emptyRestartCount = 0
        } else {
            emptyRestartCount += 1
            await environment.backoff(emptyRestartCount)
            guard !isStopped, generation == self.generation else { return }
        }
        recoveryCount += 1
        await bind()
    }

    private func teardownCurrent() async {
        // Retire the outgoing generation first: a completion racing this
        // teardown must not schedule a replacement behind our back.
        generation += 1
        guard let retired = current else { return }
        current = nil
        retired.task.cancel()
        await retired.task.value
        await environment.detach(retired.observation)
    }
}

extension TerminalChat {
    // Mailbox monitoring, drain batching and the idle/busy decision belong
    // to the Core coordinator. This task only forwards its live events into
    // the terminal queue: the TUI renders and answers, but never owns the
    // auto-trigger semantics, so non-TUI consumers behave identically.
    func startInteractiveSharedChatObservation(
        roomID: String,
        eventQueue: TerminalChatEventQueue
    ) async -> (
        observation: AgentSharedChatCoordinator.Observation,
        task: Task<Void, Never>
    ) {
        let observation = await sessionRunner.attachSharedChatObservation(rootSessionID: roomID)
        let task = Task(name: "ZenCODE.TUI.shared-chat-events") {
            for await event in observation.events {
                switch event {
                case let .messages(messages):
                    // Shared-chat messages are never evicted from the
                    // bounded runtime queue: the box must reach this
                    // observer within the transcript bound, so the forwarder
                    // applies backpressure instead of dropping. The TUI
                    // deduplicates by message id, so a replayed transcript
                    // cannot double-render.
                    _ = await eventQueue.sendWithBackpressure(
                        .sharedChatMessages(roomID: roomID, messages: messages)
                    )
                case .participantsChanged:
                    eventQueue.send(.sharedChatParticipantsChanged(roomID: roomID))
                case let .autoTrigger(trigger):
                    // A trigger has Core-owned recovery semantics. Do not
                    // retain it in a local overflow side-channel: if the
                    // bounded TUI FIFO is full, decline it immediately and
                    // let the coordinator requeue the batch for a later turn.
                    if eventQueue.offer(.sharedChatAutoTrigger(trigger)) == .rejectedFull {
                        await sessionRunner.declineSharedChatAutoTrigger(
                            id: trigger.id,
                            rootSessionID: trigger.roomID
                        )
                    }
                }
            }
            // `stop` or a backend replacement can finish an observation
            // without changing the session identifier. Surface that lifecycle
            // edge to the serialized loop; cancellation is local teardown,
            // not a reason to attach a replacement observer.
            guard !Task.isCancelled else { return }
            // Do this at the producer lifecycle boundary rather than after
            // a potentially slow slash-command replacement returns. The
            // status bar accepts the observation identity, so a late old
            // completion cannot erase the replacement dock.
            await statusBar.removeSharedChatReader(ownedBy: observation.id)
            _ = await eventQueue.sendWithBackpressure(
                .sharedChatObservationEnded(
                    roomID: roomID,
                    observationID: observation.id
                )
            )
        }
        return (observation, task)
    }

    /// Runs one generation turn and folds its outcome into a queue-deliverable result.
    func generationResult(for attempt: TerminalPromptAttempt) async -> TerminalChatGenerationResult {
        do {
            if let onGenerateResponseForTesting {
                return .success(try await onGenerateResponseForTesting(attempt))
            }
            return .success(try await generateResponse(attempt: attempt))
        } catch is CancellationError {
            return .failure(
                TerminalChatGenerationFailure(
                    message: "",
                    isCancellation: true,
                    origin: attempt.origin,
                    fileChangeSummary: nil
                )
            )
        } catch {
            return .failure(TerminalChatGenerationFailure(error: error, origin: attempt.origin))
        }
    }

    /// Fences concurrent publications across an external bottom-overlay repaint.
    /// The status bar preserves the retired block's insertion point on same-height
    /// updates and adjusts it only for actual scroll.
    func withBottomOverlayTransition<T>(_ body: () async -> T) async -> T {
        let previousOutputCapacity = await statusBar.scrollableOutputRowCapacity()
        await renderCoordinator.beginBottomOverlayTransition(
            maximumInPlaceRows: previousOutputCapacity
        )
        let result = await body()
        let currentOutputCapacity = await statusBar.scrollableOutputRowCapacity()
        await renderCoordinator.endBottomOverlayTransition(
            maximumInPlaceRows: currentOutputCapacity
        )
        await renderSubAgentOverview(force: false)
        return result
    }
}
