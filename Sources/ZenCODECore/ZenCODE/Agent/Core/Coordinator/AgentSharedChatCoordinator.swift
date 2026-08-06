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
/// active-trigger check and its removal one atomic operation, so exactly one
/// observer can acquire a given trigger.
public enum AgentSharedChatAutoTriggerClaimResult: Sendable, Equatable {
    /// This consumer atomically acquired the active trigger and owns its turn.
    case acquired
    /// The trigger was stale, belonged to another room, or was acquired by a
    /// different observer. It must be treated as a no-op.
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
/// * declining, stopping or resetting re-queues the batch instead of losing it;
/// * no persistence: the transcript stays transient and `SessionTaskOrchestrator`
///   remains the only owner of durable task state.
public actor AgentSharedChatCoordinator {
    /// Backend access is injected so the coordinator never retains the runner
    /// (no reference cycle) and can be unit-tested without a model backend.
    public struct Source: Sendable {
        public let drainCoordinatorMessages: @Sendable (String) async -> [AgentSharedChat.Message]
        public let participants: @Sendable (String) async -> [AgentSharedChat.Participant]

        public init(
            drainCoordinatorMessages: @escaping @Sendable (String) async -> [AgentSharedChat.Message],
            participants: @escaping @Sendable (String) async -> [AgentSharedChat.Participant]
        ) {
            self.drainCoordinatorMessages = drainCoordinatorMessages
            self.participants = participants
        }
    }

    /// Upper bound for messages parked outside a mailbox. It matches the room
    /// transcript bound, so a stalled consumer cannot grow memory without limit.
    static let maximumPendingMessages = AgentSharedChat.maximumRetainedMessagesPerRoom

    private struct Room {
        var pending: [AgentSharedChat.Message] = []
        var activeTrigger: AgentSharedChatAutoTrigger?
        /// Turns observed by the Core itself (`AgentCoreSessionRunner.sendPrompt`).
        var turnsInFlight = 0
        /// Busy state declared by the consumer, covering the window between a
        /// queued prompt and its actual turn start.
        var consumerBusy = false
        /// Set when `resolveAutoTrigger(.started)` claimed the busy state on the
        /// consumer's behalf. It is released automatically when the resulting
        /// turn ends, so a consumer that never reports back cannot stall the
        /// room forever. Any explicit `setConsumerBusy` hands ownership back.
        var autoTriggerBusyLatch = false
        var participantSignature: [String]?
        var subscribers: [UUID: AsyncStream<AgentSharedChatCoordinatorEvent>.Continuation] = [:]
        var monitorTask: Task<Void, Never>?
        var tickerTask: Task<Void, Never>?
        var signal: AsyncStream<Void>.Continuation?
        /// Single-flight guard around the asynchronous drain itself.
        var isPolling = false
        var pollRequested = false

        var isBusy: Bool {
            turnsInFlight > 0 || consumerBusy
        }
    }

    private let source: Source
    private let pollInterval: Duration
    private var rooms: [String: Room] = [:]

    public init(
        source: Source,
        pollInterval: Duration = .milliseconds(120)
    ) {
        self.source = source
        self.pollInterval = pollInterval
    }

    // MARK: - Observation

    /// Subscribes to live coordination events and starts the monitor if needed.
    ///
    /// Any number of consumers may observe the same room; the monitor, the drain
    /// and the auto-trigger decision stay owned here, so no subscriber becomes
    /// the semantic owner of the auto-trigger.
    public func observe(roomID rawRoomID: String) -> AsyncStream<AgentSharedChatCoordinatorEvent> {
        let roomID = Self.normalizedRoomID(rawRoomID)
        let subscriberID = UUID()
        let (stream, continuation) = AsyncStream<AgentSharedChatCoordinatorEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        continuation.onTermination = { [weak self] _ in
            Task(name: "ZenCODE.shared-chat.unsubscribe") { [weak self] in
                await self?.removeSubscriber(subscriberID, roomID: roomID)
            }
        }
        var room = rooms[roomID] ?? Room()
        room.subscribers[subscriberID] = continuation
        rooms[roomID] = room

        // A consumer that attaches after a close/reset must still see whatever
        // never reached a synthetic turn, so replay the parked batch.
        if !room.pending.isEmpty {
            continuation.yield(.messages(room.pending))
        }
        startMonitorIfNeeded(roomID: roomID)
        evaluate(roomID: roomID)
        requestPoll(roomID: roomID)
        return stream
    }

    /// Stops monitoring a room and terminates its subscriptions (close path).
    /// Undelivered work is preserved: an unresolved batch returns to `pending`.
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
        let subscribers = room.subscribers
        room.subscribers.removeAll()
        room.consumerBusy = false
        room.autoTriggerBusyLatch = false
        rooms[roomID] = room
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    /// Backend reset: the transient bus may be rebuilt underneath, so release an
    /// unresolved batch back into the queue while keeping the monitor and every
    /// live subscription attached.
    public func reset(roomID rawRoomID: String) {
        let roomID = Self.normalizedRoomID(rawRoomID)
        guard var room = rooms[roomID] else { return }
        requeueActiveTrigger(&room)
        room.consumerBusy = false
        room.autoTriggerBusyLatch = false
        rooms[roomID] = room
        evaluate(roomID: roomID)
    }

    /// Full teardown. Rooms and their parked messages are dropped because the
    /// runtime tree that produced them no longer exists.
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
    public func setConsumerBusy(_ isBusy: Bool, roomID rawRoomID: String) {
        let roomID = Self.normalizedRoomID(rawRoomID)
        var room = rooms[roomID] ?? Room()
        room.consumerBusy = isBusy
        // The consumer now governs its own busy state explicitly.
        room.autoTriggerBusyLatch = false
        rooms[roomID] = room
        if !isBusy {
            evaluate(roomID: roomID)
            requestPoll(roomID: roomID)
        }
    }

    /// Called by the session runner around every prompt, including operator and
    /// synthetic turns, so busy detection does not depend on consumer honesty.
    func noteTurnStarted(roomID rawRoomID: String) {
        let roomID = Self.normalizedRoomID(rawRoomID)
        var room = rooms[roomID] ?? Room()
        room.turnsInFlight += 1
        rooms[roomID] = room
    }

    func noteTurnEnded(roomID rawRoomID: String) {
        let roomID = Self.normalizedRoomID(rawRoomID)
        guard var room = rooms[roomID] else { return }
        room.turnsInFlight = max(0, room.turnsInFlight - 1)
        if room.turnsInFlight == 0, room.autoTriggerBusyLatch {
            room.autoTriggerBusyLatch = false
            room.consumerBusy = false
        }
        rooms[roomID] = room
        guard room.turnsInFlight == 0 else { return }
        evaluate(roomID: roomID)
        requestPoll(roomID: roomID)
    }

    // MARK: - Auto-trigger resolution

    /// Answers an emitted trigger. Resolving `started` atomically claims its
    /// active entry: only the caller that receives ``AgentSharedChatAutoTriggerClaimResult/acquired``
    /// may start the synthetic generation. A stale `started` response is a
    /// no-op. `declined` re-queues an active batch for a later turn and never
    /// claims it.
    @discardableResult
    public func resolveAutoTrigger(
        id: UUID,
        roomID rawRoomID: String,
        resolution: AgentSharedChatAutoTriggerResolution
    ) -> AgentSharedChatAutoTriggerClaimResult {
        let roomID = Self.normalizedRoomID(rawRoomID)
        guard var room = rooms[roomID], room.activeTrigger?.id == id else {
            return .notAcquired
        }
        switch resolution {
        case .started:
            room.activeTrigger = nil
            // The consumer owns a turn now. Marking the room busy here closes
            // the window between this acknowledgement and the moment its
            // prompt actually reaches `sendPrompt`.
            room.consumerBusy = true
            room.autoTriggerBusyLatch = true
            rooms[roomID] = room
            return .acquired
        case .declined:
            requeueActiveTrigger(&room)
            rooms[roomID] = room
            evaluate(roomID: roomID)
            return .notAcquired
        }
    }

    // MARK: - Introspection (diagnostics and tests)

    func pendingMessageCount(roomID rawRoomID: String) -> Int {
        rooms[Self.normalizedRoomID(rawRoomID)]?.pending.count ?? 0
    }

    func activeAutoTriggerID(roomID rawRoomID: String) -> UUID? {
        rooms[Self.normalizedRoomID(rawRoomID)]?.activeTrigger?.id
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

    /// Wakes the monitor immediately instead of waiting for the next tick.
    public func requestPoll(roomID rawRoomID: String) {
        let roomID = Self.normalizedRoomID(rawRoomID)
        rooms[roomID]?.signal?.yield()
    }

    /// Performs one drain/evaluate cycle. Exposed for deterministic tests; the
    /// production monitor calls exactly the same body.
    func poll(roomID rawRoomID: String) async {
        let roomID = Self.normalizedRoomID(rawRoomID)
        guard rooms[roomID] != nil else { return }
        guard rooms[roomID]?.isPolling != true else {
            // A drain is already suspended on the backend; coalesce instead of
            // starting a second one that could double-emit a trigger.
            rooms[roomID]?.pollRequested = true
            return
        }
        rooms[roomID]?.isPolling = true
        defer { rooms[roomID]?.isPolling = false }

        repeat {
            rooms[roomID]?.pollRequested = false
            let participants = await source.participants(roomID)
            let messages = await source.drainCoordinatorMessages(roomID)
            // The room dictionary entry survives `stop`, so messages drained
            // across a teardown are parked instead of dropped.
            ingest(participants: participants, messages: messages, roomID: roomID)
            if !messages.isEmpty {
                // A mailbox drain is bounded per call; keep pulling until the
                // mailbox is empty so a burst is never left behind.
                rooms[roomID]?.pollRequested = true
            }
        } while rooms[roomID]?.pollRequested == true
    }

    // MARK: - Internals

    private func ingest(
        participants: [AgentSharedChat.Participant],
        messages: [AgentSharedChat.Message],
        roomID: String
    ) {
        var room = rooms[roomID] ?? Room()
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
        rooms[roomID] = room
        emit(.autoTrigger(trigger), roomID: roomID)
    }

    private func requeueActiveTrigger(_ room: inout Room) {
        guard let trigger = room.activeTrigger else { return }
        room.activeTrigger = nil
        room.pending.insert(contentsOf: trigger.messages, at: 0)
        if room.pending.count > Self.maximumPendingMessages {
            room.pending.removeLast(room.pending.count - Self.maximumPendingMessages)
        }
    }

    private func emit(_ event: AgentSharedChatCoordinatorEvent, roomID: String) {
        guard let room = rooms[roomID] else { return }
        for continuation in room.subscribers.values {
            continuation.yield(event)
        }
    }

    private func removeSubscriber(_ id: UUID, roomID: String) {
        guard var room = rooms[roomID] else { return }
        room.subscribers.removeValue(forKey: id)
        if room.subscribers.isEmpty {
            // Nobody can run a synthetic turn anymore: release the batch so it
            // is re-offered to the next consumer instead of being lost.
            requeueActiveTrigger(&room)
            room.monitorTask?.cancel()
            room.monitorTask = nil
            room.tickerTask?.cancel()
            room.tickerTask = nil
            room.signal?.finish()
            room.signal = nil
            room.consumerBusy = false
            room.autoTriggerBusyLatch = false
        }
        rooms[roomID] = room
    }

    private static func normalizedRoomID(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "default"
            : rawValue
    }

    /// Core-owned prompt text for a synthetic coordinator turn, shared by every
    /// consumer so terminal and headless drivers inject identical content.
    public static func coordinatorPrompt(
        for messages: [AgentSharedChat.Message]
    ) -> String {
        let body = messages
            .map { "@\($0.sender.name): \($0.text)" }
            .joined(separator: "\n")
        return """
        [Live shared-chat messages from delegated agents]
        \(body)

        Reply to these messages and coordinate the active work. Do not claim that this transient message bus is persisted.
        """
    }
}
