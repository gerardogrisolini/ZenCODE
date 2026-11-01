import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite
struct TerminalTelegramMultiSessionTests {
    @Test
    func topicPersistentWireUsesMessageThreadID() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(TerminalTelegramSendMessageRequest(
            chatID: 42, text: "answer", parseMode: nil,
            replyMarkup: nil, messageThreadID: 12
        ))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["chat_id"] as? Int64 == 42)
        #expect(object["message_thread_id"] as? Int == 12)
    }

    @Test
    func ownerAndPrivateTopicsAreFailClosedAndIsolated() async throws {
        let router = TerminalTelegramSessionRouter(linkedChatID: 42, ownerUserID: 7)
        let first = try await router.create(topicID: 1, roomID: "one")
        let second = try await router.create(topicID: 2, roomID: "two")
        await #expect(throws: TerminalTelegramRouteDenial.unauthorized) {
            try await router.resolve(chatID: 42, userID: 8, topicID: 1)
        }
        await #expect(throws: TerminalTelegramRouteDenial.unauthorized) {
            try await router.resolve(chatID: -100, userID: 7, topicID: 1)
        }
        let state = TerminalTelegramRouteRuntimeState(router: router)
        try await state.enqueue("first", lease: first)
        try await state.enqueue("second", lease: second)
        #expect(try await state.dequeue(lease: second) == "second")
        #expect(try await state.dequeue(lease: first) == "first")
    }

    @Test
    func topicLifecycleAndGenerationFenceRemainEnforced() async throws {
        let router = TerminalTelegramSessionRouter(linkedChatID: 42, ownerUserID: 7)
        _ = try await router.create(roomID: "fallback")
        let topic = try await router.create(topicID: 12, roomID: "topic")
        try await router.close(topic)
        await #expect(throws: TerminalTelegramRouteDenial.routeClosed) {
            try await router.resolve(chatID: 42, userID: 7, topicID: 12)
        }
        let reopened = try await router.create(topicID: 12, roomID: "topic-2")
        await #expect(throws: TerminalTelegramRouteDenial.staleGeneration) {
            try await router.validate(topic)
        }
        try await router.delete(reopened)
        let fallback = try await router.resolve(chatID: 42, userID: 7, topicID: 12)
        #expect(fallback.key.topicID == nil)
        #expect(fallback.effectiveMessageThreadID == 12)
    }

    /// Characterization of the current lookup: a topic no route was ever
    /// created for has no exact match and falls back to the single active
    /// topicless route, keeping the inbound topic as the effective thread.
    /// The `.closed` topic denial is pinned by
    /// `topicLifecycleAndGenerationFenceRemainEnforced`.
    @Test
    func unknownTopicFallsBackToTheSingleActiveTopiclessRoute() async throws {
        let router = TerminalTelegramSessionRouter(linkedChatID: 42, ownerUserID: 7)
        let topicless = try await router.create(roomID: "fallback")
        _ = try await router.create(topicID: 12, roomID: "topic")

        let lease = try await router.resolve(chatID: 42, userID: 7, topicID: 99)

        #expect(lease.key == topicless.key)
        #expect(lease.key.roomID == "fallback")
        #expect(lease.key.topicID == nil)
        #expect(lease.generation == topicless.generation)
        #expect(lease.effectiveMessageThreadID == 99)
    }

    @Test
    func failedPersistenceDoesNotPublishRoute() async throws {
        struct SaveFailure: Error {}
        let router = TerminalTelegramSessionRouter(linkedChatID: 42, ownerUserID: 7) { _, _ in
            throw SaveFailure()
        }
        await #expect(throws: SaveFailure.self) {
            try await router.create(roomID: "room")
        }
        #expect(await router.snapshot().isEmpty)
    }

    @Test
    func activeRouteForRoomIDReturnsOnlyActiveRoutes() async throws {
        let router = TerminalTelegramSessionRouter(linkedChatID: 42, ownerUserID: 7)
        _ = try await router.create(roomID: "default")
        _ = try await router.create(topicID: 10, roomID: "session-a")
        let closing = try await router.create(topicID: 20, roomID: "session-b")
        try await router.close(closing)

        let route = try #require(await router.activeRoute(forRoomID: "session-a"))
        #expect(route == AgentTelegramRouteManifest(topicID: 10, roomID: "session-a", generation: 1))
        #expect(await router.activeRoute(forRoomID: " session-a\n") == route)
        #expect(await router.activeRoute(forRoomID: "default") == AgentTelegramRouteManifest(roomID: "default"))
        #expect(await router.activeRoute(forRoomID: "session-b") == nil)
        #expect(await router.activeRoute(forRoomID: "missing") == nil)
        #expect(await router.activeRoute(forRoomID: " ") == nil)
    }

    /// Room IDs are not unique: the highest active topic wins, the topicless
    /// route ranks lowest and the input order of the routes is irrelevant.
    @Test
    func activeRoutePrefersTheHighestTopicWhenSeveralRoutesShareTheRoom() async {
        let newest = AgentTelegramRouteManifest(topicID: 9, roomID: "shared", generation: 4)
        let routes: [AgentTelegramRouteManifest] = [
            .init(topicID: 12, roomID: "shared", lifecycle: .closed, generation: 2),
            .init(topicID: 5, roomID: "shared"),
            .init(roomID: "shared"),
            newest,
        ]
        for order in [routes, Array(routes.reversed())] {
            let router = TerminalTelegramSessionRouter(linkedChatID: 42, ownerUserID: 7, routes: order)
            #expect(await router.activeRoute(forRoomID: "shared") == newest)
        }

        let topicless = TerminalTelegramSessionRouter(linkedChatID: 42, ownerUserID: 7, routes: [
            .init(roomID: "shared"),
            .init(topicID: 3, roomID: "shared", lifecycle: .deleted, generation: 2),
        ])
        #expect(await topicless.activeRoute(forRoomID: "shared") == AgentTelegramRouteManifest(roomID: "shared"))
    }

    @Test
    func rebindKeepsTheTopicAndFencesThePreviousLease() async throws {
        let recorder = TelegramRoutePersistRecorder()
        let router = TerminalTelegramSessionRouter(
            linkedChatID: 42, ownerUserID: 7, persist: recorder.persist
        )
        let state = TerminalTelegramRouteRuntimeState(router: router)
        let previous = try await router.create(topicID: 10, roomID: "session-a")
        try await state.enqueue("queued for session-a", lease: previous)
        let fence = TerminalTelegramWireFence(lease: previous, lifecycleEpoch: UUID()) { lease in
            try await router.validate(lease)
        }
        try await fence.validate(chatID: 42)

        let rebound = try await router.rebind(previous, toRoomID: "session-b")

        #expect(rebound.key == TerminalTelegramRouteKey(
            chatID: 42, userID: 7, topicID: 10, roomID: "session-b"
        ))
        #expect(rebound.generation == previous.generation + 1)
        #expect(rebound.effectiveMessageThreadID == 10)
        #expect(await router.snapshot() == [
            AgentTelegramRouteManifest(topicID: 10, roomID: "session-b", generation: 2),
        ])
        #expect(recorder.count == 2)
        try await router.validate(rebound)
        #expect(try await router.resolve(chatID: 42, userID: 7, topicID: 10) == rebound)
        #expect(await router.activeRoute(forRoomID: "session-a") == nil)
        #expect(await router.activeRoute(forRoomID: "session-b")?.topicID == 10)

        // Work still holding the previous lease can no longer reach the route.
        await #expect(throws: TerminalTelegramRouteDenial.staleGeneration) {
            try await router.validate(previous)
        }
        await #expect(throws: TerminalTelegramRouteDenial.staleGeneration) {
            try await fence.validate(chatID: 42)
        }
        await #expect(throws: TerminalTelegramRouteDenial.staleGeneration) {
            try await state.dequeue(lease: previous)
        }
        await #expect(throws: TerminalTelegramRouteDenial.staleGeneration) {
            try await router.close(previous)
        }
        await #expect(throws: TerminalTelegramRouteDenial.staleGeneration) {
            try await router.rebind(previous, toRoomID: "session-a")
        }
        #expect(recorder.count == 2)

        // Rebinding to the same room still advances the generation.
        let refreshed = try await router.rebind(rebound, toRoomID: "session-b")
        #expect(refreshed.key == rebound.key)
        #expect(refreshed.generation == rebound.generation + 1)
        await #expect(throws: TerminalTelegramRouteDenial.staleGeneration) {
            try await router.validate(rebound)
        }
        #expect(recorder.count == 3)
    }

    @Test
    func rebindRefusesTheTopiclessRouteInactiveRoutesForeignOwnersAndBlankRooms() async throws {
        let recorder = TelegramRoutePersistRecorder()
        let router = TerminalTelegramSessionRouter(
            linkedChatID: 42, ownerUserID: 7, persist: recorder.persist
        )
        let shared = try await router.create(roomID: "default")
        let topic = try await router.create(topicID: 10, roomID: "session-a")
        let closing = try await router.create(topicID: 20, roomID: "session-c")
        try await router.close(closing)
        let closed = TerminalTelegramRouteLease(key: closing.key, generation: closing.generation + 1)
        let foreign = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 8, topicID: 10, roomID: "session-a"),
            generation: topic.generation
        )
        let before = await router.snapshot()
        let commits = recorder.count

        await #expect(throws: TerminalTelegramRouteDenial.unauthorized) {
            try await router.rebind(shared, toRoomID: "session-b")
        }
        await #expect(throws: TerminalTelegramRouteDenial.unauthorized) {
            try await router.rebind(closed, toRoomID: "session-b")
        }
        await #expect(throws: TerminalTelegramRouteDenial.unauthorized) {
            try await router.rebind(foreign, toRoomID: "session-b")
        }
        await #expect(throws: TerminalTelegramRouteDenial.noRoute) {
            try await router.rebind(topic, toRoomID: " \n")
        }

        #expect(await router.snapshot() == before)
        #expect(recorder.count == commits)
        try await router.validate(shared)
        try await router.validate(topic)
    }

    /// `/sessions load` of a session another companion already mirrors binds
    /// a second topic to the same room; the lookup stays deterministic.
    @Test
    func rebindMayTargetARoomAnotherTopicIsAlreadyBoundTo() async throws {
        let router = TerminalTelegramSessionRouter(linkedChatID: 42, ownerUserID: 7)
        let first = try await router.create(topicID: 10, roomID: "session-a")
        let second = try await router.create(topicID: 20, roomID: "session-b")

        let rebound = try await router.rebind(first, toRoomID: "session-b")

        #expect(rebound.key.roomID == "session-b")
        try await router.validate(rebound)
        try await router.validate(second)
        #expect(await router.activeRoute(forRoomID: "session-b")?.topicID == 20)
        #expect(await router.activeRoute(forRoomID: "session-a") == nil)
    }

    @Test
    func failedPersistenceDuringRebindOrPruneDoesNotPublish() async throws {
        let recorder = TelegramRoutePersistRecorder()
        let router = TerminalTelegramSessionRouter(
            linkedChatID: 42, ownerUserID: 7, persist: recorder.persist
        )
        let previous = try await router.create(topicID: 10, roomID: "session-a")
        let closing = try await router.create(topicID: 11, roomID: "session-b")
        try await router.close(closing)
        let before = await router.snapshot()
        recorder.setFailing(true)

        await #expect(throws: TelegramRoutePersistRecorder.SaveFailure.self) {
            try await router.rebind(previous, toRoomID: "session-c")
        }
        await #expect(throws: TelegramRoutePersistRecorder.SaveFailure.self) {
            try await router.prune(keepingInactive: 0)
        }

        #expect(await router.snapshot() == before)
        try await router.validate(previous)
        #expect(await router.activeRoute(forRoomID: "session-c") == nil)
    }

    /// Pruning drops the oldest inactive topics (`.closed` and `.deleted`)
    /// beyond the limit, never an active route nor the topicless route, even
    /// when it is inactive, and the result does not depend on input order.
    @Test
    func pruneKeepsTheTopiclessActiveAndNewestInactiveRoutesDeterministically() async throws {
        let topicless = AgentTelegramRouteManifest(roomID: "default", lifecycle: .closed, generation: 3)
        let oldActive = AgentTelegramRouteManifest(topicID: 1, roomID: "active-old")
        let newActive = AgentTelegramRouteManifest(topicID: 50, roomID: "active-new")
        let inactive: [AgentTelegramRouteManifest] = [
            .init(topicID: 2, roomID: "closed-2", lifecycle: .closed, generation: 2),
            .init(topicID: 3, roomID: "deleted-3", lifecycle: .deleted, generation: 2),
            .init(topicID: 4, roomID: "closed-4", lifecycle: .closed, generation: 2),
            .init(topicID: 7, roomID: "closed-7", lifecycle: .closed, generation: 2),
            .init(topicID: 8, roomID: "deleted-8", lifecycle: .deleted, generation: 2),
            .init(topicID: 9, roomID: "closed-9", lifecycle: .closed, generation: 2),
        ]
        let routes = [topicless, oldActive] + inactive + [newActive]
        let expected: [AgentTelegramRouteManifest] = [topicless, oldActive] + inactive.suffix(3) + [newActive]
        let interleaved: [AgentTelegramRouteManifest] = [inactive[4], newActive, inactive[0], topicless, inactive[5],
                           inactive[2], oldActive, inactive[1], inactive[3]]

        for order in [routes, Array(routes.reversed()), interleaved] {
            let recorder = TelegramRoutePersistRecorder()
            let router = TerminalTelegramSessionRouter(
                linkedChatID: 42, ownerUserID: 7, routes: order, persist: recorder.persist
            )
            try await router.prune(keepingInactive: 3)
            #expect(await router.snapshot() == expected)
            #expect(recorder.commits == [expected])

            try await router.prune(keepingInactive: 3)
            #expect(recorder.count == 1)
        }
    }

    @Test
    func pruneWithinTheLimitPersistsNothingAndANegativeLimitCountsAsZero() async throws {
        let recorder = TelegramRoutePersistRecorder()
        let kept: [AgentTelegramRouteManifest] = [
            .init(roomID: "default"),
            .init(topicID: 10, roomID: "session-a"),
        ]
        let routes = kept + [
            .init(topicID: 11, roomID: "session-b", lifecycle: .closed, generation: 2),
            .init(topicID: 12, roomID: "session-c", lifecycle: .deleted, generation: 3),
        ]
        let router = TerminalTelegramSessionRouter(
            linkedChatID: 42, ownerUserID: 7, routes: routes, persist: recorder.persist
        )

        try await router.prune(keepingInactive: 2)
        try await router.prune(keepingInactive: 32)
        #expect(recorder.count == 0)
        #expect(await router.snapshot() == routes)

        try await router.prune(keepingInactive: -1)
        #expect(await router.snapshot() == kept)
        #expect(recorder.commits == [kept])

        try await router.prune(keepingInactive: 0)
        #expect(recorder.count == 1)
    }

    @Test
    func pruneRequiresAPairedOwner() async {
        let recorder = TelegramRoutePersistRecorder()
        let routes = [AgentTelegramRouteManifest(topicID: 1, roomID: "closed", lifecycle: .closed, generation: 2)]
        let unpaired = TerminalTelegramSessionRouter(
            linkedChatID: nil, ownerUserID: 7, routes: routes, persist: recorder.persist
        )
        let ownerless = TerminalTelegramSessionRouter(
            linkedChatID: 42, ownerUserID: nil, routes: routes, persist: recorder.persist
        )

        for router in [unpaired, ownerless] {
            await #expect(throws: TerminalTelegramRouteDenial.unauthorized) {
                try await router.prune(keepingInactive: 0)
            }
            #expect(await router.snapshot() == routes)
        }
        #expect(recorder.count == 0)
    }

    /// Each successful mutation persists its committed routes exactly once;
    /// refused mutations and no-op prunes persist nothing.
    @Test
    func everyRouterCommitPersistsExactlyOnce() async throws {
        let recorder = TelegramRoutePersistRecorder()
        let router = TerminalTelegramSessionRouter(
            linkedChatID: 42, ownerUserID: 7, persist: recorder.persist
        )
        var snapshots: [[AgentTelegramRouteManifest]] = []

        _ = try await router.create(roomID: "default")
        snapshots.append(await router.snapshot())
        let topic = try await router.create(topicID: 10, roomID: "session-a")
        snapshots.append(await router.snapshot())
        let rebound = try await router.rebind(topic, toRoomID: "session-b")
        snapshots.append(await router.snapshot())
        try await router.close(rebound)
        snapshots.append(await router.snapshot())
        try await router.prune(keepingInactive: 1)
        try await router.prune(keepingInactive: 0)
        snapshots.append(await router.snapshot())
        try await router.prune(keepingInactive: 0)
        _ = try? await router.rebind(topic, toRoomID: "session-c")

        #expect(recorder.commits == snapshots)
        #expect(snapshots.last == [AgentTelegramRouteManifest(roomID: "default")])
    }

    @Test
    func botDispatcherBroadcastsOnePolledUpdateToBothSessions() async throws {
        let transport = DispatcherGateTelegramTransport()
        let client = TerminalTelegramAPIClient(token: "token", transport: transport)
        let botID = Int64.random(in: 8_000_000...9_000_000)
        let first = try await TerminalTelegramBotDispatcher.shared.subscribe(
            botID: botID, client: client
        )
        await transport.waitUntilPolling()
        let second = try await TerminalTelegramBotDispatcher.shared.subscribe(
            botID: botID, client: client
        )
        let firstRead = Task { await first.updates.first(where: { _ in true }) }
        let secondRead = Task { await second.updates.first(where: { _ in true }) }
        #expect(await transport.pollCount == 1)
        await transport.releaseUpdate()
        let firstUpdate = await firstRead.value
        let secondUpdate = await secondRead.value
        #expect(firstUpdate?.updateID == 123)
        #expect(secondUpdate?.updateID == 123)
        await TerminalTelegramBotDispatcher.shared.unsubscribe(first)
        await TerminalTelegramBotDispatcher.shared.unsubscribe(second)
    }

    @Test
    func botDispatcherDoesNotLoseBacklogAboveLegacyBufferForTwoSubscribers() async throws {
        let transport = DispatcherBacklogTelegramTransport(count: 100)
        let client = TerminalTelegramAPIClient(token: "token", transport: transport)
        let botID = Int64.random(in: 9_000_001...9_900_000)
        let first = try await TerminalTelegramBotDispatcher.shared.subscribe(botID: botID, client: client)
        await transport.waitUntilPolling()
        let second = try await TerminalTelegramBotDispatcher.shared.subscribe(botID: botID, client: client)
        let firstRead = Task { await Self.collect(first.updates, count: 100) }
        let secondRead = Task { await Self.collect(second.updates, count: 100) }
        await transport.release()
        #expect(await firstRead.value == Array(1...100))
        #expect(await secondRead.value == Array(1...100))
        await TerminalTelegramBotDispatcher.shared.unsubscribe(first)
        await TerminalTelegramBotDispatcher.shared.unsubscribe(second)
    }

    @Test(.timeLimit(.minutes(1)))
    func botDispatcherAdmitsSubscriberThatJoinsDuringBackpressure() async throws {
        let transport = DispatcherBacklogTelegramTransport(count: 66)
        let client = TerminalTelegramAPIClient(token: "token", transport: transport)
        let botID = Int64.random(in: 10_000_001...10_900_000)
        let first = try await TerminalTelegramBotDispatcher.shared.subscribe(botID: botID, client: client)
        await transport.waitUntilPolling()
        await transport.release()
        try await Self.waitForOffset(64, botID: botID)

        // `publish(65)` is suspended because the first stream's 64 slots are
        // full. This subscribe linearizes inside that publish and therefore
        // must be admitted before offset 65 can be persisted.
        let late = try await TerminalTelegramBotDispatcher.shared.subscribe(botID: botID, client: client)
        let lateRead = Task { await Self.collect(late.updates, count: 2) }
        let firstRead = Task { await Self.collect(first.updates, count: 66) }
        #expect(await firstRead.value == Array(1...66))
        #expect(await lateRead.value == [65, 66])
        await TerminalTelegramBotDispatcher.shared.unsubscribe(first)
        await TerminalTelegramBotDispatcher.shared.unsubscribe(late)
    }

    @Test(.timeLimit(.minutes(1)))
    func botDispatcherUnsubscribeDuringRetryDoesNotStopOtherSubscriber() async throws {
        let transport = DispatcherBacklogTelegramTransport(count: 66)
        let client = TerminalTelegramAPIClient(token: "token", transport: transport)
        let botID = Int64.random(in: 11_000_001...11_900_000)
        let stalled = try await TerminalTelegramBotDispatcher.shared.subscribe(botID: botID, client: client)
        let live = try await TerminalTelegramBotDispatcher.shared.subscribe(botID: botID, client: client)
        let liveRead = Task { await Self.collect(live.updates, count: 66) }
        await transport.waitUntilPolling()
        await transport.release()
        try await Self.waitForOffset(64, botID: botID)

        await TerminalTelegramBotDispatcher.shared.unsubscribe(stalled)
        #expect(await liveRead.value == Array(1...66))
        await TerminalTelegramBotDispatcher.shared.unsubscribe(live)
    }

    @Test(.timeLimit(.minutes(1)))
    func botDispatcherReplacesCompletedOwnerTask() async throws {
        let transport = DispatcherOneShotCancellationTelegramTransport()
        let client = TerminalTelegramAPIClient(token: "token", transport: transport)
        let botID = Int64.random(in: 12_000_001...12_900_000)
        let subscription = try await TerminalTelegramBotDispatcher.shared.subscribe(
            botID: botID, client: client
        )
        await transport.waitUntilFirstCancellation()
        try await Self.waitUntil { await transport.pollCount >= 2 }
        await TerminalTelegramBotDispatcher.shared.unsubscribe(subscription)
    }

    private static func collect(
        _ stream: AsyncStream<TerminalTelegramUpdate>, count: Int
    ) async -> [Int] {
        var result: [Int] = []
        for await update in stream {
            result.append(update.updateID)
            if result.count == count { break }
        }
        return result
    }

    private static func waitForOffset(_ updateID: Int, botID: Int64) async throws {
        try await waitUntil { TerminalTelegramUpdateOffsetStore.load(botID: botID) == updateID }
    }

    private static func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard clock.now < deadline else { throw CancellationError() }
            await Task.yield()
        }
    }
}

// MARK: - Companions on one bot

/// Two sessions of one process, each with a Telegram companion attached in
/// topic mode to one bot: one dispatcher polls it, one router holds every
/// route and persists to the settings, one registry counts the companions.
/// Alpha's topic is 601, beta's 602. A message is delivered to both, as the
/// dispatcher broadcasts every update to every session. Each test runs in
/// a support directory of its own.
extension TerminalTelegramMultiSessionTests {
    private static let alreadyLinkedText =
        "Telegram is already linked to this ZenCODE session. Send a prompt or /help."

    /// A message in a session's topic reaches that session only, and is
    /// answered there; each topic was created and announced in General once.
    @Test(.timeLimit(.minutes(1)))
    func companionTopicsOnOneBotAreIsolated() async throws {
        try await Self.withCompanionSupport {
            let pair = try await Self.attachedCompanionPair(botID: 9701)
            let (alpha, beta) = (pair.alpha, pair.beta)
            #expect(pair.attachments.attachedCount(botID: 9701) == 2)
            #expect(await pair.router.snapshot() == [
                AgentTelegramRouteManifest(roomID: "default"),
                AgentTelegramRouteManifest(topicID: 601, roomID: alpha.sessionID),
                AgentTelegramRouteManifest(topicID: 602, roomID: beta.sessionID),
            ])
            for member in [alpha, beta] {
                let name = TelegramSessionCompanion.defaultTopicName(
                    workingDirectory: member.companion.controller.workingDirectory,
                    sessionID: member.sessionID
                )
                #expect(await member.transport.sentMessages == [CompanionSentText(
                    text: TelegramSessionCompanion.generalTopicNoticeText(topicName: name), topicID: nil
                )])
                #expect(member.companion.activeRouteLease == member.topic)
            }

            #expect(await Self.deliver(Self.ownerMessage("hello", topicID: 601), to: pair) == [alpha.topic, nil])
            #expect(await Self.deliver(Self.ownerMessage("hello", topicID: 602), to: pair) == [nil, beta.topic])
            _ = await Self.deliver(Self.ownerMessage("/start", topicID: 601), to: pair)
            _ = await Self.deliver(Self.ownerMessage("/start", topicID: 602), to: pair)

            #expect(await alpha.transport.sentMessages.dropFirst() == [
                CompanionSentText(text: Self.alreadyLinkedText, topicID: 601),
            ])
            #expect(await beta.transport.sentMessages.dropFirst() == [
                CompanionSentText(text: Self.alreadyLinkedText, topicID: 602),
            ])
            await pair.shutdown()
        }
    }

    /// General belongs to every session: both companions handle a message
    /// sent there on the shared route, and answer in General.
    @Test(.timeLimit(.minutes(1)))
    func generalIsHandledByBothCompanions() async throws {
        try await Self.withCompanionSupport {
            let pair = try await Self.attachedCompanionPair(botID: 9702)
            let shared = try await pair.router.resolve(chatID: 42, userID: 7, topicID: nil)
            #expect(shared.key == TerminalTelegramRouteKey(chatID: 42, userID: 7, roomID: "default"))
            #expect(shared.effectiveMessageThreadID == nil)

            #expect(await Self.deliver(Self.ownerMessage("hello"), to: pair) == [shared, shared])
            _ = await Self.deliver(Self.ownerMessage("/start"), to: pair)

            for member in [pair.alpha, pair.beta] {
                #expect(await member.transport.sentMessages.dropFirst() == [
                    CompanionSentText(text: Self.alreadyLinkedText, topicID: nil),
                ])
            }
            await pair.shutdown()
        }
    }

    /// A topic no route knows falls back to the shared route: both companions
    /// handle the message and answer in the topic it came from.
    @Test(.timeLimit(.minutes(1)))
    func unknownTopicIsHandledByBothCompanionsInThatTopic() async throws {
        try await Self.withCompanionSupport {
            let pair = try await Self.attachedCompanionPair(botID: 9703)
            let unknown = try await pair.router.resolve(chatID: 42, userID: 7, topicID: 999)
            #expect(unknown.key == TerminalTelegramRouteKey(chatID: 42, userID: 7, roomID: "default"))
            #expect(unknown.effectiveMessageThreadID == 999)

            #expect(await Self.deliver(Self.ownerMessage("hello", topicID: 999), to: pair) == [unknown, unknown])
            _ = await Self.deliver(Self.ownerMessage("/start", topicID: 999), to: pair)

            for member in [pair.alpha, pair.beta] {
                #expect(await member.transport.sentMessages.dropFirst() == [
                    CompanionSentText(text: Self.alreadyLinkedText, topicID: 999),
                ])
            }
            await pair.shutdown()
        }
    }

    /// D4 a′: while both companions are attached to the bot, a permission
    /// reply without a request ID in General, or in a topic no route knows,
    /// is refused by both, each in the topic it came from, and runs nothing.
    @Test(.timeLimit(.minutes(1)))
    func permissionRepliesWithoutAnIDInGeneralAreRefusedByBothCompanions() async throws {
        try await Self.withCompanionSupport {
            let pair = try await Self.attachedCompanionPair(botID: 9704)
            let refusal = TelegramSessionCompanion.sharedRoutePermissionReplyText

            for topicID in [nil, 999] as [Int?] {
                #expect(await Self.deliver(
                    Self.ownerMessage("/allow", topicID: topicID), to: pair
                ) == [nil, nil])
            }

            for member in [pair.alpha, pair.beta] {
                #expect(await member.transport.sentMessages.dropFirst() == [
                    CompanionSentText(text: refusal, topicID: nil),
                    CompanionSentText(text: refusal, topicID: 999),
                ])
            }
            await pair.shutdown()
        }
    }

    /// A message in General, or in a topic no route knows, leaves each link
    /// on its session's topic (decision A): the link's route, the next turn
    /// of the primary channel, and the shared-chat relay stay there, while
    /// the message itself is handled on its own route.
    @Test(.timeLimit(.minutes(1)))
    func generalLeavesEachLinkOnItsSessionTopic() async throws {
        try await Self.withCompanionSupport {
            let pair = try await Self.attachedCompanionPair(botID: 9705)
            let (alpha, beta) = (pair.alpha, pair.beta)
            let cards = CompanionLeaseRecorder()
            alpha.companion.sharedChatRelayStorage = TerminalTelegramSharedChatRelay(
                validateLease: { _ in true },
                send: { _, _, lease in
                    cards.append(lease)
                    return 1
                }
            )
            let shared = try await pair.router.resolve(chatID: 42, userID: 7, topicID: nil)
            let unknown = try await pair.router.resolve(chatID: 42, userID: 7, topicID: 999)

            // A message in alpha's topic binds alpha's relay to it.
            #expect(await Self.deliver(Self.ownerMessage("hello", topicID: 601), to: pair) == [alpha.topic, nil])
            #expect(await Self.deliver(Self.ownerMessage("hello"), to: pair) == [shared, shared])
            #expect(await Self.deliver(Self.ownerMessage("hello", topicID: 999), to: pair) == [unknown, unknown])

            for member in [alpha, beta] {
                #expect(member.companion.activeRouteLease == member.topic)
                #expect(member.companion.sessionTopic?.lease == member.topic)
                #expect(member.companion.routedOrigin(for: .primary) == .telegram(member.topic))
            }
            let relay = try #require(alpha.companion.sharedChatRelayStorage)
            await relay.forward([AgentSharedChat.Message(
                roomID: alpha.sessionID,
                sender: AgentSharedChat.Participant(id: "agent-1", name: "planner", kind: .agent),
                recipientIDs: [AgentSharedChat.operatorID(for: alpha.sessionID)],
                text: "ready"
            )], roomID: alpha.sessionID)
            await relay.waitForPendingCards()
            #expect(cards.values == [alpha.topic])
            await pair.shutdown()
        }
    }

    // MARK: Companion support

    /// Runs `body` on the chat-session actor with a fresh support directory
    /// whose settings pair chat 42 of owner 7 with the shared route only,
    /// then removes the directory.
    private static func withCompanionSupport(
        _ body: @escaping @Sendable @ChatSessionActor () async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zencode-telegram-multi-companion-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let telegram = AgentTelegramSettingsManifest(
            enabled: true, botToken: "123456:ABCDEF", linkedChatID: 42,
            linkedChatTitle: "Test", ownerUserID: 7, routes: [.init(roomID: "default")]
        )
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(models: [], telegram: telegram),
            to: directory.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        )
        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            try await body()
        }
    }

    /// Alpha and beta, two sessions in `/tmp/project`, with their companions
    /// attached in topic mode to bot `botID` through one dispatcher, one
    /// router and one registry: alpha first, creating topic 601, then beta,
    /// creating topic 602.
    @ChatSessionActor
    private static func attachedCompanionPair(botID: Int64) async throws -> CompanionPair {
        let settings = AgentSettingsManifestStore.load()?.telegram
        let router = TerminalTelegramSessionRouter(
            linkedChatID: settings?.linkedChatID,
            ownerUserID: settings?.ownerUserID,
            routes: settings?.routes ?? [],
            persist: { ownerUserID, routes in
                try AgentSettingsManifestStore.saveTelegramRoutes(routes, ownerUserID: ownerUserID)
            }
        )
        let dispatcher = TerminalTelegramBotDispatcher()
        let attachments = TelegramCompanionAttachments()
        func member(sessionID: String, topicID: Int) throws -> CompanionPairMember {
            let transport = CompanionTopicTransport(botID: botID, topicID: topicID)
            let terminal = TerminalChat(
                configuration: try AgentConfiguration(
                    hostedModelID: "remote-community/test",
                    availableAgents: AgentProfileStore.defaultProfiles(),
                    workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
                ),
                stdinIsTerminal: true,
                sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil),
                telegramTransportFactory: { transport },
                renderCoordinator: TerminalChatRenderCoordinator(
                    stdinIsTerminal: false,
                    standardOutput: nil,
                    standardError: nil,
                    standardOutputIsTerminal: false,
                    standardErrorIsTerminal: false,
                    cursorTopology: .separate,
                    capturesWrites: true,
                    streamingFlushDelay: nil,
                    columnWidthProvider: { 100 }
                )
            )
            terminal.sessionID = sessionID
            let channel = CompanionPairChannel()
            let companion = TelegramSessionCompanion(
                controller: terminal.chatSession,
                sessionRunner: terminal.sessionRunner,
                router: router,
                controlService: TerminalTelegramControlService(
                    transportFactory: { transport }, dispatcher: dispatcher
                ),
                channel: channel,
                configuration: .init(primaryChannelDescription: "TUI", policy: .full),
                attachments: attachments
            )
            return CompanionPairMember(
                terminal: terminal, channel: channel, companion: companion,
                transport: transport, topicID: topicID
            )
        }
        let pair = CompanionPair(
            alpha: try member(sessionID: "alpha-session-00000001", topicID: 601),
            beta: try member(sessionID: "beta-session-00000002", topicID: 602),
            router: router,
            attachments: attachments
        )
        try await pair.alpha.companion.attach()
        try await pair.beta.companion.attach()
        return pair
    }

    /// Delivers `message` to alpha, then to beta, and returns the route each
    /// admitted its prompt on (`nil`: not admitted).
    @ChatSessionActor
    private static func deliver(
        _ message: TerminalTelegramIncomingMessage,
        to pair: CompanionPair
    ) async -> [TerminalTelegramRouteLease?] {
        var leases: [TerminalTelegramRouteLease?] = []
        for member in [pair.alpha, pair.beta] {
            var admitted: TerminalTelegramRouteLease?
            _ = await member.companion.handleIncomingMessage(
                message, isSessionGenerating: false
            ) { prompt in
                admitted = prompt.origin
                return .queued
            }
            leases.append(admitted)
        }
        return leases
    }

    /// A text of the owner in chat 42, in `topicID` (General when `nil`).
    private static func ownerMessage(_ text: String, topicID: Int? = nil) -> TerminalTelegramIncomingMessage {
        TerminalTelegramIncomingMessage(
            chatID: 42, userID: 7, topicID: topicID, text: text, voice: nil,
            messageID: 78, chatTitle: "Test", username: "operator"
        )
    }
}

/// The two companions of ``TerminalTelegramMultiSessionTests`` on one bot,
/// with the router and the registry they share.
private struct CompanionPair {
    let alpha: CompanionPairMember
    let beta: CompanionPairMember
    let router: TerminalTelegramSessionRouter
    let attachments: TelegramCompanionAttachments

    @ChatSessionActor
    func shutdown() async {
        await alpha.companion.shutdown()
        await beta.companion.shutdown()
    }
}

/// One session of a ``CompanionPair``: the terminal whose session the
/// companion follows, its channel, and its own transport to the bot.
private struct CompanionPairMember {
    let terminal: TerminalChat
    let channel: CompanionPairChannel
    let companion: TelegramSessionCompanion
    let transport: CompanionTopicTransport
    let topicID: Int

    @ChatSessionActor
    var sessionID: String {
        companion.controller.sessionID
    }

    /// The lease of the session's topic, as its attach created it.
    @ChatSessionActor
    var topic: TerminalTelegramRouteLease {
        TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, topicID: topicID, roomID: sessionID),
            generation: 1, effectiveMessageThreadID: topicID
        )
    }
}

/// A primary channel that records the companion's notices and queues
/// nothing.
@ChatSessionActor
private final class CompanionPairChannel: TelegramCompanionChannel {
    let primaryChannelDescription = "TUI"
    private(set) var notices: [String] = []

    func commandContext() -> ChatCommandContext {
        []
    }

    func presentCompanionNotice(_ text: String, channel: ChatSessionNoticeChannel) async {
        notices.append(text)
    }

    func enqueueTelegramPrompt(
        _ text: String,
        lease: TerminalTelegramRouteLease,
        mode: ChatQueuedPromptMode
    ) async -> TelegramPromptAdmission {
        .refused
    }

    func telegramRouteWasInvalidated(_ lease: TerminalTelegramRouteLease) async {}
}

/// A `sendMessage` text with the topic it was sent to.
private struct CompanionSentText: Equatable, Sendable {
    let text: String
    let topicID: Int?
}

/// The leases the shared-chat relay sent its cards on.
private final class CompanionLeaseRecorder: Sendable {
    private let storage = Mutex<[TerminalTelegramRouteLease]>([])

    func append(_ lease: TerminalTelegramRouteLease) {
        storage.withLock { $0.append(lease) }
    }

    var values: [TerminalTelegramRouteLease] {
        storage.withLock { $0 }
    }
}

/// One session's transport to a bot in Threaded mode: getMe reports
/// `botID` with `has_topics_enabled`, createForumTopic answers `topicID`,
/// sendMessage records its text and topic, getUpdates waits until it is
/// cancelled, and every other method succeeds.
private actor CompanionTopicTransport: TelegramHTTPTransport {
    private let botID: Int64
    private let topicID: Int
    private(set) var sentMessages: [CompanionSentText] = []

    init(botID: Int64, topicID: Int) {
        self.botID = botID
        self.topicID = topicID
    }

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        switch url.lastPathComponent {
        case "getMe":
            return (200, Data(
                #"{"ok":true,"result":{"id":\#(botID),"is_bot":true,"first_name":"ZenCODE","username":"zencode_bot","has_topics_enabled":true}}"#.utf8
            ))
        case "getUpdates":
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        case "createForumTopic":
            let topic: [String: Any] = [
                "message_thread_id": topicID, "name": object?["name"] as? String ?? "",
            ]
            return (200, try JSONSerialization.data(withJSONObject: ["ok": true, "result": topic]))
        case "sendMessage":
            sentMessages.append(CompanionSentText(
                text: object?["text"] as? String ?? "",
                topicID: object?["message_thread_id"] as? Int
            ))
            return (200, Data(#"{"ok":true,"result":{"message_id":9,"chat":{"id":42,"type":"private"},"date":0}}"#.utf8))
        default:
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        }
    }
}

private actor DispatcherBacklogTelegramTransport: TelegramHTTPTransport {
    let count: Int
    private var didPoll = false
    private var pollWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var polls = 0

    init(count: Int) { self.count = count }
    func waitUntilPolling() async {
        if didPoll { return }
        await withCheckedContinuation { pollWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        polls += 1
        guard polls == 1 else {
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        didPoll = true
        pollWaiter?.resume(); pollWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        let updates = (1...count).map { id in
            #"{"update_id":\#(id),"message":{"message_id":\#(id),"from":{"id":7,"is_bot":false,"first_name":"x"},"chat":{"id":42,"type":"private","first_name":"x"},"date":1,"text":"hello"}}"#
        }.joined(separator: ",")
        return (200, Data("{\"ok\":true,\"result\":[\(updates)]}".utf8))
    }
}

private actor DispatcherGateTelegramTransport: TelegramHTTPTransport {
    private var didPoll = false
    private var pollWaiter: CheckedContinuation<Void, Never>?
    private var responseWaiter: CheckedContinuation<Void, Never>?
    private(set) var pollCount = 0

    func waitUntilPolling() async {
        if didPoll { return }
        await withCheckedContinuation { pollWaiter = $0 }
    }

    func releaseUpdate() {
        responseWaiter?.resume()
        responseWaiter = nil
    }

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        pollCount += 1
        if pollCount > 1 {
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        didPoll = true
        pollWaiter?.resume()
        pollWaiter = nil
        await withCheckedContinuation { responseWaiter = $0 }
        let json = #"{"ok":true,"result":[{"update_id":123,"message":{"message_id":1,"from":{"id":7,"is_bot":false,"first_name":"x"},"chat":{"id":42,"type":"private","first_name":"x"},"date":1,"text":"hello"}}]}"#
        return (200, Data(json.utf8))
    }
}

private actor DispatcherOneShotCancellationTelegramTransport: TelegramHTTPTransport {
    private var firstCancellationDelivered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var pollCount = 0

    func waitUntilFirstCancellation() async {
        if firstCancellationDelivered { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        pollCount += 1
        if pollCount == 1 {
            firstCancellationDelivered = true
            waiter?.resume()
            waiter = nil
            throw CancellationError()
        }
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

/// Records every `persist` call of a ``TerminalTelegramSessionRouter`` and can
/// make the save fail, so tests count commits without touching the settings
/// store.
private final class TelegramRoutePersistRecorder: Sendable {
    struct SaveFailure: Error {}

    private struct State {
        var commits: [[AgentTelegramRouteManifest]] = []
        var failing = false
    }

    private let state = Mutex(State())

    var commits: [[AgentTelegramRouteManifest]] { state.withLock { $0.commits } }
    var count: Int { commits.count }

    func setFailing(_ failing: Bool) { state.withLock { $0.failing = failing } }

    var persist: TerminalTelegramSessionRouter.Persist {
        { [self] _, routes in
            try state.withLock { state in
                guard !state.failing else { throw SaveFailure() }
                state.commits.append(routes)
            }
        }
    }
}

// MARK: - Two ACP sessions

extension TerminalTelegramMultiSessionTests {
    /// Two sessions of one ACP bridge, each linked with `/telegram on` to the
    /// same bot in Threaded mode, share the bridge's router: each creates its
    /// own topic and neither overwrites the route of the other, in the router
    /// and in the settings. They also share its dispatcher, so the bot has a
    /// single long poll (a second concurrent `getUpdates` would get HTTP 409),
    /// whose messages reach both: a permission reply without an ID in General
    /// is refused by both (D4 a′), and runs nothing.
    @Test(.timeLimit(.minutes(1)))
    func twoACPSessionsShareOneRouterAndOneLongPoll() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let botID = ACPTelegramTestSupport.uniqueBotID()
            let transport = ACPTelegramScriptedTransport(
                botID: botID, hasTopicsEnabled: true, createdTopicIDs: [601, 602]
            )
            let alpha = "acp-alpha-\(UUID().uuidString)"
            let beta = "acp-beta-\(UUID().uuidString)"
            let fixture = try await ACPTelegramBridgeFixture.make(
                root: root, sessionIDs: [alpha, beta], transport: transport
            )
            let activeText = "Telegram remote control is active.\nLinked chat: Test"
            #expect(await fixture.turnTelegramOn(sessionID: alpha, id: 1) == activeText)
            #expect(await fixture.turnTelegramOn(sessionID: beta, id: 2) == activeText)

            let router = try #require(await fixture.bridge.telegramRouterForTesting())
            let alphaCompanion = try #require(await fixture.companion(sessionID: alpha))
            let betaCompanion = try #require(await fixture.companion(sessionID: beta))
            #expect(alphaCompanion !== betaCompanion)
            #expect(await alphaCompanion.router === router)
            #expect(await betaCompanion.router === router)
            #expect(await alphaCompanion.controlService !== betaCompanion.controlService)
            let routes = [
                AgentTelegramRouteManifest(roomID: "default"),
                AgentTelegramRouteManifest(topicID: 601, roomID: alpha),
                AgentTelegramRouteManifest(topicID: 602, roomID: beta),
            ]
            #expect(await router.snapshot() == routes)
            #expect(AgentSettingsManifestStore.load()?.telegram?.routes == routes)
            #expect(await alphaCompanion.activeRouteLease?.key.topicID == 601)
            #expect(await betaCompanion.activeRouteLease?.key.topicID == 602)
            #expect(await TelegramCompanionAttachments.shared.attachedCount(botID: botID) == 2)

            #expect(await ACPTelegramTestSupport.waitUntil { await transport.pollCount > 0 })
            let before = await transport.sentMessages.count
            try await transport.deliver("/allow")
            #expect(await ACPTelegramTestSupport.waitUntil {
                await transport.sentMessages.count >= before + 2
            })
            let refusalText = await TelegramSessionCompanion.sharedRoutePermissionReplyText
            let refusal = ACPTelegramSentMessage(
                method: "sendMessage",
                text: refusalText,
                topicID: nil
            )
            #expect(await Array(transport.sentMessages.dropFirst(before)) == [refusal, refusal])
            #expect(await transport.maximumConcurrentPolls == 1)
            #expect(await fixture.backend.prompts.isEmpty)

            await fixture.bridge.shutdown()
            // Each shutdown closed its session's topic route, in the router
            // and in the settings; the shared route stays active.
            let closed = await router.snapshot()
            #expect(closed.count == 3)
            #expect(closed.filter { $0.topicID == nil }.allSatisfy { $0.lifecycle == .active })
            #expect(closed.filter { $0.topicID != nil }.allSatisfy { $0.lifecycle != .active })
            #expect(AgentSettingsManifestStore.load()?.telegram?.routes == closed)
            #expect(await TelegramCompanionAttachments.shared.attachedCount(botID: botID) == 0)
        }
    }
}
