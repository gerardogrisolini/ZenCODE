//
//  AgentSharedChatCoordinator.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

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
/// * transcript message delivery is accounted independently for each observer:
///   an attach-time replay and a concurrent poll cannot suppress or duplicate a
///   raw `.messages` event for another stream;
/// * draining is bounded per poll and every suspension is generation-fenced
///   *before* the next one, so one hot room cannot starve the others, a drain
///   that outlives its room can never resurrect it, and a stale poll can never
///   consume the mailbox of the instance that replaced it;
/// * the mailbox is drained even while a turn is in flight: a message that
///   lands mid-turn is parked in `pending` and shown to every observer, but the
///   single-flight `evaluate` keeps it from starting a turn until the room goes
///   idle, so `noteTurnEnded` is what re-arms the next auto-trigger
///   (see ``poll(roomID:)``);
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
    private let source: Source
    private let pollInterval: Duration
    var rooms: [String: Room] = [:]
    /// Never reused, so a room recreated under a known id is never mistaken for
    /// the instance an in-flight poll observed.
    private var nextRoomGeneration: UInt64 = 1

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
                await self?.releaseSubscriber(subscriberID, roomID: roomID, finishesStream: false)
            }
        }
        var room = rooms[roomID] ?? makeRoom()
        room.subscribers[subscriberID] = continuation
        // Transcript delivery is owed independently to each stream: never inherit a ledger.
        room.enqueuedMessageIDsBySubscriber[subscriberID] = []
        // A newly attached observer restores the room's ability to answer an
        // outstanding trigger, so the overflow re-offer budget starts again.
        room.triggerReofferCount = 0
        let pending = room.pending
        let activeTrigger = room.activeTrigger
        let generation = room.generation
        rooms[roomID] = room

        if !pending.isEmpty {
            emitMessages(pending, roomID: roomID, onlyTo: subscriberID)
        }
        // Replaying an unclaimed trigger recovers an observer that dropped the broadcast.
        if let trigger = activeTrigger {
            emit(.autoTrigger(trigger), roomID: roomID, onlyTo: subscriberID)
        }
        // The replay and a concurrent poll both go through `emitMessages`, so
        // per-observer actor state makes their ordering irrelevant.
        Task(name: "ZenCODE.shared-chat.transcript-replay") { [weak self] in
            await self?.replayTranscript(
                to: subscriberID,
                roomID: roomID,
                generation: generation
            )
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

    /// Ends one observer's stream and releases only the state it owns (busy
    /// declaration and claimed turn). An unconsumed claimed batch is requeued at
    /// the head; one a turn is already carrying is not. The last detached
    /// observer also releases an unclaimed trigger.
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
        room.cancelMonitor()
        requeueActiveTrigger(&room)
        releaseClaim(&room, .requeueingUnconsumedBatch)
        // A room that stops mid-rebuild must not stay suspended forever.
        room.isAwaitingSourceRebuild = false
        let subscribers = room.subscribers
        room.subscribers.removeAll()
        room.busyObservers.removeAll()
        room.enqueuedMessageIDsBySubscriber.removeAll()
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
        // A suspended pre-reset drain owns the old generation; its `defer` must not unlock this room.
        room.isPolling = false
        room.pollRequested = false
        room.isAwaitingSourceRebuild = true
        // IDs from the retired transcript must neither suppress nor be recovered into the new one.
        room.enqueuedMessageIDsBySubscriber.removeAll()
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
        // Going idle ends this observer's own claimed turn; the batch is not
        // requeued because the claimant already received it with the trigger.
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
        // The end of the claimant's own turn releases the claim without requeueing:
        // the batch was injected into the generation that just finished.
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
            // The room may have become busy between the offer and this async
            // acknowledgement. The busy check, offer removal and ownership record
            // run in one actor step, so a late claim never races work in flight;
            // the batch is re-offered once the room is idle.
            guard !room.isBusy else {
                requeueActiveTrigger(&room)
                rooms[roomID] = room
                return .notAcquired
            }
            room.activeTrigger = nil
            // Recording the claim closes the window before the prompt reaches
            // `sendPrompt`; the trigger prompt identifies the consuming turn.
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
    /// Replays the bounded room transcript to one observer. Called when a new
    /// observer attaches so it sees every retained message — including
    /// agent-to-agent traffic that never entered the coordinator mailbox and was
    /// already emitted to existing observers.
    ///
    /// Fetching the source is asynchronous, but applying its result is an actor
    /// step and uses the same per-observer helper as a poll. Therefore either
    /// ordering is safe: a poll that wins marks this observer first, while a
    /// replay that wins cannot suppress delivery to a different observer.
    private func replayTranscript(
        to subscriberID: UUID,
        roomID: String,
        generation: UInt64
    ) async {
        let allMessages = await source.allRoomMessages(roomID)
        guard rooms[roomID]?.generation == generation,
              rooms[roomID]?.subscribers[subscriberID] != nil else {
            return
        }
        emitMessages(allMessages, roomID: roomID, onlyTo: subscriberID)
    }

    // MARK: - Monitor

    private func startMonitorIfNeeded(roomID: String) {
        guard var room = rooms[roomID], room.monitorTask == nil else { return }
        let (signals, signalContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        room.signal = signalContinuation
        // Safety net for a rebuilt backend: wake-up callbacks cannot survive every reset.
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
            // Coalesce instead of starting a second drain that could double-emit a trigger.
            rooms[roomID]?.pollRequested = true
            return
        }
        rooms[roomID]?.isPolling = true
        defer {
            // A room recreated under the same id owns its own single-flight flag.
            if rooms[roomID]?.generation == generation {
                rooms[roomID]?.isPolling = false
            }
        }

        var rounds = 0
        repeat {
            rounds += 1
            rooms[roomID]?.pollRequested = false
            let participants = await source.participants(roomID)
            // The drain below is destructive, so fence before it: a stale poll must never drain.
            guard rooms[roomID]?.generation == generation else {
                // The live instance owns that mailbox: wake it.
                requestPoll(roomID: roomID)
                return
            }
            // While a coordinator turn is active its direct-tool executor owns this
            // mailbox; stealing the batch into `pending` would delay the reply.
            // `noteTurnEnded` re-arms the poll as the lossless fallback.
            let drained: [AgentSharedChat.Message]
            if rooms[roomID]?.activeTurns.isEmpty ?? true {
                drained = await source.drainCoordinatorMessages(roomID)
                guard rooms[roomID]?.generation == generation else { return }
            } else {
                drained = []
            }
            ingest(participants: participants, messages: drained, roomID: roomID)
            // Agent-to-agent messages never enter the coordinator mailbox. The
            // read-only transcript source returns the full
            // bounded history; `deliverTranscript` filters it independently for
            // each observer, so a new observer's replay can never affect an
            // existing observer's delivery.
            let allMessages = await source.allRoomMessages(roomID)
            guard rooms[roomID]?.generation == generation else { return }
            // Also the recovery path after a dropped `.messages` event: only the
            // affected observer is re-sent its evicted IDs.
            deliverTranscript(allMessages, roomID: roomID)
            if !drained.isEmpty {
                // Keep pulling until the mailbox is empty; the next round re-checks the fence.
                rooms[roomID]?.pollRequested = true
            }
        } while rooms[roomID]?.pollRequested == true && rounds < Self.maximumDrainRoundsPerPoll

        guard rooms[roomID]?.generation == generation else { return }
        // Evaluate only after the bounded drain: a trigger emitted mid-drain would race the rest of the burst.
        evaluate(roomID: roomID)
        reofferActiveTriggerIfNeeded(roomID: roomID)
        if rooms[roomID]?.pollRequested == true {
            // Budget spent with work still queued: drain the remainder in a later round.
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
            // Budget exhausted: an unanswered offer must not stay parked in front of
            // the queue; the next idle evaluation mints a fresh trigger and budget.
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
        // Never recreate a room here: a drain that outlived its room must not resurrect it.
        guard var room = rooms[roomID] else { return }
        let signature = participants.map { "\($0.id)|\($0.name)|\($0.isActive)" }
        // An empty first observation is not a change.
        let participantsChanged = room.needsParticipantsReemit
            || (room.participantSignature != signature
                && !(room.participantSignature == nil && signature.isEmpty))
        room.needsParticipantsReemit = false
        room.participantSignature = signature
        if !messages.isEmpty {
            room.pending.append(contentsOf: messages)
            if room.pending.count > Self.maximumPendingMessages {
                room.pending.removeFirst(room.pending.count - Self.maximumPendingMessages)
            }
        }
        rooms[roomID] = room

        if participantsChanged {
            emit(.participantsChanged(participants), roomID: roomID)
        }
        if !messages.isEmpty {
            emitMessages(messages, roomID: roomID)
        }
    }

    /// The single-flight decision. It is deliberately synchronous: no suspension
    /// happens between reading the busy state and publishing a trigger, so two
    /// concurrent callers cannot both decide that the room is idle.
    func evaluate(roomID: String) {
        guard var room = rooms[roomID],
              room.activeTrigger == nil,
              !room.isBusy,
              // A source being rebuilt cannot host a turn; the offer waits for `endReset`.
              !room.isAwaitingSourceRebuild,
              !room.pending.isEmpty,
              // Without a live consumer the batch stays queued.
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

    func requeueActiveTrigger(_ room: inout Room) {
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
    func releaseClaim(_ room: inout Room, _ policy: ClaimRelease) {
        guard let claim = room.claim else { return }
        room.claim = nil
        guard policy == .requeueingUnconsumedBatch, !claim.isConsumed else { return }
        requeue(claim.messages, in: &room)
    }

    /// Returns undelivered messages to the head of the queue. The bound is
    /// enforced from the tail so the oldest live message survives a requeue.
    func requeue(_ messages: [AgentSharedChat.Message], in room: inout Room) {
        guard !messages.isEmpty else { return }
        room.pending.insert(contentsOf: messages, at: 0)
        if room.pending.count > Self.maximumPendingMessages {
            room.pending.removeLast(room.pending.count - Self.maximumPendingMessages)
        }
    }

    static func normalizedRoomID(_ rawValue: String) -> String {
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
