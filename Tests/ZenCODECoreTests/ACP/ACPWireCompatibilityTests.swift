//
//  ACPCompatibilityTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/06/26.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

private final class ACPWireRecordingTransport: Sendable {
    private let messages = Mutex<[Data]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            messages.withLock { $0.append(data) }
        }
    }

    private var decodedMessages: [[String: Any]] {
        messages.withLock { rawMessages in
            rawMessages.compactMap { data in
                guard let object = try? JSONSerialization.jsonObject(with: data) else {
                    return nil
                }
                return object as? [String: Any]
            }
        }
    }

    func response(id: Int) -> [String: Any]? {
        decodedMessages.first { message in
            guard let rawID = message["id"] as? NSNumber else {
                return false
            }
            return rawID.intValue == id
        }
    }

    func errorCode(id: Int) -> Int? {
        response(id: id)?["error"]
            .flatMap { ($0 as? [String: Any])?["code"] }
            .flatMap { ($0 as? NSNumber)?.intValue }
    }

    /// Payloads of the `session/update` notifications, in wire order, from
    /// the message at `index` on.
    func sessionUpdates(from index: Int = 0) -> [[String: Any]] {
        decodedMessages.dropFirst(index).compactMap { message in
            guard message["method"] as? String == "session/update",
                  let params = message["params"] as? [String: Any] else {
                return nil
            }
            return params["update"] as? [String: Any]
        }
    }

    /// How many messages reached the wire so far.
    var messageCount: Int {
        messages.withLock { $0.count }
    }
}

/// One prompt's `session/update` stream, split the way the wire baseline
/// compares it: the exact order of every `sessionUpdate` kind except `plan`,
/// and the `plan` updates kept apart.
///
/// The position of `plan` is deliberately not part of the order. The task
/// graph observer publishes it from its own task, concurrently with the turn
/// that publishes every other update, so where it lands depends on actor
/// scheduling. When the observer loses the race, `finishTaskPresentation`
/// publishes it at the end of the turn, deduplicating on `lastPlan`, so it is
/// still published exactly once.
struct ACPSessionUpdateStream {
    /// `sessionUpdate` kinds in wire order, `plan` excluded.
    let orderedKinds: [String]
    /// The `plan` updates, in wire order.
    let plans: [[String: Any]]

    init(updates: [[String: Any]]) {
        var orderedKinds: [String] = []
        var plans: [[String: Any]] = []
        for update in updates {
            guard let kind = update["sessionUpdate"] as? String else { continue }
            if kind == "plan" {
                plans.append(update)
            } else {
                orderedKinds.append(kind)
            }
        }
        self.orderedKinds = orderedKinds
        self.plans = plans
    }
}

private func makeACPWireBridge(
    transport: ACPWireRecordingTransport,
    setupRequired: Bool = false,
    backendFactory: AgentRuntimeBackendFactory? = nil
) throws -> ZenCODEACPBridge {
    // A bridge that still needs its setup has no model: the hosted model list
    // is empty, which keeps `configOptions` and `models` deterministic instead
    // of reading the settings of the machine running the tests.
    let configuration = try AgentConfiguration(
        hostedModelID: "test-model",
        availableModels: setupRequired ? [] : [
            AgentSettingsModelManifest(
                id: "test-model",
                kind: .remoteAPI,
                modelID: "local/test-model"
            )
        ],
        runMode: .acp,
        workingDirectory: FileManager.default.temporaryDirectory
    )
    return ZenCODEACPBridge(
        configuration: configuration,
        writer: ACPWriter(sink: transport.sink),
        backendFactory: backendFactory,
        setupRequired: setupRequired
    )
}

/// The exact `initialize` line the ACP Registry validator sends (Python
/// `json.dumps`, hence the spaces): terminal authentication is declared under
/// `_meta` and there is no `clientCapabilities.auth` key.
private let acpRegistryValidatorInitializeLine = #"""
{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1, "clientInfo": {"name": "ACP Registry Validator", "version": "1.0.0"}, "clientCapabilities": {"terminal": true, "fs": {"readTextFile": true, "writeTextFile": true}, "_meta": {"terminal_output": true, "terminal-auth": true}}}}
"""#

extension ACPCompatibilityTests {
    @Test
    func initializeThroughHandleLineAdvertisesTheEffectiveAuthenticationMethod() async throws {
        let transport = ACPWireRecordingTransport()
        let bridge = try makeACPWireBridge(transport: transport)

        await bridge.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientCapabilities":{"auth":{"terminal":true}}}}"#
        )

        let response = try #require(transport.response(id: 1))
        #expect(response["jsonrpc"] as? String == "2.0")
        let result = try #require(response["result"] as? [String: Any])
        #expect((result["protocolVersion"] as? NSNumber)?.intValue == 1)
        let authMethods = try #require(result["authMethods"] as? [[String: Any]])
        #expect(authMethods.count == 1)
        #expect(authMethods.first?["id"] as? String == "zencode-client-compatibility")
    }

    @Test
    func authenticateThroughHandleMessageAcceptsAnAdvertisedMethod() async throws {
        let transport = ACPWireRecordingTransport()
        let bridge = try makeACPWireBridge(transport: transport)

        await bridge.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientCapabilities":{"auth":{"terminal":true}}}}"#
        )
        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "authenticate",
            "params": ["methodId": "zencode-client-compatibility"] as [String: Any]
        ])

        let response = try #require(transport.response(id: 2))
        #expect(response["error"] == nil)
        #expect((response["result"] as? [String: Any])?.isEmpty == true)
    }

    @Test
    func authenticateThroughWireRejectsMissingWrongTypeAndUnadvertisedMethods() async throws {
        let transport = ACPWireRecordingTransport()
        let bridge = try makeACPWireBridge(transport: transport)

        await bridge.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientCapabilities":{"auth":{"terminal":true}}}}"#
        )
        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "authenticate",
            "params": [:] as [String: Any]
        ])
        await bridge.handleLine(
            #"{"jsonrpc":"2.0","id":3,"method":"authenticate","params":{"methodId":42}}"#
        )
        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": 4,
            "method": "authenticate",
            "params": ["methodId": "not-advertised"] as [String: Any]
        ])

        #expect(transport.errorCode(id: 2) == -32602)
        #expect(transport.errorCode(id: 3) == -32602)
        #expect(transport.errorCode(id: 4) == -32602)
    }

    @Test
    func unknownMethodThroughHandleMessageUsesMethodNotFoundError() async throws {
        let transport = ACPWireRecordingTransport()
        let bridge = try makeACPWireBridge(transport: transport)

        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "unknown/acp-method",
            "params": [:] as [String: Any]
        ])

        #expect(transport.errorCode(id: 1) == -32601)
    }

    @Test
    func compatibilityAuthenticationMethodIsNotAdvertisedWithoutAuthCapability() {
        let firstClientMethods = ZenCODEACPBridge.authenticationMethods(from: [
            "clientInfo": [
                "name": "FixtureClient",
                "version": "1.0"
            ] as [String: Any]
        ])
        let otherClientMethods = ZenCODEACPBridge.authenticationMethods(from: [
            "clientInfo": [
                "name": "OtherClient",
                "version": "27.0"
            ] as [String: Any]
        ])

        #expect(firstClientMethods.isEmpty)
        #expect(otherClientMethods.isEmpty)
    }

    @Test
    func registryValidatorInitializeAdvertisesOnlyTheTerminalSetupMethod() async throws {
        let transport = ACPWireRecordingTransport()
        let bridge = try makeACPWireBridge(transport: transport)

        await bridge.handleLine(acpRegistryValidatorInitializeLine)

        let response = try #require(transport.response(id: 1))
        #expect(response["jsonrpc"] as? String == "2.0")
        #expect(response["error"] == nil)
        let result = try #require(response["result"] as? [String: Any])
        #expect((result["protocolVersion"] as? NSNumber)?.intValue == 1)
        let authMethods = try #require(result["authMethods"] as? [[String: Any]])
        #expect(authMethods.count == 1)
        let method = try #require(authMethods.first)
        #expect(method["id"] as? String == "zencode-setup")
        #expect(method["name"] as? String == "Set up ZenCODE")
        #expect(method["type"] as? String == "terminal")
        // `args` replaces the client's default `--acp`: the client launches
        // `zen --setup`, which opens the setup and exits when it ends.
        let args = try #require(method["args"] as? [String])
        #expect(args == ["--setup"])
        #expect(args == [ZenCODESetupCommand.option])
        #expect(Set(method.keys) == ["id", "name", "type", "args"])
        #expect(!authMethods.contains { $0["type"] as? String == "agent" })
    }

    @Test
    func clientWithAuthAndTerminalAuthReceivesAgentMethodThenTerminalSetupMethod() async throws {
        let transport = ACPWireRecordingTransport()
        let bridge = try makeACPWireBridge(transport: transport)

        await bridge.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientCapabilities":{"auth":{"terminal":true},"_meta":{"terminal-auth":true}}}}"#
        )

        let response = try #require(transport.response(id: 1))
        let result = try #require(response["result"] as? [String: Any])
        let authMethods = try #require(result["authMethods"] as? [[String: Any]])
        #expect(authMethods.count == 2)
        #expect(authMethods.first?["id"] as? String == "zencode-client-compatibility")
        #expect(authMethods.first?["type"] as? String == "agent")
        #expect(authMethods.last?["id"] as? String == "zencode-setup")
        #expect(authMethods.last?["type"] as? String == "terminal")
        #expect(authMethods.last?["args"] as? [String] == ["--setup"])
    }

    @Test
    func terminalSetupMethodRequiresTheTerminalAuthExtensionToBeTrue() {
        let terminalAuthFalse = ZenCODEACPBridge.authenticationMethods(from: [
            "clientCapabilities": [
                "_meta": ["terminal-auth": false] as [String: Any]
            ] as [String: Any]
        ])
        let terminalAuthAbsent = ZenCODEACPBridge.authenticationMethods(from: [
            "clientCapabilities": [
                "terminal": true,
                "_meta": ["terminal_output": true] as [String: Any]
            ] as [String: Any]
        ])
        let terminalAuthNotABoolean = ZenCODEACPBridge.authenticationMethods(from: [
            "clientCapabilities": [
                "_meta": ["terminal-auth": "true"] as [String: Any]
            ] as [String: Any]
        ])
        let authOnlyClient = ZenCODEACPBridge.authenticationMethods(from: [
            "clientCapabilities": [
                "auth": ["terminal": true],
                "_meta": ["terminal-auth": false] as [String: Any]
            ] as [String: Any]
        ])

        #expect(terminalAuthFalse.isEmpty)
        #expect(terminalAuthAbsent.isEmpty)
        #expect(terminalAuthNotABoolean.isEmpty)
        #expect(authOnlyClient.map { $0["id"] as? String } == ["zencode-client-compatibility"])
    }

    @Test
    func bridgeAwaitingSetupStillInitializesAndAcknowledgesTheSetupMethod() async throws {
        let transport = ACPWireRecordingTransport()
        let bridge = try makeACPWireBridge(transport: transport, setupRequired: true)

        await bridge.handleLine(acpRegistryValidatorInitializeLine)
        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "authenticate",
            "params": ["methodId": "zencode-setup"] as [String: Any]
        ])

        let initializeResponse = try #require(transport.response(id: 1))
        #expect(initializeResponse["error"] == nil)
        let result = try #require(initializeResponse["result"] as? [String: Any])
        let authMethods = try #require(result["authMethods"] as? [[String: Any]])
        #expect(!authMethods.isEmpty)
        #expect(authMethods.first?["id"] as? String == "zencode-setup")
        // No model is configured yet: the lists are empty but still valid JSON.
        let configOptions = try #require(result["configOptions"] as? [Any])
        #expect(configOptions.isEmpty)
        let models = try #require(
            (result["_meta"] as? [String: Any])?["models"] as? [String: Any]
        )
        #expect((models["availableModels"] as? [Any])?.isEmpty == true)

        let authenticateResponse = try #require(transport.response(id: 2))
        #expect(authenticateResponse["error"] == nil)
        #expect((authenticateResponse["result"] as? [String: Any])?.isEmpty == true)
    }

    @Test
    func bridgeAwaitingSetupAnswersAuthRequiredToSessionAndPromptRequests() async throws {
        let transport = ACPWireRecordingTransport()
        let bridge = try makeACPWireBridge(transport: transport, setupRequired: true)
        let cwd = FileManager.default.temporaryDirectory.path

        await bridge.handleLine(acpRegistryValidatorInitializeLine)
        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "session/new",
            "params": ["cwd": cwd, "mcpServers": [] as [Any]] as [String: Any]
        ])
        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": 3,
            "method": "session/prompt",
            "params": [
                "sessionId": "swift-agent-unknown",
                "prompt": [["type": "text", "text": "Hello"]] as [[String: Any]]
            ] as [String: Any]
        ])
        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": 4,
            "method": "session/load",
            "params": [
                "sessionId": "swift-agent-unknown",
                "cwd": cwd,
                "mcpServers": [] as [Any]
            ] as [String: Any]
        ])
        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": 5,
            "method": "session/resume",
            "params": [
                "sessionId": "swift-agent-unknown",
                "cwd": cwd,
                "mcpServers": [] as [Any]
            ] as [String: Any]
        ])
        await bridge.handleMessage([
            "jsonrpc": "2.0",
            "id": 6,
            "method": "_zencode/model/preload",
            "params": [:] as [String: Any]
        ])

        for id in 2...6 {
            #expect(transport.errorCode(id: id) == -32000)
            #expect(transport.response(id: id)?["result"] == nil)
        }
        let error = try #require(transport.response(id: 2)?["error"] as? [String: Any])
        let message = try #require(error["message"] as? String)
        #expect(message.contains("Authentication required"))
        #expect(message.contains("Set up ZenCODE"))
        #expect(message == ZenCODEACPBridge.setupRequiredMessage)
        #expect(ZenCODEACPBridge.setupRequiredMessage
            == "Authentication required: ZenCODE is not configured. "
            + "Use the \"Set up ZenCODE\" terminal authentication method, or run `zen --setup` in a terminal.")
        // Nothing may have been created behind the refused requests.
        #expect(await bridge.sessionConfigurationsForTesting().isEmpty)
    }

    @Test
    func shutdownFenceWinsOverAuthRequiredOnABridgeAwaitingSetup() async throws {
        let transport = ACPWireRecordingTransport()
        let bridge = try makeACPWireBridge(transport: transport, setupRequired: true)

        await bridge.shutdown()

        await #expect(throws: ACPShutdownFenceError.self) {
            try await bridge.newSession(id: nil, params: [:])
        }
        await #expect(throws: ACPShutdownFenceError.self) {
            try await bridge.prompt(id: nil, params: [:])
        }
        await #expect(throws: ACPShutdownFenceError.self) {
            try await bridge.loadSession(id: nil, params: [:])
        }
        await #expect(throws: ACPShutdownFenceError.self) {
            try await bridge.preloadModel(id: nil, params: [:])
        }
    }

    /// Characterization of the current wire: the ordered `sessionUpdate` kinds
    /// and the stop reason of a simple text `session/prompt` on an installed
    /// session whose model answers with one content event, from the prompt
    /// line to its result. Texts and timing are deliberately not compared, and
    /// the `plan` position is not constrained (see `ACPSessionUpdateStream`).
    @Test
    func simplePromptPublishesTheCurrentSessionUpdateSequence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-wire-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await AppStorageDirectory.withSupportDirectoryURL(root) {
            let transport = ACPWireRecordingTransport()
            let backend = SingleReplyACPBackend()
            let bridge = try makeACPWireBridge(transport: transport, backendFactory: { _, _ in backend })
            let sessionID = "acp-wire-prompt-\(UUID().uuidString)"
            let sessionConfiguration = AgentCoreSessionConfiguration(
                sessionID: sessionID,
                modelID: "test-model",
                workingDirectory: root.appendingPathComponent("workspace", isDirectory: true),
                systemPrompt: "ACP wire baseline",
                cacheKey: nil,
                history: [],
                allowedToolNames: nil
            )
            try await bridge.sessionRunner.createSession(configuration: sessionConfiguration)
            await bridge.installTestSession(sessionConfiguration)

            await bridge.handleMessage([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "session/prompt",
                "params": [
                    "sessionId": sessionID,
                    "prompt": [["type": "text", "text": "Hello"]] as [[String: Any]]
                ] as [String: Any]
            ])

            #expect(transport.errorCode(id: 1) == nil)
            let result = try #require(transport.response(id: 1)?["result"] as? [String: Any])
            #expect(result["stopReason"] as? String == "end_turn")
            let stream = ACPSessionUpdateStream(updates: transport.sessionUpdates())
            // The first agent message is the initial configuration summary, the
            // second one the model reply.
            #expect(stream.orderedKinds == [
                "user_message_chunk",
                "session_info_update",
                "available_commands_update",
                "agent_message_chunk",
                "agent_message_chunk",
            ])
            // No task graph: exactly one empty plan.
            #expect(stream.plans.count == 1)
            #expect((stream.plans.first?["entries"] as? [Any])?.isEmpty == true)
        }
    }
}

/// Minimal backend whose model answers every prompt with one content event,
/// so the reply path of a turn is on the wire.
private actor SingleReplyACPBackend: AgentRuntimeBackend {
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
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        await onEvent(.content("reply"))
        return DirectAgentResponse(text: "reply", stopReason: "end_turn", modelID: "test-model")
    }
}
