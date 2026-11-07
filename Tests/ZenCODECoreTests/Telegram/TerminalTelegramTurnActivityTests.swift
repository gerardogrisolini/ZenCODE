//
//  TerminalTelegramTurnActivityTests.swift
//  ZenCODE
//
//  What a turn reporter sends besides its text messages: the tool activity
//  (rows edited in place with their outcome and elapsed time, room kept for
//  the times so a message never exceeds the limit, the message closed only by
//  a new message or by a creation whose outcome is unknown, an outcome
//  written where the call started, bursts coalesced, a full message continued
//  in a new one), the thinking messages
//  (a plain text in an expandable blockquote with the reasoning in italic
//  by entity, cut to the message limit, always one `sendMessage` and never
//  retried), the
//  sub-agent status, the queue order, and nothing after the retire. Nothing
//  reaches the network; the wire tests run in a UUID support directory.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@Suite(.timeLimit(.minutes(1)))
struct TerminalTelegramTurnActivityTests {
    private typealias Effect = TelegramTurnActivityEffect

    // MARK: - Tool activity

    /// A call is a row with a neutral marker, edited in place with ✅ or ❌
    /// and the time the tool executor measured once it ended; a running row
    /// shows no time; a second outcome or an unknown call changes nothing.
    @Test
    func aToolCallIsARowEditedInPlaceWithItsOutcome() async {
        let log = TelegramTurnActivityWireLog()
        let reporter = log.makeReporter()

        await reporter.toolCallDidStart(id: "1", title: "Read Package.swift")
        await reporter.flush()
        await reporter.toolCallDidStart(id: "2", title: "Run swift build")
        await reporter.flush()
        await reporter.toolCallDidComplete(id: "1", failed: false, elapsed: .milliseconds(1_250))
        await reporter.flush()
        await reporter.toolCallDidComplete(id: "2", failed: true, elapsed: .milliseconds(1_330))
        await reporter.flush()
        await reporter.toolCallDidComplete(id: "1", failed: true, elapsed: .seconds(9))
        await reporter.toolCallDidComplete(id: "9", failed: false, elapsed: .seconds(9))
        await reporter.flush()

        #expect(await log.effects == [
            .create(id: 100, text: "⏳ Read Package.swift"),
            .edit(id: 100, text: "⏳ Read Package.swift\n⏳ Run swift build"),
            .edit(id: 100, text: "✅ Read Package.swift 1.25s\n⏳ Run swift build"),
            .edit(id: 100, text: "✅ Read Package.swift 1.25s\n❌ Run swift build 1.33s"),
        ])
        // The activity message stays in the chat: retiring deletes nothing.
        await reporter.retire()
        #expect(await log.effects.count == 4)
    }

    /// Every kind of new message closes the activity message: a response, a
    /// reasoning block, a sub-agent response, an authorization, the summary,
    /// the first card, and the creation of the sub-agent status.
    @Test(arguments: ["response", "thought", "subAgentResponse", "authorization", "summary", "card", "status"])
    func everyNewMessageClosesTheActivityMessage(closer: String) async {
        let log = TelegramTurnActivityWireLog()
        let reporter = log.makeReporter()

        await reporter.toolCallDidStart(id: "a", title: "A")
        switch closer {
        case "response": await reporter.enqueue(.agentResponse("Reply"))
        case "thought": await reporter.enqueue(.thought("A thought."))
        case "subAgentResponse": await reporter.enqueue(.subAgentResponse("✅ Response from worker:\n\nDone."))
        case "authorization": _ = await reporter.send(.authorization("Allow local.exec?"))
        case "summary": await reporter.enqueue(.summary("1 file changed"))
        case "card": await reporter.enqueue(.tasks("📋 card"))
        default: await reporter.enqueue(.subAgentStatus("🤖 Sub-agent\n\none"))
        }
        await reporter.toolCallDidStart(id: "b", title: "B")
        await reporter.flush()

        let creates = await log.effects.filter {
            if case let .create(_, text) = $0 { return text.hasPrefix("⏳") }
            return false
        }
        #expect(creates.count == 2, "\(closer)")
        #expect(await log.editableTexts.values.sorted() == (closer == "status"
            ? ["⏳ A", "⏳ B", "🤖 Sub-agent\n\none"] : ["⏳ A", "⏳ B"]))
        await reporter.retire()
    }

    /// A row that would take the message past 3 900 UTF-16 units, the room
    /// kept for the time of every running row included, opens a new message;
    /// each one stays within the limit once every call ended with its time.
    @Test
    func aRowThatDoesNotFitOpensANewMessage() async {
        let log = TelegramTurnActivityWireLog()
        let reporter = log.makeReporter()
        let title = String(repeating: "x", count: 200)

        for index in 0 ..< 25 {
            await reporter.toolCallDidStart(id: "\(index)", title: title)
        }
        await reporter.flush()

        var texts = await log.editableTexts
        #expect(texts.keys.sorted() == [100, 101])
        #expect(texts[100]?.split(separator: "\n").count == 18)
        #expect(texts[101]?.split(separator: "\n").count == 7)
        for text in texts.values {
            #expect(text.utf16.count <= TerminalTelegramTurnProgressReporter.maximumMessageLength)
        }

        let elapsed: Duration = .seconds(1_234_567) + .milliseconds(890)
        for index in 0 ..< 25 {
            await reporter.toolCallDidComplete(id: "\(index)", failed: false, elapsed: elapsed)
        }
        await reporter.flush()
        texts = await log.editableTexts
        for text in texts.values {
            #expect(text.utf16.count <= TerminalTelegramTurnProgressReporter.maximumMessageLength)
            #expect(text.split(separator: "\n").allSatisfy { $0 == "✅ \(title) 1234567.89s" })
        }
        await reporter.retire()
    }

    // MARK: - Retire

    /// Once retired, a reporter sends and edits nothing: an outcome, a call,
    /// a thought, a status, a response. The card is deleted, the activity
    /// message stays.
    @Test
    func nothingIsSentOnceTheReporterRetired() async {
        let log = TelegramTurnActivityWireLog()
        let reporter = log.makeReporter()

        await reporter.enqueue(.tasks("📋 card"))
        await reporter.toolCallDidStart(id: "a", title: "A")
        await reporter.flush()
        await reporter.retire()
        await reporter.toolCallDidComplete(id: "a", failed: false, elapsed: .zero)
        await reporter.toolCallDidStart(id: "b", title: "B")
        await reporter.enqueue(.thought("late"))
        await reporter.enqueue(.subAgentStatus("🤖 Sub-agent\n\nlate"))
        await reporter.enqueue(.agentResponse("late"))
        await reporter.flush()

        #expect(await log.effects == [
            .cardCreate(id: 100, text: "📋 card"),
            .create(id: 101, text: "⏳ A"),
            .cardDelete(id: 100),
        ])
    }

    /// A creation still in flight when the reporter retires is not followed
    /// by the edits queued behind it, and its receipt changes nothing.
    @Test
    func theEditsQueuedBehindACreateInFlightAreDroppedAtTheRetire() async {
        let log = TelegramTurnActivityWireLog()
        let reporter = log.makeReporter()
        await log.holdCreates()

        await reporter.toolCallDidStart(id: "a", title: "A")
        await log.waitUntilACreateIsHeld()
        await reporter.toolCallDidStart(id: "b", title: "B")
        await reporter.toolCallDidComplete(id: "a", failed: false, elapsed: .zero)
        await reporter.retire()
        await log.releaseCreates()
        await reporter.flush()

        #expect(await log.effects == [.create(id: 100, text: "⏳ A")])
    }

    // MARK: - Editable message ledger

    /// A create whose outcome is unknown fences the message for good; a
    /// failed edit keeps the ownership and the next update edits again; an
    /// unchanged text is not sent again.
    @Test
    func theEditableMessageNeverDuplicatesAfterAnAmbiguousCreate() async {
        actor Wire {
            var sends = 0
            var edits: [String] = []
            var failsSend = true
            var failsEdit = false
            func send() throws -> Int {
                sends += 1
                if failsSend { throw URLError(.networkConnectionLost) }
                return 7
            }
            func edit(_ text: String) throws {
                if failsEdit { failsEdit = false; throw URLError(.timedOut) }
                edits.append(text)
            }
            func setFailsSend(_ fails: Bool) { failsSend = fails }
            func setFailsEdit(_ fails: Bool) { failsEdit = fails }
        }
        let ambiguous = Wire()
        let fenced = TerminalTelegramEditableMessageLedger(
            chatID: 42,
            send: { _, _ in try await ambiguous.send() },
            edit: { text, _, _ in try await ambiguous.edit(text) }
        )
        await fenced.update(text: "first")
        await fenced.update(text: "second")
        #expect(await ambiguous.sends == 1)
        #expect(await ambiguous.edits.isEmpty)

        let wire = Wire()
        await wire.setFailsSend(false)
        let ledger = TerminalTelegramEditableMessageLedger(
            chatID: 42,
            send: { _, _ in try await wire.send() },
            edit: { text, _, _ in try await wire.edit(text) }
        )
        await ledger.update(text: "one")
        await ledger.update(text: "one")
        await wire.setFailsEdit(true)
        await ledger.update(text: "two")
        await ledger.update(text: "two")
        await ledger.retire()
        await ledger.update(text: "three")
        #expect(await wire.sends == 1)
        #expect(await wire.edits == ["two"])
    }

    // MARK: - Wire

    /// The thinking message goes out as exactly one `sendMessage` and never
    /// as a rich message: the marker and the reasoning as plain text, without
    /// a parse mode, all of it covered by an `expandable_blockquote` and the
    /// reasoning by an `italic` entity, in UTF-16 units.
    @Test
    func theThinkingMessageIsOneSendMessageWithQuoteAndItalicEntities() async throws {
        let transport = ThoughtWireTransport()
        let support = try Self.makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let thought = "Check *this* <b>first</b> 👍"
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let service = TerminalTelegramControlService(transportFactory: { transport })
            let epoch = try #require(try await service.start().wireLifecycleEpoch)
            let messageID = try await service.sendThoughtMessage(
                thought, to: 42, topicID: nil, fence: Self.makeFence(epoch: epoch)
            )
            #expect(messageID == 8)
            _ = await service.stop()
        }
        let requests = transport.requests
        #expect(requests.map(\.method) == ["sendMessage"])
        let body = try Self.jsonObject(try #require(requests.first).body)
        #expect(body["text"] as? String == "💭 \(thought)")
        #expect(body["parse_mode"] == nil)
        let entities = try #require(body["entities"] as? [[String: Any]])
        #expect(entities.map { $0["type"] as? String } == ["expandable_blockquote", "italic"])
        #expect(entities.map { $0["offset"] as? Int } == [0, "💭 ".utf16.count])
        #expect(entities.map { $0["length"] as? Int } == [
            "💭 \(thought)".utf16.count, thought.utf16.count,
        ])
    }

    /// A message without entities keeps its wire content, the JSON of the
    /// request as it was before entities existed: the same fields with the
    /// same values, nothing added (the encoder does not fix the order of the
    /// keys, so the comparison is on the JSON with sorted keys); entities
    /// replace the parse mode.
    @Test
    func entitiesNeverTravelWithAParseMode() async throws {
        let transport = ThoughtWireTransport()
        let client = TerminalTelegramAPIClient(token: "secret", transport: transport)
        try await client.sendMessage("plain", to: 42, parseMode: "Markdown")
        try await client.sendMessage(
            "in a topic", to: 42, messageThreadID: 9, parseMode: "MarkdownV2", replyMarkup: .forceReply
        )
        try await client.sendMessage("styled", to: 42, parseMode: "Markdown", entities: [.italic(offset: 0, length: 6)])
        let requests = transport.requests
        #expect(requests.count == 3)
        guard requests.count == 3 else { return }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let expectedPlain = try encoder.encode(SendMessageRequestBeforeEntities(
            chatID: 42, text: "plain", parseMode: "Markdown", replyMarkup: nil, messageThreadID: nil
        ))
        let expectedTopic = try encoder.encode(SendMessageRequestBeforeEntities(
            chatID: 42, text: "in a topic", parseMode: "MarkdownV2", replyMarkup: .forceReply, messageThreadID: 9
        ))
        let plain = try Self.canonicalJSON(requests[0].body)
        let topic = try Self.canonicalJSON(requests[1].body)
        let canonicalExpectedPlain = try Self.canonicalJSON(expectedPlain)
        let canonicalExpectedTopic = try Self.canonicalJSON(expectedTopic)
        #expect(plain == canonicalExpectedPlain)
        #expect(topic == canonicalExpectedTopic)
        #expect(plain == #"{"chat_id":42,"parse_mode":"Markdown","text":"plain"}"#)

        let styled = try Self.jsonObject(requests[2].body)
        #expect(Set(styled.keys) == ["chat_id", "text", "entities"])
    }

    /// `sendMessage` as its request was encoded before entities existed: the
    /// same fields, in the same order.
    private struct SendMessageRequestBeforeEntities: Encodable {
        let chatID: Int64
        let text: String
        let parseMode: String?
        let replyMarkup: TerminalTelegramReplyMarkup?
        let messageThreadID: Int?
    }

    /// The JSON object of `body` with its keys sorted, as text.
    private static func canonicalJSON(_ body: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: body)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Helpers

    private static func makeSupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-turn-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(models: [], telegram: TelegramChannelTestSupport.pairedSettings),
            to: url.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        )
        return url
    }

    private static func makeFence(epoch: UUID) -> TerminalTelegramWireFence {
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: "test-room"), generation: 1
        )
        return TerminalTelegramWireFence(lease: lease, lifecycleEpoch: epoch) { candidate in
            guard candidate == lease else { throw CancellationError() }
        }
    }

    private static func jsonObject(_ body: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

/// Records every request after the lifecycle calls, rejecting `sendMessage`
/// with `sendMessageStatus` unless it is 200.
private final class ThoughtWireTransport: TelegramHTTPTransport, @unchecked Sendable {
    struct Request: Sendable { let method: String; let body: Data }
    private let storage = Mutex<[Request]>([])
    private let sendMessageStatus: Int

    init(sendMessageStatus: Int = 200) { self.sendMessageStatus = sendMessageStatus }

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        let apiMethod = url.lastPathComponent
        switch apiMethod {
        case "deleteWebhook", "setMyCommands":
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        case "getMe":
            return (200, Data(#"{"ok":true,"result":{"id":9011,"is_bot":true,"first_name":"bot","username":"test_bot"}}"#.utf8))
        case "getUpdates":
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        default:
            break
        }
        storage.withLock { $0.append(Request(method: apiMethod, body: body ?? Data())) }
        if apiMethod == "sendMessage", sendMessageStatus != 200 {
            return (
                sendMessageStatus,
                Data("{\"ok\":false,\"error_code\":\(sendMessageStatus),\"description\":\"message rejected\"}".utf8)
            )
        }
        return (200, Data(#"{"ok":true,"result":{"message_id":8,"chat":{"id":42,"type":"private"},"text":"ok"}}"#.utf8))
    }

    var requests: [Request] { storage.withLock { $0 } }
}
