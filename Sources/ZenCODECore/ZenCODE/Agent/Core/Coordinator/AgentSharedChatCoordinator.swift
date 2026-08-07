//
//  AgentSharedChatCoordinator.swift
//  ZenCODE
//

import Foundation

/// One synthetic coordinator turn requested by the Core auto-trigger.
///
/// The batch is already bounded by ``AgentSharedChat/maximumMessagesPerInjectedPrompt``
/// and its ``prompt`` is built by the Core, so every consumer (terminal UI,
/// ACP, tests, headless drivers) injects exactly the same text.
public struct AgentSharedChatAutoTrigger: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let roomID: String
    public let messages: [AgentSharedChat.Message]
    public let prompt: String

    init(
        id: UUID = UUID(),
        roomID: String,
        messages: [AgentSharedChat.Message],
        prompt: String
    ) {
        self.id = id
        self.roomID = roomID
        self.messages = messages
        self.prompt = prompt
    }
}

/// How a consumer answered an auto-trigger. `declined` returns the batch to the
/// head of the pending queue, so refusing a turn never drops a live message.
public enum AgentSharedChatAutoTriggerResolution: Sendable, Equatable {
    /// The consumer owns the turn now and reports itself busy until it ends.
    case started
    /// The consumer cannot run the turn; the Core re-offers the same messages.
    case declined
}

/// The result of attempting to take an auto-triggered coordinator turn.
///
/// A trigger is broadcast to every observer of a room. Observers must start a
/// synthetic generation only after receiving ``acquired``: the actor makes the
/// active-trigger check, its removal and the claim ownership record one atomic
/// operation, so exactly one observer can acquire a given trigger.
public enum AgentSharedChatAutoTriggerClaimResult: Sendable, Equatable {
    /// This consumer atomically acquired the active trigger and owns its turn.
    case acquired
    /// The trigger was stale, belonged to another room, was already claimed by
    /// a different observer, or the caller is no longer an attached observer.
    /// It must be treated as a no-op.
    case notAcquired
}

/// Events published by the Core auto-trigger. Rendering surfaces consume
/// `messages`/`participantsChanged`; `autoTrigger` carries the single-flight
/// decision that used to live inside the terminal input loop.
public enum AgentSharedChatCoordinatorEvent: Sendable, Equatable {
    case messages([AgentSharedChat.Message])
    case participantsChanged([AgentSharedChat.Participant])
    case autoTrigger(AgentSharedChatAutoTrigger)
}

/// Core-side owner of the coordinator mailbox: it monitors, drains, batches and
/// decides *when* a synthetic coordinator turn may start.
///
/// Design constraints encoded here:
/// * exactly one synthetic turn may be outstanding per room (single flight);
/// * a message that arrives while a turn is running is queued, never raced;
/// * busy state and turn ownership are per observer: one consumer can never
///   clear another's declaration, take its claim, or start a concurrent turn;
/// * publishing an offer, observing the busy state and recording the claim are
///   one atomic actor step, so a turn that starts between the offer and its
///   acknowledgement always wins over the late claim;
/// * a claim is bound to the turn that consumes it, so an unrelated generation
///   ending can neither release it nor strand its batch, and a detach in the
///   middle of a running synthetic turn cannot requeue messages that turn is
///   already carrying;
/// * declining, detaching, stopping or resetting re-queues the batch instead of
///   losing it, unless a turn already injected it;
/// * every queue and every observer stream is bounded with an explicit eviction
///   policy, so a stalled consumer cannot grow memory without limit;
/// * draining is bounded per poll and every suspension is generation-fenced
///   *before* the next one, so one hot room cannot starve the others, a drain
///   that outlives its room can never resurrect it, and a stale poll can never
///   consume the mailbox of the instance that replaced it;
/// * the mailbox is not drained while a turn is in flight: inline message
///   delivery owns the mailbox for the whole duration of the turn, so the
///   monitor leaves it untouched and drains the leftover the instant the room
///   goes idle (see ``poll(roomID:)``);
/// * a backend rebuild fences the room for its whole duration
///   (``beginReset(roomID:)``/``endReset(_:)``), so nothing is drained from a
///   bus that is about to be cleared and no offer opens a turn against a
///   session being torn down;
/// * no persistence: the transcript stays transient and `SessionTaskOrchestrator`
///   remains the only owner of durable task state.
public actor AgentSharedChatCoordinator {
    /// One independently detachable observation of a room, and the identity a
    /// consumer uses to declare busy state or to claim a turn.
    ///
    /// Detaching this value ends only its stream and releases only the state it
    /// owns; it never stops monitoring for the room's other observers and never
    /// clears another observer's busy state or claim.
    public struct Observation: Sendable, Identifiable {
        /// Stable observer identity. Busy state and turn ownership are keyed by
        /// this value, never by the room as a whole.
        public let id: UUID
        public let roomID: String
        public let events: AsyncStream<AgentSharedChatCoordinatorEvent>
    }

    /// Backend access is injected so the coordinator never retains the runner
    /// (no reference cycle) and can be unit-tested without a model backend.
    public struct Source: Sendable {
        public let drainCoordinatorMessages: @Sendable (String) async -> [AgentSharedChat.Message]
        public let participants: @Sendable (String) async -> [AgentSharedChat.Participant]
        /// Read-only transcript access: returns every retained message in a
        /// room without draining any mailbox. Used to display agent-to-agent
        /// traffic that never enters the coordinator mailbox.
        public let allRoomMessages: @Sendable (String) async -> [AgentSharedChat.Message]

        public init(
            drainCoordinatorMessages: @escaping @Sendable (String) async -> [AgentSharedChat.Message],
            participants: @escaping @Sendable (String) async -> [AgentSharedChat.Participant],
            allRoomMessages: @escaping @Sendable (String) async -> [AgentSharedChat.Message]
        ) {
            self.drainCoordinatorMessages = drainCoordinatorMessages
            self.participants = participants
            self.allRoomMessages = allRoomMessages
        }
    }

    /// Upper bound for messages parked outside a mailbox. It matches the room
    /// transcript bound, so a stalled consumer cannot grow memory without limit.
    static let maximumPendingMessages = AgentSharedChat.maximumRetainedMessagesPerRoom

    /// Upper bound for events buffered for one observer that is not consuming
    /// its stream. It is half the transcript bound: large enough that a healthy
    /// consumer never drops an event, small enough that a stalled one cannot
    /// grow memory without limit.
    ///
    /// Overflow policy: the *oldest* buffered events are evicted first, because
    /// the newest render/roster state is the useful one. Rendering loss is
    /// therefore accepted under overflow, while coordination is not: a drop
    /// marks the room for a trigger re-offer (see
    /// ``maximumAutoTriggerReoffers``), and an outstanding trigger is also
    /// replayed to every newly attached observer.
    static let maximumBufferedEventsPerSubscriber = AgentSharedChat.maximumRetainedMessagesPerRoom / 2

    /// How many times one unclaimed trigger may be re-offered after an observer
    /// buffer overflow before the coordinator retires that offer. The batch is
    /// never lost: an exhausted budget returns it to the head of the queue, so
    /// the next idle evaluation mints a fresh trigger with a fresh budget
    /// instead of parking an offer nobody answers in front of the queue.
    static let maximumAutoTriggerReoffers = 3

    /// How many drain rounds one ``poll(roomID:)`` may run before handing the
    /// room back to the monitor.
    ///
    /// A producer that keeps the mailbox non-empty must not own the poll loop
    /// forever: without this budget a hot room would starve its own re-offer
    /// step (which runs after the loop) and every other room served by the same
    /// actor. Leftover work is not dropped — it re-arms the monitor signal, so
    /// draining continues on the next wake-up with fair interleaving.
    static let maximumDrainRoundsPerPoll = 4

    /// One synthetic turn owned by exactly one observer.
    ///
    /// A claim is bound to the turn that *consumes* it. The trigger prompt is
    /// minted by the Core for this batch alone and every consumer injects it
    /// verbatim, so the turn carrying exactly that text is the turn this claim
    /// was granted for. Until such a turn starts the claim is unconsumed and
    /// its batch is still owed to the queue; afterwards the batch lives inside
    /// the running generation, where requeueing it would duplicate it and an
    /// unrelated turn ending must not release it.
    private struct Claim {
        let triggerID: UUID
        let owner: UUID
        let messages: [AgentSharedChat.Message]
        /// Core-minted prompt of the trigger: the binding key for its turn.
        let prompt: String
        /// The turn that injected this batch, once one started.
        var consumingTurnID: UUID?

        var isConsumed: Bool { consumingTurnID != nil }
    }

    /// Identity of one turn tracked by the coordinator.
    ///
    /// ``noteTurnStarted(roomID:prompt:)`` mints it and ``noteTurnEnded(_:)``
    /// consumes it, so ending a turn can only ever end *that* turn: a repeated
    /// end is idempotent instead of double-decrementing the room, and one turn
    /// can never release the claim another turn owns.
    struct TurnToken: Sendable, Hashable {
        let id: UUID
        let roomID: String
    }

    /// Capability returned by ``beginReset(roomID:)``.
    ///
    /// It names the room *and* the suspension it opened, so a late or repeated
    /// resume cannot re-arm a room that a newer reset, stop or replacement
    /// already owns.
    struct ResetToken: Sendable, Hashable {
        let roomID: String
        let generation: UInt64
    }

    /// Whether a released claim still owes its batch to the queue.
    private enum ClaimRelease {
        /// Return the batch to the head of the queue *unless* a turn already
        /// consumed it. Requeueing a consumed batch would inject it twice.
        case requeueingUnconsumedBatch
        /// The claimant keeps the batch: it received the trigger and answered
        /// for it, so the queue no longer owes it a turn.
        case keepingBatch
    }

    private struct Room {
        /// Monotonic identity of this room *instance*.
        ///
        /// A drain suspends on the backend, so `stopAll` (or any teardown that
        /// removes the entry) can retire the room while a poll is in flight.
        /// The generation lets that poll detect it is speaking for a room that
        /// no longer exists — or for a different room that reused the same id —
        /// and abort instead of resurrecting it.
        var generation: UInt64
        var pending: [AgentSharedChat.Message] = []
        /// Published and not yet claimed. Any observer may claim or decline it.
        var activeTrigger: AgentSharedChatAutoTrigger?
        /// Claimed turn. Only its owner can release it; every other observer
        /// sees the room as busy until it does.
        var claim: Claim?
        /// Turns observed by the Core itself (`AgentCoreSessionRunner.sendPrompt`),
        /// keyed by turn identity so an end releases exactly the turn it names.
        var activeTurns: Set<UUID> = []
        /// Set between ``beginReset(roomID:)`` and ``endReset(_:)``: the source
        /// this room drains is being rebuilt, so neither a drain nor an offer
        /// may run against a backend that is about to be cleared.
        var isAwaitingSourceRebuild = false
        /// Busy state declared per observer, covering the window between a
        /// queued prompt and its actual turn start. One observer reporting
        /// itself idle can never clear another observer's declaration.
        var busyObservers: Set<UUID> = []
        var participantSignature: [String]?
        var subscribers: [UUID: AsyncStream<AgentSharedChatCoordinatorEvent>.Continuation] = [:]
        var monitorTask: Task<Void, Never>?
        var tickerTask: Task<Void, Never>?
        var signal: AsyncStream<Void>.Continuation?
        /// Single-flight guard around the asynchronous drain itself.
        var isPolling = false
        var pollRequested = false
        /// Set when a subscriber buffer evicted an event, so the next poll can
        /// re-offer an outstanding trigger that may have been evicted with it.
        var needsTriggerReoffer = false
        var triggerReofferCount = 0
        var droppedEventCount = 0
        /// IDs of messages already emitted as `.messages` events to observers.
        /// Prevents re-emitting the same transcript message on every poll while
        /// the read-only `allRoomMessages` source keeps returning the full
        /// bounded transcript. Bounded by the same limit as the transcript.
        var emittedMessageIDs: Set<UUID> = []

        var turnsInFlight: Int { activeTurns.count }

        var isBusy: Bool {
            !activeTurns.isEmpty || !busyObservers.isEmpty || claim != nil
        }
    }

    private let source: Source
    private let pollInterval: Duration
    private var rooms: [String: Room] = [:]
    /// Never reused, so a room recreated under a known id is never mistaken for
    /// the instance an in-flight poll observed.
    private var nextRoomGeneration: UInt64 = 1
    /// Identity used by the deprecated room-scoped API (see
    /// `AgentSharedChatCoordinator+Compatibility.swift`): the most recent legacy
    /// observer of a room, which is the single consumer that API assumed.
    private var legacyObservations: [String: Observation] = [:]

    public init(
        source: Source,
        pollInterval: Duration = .milliseconds(120)
    ) {
        self.source = source
        self.pollInterval = pollInterval
    }

    // MARK: - Observation

    /// Creates a bounded event stream with its own observer identity.
    ///
    /// Any number of consumers may observe the same room; the monitor, the
    /// drain and the auto-trigger decision stay owned here, so no subscriber
    /// becomes the semantic owner of the auto-trigger. The returned value is
    /// also the capability used to declare busy state
    /// (``setConsumerBusy(_:observation:)``) and to claim a turn
    /// (``resolveAutoTrigger(id:observation:resolution:)``): both are keyed by
    /// this observer, never by the room.
    public func observeSubscription(roomID rawRoomID: String) -> Observation {
        let roomID = Self.normalizedRoomID(rawRoomID)
        let subscriberID = UUID()
        let (stream, continuation) = AsyncStream<AgentSharedChatCoordinatorEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.maximumBufferedEventsPerSubscriber)
        )
        continuation.onTermination = { [weak self] _ in
            Task(name: "ZenCODE.shared-chat.unsubscribe") { [weak self] in
                await self?.removeSubscriber(subscriberID, roomID: roomID)
            }
        }
        var room = rooms[roomID] ?? makeRoom()
        room.subscribers[subscriberID] = continuation
        // A newly attached observer restores the room's ability to answer an
        // outstanding trigger, so the overflow re-offer budget starts again.
        room.triggerReofferCount = 0
        rooms[roomID] = room

        // A consumer that attaches after a close/reset must still see whatever
        // never reached a synthetic turn, so replay the parked batch.
        if !room.pending.isEmpty {
            continuation.yield(.messages(room.pending))
        }
        // An unclaimed trigger is replayed too: it is the recovery path for an
        // observer that dropped the original broadcast under buffer overflow.
        if let trigger = room.activeTrigger {
            continuation.yield(.autoTrigger(trigger))
        }
        startMonitorIfNeeded(roomID: roomID)
        evaluate(roomID: roomID)
        requestPoll(roomID: roomID)
        return Observation(
            id: subscriberID,
            roomID: roomID,
            events: stream
        )
    }

    /// Ends one observer's event stream and releases only the state it owns:
    /// its busy declaration and, if it holds one, its claimed turn. A claimed
    /// batch that never reached a prompt is requeued at the head so no live
    /// message is lost; one a turn is already carrying is not, because that
    /// generation is delivering it. Other subscribers and the room-wide monitor
    /// are untouched; the last detached observer also releases an unclaimed
    /// trigger, ready for a future observer.
    public func detach(_ observation: Observation) {
        releaseSubscriber(
            observation.id,
            roomID: observation.roomID,
            finishesStream: true
        )
    }

    /// Stops monitoring a room and terminates its subscriptions (close path).
    /// Undelivered work is preserved: an unresolved batch and a claimed turn
    /// that never reached a prompt both return to `pending`. A claim a turn
    /// already consumed is released without requeueing, because that batch is
    /// inside the generation it opened.
    public func stop(roomID rawRoomID: String) {
        let roomID = Self.normalizedRoomID(rawRoomID)
        guard var room = rooms[roomID] else { return }
        room.monitorTask?.cancel()
        room.monitorTask = nil
        room.tickerTask?.cancel()
        room.tickerTask = nil
        room.signal?.finish()
        room.signal = nil
        requeueActiveTrigger(&room)
        releaseClaim(&room, .requeueingUnconsumedBatch)
        // A room that stops mid-rebuild must not stay suspended forever: the
        // resume it was waiting for belongs to a lifecycle that just ended.
        room.isAwaitingSourceRebuild = false
        let subscribers = room.subscribers
        room.subscribers.removeAll()
        room.busyObservers.removeAll()
        rooms[roomID] = room
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    /// Backend reset in one step, for callers that rebuild the source before
    /// returning. Prefer ``beginReset(roomID:)``/``endReset(_:)`` when the
    /// rebuild suspends: they keep the room fenced *across* the rebuild.
    public func reset(roomID rawRoomID: String) {
        guard let token = beginReset(roomID: rawRoomID) else { return }
        endReset(token)
    }

    /// Opens a backend reset: the transient bus is about to be rebuilt
    /// underneath this room.
    ///
    /// An unresolved batch returns to the queue while the monitor and every
    /// live subscription stay attached, and the room receives a fresh
    /// generation so a pre-reset drain still suspended on the retired backend
    /// is fenced out instead of being ingested into the rebuilt room.
    ///
    /// Polling and offering are then *suspended* until ``endReset(_:)``. That
    /// is the half a generation alone cannot express: between this call and the
    /// backend clear the retiring bus is still answering, so a poll woken in
    /// that window would drain messages the clear is about to destroy and
    /// inject them into the rebuilt session, and an offer published there would
    /// open a synthetic turn against a session being torn down.
    @discardableResult
    func beginReset(roomID rawRoomID: String) -> ResetToken? {
        let roomID = Self.normalizedRoomID(rawRoomID)
        guard var room = rooms[roomID] else { return nil }
        requeueActiveTrigger(&room)
        releaseClaim(&room, .requeueingUnconsumedBatch)
        room.busyObservers.removeAll()
        room.generation = allocateRoomGeneration()
        // Any suspended pre-reset drain owns the old generation. Its `defer`
        // must not unlock this replacement, which is ready to start a fresh
        // poll against the rebuilt backend as soon as the reset closes.
        room.isPolling = false
        room.pollRequested = false
        room.isAwaitingSourceRebuild = true
        rooms[roomID] = room
        return ResetToken(roomID: roomID, generation: room.generation)
    }

    /// Closes the reset opened by ``beginReset(roomID:)`` and re-arms the room
    /// against the rebuilt source.
    ///
    /// A token whose generation is no longer the live one is ignored: the room
    /// was stopped, reset again or replaced meanwhile, and that newer lifecycle
    /// owns the decision to resume.
    func endReset(_ token: ResetToken) {
        guard var room = rooms[token.roomID], room.generation == token.generation else {
            return
        }
        room.isAwaitingSourceRebuild = false
        rooms[token.roomID] = room
        evaluate(roomID: token.roomID)
        requestPoll(roomID: token.roomID)
    }

    /// Full teardown. Rooms and their parked messages are dropped because the
    /// runtime tree that produced them no longer exists. A drain still
    /// suspended on that tree is fenced by the room generation, so it cannot
    /// recreate what this call retires.
    public func stopAll() {
        for roomID in Array(rooms.keys) {
            stop(roomID: roomID)
        }
        rooms.removeAll()
        legacyObservations.removeAll()
    }

    // MARK: - Deprecated room-scoped API support

    /// Records the identity handed out by the deprecated `observe(roomID:)`.
    func registerLegacyObservation(_ observation: Observation) {
        legacyObservations[observation.roomID] = observation
    }

    /// The room's legacy observer, if it is still attached. A detached entry is
    /// purged instead of being used, so a deprecated call can never act for an
    /// observer that no longer exists.
    func legacyObservation(roomID rawRoomID: String) -> Observation? {
        let roomID = Self.normalizedRoomID(rawRoomID)
        guard let observation = legacyObservations[roomID] else { return nil }
        guard rooms[roomID]?.subscribers[observation.id] != nil else {
            legacyObservations.removeValue(forKey: roomID)
            return nil
        }
        return observation
    }

    // MARK: - Busy state

    /// Declared by a consumer that queues or runs prompts of its own. Combined
    /// with Core turn tracking it guarantees that a synthetic turn never races
    /// an operator prompt.
    ///
    /// The declaration is scoped to `observation`: a second terminal, ACP or
    /// headless consumer reporting itself idle cannot clear it, and a detached
    /// observer can neither hold the room busy nor release it.
    public func setConsumerBusy(_ isBusy: Bool, observation: Observation) {
        let roomID = observation.roomID
        guard var room = rooms[roomID], room.subscribers[observation.id] != nil else {
            return
        }
        guard !isBusy else {
            room.busyObservers.insert(observation.id)
            rooms[roomID] = room
            return
        }
        room.busyObservers.remove(observation.id)
        // Going idle also ends this observer's own claimed turn: it either
        // finished the synthetic generation or never managed to start it. The
        // batch is not requeued, because the claimant already received it with
        // the trigger it acknowledged.
        if room.claim?.owner == observation.id {
            releaseClaim(&room, .keepingBatch)
        }
        rooms[roomID] = room
        evaluate(roomID: roomID)
        requestPoll(roomID: roomID)
    }

    /// Called by the session runner around every prompt, including operator and
    /// synthetic turns, so busy detection does not depend on consumer honesty.
    ///
    /// The `prompt` is what binds a claim to its turn. A trigger prompt is
    /// minted by the Core for one batch and injected verbatim, so the turn that
    /// carries exactly that text is the turn the claim was granted for. Any
    /// other prompt — an operator turn, a replay, another room's work — starts
    /// an unrelated turn that keeps the room busy but can never release, and
    /// therefore never strand or duplicate, someone else's claimed batch.
    @discardableResult
    func noteTurnStarted(roomID rawRoomID: String, prompt: String) -> TurnToken {
        let roomID = Self.normalizedRoomID(rawRoomID)
        var room = rooms[roomID] ?? makeRoom()
        let token = TurnToken(id: UUID(), roomID: roomID)
        room.activeTurns.insert(token.id)
        if var claim = room.claim, !claim.isConsumed, claim.prompt == prompt {
            claim.consumingTurnID = token.id
            room.claim = claim
        }
        rooms[roomID] = room
        return token
    }

    /// Ends exactly the turn `token` names.
    ///
    /// A turn that never consumed a claim leaves every claim untouched: the
    /// batch of a claimant that has not started yet stays owed to it, and no
    /// unrelated generation can hand the room to a second synthetic turn while
    /// that claimant is still opening its own.
    func noteTurnEnded(_ token: TurnToken) {
        guard var room = rooms[token.roomID],
              room.activeTurns.remove(token.id) != nil else {
            return
        }
        // A claimant whose turn ran cannot stall the room: the end of *its*
        // turn releases the claim. The batch is not requeued — it was injected
        // into the generation that just finished. Its own busy declaration, if
        // any, still has to be withdrawn by the claimant.
        if room.claim?.consumingTurnID == token.id {
            releaseClaim(&room, .keepingBatch)
        }
        rooms[token.roomID] = room
        guard room.activeTurns.isEmpty else { return }
        evaluate(roomID: token.roomID)
        requestPoll(roomID: token.roomID)
    }

    // MARK: - Auto-trigger resolution

    /// Answers an emitted trigger on behalf of one observer.
    ///
    /// Resolving `started` atomically claims the active entry *for this
    /// observer*: only the caller that receives
    /// ``AgentSharedChatAutoTriggerClaimResult/acquired`` may start the
    /// synthetic generation, and only that caller can later release the claim.
    /// A stale `started` response is a no-op, and so is one that arrives after
    /// the room became busy: the batch is requeued and re-offered when the room
    /// is idle again. `declined` re-queues the batch — the unclaimed trigger
    /// for any observer, or its own claim for the owner — and never grants
    /// ownership.
    @discardableResult
    public func resolveAutoTrigger(
        id: UUID,
        observation: Observation,
        resolution: AgentSharedChatAutoTriggerResolution
    ) -> AgentSharedChatAutoTriggerClaimResult {
        let roomID = observation.roomID
        guard var room = rooms[roomID] else { return .notAcquired }

        // An already claimed trigger is owner-private: another observer can
        // neither re-acquire it nor return it to the queue.
        if let claim = room.claim, claim.triggerID == id {
            guard claim.owner == observation.id, resolution == .declined else {
                return .notAcquired
            }
            releaseClaim(&room, .requeueingUnconsumedBatch)
            rooms[roomID] = room
            evaluate(roomID: roomID)
            return .notAcquired
        }

        guard let trigger = room.activeTrigger, trigger.id == id else {
            return .notAcquired
        }
        switch resolution {
        case .started:
            // A detached consumer cannot own a turn nobody would finish.
            guard room.subscribers[observation.id] != nil else {
                requeueActiveTrigger(&room)
                rooms[roomID] = room
                evaluate(roomID: roomID)
                return .notAcquired
            }
            // The offer was published while the room was idle, but this
            // acknowledgement arrives asynchronously: an operator turn tracked
            // by the Core, another observer's busy declaration, or a claim
            // taken meanwhile may have occupied the room in between. The busy
            // check, the removal of the offer and the ownership record all run
            // in this single actor step, so a late claim can never open a turn
            // that races the work already in flight. The batch returns to the
            // queue and is re-offered once the room is genuinely idle.
            guard !room.isBusy else {
                requeueActiveTrigger(&room)
                rooms[roomID] = room
                return .notAcquired
            }
            room.activeTrigger = nil
            // The consumer owns a turn now. Recording the claim here closes the
            // window between this acknowledgement and the moment its prompt
            // actually reaches `sendPrompt`, and binds the busy state to it.
            // The trigger prompt travels with the claim: it is what identifies
            // the turn that will consume this batch.
            room.claim = Claim(
                triggerID: trigger.id,
                owner: observation.id,
                messages: trigger.messages,
                prompt: trigger.prompt
            )
            rooms[roomID] = room
            return .acquired
        case .declined:
            requeueActiveTrigger(&room)
            rooms[roomID] = room
            evaluate(roomID: roomID)
            return .notAcquired
        }
    }

    /// Returns an *unclaimed* trigger to the queue without observer identity.
    ///
    /// This is the retired-room path: a consumer that already rebound to a new
    /// session still has to release the batch it will never answer. It can only
    /// requeue work; it can never grant a turn or disturb an existing claim.
    public func declineAutoTrigger(id: UUID, roomID rawRoomID: String) {
        let roomID = Self.normalizedRoomID(rawRoomID)
        guard var room = rooms[roomID], room.activeTrigger?.id == id else {
            return
        }
        requeueActiveTrigger(&room)
        rooms[roomID] = room
        evaluate(roomID: roomID)
    }

    // MARK: - Introspection (diagnostics and tests)

    func pendingMessageCount(roomID rawRoomID: String) -> Int {
        rooms[Self.normalizedRoomID(rawRoomID)]?.pending.count ?? 0
    }

    func activeAutoTriggerID(roomID rawRoomID: String) -> UUID? {
        rooms[Self.normalizedRoomID(rawRoomID)]?.activeTrigger?.id
    }

    /// The room's unclaimed offer. A consumer binds its turn to the claim it
    /// takes by injecting exactly this trigger's prompt, so diagnostics and
    /// tests need the offer itself, not only its id.
    func activeAutoTrigger(roomID rawRoomID: String) -> AgentSharedChatAutoTrigger? {
        rooms[Self.normalizedRoomID(rawRoomID)]?.activeTrigger
    }

    func activeAutoTriggerMessageCount(roomID rawRoomID: String) -> Int {
        rooms[Self.normalizedRoomID(rawRoomID)]?.activeTrigger?.messages.count ?? 0
    }

    /// Every message the room still owes to a turn — parked, offered or claimed
    /// — read in one actor step, so a conservation check cannot observe a
    /// half-applied requeue.
    func retainedMessageCount(roomID rawRoomID: String) -> Int {
        guard let room = rooms[Self.normalizedRoomID(rawRoomID)] else { return 0 }
        return room.pending.count
            + (room.activeTrigger?.messages.count ?? 0)
            + (room.claim?.messages.count ?? 0)
    }

    func claimedAutoTriggerOwnerID(roomID rawRoomID: String) -> UUID? {
        rooms[Self.normalizedRoomID(rawRoomID)]?.claim?.owner
    }

    /// Whether the room's claimed batch already reached a prompt. A consumed
    /// batch lives inside a running generation, so no release path may requeue
    /// it without duplicating those messages.
    func hasConsumedClaim(roomID rawRoomID: String) -> Bool {
        rooms[Self.normalizedRoomID(rawRoomID)]?.claim?.isConsumed ?? false
    }

    /// Turns the Core is tracking for a room, by identity rather than by count.
    func turnsInFlight(roomID rawRoomID: String) -> Int {
        rooms[Self.normalizedRoomID(rawRoomID)]?.turnsInFlight ?? 0
    }

    /// Whether the room is fenced between ``beginReset(roomID:)`` and
    /// ``endReset(_:)``.
    func isAwaitingSourceRebuild(roomID rawRoomID: String) -> Bool {
        rooms[Self.normalizedRoomID(rawRoomID)]?.isAwaitingSourceRebuild ?? false
    }

    func busyObserverCount(roomID rawRoomID: String) -> Int {
        rooms[Self.normalizedRoomID(rawRoomID)]?.busyObservers.count ?? 0
    }

    /// Whether the coordinator still holds any state for a room. `stopAll`
    /// clears it; a stale poll must not bring it back.
    func isTrackingRoom(roomID rawRoomID: String) -> Bool {
        rooms[Self.normalizedRoomID(rawRoomID)] != nil
    }

    func droppedEventCount(roomID rawRoomID: String) -> Int {
        rooms[Self.normalizedRoomID(rawRoomID)]?.droppedEventCount ?? 0
    }

    func isMonitoring(roomID rawRoomID: String) -> Bool {
        rooms[Self.normalizedRoomID(rawRoomID)]?.monitorTask != nil
    }

    // MARK: - Monitor

    private func startMonitorIfNeeded(roomID: String) {
        guard var room = rooms[roomID], room.monitorTask == nil else { return }
        let (signals, signalContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        room.signal = signalContinuation
        // The ticker is a safety net for a rebuilt backend: the shared-chat bus
        // lives inside the backend tree, so a wake-up callback cannot survive
        // every reset. Draining is idempotent, so both paths can coexist.
        room.tickerTask = Task(name: "ZenCODE.shared-chat.monitor-tick") { [pollInterval] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return
                }
                signalContinuation.yield()
            }
        }
        room.monitorTask = Task(name: "ZenCODE.shared-chat.monitor") { [weak self] in
            for await _ in signals {
                if Task.isCancelled { break }
                await self?.poll(roomID: roomID)
            }
        }
        rooms[roomID] = room
    }

    /// Wakes the monitor immediately instead of waiting for the next tick. A
    /// room whose source is being rebuilt stays parked: ``endReset(_:)`` is the
    /// only thing that may re-arm it.
    public func requestPoll(roomID rawRoomID: String) {
        let roomID = Self.normalizedRoomID(rawRoomID)
        guard rooms[roomID]?.isAwaitingSourceRebuild != true else { return }
        rooms[roomID]?.signal?.yield()
    }

    /// Performs one drain/evaluate cycle. Exposed for deterministic tests; the
    /// production monitor calls exactly the same body.
    ///
    /// Three guarantees are encoded here. *Fairness*: the drain loop is bounded
    /// by ``maximumDrainRoundsPerPoll``, and leftover work re-arms the monitor
    /// instead of holding the actor. *Generation fencing*: every suspension is
    /// followed by a check that the room instance this poll started on is still
    /// the live one, performed *before* the next suspension, so a poll that
    /// resumes into a reset, a teardown or a replacement room never consumes
    /// the mailbox of an instance it does not speak for. *Rebuild fencing*: a
    /// room whose source is being rebuilt is not polled at all.
    func poll(roomID rawRoomID: String) async {
        let roomID = Self.normalizedRoomID(rawRoomID)
        guard let room = rooms[roomID], !room.isAwaitingSourceRebuild else { return }
        let generation = room.generation
        guard !room.isPolling else {
            // A drain is already suspended on the backend; coalesce instead of
            // starting a second one that could double-emit a trigger.
            rooms[roomID]?.pollRequested = true
            return
        }
        rooms[roomID]?.isPolling = true
        defer {
            // Only the room instance this poll locked may be unlocked: a room
            // recreated under the same id owns its own single-flight flag.
            if rooms[roomID]?.generation == generation {
                rooms[roomID]?.isPolling = false
            }
        }

        var rounds = 0
        repeat {
            rounds += 1
            rooms[roomID]?.pollRequested = false
            let participants = await source.participants(roomID)
            // The drain below is destructive. Fencing only after it would let a
            // poll that resumed into a reset pull the *rebuilt* mailbox and
            // then discard the batch it removed, so the check happens here,
            // before the next suspension: a stale poll never drains at all.
            guard rooms[roomID]?.generation == generation else {
                // The live instance owns that mailbox: wake it instead of
                // leaving its messages until the next tick.
                requestPoll(roomID: roomID)
                return
            }
            // Hold-back: while a turn is in flight the coordinator must not
            // steal messages from the shared-chat mailbox. Inline delivery —
            // surfaced through the result of the consumer's next tool call —
            // owns the mailbox for the duration of the turn, so a destructive
            // drain here would race it and swallow the very batch it is about
            // to present. The drain is simply deferred: `noteTurnEnded` re-arms
            // the poll, so whatever stayed in the mailbox is drained the instant
            // the room goes idle and becomes the next auto-trigger exactly as it
            // does today. The check reads only actor-isolated state, so no
            // suspension opens between it and the decision to skip.
            let drained: [AgentSharedChat.Message]
            if rooms[roomID]?.activeTurns.isEmpty ?? true {
                // The room dictionary entry survives `stop`, so messages drained
                // across a teardown are parked instead of dropped. A *removed* or
                // *reset* room is different: the runtime tree that produced these
                // messages is gone, so they die with it rather than resurfacing
                // in an instance that never owned them.
                drained = await source.drainCoordinatorMessages(roomID)
                guard rooms[roomID]?.generation == generation else { return }
            } else {
                drained = []
            }
            ingest(participants: participants, messages: drained, roomID: roomID)
            // Emit agent-to-agent messages that never enter the coordinator
            // mailbox. The transcript source is read-only, so filter by
            // `emittedMessageIDs` to avoid re-emitting on every poll.
            let allMessages = await source.allRoomMessages(roomID)
            guard rooms[roomID]?.generation == generation else { return }
            if var room = rooms[roomID], !allMessages.isEmpty {
                let newDisplayMessages = allMessages.filter {
                    !room.emittedMessageIDs.contains($0.id)
                }
                if !newDisplayMessages.isEmpty {
                    emit(.messages(newDisplayMessages), roomID: roomID)
                }
                // Rebuild from the live transcript so stale IDs from evicted
                // messages are pruned automatically.
                room.emittedMessageIDs = Set(allMessages.map(\.id))
                rooms[roomID] = room
            }
            if !drained.isEmpty {
                // A mailbox drain is bounded per call; keep pulling until the
                // mailbox is empty so a burst is never left behind. This never
                // fires for a skipped drain, so the hold-back cannot spin the
                // bounded loop against an unchanging mailbox.
                rooms[roomID]?.pollRequested = true
            }
        } while rooms[roomID]?.pollRequested == true && rounds < Self.maximumDrainRoundsPerPoll

        guard rooms[roomID]?.generation == generation else { return }
        reofferActiveTriggerIfNeeded(roomID: roomID)
        if rooms[roomID]?.pollRequested == true {
            // Budget spent with work still queued: wake the monitor again so the
            // remainder is drained in a later, equally bounded round.
            requestPoll(roomID: roomID)
        }
    }

    /// Republishes an outstanding trigger after a subscriber buffer evicted
    /// events. Claiming is keyed by trigger id, so a re-offer is idempotent:
    /// a consumer that already saw it simply gets `notAcquired`.
    private func reofferActiveTriggerIfNeeded(roomID: String) {
        guard var room = rooms[roomID], room.needsTriggerReoffer else { return }
        room.needsTriggerReoffer = false
        guard let trigger = room.activeTrigger, !room.subscribers.isEmpty else {
            rooms[roomID] = room
            return
        }
        guard room.triggerReofferCount < Self.maximumAutoTriggerReoffers else {
            // Budget exhausted. An offer nobody answers must not stay parked in
            // front of the queue: returning it makes the batch pending again,
            // so the next idle evaluation mints a fresh trigger with a fresh
            // budget. Liveness is preserved and each cycle still costs at most
            // one emission per poll.
            requeueActiveTrigger(&room)
            rooms[roomID] = room
            evaluate(roomID: roomID)
            return
        }
        room.triggerReofferCount += 1
        rooms[roomID] = room
        emit(.autoTrigger(trigger), roomID: roomID)
    }

    // MARK: - Internals

    /// Allocates a room instance with a fresh generation. Rooms are only ever
    /// created here, so no code path can hand out a room that an in-flight poll
    /// could confuse with the instance it started on.
    private func allocateRoomGeneration() -> UInt64 {
        defer { nextRoomGeneration += 1 }
        return nextRoomGeneration
    }

    private func makeRoom() -> Room {
        Room(generation: allocateRoomGeneration())
    }

    private func ingest(
        participants: [AgentSharedChat.Participant],
        messages: [AgentSharedChat.Message],
        roomID: String
    ) {
        // Never recreate a room here: ingestion always follows a drain, and a
        // drain that outlived its room must not resurrect it.
        guard var room = rooms[roomID] else { return }
        let signature = participants.map { "\($0.id)|\($0.name)|\($0.isActive)" }
        // An empty first observation is not a change: it would only make the
        // consumer refresh a roster that never had participants.
        let participantsChanged = room.participantSignature != signature
            && !(room.participantSignature == nil && signature.isEmpty)
        room.participantSignature = signature
        if !messages.isEmpty {
            room.pending.append(contentsOf: messages)
            if room.pending.count > Self.maximumPendingMessages {
                room.pending.removeFirst(room.pending.count - Self.maximumPendingMessages)
            }
            room.emittedMessageIDs.formUnion(messages.map(\.id))
        }
        rooms[roomID] = room

        if participantsChanged {
            emit(.participantsChanged(participants), roomID: roomID)
        }
        if !messages.isEmpty {
            emit(.messages(messages), roomID: roomID)
        }
        evaluate(roomID: roomID)
    }

    /// The single-flight decision. It is deliberately synchronous: no suspension
    /// happens between reading the busy state and publishing a trigger, so two
    /// concurrent callers cannot both decide that the room is idle.
    private func evaluate(roomID: String) {
        guard var room = rooms[roomID],
              room.activeTrigger == nil,
              !room.isBusy,
              // A source being rebuilt cannot host a synthetic turn: the offer
              // waits for `endReset` instead of opening a generation against a
              // session that is being cleared.
              !room.isAwaitingSourceRebuild,
              !room.pending.isEmpty,
              // Without a live consumer the batch stays queued instead of being
              // consumed by a turn nobody would run.
              !room.subscribers.isEmpty else {
            return
        }
        let batch = Array(room.pending.prefix(AgentSharedChat.maximumMessagesPerInjectedPrompt))
        room.pending.removeFirst(batch.count)
        let trigger = AgentSharedChatAutoTrigger(
            roomID: roomID,
            messages: batch,
            prompt: Self.coordinatorPrompt(for: batch)
        )
        room.activeTrigger = trigger
        room.triggerReofferCount = 0
        rooms[roomID] = room
        emit(.autoTrigger(trigger), roomID: roomID)
    }

    private func requeueActiveTrigger(_ room: inout Room) {
        guard let trigger = room.activeTrigger else { return }
        room.activeTrigger = nil
        room.triggerReofferCount = 0
        requeue(trigger.messages, in: &room)
    }

    /// Releases the room's claim.
    ///
    /// ``ClaimRelease/requeueingUnconsumedBatch`` is the safe default for every
    /// path that gives a turn back: it returns the batch only while no turn has
    /// injected it, so a claim released while its generation is running cannot
    /// deliver the same messages twice.
    private func releaseClaim(_ room: inout Room, _ policy: ClaimRelease) {
        guard let claim = room.claim else { return }
        room.claim = nil
        guard policy == .requeueingUnconsumedBatch, !claim.isConsumed else { return }
        requeue(claim.messages, in: &room)
    }

    /// Returns undelivered messages to the head of the queue. The bound is
    /// enforced from the tail so the oldest live message survives a requeue.
    private func requeue(_ messages: [AgentSharedChat.Message], in room: inout Room) {
        guard !messages.isEmpty else { return }
        room.pending.insert(contentsOf: messages, at: 0)
        if room.pending.count > Self.maximumPendingMessages {
            room.pending.removeLast(room.pending.count - Self.maximumPendingMessages)
        }
    }

    /// Publishes to every subscriber of a room.
    ///
    /// Each stream is bounded, so a stalled consumer evicts its own oldest
    /// events instead of growing without limit. A drop is recorded and marks
    /// the room for a trigger re-offer, so losing render events never loses the
    /// coordination decision itself.
    private func emit(_ event: AgentSharedChatCoordinatorEvent, roomID: String) {
        guard var room = rooms[roomID] else { return }
        var droppedCount = 0
        for continuation in room.subscribers.values {
            if case .dropped = continuation.yield(event) {
                droppedCount += 1
            }
        }
        guard droppedCount > 0 else { return }
        room.droppedEventCount += droppedCount
        room.needsTriggerReoffer = true
        rooms[roomID] = room
    }

    private func removeSubscriber(_ id: UUID, roomID: String) {
        releaseSubscriber(id, roomID: roomID, finishesStream: false)
    }

    /// The single teardown path for one observer, shared by explicit detach and
    /// by stream termination. It releases exactly the state this observer owns.
    private func releaseSubscriber(
        _ id: UUID,
        roomID: String,
        finishesStream: Bool
    ) {
        guard var room = rooms[roomID], room.subscribers[id] != nil else { return }
        let continuation = room.subscribers.removeValue(forKey: id)
        room.busyObservers.remove(id)
        // The claim owner is leaving. If its turn never started, the batch
        // returns to the head of the queue for another observer; if a turn is
        // already carrying it, the claim is released without requeueing, so a
        // detach in the middle of a running generation cannot duplicate it.
        if room.claim?.owner == id {
            releaseClaim(&room, .requeueingUnconsumedBatch)
        }
        if room.subscribers.isEmpty {
            // Nobody can run a synthetic turn anymore: release the batch so it
            // is re-offered to the next consumer instead of being lost.
            requeueActiveTrigger(&room)
            releaseClaim(&room, .requeueingUnconsumedBatch)
            room.monitorTask?.cancel()
            room.monitorTask = nil
            room.tickerTask?.cancel()
            room.tickerTask = nil
            room.signal?.finish()
            room.signal = nil
            room.busyObservers.removeAll()
        }
        rooms[roomID] = room
        if finishesStream {
            // Finishing after the removal keeps the `onTermination` callback a
            // no-op instead of racing this teardown.
            continuation?.finish()
        }
        evaluate(roomID: roomID)
        requestPoll(roomID: roomID)
    }

    private static func normalizedRoomID(_ rawValue: String) -> String {
        AgentSharedChat.boundedRoomIdentifier(rawValue)
    }

    /// Core-owned prompt text for a synthetic coordinator turn, shared by every
    /// consumer so terminal and headless drivers inject identical content.
    ///
    /// Message content is quoted by ``AgentSharedChat/promptTranscript(for:)``,
    /// so no sender name or message body can forge a second sender header.
    public static func coordinatorPrompt(
        for messages: [AgentSharedChat.Message]
    ) -> String {
        """
        [Live chat messages]
        \(AgentSharedChat.promptTranscript(for: messages))

        \(AgentSharedChat.promptTrustBoundaryNote)
        Reply to the sender through this chat using the `agent.message` tool: address a delegated agent by its `id`/`name`, or use `to: "all"` so the operator and every active agent see the reply. Your ordinary output does not reach this chat, so any reply to a chat message must be sent via `agent.message`. Coordinate the active work and do not claim that this transient message bus is persisted.
        """
    }
}
