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

/// The model ids the backends of a bridge were built for, in build order.
private final class ACPBackendBuildLog: Sendable {
    private let storage = Mutex<[String?]>([])

    var modelIDs: [String?] {
        storage.withLock { $0 }
    }

    func record(_ modelID: String?) {
        storage.withLock { $0.append(modelID) }
    }
}

/// Minimal backend that answers every prompt, optionally emitting subscription
/// telemetry after the reply text.
///
/// With a `snapshotModelID` it also reports its sessions' snapshots, naming
/// that model in them: the id a provider client speaks on the wire, which is
/// not the id the session was configured with.
private actor EchoACPBackend: AgentRuntimeBackend {
    private let emitsSubscriptionUsage: Bool
    private let snapshotModelID: String?
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var prompts: [String] = []

    init(emitsSubscriptionUsage: Bool = false, snapshotModelID: String? = nil) {
        self.emitsSubscriptionUsage = emitsSubscriptionUsage
        self.snapshotModelID = snapshotModelID
    }

    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard let snapshotModelID else {
            return
        }
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id,
            modelID: snapshotModelID,
            workingDirectoryPath: cwd,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard sessions[id] == nil else {
            return
        }
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }

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

    /// A backend reports the model id it speaks on the wire, which is not the
    /// id its session was configured with (`claude-fable-5-2` for
    /// `claude:claude-fable-5-2`). The session keeps its own id after a turn:
    /// adopting the reported one makes the next prompt's configuration differ
    /// from the running one, so the backend is built again (its features
    /// discover their tools, and ask for their consent, again) for an id
    /// that no longer names the provider of the session.
    ///
    /// The session is created by `session/new` in an existing workspace, so
    /// its configuration is the one a client's session has.
    @Test
    func secondPromptKeepsTheConfiguredModelAndRunsOnTheSameBackend() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-round-trip-wire-model-\(UUID().uuidString)", isDirectory: true)
        let supportDirectory = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let backend = EchoACPBackend(snapshotModelID: "wire/test-model")
        let builds = ACPBackendBuildLog()
        let wire = ACPRoundTripWire()
        try await AppStorageDirectory.withSupportDirectoryURL(supportDirectory) {
            let bridge = ZenCODEACPBridge(
                configuration: try Self.hostedConfiguration(workingDirectory: workspace),
                writer: ACPWriter(sink: wire.sink),
                backendFactory: { configuration, _ in
                    builds.record(configuration.modelID)
                    return backend
                }
            )
            try await bridge.newSession(id: nil, params: ["cwd": workspace.path])
            let sessionID = try #require(
                await bridge.sessionConfigurationsForTesting().first?.sessionID
            )

            await bridge.handleLine("""
            {"jsonrpc":"2.0","id":21,"method":"session/prompt","params":{"sessionId":"\
            \(sessionID)","prompt":[{"type":"text","text":"first"}]}}
            """)

            #expect(wire.stopReason(for: 21) == "end_turn")
            #expect(await bridge.sessionConfigurationsForTesting().map(\.modelID) == ["test-model"])

            await bridge.handleLine("""
            {"jsonrpc":"2.0","id":22,"method":"session/prompt","params":{"sessionId":"\
            \(sessionID)","prompt":[{"type":"text","text":"second"}]}}
            """)

            #expect(wire.hasError(for: 22) == false)
            #expect(wire.stopReason(for: 22) == "end_turn")
            #expect(await backend.recordedPrompts() == ["first", "second"])
            // One backend, built for the configured model, served both prompts.
            #expect(builds.modelIDs == ["test-model"])
            #expect(await bridge.sessionConfigurationsForTesting().map(\.modelID) == ["test-model"])
            await bridge.shutdown()
        }
    }

    private static func hostedConfiguration(
        workingDirectory: URL,
        appMode: Bool = false
    ) throws -> AgentConfiguration {
        try AgentConfiguration(
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
        let bridge = ZenCODEACPBridge(
            configuration: try hostedConfiguration(
                workingDirectory: workingDirectory,
                appMode: appMode
            ),
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
