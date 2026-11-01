//
//  ACPChatRoundTripTests.swift
//  ZenCODE
//
//  End-to-end coverage of the ACP chat flow: a client line arriving on the wire
//  must reach the shared session runner, and the agent reply must come back to
//  the same client as ordered `session/update` notifications plus a result.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

private final class ACPRoundTripWire: Sendable {
    private let storage = Mutex<[JSONValue]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                storage.withLock { $0.append(value) }
            }
        }
    }

    private var messages: [[String: JSONValue]] {
        storage.withLock { $0.compactMap(\.objectValue) }
    }

    /// Ordered wire trace of what a client observes: session update kinds and
    /// custom notification methods, in delivery order.
    func trace() -> [String] {
        messages.compactMap { message in
            guard let method = message["method"]?.acpStringValue else {
                return nil
            }
            guard method == "session/update" else {
                return method
            }
            return message["params"]?.objectValue?["update"]?
                .objectValue?["sessionUpdate"]?.acpStringValue
        }
    }

    func updateTexts(kind: String) -> [String] {
        messages.compactMap { message in
            guard message["method"]?.acpStringValue == "session/update",
                  let update = message["params"]?.objectValue?["update"]?.objectValue,
                  update["sessionUpdate"]?.acpStringValue == kind else {
                return nil
            }
            return update["content"]?.objectValue?["text"]?.acpStringValue
        }
    }

    func sessionIDs(forMethod method: String) -> [String] {
        messages.compactMap { message in
            guard message["method"]?.acpStringValue == method else {
                return nil
            }
            return message["params"]?.objectValue?["sessionId"]?.acpStringValue
        }
    }

    func stopReason(for id: Int) -> String? {
        messages.first { $0["id"] == .number(Double(id)) }?
            .objectValue(forKey: "result")?["stopReason"]?.acpStringValue
    }

    func hasError(for id: Int) -> Bool {
        messages.first { $0["id"] == .number(Double(id)) }?["error"] != nil
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func objectValue(forKey key: String) -> [String: JSONValue]? {
        self[key]?.objectValue
    }
}

/// Minimal backend that answers every prompt, optionally emitting subscription
/// telemetry after the reply text.
private actor EchoACPBackend: AgentRuntimeBackend {
    private let emitsSubscriptionUsage: Bool
    private var prompts: [String] = []

    init(emitsSubscriptionUsage: Bool = false) {
        self.emitsSubscriptionUsage = emitsSubscriptionUsage
    }

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
        "echo-acp-model"
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
        if emitsSubscriptionUsage {
            await onEvent(.subscriptionUsage(
                DirectAgentSubscriptionUsageStatus(
                    provider: "test-provider",
                    dailyUsedPercent: 12,
                    weeklyUsedPercent: 34,
                    dailyResetsInSeconds: 60,
                    weeklyResetsInSeconds: 600
                )
            ))
        }
        return DirectAgentResponse(
            text: reply,
            stopReason: "end_turn",
            modelID: "echo-acp-model"
        )
    }

    func recordedPrompts() -> [String] {
        prompts
    }
}

@Suite(.serialized)
struct ACPChatRoundTripTests {
    /// The full bidirectional path: a JSON-RPC `session/prompt` line handed to
    /// the bridge exactly as stdin delivers it must reach the shared runner, and
    /// the reply must return to the client after the initial configuration summary,
    /// as separate `agent_message_chunk` updates plus the prompt result.
    @Test
    func promptLineFromClientIsAnsweredOnTheSameWire() async throws {
        let fixture = try await Self.makeFixture(sessionID: "acp-round-trip")

        await fixture.bridge.handleLine("""
        {"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"\
        \(fixture.sessionID)","prompt":[{"type":"text","text":"ping from client"}]}}
        """)

        // Inbound: the prompt reached the shared session runner unchanged.
        #expect(await fixture.backend.recordedPrompts() == ["ping from client"])
        // Outbound: the client sees its own message, the configuration summary, and the reply.
        #expect(fixture.wire.updateTexts(kind: "user_message_chunk")
            == ["ping from client"])
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk")
            == [
                "Agent: Default · Model: test-model · Thinking: Not supported\n\n",
                "echo: ping from client"
            ])
        // The request is answered, and answered for the right session.
        #expect(fixture.wire.hasError(for: 7) == false)
        #expect(fixture.wire.stopReason(for: 7) == "end_turn")
        #expect(fixture.wire.sessionIDs(forMethod: "session/update")
            .allSatisfy { $0 == fixture.sessionID })
    }

    /// A prompt for an unknown session must be refused instead of silently
    /// starting a turn, so a client can never lose a reply to a dead session.
    @Test
    func promptForUnknownSessionIsRejectedWithoutRunningATurn() async throws {
        let fixture = try await Self.makeFixture(sessionID: "acp-round-trip-unknown")

        await fixture.bridge.handleLine(#"""
        {"jsonrpc":"2.0","id":9,"method":"session/prompt","params":{"sessionId":"missing-session","prompt":[{"type":"text","text":"hello"}]}}
        """#)

        #expect(await fixture.backend.recordedPrompts().isEmpty)
        #expect(fixture.wire.hasError(for: 9))
    }

    /// In app mode the reply text is buffered while the custom subscription
    /// notification is written straight to the wire. The notification must not
    /// overtake content the turn already produced.
    @Test
    func appModeSubscriptionNotificationNeverOvertakesTheReply() async throws {
        let fixture = try await Self.makeFixture(
            sessionID: "acp-round-trip-app-mode",
            appMode: true,
            emitsSubscriptionUsage: true
        )

        await fixture.bridge.handleLine("""
        {"jsonrpc":"2.0","id":11,"method":"session/prompt","params":{"sessionId":"\
        \(fixture.sessionID)","prompt":[{"type":"text","text":"ordering"}]}}
        """)

        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk")
            == [
                "Agent: Default · Model: test-model · Thinking: Not supported\n\n",
                "echo: ordering"
            ])

        let trace = fixture.wire.trace()
        let replyIndex = try #require(trace.lastIndex(of: "agent_message_chunk"))
        let notificationIndex = try #require(
            trace.firstIndex(of: "_zencode/usage/subscription")
        )
        #expect(replyIndex < notificationIndex)
        #expect(fixture.wire.stopReason(for: 11) == "end_turn")
    }

    /// Outside app mode there is no prompt-update pipeline or buffer. The
    /// subscription event must still be written as its custom notification.
    @Test
    func nonAppModeSubscriptionNotificationIsSentDirectly() async throws {
        let fixture = try await Self.makeFixture(
            sessionID: "acp-round-trip-non-app-subscription",
            appMode: false,
            emitsSubscriptionUsage: true
        )

        await fixture.bridge.handleLine("""
        {"jsonrpc":"2.0","id":12,"method":"session/prompt","params":{"sessionId":"\
        \(fixture.sessionID)","prompt":[{"type":"text","text":"direct notification"}]}}
        """)

        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk")
            == [
                "Agent: Default · Model: test-model · Thinking: Not supported\n\n",
                "echo: direct notification"
            ])
        let trace = fixture.wire.trace()
        let replyIndex = try #require(trace.lastIndex(of: "agent_message_chunk"))
        let notificationIndex = try #require(
            trace.firstIndex(of: "_zencode/usage/subscription")
        )
        #expect(replyIndex < notificationIndex)
        #expect(
            fixture.wire.sessionIDs(forMethod: "_zencode/usage/subscription")
                == [fixture.sessionID]
        )
        #expect(fixture.wire.stopReason(for: 12) == "end_turn")
    }

    private static func makeFixture(
        sessionID: String,
        appMode: Bool = false,
        emitsSubscriptionUsage: Bool = false
    ) async throws -> (
        bridge: ZenCODEACPBridge,
        backend: EchoACPBackend,
        wire: ACPRoundTripWire,
        sessionID: String
    ) {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(sessionID, isDirectory: true)
        let backend = EchoACPBackend(emitsSubscriptionUsage: emitsSubscriptionUsage)
        let wire = ACPRoundTripWire()
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            runMode: .acp,
            workingDirectory: workingDirectory,
            appMode: appMode
        )
        let bridge = ZenCODEACPBridge(
            configuration: configuration,
            writer: ACPWriter(sink: wire.sink),
            backendFactory: { _, _ in backend }
        )
        let sessionConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: workingDirectory,
            systemPrompt: "ACP round-trip test",
            cacheKey: nil,
            history: [],
            allowedToolNames: nil
        )
        try await bridge.sessionRunner.createSession(
            configuration: sessionConfiguration
        )
        await bridge.installTestSession(sessionConfiguration)
        return (bridge, backend, wire, sessionID)
    }
}

// MARK: - Telegram companion

/// An ACP session linked to Telegram with `/telegram on`, through a scripted
/// Bot API: the editor drives the session, the linked chat follows it and
/// can consult and approve it, never drive it.
extension ACPChatRoundTripTests {
    /// The editor's turn is mirrored to the linked chat once it ends: its
    /// outcome, then the files it changed.
    @Test(.timeLimit(.minutes(1)))
    func editorPromptIsMirroredToTelegramWithItsOutcomeAndSummary() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let (fixture, sessionID) = try await Self.linkedTelegramFixture(root: root)
            await fixture.backend.enqueue([
                .writeFile(path: "notes.txt", contents: "hello\n"),
                .reply("All done."),
            ])
            let before = await fixture.transport.sentMessages.count

            await fixture.prompt("Create notes.txt", id: 2, sessionID: sessionID)

            #expect(fixture.wire.stopReason(id: 2) == "end_turn")
            // The turn's Telegram side ended before the editor's reply.
            let mirrored = await fixture.transport.sentTexts.dropFirst(before)
            let outcome = try #require(mirrored.firstIndex { $0.contains("ZenCODE completed") })
            #expect(mirrored[outcome].contains("All done."))
            let summary = try #require(mirrored.firstIndex { $0.contains("Summary: 1 file") })
            #expect(mirrored[summary].contains("added notes.txt"))
            #expect(outcome < summary)
            await fixture.bridge.shutdown()
        }
    }

    /// From the linked chat, a prompt and `/undo` are refused with the
    /// mirror-only text naming the editor, and `/status` is answered; none of
    /// them reaches the model or the ACP wire.
    @Test(.timeLimit(.minutes(1)))
    func telegramPromptsAndUndoAreRefusedWhileStatusIsAnswered() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let (fixture, sessionID) = try await Self.linkedTelegramFixture(root: root)
            let companion = try #require(await fixture.companion(sessionID: sessionID))
            let refusal = "ZenCODE: this session is driven by the editor; send prompts there. From Telegram you can use /help, /status, /changes, /diff and /chat, and answer permission requests with /allow, /always or /deny."
            #expect(await companion.mirrorOnlyRefusalText == refusal)
            let status = await companion.remoteStatusText()
            let wireCount = fixture.wire.count

            for (line, answer) in [("Run the tests", refusal), ("/status", status), ("/undo", refusal)] {
                let before = await fixture.transport.sentMessages.count
                try await fixture.transport.deliver(line)
                #expect(await ACPTelegramTestSupport.waitUntil {
                    await fixture.transport.sentMessages.count > before
                }, "no answer to \(line)")
                #expect(await fixture.transport.sentTexts.dropFirst(before) == [answer])
            }
            #expect(status.hasPrefix("Session active."))
            #expect(await fixture.backend.prompts.isEmpty)
            #expect(fixture.wire.count == wireCount)
            await fixture.bridge.shutdown()
        }
    }

    /// A gated tool is asked both in the editor and in the linked chat;
    /// `/allow ID` in the chat decides it. The editor's
    /// `session/request_permission` is withdrawn on ZenCODE's side only: ACP
    /// cannot close the editor's dialog, and its late answer is ignored
    /// without anything reaching the wire.
    @Test(.timeLimit(.minutes(1)))
    func telegramAllowAnswersAPendingEditorPermissionRequest() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let (fixture, sessionID) = try await Self.linkedTelegramFixture(root: root)
            await fixture.backend.enqueue([.askPermission(command: "echo hi"), .reply("ran")])

            let turn = Task { await fixture.prompt("Run echo hi", id: 2, sessionID: sessionID) }
            guard let requestID = await Self.pendingPermission(in: fixture),
                  let editorRequestID = fixture.wire.permissionRequestIDs.first else {
                await fixture.bridge.shutdown()
                await turn.value
                return
            }
            try await fixture.transport.deliver("/allow \(requestID)")
            await fixture.finish(turn, id: 2)

            #expect(fixture.wire.stopReason(id: 2) == "end_turn")
            #expect(await fixture.backend.permissionDecisions == [true])
            #expect(await fixture.transport.sentTexts.contains(
                "✅ Permission \(requestID) allowed once. Continuing."
            ))

            let wireCount = fixture.wire.count
            await fixture.bridge.handleLine(try Self.permissionAnswer(id: editorRequestID, optionID: "reject_once"))
            #expect(fixture.wire.count == wireCount)
            #expect(fixture.wire.errorResponses.isEmpty)
            #expect(await fixture.backend.permissionDecisions == [true])
            await fixture.bridge.shutdown()
        }
    }

    /// The editor's answer to `session/request_permission` decides a gated
    /// tool asked in both places too; the linked chat is told, in the
    /// editor's words, and a late `/allow` there finds nothing pending.
    @Test(.timeLimit(.minutes(1)))
    func editorAnswerDecidesAPermissionAlsoAskedInTelegram() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let (fixture, sessionID) = try await Self.linkedTelegramFixture(root: root)
            await fixture.backend.enqueue([.askPermission(command: "echo hi"), .reply("ran")])

            let turn = Task { await fixture.prompt("Run echo hi", id: 2, sessionID: sessionID) }
            guard let requestID = await Self.pendingPermission(in: fixture),
                  let editorRequestID = fixture.wire.permissionRequestIDs.first else {
                await fixture.bridge.shutdown()
                await turn.value
                return
            }
            await fixture.bridge.handleLine(try Self.permissionAnswer(id: editorRequestID, optionID: "allow_once"))
            await fixture.finish(turn, id: 2)

            #expect(fixture.wire.stopReason(id: 2) == "end_turn")
            #expect(await fixture.backend.permissionDecisions == [true])
            #expect(await fixture.transport.sentTexts.contains(
                "✅ Permission granted in the editor for local.exec. Continuing."
            ))

            let before = await fixture.transport.sentMessages.count
            try await fixture.transport.deliver("/allow \(requestID)")
            #expect(await ACPTelegramTestSupport.waitUntil {
                await fixture.transport.sentMessages.count > before
            })
            #expect(await fixture.transport.sentTexts.dropFirst(before) == ["No permission request is pending."])
            #expect(await fixture.backend.permissionDecisions == [true])
            #expect(fixture.wire.errorResponses.isEmpty)
            await fixture.bridge.shutdown()
        }
    }

    // MARK: Telegram support

    /// A bridge with one session, linked to the scripted Bot API by a
    /// `/telegram on` prompt (request 1).
    private static func linkedTelegramFixture(
        root: URL
    ) async throws -> (fixture: ACPTelegramBridgeFixture, sessionID: String) {
        let sessionID = "acp-telegram-round-trip-\(UUID().uuidString)"
        let fixture = try await ACPTelegramBridgeFixture.make(
            root: root,
            sessionIDs: [sessionID],
            transport: ACPTelegramScriptedTransport(botID: ACPTelegramTestSupport.uniqueBotID())
        )
        let reply = await fixture.turnTelegramOn(sessionID: sessionID, id: 1)
        #expect(reply == "Telegram remote control is active.\nLinked chat: Test")
        #expect(await ACPTelegramTestSupport.waitUntil { await fixture.transport.pollCount > 0 })
        return (fixture, sessionID)
    }

    /// Waits until a permission is asked both in the editor and in the linked
    /// chat, and returns the request ID the chat was given; `nil`, with the
    /// expectation failed, when either is not asked.
    private static func pendingPermission(in fixture: ACPTelegramBridgeFixture) async -> String? {
        #expect(await ACPTelegramTestSupport.waitUntil { fixture.wire.permissionRequestIDs.count == 1 })
        let card = await fixture.transport.waitForSentMessage { $0.text.contains("Request ID: ") }
        guard let card, let range = card.text.range(of: "Request ID: ") else {
            Issue.record("Telegram was not asked the permission")
            return nil
        }
        let requestID = card.text[range.upperBound...].prefix { !$0.isWhitespace }
        return requestID.isEmpty ? nil : String(requestID)
    }

    /// The editor's JSON-RPC answer selecting `optionID` for request `id`.
    private static func permissionAnswer(id: JSONValue, optionID: String) throws -> String {
        let answer = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": .object([
                "outcome": .object(["outcome": .string("selected"), "optionId": .string(optionID)]),
            ]),
        ])
        return String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
    }
}
