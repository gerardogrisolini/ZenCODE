//
//  TerminalTelegramAPIClientTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalTelegramAPIClientTests {
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
            TerminalTelegramSendMessageRequest(chatID: 42, text: "hello", parseMode: "MarkdownV2"),
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
