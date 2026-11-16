//
//  ACPTelegramTestSupport+WireAndFixture.swift
//  ZenCODE
//
//  ACP wire recorder, client text file system and bridge fixture for the ACP
//  Telegram tests, plus the bridge test-only accessors they rely on.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

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
