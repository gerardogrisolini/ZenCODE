//
//  ACPSessionPersistenceTests+XcodeContext.swift
//  ZenCODE
//
//  The context Xcode sends before the operator's text reaches the model and
//  stays in the saved `history`, but the saved session is named after, and
//  presents (`transcriptHistory`), the operator's text alone, also after a
//  restart of `zen --acp`.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

extension ACPSessionPersistenceTests {
    // MARK: - Context sent by Xcode

    /// The blocks current Xcode releases send: the `<system-reminder>`, the
    /// project structure, then the operator's text.
    static func xcodeBlocks(operatorText: String) -> [[String: Any]] {
        [
            ["type": "text", "text": "<system-reminder>## Xcode\n\nYou are working in Xcode.</system-reminder>"],
            [
                "type": "text",
                "text": "Project structure (these are Xcode workspace-relative paths):\nA/B.swift\n\n"
                    + "The user has no file currently open.\n",
            ],
            ["type": "text", "text": operatorText],
        ]
    }

    /// `session/prompt` with several content blocks, as Xcode sends it.
    static func promptRequest(id: Int, sessionID: String, blocks: [[String: Any]]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/prompt",
            "params": [
                "sessionId": sessionID,
                "prompt": blocks,
            ] as [String: Any],
        ]
    }

    /// The saved session is named after the operator's text and presents it
    /// in its transcript, while its history keeps the whole prompt the model
    /// got; everything else is the same in both.
    @Test
    func theXcodeContextIsNeitherTheNameNorTheTranscriptOfTheSavedSession() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let wire = ACPPersistenceWire()
            let backend = ACPPersistenceBackend()
            let bridge = try Self.makeBridge(wire: wire, backend: backend, workspace: workspace)
            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: workspace))
            let sessionID = try #require(wire.sessionID(ofResponse: 1))
            await bridge.handleMessage(Self.promptRequest(
                id: 2,
                sessionID: sessionID,
                blocks: Self.xcodeBlocks(operatorText: "Domanda vera")
            ))
            #expect(wire.stopReason(id: 2) == "end_turn")
            await bridge.shutdown()

            // The model still gets the context.
            let prompt = try #require(await backend.observations.last?.prompt)
            #expect(prompt.hasPrefix("<system-reminder>"))
            #expect(prompt.contains("Project structure ("))
            #expect(prompt.hasSuffix("Domanda vera"))

            let saved = try TerminalSessionStore.savedSessions(for: workspace)
            let session = try #require(saved.first)
            #expect(saved.count == 1)
            #expect(session.name == "Domanda vera")
            #expect(session.autosaveChannel == TerminalSavedSession.acpAutosaveChannel)

            let transcript = try #require(session.transcriptHistory)
            #expect(transcript.first?.role == .user)
            #expect(transcript.first?.content == "Domanda vera")
            #expect(transcript.count == session.history.count)
            // The history is what the model saw.
            #expect(session.history.first?.content == prompt)
            #expect(session.history.first?.content.contains("<system-reminder>") == true)
            #expect(session.history.first?.content.contains("Project structure (") == true)
            // Only the user message differs.
            #expect(transcript.filter { $0.role != .user } == session.history.filter { $0.role != .user })
            #expect(session.displayHistory.first?.content == "Domanda vera")
        }
    }

    /// A restored session goes on presenting the operator's text of the turns
    /// saved before the restart, next to the turns after it, with or without
    /// context, and keeps its name.
    @Test(arguments: ["session/load", "session/resume"])
    func theOperatorTextOfEveryTurnSurvivesARestart(method: String) async throws {
        try await Self.withSupportDirectory { _, workspace in
            let firstWire = ACPPersistenceWire()
            let first = try Self.makeBridge(wire: firstWire, backend: ACPPersistenceBackend(), workspace: workspace)
            await first.handleMessage(Self.newSessionRequest(id: 1, workspace: workspace))
            let sessionID = try #require(firstWire.sessionID(ofResponse: 1))
            await first.handleMessage(Self.promptRequest(
                id: 2,
                sessionID: sessionID,
                blocks: Self.xcodeBlocks(operatorText: "Domanda vera")
            ))
            #expect(firstWire.stopReason(id: 2) == "end_turn")
            await first.shutdown()

            let wire = ACPPersistenceWire()
            let restarted = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await restarted.handleMessage(Self.restoreRequest(method, id: 1, sessionID: sessionID, workspace: workspace))
            #expect(wire.result(id: 1) != nil)
            await restarted.handleMessage(Self.promptRequest(
                id: 2,
                sessionID: sessionID,
                blocks: Self.xcodeBlocks(operatorText: "Seconda domanda")
            ))
            await restarted.handleMessage(Self.promptRequest(id: 3, sessionID: sessionID, text: "Terza domanda"))
            #expect(wire.stopReason(id: 2) == "end_turn")
            #expect(wire.stopReason(id: 3) == "end_turn")
            await restarted.shutdown()

            let saved = try TerminalSessionStore.savedSessions(for: workspace)
            let session = try #require(saved.first)
            #expect(saved.count == 1)
            #expect(session.name == "Domanda vera")
            let transcript = try #require(session.transcriptHistory)
            #expect(transcript.filter { $0.role == .user }.map(\.content) == [
                "Domanda vera",
                "Seconda domanda",
                "Terza domanda",
            ])
            let history = session.history.filter { $0.role == .user }.map(\.content)
            #expect(history.count == 3)
            #expect(history[0].contains("<system-reminder>") && history[0].hasSuffix("Domanda vera"))
            #expect(history[1].contains("<system-reminder>") && history[1].hasSuffix("Seconda domanda"))
            #expect(history[2] == "Terza domanda")
            #expect(transcript.count == session.history.count)
            #expect(transcript.filter { $0.role != .user } == session.history.filter { $0.role != .user })
        }
    }

    /// A prompt without Xcode's context leaves no transcript, even among the
    /// turns of a session that has one for another prompt.
    @Test
    func aSessionWithoutXcodeContextSavesNoTranscript() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: workspace))
            let sessionID = try #require(wire.sessionID(ofResponse: 1))
            await bridge.handleMessage(Self.promptRequest(
                id: 2,
                sessionID: sessionID,
                blocks: [
                    ["type": "text", "text": "Question"],
                    ["type": "resource", "resource": ["uri": "file:///A/B.swift", "text": "let a = 1"]],
                ]
            ))
            #expect(wire.stopReason(id: 2) == "end_turn")
            await bridge.shutdown()

            let session = try #require(try TerminalSessionStore.savedSessions(for: workspace).first)
            #expect(session.transcriptHistory == nil)
            #expect(session.name.hasPrefix("Question"))
        }
    }
}
