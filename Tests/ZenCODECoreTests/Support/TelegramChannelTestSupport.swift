//
//  TelegramChannelTestSupport.swift
//  ZenCODE
//
//  Shared fixtures of the suites that drive a ``TelegramChannel`` directly,
//  as the slot's channel of a terminal whose output is captured: a UUID
//  support directory with paired settings, a Bot API double routed by method
//  (topics, drafts, failures), a recorder of the texts the channel presents on
//  the primary channel, and a few readers of what the terminal writes. Nothing
//  reaches the network.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

enum TelegramChannelTestSupport {
    static let pairedSettings = AgentTelegramSettingsManifest(
        enabled: true, botToken: "123456:ABCDEF", linkedChatID: 42,
        linkedChatTitle: "Test", ownerUserID: 7, routes: [.init(roomID: "default")]
    )

    static let defaultRouteKey = TerminalTelegramRouteKey(
        chatID: 42, userID: 7, roomID: "default"
    )

    static let unauthorizedBody = Data(
        #"{"ok":false,"error_code":401,"description":"Unauthorized"}"#.utf8
    )

    static func getMeBody(botID: Int64) -> Data {
        Data(#"{"ok":true,"result":{"id":\#(botID),"is_bot":true,"first_name":"ZenCODE","username":"zencode_bot"}}"#.utf8)
    }

    /// deleteWebhook succeeds and getMe is rejected, so `start()` fails
    /// before polling.
    static func unauthorizedGetMeTransport() -> ScriptedTelegramTransport {
        ScriptedTelegramTransport(responses: [
            (200, Data(#"{"ok":true,"result":true}"#.utf8)),
            (401, unauthorizedBody),
        ])
    }

    /// A bot id no other test uses, so the process-wide registry of attached
    /// channels never mixes two tests.
    static func uniqueBotID() -> Int64 {
        Int64.random(in: 40_000_001...49_000_000)
    }

    /// Runs `body` on the chat-session actor with a fresh support directory
    /// holding `telegram` (and `voice`) as its settings, then removes the
    /// directory.
    static func withSupport(
        telegram: AgentTelegramSettingsManifest? = pairedSettings,
        voice: AgentVoiceSettingsManifest? = nil,
        _ body: @escaping @Sendable @ChatSessionActor () async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zencode-telegram-channel-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(models: [], telegram: telegram, voice: voice),
            to: directory.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        )
        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            try await Task(name: "ZenCODE.Tests.telegram-channel-support") { @ChatSessionActor in
                try await body()
            }.value
        }
    }

    /// A terminal chat whose Telegram channels use `transport` on the host's
    /// dispatcher, whose writes are captured instead of reaching the real
    /// terminal, and which reads its interactive-only Telegram commands.
    /// `hostedModelID` and `availableModels` are the models the host supplies;
    /// without `stdinIsTerminal` the terminal host asks nothing (the folder
    /// of a switched agent is trusted without a prompt).
    @ChatSessionActor
    static func makeTerminal(
        transport: any TelegramHTTPTransport,
        permissionAuthorizer: LocalExecPermissionAuthorizer? = nil,
        sessionRunner: AgentCoreSessionRunner? = nil,
        workingDirectory: URL = URL(fileURLWithPath: "/tmp/project", isDirectory: true),
        hostedModelID: String = "remote-community/test",
        availableModels: [AgentSettingsModelManifest] = [],
        stdinIsTerminal: Bool = true
    ) throws -> TerminalChat {
        TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: hostedModelID,
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: availableModels,
                workingDirectory: workingDirectory
            ),
            stdinIsTerminal: stdinIsTerminal,
            sessionRunner: sessionRunner ?? AgentCoreSessionRunner(taskGraphStore: nil),
            permissionAuthorizer: permissionAuthorizer,
            telegramTransportFactory: { transport },
            renderCoordinator: TerminalChatRenderCoordinator(
                stdinIsTerminal: false,
                standardOutput: nil,
                standardError: nil,
                standardOutputIsTerminal: false,
                standardErrorIsTerminal: false,
                cursorTopology: .separate,
                capturesWrites: true,
                streamingFlushDelay: nil,
                columnWidthProvider: { 100 }
            )
        )
    }

    /// What `terminal` writes while `operation` runs, one entry per write.
    @ChatSessionActor
    static func capturing(
        _ terminal: TerminalChat,
        _ operation: () async -> Void
    ) async -> [String] {
        terminal.capturedCommandOutputForTesting = []
        await operation()
        let writes = terminal.capturedCommandOutputForTesting ?? []
        terminal.capturedCommandOutputForTesting = nil
        return writes
    }

    /// Stands in for the interactive input loop of `terminal`, which
    /// `/telegram on` needs (``TerminalChat/loopEventQueue``), for a test that
    /// drives the commands directly. Nothing reads the queue: a test that
    /// adopts a turn runs the real loop instead.
    @ChatSessionActor
    static func standInForInteractiveLoop(of terminal: TerminalChat) {
        terminal.loopEventQueue = TerminalChatEventQueue()
    }

    /// Polls `condition` for up to five seconds.
    @ChatSessionActor
    static func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 where !(await condition()) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A notice the channel presented on the primary channel.
struct TelegramChannelNotice: Equatable, Sendable {
    let text: String
    let channel: ChatSessionNoticeChannel
}

/// Records what a channel presents through its ``TelegramChannel/noticeSink``.
@ChatSessionActor
final class TelegramChannelNoticeRecorder {
    private(set) var notices: [TelegramChannelNotice] = []

    init() {}

    var texts: [String] {
        notices.map(\.text)
    }

    func clear() {
        notices = []
    }

    /// Makes this recorder the sink of `channel`.
    func install(on channel: TelegramChannel) {
        channel.noticeSink = { [weak self] text, noticeChannel in
            self?.notices.append(TelegramChannelNotice(text: text, channel: noticeChannel))
        }
    }
}

/// A text sent to a Telegram chat, with its topic.
struct TelegramRoutedText: Equatable, Sendable {
    let text: String
    let topicID: Int?
}

/// Values appended from `@Sendable` seams, read back by the test.
final class TelegramTestRecorder<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    func append(_ element: Element) {
        storage.withLock { $0.append(element) }
    }

    var values: [Element] {
        storage.withLock { $0 }
    }
}

/// A Bot API double routed by method: getMe reports `botID` and, when asked,
/// Threaded mode (`has_topics_enabled`), getUpdates waits until it is
/// cancelled, sendMessage records its text and its topic (or fails while
/// `sendMessageFails`), sendRichMessageDraft records its `can_stop`,
/// createForumTopic answers with the next of `createdTopicIDs` (and fails
/// once they are used up), and editForumTopic records the rename (or fails
/// with `renameTopicFails`).
actor TelegramChannelTestTransport: TelegramHTTPTransport {
    /// The description of a failed `createForumTopic`.
    static let createTopicFailure = "Bad Request: not enough rights to create a topic"
    /// The description of a failed `editForumTopic`.
    static let renameTopicFailure = "Bad Request: not enough rights to manage topics"

    let botID: Int64
    private let sendMessageFails: Bool
    private let hasTopicsEnabled: Bool
    private var createdTopicIDs: [Int]
    private var renameTopicFails: Bool
    private var getMeFails = false
    private(set) var requestCount = 0
    private(set) var sentTexts: [String] = []
    private(set) var sentBodies: [String] = []
    private(set) var sentMessages: [TelegramRoutedText] = []
    private(set) var createdTopicNames: [String] = []
    private(set) var renamedTopics: [TelegramRoutedText] = []
    private var draftCanStops: [Bool] = []
    private var draftWaiters: [CheckedContinuation<Bool, Never>] = []

    init(
        botID: Int64,
        sendMessageFails: Bool = false,
        hasTopicsEnabled: Bool = false,
        createdTopicIDs: [Int] = [],
        renameTopicFails: Bool = false
    ) {
        self.botID = botID
        self.sendMessageFails = sendMessageFails
        self.hasTopicsEnabled = hasTopicsEnabled
        self.createdTopicIDs = createdTopicIDs
        self.renameTopicFails = renameTopicFails
    }

    func setGetMeFails(_ fails: Bool) {
        getMeFails = fails
    }

    func setRenameTopicFails(_ fails: Bool) {
        renameTopicFails = fails
    }

    /// The topic requests sent so far: creations and renames.
    var topicRequestCount: Int {
        createdTopicNames.count + renamedTopics.count
    }

    /// The `can_stop` of the first streamed draft, once one is sent.
    func firstDraftCanStop() async -> Bool {
        if let first = draftCanStops.first {
            return first
        }
        return await withCheckedContinuation { draftWaiters.append($0) }
    }

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        requestCount += 1
        switch url.lastPathComponent {
        case "getMe":
            guard !getMeFails else {
                return (401, TelegramChannelTestSupport.unauthorizedBody)
            }
            let topics = hasTopicsEnabled ? #","has_topics_enabled":true"# : ""
            return (200, Data(
                #"{"ok":true,"result":{"id":\#(botID),"is_bot":true,"first_name":"ZenCODE","username":"zencode_bot"\#(topics)}}"#.utf8
            ))
        case "getUpdates":
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        case "sendMessage":
            guard !sendMessageFails else {
                return (400, Data(#"{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}"#.utf8))
            }
            let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            sentTexts.append(object?["text"] as? String ?? "")
            sentBodies.append(body.map { String(decoding: $0, as: UTF8.self) } ?? "")
            sentMessages.append(TelegramRoutedText(
                text: object?["text"] as? String ?? "",
                topicID: object?["message_thread_id"] as? Int
            ))
            return (200, Data(#"{"ok":true,"result":{"message_id":9,"chat":{"id":42,"type":"private"},"date":0}}"#.utf8))
        case "createForumTopic":
            let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let name = object?["name"] as? String ?? ""
            createdTopicNames.append(name)
            guard !createdTopicIDs.isEmpty else {
                return (400, Data(#"{"ok":false,"error_code":400,"description":"\#(Self.createTopicFailure)"}"#.utf8))
            }
            let topic: [String: Any] = [
                "message_thread_id": createdTopicIDs.removeFirst(), "name": name, "icon_color": 7_322_096,
            ]
            let result = try JSONSerialization.data(withJSONObject: ["ok": true, "result": topic])
            return (200, result)
        case "editForumTopic":
            let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            renamedTopics.append(TelegramRoutedText(
                text: object?["name"] as? String ?? "",
                topicID: object?["message_thread_id"] as? Int
            ))
            guard !renameTopicFails else {
                return (400, Data(#"{"ok":false,"error_code":400,"description":"\#(Self.renameTopicFailure)"}"#.utf8))
            }
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        case "sendRichMessageDraft":
            let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let canStop = object?["can_stop"] as? Bool ?? true
            draftCanStops.append(canStop)
            let waiters = draftWaiters
            draftWaiters = []
            for waiter in waiters {
                waiter.resume(returning: canStop)
            }
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        default:
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        }
    }
}
