//
//  TerminalTelegramTurnActivityTests.swift
//  ZenCODE
//
//  What a turn reporter sends besides its text messages: the tool activity
//  (rows edited in place with their outcome, the message closed only by a
//  new message or by a creation whose outcome is unknown, an outcome written
//  where the call started, bursts coalesced, a full message continued in a
//  new one), the thinking messages
//  (an expandable details block of plain text, cut to the message limit,
//  with an italic entity fallback on a definite rejection only), the
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
    /// once it ended; a second outcome or an unknown call changes nothing.
    @Test
    func aToolCallIsARowEditedInPlaceWithItsOutcome() async {
        let log = TelegramTurnActivityWireLog()
        let reporter = log.makeReporter()

        await reporter.toolCallDidStart(id: "1", title: "Read Package.swift")
        await reporter.flush()
        await reporter.toolCallDidStart(id: "2", title: "Run swift build")
        await reporter.flush()
        await reporter.toolCallDidComplete(id: "1", failed: false)
        await reporter.flush()
        await reporter.toolCallDidComplete(id: "2", failed: true)
        await reporter.flush()
        await reporter.toolCallDidComplete(id: "1", failed: true)
        await reporter.toolCallDidComplete(id: "9", failed: false)
        await reporter.flush()

        #expect(await log.effects == [
            .create(id: 100, text: "⏳ Read Package.swift"),
            .edit(id: 100, text: "⏳ Read Package.swift\n⏳ Run swift build"),
            .edit(id: 100, text: "✅ Read Package.swift\n⏳ Run swift build"),
            .edit(id: 100, text: "✅ Read Package.swift\n❌ Run swift build"),
        ])
        // The activity message stays in the chat: retiring deletes nothing.
        await reporter.retire()
        #expect(await log.effects.count == 4)
    }

    /// Only a new message closes the activity message: the first card and
    /// the first sub-agent status create messages, later ones edit theirs in
    /// place and close nothing, a response closes it and the next call opens
    /// a new message below.
    @Test
    func onlyANewMessageClosesTheActivityMessage() async {
        let log = TelegramTurnActivityWireLog()
        let reporter = log.makeReporter()

        await reporter.enqueue(.tasks("📋 card 1"))
        await reporter.enqueue(.subAgentStatus("🤖 Sub-agent\n\none"))
        await reporter.toolCallDidStart(id: "a", title: "A")
        await reporter.flush()
        await reporter.enqueue(.tasks("📋 card 2"))
        await reporter.enqueue(.subAgentStatus("🤖 Sub-agent\n\ntwo"))
        await reporter.toolCallDidStart(id: "b", title: "B")
        await reporter.flush()
        await reporter.enqueue(.agentResponse("Reply"))
        await reporter.toolCallDidStart(id: "c", title: "C")
        await reporter.flush()

        #expect(await log.effects == [
            .cardCreate(id: 100, text: "📋 card 1"),
            .create(id: 101, text: "🤖 Sub-agent\n\none"),
            .create(id: 102, text: "⏳ A"),
            .cardEdit(id: 100, text: "📋 card 2"),
            .edit(id: 101, text: "🤖 Sub-agent\n\ntwo"),
            .edit(id: 102, text: "⏳ A\n⏳ B"),
            .message("Reply"),
            .create(id: 103, text: "⏳ C"),
        ])
        await reporter.retire()
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

    /// The outcome of a call is written in the row of the message it started
    /// in, even once a new message closed it, and after that message.
    @Test
    func anOutcomeGoesToTheMessageItStartedInAfterTheMessageThatClosedIt() async {
        let log = TelegramTurnActivityWireLog()
        let reporter = log.makeReporter()

        await reporter.toolCallDidStart(id: "a", title: "A")
        await reporter.enqueue(.agentResponse("Between"))
        await reporter.toolCallDidStart(id: "b", title: "B")
        await reporter.toolCallDidComplete(id: "a", failed: false)
        await reporter.toolCallDidComplete(id: "b", failed: true)
        await reporter.flush()

        #expect(await log.effects == [
            .create(id: 100, text: "⏳ A"),
            .message("Between"),
            .create(id: 101, text: "⏳ B"),
            .edit(id: 100, text: "✅ A"),
            .edit(id: 101, text: "❌ B"),
        ])
        await reporter.retire()
    }

    /// A burst of calls queued while the message is being created becomes a
    /// single edit with every row and its outcome.
    @Test
    func aBurstOfToolCallsBecomesOneCreateAndOneEdit() async {
        let log = TelegramTurnActivityWireLog()
        let reporter = log.makeReporter()
        await log.holdCreates()

        await reporter.toolCallDidStart(id: "0", title: "Call 0")
        await log.waitUntilACreateIsHeld()
        for index in 1 ..< 20 {
            await reporter.toolCallDidStart(id: "\(index)", title: "Call \(index)")
            await reporter.toolCallDidComplete(id: "\(index)", failed: false)
        }
        await reporter.toolCallDidComplete(id: "0", failed: false)
        await log.releaseCreates()
        await reporter.flush()

        let rows = (0 ..< 20).map { "✅ Call \($0)" }.joined(separator: "\n")
        #expect(await log.effects == [
            .create(id: 100, text: "⏳ Call 0"),
            .edit(id: 100, text: rows),
        ])
        await reporter.retire()
    }

    /// A row that would take the message past 3 900 UTF-16 units opens a new
    /// message; each one stays within the limit.
    @Test
    func aRowThatDoesNotFitOpensANewMessage() async {
        let log = TelegramTurnActivityWireLog()
        let reporter = log.makeReporter()
        let title = String(repeating: "x", count: 200)

        for index in 0 ..< 25 {
            await reporter.toolCallDidStart(id: "\(index)", title: title)
        }
        await reporter.flush()

        let texts = await log.editableTexts
        #expect(texts.keys.sorted() == [100, 101])
        #expect(texts[100]?.split(separator: "\n").count == 19)
        #expect(texts[101]?.split(separator: "\n").count == 6)
        for text in texts.values {
            #expect(text.utf16.count <= TerminalTelegramTurnProgressReporter.maximumMessageLength)
        }
        await reporter.retire()
    }

    /// An activity message whose creation failed with an unknown outcome is
    /// fenced for good: its ledger never creates it again nor adopts it, so
    /// the next call opens a new message instead of joining rows nobody
    /// sees; the outcome of the call it held is never written anywhere.
    @Test
    func aCallAfterAnActivityMessageWhoseCreationFailedOpensANewMessage() async {
        let log = TelegramTurnActivityWireLog()
        let reporter = log.makeReporter()
        await log.failNextCreates()

        await reporter.toolCallDidStart(id: "a", title: "A")
        await reporter.flush()
        await reporter.toolCallDidStart(id: "b", title: "B")
        await reporter.flush()
        await reporter.toolCallDidComplete(id: "a", failed: false)
        await reporter.toolCallDidComplete(id: "b", failed: true)
        await reporter.flush()
        await reporter.toolCallDidStart(id: "c", title: "C")
        await reporter.flush()

        #expect(await log.effects == [
            .createFailed(text: "⏳ A"),
            .create(id: 100, text: "⏳ B"),
            .edit(id: 100, text: "❌ B"),
            .edit(id: 100, text: "❌ B\n⏳ C"),
        ])
        await reporter.retire()
    }

    // MARK: - Order

    /// Reasoning, responses, and tool rows leave in the order they were
    /// queued.
    @Test
    func thinkingResponsesAndToolRowsKeepTheQueueOrder() async {
        let log = TelegramTurnActivityWireLog()
        let reporter = log.makeReporter()

        await reporter.enqueue(.thought("Plan the read."))
        await reporter.enqueue(.agentResponse("Reading."))
        await reporter.toolCallDidStart(id: "a", title: "Read A")
        await reporter.enqueue(.thought("  \n "))
        await reporter.flush()

        #expect(await log.effects == [
            .thought("Plan the read."),
            .message("Reading."),
            .create(id: 100, text: "⏳ Read A"),
        ])
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
        await reporter.toolCallDidComplete(id: "a", failed: false)
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
        await reporter.toolCallDidComplete(id: "a", failed: false)
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

    // MARK: - Presentation

    /// A tool title is one visible line of at most 200 characters.
    @Test
    func aToolTitleIsOneVisibleLineOfAtMost200Characters() {
        #expect(TerminalTelegramTurnActivity.toolTitle("Read\nfile\t`a.swift`  \u{1B}[1mnow\u{1B}[0m\u{202E}")
            == "Read file `a.swift`  now")
        let long = TerminalTelegramTurnActivity.toolTitle(String(repeating: "x", count: 500))
        #expect(long.count == 200)
        #expect(long.hasSuffix("…"))
        #expect(TerminalTelegramTurnActivity.toolTitle(" \n ") == "tool")
        #expect(TerminalTelegramTurnActivity.toolRow(title: "A", outcome: nil) == "⏳ A")
        #expect(TerminalTelegramTurnActivity.toolRow(title: "A", outcome: .succeeded) == "✅ A")
        #expect(TerminalTelegramTurnActivity.toolRow(title: "A", outcome: .failed) == "❌ A")
    }

    /// The thinking message is one closed details block titled
    /// `💭 Thinking`, whose paragraphs are the reasoning as plain text: the
    /// markup it carries is not parsed.
    @Test
    func theThinkingMessageIsAClosedDetailsBlockOfPlainParagraphs() throws {
        let thought = "Use **bold** and <b>tags</b>.\n\nThen `run` it."
        let document = TerminalTelegramTurnActivity.thoughtDocument(thought)
        #expect(document == PresentationDocument(blocks: [
            .details(
                summary: PresentationText("💭 Thinking"),
                blocks: [
                    .paragraph(PresentationText("Use **bold** and <b>tags</b>.")),
                    .paragraph(PresentationText("Then `run` it.")),
                ],
                isOpen: false
            ),
        ]))
        let encoded = try JSONEncoder().encode(TerminalTelegramRichMessageRenderer.render(document))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let blocks = try #require(object["blocks"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "details")
        #expect(blocks[0]["is_open"] == nil)
        let texts = Self.texts(in: blocks[0])
        #expect(texts.joined(separator: "|") == "💭 Thinking|Use **bold** and <b>tags</b>.|Then `run` it.")
    }

    /// A long reasoning block is cut to 3 900 characters with an ellipsis; a
    /// blank one is no message.
    @Test
    func aLongThoughtIsCutToTheMessageLimit() {
        let bounded = TerminalTelegramTurnActivity.boundedThought(String(repeating: "a", count: 5_000))
        #expect(bounded?.count == TerminalTelegramTurnProgressReporter.maximumMessageLength)
        #expect(bounded?.hasSuffix("…") == true)
        #expect(TerminalTelegramTurnActivity.boundedThought("  \n\t ") == nil)
        #expect(TerminalTelegramTurnActivity.boundedThought("  short  ") == "short")
    }

    /// The fallback is the heading over the reasoning, which an italic entity
    /// covers in UTF-16 units: nothing of the text is parsed.
    @Test
    func theFallbackStylesTheThoughtInItalicByEntity() {
        let thought = "Use *stars*, _lines_ and <i>tags</i> 👍"
        let fallback = TerminalTelegramTurnActivity.thoughtFallback(thought)
        #expect(fallback.text == "💭 Thinking\n\n\(thought)")
        #expect(fallback.entities == [
            .italic(offset: "💭 Thinking\n\n".utf16.count, length: thought.utf16.count),
        ])
    }

    /// The sub-agent status is the heading over single lines of at most 160
    /// characters, without terminal styling; no rows, no message.
    @Test
    func theSubAgentStatusIsTheHeadingOverBoundedPlainRows() throws {
        let text = try #require(TerminalTelegramTurnActivity.subAgentStatusText(rows: [
            "\u{1B}[2m1 total\u{1B}[0m",
            "● worker\n  [RUNNING]  · " + String(repeating: "y", count: 300),
        ]))
        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == 4)
        #expect(lines[0] == "🤖 Sub-agent")
        #expect(lines[1].isEmpty)
        #expect(lines[2] == "1 total")
        #expect(lines[3].hasPrefix("● worker   [RUNNING]  · y"))
        #expect(lines[3].count == TerminalTelegramTurnActivity.maximumStatusRowLength)
        #expect(TerminalTelegramTurnActivity.subAgentStatusText(rows: []) == nil)
    }

    // MARK: - Wire

    /// The thinking message goes out as `sendRichMessage` with the details
    /// block; only a definite rejection (400) falls back, once, to a plain
    /// `sendMessage` styled by an italic entity and without a parse mode; an
    /// ambiguous failure (500) never falls back.
    @Test(arguments: [200, 400, 500])
    func theThinkingMessageFallsBackToItalicEntitiesOnlyOnADefiniteRejection(richStatus: Int) async throws {
        let transport = ThoughtWireTransport(richStatus: richStatus)
        let support = try Self.makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let thought = "Check *this* <b>first</b>."
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let service = TerminalTelegramControlService(transportFactory: { transport })
            let epoch = try #require(try await service.start().wireLifecycleEpoch)
            if richStatus == 500 {
                await #expect(throws: TerminalTelegramControlError.self) {
                    _ = try await service.sendThoughtMessageWithFallback(
                        thought, to: 42, topicID: nil, fence: Self.makeFence(epoch: epoch)
                    )
                }
            } else {
                _ = try await service.sendThoughtMessageWithFallback(
                    thought, to: 42, topicID: nil, fence: Self.makeFence(epoch: epoch)
                )
            }
            _ = await service.stop()
        }
        let requests = transport.requests
        let rich = try #require(requests.first)
        #expect(rich.method == "sendRichMessage")
        let richBody = try Self.jsonObject(rich.body)
        let richMessage = try #require(richBody["rich_message"] as? [String: Any])
        let blocks = try #require(richMessage["blocks"] as? [[String: Any]])
        #expect(blocks.first?["type"] as? String == "details")
        #expect(richBody["parse_mode"] == nil)
        switch richStatus {
        case 400:
            #expect(requests.map(\.method) == ["sendRichMessage", "sendMessage"])
            let fallback = try Self.jsonObject(requests[1].body)
            #expect(fallback["text"] as? String == "💭 Thinking\n\n\(thought)")
            #expect(fallback["parse_mode"] == nil)
            let entities = try #require(fallback["entities"] as? [[String: Any]])
            #expect(entities.count == 1)
            #expect(entities.first?["type"] as? String == "italic")
            #expect(entities.first?["offset"] as? Int == "💭 Thinking\n\n".utf16.count)
            #expect(entities.first?["length"] as? Int == thought.utf16.count)
        default:
            #expect(requests.map(\.method) == ["sendRichMessage"])
        }
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

    /// Every string held under a `text` key of a decoded rich block, in
    /// document order.
    private static func texts(in value: Any) -> [String] {
        if let text = value as? String {
            return [text]
        }
        if let array = value as? [Any] {
            return array.flatMap { texts(in: $0) }
        }
        guard let object = value as? [String: Any] else { return [] }
        return ["summary", "text", "blocks"].flatMap { key in
            object[key].map { texts(in: $0) } ?? []
        }
    }

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

/// Records every request after the lifecycle calls, rejecting
/// `sendRichMessage` with `richStatus` unless it is 200.
private final class ThoughtWireTransport: TelegramHTTPTransport, @unchecked Sendable {
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
            return (200, Data(#"{"ok":true,"result":{"id":9011,"is_bot":true,"first_name":"bot","username":"test_bot"}}"#.utf8))
        case "getUpdates":
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        default:
            break
        }
        storage.withLock { $0.append(Request(method: apiMethod, body: body ?? Data())) }
        if apiMethod == "sendRichMessage", richStatus != 200 {
            return (
                richStatus,
                Data("{\"ok\":false,\"error_code\":\(richStatus),\"description\":\"rich messages unsupported\"}".utf8)
            )
        }
        return (200, Data(#"{"ok":true,"result":{"message_id":8,"chat":{"id":42,"type":"private"},"text":"ok"}}"#.utf8))
    }

    var requests: [Request] { storage.withLock { $0 } }
}
