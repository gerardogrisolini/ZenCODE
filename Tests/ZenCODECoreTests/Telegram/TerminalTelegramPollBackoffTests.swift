import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite
struct TerminalTelegramPollBackoffTests {
    private struct NetworkDown: Error {}

    private func api(_ status: Int, retryAfter: Int? = nil) -> TerminalTelegramControlError {
        .apiFailure(status: status, errorCode: status, description: "x", retryAfter: retryAfter)
    }

    @Test
    func transientDelaysGrowExponentiallyAndCapAtSixtySeconds() {
        var backoff = TerminalTelegramPollBackoff()
        var delays: [Duration] = []
        for _ in 0..<7 {
            delays.append(backoff.recordFailure(NetworkDown(), jitter: 0.5).delay)
        }
        #expect(delays == [
            .seconds(3), .seconds(6), .seconds(12), .seconds(24),
            .seconds(48), .seconds(60), .seconds(60),
        ])
        #expect(backoff.recordFailure(NetworkDown(), jitter: 1).delay <= .seconds(60))
    }

    @Test
    func jitterStaysWithinBand() {
        var low = TerminalTelegramPollBackoff()
        var high = TerminalTelegramPollBackoff()
        #expect(low.recordFailure(NetworkDown(), jitter: 0).delay == .milliseconds(2250))
        #expect(high.recordFailure(NetworkDown(), jitter: 1).delay == .milliseconds(3750))
    }

    @Test
    func successResetsSequence() {
        var backoff = TerminalTelegramPollBackoff()
        _ = backoff.recordFailure(NetworkDown())
        _ = backoff.recordFailure(NetworkDown())
        backoff.recordSuccess()
        #expect(backoff.consecutiveFailures == 0)
        #expect(backoff.recordFailure(NetworkDown(), jitter: 0.5).delay == .seconds(3))
    }

    @Test
    func rateLimitHonoursRetryAfterWithCap() {
        var backoff = TerminalTelegramPollBackoff()
        let short = backoff.recordFailure(api(429, retryAfter: 17))
        #expect(short.kind == .rateLimited)
        #expect(short.delay == .seconds(17))
        let long = backoff.recordFailure(api(429, retryAfter: 3600))
        #expect(long.delay == TerminalTelegramRateGovernor.maximumServerRetryAfter)
        let missing = backoff.recordFailure(api(429))
        #expect(missing.kind == .rateLimited)
        #expect(missing.delay <= .seconds(60))
    }

    @Test
    func tokenAndConflictErrorsUseLongIntervalAndArePersistent() {
        var backoff = TerminalTelegramPollBackoff()
        for status in [401, 403] {
            let decision = backoff.recordFailure(api(status))
            #expect(decision.kind == .invalidToken)
            #expect(decision.kind.isPersistent)
            #expect(decision.delay == .seconds(60))
        }
        let conflict = backoff.recordFailure(api(409))
        #expect(conflict.kind == .conflict)
        #expect(conflict.delay == .seconds(60))
        #expect(backoff.recordFailure(NetworkDown()).kind == .transient)
        #expect(!backoff.recordFailure(api(500)).kind.isPersistent)
    }

    @Test
    func descriptionNeverContainsBotToken() {
        let token = "123456:ABC-def_GHI"
        let error = TerminalTelegramControlError.httpError(
            502, "failed https://api.telegram.org/bot\(token)/getUpdates"
        )
        let text = TerminalTelegramPollBackoff.sanitizedDescription(error)
        #expect(!text.contains(token))
        #expect(text.contains("bot<redacted>"))
        let url = URLError(.cannotConnectToHost, userInfo: [
            NSLocalizedDescriptionKey: "cannot reach https://api.telegram.org/bot\(token)/getUpdates",
        ])
        #expect(!TerminalTelegramPollBackoff.sanitizedDescription(url).contains(token))
    }
}

@Suite
struct TerminalTelegramPollErrorPropagationTests {
    @Test(.timeLimit(.minutes(1)))
    func dispatcherReportsPollFailureThenClearsOnSuccess() async throws {
        let transport = ScriptedPollTransport(responses: [
            (409, #"{"ok":false,"error_code":409,"description":"Conflict: terminated by other getUpdates request"}"#),
            (200, #"{"ok":true,"result":[]}"#),
        ])
        let delays = Mutex<[Duration]>([])
        let dispatcher = TerminalTelegramBotDispatcher(
            sleeper: { delay in delays.withLock { $0.append(delay) } },
            jitter: { 0.5 }
        )
        let client = TerminalTelegramAPIClient(token: "123:secret", transport: transport)
        let events = Mutex<[String?]>([])
        let botID = Int64.random(in: 13_000_001...13_900_000)
        let subscription = try await dispatcher.subscribe(botID: botID, client: client) { text in
            events.withLock { $0.append(text) }
        }
        for _ in 0..<500 where events.withLock({ $0.count }) < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        await dispatcher.unsubscribe(subscription)
        let seen = events.withLock { $0 }
        #expect(seen.count == 2)
        #expect(seen.first??.contains("409") == true)
        #expect(seen.first??.contains("123:secret") == false)
        #expect(seen.last! == nil)
        #expect(delays.withLock { $0.first } == .seconds(60))
    }

    /// Every Telegram diagnostic path shares one sanitizer: tokens embedded in
    /// API or file URLs are removed and oversized bodies are bounded.
    @Test
    func operatorDescriptionRedactsTokenAndBoundsLength() {
        let page = "<html>GET /bot123456:ABCDEF_x-y/getMe "
            + String(repeating: "x", count: 5_000) + "</html>"
        let text = TerminalTelegramControlError.operatorDescription(
            TerminalTelegramControlError.httpError(502, page)
        )
        #expect(!text.contains("123456:ABCDEF"))
        #expect(text.contains("bot<redacted>"))
        #expect(text.count <= TerminalTelegramControlError.maximumDiagnosticLength + 1)

        let foreign = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "download failed: https://api.telegram.org/file/bot42:secret_token/voice.oga",
        ])
        let foreignText = TerminalTelegramControlError.operatorDescription(foreign)
        #expect(!foreignText.contains("secret_token"))
        #expect(foreignText.contains("file/bot<redacted>/voice.oga"))
    }
}

private actor ScriptedPollTransport: TelegramHTTPTransport {
    private var responses: [(Int, String)]

    init(responses: [(Int, String)]) {
        self.responses = responses
    }

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        if responses.isEmpty {
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        let next = responses.removeFirst()
        return (next.0, Data(next.1.utf8))
    }
}
