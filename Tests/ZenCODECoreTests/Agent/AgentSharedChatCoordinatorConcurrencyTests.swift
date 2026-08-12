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

    /// The stricter case: the id is reused by a brand new room while the stale
    /// drain is still suspended. Messages drained from the retired runtime must
    /// not surface in the replacement room.
    @Test
    func drainThatOutlivesItsRoomDoesNotIngestIntoAReplacementRoom() async throws {
        let room = Self.makeRoomID()
        let source = TestSharedChatSource()
        await source.enqueue([Self.message("belongs to the retired room", roomID: room)])
        await source.armDrainGate()
        let coordinator = Self.makeCoordinator(source: source)
        let retiredObservation = await coordinator.observeSubscription(roomID: room)

        let poll = Task { await coordinator.poll(roomID: room) }
        await source.waitUntilDrainSuspended()
        await coordinator.stopAll()

        // A new session reuses the id before the stale drain returns.
        let replacement = await coordinator.observeSubscription(roomID: room)
        #expect(await coordinator.isTrackingRoom(roomID: room))

        await source.releaseDrainGate()
        await poll.value

        #expect(await coordinator.pendingMessageCount(roomID: room) == 0)
        #expect(await coordinator.activeAutoTriggerID(roomID: room) == nil)
        #expect(await coordinator.claimedAutoTriggerOwnerID(roomID: room) == nil)

        // The replacement room is fully functional: its own traffic still flows.
        await source.enqueue([Self.message("belongs to the live room", roomID: room)])
        await coordinator.poll(roomID: room)
        let triggerID = try #require(await Self.waitForActiveAutoTriggerID(
            from: coordinator,
            roomID: room
        ))
        #expect(await coordinator.activeAutoTriggerMessageCount(roomID: room) == 1)
        #expect(await coordinator.resolveAutoTrigger(
            id: triggerID,
            observation: replacement,
            resolution: .started
        ) == .acquired)

        await coordinator.stopAll()
        withExtendedLifetime(retiredObservation) {}
    }

    /// A poll suspends twice per round: once on the roster and once on the
    /// mailbox. Only the second suspension is destructive, so the fence has to
    /// sit *between* them. Otherwise a poll that resumed into a reset drains
    /// the mailbox of the backend that replaced it and then throws the batch
    /// away on the late generation check.
    @Test
    func resetBetweenTheRosterAndTheDrainNeverConsumesTheRebuiltMailbox() async throws {
        let room = Self.makeRoomID()
        let source = TestSharedChatSource()
        let coordinator = Self.makeCoordinator(source: source)
        // The room exists without a subscriber, so it has no monitor and every
        // poll in this test is one the test itself drives.
        await coordinator.noteTurnEnded(
            coordinator.noteTurnStarted(roomID: room, prompt: "warm-up")
        )

        await source.armParticipantsGate()
        let poll = Task { await coordinator.poll(roomID: room) }
        await source.waitUntilParticipantsSuspended()

        // The backend is rebuilt while this poll is parked on the roster, and
        // the replacement bus immediately carries traffic of its own.
        await coordinator.reset(roomID: room)
        await source.enqueue([Self.message("belongs to the rebuilt backend", roomID: room)])
        await source.releaseParticipantsGate()
        await poll.value

        // The stale poll never reached the mailbox, so the live generation
        // still owns every message the rebuilt backend produced.
        #expect(await source.drainCallCount == 0)
        #expect(await source.remainingBatchCount == 1)
        #expect(await coordinator.retainedMessageCount(roomID: room) == 0)

        let observation = await coordinator.observeSubscription(roomID: room)
        let trigger = try #require(await Self.waitForActiveAutoTrigger(
            from: coordinator,
            roomID: room
        ))
        #expect(trigger.messages.map(\.text) == ["belongs to the rebuilt backend"])
        #expect(await coordinator.resolveAutoTrigger(
            id: trigger.id,
            observation: observation,
            resolution: .started
        ) == .acquired)

        await coordinator.stopAll()
    }

    /// `rebuildSession` resets the room *before* clearing the backend, so the
    /// retiring bus is still answering in between. A poll woken in that window
    /// must not drain it: those messages die with the clear, and ingesting them
    /// would inject a discarded conversation into the rebuilt session.
    @Test
    func roomStaysFencedBetweenTheResetAndTheBackendClear() async throws {
        let room = Self.makeRoomID()
        let source = TestSharedChatSource()
        await source.enqueue([Self.message("dies with the retired backend", roomID: room)])
        let coordinator = Self.makeCoordinator(source: source)
        await coordinator.noteTurnEnded(
            coordinator.noteTurnStarted(roomID: room, prompt: "warm-up")
        )

        let token = try #require(await coordinator.beginReset(roomID: room))
        #expect(await coordinator.isAwaitingSourceRebuild(roomID: room))

        // The monitor fires between the reset and the clear: it must find the
        // room fenced instead of draining a bus that is about to disappear.
        await coordinator.poll(roomID: room)
        #expect(await source.participantsCallCount == 0)
        #expect(await source.drainCallCount == 0)
        #expect(await source.remainingBatchCount == 1)
        #expect(await coordinator.retainedMessageCount(roomID: room) == 0)

        // The clear destroys the transient bus, then the reset closes over the
        // rebuilt one.
        await source.clearPendingBatches()
        await source.enqueue([Self.message("belongs to the rebuilt backend", roomID: room)])
        await coordinator.endReset(token)
        #expect(await coordinator.isAwaitingSourceRebuild(roomID: room) == false)

        let observation = await coordinator.observeSubscription(roomID: room)
        let trigger = try #require(await Self.waitForActiveAutoTrigger(
            from: coordinator,
            roomID: room
        ))
        // Only post-clear traffic reached the room, and it reached it whole.
        #expect(trigger.messages.map(\.text) == ["belongs to the rebuilt backend"])
        #expect(await coordinator.retainedMessageCount(roomID: room) == 1)
        #expect(await coordinator.resolveAutoTrigger(
            id: trigger.id,
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

    // MARK: - Claim / turn binding

    /// A claim is released by detach, but its batch is only requeued while no
    /// turn is carrying it. Detaching mid-generation used to re-offer messages
    /// the model had already been given.
    @Test
    func detachDuringAClaimedTurnNeitherDuplicatesNorStrandsTheBatch() async throws {
        let room = Self.makeRoomID()
        let source = TestSharedChatSource()
        await source.enqueue([Self.message("claimed batch", roomID: room)])
        let coordinator = Self.makeCoordinator(source: source)
        let claimant = await coordinator.observeSubscription(roomID: room)
        let trigger = try #require(await Self.waitForActiveAutoTrigger(
            from: coordinator,
            roomID: room
        ))
        #expect(await coordinator.resolveAutoTrigger(
            id: trigger.id,
            observation: claimant,
            resolution: .started
        ) == .acquired)

        // The claimant's synthetic prompt reached `sendPrompt`: the batch now
        // lives inside that generation.
        let syntheticTurn = await coordinator.noteTurnStarted(
            roomID: room,
            prompt: trigger.prompt
        )
        #expect(await coordinator.hasConsumedClaim(roomID: room))

        // The consumer disappears while its generation is still running.
        await coordinator.detach(claimant)
        #expect(await coordinator.claimedAutoTriggerOwnerID(roomID: room) == nil)
        #expect(await coordinator.retainedMessageCount(roomID: room) == 0)

        let successor = await coordinator.observeSubscription(roomID: room)
        await coordinator.noteTurnEnded(syntheticTurn)
        await coordinator.poll(roomID: room)
        // The batch was delivered exactly once: nothing is re-offered to the
        // consumer that took the room over.
        #expect(await coordinator.activeAutoTriggerID(roomID: room) == nil)
        #expect(await coordinator.retainedMessageCount(roomID: room) == 0)

        // The other half of the rule still holds: a claim detached *before* its
        // turn starts owes its batch back to the queue.
        await source.enqueue([Self.message("never started", roomID: room)])
        await coordinator.poll(roomID: room)
        let unstarted = try #require(await Self.waitForActiveAutoTrigger(
            from: coordinator,
            roomID: room
        ))
        #expect(await coordinator.resolveAutoTrigger(
            id: unstarted.id,
            observation: successor,
            resolution: .started
        ) == .acquired)
        await coordinator.detach(successor)
        #expect(await coordinator.retainedMessageCount(roomID: room) == 1)

        await coordinator.stopAll()
    }

    /// Turn tracking is room-wide, but a claim belongs to the turn that injects
    /// its prompt. An operator generation ending must not hand the room away
    /// while the claimant is still opening its own.
    @Test
    func anUnrelatedTurnEndingCannotReleaseAnotherObserversClaim() async throws {
        let room = Self.makeRoomID()
        let source = TestSharedChatSource()
        await source.enqueue([Self.message("claimed batch", roomID: room)])
        let coordinator = Self.makeCoordinator(source: source)
        let claimant = await coordinator.observeSubscription(roomID: room)
        let trigger = try #require(await Self.waitForActiveAutoTrigger(
            from: coordinator,
            roomID: room
        ))
        #expect(await coordinator.resolveAutoTrigger(
            id: trigger.id,
            observation: claimant,
            resolution: .started
        ) == .acquired)

        // A prompt that is not this claim's prompt runs and finishes while the
        // claimant is still on its way to `sendPrompt`.
        let unrelatedTurn = await coordinator.noteTurnStarted(
            roomID: room,
            prompt: "an operator prompt of its own"
        )
        #expect(await coordinator.hasConsumedClaim(roomID: room) == false)
        await coordinator.noteTurnEnded(unrelatedTurn)

        // The claim survives with its batch, and no second synthetic turn is
        // authorised behind the claimant's back.
        #expect(await coordinator.claimedAutoTriggerOwnerID(roomID: room) == claimant.id)
        #expect(await coordinator.retainedMessageCount(roomID: room) == 1)
        await coordinator.poll(roomID: room)
        #expect(await coordinator.activeAutoTriggerID(roomID: room) == nil)

        // Only the turn carrying the Core-minted prompt consumes the claim, and
        // only its end releases the room.
        let syntheticTurn = await coordinator.noteTurnStarted(
            roomID: room,
            prompt: trigger.prompt
        )
        #expect(await coordinator.hasConsumedClaim(roomID: room))
        await coordinator.noteTurnEnded(syntheticTurn)
        #expect(await coordinator.claimedAutoTriggerOwnerID(roomID: room) == nil)
        #expect(await coordinator.turnsInFlight(roomID: room) == 0)
        // Released, not requeued: those messages went out with the generation.
        #expect(await coordinator.retainedMessageCount(roomID: room) == 0)

        await coordinator.stopAll()
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

    /// An offer nobody can answer must not stay parked in front of the queue.
    /// Once the re-offer budget is spent the batch returns to `pending` and a
    /// fresh trigger is minted, so an overflowed consumer cannot stall the room
    /// permanently.
    @Test
    func exhaustedReofferBudgetReturnsTheOfferInsteadOfStrandingIt() async throws {
        let room = Self.makeRoomID()
        let source = TestSharedChatSource()
        let producedMessages = AgentSharedChatCoordinator.maximumBufferedEventsPerSubscriber + 40
        for index in 0 ..< producedMessages {
            await source.enqueue([Self.message("overflow \(index)", roomID: room)])
        }
        let coordinator = Self.makeCoordinator(source: source)
        // Deliberately never consumed: a stalled rendering surface. Its stream
        // must stay attached, otherwise the room would simply lose its only
        // observer and never emit at all.
        let stalled = await coordinator.observeSubscription(roomID: room)

        var polls = 0
        while await coordinator.droppedEventCount(roomID: room) == 0, polls < 4 * producedMessages {
            await coordinator.poll(roomID: room)
            polls += 1
        }
        #expect(await coordinator.droppedEventCount(roomID: room) > 0)

        // Drain what the producer had left, so the accounting below cannot be
        // moved by a later round.
        while await source.remainingBatchCount > 0 {
            await coordinator.poll(roomID: room)
        }
        let strandedID = try #require(await coordinator.activeAutoTriggerID(roomID: room))
        let retainedBefore = await coordinator.retainedMessageCount(roomID: room)

        var currentID = strandedID
        // The room has an attached (stalled) observer, so its monitor polls
        // too and one of these explicit polls can coalesce with a drain that is
        // already in flight. That is normal single-flight behaviour, not a
        // missed re-offer: allow for it by yielding to the monitor between
        // rounds and by bounding the loop on the budget rather than on an exact
        // poll count. The property under test is unchanged — a spent budget
        // must retire the offer after a *bounded* number of rounds.
        for _ in 0 ..< (4 * (AgentSharedChatCoordinator.maximumAutoTriggerReoffers + 2)) {
            await coordinator.poll(roomID: room)
            currentID = await coordinator.activeAutoTriggerID(roomID: room) ?? currentID
            if currentID != strandedID { break }
            await Task.yield()
        }
        #expect(currentID != strandedID, "a spent re-offer budget must not strand the batch")

        // Liveness did not cost a message: the retired offer went back to the
        // queue and the fresh one was minted from it.
        #expect(await coordinator.retainedMessageCount(roomID: room) == retainedBefore)

        await coordinator.stopAll()
        withExtendedLifetime(stalled) {}
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
    private var isParticipantsGateArmed = false
    private var isParticipantsSuspended = false
    private var participantsEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var participantsReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    var remainingBatchCount: Int {
        batches.count
    }

    func enqueue(_ messages: [AgentSharedChat.Message]) {
        batches.append(messages)
    }

    /// Models the backend clear: the transient bus dies with the session that
    /// owned it, so whatever it still held is gone.
    func clearPendingBatches() {
        batches.removeAll()
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

    /// Suspends the next roster lookup, which is the poll's *first* suspension
    /// point and the one that precedes the destructive drain.
    func armParticipantsGate() {
        isParticipantsGateArmed = true
    }

    func waitUntilParticipantsSuspended() async {
        guard !isParticipantsSuspended else { return }
        await withCheckedContinuation { continuation in
            participantsEntryWaiters.append(continuation)
        }
    }

    func releaseParticipantsGate() {
        isParticipantsGateArmed = false
        isParticipantsSuspended = false
        let waiters = participantsReleaseWaiters
        participantsReleaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func participants() async -> [AgentSharedChat.Participant] {
        participantsCallCount += 1
        guard isParticipantsGateArmed else { return [] }
        isParticipantsGateArmed = false
        isParticipantsSuspended = true
        let waiters = participantsEntryWaiters
        participantsEntryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            participantsReleaseWaiters.append(continuation)
        }
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
