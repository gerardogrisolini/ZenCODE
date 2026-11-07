//
//  TerminalTelegramFoundationTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Foundation tests for phase 1: typed error envelope, rate governor,
/// presence lease lifecycle, command registry, and pairing grant.
@Suite
struct TerminalTelegramFoundationTests {
    // MARK: - Error envelope

    /// A Bot API 429 envelope decodes into the typed error with status,
    /// error_code, description and retry_after — no body re-parsing at the
    /// call site.
    @Test
    func rateLimitEnvelopeDecodesTypedErrorWithRetryAfter() async throws {
        let error = try await Self.decodeError(Data(#"""
        {"ok":false,"error_code":429,"description":"Too Many Requests: retry after 3","parameters":{"retry_after":3}}
        """#.utf8))

        guard case let .apiFailure(status, errorCode, description, retryAfter) = error else {
            Issue.record("expected apiFailure, got \(error)")
            return
        }
        #expect(status == 429)
        #expect(errorCode == 429)
        #expect(description == "Too Many Requests: retry after 3")
        #expect(retryAfter == 3)
        #expect(error.isExplicitRateLimit)
        #expect(error.retryAfter == 3)
    }

    // MARK: - Governor

    /// A controllable monotonic clock so window math is verified without real
    /// sleeping. Anchored at the first read, then advanced in whole seconds.
    private final class MutableClock: @unchecked Sendable {
        private let lock = Mutex(Double?.none)
        func advance(by seconds: Double) {
            lock.withLock { $0 = ($0 ?? 0) + seconds }
        }
        var now: ContinuousClock.Instant {
            let elapsed = lock.withLock { state -> Double in
                if let value = state { return value }
                state = 0
                return 0
            }
            return anchor.advanced(by: .seconds(elapsed))
        }
        private var anchor: ContinuousClock.Instant {
            ContinuousClock().now
        }
    }

    private func makeGovernor(clock: MutableClock) -> TerminalTelegramRateGovernor {
        TerminalTelegramRateGovernor(now: { clock.now })
    }

    /// The per-chat window throttles a second send to the same chat.
    @Test
    func perChatWindowThrottlesSecondSend() async {
        let clock = MutableClock()
        let governor = makeGovernor(clock: clock)
        await governor.record(chatID: 7)
        clock.advance(by: 0.2)

        let delay = await governor.delay(forChat: 7)
        guard case let .perChat(chatID) = delay?.reason else {
            Issue.record("expected perChat reason, got \(String(describing: delay))")
            return
        }
        #expect(chatID == 7)
        // ~800ms of the 1s window remains after 200ms.
        let duration = delay?.duration ?? .zero
        #expect(duration >= .milliseconds(700))
        #expect(duration <= .milliseconds(900))
    }

    @Test
    func concurrentReservationsCannotTakeTheSameSlot() async {
        let clock = MutableClock()
        let governor = makeGovernor(clock: clock)
        let outcomes = await withTaskGroup(
            of: TerminalTelegramGovernedDelay?.self,
            returning: [TerminalTelegramGovernedDelay?].self
        ) { group in
            for _ in 0..<16 {
                group.addTask { await governor.reserve(chatID: 42) }
            }
            var values: [TerminalTelegramGovernedDelay?] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(outcomes.filter { $0 == nil }.count == 1)
        #expect(outcomes.compactMap { $0 }.count == 15)
    }

    /// Every non-429 failure — including ambiguous outcomes — must not be
    /// retried.
    @Test
    func nonFourTwentyNineFailuresAreNotRetryable() async {
        let clock = MutableClock()
        let governor = makeGovernor(clock: clock)
        let failures: [TerminalTelegramControlError] = [
            .apiFailure(status: 400, errorCode: 400, description: "Bad Request", retryAfter: nil),
            .apiFailure(status: 500, errorCode: 500, description: "Internal", retryAfter: nil),
            .httpError(0, nil), // transport failure, ambiguous outcome
            .unexpectedResponse,
        ]
        for failure in failures {
            let retryable = await governor.retryAfterFailure(failure, chatID: 1)
            #expect(!retryable, "failure \(failure) must not be retryable")
        }
    }

    // MARK: - Presence lease

    /// Records every fired chat action behind an actor, so assertions read a
    /// consistent snapshot without manual locking.
    private actor PresenceRecorder {
        private(set) var scopes: [TerminalTelegramPresenceScope] = []
        func record(_ scope: TerminalTelegramPresenceScope) {
            scopes.append(scope)
        }
    }

    private static func presenceFence(chatID: Int64) -> TerminalTelegramWireFence {
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: chatID, userID: 7, roomID: "presence-test"), generation: 1
        )
        return TerminalTelegramWireFence(lease: lease, lifecycleEpoch: UUID()) { candidate in
            guard candidate == lease else { throw CancellationError() }
        }
    }

    @Test
    func revokedRouteFencePreventsPresenceWireEffect() async {
        let recorder = PresenceRecorder()
        let manager = TerminalTelegramPresenceLeaseManager(sendAction: {
            await recorder.record($0)
        })
        let fence = Self.presenceFence(chatID: 3)
        fence.invalidate()
        _ = await manager.acquire(scope: .turn(chatID: 3), fence: fence)
        #expect(await recorder.scopes.isEmpty)
    }

    // MARK: - Command registry

    /// The registry drives the parser: every registered spelling resolves.
    @Test
    func registryDrivesParser() {
        for specification in TerminalTelegramCommandRegistry.commands {
            for form in specification.allForms {
                #expect(
                    TerminalTelegramRemoteCommand(text: form) == specification.command,
                    "form \(form) must resolve to \(specification.command)"
                )
                #expect(
                    TerminalTelegramRemoteCommand(text: form.uppercased()) == specification.command,
                    "parser is case-insensitive"
                )
            }
            // A @botname suffix on the slash form resolves too.
            #expect(
                TerminalTelegramRemoteCommand(text: "/\(specification.name)@zencode_bot") == specification.command
            )
        }
    }

    /// The production API client emits a valid all-private-chats Bot API scope
    /// and omits the chat id that is illegal for that scope.
    @Test
    func setMyCommandsAPIClientEmitsValidPrivateChatScope() async throws {
        let transport = RecordingTelegramHTTPTransport()
        let client = TerminalTelegramAPIClient(token: "token", transport: transport)
        _ = try await client.setMyCommands(TerminalTelegramCommandRegistry.botCommands)
        let body = try #require(await transport.lastBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let commands = try #require(json?["commands"] as? [[String: Any]])
        let first = try #require(commands.first)
        let scope = try #require(json?["scope"] as? [String: Any])
        #expect(first["command"] as? String == "help")
        #expect(first["description"] as? String != nil)
        #expect(scope["type"] as? String == "all_private_chats")
        #expect(scope["chat_id"] == nil)
    }

    /// sendChatAction wire shape.
    @Test
    func sendChatActionRequestEncodesWireShape() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let request = TerminalTelegramSendChatActionRequest(chatID: 42, action: "typing")
        let json = try JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any]
        #expect(json?["chat_id"] as? Int == 42)
        #expect(json?["action"] as? String == "typing")
    }

    // MARK: - Pairing grant

    /// A grant is single-use: the first consume succeeds, replays fail.
    @Test
    func grantIsSingleUse() async {
        let store = TerminalTelegramPairingGrantStore()
        let payload = await store.issueGrant()
        let firstConsume = await store.consume(payload: payload)
        let replayConsume = await store.consume(payload: payload)
        let thirdConsume = await store.consume(payload: payload)
        #expect(firstConsume)
        #expect(!replayConsume)
        #expect(!thirdConsume)
    }

    /// Unknown payloads never consume anything.
    @Test
    func unknownPayloadIsRejected() async {
        let store = TerminalTelegramPairingGrantStore()
        _ = await store.issueGrant()
        let unknownConsume = await store.consume(payload: "DEADBEEF")
        let emptyConsume = await store.consume(payload: "")
        #expect(!unknownConsume)
        #expect(!emptyConsume)
    }

    @Test
    func nonPrivatePairingPresentationDoesNotConsumeGrant() async {
        let service = TerminalTelegramPairingService(botToken: "token")
        let grant = await service.issuePairingGrant()
        #expect(!(await service.consumePairingGrant(
            payload: grant, chatType: "supergroup"
        )))
        #expect(await service.consumePairingGrant(payload: grant, chatType: "private"))
        #expect(!(await service.consumePairingGrant(payload: grant, chatType: "private")))
    }

    @Test
    func pairingDeadlineCancelsInFlightGetUpdates() async throws {
        let transport = BlockingPairingTelegramHTTPTransport()
        let service = TerminalTelegramPairingService(botToken: "token", transport: transport)
        let wait = Task {
            try await service.waitForPairing(
                code: "ABCD",
                deadline: Date().addingTimeInterval(0.2)
            )
        }
        await transport.waitUntilPollStarted()
        do {
            _ = try await wait.value
            Issue.record("expected pairing deadline")
        } catch let error as TerminalTelegramPairingError {
            #expect(error == .expired)
        }
        #expect(await transport.pollWasCancelled)
    }

    /// Grants expire after the TTL and can no longer be consumed.
    @Test
    func grantExpiresAfterTTL() async {
        let store = TerminalTelegramPairingGrantStore()
        let issued = Date()
        let payload = await store.issueGrant(now: issued)
        let expired = issued.addingTimeInterval(TerminalTelegramPairingGrant.timeToLive + 1)
        let consumeExpired = await store.consume(payload: payload, now: expired)
        #expect(!consumeExpired)
    }

    /// Payloads carry 128 bits of entropy (32 hex characters) and differ
    /// between issuances.
    @Test
    func payloadCarries128BitsAndIsUnique() async {
        let store = TerminalTelegramPairingGrantStore()
        var seen = Set<String>()
        for _ in 0..<16 {
            let payload = await store.issueGrant()
            #expect(payload.count == 32)
            #expect(payload.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789ABCDEF").inverted) == nil)
            seen.insert(payload)
        }
        #expect(seen.count == 16)
    }

    /// The store keeps only the SHA-256 digest, never the payload: two equal
    /// payloads hash identically, and the digest is not the payload itself.
    @Test
    func storeKeepsOnlyDigest() async {
        let store = TerminalTelegramPairingGrantStore()
        let payload = await store.issueGrant()
        let digest = TerminalTelegramPairingGrantStore.digest(payload)
        #expect(digest != payload)
        #expect(digest.count == 64) // SHA-256 hex
        #expect(TerminalTelegramPairingGrantStore.digest(payload.lowercased()) == digest)
    }

    /// `/start <payload>` extraction, including @botname, bare /start (nil)
    /// and non-start lines (nil).
    @Test
    func startPayloadExtraction() {
        #expect(TerminalTelegramPairingGrantLink.payload(fromStartCommand: "/start ABCD") == "ABCD")
        #expect(TerminalTelegramPairingGrantLink.payload(fromStartCommand: "/start@bot 1234") == "1234")
        #expect(TerminalTelegramPairingGrantLink.payload(fromStartCommand: "/start") == nil)
        #expect(TerminalTelegramPairingGrantLink.payload(fromStartCommand: "hello") == nil)
        #expect(TerminalTelegramPairingGrantLink.payload(fromStartCommand: "/help ABCD") == nil)
        #expect(TerminalTelegramPairingGrantLink.payload(fromStartCommand: "/start ") == nil)
    }

    // MARK: - Helpers

    /// Sends one message through a stub transport and returns the typed error
    /// it produces. Fails the test when the send unexpectedly succeeds.
    private static func decodeError(
        _ data: Data,
        status: Int = 429
    ) async throws -> TerminalTelegramControlError {
        let transport = StubTelegramHTTPTransport(status: status, body: data)
        let client = TerminalTelegramAPIClient(token: "t", transport: transport)
        do {
            _ = try await client.sendMessage("x", to: 1)
            Issue.record("expected the envelope to throw")
            throw CocoaError(.userActivityConnectionUnavailable)
        } catch let error as TerminalTelegramControlError {
            return error
        }
    }
}

private actor RecordingTelegramHTTPTransport: TelegramHTTPTransport {
    private(set) var lastBody: Data?

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        lastBody = body
        return (200, Data(#"{"ok":true,"result":true}"#.utf8))
    }
}

private actor BlockingPairingTelegramHTTPTransport: TelegramHTTPTransport {
    private var pollStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var pollWasCancelled = false

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        guard url.lastPathComponent == "getUpdates" else {
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        }
        pollStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        do {
            try await Task.sleep(for: .seconds(60))
            return (200, Data(#"{"ok":true,"result":[]}"#.utf8))
        } catch {
            pollWasCancelled = true
            throw error
        }
    }

    func waitUntilPollStarted() async {
        guard !pollStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

/// Minimal transport stub returning one canned response.
struct StubTelegramHTTPTransport: TelegramHTTPTransport {
    let status: Int
    let body: Data

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        (status: status, body: self.body)
    }
}
/// Transport that replays scripted responses, to drive the production
/// `sendMessage` path through the governor without any network.
private final class ScriptedTelegramHTTPTransport: TelegramHTTPTransport, @unchecked Sendable {
    private let lock = Mutex(Data?.none)
    /// Responses in order; the last one repeats.
    private var responses: [(status: Int, body: Data)]
    private var index = 0

    init(responses: [(status: Int, body: Data)]) {
        self.responses = responses
    }

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        lock.withLock { _ in
            let response = responses[min(index, responses.count - 1)]
            index += 1
            return response
        }
    }
}

/// Governor-driven end-to-end behaviour of `sendMessage`.
@Suite
struct TerminalTelegramGovernedSendTests {
    /// An explicit 429 with retry_after is retried once and then succeeds.
    @Test
    func explicit429IsRetriedAndThenSucceeds() async throws {
        let transport = ScriptedTelegramHTTPTransport(responses: [
            (429, Data(#"{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 1","parameters":{"retry_after":1}}"#.utf8)),
            (200, Data(#"{"ok":true,"result":{"message_id":51,"chat":{"id":9,"type":"private"},"text":"ok"}}"#.utf8)),
        ])
        let client = TerminalTelegramAPIClient(token: "t", transport: transport)
        let receipt = try await client.sendMessage("hello", to: 9, governor: TerminalTelegramRateGovernor())
        #expect(receipt == 51)
    }
}

@Suite
struct TerminalTelegramReleaseFenceTests {
    @Test
    func wireFenceRejectsRootAndMismatchedTopicForTopicLease() async throws {
        let lease = TerminalTelegramRouteLease(
            key: TerminalTelegramRouteKey(
                chatID: 42, userID: 7, topicID: nil, roomID: "room"
            ),
            generation: 1,
            effectiveMessageThreadID: 44
        )
        let fence = TerminalTelegramWireFence(lease: lease, lifecycleEpoch: UUID()) { candidate in
            guard candidate == lease else { throw CancellationError() }
        }

        try await fence.validate(chatID: 42, topicID: 44)
        await #expect(throws: CancellationError.self) {
            try await fence.validate(chatID: 42, topicID: nil)
        }
        await #expect(throws: CancellationError.self) {
            try await fence.validate(chatID: 42, topicID: 45)
        }
    }

    // MARK: - Suspended receiver identity
}
