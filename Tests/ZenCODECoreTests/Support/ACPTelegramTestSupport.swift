//
//  ACPTelegramTestSupport.swift
//  ZenCODE
//
//  Shared fixtures of the tests that link ACP sessions to Telegram: a support
//  directory of their own with paired settings, a scripted Bot API, a scripted
//  model backend that can write a file or ask a permission, and an ACP wire
//  recorder. Nothing reaches the network.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

// MARK: - Settings

enum ACPTelegramTestSupport {
    static let linkedChatID: Int64 = 42
    static let ownerUserID: Int64 = 7
    static let linkedChatTitle = "Test"

    /// Paired settings: chat 42 of owner 7, with the shared route only.
    static func pairedSettings(
        routes: [AgentTelegramRouteManifest] = [.init(roomID: "default")]
    ) -> AgentTelegramSettingsManifest {
        AgentTelegramSettingsManifest(
            enabled: true,
            botToken: "123456:ABCDEF",
            linkedChatID: linkedChatID,
            linkedChatTitle: linkedChatTitle,
            ownerUserID: ownerUserID,
            routes: routes
        )
    }

    /// Runs `body` in a fresh UUID support directory whose settings hold
    /// `telegram` (none when `nil`), then removes the directory.
    static func withSupportDirectory(
        telegram: AgentTelegramSettingsManifest? = pairedSettings(),
        _ body: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-telegram-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppStorageDirectory.withSupportDirectoryURL(root) {
            if let telegram {
                try AgentSettingsManifestStore.save(AgentSettingsManifest(models: [], telegram: telegram))
            }
            try await body(root)
        }
    }

    /// A bot id no other test uses, so the process-wide registry of attached
    /// channels never mixes two tests.
    static func uniqueBotID() -> Int64 {
        Int64.random(in: 30_000_001...39_000_000)
    }

    /// Polls `predicate` every 10 ms for up to `timeout`; `true` once it holds.
    @discardableResult
    static func waitUntil(
        timeout: Duration = .seconds(30),
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }
}

// MARK: - Bot API

/// A message the scripted Bot API received: the method, its text (for
/// `sendRichMessage` every text of the rendered document, concatenated), and
/// its topic.
struct ACPTelegramSentMessage: Equatable, Sendable {
    let method: String
    let text: String
    let topicID: Int?
    /// The request body as sent, for diagnostics; not compared.
    var rawBody: String = ""

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.method == rhs.method && lhs.text == rhs.text && lhs.topicID == rhs.topicID
    }
}

/// A Bot API double routed by method, for one bot. getMe reports `botID`
/// (in Threaded mode when `hasTopicsEnabled`), or fails while `getMeFails`;
/// getUpdates returns the messages and button presses
/// ``deliver(_:topicID:)`` and ``deliverCallbackQuery(_:)`` queued and
/// otherwise waits until it is cancelled, counting how many polls run at
/// once; sendMessage and sendRichMessage are recorded, and while
/// ``holdSends(containing:)`` is on one whose text contains its marker waits
/// for ``releaseSends()`` before it is recorded; createForumTopic answers
/// the next of `createdTopicIDs`; every other method succeeds.
actor ACPTelegramScriptedTransport: TelegramHTTPTransport {
    let botID: Int64
    private let hasTopicsEnabled: Bool
    private var createdTopicIDs: [Int]
    private var getMeFails = false
    private var pendingUpdates: [String] = []
    private var nextUpdateID = 1
    private var nextMessageID = 100
    private(set) var sentMessages: [ACPTelegramSentMessage] = []
    private var runningPolls = 0
    /// The most `getUpdates` that ever ran at once: Telegram answers HTTP 409
    /// to a second concurrent long poll on one bot.
    private(set) var maximumConcurrentPolls = 0
    private(set) var pollCount = 0
    private var heldSendMarker: String?
    private var heldSends: [CheckedContinuation<Void, Never>] = []
    private var heldSendWaiters: [CheckedContinuation<Void, Never>] = []

    init(botID: Int64, hasTopicsEnabled: Bool = false, createdTopicIDs: [Int] = []) {
        self.botID = botID
        self.hasTopicsEnabled = hasTopicsEnabled
        self.createdTopicIDs = createdTopicIDs
    }

    func setGetMeFails(_ fails: Bool) {
        getMeFails = fails
    }

    /// From now on a sendMessage or sendRichMessage whose text contains
    /// `marker` waits for ``releaseSends()`` before it is recorded and
    /// answered, so a test can keep a reporter's flush in flight.
    func holdSends(containing marker: String) {
        heldSendMarker = marker
    }

    /// Lets every held send go on, in order; later ones no longer wait.
    func releaseSends() {
        heldSendMarker = nil
        let held = heldSends
        heldSends = []
        for continuation in held {
            continuation.resume()
        }
    }

    /// Returns once a send waits at the gate of ``holdSends(containing:)``.
    func waitUntilASendIsHeld() async {
        guard heldSends.isEmpty else { return }
        await withCheckedContinuation { heldSendWaiters.append($0) }
    }

    var runningPollCount: Int {
        runningPolls
    }

    /// The texts sent so far, in order.
    var sentTexts: [String] {
        sentMessages.map(\.text)
    }

    /// Queues a text of the owner in the linked chat, in `topicID` (the chat
    /// itself, or General in Threaded mode, when `nil`), for the next poll.
    func deliver(_ text: String, topicID: Int? = nil) throws {
        var message: [String: Any] = [
            "message_id": nextMessageID,
            "from": ["id": ACPTelegramTestSupport.ownerUserID, "is_bot": false, "first_name": "Owner", "username": "owner"],
            "chat": ["id": ACPTelegramTestSupport.linkedChatID, "type": "private", "first_name": "Owner"],
            "date": 1,
            "text": text,
        ]
        if let topicID {
            message["message_thread_id"] = topicID
        }
        nextMessageID += 1
        let update: [String: Any] = ["update_id": nextUpdateID, "message": message]
        nextUpdateID += 1
        let data = try JSONSerialization.data(withJSONObject: update)
        pendingUpdates.append(String(decoding: data, as: UTF8.self))
    }

    /// Queues a press of the owner on a button carrying `data`, on a message
    /// of the linked chat, for the next poll.
    func deliverCallbackQuery(_ data: String) throws {
        let callback: [String: Any] = [
            "id": "callback-\(nextUpdateID)",
            "from": ["id": ACPTelegramTestSupport.ownerUserID, "is_bot": false, "first_name": "Owner"],
            "data": data,
            "message": [
                "message_id": nextMessageID,
                "chat": ["id": ACPTelegramTestSupport.linkedChatID, "type": "private"],
            ] as [String: Any],
        ]
        nextMessageID += 1
        let update: [String: Any] = ["update_id": nextUpdateID, "callback_query": callback]
        nextUpdateID += 1
        let encoded = try JSONSerialization.data(withJSONObject: update)
        pendingUpdates.append(String(decoding: encoded, as: UTF8.self))
    }

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        switch url.lastPathComponent {
        case "getMe":
            guard !getMeFails else {
                return (401, Data(#"{"ok":false,"error_code":401,"description":"Unauthorized"}"#.utf8))
            }
            let topics = hasTopicsEnabled ? #","has_topics_enabled":true"# : ""
            return (200, Data(
                #"{"ok":true,"result":{"id":\#(botID),"is_bot":true,"first_name":"ZenCODE","username":"zencode_bot"\#(topics)}}"#.utf8
            ))
        case "getUpdates":
            pollCount += 1
            runningPolls += 1
            maximumConcurrentPolls = max(maximumConcurrentPolls, runningPolls)
            defer { runningPolls -= 1 }
            while pendingUpdates.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            let updates = pendingUpdates
            pendingUpdates = []
            return (200, Data(#"{"ok":true,"result":[\#(updates.joined(separator: ","))]}"#.utf8))
        case "sendMessage", "sendRichMessage":
            let rawBody = body.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let richText = Self.richText(of: object)
            let text = url.lastPathComponent == "sendMessage"
                ? object?["text"] as? String ?? ""
                : richText.isEmpty ? rawBody : richText
            if let marker = heldSendMarker, text.contains(marker) {
                await withCheckedContinuation { continuation in
                    heldSends.append(continuation)
                    let waiters = heldSendWaiters
                    heldSendWaiters = []
                    for waiter in waiters {
                        waiter.resume()
                    }
                }
            }
            sentMessages.append(ACPTelegramSentMessage(
                method: url.lastPathComponent,
                text: text,
                topicID: object?["message_thread_id"] as? Int,
                rawBody: rawBody
            ))
            nextMessageID += 1
            return (200, Data(
                #"{"ok":true,"result":{"message_id":\#(nextMessageID),"chat":{"id":42,"type":"private"},"date":0}}"#.utf8
            ))
        case "createForumTopic":
            guard !createdTopicIDs.isEmpty else {
                return (400, Data(#"{"ok":false,"error_code":400,"description":"Bad Request: no topic left"}"#.utf8))
            }
            let topic: [String: Any] = [
                "message_thread_id": createdTopicIDs.removeFirst(),
                "name": object?["name"] as? String ?? "",
            ]
            return (200, try JSONSerialization.data(withJSONObject: ["ok": true, "result": topic]))
        default:
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        }
    }

    /// The text of a rich message: the text of each block, blocks separated
    /// by a newline.
    private static func richText(of object: [String: Any]?) -> String {
        guard let richMessage = object?["rich_message"] as? [String: Any],
              let blocks = richMessage["blocks"] as? [Any] else {
            return texts(in: object as Any).joined()
        }
        return blocks.map { texts(in: $0).joined() }.joined(separator: "\n")
    }

    /// Every string of a decoded rich message held under a `text` key (a
    /// string, or an array of strings and styled runs), in document order; a
    /// table gives its rows one per line with their cells joined by ` | `, and
    /// a divider gives `———`.
    private static func texts(in value: Any) -> [String] {
        if let object = value as? [String: Any] {
            if let rows = object["cells"] as? [[Any]] {
                return [rows.map { row in row.map { texts(in: $0).joined() }.joined(separator: " | ") }
                    .joined(separator: "\n")]
            }
            if object["type"] as? String == "divider" {
                return ["———"]
            }
            return object.keys.sorted().flatMap { key -> [String] in
                key == "text" ? flattenedText(object[key] as Any) : texts(in: object[key] as Any)
            }
        }
        if let array = value as? [Any] {
            return array.flatMap { texts(in: $0) }
        }
        return []
    }

    private static func flattenedText(_ value: Any) -> [String] {
        if let text = value as? String {
            return [text]
        }
        if let array = value as? [Any] {
            return array.flatMap { flattenedText($0) }
        }
        return texts(in: value)
    }

    /// Waits until a sent text satisfies `predicate` and returns it.
    func waitForSentMessage(
        timeout: Duration = .seconds(30),
        where predicate: @Sendable (ACPTelegramSentMessage) -> Bool
    ) async -> ACPTelegramSentMessage? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let match = sentMessages.first(where: predicate) {
                return match
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return sentMessages.first(where: predicate)
    }
}
