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
        timeout: Duration = .seconds(10),
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
    /// string, or an array of strings and styled runs), in document order.
    private static func texts(in value: Any) -> [String] {
        if let object = value as? [String: Any] {
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
        timeout: Duration = .seconds(10),
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

// MARK: - Model backend

/// A model backend whose prompts follow the script of ``enqueue(_:)``, one
/// list of steps per prompt; a prompt without a script answers `reply`. It
/// keeps the history of every session, so the runner's snapshot (and ACP's
/// `session/load` replay) carries the turns it ran, and records the system
/// prompt and the tool grant of every session write, so a test can tell how
/// a turn was composed. The runtime's authorization handler is captured
/// from the configuration the backend factory receives (see ``factory``).
actor ACPTelegramScriptedBackend: AgentRuntimeBackend {
    enum Step: Sendable {
        /// Streams `text` as model content.
        case reply(String)
        /// Waits until ``release()`` lets the prompt go on.
        case pause
        /// Writes `contents` to `path`, relative to the session's directory,
        /// through a reported `local.writeFile` tool call.
        case writeFile(path: String, contents: String)
        /// Asks permission to run `command` with `local.exec`, as a gated
        /// tool call would, and records the decision; a prompt cancelled
        /// while it waited ends there, as a model turn does.
        case askPermission(command: String)
        /// Reads `path`, relative to the session's directory, through the text
        /// file system the turn runs in (``ClientTextFileSystem/current``) and
        /// records what it saw in ``clientFileAccesses``; without one, from
        /// the disk.
        case readClientFile(path: String)
        /// Writes `contents` to `path`, relative to the session's directory,
        /// through the text file system the turn runs in, as the file tools
        /// do, and records it in ``clientFileAccesses``; without one, to the
        /// disk.
        case writeClientFile(path: String, contents: String)
    }

    /// A file access a turn made through ``Step/readClientFile(path:)`` or
    /// ``Step/writeClientFile(path:contents:)``: whether the turn ran inside a
    /// client text file system, and what a read returned.
    struct ClientFileAccess: Equatable, Sendable {
        let hadClientFileSystem: Bool
        let readContents: String?
    }

    /// A session write the backend received: the system prompt and the
    /// tool grant of a `createSession`, `createSessionIfNeeded`, or
    /// `updateSessionOptions`.
    struct SessionWrite: Equatable, Sendable {
        let systemPrompt: String?
        let allowedToolNames: Set<String>?
    }

    private let authorization = Mutex<AgentToolAuthorizationHandler?>(nil)
    private var scripts: [[Step]] = []
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private(set) var prompts: [String] = []
    private(set) var permissionDecisions: [Bool] = []
    private(set) var sessionWrites: [SessionWrite] = []
    private(set) var clientFileAccesses: [ClientFileAccess] = []
    private var permissionAskCount = 0
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var pausedCount = 0
    private var releasedCount = 0

    /// The backend factory of a bridge using this backend.
    nonisolated var factory: AgentRuntimeBackendFactory {
        { [self] configuration, _ in
            authorization.withLock { $0 = configuration.toolAuthorizationHandler }
            return self
        }
    }

    func enqueue(_ steps: [Step]) {
        scripts.append(steps)
    }

    /// How many permissions were asked so far, answered or not.
    var askedPermissionCount: Int {
        permissionAskCount
    }

    /// Whether a prompt waits at a `.pause` step.
    var isPaused: Bool {
        pausedCount > releasedCount
    }

    /// Lets the prompt waiting at a `.pause` step go on.
    func release() {
        releasedCount += 1
        if !pauseWaiters.isEmpty {
            pauseWaiters.removeFirst().resume()
        }
    }

    func createSession(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {
        sessionWrites.append(SessionWrite(systemPrompt: systemPrompt, allowedToolNames: allowedToolNames))
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id, modelID: "test-model", workingDirectoryPath: cwd,
            systemPrompt: systemPrompt, cacheKey: cacheKey, history: history,
            allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func createSessionIfNeeded(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {
        guard sessions[id] == nil else {
            sessionWrites.append(SessionWrite(systemPrompt: systemPrompt, allowedToolNames: allowedToolNames))
            return
        }
        createSession(
            id: id, cwd: cwd, systemPrompt: systemPrompt, history: history, cacheKey: cacheKey,
            allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String, systemPrompt: String?, allowedToolNames: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?, preserveThinking _: Bool
    ) {
        sessionWrites.append(SessionWrite(systemPrompt: systemPrompt, allowedToolNames: allowedToolNames))
    }

    func closeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        let steps = scripts.isEmpty ? [.reply("reply")] : scripts.removeFirst()
        let directory = URL(fileURLWithPath: sessions[sessionID]?.workingDirectoryPath ?? FileManager.default.currentDirectoryPath)
        var text = ""
        for (index, step) in steps.enumerated() {
            switch step {
            case let .reply(reply):
                text += reply
                await onEvent(.content(reply))
            case .pause:
                pausedCount += 1
                if releasedCount < pausedCount {
                    await withCheckedContinuation { pauseWaiters.append($0) }
                }
                try Task.checkCancellation()
            case let .writeFile(path, contents):
                let write = DirectAgentToolCall(
                    id: "write-\(index)",
                    name: "local.writeFile",
                    argumentsObject: ["path": path, "content": contents],
                    argumentsJSON: "{}"
                )
                await onEvent(.toolCallStarted(write))
                try Data(contents.utf8).write(to: directory.appendingPathComponent(path))
                await onEvent(.toolCallCompleted(write, DirectAgentToolResult(
                    output: "Wrote \(path)",
                    summary: "Wrote \(path)",
                    fileChanges: [OperationFileChange(path: path, oldText: nil, newText: contents)]
                )))
            case let .askPermission(command):
                permissionAskCount += 1
                let handler = authorization.withLock { $0 }
                let request = AgentToolAuthorizationRequest(
                    sessionID: sessionID,
                    toolCallID: "exec-\(index)",
                    toolName: "local.exec",
                    title: "Run \(command)",
                    kind: "execute",
                    command: command,
                    workingDirectory: directory.path
                )
                let approved = await handler?(request) ?? false
                permissionDecisions.append(approved)
                try Task.checkCancellation()
            case let .readClientFile(path):
                let url = directory.appendingPathComponent(path)
                let client = ClientTextFileSystem.current
                let contents: String?
                if let read = client?.read {
                    contents = try await read(url)
                } else {
                    contents = try? String(contentsOf: url, encoding: .utf8)
                }
                clientFileAccesses.append(ClientFileAccess(
                    hadClientFileSystem: client != nil, readContents: contents
                ))
            case let .writeClientFile(path, contents):
                let url = directory.appendingPathComponent(path)
                let client = ClientTextFileSystem.current
                if let write = client?.write {
                    try await write(url, contents)
                } else {
                    try Data(contents.utf8).write(to: url)
                }
                clientFileAccesses.append(ClientFileAccess(
                    hadClientFileSystem: client != nil, readContents: nil
                ))
            }
        }
        if let snapshot = sessions[sessionID] {
            sessions[sessionID] = AgentRuntimeSessionSnapshot(
                sessionID: snapshot.sessionID, modelID: snapshot.modelID,
                workingDirectoryPath: snapshot.workingDirectoryPath,
                systemPrompt: snapshot.systemPrompt, cacheKey: snapshot.cacheKey,
                history: snapshot.history + [
                    AgentRuntimeMessage(role: .user, content: prompt),
                    AgentRuntimeMessage(role: .assistant, content: text),
                ],
                allowedToolNames: snapshot.allowedToolNames,
                thinkingSelection: snapshot.thinkingSelection,
                preserveThinking: snapshot.preserveThinking
            )
        }
        return DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "test-model")
    }
}

// MARK: - ACP wire

/// Every JSON-RPC message the bridge wrote, in order.
final class ACPTelegramWire: Sendable {
    private let storage = Mutex<[JSONValue]>([])
    private let observer = Mutex<(@Sendable (JSONValue) -> Void)?>(nil)

    var sink: ACPWriter.Sink {
        { [self] data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                storage.withLock { $0.append(value) }
                let observe = observer.withLock { $0 }
                observe?(value)
            }
        }
    }

    /// Calls `handler` with every message written from now on, after it is
    /// recorded: the way a client double answers the bridge's requests.
    func observe(_ handler: @escaping @Sendable (JSONValue) -> Void) {
        observer.withLock { $0 = handler }
    }

    var messages: [[String: JSONValue]] {
        storage.withLock { $0.compactMap(\.objectValue) }
    }

    var count: Int {
        storage.withLock { $0.count }
    }

    /// The `session/update` payloads written from message `index` on.
    func sessionUpdates(from index: Int = 0) -> [[String: JSONValue]] {
        messages.dropFirst(index).compactMap { message in
            guard message["method"]?.acpStringValue == "session/update" else { return nil }
            return message["params"]?.objectValue?["update"]?.objectValue
        }
    }

    /// The texts of the `kind` updates written from message `index` on.
    func updateTexts(kind: String, from index: Int = 0) -> [String] {
        sessionUpdates(from: index).compactMap { update in
            guard update["sessionUpdate"]?.acpStringValue == kind else { return nil }
            return update["content"]?.objectValue?["text"]?.acpStringValue
        }
    }

    func response(id: Int) -> [String: JSONValue]? {
        messages.first { $0["id"] == .number(Double(id)) && $0["method"] == nil }
    }

    func stopReason(id: Int) -> String? {
        response(id: id)?["result"]?.objectValue?["stopReason"]?.acpStringValue
    }

    /// The message of the error response to request `id`, if any.
    func errorMessage(id: Int) -> String? {
        response(id: id)?["error"]?.objectValue?["message"]?.acpStringValue
    }

    /// The error responses written so far.
    var errorResponses: [[String: JSONValue]] {
        messages.filter { $0["error"] != nil }
    }

    /// The ids of the `session/request_permission` requests written so far.
    var permissionRequestIDs: [JSONValue] {
        messages.compactMap { message in
            guard message["method"]?.acpStringValue == "session/request_permission" else { return nil }
            return message["id"]
        }
    }
}

// MARK: - Client text file system

/// The editor's side of the ACP text file system: answers the bridge's
/// `fs/read_text_file` and `fs/write_text_file` requests from buffers it
/// keeps in memory, and records the paths it served. Nothing reaches the
/// disk. Files are keyed by their standardized absolute path.
final class ACPTelegramClientFiles: Sendable {
    private struct State {
        var buffers: [String: String]
        var readPaths: [String] = []
        var writtenPaths: [String] = []
        var sessionIDs: Set<String> = []
    }

    private let state: Mutex<State>

    init(buffers: [URL: String] = [:]) {
        state = Mutex(State(buffers: Dictionary(
            uniqueKeysWithValues: buffers.map { ($0.key.standardizedFileURL.path, $0.value) }
        )))
    }

    /// The paths read from the buffers, in order.
    var readPaths: [String] {
        state.withLock { $0.readPaths }
    }

    /// The paths written to the buffers, in order.
    var writtenPaths: [String] {
        state.withLock { $0.writtenPaths }
    }

    /// The sessions the requests named.
    var requestedSessionIDs: Set<String> {
        state.withLock { $0.sessionIDs }
    }

    /// The buffer of `url`.
    func buffer(at url: URL) -> String? {
        state.withLock { $0.buffers[url.standardizedFileURL.path] }
    }

    /// Answers the file system requests `wire` carries from now on to
    /// `writer`, the bridge's.
    func serve(wire: ACPTelegramWire, writer: ACPWriter) {
        wire.observe { [self] message in
            guard let reply = response(to: message) else { return }
            Task(name: "ACP Telegram client files") { await writer.handleResponse(reply) }
        }
    }

    private func response(to message: JSONValue) -> JSONValue? {
        guard let object = message.objectValue,
              let method = object["method"]?.acpStringValue, method.hasPrefix("fs/"),
              let id = object["id"], let params = object["params"]?.objectValue,
              let path = params["path"]?.acpStringValue else { return nil }
        let result: JSONValue? = state.withLock { state in
            if let sessionID = params["sessionId"]?.acpStringValue {
                state.sessionIDs.insert(sessionID)
            }
            switch method {
            case "fs/read_text_file":
                guard let text = state.buffers[path] else { return nil }
                state.readPaths.append(path)
                return .object(["content": .string(text)])
            case "fs/write_text_file":
                guard let text = params["content"]?.acpStringValue else { return nil }
                state.buffers[path] = text
                state.writtenPaths.append(path)
                return .null
            default:
                return nil
            }
        }
        if let result {
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        }
        return .object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .number(-32000), "message": .string("Client file unavailable")]),
        ])
    }
}

// MARK: - Bridge fixture

/// An ACP bridge whose sessions run on ``ACPTelegramScriptedBackend`` and
/// whose Telegram channels use `transport`.
struct ACPTelegramBridgeFixture {
    let bridge: ZenCODEACPBridge
    let backend: ACPTelegramScriptedBackend
    let wire: ACPTelegramWire
    let transport: ACPTelegramScriptedTransport
    let workingDirectory: URL

    /// A bridge with the sessions `sessionIDs` installed, in `root`, each
    /// with `selectedAgent` as its agent.
    static func make(
        root: URL,
        sessionIDs: [String],
        selectedAgent: AgentProfile? = nil,
        transport: ACPTelegramScriptedTransport
    ) async throws -> ACPTelegramBridgeFixture {
        let workingDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let backend = ACPTelegramScriptedBackend()
        let wire = ACPTelegramWire()
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [
                AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model"),
            ],
            runMode: .acp,
            workingDirectory: workingDirectory
        )
        let bridge = ZenCODEACPBridge(
            configuration: configuration,
            writer: ACPWriter(sink: wire.sink),
            backendFactory: backend.factory
        )
        let host = await bridge.host
        await { @ChatSessionActor in host.telegramTransportFactory = { transport } }()
        for sessionID in sessionIDs {
            let sessionConfiguration = AgentCoreSessionConfiguration(
                sessionID: sessionID,
                modelID: "test-model",
                workingDirectory: workingDirectory,
                systemPrompt: "ACP Telegram test",
                cacheKey: nil,
                history: [],
                allowedToolNames: nil
            )
            try await bridge.sessionRunner.createSession(configuration: sessionConfiguration)
            await bridge.installTestSession(sessionConfiguration, selectedAgent: selectedAgent)
        }
        return ACPTelegramBridgeFixture(
            bridge: bridge, backend: backend, wire: wire,
            transport: transport, workingDirectory: workingDirectory
        )
    }

    /// Sends `session/prompt` with `text` for `sessionID` as request `id`,
    /// and returns once the bridge answered it.
    func prompt(_ text: String, id: Int, sessionID: String) async {
        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/prompt",
            "params": [
                "sessionId": sessionID,
                "prompt": [["type": "text", "text": text]] as [[String: Any]],
            ] as [String: Any],
        ])
    }

    /// Sends `session/cancel` for `sessionID` as request `id`, and returns
    /// once the bridge answered it.
    func cancel(sessionID: String, id: Int) async {
        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/cancel",
            "params": ["sessionId": sessionID] as [String: Any],
        ])
    }

    /// Sends `session/load` for the live session `sessionID` as request
    /// `id`, which replays its history, and returns once the bridge answered.
    func loadSession(sessionID: String, id: Int) async {
        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/load",
            "params": ["sessionId": sessionID] as [String: Any],
        ])
    }

    /// Waits until the linked chat is asked a permission and returns the
    /// request ID the card carries; `nil`, with the expectation failed,
    /// when it is not asked.
    func pendingTelegramPermissionRequestID() async -> String? {
        let card = await transport.waitForSentMessage { $0.text.contains("Request ID: ") }
        guard let card, let range = card.text.range(of: "Request ID: ") else {
            Issue.record("Telegram was not asked the permission")
            return nil
        }
        let requestID = card.text[range.upperBound...].prefix { !$0.isWhitespace }
        return requestID.isEmpty ? nil : String(requestID)
    }

    /// The last `agent_message_chunk` text of the prompt that started at
    /// wire message `index`: the immediate reply of a command.
    func lastAgentText(from index: Int) -> String? {
        wire.updateTexts(kind: "agent_message_chunk", from: index).last
    }

    /// Runs `/telegram on` in `sessionID` and returns its reply.
    @discardableResult
    func turnTelegramOn(sessionID: String, id: Int) async -> String? {
        let start = wire.count
        await prompt("/telegram on", id: id, sessionID: sessionID)
        return lastAgentText(from: start)
    }

    /// Waits for `turn`, the task of prompt request `id`, once the bridge
    /// answered it. When no answer comes within `timeout` the expectation
    /// fails and the bridge is shut down first, which cancels the turn, so a
    /// failing test ends instead of waiting for a turn that cannot finish.
    func finish(_ turn: Task<Void, Never>, id: Int, timeout: Duration = .seconds(10)) async {
        let answered = await ACPTelegramTestSupport.waitUntil(timeout: timeout) {
            wire.response(id: id) != nil
        }
        #expect(answered, "prompt \(id) was not answered")
        if !answered {
            await bridge.shutdown()
        }
        await turn.value
    }

    func telegramChannel(sessionID: String) async -> TelegramChannel? {
        await bridge.telegramChannelForTesting(sessionID: sessionID)
    }
}

extension ZenCODEACPBridge {
    /// ``installTestSession(_:)`` with the session's agent.
    func installTestSession(
        _ configuration: AgentCoreSessionConfiguration,
        selectedAgent: AgentProfile?
    ) async {
        do {
            _ = try await installSession(configuration: configuration, selectedAgent: selectedAgent)
        } catch {
            Issue.record("installTestSession failed: \(error)")
        }
    }

    /// The Telegram channel of the slot of `sessionID`, once `/telegram on`
    /// created it.
    func telegramChannelForTesting(sessionID: String) async -> TelegramChannel? {
        guard let slotID = sessions[sessionID]?.slotID else { return nil }
        return await host.telegramChannel(in: slotID)
    }

    func telegramRouterForTesting() async -> TerminalTelegramSessionRouter? {
        await host.telegramRouterStorage
    }

    /// The epoch of the live incarnation of `sessionID`, if any.
    func telegramTestEpoch(sessionID: String) -> UInt64? {
        sessions[sessionID]?.epoch
    }

    func telegramTestConfiguration(sessionID: String) -> AgentCoreSessionConfiguration? {
        sessions[sessionID]?.configuration
    }
}
