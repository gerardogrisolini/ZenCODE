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
    /// the reply must return to the client as an `agent_message_chunk` plus the
    /// prompt result.
    @Test
    func promptLineFromClientIsAnsweredOnTheSameWire() async throws {
        let fixture = try await Self.makeFixture(sessionID: "acp-round-trip")

        await fixture.bridge.handleLine("""
        {"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"\
        \(fixture.sessionID)","prompt":[{"type":"text","text":"ping from client"}]}}
        """)

        // Inbound: the prompt reached the shared session runner unchanged.
        #expect(await fixture.backend.recordedPrompts() == ["ping from client"])
        // Outbound: the client sees its own message echoed back and the reply.
        #expect(fixture.wire.updateTexts(kind: "user_message_chunk")
            == ["ping from client"])
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk")
            == ["echo: ping from client"])
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
            == ["echo: ordering"])

        let trace = fixture.wire.trace()
        let replyIndex = try #require(trace.firstIndex(of: "agent_message_chunk"))
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
            == ["echo: direct notification"])
        #expect(fixture.wire.trace().contains("_zencode/usage/subscription"))
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
