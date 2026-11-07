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
}

@Suite
struct TerminalTelegramPollErrorPropagationTests {

    /// Transient failures only update `pollError`; a persistent failure tells
    /// the poll-health handler exactly once (a following persistent failure
    /// with a different text does not repeat it), and the first successful poll
    /// reports the recovery and clears `pollError` without touching `lastError`.
    @Test(.timeLimit(.minutes(1)))
    func persistentPollFailureNotifiesOnceThenRecovers() async throws {
        let support = try Self.makeSupportDirectory()
        let transport = RoutedPollTransport(getUpdates: [
            (500, #"{"ok":false,"error_code":500,"description":"Internal Server Error"}"#),
            (409, #"{"ok":false,"error_code":409,"description":"Conflict: terminated by other getUpdates request"}"#),
            (401, #"{"ok":false,"error_code":401,"description":"Unauthorized"}"#),
            (200, #"{"ok":true,"result":[]}"#),
        ])
        let dispatcher = TerminalTelegramBotDispatcher(sleeper: { _ in }, jitter: { 0.5 })
        let (notices, sink) = AsyncStream<TerminalTelegramPollHealthNotice>.makeStream()
        let (seen, finalState) = try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let service = TerminalTelegramControlService(
                transportFactory: { transport }, dispatcher: dispatcher
            )
            await service.setPollHealthHandler { sink.yield($0) }
            _ = try await service.start()
            var iterator = notices.makeAsyncIterator()
            var seen: [TerminalTelegramPollHealthNotice] = []
            while seen.count < 2, let notice = await iterator.next() {
                seen.append(notice)
            }
            let state = await service.currentState()
            _ = await service.stop()
            return (seen, state)
        }
        #expect(seen.count == 2)
        guard case let .failing(text)? = seen.first else {
            Issue.record("the first notice must report the persistent failure")
            return
        }
        #expect(text.contains("409"))
        #expect(!text.contains("123456:ABCDEF"))
        #expect(seen.last == .recovered)
        #expect(finalState.pollError == nil)
        #expect(finalState.lastError == nil)
    }

    /// Rapid off/on: `stop()` returns only after the in-flight long poll has
    /// ended, so the next `start()` never overlaps two `getUpdates` (HTTP 409).
    @Test(.timeLimit(.minutes(1)))
    func stopAwaitsInFlightLongPollBeforeRestart() async throws {
        let support = try Self.makeSupportDirectory()
        let transport = BlockingPollTransport()
        let dispatcher = TerminalTelegramBotDispatcher(sleeper: { _ in }, jitter: { 0.5 })
        let (afterStop, log) = try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let service = TerminalTelegramControlService(
                transportFactory: { transport }, dispatcher: dispatcher
            )
            var started = transport.starts.makeAsyncIterator()
            _ = try await service.start()
            #expect(await started.next() == 1)
            _ = await service.stop()
            let afterStop = await transport.log
            _ = try await service.start()
            #expect(await started.next() == 2)
            _ = await service.stop()
            return (afterStop, await transport.log)
        }
        #expect(afterStop == ["start 1", "end 1"])
        #expect(Array(log.prefix(3)) == ["start 1", "end 1", "start 2"])
    }

    /// Same guarantee at the dispatcher level: unsubscribing the last
    /// subscriber awaits the cancelled poll task even when the stream's
    /// termination already retired it.
    @Test(.timeLimit(.minutes(1)))
    func lastUnsubscribeAwaitsCancelledPollTask() async throws {
        let transport = BlockingPollTransport()
        let dispatcher = TerminalTelegramBotDispatcher(sleeper: { _ in }, jitter: { 0.5 })
        let client = TerminalTelegramAPIClient(token: "123:secret", transport: transport)
        let botID = Int64.random(in: 13_000_001...13_900_000)
        var started = transport.starts.makeAsyncIterator()
        let first = try await dispatcher.subscribe(botID: botID, client: client)
        #expect(await started.next() == 1)
        await dispatcher.unsubscribe(first)
        #expect(await transport.log == ["start 1", "end 1"])
        let second = try await dispatcher.subscribe(botID: botID, client: client)
        #expect(await started.next() == 2)
        await dispatcher.unsubscribe(second)
        #expect(await transport.log == ["start 1", "end 1", "start 2", "end 2"])
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

    private static func fence(epoch: UUID) -> TerminalTelegramWireFence {
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: "default"), generation: 1
        )
        return TerminalTelegramWireFence(lease: lease, lifecycleEpoch: epoch) { candidate in
            guard candidate == lease else { throw CancellationError() }
        }
    }

    private static func makeSupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-poll-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(
                models: [],
                telegram: AgentTelegramSettingsManifest(
                    enabled: true, botToken: "123456:ABCDEF", linkedChatID: 42,
                    linkedChatTitle: "Test", ownerUserID: 7,
                    routes: [.init(roomID: "default")]
                )
            ),
            to: url.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        )
        return url
    }
}

private let sendMessageBody = #"{"ok":true,"result":{"message_id":89,"chat":{"id":42,"type":"private"},"text":"ciao"}}"#

/// Answers the start-up and send calls and plays a scripted `getUpdates`
/// sequence, then parks the long poll like an idle Bot API until cancelled.
private actor RoutedPollTransport: TelegramHTTPTransport {
    private var getUpdates: [(Int, String)]
    private let setMyCommands: (Int, String)
    private let botID = Int.random(in: 14_000_001...14_900_000)

    init(
        getUpdates: [(Int, String)],
        setMyCommands: (Int, String) = (200, #"{"ok":true,"result":true}"#)
    ) {
        self.getUpdates = getUpdates
        self.setMyCommands = setMyCommands
    }

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        switch url.lastPathComponent {
        case "setMyCommands":
            return (setMyCommands.0, Data(setMyCommands.1.utf8))
        case "getMe":
            return (200, Data(#"{"ok":true,"result":{"id":\#(botID),"is_bot":true,"first_name":"bot","username":"test_bot"}}"#.utf8))
        case "sendMessage":
            return (200, Data(sendMessageBody.utf8))
        case "getUpdates":
            guard !getUpdates.isEmpty else {
                try await Task.sleep(for: .seconds(3600))
                throw CancellationError()
            }
            let next = getUpdates.removeFirst()
            return (next.0, Data(next.1.utf8))
        default:
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        }
    }
}

/// Every `getUpdates` blocks until its task is cancelled and records when it
/// starts and ends; `starts` yields the ordinal of each started request.
private actor BlockingPollTransport: TelegramHTTPTransport {
    private(set) var log: [String] = []
    private var count = 0
    nonisolated let starts: AsyncStream<Int>
    private let startsContinuation: AsyncStream<Int>.Continuation
    private let botID = Int.random(in: 14_000_001...14_900_000)

    init() {
        (starts, startsContinuation) = AsyncStream<Int>.makeStream()
    }

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        switch url.lastPathComponent {
        case "getMe":
            return (200, Data(#"{"ok":true,"result":{"id":\#(botID),"is_bot":true,"first_name":"bot","username":"test_bot"}}"#.utf8))
        case "getUpdates":
            count += 1
            let ordinal = count
            log.append("start \(ordinal)")
            startsContinuation.yield(ordinal)
            defer { log.append("end \(ordinal)") }
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        default:
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        }
    }
}
