//
//  ACPSessionReplayCharacterizationTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// The exact wire of `session/load`'s history replay
/// (``ZenCODEACPBridge/replaySessionHistory(_:)``), pinned on a history with
/// every element a runtime history holds: prompts, a blank prompt with
/// attachments, blocks with and without reasoning, a block of blank text,
/// tool calls with and without an id and their results, a failed result, and
/// the transcript's truncation marker. The golden was captured from the
/// replay that walked the runtime messages, before the replay rendered the
/// log entries rebuilt from them (``ChatTurnEntry/kinds(fromTranscript:)``),
/// so it proves the two are the same wire.
@Suite(.serialized)
struct ACPSessionReplayCharacterizationTests {
    @Test
    func replayingAHistoryPutsTheSameMessagesOnTheWire() async throws {
        let wire = ReplayWire()
        let bridge = try Self.makeBridge(wire: wire)
        let sessionID = "acp-replay-characterization"

        await bridge.replaySessionHistory(AgentRuntimeSessionSnapshot(
            sessionID: sessionID,
            modelID: "replay-model",
            workingDirectoryPath: FileManager.default.temporaryDirectory.path,
            systemPrompt: nil,
            cacheKey: nil,
            history: Self.history,
            allowedToolNames: nil,
            thinkingSelection: nil,
            preserveThinking: false
        ))

        #expect(try wire.messages() == Self.golden(sessionID: sessionID))
    }

    // MARK: - Fixture

    /// A history with every element a runtime history holds, oldest first.
    static let history: [AgentRuntimeMessage] = [
        // The transcript's truncation marker (`ChatSessionController`).
        AgentRuntimeMessage(
            role: .system,
            content: "[Earlier detailed transcript omitted to keep session memory bounded.]"
        ),
        AgentRuntimeMessage(role: .user, content: "  Read the parser\n"),
        AgentRuntimeMessage(
            role: .assistant,
            content: "\nI will read it.  ",
            reasoningContent: "  The parser is in Sources.  ",
            toolCalls: [
                AgentRuntimeToolCall(id: "call-1", name: "local.readFile", argumentsJSON: #"{"path":"Parser.swift"}"#),
                AgentRuntimeToolCall(id: nil, name: "local.ls", argumentsJSON: "{}"),
            ]
        ),
        AgentRuntimeMessage(role: .tool, content: "struct Parser {}\n", toolCallID: "call-1", toolName: "local.readFile"),
        AgentRuntimeMessage(role: .tool, content: "", toolName: "local.ls"),
        AgentRuntimeMessage(
            role: .tool,
            content: "permission denied",
            toolCallID: "call-orphan",
            toolName: "local.exec",
            toolResultIsError: true
        ),
        AgentRuntimeMessage(role: .assistant, content: "   ", reasoningContent: "Only a thought."),
        AgentRuntimeMessage(role: .assistant, content: "The parser is fine."),
        AgentRuntimeMessage(
            role: .user,
            content: "",
            attachments: [AgentRuntimeAttachment(kind: .image, data: Data([0x89]), contentType: "image/png", originalFilename: "screen.png")]
        ),
        AgentRuntimeMessage(role: .assistant, content: "I see a screenshot.", reasoningContent: "   "),
        AgentRuntimeMessage(role: .user, content: "   "),
        AgentRuntimeMessage(
            role: .user,
            content: "Compare with this",
            attachments: [AgentRuntimeAttachment(kind: .image, data: Data([0x89]), contentType: "image/png", originalFilename: "other.png")]
        ),
        AgentRuntimeMessage(
            role: .assistant,
            content: "",
            toolCalls: [AgentRuntimeToolCall(id: "call-2", name: "local.readFile", argumentsJSON: "{}")]
        ),
        AgentRuntimeMessage(role: .tool, content: "same", toolCallID: "call-2", toolName: "local.readFile"),
        AgentRuntimeMessage(role: .assistant, content: "They match.\n\n", reasoningContent: "Compared."),
    ]

    /// The wire the replay wrote for ``history`` before it rendered the log,
    /// one JSON-RPC message per line, compared with the wire by JSON value:
    /// each line is parsed, so that neither key order nor escaping (`\/`, a
    /// tab) tells two equal messages apart. A text is escaped by the JSON
    /// encoder.
    static func golden(sessionID: String) throws -> [JSONValue] {
        func literal(_ text: String) throws -> String {
            String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        }
        func update(_ kind: String, _ text: String) throws -> String {
            #"{"jsonrpc":"2.0","method":"session\/update","params":{"sessionId":"#
                + (try literal(sessionID))
                + #","update":{"content":{"text":"#
                + (try literal(text))
                + #","type":"text"},"sessionUpdate":"#
                + (try literal(kind))
                + #"}}}"#
        }
        let lines = [
            try update("user_message_chunk", "Read the parser"),
            try update("agent_thought_chunk", "The parser is in Sources."),
            try update("agent_message_chunk", "I will read it."),
            try update("agent_thought_chunk", "Only a thought."),
            try update("agent_message_chunk", "The parser is fine."),
            try update("user_message_chunk", "Analyze the attached media."),
            try update("agent_message_chunk", "I see a screenshot."),
            try update("user_message_chunk", "Compare with this"),
            try update("agent_thought_chunk", "Compared."),
            try update("agent_message_chunk", "They match."),
        ]
        return try lines.map { line in
            try #require(ReplayWire.jsonValue(Data(line.utf8)), "Not JSON: \(line)")
        }
    }

    private static func makeBridge(wire: ReplayWire) throws -> ZenCODEACPBridge {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-replay-\(UUID().uuidString)", isDirectory: true)
        let configuration = try AgentConfiguration(
            hostedModelID: "replay-model",
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [
                AgentSettingsModelManifest(id: "replay-model", kind: .remoteAPI, modelID: "local/replay-model"),
            ],
            runMode: .acp,
            workingDirectory: workingDirectory,
            appMode: false
        )
        return ZenCODEACPBridge(configuration: configuration, writer: ACPWriter(sink: wire.sink))
    }
}

/// The messages the bridge writes, each parsed as a JSON value: the writer
/// encodes dictionaries in no fixed key order, so the comparison by value is
/// the exact one that holds across processes.
private final class ReplayWire: Sendable {
    private let storage = Mutex<[Data]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            storage.withLock { $0.append(data) }
        }
    }

    func messages() throws -> [JSONValue] {
        try storage.withLock { $0 }.map { data in
            try #require(Self.jsonValue(data), "Not JSON: \(String(decoding: data, as: UTF8.self))")
        }
    }

    static func jsonValue(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
