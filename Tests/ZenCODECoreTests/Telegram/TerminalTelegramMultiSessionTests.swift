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
            chatID: -100, text: "answer", parseMode: nil,
            replyMarkup: nil, messageThreadID: 12
        ))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["chat_id"] as? Int64 == -100)
        #expect(object["message_thread_id"] as? Int == 12)
    }

    @Test
    func settingsDecodeLegacySingleLinkWithoutWideningGroups() throws {
        let data = Data(#"{"enabled":true,"botToken":"secret","linkedChatID":42,"linkedChatTitle":"Private"}"#.utf8)
        let settings = try JSONDecoder().decode(AgentTelegramSettingsManifest.self, from: data)
        #expect(settings.isEnabled)
        #expect(settings.requiresLegacyPrivateRouteClaim)
        #expect(settings.routes.isEmpty)
        #expect(!settings.groupsEnabled)

        let encoded = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["linkedChatID"] as? Int64 == 42)
        #expect(object["routingVersion"] as? Int == 1)
        #expect((object["routes"] as? [Any])?.isEmpty == true)

        let future = AgentTelegramSettingsManifest(
            enabled: true, botToken: "secret", linkedChatID: 42,
            routingVersion: 99
        )
        #expect(!future.isRoutingSupported)
        #expect(!future.isEnabled)
    }

    @Test
    func legacyClaimIsPrivateSingleUseAndPersisted() async throws {
        let snapshots = Mutex<[[AgentTelegramRouteManifest]]>([])
        let router = TerminalTelegramSessionRouter { routes in
            snapshots.withLock { $0.append(routes) }
        }
        let lease = try await router.claimLegacyPrivateRoute(chatID: 42, userID: 7, roomID: "room-a")
        #expect(lease.key == .init(chatID: 42, userID: 7, roomID: "room-a"))
        await #expect(throws: TerminalTelegramRouteDenial.unauthorized) {
            try await router.claimLegacyPrivateRoute(chatID: 42, userID: 8, roomID: "room-b")
        }
        #expect(snapshots.withLock { $0.count } == 1)
    }

    @Test
    func groupsAreStrictOptInAndACLIsFailClosed() async throws {
        let disabled = TerminalTelegramSessionRouter(groupsEnabled: false)
        await #expect(throws: TerminalTelegramRouteDenial.groupsNotEnabled) {
            try await disabled.create(
                chatID: -100, ownerUserID: 7, topicID: 10, roomID: "room",
                chatKind: .supergroup
            )
        }

        let enabled = TerminalTelegramSessionRouter(groupsEnabled: true)
        let owner = try await enabled.create(
            chatID: -100, ownerUserID: 7, topicID: 10, roomID: "room",
            chatKind: .supergroup
        )
        await #expect(throws: TerminalTelegramRouteDenial.unauthorized) {
            try await enabled.resolve(chatID: -100, userID: 8, topicID: 10, chatKind: .supergroup)
        }
        let next = try await enabled.grant(userID: 8, on: owner)
        let member = try await enabled.resolve(
            chatID: -100, userID: 8, topicID: 10, chatKind: .supergroup
        )
        #expect(member.key.userID == 8)
        _ = try await enabled.revoke(userID: 8, on: next)
        await #expect(throws: TerminalTelegramRouteDenial.unauthorized) {
            try await enabled.resolve(chatID: -100, userID: 8, topicID: 10, chatKind: .supergroup)
        }
    }

    @Test
    func topicLifecycleCloseDeleteAndFallback() async throws {
        let router = TerminalTelegramSessionRouter(groupsEnabled: true)
        let fallback = try await router.create(
            chatID: -100, ownerUserID: 7, roomID: "fallback", chatKind: .supergroup
        )
        let topic = try await router.create(
            chatID: -100, ownerUserID: 7, topicID: 12, roomID: "topic", chatKind: .supergroup
        )
        let exact = try await router.resolve(
            chatID: -100, userID: 7, topicID: 12, chatKind: .supergroup
        )
        #expect(exact.key.roomID == "topic")

        try await router.close(topic)
        await #expect(throws: TerminalTelegramRouteDenial.routeClosed) {
            try await router.resolve(chatID: -100, userID: 7, topicID: 12, chatKind: .supergroup)
        }
        let reopened = try await router.create(
            chatID: -100, ownerUserID: 7, topicID: 12, roomID: "topic-2", chatKind: .supergroup
        )
        try await router.delete(reopened)
        let resolvedFallback = try await router.resolve(
            chatID: -100, userID: 7, topicID: 12, chatKind: .supergroup
        )
        #expect(resolvedFallback.key == fallback.key)
        #expect(resolvedFallback.key.topicID == nil)
        #expect(resolvedFallback.effectiveMessageThreadID == 12)

        let otherTopic = try await router.resolve(
            chatID: -100, userID: 7, topicID: 13, chatKind: .supergroup
        )
        #expect(otherTopic.key == fallback.key)
        #expect(otherTopic.effectiveMessageThreadID == 13)
        let state = TerminalTelegramRouteRuntimeState(router: router)
        try await state.enqueue("topic-12", lease: resolvedFallback)
        try await state.enqueue("topic-13", lease: otherTopic)
        #expect(try await state.dequeue(lease: resolvedFallback) == "topic-12")
        #expect(try await state.dequeue(lease: otherTopic) == "topic-13")
    }

    @Test
    func queueLedgerDraftAndReplyTargetsAreRouteIsolated() async throws {
        let router = TerminalTelegramSessionRouter(groupsEnabled: true)
        let first = try await router.create(
            chatID: -100, ownerUserID: 7, topicID: 1, roomID: "one", chatKind: .supergroup
        )
        let second = try await router.create(
            chatID: -100, ownerUserID: 7, topicID: 2, roomID: "two", chatKind: .supergroup
        )
        let state = TerminalTelegramRouteRuntimeState(router: router)
        let sharedID = UUID()
        try await state.enqueue("first", lease: first)
        try await state.enqueue("second", lease: second)
        #expect(try await state.dequeue(lease: second) == "second")
        #expect(try await state.dequeue(lease: first) == "first")
        #expect(try await state.admitLedgerID(sharedID, lease: first))
        #expect(try await state.admitLedgerID(sharedID, lease: second))
        #expect(!(try await state.admitLedgerID(sharedID, lease: first)))

        try await state.registerDraft(9, lease: first)
        #expect(await state.ownsDraft(9, lease: first))
        #expect(!(await state.ownsDraft(9, lease: second)))
        let target = TerminalTelegramRouteRuntimeState.ReplyTarget(roomID: "one", targetID: "agent")
        try await state.registerReplyTarget(target, messageID: 55, lease: first)
        #expect(await state.replyTarget(messageID: 55, lease: first) == target)
        #expect(await state.replyTarget(messageID: 55, lease: second) == nil)
        await #expect(throws: TerminalTelegramRouteDenial.unauthorized) {
            try await state.registerReplyTarget(
                .init(roomID: "two", targetID: "agent"), messageID: 56, lease: first
            )
        }
    }

    @Test
    func revocationFencesDelayedQueueDraftAndReplyOperations() async throws {
        let router = TerminalTelegramSessionRouter(groupsEnabled: true)
        let owner = try await router.create(
            chatID: -100, ownerUserID: 7, topicID: 1, roomID: "one", chatKind: .supergroup
        )
        let granted = try await router.grant(userID: 8, on: owner)
        let member = try await router.resolve(
            chatID: -100, userID: 8, topicID: 1, chatKind: .supergroup
        )
        let state = TerminalTelegramRouteRuntimeState(router: router)
        try await state.enqueue("before", lease: member)
        _ = try await router.revoke(userID: 8, on: granted)
        await #expect(throws: TerminalTelegramRouteDenial.staleGeneration) {
            try await state.enqueue("late", lease: member)
        }
        #expect(!(await state.ownsDraft(1, lease: member)))
        #expect(await state.replyTarget(messageID: 1, lease: member) == nil)
    }

    @Test
    func wireFenceInvalidatedWhileRouteValidationIsSuspendedCannotResume() async throws {
        let gate = WireFenceValidationGate()
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: "room"), generation: 1
        )
        let fence = TerminalTelegramWireFence(lease: lease, lifecycleEpoch: UUID()) { _ in
            await gate.validate()
        }
        let validation = Task { try await fence.validate(chatID: 42) }
        await gate.waitUntilEntered()
        fence.invalidate()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await validation.value }
    }

    @Test
    func retiringOldTurnInvalidatesItsPreexistingWireFence() async {
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: "room"), generation: 1
        )
        let fence = TerminalTelegramWireFence(lease: lease, lifecycleEpoch: UUID()) { _ in }
        let reporter = TerminalTelegramTurnProgressReporter(
            chatID: 42, sendMessage: { _, _ in true }, wireFence: fence
        )
        await reporter.retire()
        await #expect(throws: CancellationError.self) {
            try await fence.validate(chatID: 42)
        }
    }

    @Test
    func inactiveControlServiceRejectsWireAdmissionBeforeTransport() async {
        let transport = DispatcherGateTelegramTransport()
        let service = TerminalTelegramControlService(transportFactory: { transport })
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: "room"), generation: 1
        )
        let fence = TerminalTelegramWireFence(lease: lease, lifecycleEpoch: UUID()) { _ in }
        await #expect(throws: CancellationError.self) {
            _ = try await service.sendPlainMessageWithReceipt(
                "must not send", to: 42, topicID: nil, fence: fence
            )
        }
        #expect(await transport.pollCount == 0)
    }

    @Test
    func failedPersistenceDoesNotPublishRoute() async throws {
        struct SaveFailure: Error {}
        let router = TerminalTelegramSessionRouter { _ in throw SaveFailure() }
        await #expect(throws: SaveFailure.self) {
            try await router.create(
                chatID: 42, ownerUserID: 7, roomID: "room", chatKind: .privateChat
            )
        }
        #expect(await router.snapshot().isEmpty)
    }

    @Test
    func concurrentMutationHasSingleGenerationWinner() async throws {
        let router = TerminalTelegramSessionRouter(groupsEnabled: true)
        let lease = try await router.create(
            chatID: -100, ownerUserID: 7, roomID: "room", chatKind: .supergroup
        )
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for userID in [8, 9] {
                group.addTask {
                    do { _ = try await router.grant(userID: Int64(userID), on: lease); return true }
                    catch { return false }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(outcomes.filter { $0 }.count == 1)
        #expect(outcomes.filter { !$0 }.count == 1)
    }

    @Test
    func permissionReplyFromDifferentFallbackTopicCannotResolveRequest() async throws {
        let router = TerminalTelegramSessionRouter(groupsEnabled: true)
        _ = try await router.create(
            chatID: -100, ownerUserID: 7, roomID: "room", chatKind: .supergroup
        )
        let topicOne = try await router.resolve(
            chatID: -100, userID: 7, topicID: 1, chatKind: .supergroup
        )
        let topicTwo = try await router.resolve(
            chatID: -100, userID: 7, topicID: 2, chatKind: .supergroup
        )
        let broker = TerminalTelegramPermissionBroker()
        let request = AgentToolAuthorizationRequest(
            sessionID: "room", toolCallID: "call", toolName: "local.delete",
            title: "Delete file", kind: "destructive", command: "rm file",
            workingDirectory: "/tmp"
        )
        let message = Mutex<String?>(nil)
        let authorization = Task {
            await broker.authorize(request, lease: topicOne) { text in
                message.withLock { $0 = text }
                return true
            }
        }
        while message.withLock({ $0 }) == nil { await Task.yield() }
        let requestID = try #require(message.withLock { value in
            value?.split(separator: "\n")
                .first { $0.hasPrefix("Request ID:") }
                .map { $0.replacingOccurrences(of: "Request ID:", with: "")
                    .trimmingCharacters(in: .whitespaces) }
        })
        let wrong = await broker.handleMessage("/allow \(requestID)", lease: topicTwo)
        guard case let .handled(reply) = wrong else {
            Issue.record("expected permission command handling")
            authorization.cancel()
            return
        }
        #expect(reply == "No permission request is pending.")
        _ = await broker.handleMessage("/allow \(requestID)", lease: topicOne)
        #expect(await authorization.value == .allowedOnce)
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

private actor WireFenceValidationGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func validate() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
