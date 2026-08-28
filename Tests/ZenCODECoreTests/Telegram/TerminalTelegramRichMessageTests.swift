import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct TerminalTelegramRichMessageTests {
    @Test
    func markdownPresentationRendersCurrentRichSubset() throws {
        let document = PresentationDocument(markdown: """
        # Release

        A **safe** paragraph with `code`.

        ```swift
        print("ok")
        ```

        1. first
        2. second
        """)
        let rich = try TerminalTelegramRichMessageRenderer.render(document)
        let object = try jsonObject(rich)
        let blocks = try #require(object["blocks"] as? [[String: Any]])

        #expect(blocks.map { $0["type"] as? String } == ["heading", "paragraph", "pre", "list"])
        #expect(blocks[0]["size"] as? Int == 1)
        #expect(blocks[2]["language"] as? String == "swift")
        let items = try #require(blocks[3]["items"] as? [[String: Any]])
        #expect(items.count == 2)
        #expect(items[0]["value"] as? Int == 1)
        #expect(items[0]["type"] as? String == "1")
        #expect(document.plainText.contains("Release"))
        #expect(document.plainText.contains("1. first"))
    }

    @Test
    func detailsButtonsAndDocumentUseBotAPI103WireShapes() throws {
        let document = PresentationDocument(blocks: [
            .details(
                summary: PresentationText("More"),
                blocks: [.paragraph(PresentationText("Visible details"))],
                isOpen: false
            ),
            .buttons([
                PresentationButton(
                    label: "Docs", action: .url(try #require(URL(string: "https://example.com"))), style: nil
                ),
                PresentationButton(label: "Run", action: .callback("run:1"), style: .primary),
            ]),
            .document(
                PresentationDocumentReference(remoteID: "BAACAgQAAx", filename: "report.pdf"),
                caption: PresentationText("Report")
            ),
        ])
        let object = try jsonObject(TerminalTelegramRichMessageRenderer.render(document))
        let blocks = try #require(object["blocks"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["details", "buttons", "document"])
        #expect(blocks[0]["is_open"] == nil)
        let buttons = try #require(blocks[1]["buttons"] as? [[String: Any]])
        #expect(buttons[0]["url"] as? String == "https://example.com")
        #expect(buttons[1]["callback_data"] as? String == "run:1")
        let media = try #require(blocks[2]["document"] as? [String: Any])
        #expect(media["type"] as? String == "document")
        #expect(media["media"] as? String == "BAACAgQAAx")
    }

    @Test
    func sanitizerRemovesInvisibleControlsAndRejectsUnsafeActions() throws {
        let document = PresentationDocument(markdown: "ok\u{202E}\u{0000}visible")
        #expect(document.plainText == "okvisible")
        let encoded = try JSONEncoder().encode(TerminalTelegramRichMessageRenderer.render(document))
        #expect(!encoded.contains(0))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("202e"))

        let unsafe = PresentationDocument(blocks: [.buttons([
            PresentationButton(
                label: "Open", action: .url(try #require(URL(string: "file:///etc/passwd"))), style: nil
            ),
        ])])
        #expect(throws: TerminalTelegramRichMessageError.invalidButton) {
            try TerminalTelegramRichMessageRenderer.render(unsafe)
        }
    }

    @Test
    func serializerUsesSendRichMessageAndDraftBotAPI103Envelopes() async throws {
        let transport = RichRecordingTransport()
        let client = TerminalTelegramAPIClient(token: "token-secret", transport: transport)
        let document = PresentationDocument(markdown: "## Hello\n\nWorld")
        _ = try await client.sendRichMessage(document, to: 42)
        try await client.sendRichMessageDraft(document, to: 42, draftID: 9)

        let requests = transport.requests
        #expect(requests.map(\.method) == ["sendRichMessage", "sendRichMessageDraft"])
        let final = try jsonDictionary(requests[0].body)
        #expect(final["chat_id"] as? Int == 42)
        #expect(final["rich_message"] as? [String: Any] != nil)
        let draft = try jsonDictionary(requests[1].body)
        #expect(draft["draft_id"] as? Int == 9)
        #expect(draft["can_stop"] as? Bool == true)
        #expect(draft["keep_on_stop"] as? Bool == true)
        #expect(!String(decoding: requests[0].body, as: UTF8.self).contains("token-secret"))
    }

    @Test
    func compatibilityRejectionFallsBackToExactlyOnePlainFinal() async throws {
        let transport = RichRecordingTransport(richStatus: 400)
        let support = try makeSupportDirectory()
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let service = TerminalTelegramControlService(transportFactory: { transport })
            let state = try await service.start()
            _ = try await service.sendRichMessageWithFallback(
                "# Complete\n\nanswer", to: 42, topicID: nil, fence: makeFence(epoch: try #require(state.wireLifecycleEpoch))
            )
            _ = await service.stop()
        }
        let requests = transport.requests
        #expect(requests.map(\.method) == ["sendRichMessage", "sendMessage"])
        let fallback = try jsonDictionary(requests[1].body)
        #expect(fallback["text"] as? String == "Complete\n\nanswer")
        #expect(fallback["parse_mode"] == nil)
    }

    @Test
    func incompatibleRichDraftFallsBackToLegacyDraft() async throws {
        let transport = RichRecordingTransport(richStatus: 404)
        let support = try makeSupportDirectory()
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let service = TerminalTelegramControlService(transportFactory: { transport })
            let state = try await service.start()
            try await service.sendRichMessageDraftWithFallback(
                "## Partial\n\nanswer", to: 42, draftID: 19, fence: makeFence(epoch: try #require(state.wireLifecycleEpoch))
            )
            _ = await service.stop()
        }
        let requests = transport.requests
        #expect(requests.map(\.method) == ["sendRichMessageDraft", "sendMessageDraft"])
        let fallback = try jsonDictionary(requests[1].body)
        #expect(fallback["draft_id"] as? Int == 19)
        #expect(fallback["text"] as? String == "Partial\n\nanswer")
    }

    @Test
    func ambiguousFailureNeverFallsBackAndRiskDuplicate() async throws {
        let transport = RichRecordingTransport(richStatus: 500)
        let support = try makeSupportDirectory()
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let service = TerminalTelegramControlService(transportFactory: { transport })
            let state = try await service.start()
            await #expect(throws: TerminalTelegramControlError.self) {
                _ = try await service.sendRichMessageWithFallback(
                    "final", to: 42, topicID: nil, fence: makeFence(epoch: try #require(state.wireLifecycleEpoch))
                )
            }
            _ = await service.stop()
        }
        #expect(transport.requests.map(\.method) == ["sendRichMessage"])
    }

    @Test
    func cancelledRichSendDoesNotEmitPlainFallback() async throws {
        let transport = CancellingRichTransport()
        let client = TerminalTelegramAPIClient(token: "token", transport: transport)
        let task = Task {
            try await client.sendRichMessage(PresentationDocument(markdown: "visible"), to: 42)
        }
        await transport.waitUntilStarted()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.attempts == 1)
    }

    @Test
    func stopWaitsForSuspendedSendAndFencesItsStateMutation() async throws {
        let transport = LifecycleMessageGateTransport()
        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let service = TerminalTelegramControlService(transportFactory: { transport })
            let state = try await service.start()
            let send = Task {
                try await service.sendPlainMessageWithReceipt(
                    "visible", to: 42, topicID: nil, fence: makeFence(epoch: try #require(state.wireLifecycleEpoch))
                )
            }
            await transport.waitUntilStarted()
            let stopped = Mutex(false)
            let stop = Task {
                _ = await service.stop()
                stopped.withLock { $0 = true }
            }
            await Task.yield()
            #expect(!stopped.withLock { $0 })
            await transport.release()
            await #expect(throws: CancellationError.self) { try await send.value }
            _ = await stop.value
            #expect(stopped.withLock { $0 })
            #expect(await transport.attempts == 1)
        }
    }

    @Test
    func compatibilityClassificationExcludesRateLimitsAndServerFailures() {
        #expect(TerminalTelegramControlService.isRichMessageCompatibilityError(
            .apiFailure(status: 400, errorCode: 400, description: "Bad Request: rich messages unsupported", retryAfter: nil)
        ))
        #expect(TerminalTelegramControlService.isRichMessageCompatibilityError(.httpError(404, nil)))
        #expect(!TerminalTelegramControlService.isRichMessageCompatibilityError(
            .apiFailure(status: 429, errorCode: 429, description: "retry", retryAfter: 1)
        ))
        #expect(!TerminalTelegramControlService.isRichMessageCompatibilityError(.httpError(500, nil)))
    }

    private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        try jsonDictionary(JSONEncoder().encode(value))
    }

    private func jsonDictionary(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeSupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-rich-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(
                models: [],
                telegram: AgentTelegramSettingsManifest(
                    enabled: true, botToken: "123456:ABCDEF", linkedChatID: 42, linkedChatTitle: "Test"
                )
            ),
            to: url.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        )
        return url
    }

    private func makeFence(epoch: UUID) -> TerminalTelegramWireFence {
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: "test-room"), generation: 1
        )
        return TerminalTelegramWireFence(lease: lease, lifecycleEpoch: epoch) { candidate in
            guard candidate == lease else { throw CancellationError() }
        }
    }
}

private final class RichRecordingTransport: TelegramHTTPTransport, @unchecked Sendable {
    struct Request: Sendable { let method: String; let body: Data }
    private let storage = Mutex<[Request]>([])
    private let richStatus: Int

    init(richStatus: Int = 200) { self.richStatus = richStatus }

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        let apiMethod = url.lastPathComponent
        switch apiMethod {
        case "deleteWebhook", "setMyCommands":
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        case "getMe":
            return (200, Data(#"{"ok":true,"result":{"id":9001,"is_bot":true,"first_name":"bot","username":"test_bot"}}"#.utf8))
        case "getUpdates":
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        default:
            break
        }
        storage.withLock { $0.append(Request(method: apiMethod, body: body ?? Data())) }
        if apiMethod.hasPrefix("sendRichMessage"), richStatus != 200 {
            return (
                richStatus,
                Data("{\"ok\":false,\"error_code\":\(richStatus),\"description\":\"rich messages unsupported\"}".utf8)
            )
        }
        if apiMethod.hasSuffix("Draft") {
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        }
        return (200, Data(#"{"ok":true,"result":{"message_id":8,"chat":{"id":42,"type":"private"},"text":"ok"}}"#.utf8))
    }

    var requests: [Request] { storage.withLock { $0 } }
}

private actor CancellingRichTransport: TelegramHTTPTransport {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private(set) var attempts = 0

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        attempts += 1
        started = true
        continuation?.resume()
        continuation = nil
        try await Task.sleep(for: .seconds(30))
        return (200, Data())
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private actor LifecycleMessageGateTransport: TelegramHTTPTransport {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var attempts = 0

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        switch url.lastPathComponent {
        case "deleteWebhook", "setMyCommands":
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        case "getMe":
            return (200, Data(#"{"ok":true,"result":{"id":9002,"is_bot":true,"first_name":"bot"}}"#.utf8))
        case "getUpdates":
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        default:
            break
        }
        attempts += 1
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return (200, Data(#"{"ok":true,"result":{"message_id":9,"chat":{"id":42,"type":"private"},"text":"visible"}}"#.utf8))
    }
}
