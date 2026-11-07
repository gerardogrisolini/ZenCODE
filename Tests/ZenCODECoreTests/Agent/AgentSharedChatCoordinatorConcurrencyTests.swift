//
//  AgentSharedChatCoordinatorConcurrencyTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

/// Interleaving, lifecycle and API-compatibility coverage for the Core
/// auto-trigger.
///
/// Everything here is driven by a scripted source instead of a live bus, so a
/// race is reproduced by controlling *when* a drain returns rather than by
/// hoping for a timing window: the drain gate suspends inside the coordinator's
/// own suspension point, which is exactly where teardown used to slip through.
@Suite(.timeLimit(.minutes(1)))
struct AgentSharedChatCoordinatorConcurrencyTests {
    // MARK: - Offer / busy / claim atomicity

    /// The offer is published while the room is idle, but the acknowledgement
    /// travels through the consumer's own queue. A Core turn that starts in
    /// that window must win: claiming afterwards would open a second concurrent
    /// generation.
    @Test
    func claimIsDeniedWhenACoreTurnStartsBetweenTheOfferAndTheAcknowledgement() async throws {
        let room = Self.makeRoomID()
        let source = TestSharedChatSource()
        await source.enqueue([Self.message("status ready", roomID: room)])
        let coordinator = Self.makeCoordinator(source: source)
        let subscription = await coordinator.observeSubscription(roomID: room)

        await coordinator.poll(roomID: room)
        let triggerID = try #require(await coordinator.activeAutoTriggerID(roomID: room))

        // The operator's prompt reached `sendPrompt` first.
        let operatorTurn = await coordinator.noteTurnStarted(
            roomID: room,
            prompt: "an operator prompt"
        )

        let claim = await coordinator.resolveAutoTrigger(
            id: triggerID,
            observation: subscription,
            resolution: .started
        )
        #expect(claim == .notAcquired)
        #expect(await coordinator.claimedAutoTriggerOwnerID(roomID: room) == nil)
        // The batch is not consumed by the denied claim.
        #expect(await coordinator.activeAutoTriggerID(roomID: room) == nil)
        #expect(await coordinator.pendingMessageCount(roomID: room) == 1)

        // When the operator turn ends the same batch is offered again.
        await coordinator.noteTurnEnded(operatorTurn)
        let reofferedID = try #require(await coordinator.activeAutoTriggerID(roomID: room))
        #expect(reofferedID != triggerID)
        #expect(await coordinator.activeAutoTriggerMessageCount(roomID: room) == 1)
        #expect(await coordinator.resolveAutoTrigger(
            id: reofferedID,
            observation: subscription,
            resolution: .started
        ) == .acquired)

        await coordinator.stopAll()
    }

    /// The same window, closed by another observer instead of by the Core: a
    /// second consumer declaring itself busy must also invalidate a late claim.
    @Test
    func claimIsDeniedWhileAnotherObserverDeclaredItselfBusy() async throws {
        let room = Self.makeRoomID()
        let source = TestSharedChatSource()
        await source.enqueue([Self.message("needs a turn", roomID: room)])
        let coordinator = Self.makeCoordinator(source: source)
        let claimant = await coordinator.observeSubscription(roomID: room)
        let other = await coordinator.observeSubscription(roomID: room)

        await coordinator.poll(roomID: room)
        let triggerID = try #require(await coordinator.activeAutoTriggerID(roomID: room))

        await coordinator.setConsumerBusy(true, observation: other)
        #expect(await coordinator.resolveAutoTrigger(
            id: triggerID,
            observation: claimant,
            resolution: .started
        ) == .notAcquired)
        #expect(await coordinator.claimedAutoTriggerOwnerID(roomID: room) == nil)
        #expect(await coordinator.pendingMessageCount(roomID: room) == 1)

        // The room becomes genuinely idle: the preserved batch is offered again
        // and this time the claim is granted.
        await coordinator.setConsumerBusy(false, observation: other)
        let reofferedID = try #require(await coordinator.activeAutoTriggerID(roomID: room))
        #expect(await coordinator.resolveAutoTrigger(
            id: reofferedID,
            observation: claimant,
            resolution: .started
        ) == .acquired)
        #expect(await coordinator.claimedAutoTriggerOwnerID(roomID: room) == claimant.id)

        await coordinator.stopAll()
    }

    // MARK: - Generation fence

    /// A drain suspended on the backend outlives `stopAll`. Its result must die
    /// with the room instead of recreating an entry the runtime tree no longer
    /// owns.
    @Test
    func drainThatOutlivesStopAllCannotRecreateTheRoom() async throws {
        let room = Self.makeRoomID()
        let source = TestSharedChatSource()
        await source.enqueue([Self.message("drained across teardown", roomID: room)])
        await source.armDrainGate()
        let coordinator = Self.makeCoordinator(source: source)
        let observation = await coordinator.observeSubscription(roomID: room)

        let poll = Task { await coordinator.poll(roomID: room) }
        await source.waitUntilDrainSuspended()

        await coordinator.stopAll()
        #expect(await coordinator.isTrackingRoom(roomID: room) == false)

        await source.releaseDrainGate()
        await poll.value

        // The late drain neither resurrected the room nor parked its batch.
        #expect(await coordinator.isTrackingRoom(roomID: room) == false)
        #expect(await coordinator.pendingMessageCount(roomID: room) == 0)
        #expect(await coordinator.activeAutoTriggerID(roomID: room) == nil)
        // The subscription is kept alive on purpose: releasing its stream would
        // detach the observer and change what the room does under teardown.
        withExtendedLifetime(observation) {}
    }

    /// A reset keeps the observer and monitor alive, but it swaps the backend
    /// generation underneath them. A drain that already took a batch from the
    /// retired backend must not inject it after the reset completes.
    @Test
    func drainThatOutlivesResetCannotIngestFromTheRetiredBackend() async throws {
        let room = Self.makeRoomID()
        let source = TestSharedChatSource()
        await source.enqueue([Self.message("belongs to the retired backend", roomID: room)])
        await source.armDrainGate()
        let coordinator = Self.makeCoordinator(source: source)
        let observation = await coordinator.observeSubscription(roomID: room)

        let poll = Task { await coordinator.poll(roomID: room) }
        await source.waitUntilDrainSuspended()

        await coordinator.reset(roomID: room)
        await source.releaseDrainGate()
        await poll.value

        // The room and its observer survive reset, but no data from the old
        // drain was accepted into the replacement generation.
        #expect(await coordinator.isTrackingRoom(roomID: room))
        #expect(await coordinator.pendingMessageCount(roomID: room) == 0)
        #expect(await coordinator.activeAutoTriggerID(roomID: room) == nil)

        // New-backend traffic remains functional after the fence.
        await source.enqueue([Self.message("belongs to the rebuilt backend", roomID: room)])
        await coordinator.poll(roomID: room)
        let triggerID = try #require(await Self.waitForActiveAutoTriggerID(
            from: coordinator,
            roomID: room
        ))
        #expect(await coordinator.resolveAutoTrigger(
            id: triggerID,
            observation: observation,
            resolution: .started
        ) == .acquired)

        await coordinator.stopAll()
    }

    /// `stop` keeps the room entry precisely so a drain it interrupted has
    /// somewhere to park. Re-attaching must then resume coordination for that
    /// same batch — offered once, not once per attach.
    @Test
    func stopWhileDrainingParksTheBatchAndAReattachOffersItExactlyOnce() async throws {
        let room = Self.makeRoomID()
        let source = TestSharedChatSource()
        await source.enqueue([Self.message("drained across the stop", roomID: room)])
        await source.armDrainGate()
        let coordinator = Self.makeCoordinator(source: source)
        // Attaching wakes the monitor, which is what parks a drain here.
        let stopped = await coordinator.observeSubscription(roomID: room)
        await source.waitUntilDrainSuspended()

        await coordinator.stop(roomID: room)
        #expect(await coordinator.isMonitoring(roomID: room) == false)
        await source.releaseDrainGate()

        // The batch the backend had already handed over is parked, not lost,
        // and a room with no observers mints no offer for it.
        #expect(await Self.waitUntil {
            await coordinator.pendingMessageCount(roomID: room) == 1
        })
        #expect(await coordinator.isTrackingRoom(roomID: room))
        #expect(await coordinator.activeAutoTriggerID(roomID: room) == nil)

        let reattached = await coordinator.observeSubscription(roomID: room)
        #expect(await coordinator.isMonitoring(roomID: room))
        let trigger = try #require(await Self.waitForActiveAutoTrigger(
            from: coordinator,
            roomID: room
        ))
        #expect(trigger.messages.map(\.text) == ["drained across the stop"])

        // Repeated polls after the reattach neither duplicate the batch nor
        // mint a competing offer for it.
        for _ in 0 ..< 3 {
            await coordinator.poll(roomID: room)
        }
        #expect(await coordinator.activeAutoTriggerID(roomID: room) == trigger.id)
        #expect(await coordinator.retainedMessageCount(roomID: room) == 1)
        #expect(await coordinator.resolveAutoTrigger(
            id: trigger.id,
            observation: reattached,
            resolution: .started
        ) == .acquired)

        await coordinator.stopAll()
        withExtendedLifetime(stopped) {}
    }

    // MARK: - Poll fairness

    /// A producer that refills the mailbox on every drain must not own the poll
    /// loop: one poll performs a bounded number of rounds and hands the rest
    /// back to the monitor.
    @Test
    func hotProducerCannotHoldOnePollForever() async throws {
        let room = Self.makeRoomID()
        let source = TestSharedChatSource()
        // 40 single-message batches: far more than one poll may drain.
        for index in 0 ..< 40 {
            await source.enqueue([Self.message("burst \(index)", roomID: room)])
        }
        let coordinator = Self.makeCoordinator(source: source)
        // A room without subscribers still drains, and it has no monitor, so
        // the round count observed here belongs to this poll alone.
        let idleTurn = await coordinator.noteTurnStarted(roomID: room, prompt: "warm-up")
        await coordinator.noteTurnEnded(idleTurn)

        await coordinator.poll(roomID: room)
        // Bounded rounds, not "until the producer gives up": the rest of the
        // burst is handed back to the monitor instead of being drained in one
        // uninterruptible run that would also starve the re-offer step.
        #expect(await source.drainCallCount == AgentSharedChatCoordinator.maximumDrainRoundsPerPoll)
        #expect(
            await coordinator.pendingMessageCount(roomID: room)
                == AgentSharedChatCoordinator.maximumDrainRoundsPerPoll
        )

        // Nothing is lost: the next poll continues where this one stopped.
        await coordinator.poll(roomID: room)
        #expect(
            await coordinator.pendingMessageCount(roomID: room)
                == 2 * AgentSharedChatCoordinator.maximumDrainRoundsPerPoll
        )

        await coordinator.stopAll()
    }

    // MARK: - Helpers

    private static func waitForActiveAutoTriggerID(
        from coordinator: AgentSharedChatCoordinator,
        roomID: String
    ) async -> UUID? {
        await waitForActiveAutoTrigger(
            from: coordinator,
            roomID: roomID
        )?.id
    }

    /// The offer itself, because a consumer binds its turn to the claim by
    /// injecting exactly the prompt the Core minted for that batch.
    private static func waitForActiveAutoTrigger(
        from coordinator: AgentSharedChatCoordinator,
        roomID: String
    ) async -> AgentSharedChatAutoTrigger? {
        while true {
            if let trigger = await coordinator.activeAutoTrigger(roomID: roomID) {
                return trigger
            }
            await Task.yield()
        }
    }

    /// A room with observers runs its own monitor, so an explicit `poll` may
    /// coalesce with a drain that is already in flight. Wait for the state edge
    /// rather than treating a five-second deadline as successful synchronization.
    private static func waitUntil(
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        while !(await condition()) {
            await Task.yield()
        }
        return true
    }

    private static func makeRoomID() -> String {
        "room-\(UUID().uuidString)"
    }

    private static func makeCoordinator(
        source: TestSharedChatSource
    ) -> AgentSharedChatCoordinator {
        AgentSharedChatCoordinator(
            source: AgentSharedChatCoordinator.Source(
                drainCoordinatorMessages: { _ in await source.drain() },
                participants: { _ in await source.participants() },
                allRoomMessages: { _ in [] }
            ),
            // Long enough that the ticker never interferes: every test drives
            // `poll` explicitly.
            pollInterval: .seconds(600)
        )
    }

    private static func message(
        _ text: String,
        roomID: String
    ) -> AgentSharedChat.Message {
        AgentSharedChat.Message(
            roomID: roomID,
            sender: AgentSharedChat.Participant(
                id: "agent-1",
                name: "planner",
                kind: .agent
            ),
            recipientIDs: ["coordinator:\(roomID)"],
            text: text
        )
    }
}

/// Scripted drain source with a one-shot gate.
///
/// The gate takes its batch *before* suspending, which models the real hazard:
/// the backend already handed the messages over and only the return trip is
/// still in flight when the room is torn down.
private actor TestSharedChatSource {
    private var batches: [[AgentSharedChat.Message]] = []
    private(set) var drainCallCount = 0
    private(set) var participantsCallCount = 0
    private var isDrainGateArmed = false
    private var isDrainSuspended = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var remainingBatchCount: Int {
        batches.count
    }

    func enqueue(_ messages: [AgentSharedChat.Message]) {
        batches.append(messages)
    }

    /// Suspends the next drain until ``releaseDrainGate()``.
    func armDrainGate() {
        isDrainGateArmed = true
    }

    func waitUntilDrainSuspended() async {
        guard !isDrainSuspended else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func releaseDrainGate() {
        isDrainGateArmed = false
        isDrainSuspended = false
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func participants() async -> [AgentSharedChat.Participant] {
        participantsCallCount += 1
        return []
    }

    func drain() async -> [AgentSharedChat.Message] {
        drainCallCount += 1
        let batch = batches.isEmpty ? [] : batches.removeFirst()
        guard isDrainGateArmed else {
            return batch
        }
        isDrainGateArmed = false
        isDrainSuspended = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return batch
    }
}
