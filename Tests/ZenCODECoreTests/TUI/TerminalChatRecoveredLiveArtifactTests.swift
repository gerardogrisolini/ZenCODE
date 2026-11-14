import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
@ChatSessionActor
struct TerminalChatRecoveredLiveArtifactTests {
    @Test(arguments: [false, true], [false, true])
    nonisolated func checkpointReplacesSameCompletionFallbackWithoutChangingHistoryOrUndo(
        delegated: Bool, isTerminal: Bool
    ) async throws {
        try await withTerminal(isTerminal: isTerminal) { directory, terminal, renderer, coordinator, recorder in
            let prefix = String(repeating: "// unchanged context\n", count: 4_096)
            let before = prefix + "let value = 1\n"
            let after = prefix + "let value = 2\n"
            #expect(before.utf8.count > OperationFileChangeRecorder.maximumTextBytes)
            let file = directory.appendingPathComponent("Value.swift")
            try Data(before.utf8).write(to: file)
            await coordinator.captureBaselineIfNeeded(forAgentToolCall: call("edit", path: "Value.swift"))
            let context = try #require(await terminal.beginFileArtifactTurn(coordinator: coordinator))
            try Data(after.utf8).write(to: file)
            // The operation and checkpoint resolve different spellings of the same path.
            let change = fallback(path: directory.path + "/unused/../Value.swift")
            await publish(change, delegated: delegated, terminal: terminal, context: context)

            // Presented once, for the `/artifacts` panel; the chat gets nothing.
            #expect(await renderer.capturedWriteEvents().isEmpty)
            #expect(recorder.liveAgentIDs == [delegated ? "worker" : nil])
            let output = recorder.markdown
            #expect(output.components(separatedBy: "modified `Value.swift`").count - 1 == 1)
            #expect(output.contains("│ -let value = 1"))
            #expect(output.contains("│ +let value = 2"))
            #expect(!output.contains("unknown `Value.swift`"))
            #expect(!output.contains("Diff unavailable"))
            #expect(!output.contains("🪬 Artifacts"))
            #expect(await context.history.snapshot().isEmpty)
            #expect(terminal.lastFileChangeSummary == nil)
            // Recording is not skipped just because its presentation was replaced.
            #expect(await context.history.recordLive(
                [change], agentID: delegated ? "worker" : nil, callID: "edit",
                turnID: context.id, workingDirectory: directory
            ) == nil)

            let summary = try #require(await terminal.collectFileChangeSummaryIfNeeded(
                from: coordinator, sessionID: context.sessionID, history: context.history, turnID: context.id
            ))
            #expect(summary.entries.count == 1)
            #expect(summary.entries.first?.beforeDataBase64 == Data(before.utf8).base64EncodedString())
            #expect(summary.entries.first?.patch?.contains("+let value = 2") == true)
            // The final reconciliation presents nothing more.
            #expect(recorder.presentations.count == 1)
            #expect(await renderer.capturedWriteEvents().isEmpty)
            #expect(terminal.chatSession.activeFileArtifactTurn == nil)
            #expect(terminal.lastFileChangeSummary == summary)
            let history = await context.history.snapshot()
            #expect(history.count == 1)
            #expect(history.first?.number == 1)
            #expect(history.first?.artifacts.count == 1)
            #expect(history.first?.artifacts.first?.explanation == nil)
            #expect(history.first?.artifacts.first?.patch?.contains("+let value = 2") == true)
            // Without the interactive layout `/artifacts` prints the history.
            _ = await terminal.submittedLineAction("/artifacts")
            let replay = TerminalANSIText.stripANSI(
                await renderer.capturedWriteEvents().map(\.text).joined()
            )
            let displayedPath = isTerminal ? "Value.swift" : "`Value.swift`"
            #expect(replay.contains("Turn 1 — 1 file"))
            #expect(replay.components(separatedBy: "modified \(displayedPath)").count - 1 == 1)
            #expect(!replay.contains("Diff unavailable"))
            _ = try await coordinator.undoLatestChanges()
            #expect(try Data(contentsOf: file) == Data(before.utf8))
        }
    }

    @Test(arguments: UnusableCheckpoint.allCases, [false, true])
    nonisolated func fallbackRemainsOnlyWithoutSamePathCheckpoint(
        checkpoint: UnusableCheckpoint, delegated: Bool
    ) async throws {
        try await withTerminal { directory, terminal, renderer, coordinator, recorder in
            let trackedPath = checkpoint == .otherPath ? "Other.swift" : "Value.swift"
            let before: Data
            let after: Data?
            switch checkpoint {
            case .oversized:
                before = Data((String(repeating: "a", count: OperationFileChangeRecorder.maximumTextBytes + 1) + "\n").utf8)
                after = Data((String(repeating: "b", count: OperationFileChangeRecorder.maximumTextBytes + 1) + "\n").utf8)
            case .emptyDeletion:
                before = Data()
                after = nil
            case .binary:
                before = Data([0, 1])
                after = Data([0, 2])
            case .absent, .otherPath:
                before = Data("let value = 1\n".utf8)
                after = Data("let value = 2\n".utf8)
            }
            let file = directory.appendingPathComponent(trackedPath)
            try before.write(to: file)
            await coordinator.captureBaselineIfNeeded(forAgentToolCall: call("edit", path: trackedPath))
            let context = try #require(await terminal.beginFileArtifactTurn(
                coordinator: checkpoint == .absent ? nil : coordinator
            ))
            if let after {
                try after.write(to: file)
            } else {
                try FileManager.default.removeItem(at: file)
            }
            await publish(fallback(), delegated: delegated, terminal: terminal, context: context)
            #expect(await renderer.capturedWriteEvents().isEmpty)
            let output = recorder.markdown
            // A same-path checkpoint is presented instead of the fallback even
            // without a renderable diff, so the file still appears once.
            let keepsFallback = checkpoint == .absent || checkpoint == .otherPath
            #expect(output.components(separatedBy: "`Value.swift`**").count - 1 == 1)
            #expect(output.components(separatedBy: "unknown `Value.swift`").count - 1 == (keepsFallback ? 1 : 0))
            switch checkpoint {
            case .absent:
                #expect(output.contains(FileChangeArtifactMapper.byteLimitExplanation))
            case .otherPath:
                #expect(output.contains(FileChangeArtifactMapper.byteLimitExplanation))
                #expect(output.components(separatedBy: "modified `Other.swift`").count - 1 == 1)
                #expect(output.contains("1 │ +let value = 2"))
            case .oversized:
                #expect(output.contains("**modified `Value.swift`**"))
                #expect(output.contains(FileChangeArtifactMapper.byteLimitExplanation))
            case .emptyDeletion:
                #expect(output.contains("**deleted `Value.swift`**"))
                #expect(!output.contains("Diff unavailable"))
            case .binary:
                #expect(output.contains("**modified `Value.swift`** (binary)"))
                #expect(output.contains(FileChangeArtifactMapper.binaryExplanation))
            }

            let summary = try #require(await terminal.collectFileChangeSummaryIfNeeded(
                from: coordinator, sessionID: context.sessionID, history: context.history, turnID: context.id
            ))
            #expect(summary.entries.first?.beforeDataBase64 == before.base64EncodedString())
            let history = await context.history.snapshot()
            let artifact = try #require(history.first?.artifacts.first)
            #expect(artifact.displayPath == trackedPath)
            #expect(terminal.lastFileChangeSummary == summary)
            if checkpoint == .oversized {
                // Counts alone do not establish usable replacement evidence.
                #expect(artifact.hasLineCounts)
                #expect(artifact.explanation != nil)
                #expect(!artifact.isBinary)
            } else if checkpoint == .emptyDeletion {
                // Even a countable, explanation-free checkpoint may have no rendered diff.
                #expect(artifact.hasLineCounts)
                #expect(artifact.explanation == nil)
                #expect(!artifact.isBinary)
                #expect(artifact.oldText == "")
                #expect(output.contains("deleted `Value.swift`"))
            } else if checkpoint == .binary {
                #expect(artifact.isBinary)
                #expect(artifact.explanation != nil)
            }
        }
    }

    @Test
    nonisolated func checkpointReplacesDifferingArtifactButNotOtherCompletionsOrTurns() async throws {
        try await withTerminal { directory, terminal, renderer, coordinator, recorder in
            let file = directory.appendingPathComponent("Value.swift")
            try Data("let value = 1\n".utf8).write(to: file)
            await coordinator.captureBaselineIfNeeded(forAgentToolCall: call("first", path: "Value.swift"))
            let context = try #require(await terminal.beginFileArtifactTurn(coordinator: coordinator))
            // No worktree change yet: this completion's genuine fallback must stay.
            await publish(fallback(), callID: "first", terminal: terminal, context: context)
            try Data("let workspace = 2\n".utf8).write(to: file)
            // A compact patch is valid evidence, but does not prove the postimage.
            let compact = OperationFileChange(
                path: "Value.swift", oldText: nil, newText: nil,
                compactDiff: .init(
                    patch: "@@ -1,1 +1,1 @@\n-let value = 1\n+let operation = 2\n",
                    additions: 1, deletions: 1
                )
            )
            await publish(compact, callID: "second", terminal: terminal, context: context)
            let presentedCount = recorder.presentations.count
            #expect(presentedCount == 2)
            let output = recorder.markdown
            #expect(output.components(separatedBy: "unknown `Value.swift`").count - 1 == 1)
            // The workspace checkpoint wins even over a valid, differing operation diff.
            #expect(output.components(separatedBy: "modified `Value.swift`").count - 1 == 1)
            #expect(!output.contains("let operation = 2"))
            #expect(output.contains("1 │ +let workspace = 2"))
            _ = await terminal.collectFileChangeSummaryIfNeeded(
                from: coordinator, sessionID: context.sessionID, history: context.history, turnID: context.id
            )
            #expect(recorder.presentations.count == presentedCount)
            let history = await context.history.snapshot()
            #expect(history.first?.artifacts.first?.patch?.contains("+let workspace = 2") == true)
            #expect(history.first?.artifacts.first?.patch?.contains("+let operation = 2") == false)

            let next = try #require(await terminal.beginFileArtifactTurn())
            await publish(fallback(), terminal: terminal, context: next)
            let nextOutput = TerminalChat.renderFileArtifacts(
                recorder.turns.dropFirst(presentedCount).map { $0 }, includeHistoryHeadings: false
            )
            #expect(await renderer.capturedWriteEvents().isEmpty)
            #expect(nextOutput.contains("unknown `Value.swift`"))
            #expect(nextOutput.contains("Diff unavailable"))
            // Presentation filtering must not remove the fallback from recording.
            #expect(await next.history.sealTurn(next.id) == [fallback(path: file.path)])
        }
    }

    @Test
    nonisolated func laterOpaqueEditStillReconcilesAgainstOriginalUndoBaseline() async throws {
        try await withTerminal { directory, terminal, renderer, coordinator, recorder in
            let file = directory.appendingPathComponent("Value.swift")
            let before = Data("let value = 1\n".utf8)
            try before.write(to: file)
            await coordinator.captureBaselineIfNeeded(forAgentToolCall: call("edit", path: "Value.swift"))
            let context = try #require(await terminal.beginFileArtifactTurn(coordinator: coordinator))
            try Data("let value = 2\n".utf8).write(to: file)
            await publish(fallback(), terminal: terminal, context: context)
            #expect(recorder.presentations.count == 1)
            try Data("let value = 3\n".utf8).write(to: file)
            let summary = try #require(await terminal.collectFileChangeSummaryIfNeeded(
                from: coordinator, sessionID: context.sessionID, history: context.history, turnID: context.id
            ))
            // The later edit is presented once, sealed; the chat gets nothing.
            #expect(recorder.presentations.count == 2)
            let finalOutput = TerminalChat.renderFileArtifacts(recorder.sealedTurns, includeHistoryHeadings: false)
            #expect(await renderer.capturedWriteEvents().isEmpty)
            #expect(finalOutput.components(separatedBy: "modified `Value.swift`").count - 1 == 1)
            #expect(finalOutput.contains("1 │ -let value = 1"))
            #expect(finalOutput.contains("1 │ +let value = 3"))
            #expect(!finalOutput.contains("let value = 2"))
            #expect(summary.entries.first?.beforeDataBase64 == before.base64EncodedString())
            let history = await context.history.snapshot()
            #expect(history.first?.artifacts.first?.patch?.contains("+let value = 3") == true)
            #expect(terminal.lastFileChangeSummary == summary)
            _ = try await coordinator.undoLatestChanges()
            #expect(try Data(contentsOf: file) == before)
        }
    }

    enum UnusableCheckpoint: CaseIterable, Sendable {
        case absent, oversized, emptyDeletion, binary, otherPath
    }

    private func publish(
        _ change: OperationFileChange, callID: String = "edit", delegated: Bool = false,
        terminal: TerminalChat, context: TerminalChat.FileArtifactTurnContext
    ) async {
        let result = DirectAgentToolResult(output: "Updated", summary: "Updated", fileChanges: [change])
        if delegated {
            await terminal.chatSession.presentSubAgentToolEvent(
                .init(agentID: "worker", agentName: "worker", toolCall: call(callID, path: change.path),
                      lifecycle: .completed(result))
            )
        } else {
            await terminal.chatSession.publishLiveFileArtifacts(result, callID: callID, context: context)
        }
    }

    private func fallback(path: String = "Value.swift") -> OperationFileChange {
        OperationFileChange(path: path, oldText: nil, newText: nil,
                            explanation: FileChangeArtifactMapper.byteLimitExplanation)
    }

    private func call(_ id: String, path: String) -> DirectAgentToolCall {
        DirectAgentToolCall(id: id, name: "local.writeFile", argumentsObject: ["path": path], argumentsJSON: "{}")
    }

    private nonisolated func withTerminal(
        isTerminal: Bool = false,
        _ body: @escaping @ChatSessionActor @Sendable (
            URL, TerminalChat, TerminalChatRenderCoordinator, TurnFileChangeCoordinator,
            TerminalArtifactPresentationRecorder
        ) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovered-live-artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await AppStorageDirectory.withSupportDirectoryURL(directory.appendingPathComponent("support")) {
            try await Task(name: "ZenCODE.Tests.recovered-live-artifacts") { @ChatSessionActor in
                let renderer = TerminalChatRenderCoordinator(
                    stdinIsTerminal: false, standardOutput: nil, standardError: nil,
                    standardOutputIsTerminal: isTerminal, standardErrorIsTerminal: isTerminal,
                    cursorTopology: isTerminal ? .shared : .separate,
                    capturesWrites: true, streamingFlushDelay: nil, columnWidthProvider: { 100 }
                )
                let terminal = TerminalChat(
                    configuration: try AgentConfiguration(
                        hostedModelID: "test-model", availableAgents: AgentProfileStore.defaultProfiles(),
                        availableModels: [AgentSettingsModelManifest(
                            id: "test-model", kind: .remoteAPI, modelID: "local/test-model"
                        )], workingDirectory: directory
                    ), stdinIsTerminal: false, telegramTransportFactory: nil, renderCoordinator: renderer
                )
                let recorder = TerminalArtifactPresentationRecorder.attached(to: terminal)
                try await body(
                    directory, terminal, renderer, TurnFileChangeCoordinator(baseDirectoryURL: directory), recorder
                )
            }.value
        }
    }
}
