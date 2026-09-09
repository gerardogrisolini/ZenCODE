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

/// Backend with configurable runtime events for exact ACP wire assertions.
enum ThinkingACPTermination: String, Sendable {
    case success, cancelled, failure
}

private enum ThinkingACPFailure: Error {
    case interrupted
}

private actor ThinkingACPBackend: AgentRuntimeBackend {
    private var thinkingSelections: [AgentThinkingSelection?] = []
    private var prompts: [String] = []
    private var summaryCountsAtGeneration: [Int] = []
    private let wire: ACPThinkingWire?
    private let events: [DirectAgentEvent]
    private let termination: ThinkingACPTermination

    init(events: [DirectAgentEvent] = [
        .thought("Analisi"), .thought(" del problema."),
        .content("Ecco la risposta"), .content(" finale.")
    ], wire: ACPThinkingWire? = nil, termination: ThinkingACPTermination = .success) {
        self.events = events
        self.termination = termination
        self.wire = wire
    }

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
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        summaryCountsAtGeneration.append(
            wire?.updateTexts(kind: "agent_message_chunk")
                .filter { $0.hasPrefix("Agent:") }.count ?? 0
        )
        for event in events {
            await onEvent(event)
        }
        switch termination {
        case .success: break
        case .cancelled: throw CancellationError()
        case .failure: throw ThinkingACPFailure.interrupted
        }
        return DirectAgentResponse(
            text: "Ecco la risposta finale.",
            stopReason: "end_turn",
            modelID: "thinking-acp-model"
        )
    }

    func recordedPrompts() -> [String] { prompts }

    func recordedSummaryCounts() -> [Int] { summaryCountsAtGeneration }

    func recordedThinkingSelections() -> [AgentThinkingSelection?] {
        thinkingSelections
    }
}

@Suite(.serialized)
struct ACPThinkingStreamTests {
    private static let initialSummary =
        "Agent: Default · Model: thinking-model · Thinking: Default\n\n"
    /// Lifecycle and diagnostic events are not model output, including retries.
    /// Classification must depend on the event type, never on text prefixes.
    @Test(arguments: [false, true], [false, true])
    func onlyModelThoughtsReachTheReasoningChannel(
        appMode: Bool,
        includesThoughts: Bool
    ) async throws {
        let thoughts = ["Remote request: ragionamento autentico\n", "  perché è così. 🧠"]
        var events: [DirectAgentEvent] = [
            .modelLoaded("MODEL_SENTINEL"),
            .status("STATUS_SENTINEL"),
            .diagnostic("Remote request: REQUEST_SENTINEL"),
            .diagnostic("DIAGNOSTIC_SENTINEL")
        ]
        if includesThoughts { events.append(.thought(thoughts[0])) }
        events += [
            .diagnostic("Retrying remote request."),
            .modelLoaded("RETRY_MODEL_SENTINEL"),
            .status("RETRY_STATUS_SENTINEL")
        ]
        if includesThoughts { events.append(.thought(thoughts[1])) }
        events += [
            .content("Ecco la risposta"),
            .diagnostic("RETRY_DIAGNOSTIC_SENTINEL"),
            .status("FINAL_STATUS_SENTINEL"),
            .content(" finale."),
            .diagnostic("Generation done: METRICS_SENTINEL")
        ]
        let fixture = try await Self.makeFixture(
            sessionID: "acp-thinking-isolation-\(UUID().uuidString)",
            appMode: appMode,
            events: events
        )

        await fixture.bridge.handleLine("""
        {"jsonrpc":"2.0","id":25,"method":"session/prompt","params":{"sessionId":"\
        \(fixture.sessionID)","prompt":[{"type":"text","text":"explain"}]}}
        """)

        #expect(fixture.wire.updateTexts(kind: "agent_thought_chunk")
            == (includesThoughts ? thoughts : []))
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").joined()
            == Self.initialSummary + "Ecco la risposta finale.")
        #expect(fixture.wire.allUpdateChunksCarryTextContent(kind: "agent_thought_chunk"))
        #expect(fixture.wire.sessionIDs(forUpdateKind: "agent_thought_chunk")
            .allSatisfy { $0 == fixture.sessionID })
        #expect(fixture.wire.stopReason(for: 25) == "end_turn")
    }

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
            == [Self.initialSummary, "Ecco la risposta", " finale."])
        // The chunk payloads are ACP text content blocks for the right session.
        #expect(fixture.wire.allUpdateChunksCarryTextContent(kind: "agent_thought_chunk"))
        #expect(
            fixture.wire.sessionIDs(forUpdateKind: "agent_thought_chunk")
                .allSatisfy { $0 == fixture.sessionID }
        )
        // The configuration summary precedes reasoning, which precedes the reply.
        let trace = fixture.wire.trace()
        let firstThoughtIndex = try #require(trace.firstIndex(of: "agent_thought_chunk"))
        let lastThoughtIndex = try #require(trace.lastIndex(of: "agent_thought_chunk"))
        let firstMessageIndex = try #require(trace.firstIndex(of: "agent_message_chunk"))
        let lastMessageIndex = try #require(trace.lastIndex(of: "agent_message_chunk"))
        #expect(firstMessageIndex < firstThoughtIndex)
        #expect(lastThoughtIndex < lastMessageIndex)
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
        #expect(messageText == Self.initialSummary + "Ecco la risposta finale.")
        // Order across kinds is preserved on the wire.
        let trace = fixture.wire.trace()
        let lastThoughtIndex = try #require(trace.lastIndex(of: "agent_thought_chunk"))
        let firstMessageIndex = try #require(trace.firstIndex(of: "agent_message_chunk"))
        let lastMessageIndex = try #require(trace.lastIndex(of: "agent_message_chunk"))
        #expect(firstMessageIndex < lastThoughtIndex)
        #expect(lastThoughtIndex < lastMessageIndex)
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

    @Test(arguments: [false, true])
    func initialSummaryIsVisibleBeforeGenerationAndOnlyOnce(appMode: Bool) async throws {
        let fixture = try await Self.makeFixture(
            sessionID: "acp-summary-\(UUID().uuidString)", appMode: appMode
        )
        for (index, prompt) in ["first prompt", "second prompt"].enumerated() {
            try await fixture.bridge.prompt(id: .number(Double(index + 1)), params: [
                "sessionId": fixture.sessionID, "prompt": prompt
            ])
        }
        let summaries = fixture.wire.updateTexts(kind: "agent_message_chunk")
            .filter { $0.hasPrefix("Agent:") }
        #expect(summaries == [Self.initialSummary])
        #expect(await fixture.backend.recordedSummaryCounts() == [1, 1])
        #expect(await fixture.backend.recordedPrompts() == ["first prompt", "second prompt"])
        let snapshot = try #require(await fixture.bridge.sessionRunner.snapshotSession(id: fixture.sessionID))
        #expect(!snapshot.history.contains { $0.content.contains("Agent: Default · Model:") })
        #expect(fixture.wire.updateTexts(kind: "agent_thought_chunk")
            == ["Analisi", " del problema.", "Analisi", " del problema."])
    }

    @Test(arguments: [false, true])
    func immediateCommandsAndRejectedPromptsDoNotConsumeSummary(appMode: Bool) async throws {
        let fixture = try await Self.makeFixture(
            sessionID: "acp-summary-command-\(UUID().uuidString)", appMode: appMode
        )
        await #expect(throws: (any Error).self) {
            try await fixture.bridge.prompt(id: .number(1), params: [
                "sessionId": fixture.sessionID, "prompt": "   "
            ])
        }
        try await fixture.bridge.prompt(id: .number(2), params: [
            "sessionId": fixture.sessionID, "prompt": "/plan status"
        ])
        #expect(await fixture.backend.recordedPrompts().isEmpty)
        #expect(!fixture.wire.updateTexts(kind: "agent_message_chunk").contains { $0.hasPrefix("Agent:") })
        try await fixture.bridge.prompt(id: .number(3), params: [
            "sessionId": fixture.sessionID, "prompt": "@Developer explain"
        ])
        let summaries = fixture.wire.updateTexts(kind: "agent_message_chunk")
            .filter { $0.hasPrefix("Agent:") }
        #expect(summaries.count == 1)
        #expect(summaries.first?.hasPrefix("Agent: Developer · Model:") == true)
        #expect(await fixture.backend.recordedPrompts() == ["explain"])
        #expect(await fixture.backend.recordedSummaryCounts() == [1])
    }

    @Test
    func firstSummaryReflectsThinkingReconfigurationBeforeMention() async throws {
        let fixture = try await Self.makeFixture(
            sessionID: "acp-summary-current-\(UUID().uuidString)", appMode: false
        )
        await fixture.bridge.handleLine("""
        {"jsonrpc":"2.0","id":1,"method":"session/set_config_option","params":{"sessionId":"\(fixture.sessionID)","configId":"thinking","value":"high"}}
        """)
        try await fixture.bridge.prompt(id: .number(2), params: [
            "sessionId": fixture.sessionID, "prompt": "@Developer explain"
        ])
        let summaries = fixture.wire.updateTexts(kind: "agent_message_chunk")
            .filter { $0.hasPrefix("Agent:") }
        #expect(summaries == [
            "Agent: Developer · Model: thinking-model · Thinking: \(AgentThinkingSelection.high.displayTitle)\n\n"
        ])
        #expect(await fixture.backend.recordedPrompts() == ["explain"])
        #expect(await fixture.backend.recordedSummaryCounts() == [1])
    }

    @Test
    func mentionAndReconfigurationPreserveSummaryAcrossRefresh() async throws {
        let fixture = try await Self.makeFixture(
            sessionID: "acp-summary-refresh-\(UUID().uuidString)", appMode: false
        )
        try await fixture.bridge.prompt(id: .number(1), params: [
            "sessionId": fixture.sessionID, "prompt": "first"
        ])
        await fixture.bridge.handleLine("""
        {"jsonrpc":"2.0","id":2,"method":"session/set_model","params":{"sessionId":"\(fixture.sessionID)","modelId":"thinking-model"}}
        """)
        await fixture.bridge.handleLine("""
        {"jsonrpc":"2.0","id":3,"method":"session/set_config_option","params":{"sessionId":"\(fixture.sessionID)","configId":"thinking","value":"high"}}
        """)
        let configured = try #require(await fixture.bridge.initialSummaryStateForTesting(sessionID: fixture.sessionID))
        #expect(configured.thinkingSelection == .high)
        #expect(configured.presented)
        try await fixture.bridge.prompt(id: .number(4), params: [
            "sessionId": fixture.sessionID, "prompt": "@Developer second"
        ])
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk")
            .filter { $0.hasPrefix("Agent:") } == [Self.initialSummary])
        #expect(await fixture.backend.recordedSummaryCounts() == [1, 1])
    }

    @Test(arguments: ["session/load", "session/resume"])
    func restoredIncarnationShowsSummaryAgain(method: String) async throws {
        let fixture = try await Self.makeFixture(
            sessionID: "acp-summary-restore-\(UUID().uuidString)", appMode: false
        )
        try await fixture.bridge.prompt(id: .number(1), params: [
            "sessionId": fixture.sessionID, "prompt": "first"
        ])
        let original = try #require(await fixture.bridge.initialSummaryStateForTesting(sessionID: fixture.sessionID))
        await fixture.bridge.handleLine("""
        {"jsonrpc":"2.0","id":2,"method":"session/close","params":{"sessionId":"\(fixture.sessionID)"}}
        """)
        await fixture.bridge.handleLine("""
        {"jsonrpc":"2.0","id":3,"method":"\(method)","params":{"sessionId":"\(fixture.sessionID)","history":[{"role":"user","content":"saved question"},{"role":"assistant","content":"saved answer"}],"modelId":"thinking-model","thinkingSelection":"high","mcpServers":[]}}
        """)
        let restored = try #require(await fixture.bridge.initialSummaryStateForTesting(sessionID: fixture.sessionID))
        #expect(restored.epoch != original.epoch)
        #expect(!restored.presented)
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk")
            .filter { $0.hasPrefix("Agent:") }.count == 1)
        try await fixture.bridge.prompt(id: .number(4), params: [
            "sessionId": fixture.sessionID, "prompt": "continue"
        ])
        let summaries = fixture.wire.updateTexts(kind: "agent_message_chunk")
            .filter { $0.hasPrefix("Agent:") }
        #expect(summaries.count == 2)
        #expect(summaries.last?.contains("Thinking: \(AgentThinkingSelection.high.displayTitle)") == true)
        #expect(await fixture.backend.recordedSummaryCounts() == [1, 2])
    }

    @Test
    func summaryUsesCurrentConfigurationAndHonestThinkingFallbacks() async throws {
        let fixture = try await Self.makeFixture(
            sessionID: "acp-summary-labels-\(UUID().uuidString)", appMode: false
        )
        let cases: [(String, AgentThinkingSelection?, String)] = [
            ("thinking-model", nil, "Default"),
            ("plain-model", nil, "Not supported"),
            ("unknown-model", nil, "Default"),
            ("thinking-model", AgentThinkingSelection.off, AgentThinkingSelection.off.displayTitle),
            ("thinking-model", AgentThinkingSelection.high, AgentThinkingSelection.high.displayTitle)
        ]
        for (modelID, selection, expected) in cases {
            let configuration = AgentCoreSessionConfiguration(
                sessionID: fixture.sessionID, modelID: modelID,
                agentID: "current-agent", agentName: "Current Agent",
                workingDirectory: FileManager.default.temporaryDirectory,
                systemPrompt: nil, cacheKey: nil, history: [],
                thinkingSelection: selection
            )
            let summary = await fixture.bridge.initialSummaryForTesting(configuration: configuration)
            #expect(summary == "Agent: Current Agent · Model: \(modelID) · Thinking: \(expected)\n\n")
        }
    }

    private static func lastCreatedSessionID(in wire: ACPThinkingWire) -> String {
        wire.sessionIDs(forUpdateKind: "session_info_update").last
            ?? "acp-thinking-selection"
    }

    @Test(arguments: [false, true], [
        AgentProtocolProfileID.openAIChatGPTSubscription,
        .anthropicClaudeSubscription,
        .openAIResponses,
    ])
    func formattingIsScopedToConfiguredChatGPTProvider(
        appMode: Bool, protocolProfile: AgentProtocolProfileID
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-thought-format-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            try Self.installThinkingProvider(protocolProfile)
            let rawThought = "**Riduco il problema a sottoinsiemi****Verifico**\n\n"
            let fixture = try await Self.makeFixture(
                sessionID: "acp-format-\(UUID().uuidString)", appMode: appMode,
                events: [.thought("*"), .thought("*Riduco il pro"),
                         .diagnostic("retry diagnostic"),
                         .thought("blema a sottoinsiemi*"), .thought("***Verifico**\n"),
                         .thought("\n"), .content("**Risposta** *invariata*")]
            )
            try await fixture.bridge.prompt(id: .number(70), params: [
                "sessionId": fixture.sessionID, "prompt": "explain"
            ])
            let expected = protocolProfile == .openAIChatGPTSubscription
                ? "Riduco il problema a sottoinsiemi\nVerifico" : rawThought
            let thoughtText = fixture.wire.updateTexts(kind: "agent_thought_chunk").joined()
            #expect(thoughtText == expected)
            if protocolProfile == .openAIChatGPTSubscription {
                #expect(!thoughtText.contains("\n\n"))
                #expect(!thoughtText.hasSuffix("\n"))
                var prefix = ""
                for chunk in fixture.wire.updateTexts(kind: "agent_thought_chunk") {
                    prefix += chunk
                    #expect(prefix.unicodeScalars.last?.properties.isWhitespace != true)
                }
                #expect(!thoughtText.contains("\r"))
            }
            #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").joined()
                .hasSuffix("**Risposta** *invariata*"))
            #expect(fixture.wire.allUpdateChunksCarryTextContent(kind: "agent_thought_chunk"))
            #expect(fixture.wire.stopReason(for: 70) == "end_turn")
            await fixture.bridge.shutdown()
        }
    }

    @Test(arguments: [false, true], [
        ThinkingACPTermination.success, .cancelled, .failure,
    ])
    func promptExitLeavesNoTrailingWhitespaceOrStateLeak(
        appMode: Bool, termination: ThinkingACPTermination
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-thought-exit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            try Self.installThinkingProvider(.openAIChatGPTSubscription)
            let fixture = try await Self.makeFixture(
                sessionID: "acp-exit-\(UUID().uuidString)", appMode: appMode,
                events: [.thought("**Ultimo blocco*"), .thought("*")],
                termination: termination
            )
            for id in [71, 72] {
                let previousChunks = fixture.wire.updateTexts(kind: "agent_thought_chunk").count
                await fixture.bridge.handleLine("""
                {"jsonrpc":"2.0","id":\(id),"method":"session/prompt","params":{"sessionId":"\(fixture.sessionID)","prompt":"explain"}}
                """)
                if termination != .failure {
                    #expect(fixture.wire.stopReason(for: id)
                        == (termination == .cancelled ? "cancelled" : "end_turn"))
                }
                let segment = Array(fixture.wire.updateTexts(kind: "agent_thought_chunk")
                    .dropFirst(previousChunks))
                #expect(segment == ["Ultimo blocco"])
            }
            #expect(fixture.wire.updateTexts(kind: "agent_thought_chunk")
                == ["Ultimo blocco", "Ultimo blocco"])
            await fixture.bridge.shutdown()
        }
    }

    @Test
    func replayDoesNotAssumeCurrentProviderIsHistoricalProvenance() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-thought-replay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            try Self.installThinkingProvider(.openAIChatGPTSubscription)
            let fixture = try await Self.makeFixture(
                sessionID: "acp-replay-\(UUID().uuidString)", appMode: false
            )
            let original = AgentRuntimeMessage(
                role: .assistant, content: "**Finale**", reasoningContent: "**Origine ignota**"
            )
            let snapshot = AgentRuntimeSessionSnapshot(
                sessionID: fixture.sessionID, modelID: "thinking-model",
                workingDirectoryPath: directory.path, systemPrompt: nil, cacheKey: nil,
                history: [original], allowedToolNames: nil,
                thinkingSelection: nil, preserveThinking: true
            )
            await fixture.bridge.replaySessionHistory(snapshot)
            #expect(fixture.wire.updateTexts(kind: "agent_thought_chunk") == ["**Origine ignota**"])
            #expect(fixture.wire.updateTexts(kind: "agent_message_chunk") == ["**Finale**"])
            #expect(snapshot.history == [original])
            await fixture.bridge.shutdown()
        }
    }

    @Test(arguments: [false, true])
    func formattingStreamsBeforeTurnEndAndFlushesBeforeToolOrAnswer(buffersUpdates: Bool) async throws {
        let wire = ACPThinkingWire()
        let pipeline = ACPPromptUpdatePipeline(
            sessionID: "format-pipeline", writer: ACPWriter(sink: wire.sink),
            buffer: ACPPromptUpdateBuffer(), buffersUpdates: buffersUpdates,
            normalizesChatGPTThoughts: true
        )
        func thought(_ text: String) async {
            await pipeline.enqueue(.init(kind: .consume(
                ZenCODEACPBridge.textChunkJSONUpdate(kind: "agent_thought_chunk", text: text)
            ))).value
            let chunks = wire.updateTexts(kind: "agent_thought_chunk")
            for chunk in chunks {
                #expect(chunk.unicodeScalars.last?.properties.isWhitespace != true)
            }
        }
        await thought("**Sto ragio")
        #expect(wire.updateTexts(kind: "agent_thought_chunk").joined() == "Sto ragio")
        await thought("nando*")
        await pipeline.enqueue(.init(kind: .flushThenNotify(
            method: "_zencode/usage/subscription", params: .object([:])
        ))).value
        await thought("*")
        await pipeline.enqueue(.init(kind: .consume(.object([
            "sessionUpdate": .string("tool_call"), "toolCallId": .string("test-tool"),
            "title": .string("Test tool"), "status": .string("pending"),
        ])))).value
        #expect(wire.updateTexts(kind: "agent_thought_chunk").joined() == "Sto ragionando")
        let firstSegmentChunkCount = wire.updateTexts(kind: "agent_thought_chunk").count
        let trace = wire.trace()
        let toolIndex = try #require(trace.firstIndex(of: "tool_call"))
        let thoughtIndex = try #require(trace.lastIndex(of: "agent_thought_chunk"))
        #expect(thoughtIndex < toolIndex)
        await thought("\r\n **Dopo il tool**\r\n")
        await thought("*")
        await thought("")
        await thought("*")
        #expect(wire.updateTexts(kind: "agent_thought_chunk")
            .dropFirst(firstSegmentChunkCount).joined() == "Dopo il tool")
        await thought("Altro blocco**\n")
        await pipeline.enqueue(.init(kind: .consume(
            ZenCODEACPBridge.textChunkJSONUpdate(kind: "agent_message_chunk", text: "**Finale**")
        ))).value
        await pipeline.enqueue(.init(kind: .flush)).value
        #expect(wire.updateTexts(kind: "agent_thought_chunk")
            .dropFirst(firstSegmentChunkCount).joined() == "Dopo il tool\nAltro blocco")
        #expect(wire.updateTexts(kind: "agent_message_chunk").joined() == "**Finale**")
        let afterAnswerChunkCount = wire.updateTexts(kind: "agent_thought_chunk").count
        await thought("**Nuovo segmento** ")
        await pipeline.enqueue(.init(kind: .flush)).value
        #expect(wire.updateTexts(kind: "agent_thought_chunk")
            .dropFirst(afterAnswerChunkCount).joined() == "Nuovo segmento")
    }

    private static func installThinkingProvider(_ protocolProfile: AgentProtocolProfileID) throws {
        let isAnthropic = protocolProfile == .anthropicClaudeSubscription
        let provider = AgentRemoteProvider(
            name: "Deliberately unrelated display name", baseURL: "https://example.invalid/v1",
            modelID: "same-model-for-every-provider",
            providerProfileID: isAnthropic ? .anthropic : .openAI,
            protocolProfileID: protocolProfile,
            authPolicy: isAnthropic ? .anthropicSubscription
                : (protocolProfile == .openAIChatGPTSubscription ? .chatGPTSubscription : .apiKeyRequired)
        )
        try AgentSettingsManifestStore.save(AgentSettingsManifest(models: [
            AgentSettingsModelManifest(
                id: "thinking-model", kind: .remoteAPI,
                modelID: "same-model-for-every-provider", provider: provider
            ),
        ]))
    }

    private static func makeFixture(
        sessionID: String,
        appMode: Bool,
        events: [DirectAgentEvent]? = nil,
        termination: ThinkingACPTermination = .success
    ) async throws -> (
        bridge: ZenCODEACPBridge,
        backend: ThinkingACPBackend,
        wire: ACPThinkingWire,
        sessionID: String
    ) {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(sessionID, isDirectory: true)
        let wire = ACPThinkingWire()
        let backend = ThinkingACPBackend(
            events: events ?? [.thought("Analisi"), .thought(" del problema."),
                               .content("Ecco la risposta"), .content(" finale.")],
            wire: wire,
            termination: termination
        )
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
                ),
                AgentSettingsModelManifest(
                    id: "plain-model", kind: .remoteAPI, modelID: "local/plain-model"
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

private extension ZenCODEACPBridge {
    func initialSummaryStateForTesting(
        sessionID: String
    ) -> (epoch: UInt64, presented: Bool, thinkingSelection: AgentThinkingSelection?)? {
        guard let session = sessions[sessionID] else { return nil }
        return (session.epoch, session.hasPresentedInitialConfiguration, session.configuration.thinkingSelection)
    }

    func initialSummaryForTesting(configuration: AgentCoreSessionConfiguration) -> String {
        initialConfigurationSummary(for: sessionState(configuration: configuration))
    }
}
