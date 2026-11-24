//
//  ACPCommandRoutingTests+Workspace.swift
//  ZenCODE
//
//  The ACP routing of /changes and /undo: answered at once from the shared
//  controller before the coordinator parser, the patches of `/changes diff` in
//  Markdown `diff` blocks, the real reversal of the files, and the command
//  fence on both sides of it. None of them reaches the model.
//

import Foundation
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing
import ToolCore

extension ACPCommandRoutingTests {
    // MARK: - Fixtures

    private static let gitPatch = """
    diff --git a/Sources/Value.swift b/Sources/Value.swift
    --- a/Sources/Value.swift
    +++ b/Sources/Value.swift
    @@ -1 +1 @@
    -let value = 1
    +let value = 2

    """

    /// One modified file whose patch `/changes diff` shows and whose snapshot
    /// `/undo` restores.
    private static let valueEntry = TurnFileChangeSummary.Entry(
        path: "Sources/Value.swift",
        additions: 1,
        deletions: 1,
        status: .modified,
        isBinary: false,
        existedBefore: true,
        beforeDataBase64: Data("let value = 1\n".utf8).base64EncodedString(),
        patch: gitPatch
    )

    private static let summaryText = """
    🪬 Summary: 1 file  +1 -1
      modified Sources/Value.swift  +1 -1
    Use /undo to revert, /changes diff to show patches.
    """

    private struct WorkspaceFixture {
        let bridge: ZenCODEACPBridge
        let backend: ScriptedACPCommandBackend
        let wire: ACPCommandWire
        let sessionID: String
        let controller: ChatSessionController
        let workingDirectory: URL
    }

    private func makeWorkspaceFixture() async throws -> WorkspaceFixture {
        let fixture = try await makeFixture(
            sessionID: "acp-workspace-\(UUID().uuidString)",
            allowedToolNames: ["local.read"]
        )
        let controller = try #require(await fixture.bridge.workspaceControllerForTesting(
            sessionID: fixture.sessionID
        ))
        let workingDirectory = await controller.workingDirectory
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        return WorkspaceFixture(
            bridge: fixture.bridge,
            backend: fixture.backend,
            wire: fixture.wire,
            sessionID: fixture.sessionID,
            controller: controller,
            workingDirectory: workingDirectory
        )
    }

    private func writeWorkspaceFile(
        _ relativePath: String,
        _ contents: String,
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Sends `line` as a prompt and returns what the session answered.
    private func answer(
        _ line: String,
        requestID: Int,
        in fixture: WorkspaceFixture
    ) async throws -> String {
        try await fixture.bridge.prompt(
            id: .number(Double(requestID)),
            params: ["sessionId": fixture.sessionID, "prompt": line]
        )
        #expect(fixture.wire.updateTexts(kind: "user_message_chunk").last == line)
        #expect(fixture.wire.stopReason(for: requestID) == "end_turn")
        return try #require(fixture.wire.updateTexts(kind: "agent_message_chunk").last)
    }

    // MARK: - Advertisement and routing

    /// `changes` takes the `diff` argument and says so; `undo` takes none.
    @Test
    func workspaceCommandsAreAdvertisedWithTheDiffHintOnlyForChanges() async throws {
        let fixture = try await makeWorkspaceFixture()
        let commands = await fixture.bridge.workspaceAvailableCommandsForTesting(sessionID: fixture.sessionID)
        var byName: [String: [String: JSONValue]] = [:]
        for command in commands {
            if let object = command.objectValue, let name = object["name"]?.stringValue {
                byName[name] = object
            }
        }

        #expect(commands.compactMap { $0.objectValue?["name"]?.stringValue }
            == ["goal", "tasks", "changes", "undo"])
        let changes = try #require(byName["changes"])
        #expect(changes["description"]?.stringValue?.isEmpty == false)
        #expect(changes["input"]?.objectValue?["hint"]?.stringValue?.contains("diff") == true)
        let undo = try #require(byName["undo"])
        #expect(undo["description"]?.stringValue?.isEmpty == false)
        #expect(undo["input"] == nil)
    }

    /// Only the exact command tokens are the commands' own: a longer word, or
    /// another case, is an ordinary line, as in the terminal.
    @Test
    func onlyTheExactCommandTokensAreWorkspaceCommands() {
        for line in ["/changes", "/changes diff", "  /undo  ", "/undo now"] {
            #expect(ZenCODEACPBridge.isWorkspaceCommand(line), "\(line)")
        }
        for line in ["/changesx", "/Changes", "/UNDO", "undo", "changes diff", "/undone", "hello /undo"] {
            #expect(!ZenCODEACPBridge.isWorkspaceCommand(line), "\(line)")
        }
    }

    /// The client sends content blocks through JSON-RPC, not the rendered
    /// string used by the direct routing tests above.
    private func sendBlocks(_ blocks: [[String: any Sendable]], id: Int, in fixture: WorkspaceFixture) async {
        await fixture.bridge.handleMessage([
            "jsonrpc": "2.0", "id": id, "method": "session/prompt",
            "params": ["sessionId": fixture.sessionID, "prompt": blocks] as [String: Any],
        ])
    }

    @Test
    func clientWorkspaceCommandsSurviveContextBlocksAndKeepTheirArguments() async throws {
        let fixture = try await makeWorkspaceFixture()
        let edited = try writeWorkspaceFile("Sources/Value.swift", "let value = 2\n", in: fixture.workingDirectory)
        await seedWorkspaceSummary(TurnFileChangeSummary(entries: [Self.valueEntry]), in: fixture.controller)
        let reminder: [String: any Sendable] = ["type": "text", "text": "<system-reminder>Xcode context</system-reminder>"]
        let structure: [String: any Sendable] = ["type": "text", "text": "Project structure: App/App.swift"]
        let resource: [String: any Sendable] = ["type": "resource", "resource": ["text": "Project notes"]]
        let assistantContext: [String: any Sendable] = [
            "type": "text", "text": "Context for the assistant",
            "annotations": ["audience": ["assistant"]],
        ]

        await sendBlocks([reminder, structure, ["type": "text", "text": "/changes diff"]], id: 1, in: fixture)
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").last?.contains("```diff\n") == true)
        await sendBlocks([resource, ["type": "text", "text": "/changes --diff"]], id: 2, in: fixture)
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").last?.contains("```diff\n") == true)
        await sendBlocks([["type": "text", "text": "/undo now"], resource], id: 3, in: fixture)
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").last == "ZenCODE: unknown command '/undo'.")
        #expect(try String(contentsOf: edited, encoding: .utf8) == "let value = 2\n")
        await sendBlocks([assistantContext, ["type": "text", "text": "/changes"]], id: 4, in: fixture)
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").last == Self.summaryText)
        await sendBlocks([reminder, structure, ["type": "text", "text": "/undo"]], id: 5, in: fixture)
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").last == "File changes reverted.")
        #expect(try String(contentsOf: edited, encoding: .utf8) == "let value = 1\n")
        try Data("let value = 2\n".utf8).write(to: edited)
        await seedWorkspaceSummary(TurnFileChangeSummary(entries: [Self.valueEntry]), in: fixture.controller)
        await sendBlocks([["type": "text", "text": "/undo"], resource], id: 6, in: fixture)
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").last == "File changes reverted.")
        #expect(try String(contentsOf: edited, encoding: .utf8) == "let value = 1\n")
        await sendBlocks([structure, ["type": "text", "text": "/changes diff"]], id: 7, in: fixture)
        #expect(fixture.wire.updateTexts(kind: "user_message_chunk") == [
            "/changes diff", "/changes --diff", "/undo now", "/changes", "/undo", "/undo", "/changes diff",
        ])
        #expect(await fixture.backend.recordedPrompts().isEmpty)
        for id in 1...7 { #expect(fixture.wire.stopReason(for: id) == "end_turn") }
    }

    @Test
    func clientContextAndOrdinaryPromptsCannotBecomeWorkspaceCommands() async throws {
        let fixture = try await makeWorkspaceFixture()
        let edited = try writeWorkspaceFile("Sources/Value.swift", "let value = 2\n", in: fixture.workingDirectory)
        await seedWorkspaceSummary(TurnFileChangeSummary(entries: [Self.valueEntry]), in: fixture.controller)
        let prompts: [[[String: any Sendable]]] = [
            [["type": "resource", "resource": ["text": "/undo"]]],
            [["type": "text", "text": "/undo", "annotations": ["audience": ["assistant"]]]],
            [["type": "text", "text": "Explain the command /undo without running it."]],
            [["type": "text", "text": "/undo"], ["type": "text", "text": "explain this"]],
            [["type": "text", "text": "arbitrary context"], ["type": "text", "text": "/undo"]],
            [
                ["type": "text", "text": "<system-reminder>/undo</system-reminder>"],
                ["type": "text", "text": "Project structure: App/App.swift"],
                ["type": "text", "text": "What does this project do?"],
            ],
        ]
        for (index, blocks) in prompts.enumerated() {
            await sendBlocks(blocks, id: index + 1, in: fixture)
            #expect(fixture.wire.stopReason(for: index + 1) == "end_turn")
            #expect(try String(contentsOf: edited, encoding: .utf8) == "let value = 2\n")
        }
        let received = await fixture.backend.recordedPrompts()
        #expect(received.count == prompts.count)
        #expect(received.contains { $0.contains("Explain the command /undo") })
        #expect(received.contains { $0.contains("What does this project do?") })
    }

    // MARK: - /changes

    /// `/changes` answers the summary the terminal prints, whatever follows
    /// it but `diff`, without a prompt and with the stop reason of an
    /// immediate command; without a summary it says so.
    @Test
    func changesAnswersWithTheSummaryAtOnceAndNeverReachesTheModel() async throws {
        let fixture = try await makeWorkspaceFixture()
        #expect(try await answer("/changes", requestID: 1, in: fixture) == "No tracked file changes.")
        #expect(try await answer("/changes diff", requestID: 2, in: fixture) == "No tracked file changes.")

        await seedWorkspaceSummary(TurnFileChangeSummary(entries: [Self.valueEntry]), in: fixture.controller)
        for (index, line) in ["/changes", "/changes everything", "/changes diffs"].enumerated() {
            let text = try await answer(line, requestID: 3 + index, in: fixture)
            #expect(text == Self.summaryText, "\(line)")
            #expect(!text.contains("```"), "\(line)")
        }
        #expect(await fixture.backend.recordedPrompts().isEmpty)
        // Reading the changes forgets nothing.
        #expect(await workspaceSummary(of: fixture.controller)?.entries == [Self.valueEntry])
    }

    /// `/changes diff` and `/changes --diff` put the real patch in a Markdown
    /// `diff` block under the file it belongs to; no spelling of the argument
    /// leaves it out.
    @Test
    func changesDiffAndDashDiffShowTheRealPatchInAMarkdownDiffBlock() async throws {
        let fixture = try await makeWorkspaceFixture()
        await seedWorkspaceSummary(TurnFileChangeSummary(entries: [Self.valueEntry]), in: fixture.controller)

        let expected = """
        \(Self.summaryText)

        **modified `Sources/Value.swift`**  +1 -1

        ```diff
        diff --git a/Sources/Value.swift b/Sources/Value.swift
        --- a/Sources/Value.swift
        +++ b/Sources/Value.swift
        @@ -1 +1 @@
        -let value = 1
        +let value = 2
        ```
        """
        for (index, line) in ["/changes diff", "/changes --diff", "/changes DIFF", "/changes --Diff"].enumerated() {
            #expect(try await answer(line, requestID: 1 + index, in: fixture) == expected, "\(line)")
        }
        #expect(await fixture.backend.recordedPrompts().isEmpty)
    }

    /// Every kind of entry has its section: a deleted file's diff comes from
    /// the snapshot, a binary file and a file without evidence say why they
    /// have no block, and a patch that quotes Markdown cannot close its fence.
    @Test
    func changesDiffRendersEveryKindOfEntry() async throws {
        let fixture = try await makeWorkspaceFixture()
        let quoting = "diff --git a/Doc.md b/Doc.md\n--- a/Doc.md\n+++ b/Doc.md\n@@ -1 +1,3 @@\n a\n+```\n+b\n"
        await seedWorkspaceSummary(
            TurnFileChangeSummary(entries: [
                .init(
                    path: "Gone.txt", additions: 0, deletions: 1, status: .deleted, isBinary: false,
                    existedBefore: true,
                    beforeDataBase64: Data("bye\n".utf8).base64EncodedString(), patch: nil
                ),
                .init(
                    path: "Logo.png", additions: 0, deletions: 0, status: .modified, isBinary: true,
                    existedBefore: true,
                    beforeDataBase64: Data([0, 1]).base64EncodedString(), patch: nil
                ),
                .init(
                    path: "Notes.txt", additions: 1, deletions: 0, status: .modified, isBinary: false,
                    existedBefore: true,
                    beforeDataBase64: Data("n\n".utf8).base64EncodedString(), patch: nil
                ),
                .init(
                    path: "Doc.md", additions: 2, deletions: 0, status: .modified, isBinary: false,
                    existedBefore: nil, beforeDataBase64: nil, patch: quoting
                ),
            ]),
            in: fixture.controller
        )

        let text = try await answer("/changes diff", requestID: 1, in: fixture)

        #expect(text.contains("**deleted `Gone.txt`**  +0 -1\n\n```diff\n@@ -1,1 +0,0 @@\n-bye\n```"))
        #expect(text.contains("**modified `Logo.png`** (binary)\n\nExplanation: Diff unavailable: binary file evidence."))
        // A binary file has no block, and neither has a file without evidence.
        let beforeNotes = try #require(text.components(separatedBy: "**modified `Notes.txt`**").first)
        let logoToNotes = try #require(beforeNotes.components(separatedBy: "**modified `Logo.png`**").last)
        #expect(!logoToNotes.contains("```"))
        let afterNotes = try #require(text.components(separatedBy: "**modified `Notes.txt`**").last)
        #expect(afterNotes.hasPrefix("  +1 -0\n\nExplanation: \(FileChangeArtifactMapper.unavailableEvidenceExplanation)\n\n**modified `Doc.md`**"))
        #expect(text.contains("````diff\n\(quoting.dropLast())\n````"))
        #expect(await fixture.backend.recordedPrompts().isEmpty)
    }

    // MARK: - /undo

    /// `/undo` restores the files of the last summary in the session's working
    /// directory, forgets the summary, and answers as the terminal does; a
    /// second one has nothing to revert.
    @Test
    func undoRestoresTheFilesAndAnswersWithoutReachingTheModel() async throws {
        let fixture = try await makeWorkspaceFixture()
        let edited = try writeWorkspaceFile("Sources/Value.swift", "let value = 2\n", in: fixture.workingDirectory)
        let created = try writeWorkspaceFile("Created.swift", "let created = 1\n", in: fixture.workingDirectory)
        let snapshotOnly = TurnFileChangeSummary.Entry(
            path: "Sources/Value.swift", additions: 1, deletions: 1, status: .modified, isBinary: false,
            existedBefore: true, beforeDataBase64: Self.valueEntry.beforeDataBase64, patch: nil
        )
        await seedWorkspaceSummary(
            TurnFileChangeSummary(entries: [
                snapshotOnly,
                .init(
                    path: "Created.swift", additions: 1, deletions: 0, status: .added, isBinary: false,
                    existedBefore: false, beforeDataBase64: nil, patch: nil
                ),
            ]),
            in: fixture.controller
        )

        #expect(try await answer("/undo", requestID: 1, in: fixture) == "File changes reverted.")
        #expect(try String(contentsOf: edited, encoding: .utf8) == "let value = 1\n")
        #expect(!FileManager.default.fileExists(atPath: created.path))
        #expect(await workspaceSummary(of: fixture.controller) == nil)

        #expect(try await answer("/undo", requestID: 2, in: fixture) == "No tracked file changes to undo.")
        #expect(try await answer("/changes", requestID: 3, in: fixture) == "No tracked file changes.")
        #expect(await fixture.backend.recordedPrompts().isEmpty)
    }

    /// The patch of the summary reverts the file as well, and what it shows
    /// is what `/undo` then takes back.
    @Test
    func undoRevertsTheSamePatchChangesDiffShows() async throws {
        let fixture = try await makeWorkspaceFixture()
        let edited = try writeWorkspaceFile("Sources/Value.swift", "let value = 2\n", in: fixture.workingDirectory)
        await seedWorkspaceSummary(TurnFileChangeSummary(entries: [Self.valueEntry]), in: fixture.controller)

        let shown = try await answer("/changes diff", requestID: 1, in: fixture)
        #expect(shown.contains("-let value = 1\n+let value = 2\n```"))
        #expect(try await answer("/undo", requestID: 2, in: fixture) == "File changes reverted.")
        #expect(try String(contentsOf: edited, encoding: .utf8) == "let value = 1\n")
        #expect(await fixture.backend.recordedPrompts().isEmpty)
    }

    /// `/undo` takes no argument: a line with one names no command, reverts
    /// nothing, and keeps the summary. A summary that cannot be undone says
    /// so and is kept too.
    @Test
    func undoRefusesArgumentsAndSaysWhatItCannotRevert() async throws {
        let fixture = try await makeWorkspaceFixture()
        let edited = try writeWorkspaceFile("Sources/Value.swift", "let value = 2\n", in: fixture.workingDirectory)
        let summary = TurnFileChangeSummary(entries: [Self.valueEntry])
        await seedWorkspaceSummary(summary, in: fixture.controller)

        #expect(try await answer("/undo now", requestID: 1, in: fixture) == "ZenCODE: unknown command '/undo'.")
        #expect(try await answer("/undo diff", requestID: 2, in: fixture) == "ZenCODE: unknown command '/undo'.")
        #expect(try String(contentsOf: edited, encoding: .utf8) == "let value = 2\n")
        #expect(await workspaceSummary(of: fixture.controller) == summary)

        // A modified file with neither a snapshot nor a patch has no way back.
        let unavailable = TurnFileChangeSummary(entries: [
            .init(
                path: "Sources/Value.swift", additions: 1, deletions: 1, status: .modified, isBinary: false,
                existedBefore: true, beforeDataBase64: nil, patch: nil
            ),
        ])
        await seedWorkspaceSummary(unavailable, in: fixture.controller)
        #expect(try await answer("/undo", requestID: 3, in: fixture)
            == "Undo is not available for the latest file changes.")
        #expect(try String(contentsOf: edited, encoding: .utf8) == "let value = 2\n")
        #expect(await workspaceSummary(of: fixture.controller) == unavailable)
        #expect(await fixture.backend.recordedPrompts().isEmpty)
    }

    // MARK: - The command fence

    /// A command routed under a live fence answers; the same command whose
    /// fence `session/cancel` dropped before the reversal reverts nothing and
    /// ends cancelled.
    @Test
    func undoWhoseFenceIsGoneBeforeTheReversalRevertsNothing() async throws {
        let fixture = try await makeWorkspaceFixture()
        let edited = try writeWorkspaceFile("Sources/Value.swift", "let value = 2\n", in: fixture.workingDirectory)
        let summary = TurnFileChangeSummary(entries: [Self.valueEntry])
        await seedWorkspaceSummary(summary, in: fixture.controller)

        // The reservation and the fence are the ones `session/prompt` gives.
        let live = try await reserveWorkspaceRoute(in: fixture)
        let answered = try await fixture.bridge.routeACPWorkspaceCommand(
            "/changes",
            sessionID: fixture.sessionID,
            epoch: live.reservation.epoch,
            promptID: live.reservation.promptID,
            fence: live.fence
        )
        guard case let .immediate(text) = answered else {
            Issue.record("/changes was not answered at once: \(answered)")
            return
        }
        #expect(text == Self.summaryText)

        // `session/cancel` drops the turn token the command holds.
        fixture.controller.cancelActiveTurn()
        for line in ["/undo", "/changes diff"] {
            await #expect(throws: CancellationError.self, "\(line)") {
                try await fixture.bridge.routeACPWorkspaceCommand(
                    line,
                    sessionID: fixture.sessionID,
                    epoch: live.reservation.epoch,
                    promptID: live.reservation.promptID,
                    fence: live.fence
                )
            }
        }
        #expect(try String(contentsOf: edited, encoding: .utf8) == "let value = 2\n")
        #expect(await workspaceSummary(of: fixture.controller) == summary)
    }

    /// A command that lost its fence while the files were restored ends
    /// cancelled and presents nothing; the files stay restored and the summary
    /// forgotten, as the controller left them.
    @Test
    func undoThatLosesItsFenceDuringTheReversalEndsCancelled() async throws {
        let fixture = try await makeWorkspaceFixture()
        let edited = try writeWorkspaceFile("Sources/Value.swift", "let value = 2\n", in: fixture.workingDirectory)
        await seedWorkspaceSummary(TurnFileChangeSummary(entries: [Self.valueEntry]), in: fixture.controller)
        let live = try await reserveWorkspaceRoute(in: fixture)
        let controller = fixture.controller

        await #expect(throws: CancellationError.self) {
            try await ZenCODEACPBridge.performFenced(live.fence, on: controller) {
                // `session/cancel` arrives while the files are restored.
                controller.cancelActiveTurn()
                return await controller.runUndoCommand(line: "/undo")
            }
        }
        #expect(try String(contentsOf: edited, encoding: .utf8) == "let value = 1\n")
        #expect(await workspaceSummary(of: controller) == nil)
    }

    /// While the fence holds the operation runs once and its outcome is the
    /// command's.
    @Test
    func aFenceThatHoldsLetsTheCommandAnswer() async throws {
        let fixture = try await makeWorkspaceFixture()
        let live = try await reserveWorkspaceRoute(in: fixture)
        let controller = fixture.controller

        let outcome = try await ZenCODEACPBridge.performFenced(live.fence, on: controller) {
            await controller.runUndoCommand(line: "/undo")
        }
        #expect(outcome == ChatCommandOutcome(notices: [
            .fileChangesNotUndone(description: "No tracked file changes to undo.")
        ]))
    }

    /// The reservation a prompt holds and the fence its command takes, as
    /// `session/prompt` gives them to the routing.
    private func reserveWorkspaceRoute(
        in fixture: WorkspaceFixture
    ) async throws -> (reservation: ChatPromptReservation, fence: ChatCommandFence) {
        let slotID = try #require(await fixture.bridge.workspaceSlotIDForTesting(sessionID: fixture.sessionID))
        let reservation = try await fixture.bridge.host.reservePrompt(in: slotID)
        let fence = fixture.controller.beginCommandFence(sessionID: fixture.sessionID)
        return (reservation, fence)
    }
}

// MARK: - Controller and bridge access

@ChatSessionActor
private func seedWorkspaceSummary(_ summary: TurnFileChangeSummary?, in controller: ChatSessionController) {
    controller.lastFileChangeSummary = summary
}

@ChatSessionActor
private func workspaceSummary(of controller: ChatSessionController) -> TurnFileChangeSummary? {
    controller.lastFileChangeSummary
}

extension ZenCODEACPBridge {
    fileprivate func workspaceControllerForTesting(sessionID: String) -> ChatSessionController? {
        sessions[sessionID]?.controller
    }

    fileprivate func workspaceSlotIDForTesting(sessionID: String) -> ChatSlotID? {
        sessions[sessionID]?.slotID
    }

    fileprivate func workspaceAvailableCommandsForTesting(sessionID: String) -> [JSONValue] {
        guard let session = sessions[sessionID] else { return [] }
        return availableCommandsUpdate(for: session).objectValue?["availableCommands"]?.arrayValue ?? []
    }
}
