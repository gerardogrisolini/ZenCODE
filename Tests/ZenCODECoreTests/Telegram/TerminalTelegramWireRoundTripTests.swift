//
//  TerminalTelegramWireRoundTripTests.swift
//  ZenCODE
//
//  Wire-level bidirectional coverage of the Telegram client: an update polled
//  from `getUpdates` must decode into the message the ingress consumes, and the
//  answer must leave as a well-formed `sendMessage` request whose receipt is
//  returned to the caller. The HTTP transport is faked, so no network is used.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

private struct RecordedTelegramRequest: Sendable {
    let url: URL
    let method: String
    let body: Data?

    var apiMethod: String {
        url.lastPathComponent
    }

    var jsonBody: [String: Any] {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

private final class TelegramRequestRecorder: Sendable {
    private let storage = Mutex<[RecordedTelegramRequest]>([])

    func record(_ request: RecordedTelegramRequest) {
        storage.withLock { $0.append(request) }
    }

    func requests() -> [RecordedTelegramRequest] {
        storage.withLock { $0 }
    }
}

/// Replays canned Telegram responses keyed by API method and records every
/// outgoing request in order.
private struct FakeTelegramTransport: TelegramHTTPTransport {
    let responses: [String: String]
    let recorder: TelegramRequestRecorder

    func send(
        url: URL,
        method: String,
        headers _: [RemoteHTTPHeader],
        body: Data?,
        timeout _: Duration?
    ) async throws -> (status: Int, body: Data) {
        recorder.record(
            RecordedTelegramRequest(url: url, method: method, body: body)
        )
        guard let payload = responses[url.lastPathComponent] else {
            return (404, Data(#"{"ok":false,"description":"not found"}"#.utf8))
        }
        return (200, Data(payload.utf8))
    }
}

@Suite
struct TerminalTelegramWireRoundTripTests {
    private static let updatesPayload = """
    {
      "ok": true,
      "result": [{
        "update_id": 501,
        "message": {
          "message_id": 88,
          "from": { "id": 7, "is_bot": false, "username": "gerardo" },
          "chat": { "id": 42, "type": "private", "first_name": "Gerardo" },
          "text": "ciao ZenCODE"
        }
      }]
    }
    """

    private static let sendPayload = """
    {
      "ok": true,
      "result": {
        "message_id": 89,
        "chat": { "id": 42, "type": "private" },
        "text": "risposta"
      }
    }
    """

    /// Receive then answer over the same client: the polled update decodes into
    /// the incoming message the ingress builds on, and the reply is posted to
    /// the very chat that sent it.
    @Test
    func polledUpdateIsAnsweredOnTheSameChat() async throws {
        let recorder = TelegramRequestRecorder()
        let client = TerminalTelegramAPIClient(
            token: "123456:ABCDEF",
            transport: FakeTelegramTransport(
                responses: [
                    "getUpdates": Self.updatesPayload,
                    "sendMessage": Self.sendPayload
                ],
                recorder: recorder
            )
        )

        // Inbound.
        let updates = try await client.getUpdates(offset: 500, timeout: 30)
        let update = try #require(updates.first)
        let message = try #require(update.message)
        #expect(update.updateID == 501)
        #expect(message.chat.id == 42)
        #expect(message.text == "ciao ZenCODE")
        #expect(message.from?.isBot == false)

        // Outbound, addressed to the chat the message came from.
        let receipt = try await client.sendMessage(
            "risposta",
            to: message.chat.id,
            parseMode: "Markdown"
        )
        #expect(receipt == 89)

        let requests = recorder.requests()
        #expect(requests.map(\.apiMethod) == ["getUpdates", "sendMessage"])
        #expect(requests.allSatisfy { $0.method == "POST" })
        // The poll advances the offset so an update is never replayed.
        #expect(requests[0].jsonBody["offset"] as? Int == 500)
        #expect(requests[0].jsonBody["allowed_updates"] as? [String] == [
            "message", "callback_query", "stopped_message_generation",
        ])
        #expect(requests[1].jsonBody["chat_id"] as? Int == 42)
        #expect(requests[1].jsonBody["text"] as? String == "risposta")
        #expect(requests[1].jsonBody["parse_mode"] as? String == "Markdown")
    }

    /// A Telegram failure must surface as an error instead of being reported as
    /// a delivered reply.
    @Test
    func rejectedSendIsReportedAsAFailure() async {
        let recorder = TelegramRequestRecorder()
        let client = TerminalTelegramAPIClient(
            token: "123456:ABCDEF",
            transport: FakeTelegramTransport(responses: [:], recorder: recorder)
        )

        await #expect(throws: (any Error).self) {
            try await client.sendMessage("risposta", to: 42)
        }
        #expect(recorder.requests().count == 1)
    }
}
