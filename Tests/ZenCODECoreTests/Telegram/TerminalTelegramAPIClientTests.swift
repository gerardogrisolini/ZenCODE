//
//  TerminalTelegramAPIClientTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalTelegramAPIClientTests {
    /// Telegram's *Reply* action is the only durable link between a card the bot
    /// sent and the answer typed for it, and `reply_to_message` is decoded
    /// non-recursively: only the referenced identifier is read.
    @Test
    func replyToMessageIsDecodedAsANonRecursiveReference() throws {
        let update = try JSONDecoder().decode(
            TerminalTelegramAPIResponse<[TerminalTelegramUpdate]>.self,
            from: Data("""
            {
              "ok": true,
              "result": [{
                "update_id": 7,
                "message": {
                  "message_id": 21,
                  "from": { "id": 42, "is_bot": false },
                  "chat": { "id": 42, "type": "private" },
                  "text": "ship it",
                  "reply_to_message": {
                    "message_id": 20,
                    "from": { "id": 1, "is_bot": true },
                    "chat": { "id": 42, "type": "private" },
                    "text": "Worker \\u2192 you"
                  }
                }
              }]
            }
            """.utf8)
        )

        let message = try #require(update.result?.first?.message)
        #expect(message.replyToMessage?.messageID == 20)
    }

    @Test
    func callbackQueryAndReplyMarkupUseTelegramWireShapes() throws {
        let update = try JSONDecoder().decode(
            TerminalTelegramAPIResponse<[TerminalTelegramUpdate]>.self,
            from: Data(#"""
            {"ok":true,"result":[{"update_id":9,"callback_query":{"id":"cb-1","from":{"id":7,"is_bot":false},"data":"zencode:mention:dev","message":{"message_id":12,"chat":{"id":42,"type":"private"}}}}]}
            """#.utf8)
        )
        #expect(update.result?.first?.callbackQuery?.id == "cb-1")
        #expect(update.result?.first?.callbackQuery?.data == "zencode:mention:dev")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let keyboard = try JSONSerialization.jsonObject(with: encoder.encode(
            TerminalTelegramSendMessageRequest(
                chatID: 42, text: "Choose", parseMode: nil,
                replyMarkup: .inlineKeyboard([[
                    TerminalTelegramInlineKeyboardButton(text: "@dev", callbackData: "zencode:mention:dev")
                ]])
            )
        )) as? [String: Any]
        let markup = try #require(keyboard?["reply_markup"] as? [String: Any])
        #expect(((markup["inline_keyboard"] as? [[[String: Any]]])?.first?.first?["callback_data"] as? String) == "zencode:mention:dev")

        let forceReply = try JSONSerialization.jsonObject(with: encoder.encode(
            TerminalTelegramReplyMarkup.forceReply
        )) as? [String: Any]
        #expect(forceReply?["force_reply"] as? Bool == true)
    }

    /// Telegram counts the message limit in UTF-16 code units. A text built from
    /// non-BMP scalars is far below 4000 `Character`s and would still be rejected
    /// on the wire, so the bound must be measured the way the wire measures it.
    @Test
    func outboundTextIsBoundedByTheUTF16WireLimit() {
        let hostile = String(repeating: "👨‍👩‍👧‍👦🇮🇹", count: 4_000)
        let bounded = TerminalTelegramAPIClient.boundedMessageText(hostile)

        #expect(hostile.utf16.count > TerminalTelegramAPIClient.maximumMessageUTF16Length)
        #expect(bounded.utf16.count <= TerminalTelegramAPIClient.maximumMessageUTF16Length)
        #expect(!bounded.isEmpty)
    }

    /// Truncation happens on grapheme-cluster boundaries, so a cut can never
    /// split an emoji into unpaired surrogates or strip a combining mark from its
    /// base character.
    @Test
    func boundedTextNeverSplitsAGraphemeCluster() {
        let cluster = "👩‍💻"
        let bounded = TerminalTelegramAPIClient.boundedMessageText(
            String(repeating: cluster, count: 4_000)
        )

        #expect(bounded.utf16.count % cluster.utf16.count == 0)
        #expect(bounded.allSatisfy { String($0) == cluster })
    }

    @Test
    func snakeCaseTelegramPayloadsDecodeAndRequestsEncode() throws {
        // Mirrors the production client: plain decoder, snake-case encoder.
        let decoder = JSONDecoder()

        let updates = try decoder.decode(
            TerminalTelegramAPIResponse<[TerminalTelegramUpdate]>.self,
            from: Data("""
            {
              "ok": true,
              "result": [{
                "update_id": 1001,
                "message": {
                  "message_id": 1002,
                  "from": { "id": 42, "is_bot": false, "username": "gerardo" },
                  "chat": {
                    "id": 42,
                    "type": "private",
                    "title": "ZenCODE",
                    "username": "gerardo",
                    "first_name": "Gerardo",
                    "last_name": "Grisolini"
                  },
                  "text": "hello",
                  "voice": {
                    "file_id": "voice-file",
                    "file_unique_id": "unique-voice-file",
                    "duration": 9,
                    "mime_type": "audio/ogg",
                    "file_size": 1024
                  }
                }
              }]
            }
            """.utf8)
        )
        let update = try #require(updates.result?.first)
        let message = try #require(update.message)
        let voice = try #require(message.voice)
        #expect(update.updateID == 1001)
        #expect(message.messageID == 1002)
        #expect(message.from?.isBot == false)
        #expect(message.chat.firstName == "Gerardo")
        #expect(message.chat.lastName == "Grisolini")
        #expect(voice.fileID == "voice-file")
        #expect(voice.fileUniqueID == "unique-voice-file")
        #expect(voice.mimeType == "audio/ogg")
        #expect(voice.fileSize == 1024)

        let file = try decoder.decode(
            TerminalTelegramAPIResponse<TerminalTelegramFile>.self,
            from: Data("""
            {
              "ok": true,
              "result": {
                "file_id": "download-file",
                "file_unique_id": "unique-download-file",
                "file_size": 2048,
                "file_path": "voice/file.oga"
              }
            }
            """.utf8)
        )
        #expect(file.result?.fileID == "download-file")
        #expect(file.result?.fileUniqueID == "unique-download-file")
        #expect(file.result?.fileSize == 2048)
        #expect(file.result?.filePath == "voice/file.oga")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let requests: [any Encodable] = [
            TerminalTelegramDeleteWebhookRequest(dropPendingUpdates: true),
            TerminalTelegramGetUpdatesRequest(offset: 1003, timeout: 30, allowedUpdates: ["message"]),
            TerminalTelegramSendMessageRequest(chatID: 42, text: "hello", parseMode: "MarkdownV2", replyMarkup: nil),
            TerminalTelegramGetFileRequest(fileID: "download-file")
        ]
        let encoded = try requests.map { request in
            try JSONSerialization.jsonObject(with: encoder.encode(AnyEncodable(request))) as? [String: Any]
        }
        #expect(encoded[0]?["drop_pending_updates"] as? Bool == true)
        #expect(encoded[1]?["allowed_updates"] as? [String] == ["message"])
        #expect(encoded[2]?["chat_id"] as? Int == 42)
        #expect(encoded[2]?["parse_mode"] as? String == "MarkdownV2")
        #expect(encoded[3]?["file_id"] as? String == "download-file")
    }

    /// Changed on purpose by the topic runtime (plan 4, point 3). The point-1
    /// characterization pinned that `getMe` ignored the topic flags. Now it
    /// decodes `has_topics_enabled` (Bot API 9.3) and
    /// `allows_users_to_create_topics` (Bot API 9.4), because topic mode reads
    /// the first flag to decide on one topic per session. The `Mirror` check
    /// still pins the whole decoded surface, so any other new field remains a
    /// deliberate change.
    @Test
    func getMeDecodesTopicCapabilityFlags() async throws {
        let transport = StubTelegramHTTPTransport(status: 200, body: Data(#"""
        {"ok":true,"result":{"id":123456,"is_bot":true,"first_name":"ZenCODE","username":"zencode_bot","has_topics_enabled":true,"allows_users_to_create_topics":false}}
        """#.utf8))
        let client = TerminalTelegramAPIClient(token: "123456:ABCDEF", transport: transport)

        let bot = try await client.getMe()

        #expect(bot.id == 123456)
        #expect(bot.isBot == true)
        #expect(bot.username == "zencode_bot")
        #expect(bot.hasTopicsEnabled == true)
        #expect(bot.allowsUsersToCreateTopics == false)
        #expect(Mirror(reflecting: bot).children.map(\.label) == [
            "id", "isBot", "username", "hasTopicsEnabled", "allowsUsersToCreateTopics",
        ])
    }

    /// Changed on purpose by the topic runtime (plan 4, point 3). The point-1
    /// characterization pinned that a native draft never carried
    /// `message_thread_id`. Now the key is present only when a topic is given.
    /// Without one the body keeps exactly the pre-topic keys, including the
    /// default `can_stop: true` and `keep_on_stop: true`, so the legacy route's
    /// wire does not change.
    @Test
    func sendMessageDraftCarriesMessageThreadIDOnlyWithATopic() async throws {
        let transport = DraftRecordingTelegramTransport()
        let client = TerminalTelegramAPIClient(token: "123456:ABCDEF", transport: transport)

        try await client.sendMessageDraft("streaming", to: 42, draftID: 7)
        try await client.sendMessageDraft("streaming", to: 42, messageThreadID: 5, draftID: 7)

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["sendMessageDraft", "sendMessageDraft"])
        let legacy = try Self.jsonObject(requests.first?.body)
        #expect(Set(legacy.keys) == ["chat_id", "draft_id", "text", "can_stop", "keep_on_stop"])
        #expect(legacy["chat_id"] as? Int == 42)
        #expect(legacy["draft_id"] as? Int == 7)
        #expect(legacy["text"] as? String == "streaming")
        #expect(legacy["can_stop"] as? Bool == true)
        #expect(legacy["keep_on_stop"] as? Bool == true)
        let topic = try Self.jsonObject(requests.last?.body)
        #expect(Set(topic.keys) == Set(legacy.keys).union(["message_thread_id"]))
        #expect(topic["message_thread_id"] as? Int == 5)
    }

    /// `createForumTopic` (Bot API 9.4, private chat) sends only `chat_id` and
    /// `name` and decodes the returned `ForumTopic`. `editForumTopic` sends
    /// only the name, so the topic icon is kept.
    @Test
    func forumTopicRequestsUseBotAPIWireShapes() async throws {
        let transport = DraftRecordingTelegramTransport()
        let client = TerminalTelegramAPIClient(token: "123456:ABCDEF", transport: transport)

        let topic = try await client.createForumTopic(chatID: 42, name: "  ZenCODE · main \n")
        try await client.editForumTopic(chatID: 42, messageThreadID: 77, name: "ZenCODE · review")

        #expect(topic == TerminalTelegramForumTopic(messageThreadID: 77, name: "ZenCODE · main"))
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["createForumTopic", "editForumTopic"])
        let create = try Self.jsonObject(requests.first?.body)
        #expect(Set(create.keys) == ["chat_id", "name"])
        #expect(create["chat_id"] as? Int == 42)
        #expect(create["name"] as? String == "ZenCODE · main")
        let edit = try Self.jsonObject(requests.last?.body)
        #expect(Set(edit.keys) == ["chat_id", "message_thread_id", "name"])
        #expect(edit["message_thread_id"] as? Int == 77)
        #expect(edit["name"] as? String == "ZenCODE · review")
    }

    private static func jsonObject(_ body: Data?) throws -> [String: Any] {
        let data = try #require(body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: some Encodable) {
        encodeValue = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

/// Records the method and body of every request. It answers
/// `createForumTopic` with a `ForumTopic` and every other method with the
/// boolean result that `sendMessageDraft` and `editForumTopic` decode.
private actor DraftRecordingTelegramTransport: TelegramHTTPTransport {
    private(set) var requests: [(method: String, body: Data?)] = []

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        requests.append((method: url.lastPathComponent, body: body))
        if url.lastPathComponent == "createForumTopic" {
            return (200, Data(#"{"ok":true,"result":{"message_thread_id":77,"name":"ZenCODE · main","icon_color":7322096}}"#.utf8))
        }
        return (200, Data(#"{"ok":true,"result":true}"#.utf8))
    }
}
