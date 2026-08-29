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
