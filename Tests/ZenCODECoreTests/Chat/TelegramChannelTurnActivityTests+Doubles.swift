//
//  TelegramChannelTurnActivityTests+Doubles.swift
//  ZenCODE
//
//  The scripted agent backend and the scripted Telegram Bot API transport
//  that the host tests of the Telegram turn activity suite run over.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// A model backend whose prompts follow the script of ``enqueue(_:)``: the
/// reasoning, content, and tool-call events of each step, and the sub-agent
/// snapshots it reports from a step on. While ``holdSnapshotReads(_:)`` is
/// on, a read of the snapshots takes them as they are then and returns them
/// only once ``releaseNextSnapshotRead()`` lets it go, oldest first.
actor TurnActivityBackend: AgentRuntimeBackend {
    enum Step: Sendable {
        case thought(String)
        case content(String)
        case toolCallStarted(DirectAgentToolCall)
        case toolCallCompleted(DirectAgentToolCall, DirectAgentToolResult)
        case snapshots([DirectSubAgentRuntime.AgentSnapshot])
    }

    private var scripts: [[Step]] = []
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var snapshots: [DirectSubAgentRuntime.AgentSnapshot] = []
    private(set) var prompts: [String] = []
    private var holdsSnapshotReads = false
    private var heldSnapshotReads: [CheckedContinuation<Void, Never>] = []
    private var heldSnapshotReadWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    nonisolated var factory: AgentRuntimeBackendFactory {
        { [self] _, _ in self }
    }

    func enqueue(_ steps: [Step]) {
        scripts.append(steps)
    }

    func setSnapshots(_ snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        self.snapshots = snapshots
    }

    /// Whether the reads that start from now on wait; a read already waiting
    /// keeps waiting.
    func holdSnapshotReads(_ holds: Bool) {
        holdsSnapshotReads = holds
    }

    /// Returns once `count` reads wait.
    func waitUntilSnapshotReadsAreHeld(_ count: Int) async {
        guard heldSnapshotReads.count < count else { return }
        await withCheckedContinuation { heldSnapshotReadWaiters.append((count, $0)) }
    }

    /// Lets the oldest read that waits return.
    func releaseNextSnapshotRead() {
        guard !heldSnapshotReads.isEmpty else { return }
        heldSnapshotReads.removeFirst().resume()
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        let current = snapshots
        guard holdsSnapshotReads else { return current }
        await withCheckedContinuation { continuation in
            heldSnapshotReads.append(continuation)
            let held = heldSnapshotReads.count
            let ready = heldSnapshotReadWaiters.filter { $0.count <= held }
            heldSnapshotReadWaiters.removeAll { $0.count <= held }
            for waiter in ready {
                waiter.continuation.resume()
            }
        }
        return current
    }

    func createSession(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {
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
        guard sessions[id] == nil else { return }
        createSession(
            id: id, cwd: cwd, systemPrompt: systemPrompt, history: history, cacheKey: cacheKey,
            allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String, systemPrompt _: String?, allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?, preserveThinking _: Bool
    ) {}

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

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        let steps = scripts.isEmpty ? [.content("Answer to: \(prompt)")] : scripts.removeFirst()
        var text = ""
        for step in steps {
            switch step {
            case let .thought(thought):
                await onEvent(.thought(thought))
            case let .content(content):
                text += content
                await onEvent(.content(content))
            case let .toolCallStarted(toolCall):
                await onEvent(.toolCallStarted(toolCall))
            case let .toolCallCompleted(toolCall, result):
                await onEvent(.toolCallCompleted(toolCall, result))
            case let .snapshots(snapshots):
                self.snapshots = snapshots
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

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}

/// A Bot API double for one bot that records every message it sends,
/// edits, or deletes, in order: getUpdates returns what ``deliver(_:)``
/// queued, sendMessage and sendRichMessage answer receipts from 500 on, and
/// every other method succeeds.
actor TurnActivityTransport: TelegramHTTPTransport {
    /// One message effect: the method, the text (for a rich message every
    /// text of the document, joined by a newline), the message (the receipt
    /// of a send, the target of an edit or a deletion), and whether the
    /// message has the thinking message's shape: a `sendMessage` whose
    /// entities are exactly an `expandable_blockquote` and an `italic`.
    struct Request: Equatable, Sendable {
        let method: String
        let text: String
        let messageID: Int
        let isThinkingShape: Bool
    }

    let botID: Int64
    private(set) var requests: [Request] = []
    private(set) var pollCount = 0
    private var pendingUpdates: [String] = []
    private var nextUpdateID = 1
    private var nextMessageID = 500

    init(botID: Int64) {
        self.botID = botID
    }

    /// Queues a text of the owner in the linked chat for the next poll.
    func deliver(_ text: String) throws {
        let message: [String: Any] = [
            "message_id": nextMessageID,
            "from": ["id": 7, "is_bot": false, "first_name": "Owner", "username": "owner"],
            "chat": ["id": 42, "type": "private", "first_name": "Owner"],
            "date": 1,
            "text": text,
        ]
        nextMessageID += 1
        let update: [String: Any] = ["update_id": nextUpdateID, "message": message]
        nextUpdateID += 1
        let data = try JSONSerialization.data(withJSONObject: update)
        pendingUpdates.append(String(decoding: data, as: UTF8.self))
    }

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        switch url.lastPathComponent {
        case "getMe":
            return (200, Data(
                #"{"ok":true,"result":{"id":\#(botID),"is_bot":true,"first_name":"ZenCODE","username":"zencode_bot"}}"#.utf8
            ))
        case "getUpdates":
            pollCount += 1
            while pendingUpdates.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            let updates = pendingUpdates
            pendingUpdates = []
            return (200, Data(#"{"ok":true,"result":[\#(updates.joined(separator: ","))]}"#.utf8))
        case "sendMessage":
            let entities = object?["entities"] as? [Any] ?? []
            let types = entities.map { ($0 as? [String: Any])?["type"] as? String }
            return record(
                method: "sendMessage", text: object?["text"] as? String ?? "",
                isThinkingShape: types == ["expandable_blockquote", "italic"]
            )
        case "sendRichMessage":
            let richMessage = object?["rich_message"] as? [String: Any]
            let blocks = richMessage?["blocks"] as? [Any] ?? []
            return record(
                method: "sendRichMessage",
                text: blocks.map { Self.text(of: $0) }.joined(separator: "\n\n"),
                isThinkingShape: false
            )
        case "editMessageText":
            let messageID = object?["message_id"] as? Int ?? 0
            requests.append(Request(
                method: "editMessageText", text: object?["text"] as? String ?? "",
                messageID: messageID, isThinkingShape: false
            ))
            return (200, Self.messageBody(id: messageID))
        case "deleteMessage":
            requests.append(Request(
                method: "deleteMessage", text: "", messageID: object?["message_id"] as? Int ?? 0,
                isThinkingShape: false
            ))
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        default:
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        }
    }

    private func record(method: String, text: String, isThinkingShape: Bool) -> (status: Int, body: Data) {
        let messageID = nextMessageID
        nextMessageID += 1
        requests.append(Request(
            method: method, text: text, messageID: messageID, isThinkingShape: isThinkingShape
        ))
        return (200, Self.messageBody(id: messageID))
    }

    private static func messageBody(id: Int) -> Data {
        Data(#"{"ok":true,"result":{"message_id":\#(id),"chat":{"id":42,"type":"private"},"date":0}}"#.utf8)
    }

    /// The text of a decoded rich block: the concatenation of its runs.
    private static func text(of block: Any) -> String {
        if let text = block as? String {
            return text
        }
        if let array = block as? [Any] {
            return array.map { text(of: $0) }.joined()
        }
        guard let object = block as? [String: Any] else { return "" }
        return object["text"].map { text(of: $0) } ?? ""
    }
}
