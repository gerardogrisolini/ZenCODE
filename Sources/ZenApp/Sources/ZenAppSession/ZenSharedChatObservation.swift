//
//  ZenSharedChatObservation.swift
//  ZenApp
//
//  The window's one observation of its session's shared-chat room: attached,
//  moved with the session, recovered when its stream ends on its own, and the
//  window's busy state declared on it.
//

import Foundation
import ZenCODECore

/// Keeps exactly one shared-chat observation attached for a window, the
/// app's port of the terminal's `TerminalSharedChatObservationSupervisor`.
///
/// The observation follows the room of the window's current session
/// (``follow(roomID:)``). Its events are handled one at a time on the main
/// actor (``Handlers/handle``), only while it is the current observation
/// (``isCurrent(_:)``). A stream that ends without being cancelled (the
/// backend was replaced, the Core stopped the room at session teardown) is
/// detached, then replaced only when the window allows it
/// (``Handlers/mayRecover``); a replacement that ends without delivering any
/// event backs off first, with the terminal's pacing (50 ms, doubling, within
/// 2 s). Every attach is
/// generation-fenced: a room change, a stop, or a newer recovery retires an
/// attach in flight and a late stream completion, so the window never holds
/// two observations.
///
/// The window's busy state (a line runs or waits) is declared on the
/// observation right after it attaches and whenever it changes
/// (``declareConsumerBusy(_:)``), through one serial chain, so declarations
/// reach the Core in the order they were made. The window's own answers to an
/// auto-trigger (its claim, its give-back) run on the same chain
/// (``serialized(_:)``), so an idle declaration can never overtake them.
@MainActor
final class ZenSharedChatObservation {
    typealias Observation = AgentSharedChatCoordinator.Observation

    /// The Core calls, injected so the supervisor can be tested without a
    /// session runner.
    struct Environment: Sendable {
        var attach: @Sendable (String) async -> Observation
        var detach: @Sendable (Observation) async -> Void
        var setConsumerBusy: @Sendable (Bool, Observation) async -> Void
        /// The pause before a replacement whose predecessor ended without
        /// delivering any event; `attempt` counts such ends in a row, from 1.
        var backoff: @Sendable (_ attempt: Int) async -> Void = Environment.defaultBackoff

        /// The terminal's pacing, the same formula: 50 ms, doubling with
        /// every attempt up to the sixth, within 2 s (so 1.6 s at most).
        static let defaultBackoff: @Sendable (Int) async -> Void = { attempt in
            try? await Task.sleep(for: .milliseconds(backoffMilliseconds(attempt: attempt)))
        }

        static func backoffMilliseconds(attempt: Int) -> Int {
            min(2_000, 50 << min(max(0, attempt - 1), 5))
        }

        /// The observation API of `runner`.
        static func runner(_ runner: AgentCoreSessionRunner) -> Environment {
            Environment(
                attach: { roomID in await runner.attachSharedChatObservation(rootSessionID: roomID) },
                detach: { observation in await runner.detachSharedChatObservation(observation) },
                setConsumerBusy: { isBusy, observation in
                    await runner.setSharedChatConsumerBusy(isBusy, observation: observation)
                }
            )
        }
    }

    /// What the window does with the observation.
    struct Handlers {
        /// The busy state the window declares now: a line runs or waits, or
        /// a claim of the window is on its way.
        var consumerIsBusy: @MainActor () -> Bool
        /// The observation was attached; called before its first event.
        var didAttach: @MainActor (Observation) async -> Void
        /// One event of the observation.
        var handle: @MainActor (AgentSharedChatCoordinatorEvent, Observation) async -> Void
        /// The stream of the room `roomID` ended on its own: whether to attach
        /// a replacement (the window is open and the room is still its
        /// current session's).
        var mayRecover: @MainActor (_ roomID: String) async -> Bool
    }

    private let environment: Environment
    /// Set by the window once it starts.
    var handlers: Handlers?

    /// The room followed: the id of the window's current session.
    private(set) var roomID: String?
    /// The observation attached now; `nil` while a replacement attaches.
    private(set) var observation: Observation?
    private var eventTask: Task<Void, Never>?
    private var busyTask: Task<Void, Never>?
    /// Retires an attach in flight and a late stream completion whose binding
    /// was replaced by a room change, a stop, or a newer recovery.
    private var generation = 0
    private var emptyRestartCount = 0
    private(set) var isStopped = false

    /// The attaches made, for tests.
    private(set) var attachCount = 0
    /// The detaches made, for tests.
    private(set) var detachCount = 0
    /// The replacements attached after a stream ended on its own, for tests.
    private(set) var recoveryCount = 0

    init(environment: Environment) {
        self.environment = environment
    }

    /// `true` while `observation` is the one attached now.
    func isCurrent(_ observation: Observation) -> Bool {
        self.observation?.id == observation.id
    }

    /// Observes `newRoomID`, detaching the observation of another room first.
    /// Nothing happens once stopped, or when the room is observed already.
    func follow(roomID newRoomID: String) async {
        guard !isStopped else { return }
        guard newRoomID != roomID || observation == nil else { return }
        let retiring = retire()
        roomID = newRoomID
        emptyRestartCount = 0
        await retiring?.value
        await bind()
    }

    /// Retires the observation at once: none of its events is handled from
    /// now on, and the room is no longer followed. Returns the detach, which
    /// runs once its event task ended.
    @discardableResult
    func retire() -> Task<Void, Never>? {
        generation &+= 1
        roomID = nil
        guard let retired = observation else { return nil }
        observation = nil
        let task = eventTask
        eventTask = nil
        task?.cancel()
        detachCount += 1
        let environment = environment
        return Task {
            await task?.value
            await environment.detach(retired)
        }
    }

    /// Retires the observation for good: nothing is attached again. Returns
    /// the detach; a second call does nothing.
    @discardableResult
    func stop() -> Task<Void, Never>? {
        guard !isStopped else { return nil }
        isStopped = true
        return retire()
    }

    /// Declares `isBusy` on the current observation, after every declaration
    /// and operation (``serialized(_:)``) made before it; `nil` when nothing
    /// is attached.
    @discardableResult
    func declareConsumerBusy(_ isBusy: Bool) -> Task<Void, Never>? {
        guard !isStopped, let observation else { return nil }
        let previous = busyTask
        let environment = environment
        let task = Task {
            await previous?.value
            await environment.setConsumerBusy(isBusy, observation)
        }
        busyTask = task
        return task
    }

    /// Runs `operation` on the chain of the busy declarations and returns its
    /// result: after every declaration and operation made before the call,
    /// and before every one made after it. The place on the chain is taken
    /// when the call is made, before it suspends. It runs whether or not an
    /// observation is attached, so an answer owed to the Core is never
    /// dropped.
    ///
    /// `operation` (and any hook it awaits) must never await the chain
    /// itself (``flushConsumerBusy()``, another `serialized(_:)`, a
    /// give-back of the window): it would wait on itself.
    func serialized<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let previous = busyTask
        let task = Task {
            await previous?.value
            return await operation()
        }
        busyTask = Task { _ = await task.value }
        return await task.value
    }

    /// Waits until every declaration and operation made so far reached the
    /// Core. Never called from an operation on the chain (``serialized(_:)``,
    /// hooks included): it would wait on itself.
    func flushConsumerBusy() async {
        await busyTask?.value
    }

    // MARK: - Binding

    private func bind() async {
        guard !isStopped, observation == nil, let roomID else { return }
        generation &+= 1
        let generation = generation
        let observation = await environment.attach(roomID)
        attachCount += 1
        guard !isStopped, generation == self.generation, self.observation == nil else {
            // A stop or a room change landed while attaching: release the
            // subscription instead of leaking it into a retired generation.
            detachCount += 1
            await environment.detach(observation)
            return
        }
        self.observation = observation
        // The busy state is known to the Core before the first event.
        let declared = declareConsumerBusy(handlers?.consumerIsBusy() ?? false)
        eventTask = Task { [weak self] in
            await declared?.value
            await self?.handlers?.didAttach(observation)
            var didHandleEvent = false
            for await event in observation.events {
                guard !Task.isCancelled, let self else { return }
                didHandleEvent = true
                await self.handlers?.handle(event, observation)
            }
            guard !Task.isCancelled else { return }
            await self?.observationDidEnd(generation: generation, didHandleEvent: didHandleEvent)
        }
    }

    /// The stream of the current observation finished on its own.
    private func observationDidEnd(generation: Int, didHandleEvent: Bool) async {
        guard !isStopped, generation == self.generation, let ended = observation, let roomID else {
            return
        }
        // Released before its replacement attaches, so the Core never sees
        // two observers of this window.
        observation = nil
        eventTask = nil
        detachCount += 1
        await environment.detach(ended)
        guard !isStopped, generation == self.generation else { return }
        guard await handlers?.mayRecover(roomID) == true else { return }
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
}

/// The window's shared-chat reads on the chat actor.
@ChatSessionActor
enum ZenSharedChatSteps {
    /// The room of the incarnation `epoch` of `slotID`, its controller's
    /// session id, while the slot runs it.
    static func roomID(in sessionHost: ChatSessionHost, slotID: ChatSlotID, epoch: UInt64) -> String? {
        guard let incarnation = sessionHost.incarnation(in: slotID), incarnation.epoch == epoch else { return nil }
        return incarnation.controller.sessionID
    }

    /// The room of the session `slotID` runs now.
    static func currentRoomID(in sessionHost: ChatSessionHost, slotID: ChatSlotID) -> String? {
        sessionHost.incarnation(in: slotID)?.controller.sessionID
    }

    /// The controller `slotID` runs now, when its session is the room
    /// `roomID`.
    static func controller(
        in sessionHost: ChatSessionHost,
        slotID: ChatSlotID,
        roomID: String
    ) -> ChatSessionController? {
        guard let controller = sessionHost.incarnation(in: slotID)?.controller,
              controller.sessionID == roomID else {
            return nil
        }
        return controller
    }
}
