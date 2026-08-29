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

    /// A non-rate-limit envelope keeps every field too.
    @Test
    func genericErrorEnvelopeKeepsFields() async throws {
        let error = try await Self.decodeError(Data(#"""
        {"ok":false,"error_code":400,"description":"Bad Request: chat not found"}
        """#.utf8), status: 400)

        guard case let .apiFailure(status, errorCode, description, retryAfter) = error else {
            Issue.record("expected apiFailure, got \(error)")
            return
        }
        #expect(status == 400)
        #expect(errorCode == 400)
        #expect(description == "Bad Request: chat not found")
        #expect(retryAfter == nil)
        #expect(!error.isExplicitRateLimit)
        #expect(error.retryAfter == nil)
    }

    /// The human-readable description includes the error code and the retry
    /// hint, so operators see the same fields the governor uses.
    @Test
    func errorDescriptionIncludesCodeAndRetryAfter() {
        let error = TerminalTelegramControlError.apiFailure(
            status: 429, errorCode: 429,
            description: "Too Many Requests", retryAfter: 7
        )
        let text = error.errorDescription ?? ""
        #expect(text.contains("429"))
        #expect(text.contains("retry after 7s"))
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

    @Test
    func firstSendIsImmediatelyLegal() async {
        let clock = MutableClock()
        let governor = makeGovernor(clock: clock)
        let delay = await governor.delay(forChat: 42)
        #expect(delay == nil)
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

    /// A different chat is not throttled by another chat's *per-chat* window:
    /// the only delay it may see is the global one.
    @Test
    func differentChatIsNotThrottledPerChat() async {
        let clock = MutableClock()
        let governor = makeGovernor(clock: clock)
        await governor.record(chatID: 7)
        let delay = await governor.delay(forChat: 8)
        if let delay {
            // The global spacing window may legitimately throttle, but never
            // chat 7's per-chat budget.
            guard case .global = delay.reason else {
                Issue.record("expected global reason, got \(delay)")
                return
            }
        }
    }

    /// The global window throttles once enough sends are admitted, even across
    /// distinct chats.
    @Test
    func globalWindowThrottlesAcrossChats() async {
        let clock = MutableClock()
        let governor = makeGovernor(clock: clock)
        await governor.record(chatID: 1)
        clock.advance(by: 0.03)
        let delay = await governor.delay(forChat: 2)
        // 30ms after the first send, inside the 35ms global spacing window.
        guard case .global = delay?.reason else {
            Issue.record("expected global reason, got \(String(describing: delay))")
            return
        }
    }

    /// After the windows elapse, sending becomes legal again.
    @Test
    func windowsExpireAndSendingBecomesLegalAgain() async {
        let clock = MutableClock()
        let governor = makeGovernor(clock: clock)
        await governor.record(chatID: 9)
        clock.advance(by: 1.5)
        let delay = await governor.delay(forChat: 9)
        #expect(delay == nil)
    }

    /// Only an explicit 429 with a retry_after permits a retry: the governor
    /// reports the pause and keeps honoring server guidance.
    @Test
    func explicit429PermitsRetryAndRecordsPause() async {
        let clock = MutableClock()
        let governor = makeGovernor(clock: clock)
        let error = TerminalTelegramControlError.apiFailure(
            status: 429, errorCode: 429,
            description: "Too Many Requests", retryAfter: 3
        )
        let retryable = await governor.retryAfterFailure(error, chatID: 5)
        #expect(retryable)

        // Immediately after: every chat is paused by the server-reported
        // window.
        let delay = await governor.delay(forChat: 99)
        guard case .global = delay?.reason else {
            Issue.record("expected global pause, got \(String(describing: delay))")
            return
        }
        #expect((delay?.duration ?? .zero) >= .seconds(2))

        // After the server window elapses, sending is legal again.
        clock.advance(by: 3.5)
        let after = await governor.delay(forChat: 99)
        #expect(after == nil)
    }

    /// A 429 without retry_after is not safe to retry.
    @Test
    func fourTwoNineWithoutRetryAfterIsNotRetryable() async {
        let clock = MutableClock()
        let governor = makeGovernor(clock: clock)
        let error = TerminalTelegramControlError.apiFailure(
            status: 429, errorCode: 429, description: nil, retryAfter: nil
        )
        let retryable = await governor.retryAfterFailure(error, chatID: 5)
        #expect(!retryable)
        let delay = await governor.delay(forChat: 5)
        #expect(delay == nil)
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

    /// A hostile retry_after is bounded: no multi-hour stalls from a corrupt
    /// envelope.
    @Test
    func serverRetryAfterIsBounded() async {
        let clock = MutableClock()
        let governor = makeGovernor(clock: clock)
        let error = TerminalTelegramControlError.apiFailure(
            status: 429, errorCode: 429, description: nil, retryAfter: 86_400
        )
        _ = await governor.retryAfterFailure(error, chatID: 5)
        let delay = await governor.delay(forChat: 5)
        #expect((delay?.duration ?? .zero) <= TerminalTelegramRateGovernor.maximumServerRetryAfter)
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

    /// reset() clears both windows.
    @Test
    func resetClearsAllWindows() async {
        let clock = MutableClock()
        let governor = makeGovernor(clock: clock)
        await governor.record(chatID: 3)
        await governor.reset()
        let delay = await governor.delay(forChat: 3)
        #expect(delay == nil)
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

    /// Taking a lease sends the first chat action immediately and renewals stop
    /// at release: the fencing means no further action fires after release.
    @Test
    func presenceLeaseStopsRenewingAfterRelease() async {
        let recorder = PresenceRecorder()
        let manager = TerminalTelegramPresenceLeaseManager(sendAction: {
            await recorder.record($0)
        })
        let lease = await manager.acquire(
            scope: .turn(chatID: 11), fence: Self.presenceFence(chatID: 11)
        )
        let isActiveAfterAcquire = await manager.isActive(lease)
        let heldAfterAcquire = await manager.heldLease
        #expect(isActiveAfterAcquire)
        #expect(heldAfterAcquire == lease)

        await manager.release(lease)
        let heldAfterRelease = await manager.heldLease
        let isActiveAfterRelease = await manager.isActive(lease)
        #expect(heldAfterRelease == nil)
        #expect(!isActiveAfterRelease)

        // A renewal that wakes now finds a stale generation and exits without
        // firing the action. Give the (nonexistent) renewal a chance.
        try? await Task.sleep(for: .milliseconds(50))
        let fired = await recorder.scopes
        #expect(fired == [.turn(chatID: 11)])
    }

    /// Acquiring a second lease replaces the first atomically.
    @Test
    func secondAcquireReplacesFirstLease() async {
        let manager = TerminalTelegramPresenceLeaseManager(sendAction: { _ in })
        let first = await manager.acquire(
            scope: .turn(chatID: 1), fence: Self.presenceFence(chatID: 1)
        )
        let second = await manager.acquire(
            scope: .transcription(chatID: 1), fence: Self.presenceFence(chatID: 1)
        )
        let held = await manager.heldLease
        let firstActive = await manager.isActive(first)
        let secondActive = await manager.isActive(second)
        #expect(held == second)
        #expect(!firstActive)
        #expect(secondActive)
        // Releasing the stale first lease is inert.
        await manager.release(first)
        let heldAfterStaleRelease = await manager.heldLease
        #expect(heldAfterStaleRelease == second)
    }

    /// releaseAll() drops any held lease; used by stop().
    @Test
    func releaseAllDropsHeldLease() async {
        let manager = TerminalTelegramPresenceLeaseManager(sendAction: { _ in })
        _ = await manager.acquire(
            scope: .turn(chatID: 2), fence: Self.presenceFence(chatID: 2)
        )
        await manager.releaseAll()
        #expect(await manager.heldLease == nil)
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

    /// Plain-language aliases match the whole line only: "status" must not
    /// capture "status report please".
    @Test
    func plainAliasMatchesWholeLineOnly() {
        #expect(TerminalTelegramRemoteCommand(text: "status report please") == nil)
        #expect(TerminalTelegramRemoteCommand(text: "stato") == .status)
    }

    /// Every remote command and every coordinator workflow appears in the
    /// published menu. Workflow discovery comes from the coordinator parser.
    @Test
    func botCommandsMirrorRegistryAndExcludeStart() {
        let published = TerminalTelegramCommandRegistry.botCommands
        let publishedNames = Set(published.map(\.command))
        for specification in TerminalTelegramCommandRegistry.commands {
            #expect(publishedNames.contains(specification.name))
        }
        for family in CoordinatorCommandFamily.allCases {
            #expect(publishedNames.contains(family.rawValue))
            #expect(CoordinatorCommandParser.parse("/\(family.rawValue) test") != nil)
        }
        #expect(publishedNames.count == published.count)
        #expect(!published.contains { $0.command == "start" })
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

    /// `/start` stays recognised without being registered.
    @Test
    func startStaysRecognizedButUnregistered() {
        #expect(TerminalTelegramRemoteCommand(text: "/start") == .start)
        #expect(TerminalTelegramRemoteCommand(text: "/start PAYLOAD") == .start)
        #expect(TerminalTelegramRemoteCommand(text: "/start@bot PAYLOAD") == .start)
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

    /// Consumption is case- and whitespace-insensitive, matching the manual
    /// fallback where the operator may type the payload in any case.
    @Test
    func grantConsumptionNormalizesCase() async {
        let store = TerminalTelegramPairingGrantStore()
        let payload = await store.issueGrant()
        let lowered = payload.lowercased()
        let normalizedConsume = await store.consume(payload: "  \(lowered) \n")
        let replayConsume = await store.consume(payload: payload)
        #expect(normalizedConsume)
        #expect(!replayConsume)
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
    func pairingWaitStopsAtExpiredDeadlineAndInvitesSetupRetry() async throws {
        let service = TerminalTelegramPairingService(botToken: "token")
        do {
            _ = try await service.waitForPairing(
                code: "ABCD", deadline: Date(timeIntervalSince1970: 0)
            )
            Issue.record("expected an expired pairing wait")
        } catch let error as TerminalTelegramPairingError {
            #expect(error == .expired)
            #expect(error.localizedDescription.contains("/setup"))
        }
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

    /// The deep link is a t.me URL with the start parameter.
    @Test
    func deepLinkShape() {
        let link = TerminalTelegramPairingGrantLink.deepLink(botUsername: "zencode_bot", payload: "ABCD")
        #expect(link == "https://t.me/zencode_bot?start=ABCD")
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

    /// A 400 is never retried: the error surfaces immediately.
    @Test
    func nonRateLimitFailureIsNotRetried() async throws {
        let transport = ScriptedTelegramHTTPTransport(responses: [
            (400, Data(#"{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}"#.utf8)),
        ])
        let client = TerminalTelegramAPIClient(token: "t", transport: transport)
        do {
            _ = try await client.sendMessage("hello", to: 9, governor: TerminalTelegramRateGovernor())
            Issue.record("expected the 400 to throw")
        } catch let error as TerminalTelegramControlError {
            guard case let .apiFailure(status, _, description, _) = error else {
                Issue.record("expected apiFailure, got \(error)")
                return
            }
            #expect(status == 400)
            #expect(description == "Bad Request: chat not found")
        }
    }

    /// Without a governor the send behaves exactly as before: one request,
    /// result or thrown error, no retry loop.
    @Test
    func ungovernedSendKeepsLegacyBehaviour() async throws {
        let transport = ScriptedTelegramHTTPTransport(responses: [
            (200, Data(#"{"ok":true,"result":{"message_id":7,"chat":{"id":9,"type":"private"},"text":"ok"}}"#.utf8)),
        ])
        let client = TerminalTelegramAPIClient(token: "t", transport: transport)
        let receipt = try await client.sendMessage("hello", to: 9)
        #expect(receipt == 7)
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

    @Test
    func downstreamMailboxIsBoundedLosslessAndBackpressuresProducer() async throws {
        let mailbox = TerminalTelegramMailbox<Int>(capacity: 1)
        #expect(await mailbox.send(1))
        let second = Task { await mailbox.send(2) }

        var observedBackpressure = false
        for _ in 0..<1_000 {
            if await mailbox.hasBackpressuredProducerForTesting {
                observedBackpressure = true
                break
            }
            await Task.yield()
        }
        #expect(observedBackpressure)
        #expect(await mailbox.bufferedCountForTesting == 1)

        var iterator = mailbox.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        #expect(await second.value)
        #expect(await iterator.next() == 2)
        await mailbox.finish()
    }

    // MARK: - Suspended receiver identity

    /// Polls an async condition with cooperative yields: event-driven
    /// observation of actor state, never wall-clock sleeps.
    private static func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("mailbox condition was never observed within 1,000 yields")
    }

    /// Starts a consumer on an empty mailbox and returns it only once its
    /// receiver is actually parked in the actor.
    private static func parkConsumer(
        on mailbox: TerminalTelegramMailbox<Int>
    ) async -> Task<Int?, Never> {
        let consumer = Task { await mailbox.nextElement() }
        await waitUntil { await mailbox.hasSuspendedReceiverForTesting }
        return consumer
    }

    /// Cancelling the consumer that parked a receiver vacates only that
    /// receiver: the slot frees up and a later element is retained in the
    /// bounded buffer instead of vanishing into the dead continuation.
    @Test
    func cancellingConsumerVacatesOnlyItsOwnReceiver() async {
        let mailbox = TerminalTelegramMailbox<Int>(capacity: 1)
        let consumer = await Self.parkConsumer(on: mailbox)

        consumer.cancel()
        #expect(await consumer.value == nil)
        await Self.waitUntil { await !mailbox.hasSuspendedReceiverForTesting }

        #expect(await mailbox.send(1))
        #expect(await mailbox.bufferedCountForTesting == 1)
        #expect(await mailbox.nextElement() == 1)
        await mailbox.finish()
    }

    /// A second receive while one is suspended resolves the first with `nil`
    /// — never a silent overwrite of its continuation — and consumes no
    /// element: the next send is handed to the receiver that is actually
    /// waiting.
    @Test
    func newerReceiveSupersedesSuspendedReceiverWithoutConsuming() async {
        let mailbox = TerminalTelegramMailbox<Int>(capacity: 2)
        let first = await Self.parkConsumer(on: mailbox)

        let second = Task { await mailbox.nextElement() }
        // Only `second` parking can resolve `first`, and it must be with nil.
        #expect(await first.value == nil)
        await Self.waitUntil { await mailbox.hasSuspendedReceiverForTesting }

        #expect(await mailbox.send(7))
        #expect(await second.value == 7)
        #expect(await mailbox.bufferedCountForTesting == 0)
        await mailbox.finish()
    }

    /// The handoff race the receiver identity exists for: the cancellation
    /// handler of a superseded consumer may run after a replacement receiver
    /// has parked. It must leave that replacement alone, whichever order the
    /// two events interleave in.
    @Test
    func lateCancellationLeavesTheReplacementReceiverIntact() async {
        let mailbox = TerminalTelegramMailbox<Int>(capacity: 1)
        let first = await Self.parkConsumer(on: mailbox)

        // Cancel, then hand off before the cancellation handler can run.
        first.cancel()
        let second = Task { await mailbox.nextElement() }
        #expect(await first.value == nil)
        await Self.waitUntil { await mailbox.hasSuspendedReceiverForTesting }
        // Give any in-flight cancellation handler the chance to wrongly
        // vacate the replacement receiver.
        for _ in 0..<64 { await Task.yield() }
        #expect(await mailbox.hasSuspendedReceiverForTesting)

        #expect(await mailbox.send(9))
        #expect(await second.value == 9)
        await mailbox.finish()
    }

    /// `finish()` resolves the receiver that is currently suspended, so a
    /// consumer parked on an empty mailbox is released with `nil` instead of
    /// waiting forever.
    @Test
    func finishResolvesTheSuspendedReceiver() async {
        let mailbox = TerminalTelegramMailbox<Int>(capacity: 1)
        let consumer = await Self.parkConsumer(on: mailbox)

        await mailbox.finish()
        #expect(await consumer.value == nil)
        #expect(await mailbox.hasSuspendedReceiverForTesting == false)
    }

    // MARK: - v2.0.1 public ingress surface

    private static func probeMessage(id: Int) -> TerminalTelegramIncomingMessage {
        TerminalTelegramIncomingMessage(
            chatID: 42, userID: 7, text: "m\(id)", voice: nil,
            messageID: id, chatTitle: nil, username: nil
        )
    }

    private static func makeControlService() -> TerminalTelegramControlService {
        TerminalTelegramControlService(
            transportFactory: { StubTelegramHTTPTransport(status: 200, body: Data()) }
        )
    }

    /// Source compatibility with 2.0.1: the public ingress surface is still an
    /// `AsyncStream<TerminalTelegramIncomingMessage>` plus the public buffer
    /// limit constant, even though the bounded mailbox now owns the RAM bound.
    @Test
    func publicIngressSurfaceStaysSourceCompatibleWithV201() async throws {
        let service = Self.makeControlService()
        let stream: AsyncStream<TerminalTelegramIncomingMessage> = service.incomingMessages
        let limit: Int = TerminalTelegramControlService.incomingMessageBufferLimit
        #expect(limit == 64)

        #expect(await service.incomingMailbox.send(Self.probeMessage(id: 1)))
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.messageID == 1)
        await service.incomingMailbox.finish()
    }

    /// The `AsyncStream` façade is only a demand-driven view of the mailbox: it
    /// adds no buffer of its own, so the ingress stays bounded to
    /// `incomingMessageBufferLimit`, backpressures the extra producer and loses
    /// no message while draining through the public API.
    @Test
    func publicIngressStreamStaysBoundedLosslessAndBackpressured() async throws {
        let service = Self.makeControlService()
        let mailbox = service.incomingMailbox
        let limit = TerminalTelegramControlService.incomingMessageBufferLimit

        for id in 1...limit {
            #expect(await mailbox.send(Self.probeMessage(id: id)))
        }
        let overflow = Task { await mailbox.send(Self.probeMessage(id: limit + 1)) }

        var observedBackpressure = false
        for _ in 0..<1_000 {
            if await mailbox.hasBackpressuredProducerForTesting {
                observedBackpressure = true
                break
            }
            await Task.yield()
        }
        #expect(observedBackpressure)
        // The façade holds nothing: everything retained is the bounded mailbox.
        #expect(await mailbox.bufferedCountForTesting == limit)

        var iterator = service.incomingMessages.makeAsyncIterator()
        for id in 1...limit {
            #expect(await iterator.next()?.messageID == id)
        }
        #expect(await overflow.value)
        #expect(await iterator.next()?.messageID == limit + 1)
        await mailbox.finish()
    }

    /// Regression: `/telegram on` reported success but no Telegram message was
    /// ever delivered again once an ingress consumer had gone away.
    ///
    /// `AsyncStream(unfolding:)` is one-shot. When the façade was stored in a
    /// `let`, the first `nil` — a cancelled forwarding task, a consumer handoff
    /// or a restarted panel loop — terminated that single shared stream forever,
    /// so every later consumer completed immediately while the mailbox happily
    /// kept buffering. The service must vend a live stream to the next consumer.
    @Test
    func ingressSurvivesACancelledConsumerAndStillFeedsTheNextOne() async throws {
        let service = Self.makeControlService()
        let mailbox = service.incomingMailbox

        // A forwarding task parks on the ingress and is then torn down.
        let first = Task { for await _ in service.incomingMessages {} }
        var parked = false
        for _ in 0..<1_000 {
            if await mailbox.hasSuspendedReceiverForTesting {
                parked = true
                break
            }
            await Task.yield()
        }
        #expect(parked)
        first.cancel()
        await first.value

        // `/telegram on` starts a fresh forwarding task: ingress must still work.
        let second = Task { () -> Int? in
            for await message in service.incomingMessages { return message.messageID }
            return nil
        }
        #expect(await mailbox.send(Self.probeMessage(id: 7)))
        #expect(await second.value == 7)
        await mailbox.finish()
    }

    /// Re-vending the façade must not add buffering or duplicate elements: the
    /// bounded mailbox stays the single shared queue behind every stream.
    @Test
    func ingressVendsIndependentStreamsOverTheOneSharedMailbox() async throws {
        let service = Self.makeControlService()
        let mailbox = service.incomingMailbox

        var first = service.incomingMessages.makeAsyncIterator()
        var second = service.incomingMessages.makeAsyncIterator()

        #expect(await mailbox.send(Self.probeMessage(id: 1)))
        #expect(await first.next()?.messageID == 1)
        // Delivered once only: the element is not replayed to the other stream.
        #expect(await mailbox.send(Self.probeMessage(id: 2)))
        #expect(await second.next()?.messageID == 2)
        #expect(await mailbox.bufferedCountForTesting == 0)
        await mailbox.finish()
    }
}
