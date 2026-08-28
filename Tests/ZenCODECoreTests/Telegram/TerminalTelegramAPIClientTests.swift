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

    /// An ordinary message carries no reply link, so a normal prompt keeps its
    /// existing meaning.
    @Test
    func messageWithoutReplyHasNoReferencedIdentifier() throws {
        let update = try JSONDecoder().decode(
            TerminalTelegramAPIResponse<[TerminalTelegramUpdate]>.self,
            from: Data("""
            {
              "ok": true,
              "result": [{
                "update_id": 8,
                "message": {
                  "message_id": 22,
                  "from": { "id": 42, "is_bot": false },
                  "chat": { "id": 42, "type": "private" },
                  "text": "plain prompt"
                }
              }]
            }
            """.utf8)
        )

        #expect(update.result?.first?.message?.replyToMessage?.messageID == nil)
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

    @Test
    func telegramAudioBudgetIsExplicit() {
        #expect(TerminalTelegramAPIClient.maximumAudioFileBytes == 20 * 1_024 * 1_024)
        #expect(TerminalTelegramAPIClient.audioDownloadTimeout == .seconds(30))
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
    func oversizedFirstGraphemeUsesANonemptyWireSafeReplacement() {
        let oversizedCluster = "a" + String(repeating: "\u{0301}", count: 4_100)
        let bounded = TerminalTelegramAPIClient.boundedMessageText(oversizedCluster)

        #expect(oversizedCluster.count == 1)
        #expect(bounded == "…")
        #expect(bounded.utf16.count <= TerminalTelegramAPIClient.maximumMessageUTF16Length)
    }

    /// Ordinary text is only trimmed: the bound must not rewrite payloads that
    /// already fit.
    @Test
    func shortTextIsOnlyTrimmed() {
        #expect(TerminalTelegramAPIClient.boundedMessageText("  hello  ") == "hello")
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
