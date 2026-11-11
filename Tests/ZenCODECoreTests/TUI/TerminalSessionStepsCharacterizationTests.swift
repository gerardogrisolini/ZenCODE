//
//  TerminalSessionStepsCharacterizationTests.swift
//  ZenCODE
//
//  The exact terminal output, ANSI included, of the session operations whose
//  channel steps run through `ChatSessionChannelHooks`: `/sessions new` and
//  the load of a saved session whose transcript holds prompts, blocks with
//  reasoning, tool calls and their results, attachments, and the truncation
//  marker. The goldens were captured before the session steps became one
//  `incarnationDidChange(reason:)` hook, so they prove the output did not
//  move. The id a `/sessions new` mints keeps the terminal's format, and the
//  log rebuilt from a transcript is shown not to render as the transcript
//  does for a tool call without an id and an id repeated in one turn, which
//  is why the terminal keeps replaying the transcript itself; a result of an
//  earlier turn renders the same either way.
//  Every test runs in directories named by UUIDs.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@ChatSessionActor
@Suite("Terminal session steps characterization", .serialized, .timeLimit(.minutes(2)))
struct TerminalSessionStepsCharacterizationTests {
    private struct Environment {
        let root: URL
        let workspace: URL
        let support: URL
        let backend = CapturingACPBackend()

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("zencode-terminal-steps-\(UUID().uuidString)", isDirectory: true)
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            support = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        /// A terminal whose writes are captured as a terminal renders them:
        /// both channels report a terminal, so the output carries its ANSI
        /// styling, and nothing reaches a real file handle.
        @ChatSessionActor
        func makeTerminal() throws -> TerminalChat {
            let backend = backend
            let support = support
            return TerminalChat(
                configuration: try AgentConfiguration(
                    hostedModelID: "test-model",
                    explicitModelID: "test-model",
                    availableAgents: AgentProfileStore.defaultProfiles(),
                    availableModels: [
                        AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")
                    ],
                    workingDirectory: workspace
                ),
                stdinIsTerminal: false,
                sessionRunner: AgentCoreSessionRunner(
                    backendFactory: { _, _ in backend },
                    taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: support)
                ),
                telegramTransportFactory: nil,
                renderCoordinator: TerminalChatRenderCoordinator(
                    stdinIsTerminal: false,
                    standardOutput: nil,
                    standardError: nil,
                    standardOutputIsTerminal: true,
                    standardErrorIsTerminal: true,
                    cursorTopology: .separate,
                    capturesWrites: true,
                    streamingFlushDelay: nil,
                    columnWidthProvider: { 100 }
                )
            )
        }

        func savedSession(name: String, sessionID: String, history: [AgentRuntimeMessage]) -> TerminalSavedSession {
            let date = Date(timeIntervalSince1970: 1_000)
            return TerminalSavedSession(
                name: name, sessionID: sessionID, cacheKey: nil,
                workingDirectoryPath: workspace.path, createdAt: date, savedAt: date,
                modelID: "test-model", agentID: nil, agentName: nil, selectedTools: [],
                selectedSkillNames: [], thinkingSelection: nil, systemPrompt: "Test",
                history: history,
                checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: sessionID)
            )
        }
    }

    private nonisolated func withEnvironment(
        _ body: @escaping @Sendable @ChatSessionActor (Environment) async throws -> Void
    ) async throws {
        let environment = try Environment()
        defer { environment.remove() }
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(models: []),
            to: environment.support.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        )
        try await AppStorageDirectory.withSupportDirectoryURL(environment.support) {
            try await Task(name: "ZenCODE.Tests.terminal-session-steps") { @ChatSessionActor in
                try await body(environment)
            }.value
        }
    }

    /// The writes after the first `skipping` ones, as channel and text.
    private static func writes(
        of terminal: TerminalChat,
        skipping count: Int
    ) async -> [String] {
        await terminal.renderCoordinator.capturedWriteEvents().dropFirst(count).map { event in
            "\(event.channel): \(String(reflecting: event.text))"
        }
    }

    // MARK: - Session steps

    @Test
    nonisolated func aNewSessionWritesWhatItAlwaysWrote() async throws {
        try await withEnvironment { environment in
            let terminal = try environment.makeTerminal()
            try await terminal.createCurrentSession(discoverExternalTools: false)
            let before = await terminal.renderCoordinator.capturedWriteEvents().count

            await terminal.startNewSession()

            let writes = await Self.writes(of: terminal, skipping: before)
            #expect(writes == Self.newSessionGolden)
            await terminal.stopTaskGraphObserver()
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    nonisolated func aLoadedSessionWritesWhatItAlwaysWrote() async throws {
        try await withEnvironment { environment in
            let terminal = try environment.makeTerminal()
            try await terminal.createCurrentSession(discoverExternalTools: false)
            let saved = environment.savedSession(
                name: "kept",
                sessionID: "terminal-kept",
                history: Self.restoredHistory
            )
            let before = await terminal.renderCoordinator.capturedWriteEvents().count

            try await terminal.loadSavedSession(saved)

            let writes = await Self.writes(of: terminal, skipping: before)
            #expect(writes == Self.loadedSessionGolden)
            await terminal.stopTaskGraphObserver()
            await terminal.sessionHost.shutdown()
        }
    }

    /// The id of a new session has the terminal's format, the format of
    /// ``TerminalChat/newTerminalSessionID()``.
    @Test
    nonisolated func aNewSessionHasATerminalSessionID() async throws {
        try await withEnvironment { environment in
            let terminal = try environment.makeTerminal()
            try await terminal.createCurrentSession(discoverExternalTools: false)
            let previousSessionID = terminal.sessionID

            await terminal.startNewSession()

            #expect(terminal.sessionID != previousSessionID)
            #expect(Self.hasTerminalSessionIDFormat(terminal.sessionID))
            #expect(Self.hasTerminalSessionIDFormat(TerminalChat.newTerminalSessionID()))
            await terminal.stopTaskGraphObserver()
            await terminal.sessionHost.shutdown()
        }
    }

    /// `terminal-` and a lowercased UUID.
    private nonisolated static func hasTerminalSessionIDFormat(_ sessionID: String) -> Bool {
        guard sessionID.hasPrefix("terminal-") else { return false }
        let uuid = String(sessionID.dropFirst("terminal-".count))
        return UUID(uuidString: uuid) != nil && uuid == uuid.lowercased()
    }

    // MARK: - The rebuilt log

    /// What the log rebuilt from a transcript does not keep of it: a tool
    /// call without an id (the log completes it with the result without an
    /// id that follows it in its turn, so it renders completed, while the
    /// terminal pairs a result with its call by id only and renders the call
    /// as started), and a tool call id repeated in one turn (the log keeps
    /// one start). The terminal renders each of these transcripts otherwise
    /// once it passes through the log, so the restored session replays the
    /// transcript. A result whose call is in an earlier turn is no longer
    /// one of them: the log completes that call by its id, as the terminal
    /// pairs it (``theRebuiltLogRendersAResultOfAnEarlierTurnAsTheTranscript()``).
    @Test(arguments: [
        RebuiltLogCase.toolCallWithoutID,
        .repeatedToolCallID,
    ])
    nonisolated func theRebuiltLogDoesNotRenderAsTheTranscript(_ testCase: RebuiltLogCase) async throws {
        try await withEnvironment { environment in
            let (directText, throughLogText) = try await Self.renderings(of: testCase.transcript, in: environment)
            #expect(directText != throughLogText)
        }
    }

    @Test
    nonisolated func theRebuiltLogRendersAResultOfAnEarlierTurnAsTheTranscript() async throws {
        try await withEnvironment { environment in
            let transcript = RebuiltLogCase.resultOfAnEarlierTurn.transcript
            let (directText, throughLogText) = try await Self.renderings(of: transcript, in: environment)
            #expect(directText == throughLogText)
            // The call renders once, completed by the late result.
            #expect(directText.components(separatedBy: "local.readFile").count == 2)
        }
    }

    /// What the terminal writes for `transcript`, rendered directly and
    /// after it passed through the log (``ChatTurnEntry/kinds(fromTranscript:)``,
    /// then ``ChatTurnEntry/transcriptMessages(from:)``).
    @ChatSessionActor
    private static func renderings(
        of transcript: [AgentRuntimeMessage],
        in environment: Environment
    ) async throws -> (direct: String, throughLog: String) {
        let rebuilt = ChatTurnEntry.transcriptMessages(
            from: ChatTurnEntry.kinds(fromTranscript: transcript).enumerated().map { index, kind in
                ChatTurnEntry(sequence: index + 1, turnID: nil, kind: kind)
            }
        )

        let direct = try environment.makeTerminal()
        await direct.renderSavedSessionHistory(transcript)
        let throughLog = try environment.makeTerminal()
        await throughLog.renderSavedSessionHistory(rebuilt)

        let directText = await direct.renderCoordinator.capturedWriteEvents().map(\.text).joined()
        let throughLogText = await throughLog.renderCoordinator.capturedWriteEvents().map(\.text).joined()
        await direct.sessionHost.shutdown()
        await throughLog.sessionHost.shutdown()
        return (directText, throughLogText)
    }

    enum RebuiltLogCase: String, Sendable, CustomTestStringConvertible {
        case toolCallWithoutID
        case repeatedToolCallID
        case resultOfAnEarlierTurn

        var testDescription: String { rawValue }

        var transcript: [AgentRuntimeMessage] {
            switch self {
            case .toolCallWithoutID:
                return [
                    AgentRuntimeMessage(role: .user, content: "List the folder"),
                    AgentRuntimeMessage(
                        role: .assistant,
                        content: "Listing.",
                        toolCalls: [AgentRuntimeToolCall(id: nil, name: "local.ls", argumentsJSON: "{}")]
                    ),
                    AgentRuntimeMessage(role: .tool, content: "", toolName: "local.ls"),
                ]
            case .repeatedToolCallID:
                return [
                    AgentRuntimeMessage(role: .user, content: "Read it twice"),
                    AgentRuntimeMessage(
                        role: .assistant,
                        content: "First read.",
                        toolCalls: [AgentRuntimeToolCall(id: "call-1", name: "local.readFile", argumentsJSON: "{}")]
                    ),
                    AgentRuntimeMessage(role: .tool, content: "body", toolCallID: "call-1", toolName: "local.readFile"),
                    AgentRuntimeMessage(
                        role: .assistant,
                        content: "Second read.",
                        toolCalls: [AgentRuntimeToolCall(id: "call-1", name: "local.readFile", argumentsJSON: "{}")]
                    ),
                    AgentRuntimeMessage(role: .tool, content: "body", toolCallID: "call-1", toolName: "local.readFile"),
                ]
            case .resultOfAnEarlierTurn:
                return [
                    AgentRuntimeMessage(role: .user, content: "Start reading"),
                    AgentRuntimeMessage(
                        role: .assistant,
                        content: "Reading.",
                        toolCalls: [AgentRuntimeToolCall(id: "call-1", name: "local.readFile", argumentsJSON: "{}")]
                    ),
                    AgentRuntimeMessage(role: .user, content: "Go on"),
                    AgentRuntimeMessage(role: .tool, content: "late body", toolCallID: "call-1", toolName: "local.readFile"),
                ]
            }
        }
    }

    // MARK: - Fixtures

    /// A saved transcript with every element a restored session renders.
    static let restoredHistory: [AgentRuntimeMessage] = [
        // The transcript's truncation marker (`ChatSessionController`).
        AgentRuntimeMessage(
            role: .system,
            content: "[Earlier detailed transcript omitted to keep session memory bounded.]"
        ),
        AgentRuntimeMessage(
            role: .user,
            content: "Look at the parser",
            attachments: [AgentRuntimeAttachment(kind: .image, data: Data([0x89]), contentType: "image/png", originalFilename: "screen.png")]
        ),
        AgentRuntimeMessage(
            role: .assistant,
            content: "I will read it.",
            reasoningContent: "The parser is in Sources.",
            toolCalls: [
                AgentRuntimeToolCall(id: "call-1", name: "local.readFile", argumentsJSON: #"{"path":"Parser.swift"}"#),
            ]
        ),
        AgentRuntimeMessage(
            role: .tool,
            content: "struct Parser {}\nextension Parser {}",
            toolCallID: "call-1",
            toolName: "local.readFile"
        ),
        AgentRuntimeMessage(role: .assistant, content: "", reasoningContent: "Only a thought."),
        AgentRuntimeMessage(role: .assistant, content: "The parser is **fine**.\n\n- one\n- two"),
        AgentRuntimeMessage(
            role: .user,
            content: "",
            attachments: [AgentRuntimeAttachment(kind: .image, data: Data([0x89]), contentType: "image/png", originalFilename: "other.png")]
        ),
        AgentRuntimeMessage(role: .assistant, content: "I see a screenshot."),
        AgentRuntimeMessage(
            role: .tool,
            content: "permission denied",
            toolCallID: "call-orphan",
            toolName: "local.exec",
            toolResultIsError: true
        ),
        AgentRuntimeMessage(
            role: .assistant,
            content: "",
            toolCalls: [AgentRuntimeToolCall(id: "call-2", name: "local.ls", argumentsJSON: "{}")]
        ),
    ]

    /// What `/sessions new` wrote, captured before the session steps became
    /// one hook.
    static let newSessionGolden: [String] = [
        "standardError: \"\\u{1B}[38;5;110mStarted a new session.\\u{1B}[0m\\n\"",
    ]

    /// What the load of ``restoredHistory`` wrote, captured before the
    /// session steps became one hook: the active tools, the replayed
    /// transcript, then the loaded notice.
    static let loadedSessionGolden: [String] = [
        "standardError: \"\\u{1B}[38;5;110mActive tools: Skills (2)\\u{1B}[0m\\n\"",
        "standardError: \"\\n\\u{1B}[38;5;110mRestored transcript:\\u{1B}[0m\\n\"",
        "standardError: \"\\n\\u{1B}[48;5;236m> Look at the parser\\u{1B}[K\\u{1B}[0m\\n\\n\"",
        "standardError: \"\\u{1B}[90m🤔 thinking…\\u{1B}[0m\\n\\u{1B}[90mThe parser is in Sources.\\u{1B}[0m\\n\\n\"",
        "standardOutput: \"💬 I will read it.\\n\"",
        "standardOutput: \"\\n\"",
        "standardError: \"\\r\\u{1B}[2K\\u{1B}[38;5;208m🛠️  local.readFile ✅\\u{1B}[0m\\n\\n\"",
        "standardError: \"\\u{1B}[90m🤔 thinking…\\u{1B}[0m\\n\\u{1B}[90mOnly a thought.\\u{1B}[0m\\n\\n\"",
        "standardOutput: \"💬 The parser is \\u{1B}[1mfine\\u{1B}[0m.\\n\\n\\u{1B}[38;5;244m•\\u{1B}[0m one\\n\\u{1B}[38;5;244m•\\u{1B}[0m two\\n\"",
        "standardOutput: \"\\n\"",
        "standardOutput: \"💬 I see a screenshot.\\n\"",
        "standardOutput: \"\\n\"",
        "standardError: \"\\r\\u{1B}[2K\\u{1B}[38;5;208m🛠️  local.exec ✅\\u{1B}[0m\\n\\n\"",
        "standardError: \"\\r\\u{1B}[2K\\u{1B}[38;5;208m🛠️  local.ls ⏳\\u{1B}[0m\\n\"",
        "standardError: \"\\n\"",
        "standardError: \"\\u{1B}[38;5;110mLoaded session: kept (9 messages).\\u{1B}[0m\\n\"",
    ]
}
