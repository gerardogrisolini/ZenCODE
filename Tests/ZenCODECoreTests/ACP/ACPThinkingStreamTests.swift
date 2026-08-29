//
//  ACPThinkingStreamTests.swift
//  ZenCODE
//
//  End-to-end coverage of the reasoning/thinking flow at the ACP wire
//  boundary: a backend that emits `.thought` deltas during a prompt turn must
//  surface them to the host as ordered `agent_thought_chunk` session updates,
//  in both plain and app mode, and saved assistant reasoning must be replayed
//  the same way. These tests fail if the thinking stream stops being sent.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// Captures the exact JSON-RPC messages the bridge puts on the wire.
private final class ACPThinkingWire: Sendable {
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

    /// Ordered wire trace of update kinds and custom notification methods.
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

    func sessionIDs(forUpdateKind kind: String) -> [String] {
        messages.compactMap { message in
            guard message["method"]?.acpStringValue == "session/update",
                  let update = message["params"]?.objectValue?["update"]?.objectValue,
                  update["sessionUpdate"]?.acpStringValue == kind else {
                return nil
            }
            return message["params"]?.objectValue?["sessionId"]?.acpStringValue
        }
    }

    /// Every update of the given kind must carry a text content block, never a
    /// different content shape.
    func allUpdateChunksCarryTextContent(kind: String) -> Bool {
        messages.allSatisfy { message in
            guard message["method"]?.acpStringValue == "session/update",
                  let update = message["params"]?.objectValue?["update"]?.objectValue,
                  update["sessionUpdate"]?.acpStringValue == kind else {
                return true
            }
            let content = update["content"]?.objectValue
            return content?["type"]?.acpStringValue == "text"
                && content?["text"]?.acpStringValue != nil
        }
    }

    func stopReason(for id: Int) -> String? {
        messages.first { $0["id"] == .number(Double(id)) }?
            .objectValue(forKey: "result")?["stopReason"]?.acpStringValue
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func objectValue(forKey key: String) -> [String: JSONValue]? {
        self[key]?.objectValue
    }
}

/// Backend that streams the same event shape the remote generation clients
/// produce for a reasoning model: incremental `.thought` deltas followed by
/// incremental `.content` deltas.
private actor ThinkingACPBackend: AgentRuntimeBackend {
    private var thinkingSelections: [AgentThinkingSelection?] = []

    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        self.thinkingSelections.append(thinkingSelection)
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
        "thinking-acp-model"
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
        await onEvent(.thought("Analisi"))
        await onEvent(.thought(" del problema."))
        await onEvent(.content("Ecco la risposta"))
        await onEvent(.content(" finale."))
        return DirectAgentResponse(
            text: "Ecco la risposta finale.",
            stopReason: "end_turn",
            modelID: "thinking-acp-model"
        )
    }

    func recordedThinkingSelections() -> [AgentThinkingSelection?] {
        thinkingSelections
    }
}

@Suite(.serialized)
struct ACPThinkingStreamTests {
    /// A turn's reasoning deltas must reach the ACP client as distinct, ordered
    /// `agent_thought_chunk` updates that precede the assistant message chunks.
    @Test
    func promptThinkingDeltasReachTheWireAsAgentThoughtChunks() async throws {
        let fixture = try await Self.makeFixture(
            sessionID: "acp-thinking-stream",
            appMode: false
        )

        await fixture.bridge.handleLine("""
        {"jsonrpc":"2.0","id":21,"method":"session/prompt","params":{"sessionId":"\
        \(fixture.sessionID)","prompt":[{"type":"text","text":"explain the fix"}]}}
        """)

        // Reasoning: every delta is emitted, in order, as agent_thought_chunk.
        #expect(fixture.wire.updateTexts(kind: "agent_thought_chunk")
            == ["Analisi", " del problema."])
        #expect(
            fixture.wire.updateTexts(kind: "agent_thought_chunk").joined()
                == "Analisi del problema."
        )
        // The visible reply stays on agent_message_chunk and never mixes kinds.
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk")
            == ["Ecco la risposta", " finale."])
        // The chunk payloads are ACP text content blocks for the right session.
        #expect(fixture.wire.allUpdateChunksCarryTextContent(kind: "agent_thought_chunk"))
        #expect(
            fixture.wire.sessionIDs(forUpdateKind: "agent_thought_chunk")
                .allSatisfy { $0 == fixture.sessionID }
        )
        // Wire order: all reasoning precedes the first visible message chunk.
        let trace = fixture.wire.trace()
        let lastThoughtIndex = try #require(trace.lastIndex(of: "agent_thought_chunk"))
        let firstMessageIndex = try #require(trace.firstIndex(of: "agent_message_chunk"))
        #expect(lastThoughtIndex < firstMessageIndex)
        // The turn still completes normally.
        #expect(fixture.wire.stopReason(for: 21) == "end_turn")
    }

    /// App mode routes updates through the coalescing prompt-update pipeline.
    /// Thought chunks must pass through unbatched and undropped, and must not
    /// be reordered ahead of or behind the buffered reply they precede.
    @Test
    func appModePromptThinkingDeltasAreNotBufferedAway() async throws {
        let fixture = try await Self.makeFixture(
            sessionID: "acp-thinking-stream-app",
            appMode: true
        )

        await fixture.bridge.handleLine("""
        {"jsonrpc":"2.0","id":22,"method":"session/prompt","params":{"sessionId":"\
        \(fixture.sessionID)","prompt":[{"type":"text","text":"explain again"}]}}
        """)

        // Reasoning survives the pipeline verbatim and in order.
        #expect(fixture.wire.updateTexts(kind: "agent_thought_chunk")
            == ["Analisi", " del problema."])
        // The buffered visible text is flushed as (a) coherent message chunk(s).
        let messageText = fixture.wire.updateTexts(kind: "agent_message_chunk").joined()
        #expect(messageText == "Ecco la risposta finale.")
        // Order across kinds is preserved on the wire.
        let trace = fixture.wire.trace()
        let lastThoughtIndex = try #require(trace.lastIndex(of: "agent_thought_chunk"))
        let firstMessageIndex = try #require(trace.firstIndex(of: "agent_message_chunk"))
        #expect(lastThoughtIndex < firstMessageIndex)
        #expect(fixture.wire.stopReason(for: 22) == "end_turn")
    }

    /// Saved assistant reasoning must be replayed on resume as an
    /// `agent_thought_chunk` before the replayed assistant message.
    @Test
    func replayedAssistantReasoningIsEmittedAsAgentThoughtChunk() async throws {
        let fixture = try await Self.makeFixture(
            sessionID: "acp-thinking-replay",
            appMode: false
        )
        let snapshot = AgentRuntimeSessionSnapshot(
            sessionID: fixture.sessionID,
            modelID: "thinking-acp-model",
            workingDirectoryPath: FileManager.default.temporaryDirectory.path,
            systemPrompt: nil,
            cacheKey: nil,
            history: [
                AgentRuntimeMessage(role: .user, content: "what did you conclude?"),
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "La risposta finale.",
                    reasoningContent: "Pensiero salvato."
                )
            ],
            allowedToolNames: nil,
            thinkingSelection: nil,
            preserveThinking: false
        )

        await fixture.bridge.replaySessionHistory(snapshot)

        #expect(fixture.wire.updateTexts(kind: "agent_thought_chunk") == ["Pensiero salvato."])
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk") == ["La risposta finale."])
        #expect(
            fixture.wire.sessionIDs(forUpdateKind: "agent_thought_chunk")
                .allSatisfy { $0 == fixture.sessionID }
        )
        let trace = fixture.wire.trace()
        let thoughtIndex = try #require(trace.firstIndex(of: "agent_thought_chunk"))
        let messageIndex = try #require(trace.firstIndex(of: "agent_message_chunk"))
        #expect(thoughtIndex < messageIndex)
    }

    /// The session-level thinking selection requested over ACP must reach the
    /// backend session, so reasoning-capable providers actually stream thoughts.
    @Test
    func sessionThinkingSelectionReachesTheBackendSession() async throws {
        let fixture = try await Self.makeFixture(
            sessionID: "acp-thinking-selection",
            appMode: false
        )

        await fixture.bridge.handleLine(#"""
        {"jsonrpc":"2.0","id":23,"method":"session/new","params":{"cwd":"\#(FileManager.default.temporaryDirectory.path)","mcpServers":[],"thinkingSelection":"medium"}}
        """#)

        // The runtime backend is resolved lazily on the first prompt, so the
        // turn below is what hydrates the new session into the backend.
        await fixture.bridge.handleLine("""
        {"jsonrpc":"2.0","id":24,"method":"session/prompt","params":{"sessionId":"\
        \(Self.lastCreatedSessionID(in: fixture.wire))","prompt":[{"type":"text","text":"hi"}]}}
        """)

        #expect(fixture.wire.stopReason(for: 24) == "end_turn")
        #expect(fixture.wire.updateTexts(kind: "agent_thought_chunk") == ["Analisi", " del problema."])
        let selections = await fixture.backend.recordedThinkingSelections()
        // The selection that reached the hydrated `session/new` session must be
        // the requested one; the pre-installed fixture session carries nil.
        #expect(selections.contains(.some(.medium)))
        #expect(!selections.contains(.some(.off)))
        #expect(selections.last == .some(.medium))
    }

    private static func lastCreatedSessionID(in wire: ACPThinkingWire) -> String {
        wire.sessionIDs(forUpdateKind: "session_info_update").last
            ?? "acp-thinking-selection"
    }

    private static func makeFixture(
        sessionID: String,
        appMode: Bool
    ) async throws -> (
        bridge: ZenCODEACPBridge,
        backend: ThinkingACPBackend,
        wire: ACPThinkingWire,
        sessionID: String
    ) {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(sessionID, isDirectory: true)
        let backend = ThinkingACPBackend()
        let wire = ACPThinkingWire()
        let configuration = try AgentConfiguration(
            hostedModelID: "thinking-model",
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [
                AgentSettingsModelManifest(
                    id: "thinking-model",
                    kind: .remoteAPI,
                    modelID: "local/thinking-model",
                    thinkingOptions: [.off, .medium, .high],
                    defaultThinkingSelection: .medium
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
            modelID: "thinking-model",
            workingDirectory: workingDirectory,
            systemPrompt: "ACP thinking stream test",
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
