//
//  AgentSharedChatCoordinatorTests+Observers.swift
//  ZenCODE
//
//  Tests for multi-observer ownership, bounded transcript replay and observer
//  detachment in AgentSharedChatCoordinator.
//

import Foundation
@testable import ZenCODECore
import Testing

extension AgentSharedChatCoordinatorTests {
    // MARK: - Multi-observer ownership

    /// A claimed turn belongs to the observer that acquired it. Nobody else can
    /// take it, return it, or make the room look idle while it runs.
    @Test
    func claimedTurnIsOwnerBoundAndSurvivesAnotherObserverIdleReport() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: room, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .seconds(60))
        let ownerSubscription = await coordinator.observeSubscription(roomID: room)
        let otherSubscription = await coordinator.observeSubscription(roomID: room)
        let owner = await Observation.make(stream: ownerSubscription.events)
        let other = await Observation.make(stream: otherSubscription.events)

        try await chat.send(
            roomID: room,
            senderID: "planner",
            destination: .coordinator,
            text: "first"
        )
        await coordinator.poll(roomID: room)
        let offered = await owner.wait(untilAtLeast: 1) { $0.contains { $0.autoTrigger != nil } }
        let trigger = try #require(offered.compactMap(\.autoTrigger).first)

        #expect(await coordinator.resolveAutoTrigger(
            id: trigger.id,
            observation: ownerSubscription,
            resolution: .started
        ) == .acquired)
        #expect(await coordinator.claimedAutoTriggerOwnerID(roomID: room) == ownerSubscription.id)

        // The other observer answers the same broadcast: neither acquiring nor
        // declining nor reporting idle may touch the claim.
        #expect(await coordinator.resolveAutoTrigger(
            id: trigger.id,
            observation: otherSubscription,
            resolution: .started
        ) == .notAcquired)
        await coordinator.resolveAutoTrigger(
            id: trigger.id,
            observation: otherSubscription,
            resolution: .declined
        )
        await coordinator.setConsumerBusy(false, observation: otherSubscription)
        await coordinator.declineAutoTrigger(id: trigger.id, roomID: room)
        #expect(await coordinator.claimedAutoTriggerOwnerID(roomID: room) == ownerSubscription.id)

        // A message arriving during the claimed turn queues instead of racing.
        try await chat.send(
            roomID: room,
            senderID: "planner",
            destination: .coordinator,
            text: "second"
        )
        await coordinator.poll(roomID: room)
        // The room's monitor polls as well, so this explicit call may coalesce
        // with a drain that is already in flight. Wait for the queued message
        // instead of assuming this call is the one that drained it.
        #expect(await waitUntil {
            await coordinator.pendingMessageCount(roomID: room) == 1
        })
        #expect(await owner.snapshot().compactMap(\.autoTrigger).count == 1)
        #expect(await other.snapshot().compactMap(\.autoTrigger).count == 1)

        // The owner detaches without finishing: its batch is requeued at the
        // head and re-offered to the observer that is still live.
        await coordinator.detach(ownerSubscription)
        #expect(await owner.waitUntilFinished())
        #expect(await coordinator.claimedAutoTriggerOwnerID(roomID: room) == nil)
        let events = await other.wait(untilAtLeast: 2) { $0.compactMap(\.autoTrigger).count >= 2 }
        let triggers = events.compactMap(\.autoTrigger)
        #expect(triggers.count == 2)
        #expect(triggers[1].id != trigger.id)
        #expect(triggers[1].messages.map(\.text) == ["first", "second"])
        await other.cancel()
        await coordinator.stopAll()
    }

    /// Two observers answering the same broadcast concurrently: exactly one
    /// claim is granted and the room records that single owner.
    @Test
    func twoObserversRacingOneTriggerProduceExactlyOneOwner() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: room, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .seconds(60))
        let firstSubscription = await coordinator.observeSubscription(roomID: room)
        let secondSubscription = await coordinator.observeSubscription(roomID: room)
        let first = await Observation.make(stream: firstSubscription.events)
        let second = await Observation.make(stream: secondSubscription.events)

        try await chat.send(
            roomID: room,
            senderID: "planner",
            destination: .coordinator,
            text: "race me"
        )
        await coordinator.poll(roomID: room)
        let firstEvents = await first.wait(untilAtLeast: 1) { $0.contains { $0.autoTrigger != nil } }
        let secondEvents = await second.wait(untilAtLeast: 1) { $0.contains { $0.autoTrigger != nil } }
        let trigger = try #require(firstEvents.compactMap(\.autoTrigger).first)
        #expect(secondEvents.compactMap(\.autoTrigger).first == trigger)

        async let firstClaim = coordinator.resolveAutoTrigger(
            id: trigger.id,
            observation: firstSubscription,
            resolution: .started
        )
        async let secondClaim = coordinator.resolveAutoTrigger(
            id: trigger.id,
            observation: secondSubscription,
            resolution: .started
        )
        let claims = await [firstClaim, secondClaim]
        #expect(claims.filter { $0 == .acquired }.count == 1)

        let ownerID = await coordinator.claimedAutoTriggerOwnerID(roomID: room)
        let expectedOwnerID = claims[0] == .acquired
            ? firstSubscription.id
            : secondSubscription.id
        #expect(ownerID == expectedOwnerID)
        #expect(await coordinator.activeAutoTrigger(roomID: room)?.id == nil)
        await first.cancel()
        await second.cancel()
        await coordinator.stopAll()
    }

    // MARK: - Bounded replay

    /// A consumer that attaches after agent-to-agent traffic already flowed
    /// through the room still sees every retained message: the bounded
    /// transcript is replayed to each new observer, so the blue box reaches
    /// every active terminal within the transcript bound. The Core ledger keeps
    /// raw `.messages` delivery per observer exactly once even if its replay and
    /// a poll interleave.
    @Test
    func lateObserverReceivesBoundedTranscriptReplay() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: room, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .seconds(60))
        let firstSubscription = await coordinator.observeSubscription(roomID: room)
        let first = await Observation.make(stream: firstSubscription.events)

        // Publish a burst of agent-to-coordinator messages and drain them into
        // the coordinator queue so they leave the mailbox but stay in the
        // bounded transcript.
        let count = AgentSharedChat.maximumMessagesPerInjectedPrompt + 2
        for index in 0 ..< count {
            try await chat.send(
                roomID: room,
                senderID: "planner",
                destination: .coordinator,
                text: "replay \(index)"
            )
        }
        await coordinator.poll(roomID: room)
        let transcript = await chat.messages(roomID: room)
        let transcriptIDs = Set(transcript.map(\.id))
        // The first observer establishes that the entire burst was emitted
        // before the late subscription is created, rather than merely seeing
        // whichever first batch the scheduler happened to forward.
        _ = await first.wait(untilAtLeast: 1) {
            Set($0.compactMap(\.renderedMessages).flatMap { $0 }.map(\.id)) == transcriptIDs
        }

        // A late observer attaches after the burst was already emitted. It must
        // receive a replay of the bounded transcript, not an empty stream.
        let lateSubscription = await coordinator.observeSubscription(roomID: room)
        let late = await Observation.make(stream: lateSubscription.events)
        let replayed = await late.wait(untilAtLeast: 1) {
            Set($0.compactMap(\.renderedMessages).flatMap { $0 }.map(\.id)) == transcriptIDs
        }
        let replayedTexts = replayed.compactMap(\.renderedMessages).flatMap { $0 }.map(\.text)
        // The transcript is bounded: every retained message is replayed.
        let transcriptTexts = transcript.map(\.text)
        #expect(Set(replayedTexts) == Set(transcriptTexts))
        #expect(transcriptTexts.contains("replay 0"))
        #expect(transcriptTexts.contains("replay \(count - 1)"))

        await coordinator.stop(roomID: room)
        await first.cancel()
        await late.cancel()
        await coordinator.stopAll()
    }

    // MARK: - Close

    @Test
    func detachingOneObserverKeepsTheOtherObserverAndRoomMonitorAlive() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: room, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .seconds(60))
        let firstSubscription = await coordinator.observeSubscription(roomID: room)
        let secondSubscription = await coordinator.observeSubscription(roomID: room)
        let first = await Observation.make(stream: firstSubscription.events)
        let second = await Observation.make(stream: secondSubscription.events)

        await coordinator.detach(firstSubscription)
        #expect(await first.waitUntilFinished())
        #expect(await coordinator.isMonitoring(roomID: room))

        try await chat.send(
            roomID: room,
            senderID: "planner",
            destination: .coordinator,
            text: "the remaining observer is still live"
        )
        await coordinator.poll(roomID: room)
        let events = await second.wait(untilAtLeast: 1) {
            $0.contains { $0.renderedMessages?.map(\.text) == ["the remaining observer is still live"] }
        }
        #expect(events.contains {
            $0.renderedMessages?.map(\.text) == ["the remaining observer is still live"]
        })

        await coordinator.detach(secondSubscription)
        #expect(await second.waitUntilFinished())
    }

    @Test
    func stoppingObservationFinishesStreamsAndPreservesUndeliveredMessages() async throws {
        let room = "room-\(UUID().uuidString)"
        let chat = try await makeChat(roomID: room, agents: ["planner"])
        let coordinator = makeCoordinator(chat: chat, pollInterval: .seconds(60))
        let subscription = await coordinator.observeSubscription(roomID: room)
        let observation = await Observation.make(stream: subscription.events)

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

        let resumed = await Observation.make(
            stream: coordinator.observeSubscription(roomID: room).events
        )
        let events = await resumed.wait(untilAtLeast: 2) { $0.contains { $0.autoTrigger != nil } }
        #expect(events.first?.renderedMessages?.map(\.text) == ["survives close"])
        #expect(events.compactMap(\.autoTrigger).first?.messages.map(\.text) == ["survives close"])
        await resumed.cancel()
    }

    /// A room with observers runs its own monitor, so an explicit `poll` may
    /// coalesce with a drain already in flight. Wait for the actual state edge
    /// rather than returning after a wall-clock budget; the suite time limit is
    /// the safeguard for a real liveness regression.
    private func waitUntil(
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        while !(await condition()) {
            await Task.yield()
        }
        return true
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
