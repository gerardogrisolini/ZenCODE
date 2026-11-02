//
//  TelegramCausalRoundTripTests.swift
//  ZenCODE
//
//  Causal end-to-end proof of the Telegram chat flow. Nothing reconnects inputs
//  to outputs by hand: a fake HTTP transport stands in for Telegram, and the
//  message then travels exclusively through production code — polling and
//  ingress filtering, the incoming AsyncStream, the production forwarding task,
//  the runtime event queue, prompt routing, the turn's generation path with its
//  reporter binding, and delivery through the production control service.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// Recorded wire request with its decoded JSON body fields of interest.
private struct RecordedTelegramRequest: Sendable {
    let method: String
    let chatID: Int64?
    let text: String?
    let offset: Int?
}

/// Event-driven observation of outgoing requests. It retains a matching event
/// that arrived before the test starts awaiting, avoiding polling and sleeps.
private actor TelegramRequestSignal {
    private var sentMessages: [RecordedTelegramRequest] = []
    private var waiters: [CheckedContinuation<RecordedTelegramRequest, Never>] = []

    func record(_ request: RecordedTelegramRequest) {
        guard request.method == "sendMessage" else {
            return
        }
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: request)
        } else {
            sentMessages.append(request)
        }
    }

    func nextSendMessage() async -> RecordedTelegramRequest {
        if !sentMessages.isEmpty {
            return sentMessages.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// Fake Telegram HTTP transport: replays canned responses keyed by API method
/// and records every outgoing request in order.
private final class FakeTelegramTransport: TelegramHTTPTransport, @unchecked Sendable {
    private struct State {
        var responses: [String: String]
        var pendingUpdates: [(id: Int, payload: String)] = []
        var recordedRequests: [RecordedTelegramRequest] = []
    }

    private let state: Mutex<State>
    private let requestSignal = TelegramRequestSignal()

    init(responses: [String: String]) {
        state = Mutex(State(responses: responses))
    }

    /// Queues a single inbound update. A poll only receives it when its offset
    /// permits it, and delivery removes it so later polls cannot replay it.
    func enqueueUpdate(id: Int, payload: String) {
        state.withLock { $0.pendingUpdates.append((id, payload)) }
    }

    var requests: [RecordedTelegramRequest] {
        state.withLock { $0.recordedRequests }
    }

    func requests(forMethod method: String) -> [RecordedTelegramRequest] {
        state.withLock { state in
            state.recordedRequests.filter { $0.method == method }
        }
    }

    func nextSendMessage() async -> RecordedTelegramRequest {
        await requestSignal.nextSendMessage()
    }

    func send(
        url: URL,
        method _: String,
        headers _: [RemoteHTTPHeader],
        body: Data?,
        timeout _: Duration?
    ) async throws -> (status: Int, body: Data) {
        let apiMethod = url.lastPathComponent
        let object = body.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let request = RecordedTelegramRequest(
            method: apiMethod,
            chatID: object?["chat_id"] as? Int64 ?? (object?["chat_id"] as? Int).map(Int64.init),
            text: object?["text"] as? String,
            offset: object?["offset"] as? Int ?? (object?["offset"] as? Double).map(Int.init)
        )
        let payload: String? = state.withLock { state in
            state.recordedRequests.append(request)
            if apiMethod == "getUpdates" {
                let offset = request.offset ?? 0
                if let index = state.pendingUpdates.firstIndex(where: { $0.id >= offset }) {
                    return state.pendingUpdates.remove(at: index).payload
                }
            }
            return state.responses[apiMethod]
        }
        await requestSignal.record(request)
        guard let payload else {
            return (404, Data(#"{"ok":false,"description":"not found"}"#.utf8))
        }
        return (200, Data(payload.utf8))
    }
}

/// Echo backend that records the prompt it received and streams the reply
/// through the same event path the production terminal uses.
private actor TelegramEchoBackend: AgentRuntimeBackend {
    private var prompts: [String] = []

    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func createSessionIfNeeded(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}
    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "telegram-echo-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        let reply = "echo: \(prompt)"
        await onEvent(.content(reply))
        return DirectAgentResponse(
            text: reply,
            stopReason: "end_turn",
            modelID: "telegram-echo-model"
        )
    }

    func recordedPrompts() -> [String] {
        prompts
    }
}

@Suite
struct TelegramCausalRoundTripTests {
    private static let linkedChatID: Int64 = 42

    private static func updatesPayload(updateID: Int, text: String) -> String {
        """
        {"ok":true,"result":[{"update_id":\(updateID),"message":{"message_id":\(updateID),"from":{"id":7,"is_bot":false,"username":"gerardo"},"chat":{"id":\(Self.linkedChatID),"type":"private","first_name":"Gerardo"},"text":"\(text)"}}]}
        """
    }

    /// The single causal chain: a Telegram update polled through the fake
    /// transport crosses the whole production ingress and egress path of the
    /// slot's Telegram channel (the handover, the channel's own ingress, the
    /// turn run through the session host), and the answer the model produced
    /// is posted back to the chat that asked; the terminal then takes the
    /// slot back with the catch-up of what it did not see.
    ///
    /// The flow runs inside one `withSupportDirectoryURL` scope: the task-local
    /// override is inherited by the polling and turn tasks, so seeded settings
    /// reach the production code without a process-global override that could
    /// leak into parallel suites.
    @Test
    func polledUpdateTravelsTheProductionPathAndAnswerReturnsToSameChat() async throws {
        // Seeded support directory: settings pair the bot with chat 42.
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-causal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(
                models: [],
                telegram: AgentTelegramSettingsManifest(
                    enabled: true,
                    botToken: "123456:ABCDEF",
                    linkedChatID: Self.linkedChatID,
                    linkedChatTitle: "Gerardo",
                    ownerUserID: 7,
                    routes: [.init(roomID: "default")]
                )
            ),
            to: supportDirectory.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        )

        // Fake transport with every canned response the flow needs.
        let transport = FakeTelegramTransport(responses: [
            "deleteWebhook": #"{"ok":true,"result":true}"#,
            "getMe": #"{"ok":true,"result":{"id":9001,"is_bot":true,"first_name":"Z","username":"zencode_bot"}}"#,
            "getUpdates": #"{"ok":true,"result":[]}"#,
            "sendMessage": #"{"ok":true,"result":{"message_id":77,"chat":{"id":42,"type":"private"},"text":"x"}}"#
        ])

        try await AppStorageDirectory.withSupportDirectoryURL(supportDirectory) {
            try await Self.runCausalFlow(transport: transport)
        }
    }

    /// The isolated body of the causal chain. Runs on ``ChatSessionActor``,
    /// the isolation of the host that owns the slot and its channel.
    @ChatSessionActor
    private static func runCausalFlow(transport: FakeTelegramTransport) async throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-causal-wd-\(UUID().uuidString)", isDirectory: true)
        let backend = TelegramEchoBackend()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend }
        )
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: workingDirectory
            ),
            stdinIsTerminal: false,
            sessionRunner: runner,
            telegramTransportFactory: { transport }
        )
        try await terminal.createCurrentSession(discoverExternalTools: false)
        let host = terminal.sessionHost
        let slot = terminal.terminalSlotID

        // Production handover: the settings are already bound, so the attach
        // starts polling for real, and the channel drives the slot from here.
        try await host.activateTelegram(in: slot)
        let channel = try #require(host.telegramChannel(in: slot))
        #expect(channel.isActive)
        #expect(channel.controlState.botUsername == "zencode_bot")
        #expect(channel.readsIngress)
        #expect(host.activeChannel(in: slot) == .telegram)
        #expect(host.admitLine("typed in the terminal", in: slot)
            == .refused(ChatSlotAdmission.dormantRefusalText))

        // Deliver the inbound update on the wire the poller is reading. The
        // channel admits it and runs the turn through the host, on the
        // session's controller, and its ending goes back to the chat.
        transport.enqueueUpdate(
            id: 501,
            payload: Self.updatesPayload(updateID: 501, text: "ciao dal telefono")
        )
        let completion = await transport.nextSendMessage()

        // Busy egress is fenced inside the real control service, not merely by
        // a pre-transport hook. A stale wire lifecycle must produce no additional
        // HTTP send even though ingress ACL resolution still succeeds.
        let sendCountBeforeStaleBusy = transport.requests(forMethod: "sendMessage").count
        channel.controlState.wireLifecycleEpoch = UUID()
        let reservation = try host.reservePrompt(in: slot)
        _ = await channel.handleIncomingMessage(
            TerminalTelegramIncomingMessage(
                chatID: Self.linkedChatID, userID: 7, text: "busy stale egress",
                voice: nil, messageID: 502, chatTitle: nil, username: nil
            )
        )
        host.releasePrompt(reservation)
        #expect(channel.promptQueue.isEmpty)
        #expect(transport.requests(forMethod: "sendMessage").count == sendCountBeforeStaleBusy)

        // The terminal takes the slot back: the catch-up holds the prompt the
        // chat sent and the answer it received, in sequence order.
        let catchUp = try #require(await host.deactivateTelegram(in: slot))
        #expect(host.activeChannel(in: slot) == .primary)
        let transcript = catchUp.entries.compactMap { entry -> String? in
            switch entry.kind {
            case let .userPrompt(text, _, origin):
                return "\(origin == .telegram ? "telegram" : "other"): \(text)"
            case let .assistantText(text):
                return "assistant: \(text)"
            default:
                return nil
            }
        }
        #expect(transcript == ["telegram: ciao dal telefono", "assistant: echo: ciao dal telefono"])
        await host.shutdown()

        // Inbound causality: the polled text reached the session runner as the
        // turn's prompt.
        #expect(await backend.recordedPrompts() == ["ciao dal telefono"])
        // Egress causality: the completion message carries the model's reply
        // and is addressed to the chat that asked.
        let completionText = try #require(completion.text)
        #expect(completionText.contains("echo: ciao dal telefono"))
        #expect(completion.chatID == Self.linkedChatID)
        // The poll advanced past the update it processed, so it is not
        // replayed: the recorded getUpdates offsets only move forward.
        let offsets = transport.requests(forMethod: "getUpdates").compactMap(\.offset)
        #expect(offsets == offsets.sorted())
    }
}
