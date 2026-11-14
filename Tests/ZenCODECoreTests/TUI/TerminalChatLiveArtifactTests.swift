import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

/// The terminal's live file artifacts: they are recorded, deduplicated and
/// presented as before, and an open `/artifacts` panel shows them, but the
/// terminal writes none of them in the chat. `/changes`, `/changes diff`, the
/// final `Summary`, and the `/artifacts` history printed without the
/// interactive layout keep their output.
@Suite
@ChatSessionActor
struct TerminalChatLiveArtifactTests {
    @Test
    nonisolated func rootAndDelegatedArtifactsArePresentedOnceButNotWrittenInTheChat() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await AppStorageDirectory.withSupportDirectoryURL(directory.appendingPathComponent("support")) {
            try await Task(name: "ZenCODE.Tests.live-artifacts") { @ChatSessionActor in
                let renderer = makeRenderer()
                let backend = LiveArtifactBackend()
                let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
                let terminal = try makeTerminal(directory, renderer: renderer, runner: runner)
                let recorder = TerminalArtifactPresentationRecorder.attached(to: terminal)
                await backend.setProbe {
                    let output = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                    for source in ["root source", "delegated source", "next source"] {
                        #expect(!output.contains(source))
                    }
                    #expect(!output.contains("🪬 Artifacts"))
                    // The fake model has not returned its response yet.
                    #expect(!output.contains("generation ended"))
                    // Every completion is presented once, attributed to its agent.
                    let presented = await recorder.markdown
                    for row in ["1 │ +root source", "1 │ +delegated source", "1 │ +next source"] {
                        #expect(presented.components(separatedBy: row).count - 1 == 1)
                    }
                    #expect(await recorder.liveAgentIDs == [nil, "worker", "worker"])
                    #expect(await recorder.sealedTurns.isEmpty)
                    let history = await terminal.chatSession.fileArtifactHistory
                    #expect(await history.snapshot().isEmpty)
                }
                let success = try await terminal.generateResponse(attempt: TerminalPromptAttempt(
                    prompt: "edit files", attachments: [], origin: .local,
                    locksResponseLanguage: false, purpose: .normal
                ))
                #expect(success.response.text == "generation ended")
                #expect(await backend.didProbeBeforeReturning())
                let output = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                for source in ["root source", "delegated source", "next source"] {
                    #expect(!output.contains(source))
                }
                #expect(!output.contains("│ +"))
                #expect(recorder.presentations.count == 3)
                #expect(terminal.chatSession.activeFileArtifactTurn == nil)
                await runner.shutdown()
            }.value
        }
    }

    @Test(arguments: [false, true], [false, true])
    nonisolated func opaqueArtifactsReachTheSnapshotAtEachCompletionAndTheSummaryFollowsTheAnswer(
        delegated: Bool, isTerminal: Bool
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("initial\n".utf8).write(to: workspace.appendingPathComponent("file.txt"))
        for arguments in [["init"], ["add", "."], ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "initial"]] {
            let process = Process()
            process.executableURL = GitExecutableResolver.executableURL()
            process.arguments = ["-C", workspace.path] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try await AppStorageDirectory.withSupportDirectoryURL(directory.appendingPathComponent("support")) {
            try await Task(name: "ZenCODE.Tests.artifact-ordering") { @ChatSessionActor in
                let renderer = makeRenderer(isTerminal: isTerminal)
                let backend = CompletionArtifactBackend(workspace: workspace, delegated: delegated)
                let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
                let terminal = try makeTerminal(workspace, renderer: renderer, runner: runner)
                let recorder = TerminalArtifactPresentationRecorder.attached(to: terminal)
                await backend.setProbe { stage in
                    let output = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                    #expect(output.contains("Preparing edits"))
                    #expect(!output.contains("+stage"))
                    #expect(!output.contains("Final answer"))
                    #expect(!output.contains("Summary"))
                    // The completion is presented, and the panel's snapshot
                    // lists the turn in progress with its net changes so far.
                    #expect(await recorder.markdown.components(separatedBy: "1 │ +stage \(stage)").count - 1 == 1)
                    let snapshot = await terminal.chatSession.fileArtifactSnapshot()
                    #expect(snapshot.activeTurnNumber == 1)
                    #expect(snapshot.turns.map(\.number) == [1])
                    #expect(snapshot.turns.first?.artifacts.map(\.displayPath) == ["file.txt"])
                    let listed = TerminalChat.renderFileArtifacts(snapshot.turns, includeHistoryHeadings: false)
                    #expect(listed.contains("1 │ -initial"))
                    #expect(listed.contains("1 │ +stage \(stage)"))
                }
                let success = try await terminal.generateResponse(attempt: TerminalPromptAttempt(
                    prompt: "edit files", attachments: [], origin: .local,
                    locksResponseLanguage: false, purpose: .normal
                ))
                let beforeFinish = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                #expect(!beforeFinish.contains("late fallback"))
                #expect(!beforeFinish.contains("Final answer"))
                // The edit after the last completion is presented once, sealed.
                #expect(recorder.liveAgentIDs == (delegated ? ["worker", "worker"] : [nil, nil]))
                #expect(recorder.sealedTurns.count == 1)
                #expect(TerminalChat.renderFileArtifacts(recorder.sealedTurns, includeHistoryHeadings: false)
                    .contains("1 │ +late fallback"))
                await terminal.finishPromptResult(.success(success))
                let output = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                for text in ["Preparing edits", "Final answer"] {
                    #expect(output.components(separatedBy: text).count - 1 == 1)
                }
                for text in ["+stage 1", "+stage 2", "late fallback", "│ +", "🪬 Artifacts"] {
                    #expect(!output.contains(text))
                }
                let answer = try #require(output.range(of: "Final answer"))
                let summary = try #require(output.range(of: "Summary"))
                #expect(answer.lowerBound < summary.lowerBound)
                let tail = output[answer.upperBound..<summary.lowerBound]
                #expect(!tail.contains("file.txt"))
                #expect(success.fileChangeSummary?.entries.first?.beforeDataBase64 == Data("initial\n".utf8).base64EncodedString())
                #expect(await terminal.chatSession.fileArtifactHistory.snapshot().count == 1)
                // Finished, the turn is listed once, with its final evidence.
                let snapshot = await terminal.chatSession.fileArtifactSnapshot()
                #expect(snapshot.activeTurnNumber == nil)
                #expect(snapshot.turns.map(\.number) == [1])
                #expect(TerminalChat.renderFileArtifacts(snapshot.turns, includeHistoryHeadings: false)
                    .contains("1 │ +late fallback"))
                await runner.shutdown()
            }.value
        }
    }

    /// A delegated mutation no longer writes an artifact in the chat: what
    /// follows the delegated completion is the sub-agent overview alone,
    /// published again with the completed tool row of the agent.
    @Test
    nonisolated func aDelegatedMutationRepublishesTheSubAgentOverviewWithItsToolRow() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await AppStorageDirectory.withSupportDirectoryURL(directory.appendingPathComponent("support")) {
            try await Task(name: "ZenCODE.Tests.delegated-overview") { @ChatSessionActor in
                let renderer = makeRenderer(isTerminal: true)
                let backend = DelegatedOverviewBackend()
                let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
                let terminal = try makeTerminal(directory, renderer: renderer, runner: runner)
                let recorder = TerminalArtifactPresentationRecorder.attached(to: terminal)
                let probes = DelegatedOverviewProbes()
                await backend.setProbe { stage in
                    let events = await renderer.capturedWriteEvents()
                    await probes.record(stage, eventCount: events.count)
                    let output = TerminalANSIText.stripANSI(events.map(\.text).joined())
                    switch stage {
                    case "started":
                        let overview = output.components(separatedBy: "👥 Sub-Agents:").last ?? ""
                        #expect(overview.contains("● worker"))
                        #expect(overview.contains("local.writeFile ⏳"))
                    default:
                        let started = await probes.eventCount("started")
                        let completion = TerminalANSIText.stripANSI(
                            events.dropFirst(started).map(\.text).joined()
                        )
                        // Only the overview follows: one section, its tool row completed.
                        #expect(completion.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("👥 Sub-Agents:"))
                        #expect(completion.components(separatedBy: "👥 Sub-Agents:").count - 1 == 1)
                        #expect(completion.contains("● worker"))
                        #expect(completion.contains("local.writeFile ✅"))
                        #expect(!completion.contains("Delegated.swift"))
                        #expect(!completion.contains("delegated source"))
                        #expect(!completion.contains("│ +"))
                        let tool = await renderer.subAgentToolPresentationSnapshot().presentationsByAgentID["worker"]
                        if case .completed? = tool?.lifecycle {} else {
                            Issue.record("The delegated tool row did not complete")
                        }
                        #expect(await recorder.liveAgentIDs == ["worker"])
                    }
                }
                _ = try await terminal.generateResponse(attempt: TerminalPromptAttempt(
                    prompt: "delegate", attachments: [], origin: .local,
                    locksResponseLanguage: false, purpose: .normal
                ))
                #expect(await probes.stages == ["started", "completed"])
                let output = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                #expect(!output.contains("delegated source"))
                #expect(!output.contains("│ +"))
                await runner.shutdown()
            }.value
        }
    }

    @Test(arguments: [false, true])
    func liveArtifactsStayOutOfTheChatAndTheHistoryKeepsTheHighlightedDiff(isTerminal: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer(isTerminal: isTerminal)
        let terminal = try makeTerminal(directory, renderer: renderer)
        let recorder = TerminalArtifactPresentationRecorder.attached(to: terminal)
        let context = try #require(await terminal.chatSession.beginFileArtifactTurn())
        let old = "let value = 1\n"
        let new = "let value = 2\n"
        await terminal.chatSession.publishLiveFileArtifacts(
            result([OperationFileChange(path: "Value.swift", oldText: old, newText: new)]),
            callID: "modify", context: context
        )
        #expect(await renderer.capturedWriteEvents().isEmpty)
        let live = try #require(recorder.turns.first?.artifacts.first)
        #expect(recorder.liveAgentIDs == [nil])
        let summary = TurnFileChangeSummary(entries: [
            .init(path: "Value.swift", additions: 1, deletions: 1, status: .modified,
                  isBinary: false, existedBefore: true,
                  beforeDataBase64: Data(old.utf8).base64EncodedString(),
                  patch: "@@ -1,1 +1,1 @@\n-let value = 1\n+let value = 2\n")
        ])
        _ = await context.history.sealTurn(context.id)
        _ = await context.history.finishTurn(
            context.id, summary: summary, matchingLivePaths: [], workingDirectory: directory
        )
        // Without the interactive layout `/artifacts` prints the history.
        _ = await terminal.submittedLineAction("/artifacts")
        let history = await renderer.capturedWriteEvents().map(\.text).joined()
        let visibleHistory = TerminalANSIText.stripANSI(history)
        #expect(visibleHistory.contains("🪬 Artifacts"))
        #expect(visibleHistory.contains("Turn 1 — 1 file"))
        #expect(visibleHistory.contains("1 │ -let value = 1"))
        #expect(visibleHistory.contains("1 │ +let value = 2"))
        #expect(!visibleHistory.contains("Before"))
        #expect(!visibleHistory.contains("After"))

        // The panel draws the live artifact with the same numbered diff.
        let panel = TerminalArtifactsPanelController.bodyRows(live, width: 96, standardErrorIsTerminal: isTerminal)
        let visiblePanel = panel.map(TerminalANSIText.stripANSI)
        func numberedRows(_ rows: [String]) -> [String] {
            rows.filter { $0.contains(" │ ") }.map { row in
                var row = row
                while row.last == " " { row.removeLast() }
                return row.trimmingCharacters(in: .whitespaces)
            }
        }
        #expect(numberedRows(visiblePanel) == numberedRows(visibleHistory.components(separatedBy: "\n")))
        #expect(numberedRows(visiblePanel) == ["│ @@ -1,1 +1,1 @@", "1 │ -let value = 1", "1 │ +let value = 2"])
        for output in [history, panel.joined(separator: "\n")] {
            if isTerminal {
                let palette = TerminalMarkdownPalette.detected
                #expect(output.contains(palette.diffAdditionBackground))
                #expect(output.contains(palette.diffRemovalBackground))
                #expect(output.contains("\(palette.syntaxKeyword)let"))
                #expect(TerminalANSIText.stripANSI(output).components(separatedBy: "Code · Diff · Swift").count - 1 == 1)
            } else {
                #expect(!output.contains("\u{1B}"))
            }
        }
    }

    @Test
    func changesDiffUsesOnlyLatestSummaryWithoutMutatingHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        let summaries = ["Earlier.swift", "Latest.swift"].map { path in
            TurnFileChangeSummary(entries: [
                .init(path: path, additions: 1, deletions: 0, status: .added,
                      isBinary: false, existedBefore: false, beforeDataBase64: nil,
                      patch: "@@ -0,0 +1,1 @@\n+let value = 1\n"),
            ])
        }
        for summary in summaries {
            await terminal.chatSession.fileArtifactHistory.append(
                summary: summary, sessionID: terminal.sessionID, workingDirectory: directory
            )
        }
        terminal.chatSession.lastFileChangeSummary = summaries[1]
        let before = await terminal.chatSession.fileArtifactHistory.snapshot()
        for command in ["/changes diff", "/changes --diff", "/changes diff"] {
            let count = await renderer.capturedWriteEvents().count
            _ = await terminal.submittedLineAction(command)
            let output = await renderer.capturedWriteEvents().dropFirst(count).map(\.text).joined()
            #expect(output.contains("Latest.swift"))
            #expect(!output.contains("Earlier.swift"))
            #expect(await terminal.chatSession.fileArtifactHistory.snapshot() == before)
            #expect(terminal.chatSession.lastFileChangeSummary == summaries[1])
        }
        let count = await renderer.capturedWriteEvents().count
        _ = await terminal.submittedLineAction("/artifacts")
        let history = await renderer.capturedWriteEvents().dropFirst(count).map(\.text).joined()
        #expect(history.contains("Earlier.swift"))
        #expect(history.contains("Latest.swift"))
        #expect(history.contains("### Turn 1 — 1 file"))
        #expect(history.contains("### Turn 2 — 1 file"))
        #expect(await terminal.chatSession.fileArtifactHistory.snapshot() == before)
        #expect(await renderer.capturedWriteEvents().allSatisfy { $0.channel == .standardError })
        // Rendering /changes must not even reserve a hidden history number.
        let next = await terminal.chatSession.fileArtifactHistory.append(
            summary: summaries[1], sessionID: terminal.sessionID, workingDirectory: directory
        )
        #expect(next?.number == 3)
    }

    @Test
    func changesDiffUsesCapturedFallbacksAndDeletedSnapshotWithoutReadingWorktree() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        for path in ["Missing.swift", "Deleted.swift"] {
            try Data("unrelated worktree content\n".utf8).write(to: directory.appendingPathComponent(path))
        }
        terminal.chatSession.lastFileChangeSummary = TurnFileChangeSummary(entries: [
            .init(path: "Binary.bin", additions: 0, deletions: 0, status: .modified,
                  isBinary: true, existedBefore: true, beforeDataBase64: nil, patch: nil),
            .init(path: "Missing.swift", additions: 1, deletions: 1, status: .modified,
                  isBinary: false, existedBefore: true,
                  beforeDataBase64: Data("partial evidence\n".utf8).base64EncodedString(), patch: nil),
            .init(path: "Deleted.swift", additions: 0, deletions: 1, status: .deleted,
                  isBinary: false, existedBefore: true,
                  beforeDataBase64: Data("let removed = 1\n".utf8).base64EncodedString(), patch: nil),
            .init(path: "OverBudget.swift", additions: 1, deletions: 0, status: .added,
                  isBinary: false, existedBefore: false, beforeDataBase64: nil,
                  patch: String(repeating: "+", count: OperationFileChangeRecorder.maximumTextBytes + 1)),
        ])
        _ = await terminal.submittedLineAction("/changes diff")
        let events = await renderer.capturedWriteEvents()
        let output = events.map(\.text).joined()
        #expect(output.contains("**modified `Binary.bin`** (binary)"))
        #expect(output.contains("Explanation: \(FileChangeArtifactMapper.binaryExplanation)"))
        #expect(output.contains("**modified `Missing.swift`**  +1 -1"))
        #expect(output.contains("Explanation: \(FileChangeArtifactMapper.unavailableEvidenceExplanation)"))
        #expect(output.contains("**deleted `Deleted.swift`**  +0 -1"))
        #expect(output.contains("1 │ -let removed = 1"))
        #expect(output.contains("**added `OverBudget.swift`**  +1 -0"))
        #expect(output.contains("Explanation: \(FileChangeArtifactMapper.byteLimitExplanation)"))
        #expect(!output.contains("No text patches available."))
        #expect(!output.contains("partial evidence"))
        #expect(!output.contains("unrelated worktree content"))
        #expect(events.allSatisfy { $0.channel == .standardError })
        #expect(await terminal.chatSession.fileArtifactHistory.snapshot().isEmpty)
    }

    @Test(arguments: [false, true])
    func fileChangeDiffAdapterKeepsAllNumberedLines(isTerminal: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer(isTerminal: isTerminal)
        let terminal = try makeTerminal(directory, renderer: renderer)
        let patch = "@@ -0,0 +1,520 @@\n" + (1...520).map { "+line \($0)\n" }.joined()
        let summary = TurnFileChangeSummary(entries: [
            .init(path: "Long.txt", additions: 520, deletions: 0, status: .added,
                  isBinary: false, existedBefore: false, beforeDataBase64: nil, patch: patch),
        ])
        await terminal.writeFileChangeDiffs(summary)
        let events = await renderer.capturedWriteEvents()
        let output = TerminalANSIText.stripANSI(events.map(\.text).joined())
        #expect(output.components(separatedBy: "│ +line ").count - 1 == 520)
        #expect(output.contains("1 │ +line 1"))
        #expect(output.contains("520 │ +line 520"))
        #expect(!output.contains("Summary:"))
        #expect(events.allSatisfy { $0.channel == .standardError })
        #expect(await terminal.chatSession.fileArtifactHistory.snapshot().isEmpty)
    }

    @Test(arguments: ["assistant", "thought"])
    func aDelegatedArtifactLeavesAnOpenStreamUntouchedInTTY(_ stream: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer(isTerminal: true)
        let reference = makeRenderer(isTerminal: true)
        let terminal = try makeTerminal(directory, renderer: renderer)
        let recorder = TerminalArtifactPresentationRecorder.attached(to: terminal)
        let context = try #require(await terminal.chatSession.beginFileArtifactTurn())
        // Keep both an open fence and an incomplete source line across the
        // delegated completion: the stream must go on as if nothing happened.
        let opening = "```swift\nlet first = 1\nlet second = \""
        let remaining = "**literal**\"\n```\n**Prose after fence**\n"
        for target in [renderer, reference] {
            if stream == "thought" {
                await target.writeThought(opening)
            } else {
                await target.writeAssistantContent(opening)
            }
            await target.flushOutput()
        }
        let beforeArtifact = await renderer.capturedWriteEvents().count
        await terminal.chatSession.presentSubAgentToolEvent(
            .init(
                agentID: "worker", agentName: "worker",
                toolCall: call("split-fence", path: "Artifact.swift"),
                lifecycle: .completed(result([
                    OperationFileChange(path: "Artifact.swift", oldText: nil, newText: "let artifact = 42\n")
                ]))
            )
        )
        // The artifact is presented for the panel; the chat gets nothing.
        #expect(await renderer.capturedWriteEvents().count == beforeArtifact)
        #expect(recorder.liveAgentIDs == ["worker"])
        #expect(recorder.markdown.contains("1 │ +let artifact = 42"))
        #expect(await context.history.snapshot().isEmpty)
        #expect(await renderer.snapshot().isStreamingThoughtOutput == (stream == "thought"))

        for target in [renderer, reference] {
            if stream == "thought" {
                await target.writeThought(remaining)
            } else {
                await target.writeAssistantContent(remaining)
            }
            await target.finishStreamingOutput()
        }
        // The ANSI output too is the uninterrupted stream's: source
        // highlighting and post-fence prose, with no new thinking/bubble label.
        let output = await renderer.capturedWriteEvents().map(\.text).joined()
        #expect(output == (await reference.capturedWriteEvents().map(\.text).joined()))
        let visible = TerminalANSIText.stripANSI(output)
        #expect(visible.contains("let second = \"**literal**\""))
        #expect(visible.contains("Prose after fence"))
        #expect(!visible.contains("**Prose after fence**"))
        #expect(!visible.contains("Artifact.swift"))
        #expect(!visible.contains("let artifact = 42"))
        #expect(!visible.contains("🪬 Artifacts"))
    }

    @Test
    func finalFallbackOmitsUnchangedLiveFilesButPresentsLaterOpaqueEdits() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        let recorder = TerminalArtifactPresentationRecorder.attached(to: terminal)
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: directory)
        let context = try #require(await terminal.chatSession.beginFileArtifactTurn())
        for path in ["same.txt", "later.txt", "final.txt"] {
            try Data("before\n".utf8).write(to: directory.appendingPathComponent(path))
            await coordinator.captureBaselineIfNeeded(forAgentToolCall: call(path, path: path))
        }
        let changes = [
            OperationFileChange(path: "same.txt", oldText: "before\n", newText: "live\n"),
            OperationFileChange(path: "later.txt", oldText: "before\n", newText: "live\n")
        ]
        await terminal.chatSession.publishLiveFileArtifacts(result(changes), callID: "live", context: context)
        try Data("live\n".utf8).write(to: directory.appendingPathComponent("same.txt"))
        try Data("opaque after live\n".utf8).write(to: directory.appendingPathComponent("later.txt"))
        try Data("final only\n".utf8).write(to: directory.appendingPathComponent("final.txt"))
        #expect(recorder.presentations.count == 1)
        let summary = await terminal.chatSession.collectFileChangeSummaryIfNeeded(
            from: coordinator, sessionID: context.sessionID, history: context.history, turnID: context.id
        )
        #expect(summary?.fileCount == 3)
        #expect(recorder.presentations.count == 2)
        let fallback = TerminalChat.renderFileArtifacts(recorder.sealedTurns, includeHistoryHeadings: false)
        #expect(!fallback.contains("🪬 Artifacts"))
        #expect(!fallback.contains("Turn 1 —"))
        #expect(!fallback.contains("same.txt"))
        #expect(fallback.contains("later.txt"))
        #expect(fallback.contains("opaque after live"))
        #expect(fallback.contains("final.txt"))
        #expect(fallback.contains("1 │ +final only"))
        // Nothing of it is written in the chat.
        #expect(await renderer.capturedWriteEvents().isEmpty)
        let turns = await terminal.chatSession.fileArtifactHistory.snapshot()
        #expect(turns.count == 1)
        #expect(turns.first?.number == 1)
        #expect(turns.first?.artifacts.count == 3)
        #expect(terminal.chatSession.lastFileChangeSummary == summary)
        #expect(await terminal.chatSession.collectFileChangeSummaryIfNeeded(
            from: coordinator, sessionID: context.sessionID, history: context.history, turnID: context.id
        ) == nil)
        #expect(recorder.presentations.count == 2)
        #expect(await renderer.capturedWriteEvents().isEmpty)
    }

    @Test
    func finalReconciliationDrainsPendingPublicationBeforeSealingHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: directory)
        let context = try #require(await terminal.chatSession.beginFileArtifactTurn(coordinator: coordinator))
        await coordinator.captureBaselineIfNeeded(forAgentToolCall: call("pending", path: "pending.txt"))
        try Data("pending source\n".utf8).write(to: directory.appendingPathComponent("pending.txt"))
        let gate = ArtifactPublicationGate()
        context.pendingPublication = Task(name: "ZenCODE.Tests.pending-artifact") {
            await gate.wait()
            let turn = await context.history.recordLive(
                [.init(path: "pending.txt", oldText: nil, newText: "pending source\n")],
                agentID: nil, callID: "pending", turnID: context.id, workingDirectory: directory
            )
            #expect(turn != nil)
            if let turn {
                await renderer.writeMarkdownMessage(
                    TerminalChat.renderFileArtifacts([turn], includeHistoryHeadings: false), to: .standardError
                )
            }
        }
        let finalization = Task.immediate(name: "ZenCODE.Tests.artifact-finalization") {
            await terminal.chatSession.collectFileChangeSummaryIfNeeded(
                from: coordinator, sessionID: context.sessionID, history: context.history, turnID: context.id
            )
        }
        #expect(!context.acceptsPublications)
        #expect(await renderer.capturedWriteEvents().isEmpty)
        await gate.release()
        #expect(await finalization.value?.fileCount == 1)
        let output = await renderer.capturedWriteEvents().map(\.text).joined()
        #expect(output.components(separatedBy: "1 │ +pending source").count - 1 == 1)
        #expect(terminal.chatSession.activeFileArtifactTurn == nil)
    }

    /// The root and final evidence of a turn that a reset replaced are
    /// refused even under the same session id. A delegated event carries no
    /// turn: the controller presents it in the turn it records now, and a
    /// stale delegation is the router's to drop (see
    /// `ChatSessionHostSubAgentToolEventTests`).
    @Test
    func resetRejectsStaleRootAndFinalEvidenceEvenWithSameSessionID() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        let recorder = TerminalArtifactPresentationRecorder.attached(to: terminal)
        let old = try #require(await terminal.chatSession.beginFileArtifactTurn())
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: directory)
        await coordinator.captureBaselineIfNeeded(forAgentToolCall: call("call", path: "stale.txt"))
        try Data("stale\n".utf8).write(to: directory.appendingPathComponent("stale.txt"))
        let evidence = result([OperationFileChange(path: "stale.txt", oldText: nil, newText: "stale\n")])
        terminal.resetFileArtifactState()
        let current = try #require(await terminal.chatSession.beginFileArtifactTurn())
        #expect(current.sessionID == old.sessionID)
        await terminal.chatSession.publishLiveFileArtifacts(evidence, callID: "call", context: old)
        #expect(await terminal.chatSession.collectFileChangeSummaryIfNeeded(
            from: coordinator, sessionID: old.sessionID, history: old.history, turnID: old.id
        ) == nil)
        #expect(recorder.presentations.isEmpty)
        #expect(terminal.chatSession.lastFileChangeSummary == nil)
        #expect(await terminal.chatSession.fileArtifactHistory.snapshot().isEmpty)
        await terminal.chatSession.publishLiveFileArtifacts(evidence, callID: "call", context: current)
        #expect(recorder.liveAgentIDs == [nil])
        let presented = recorder.markdown
        #expect(presented.contains("**added `stale.txt`**  +1 -0"))
        #expect(presented.contains("1 │ +stale"))
        #expect(await renderer.capturedWriteEvents().isEmpty)
    }

    private func makeRenderer(isTerminal: Bool = false) -> TerminalChatRenderCoordinator {
        TerminalChatRenderCoordinator(
            stdinIsTerminal: false, standardOutput: nil, standardError: nil,
            standardOutputIsTerminal: isTerminal, standardErrorIsTerminal: isTerminal,
            cursorTopology: isTerminal ? .shared : .separate,
            capturesWrites: true, streamingFlushDelay: nil, columnWidthProvider: { 100 }
        )
    }

    private func makeTerminal(
        _ directory: URL, renderer: TerminalChatRenderCoordinator,
        runner: AgentCoreSessionRunner? = nil
    ) throws -> TerminalChat {
        TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "test-model", availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")],
                workingDirectory: directory
            ), stdinIsTerminal: false, sessionRunner: runner,
            telegramTransportFactory: nil, renderCoordinator: renderer
        )
    }

    private func result(_ changes: [OperationFileChange]) -> DirectAgentToolResult {
        DirectAgentToolResult(output: "Updated", summary: "Updated", fileChanges: changes)
    }

    private func call(_ id: String, path: String) -> DirectAgentToolCall {
        DirectAgentToolCall(id: id, name: "local.writeFile", argumentsObject: ["path": path], argumentsJSON: "{}")
    }

    private nonisolated func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor LiveArtifactBackend: AgentRuntimeBackend {
    private var handler: DirectSubAgentToolEventHandler?
    private var probe: (@Sendable () async -> Void)?
    private var didProbe = false

    func setProbe(_ probe: @escaping @Sendable () async -> Void) { self.probe = probe }
    func didProbeBeforeReturning() -> Bool { didProbe }
    func updateSubAgentToolEventHandler(_ handler: DirectSubAgentToolEventHandler?) { self.handler = handler }
    func createSession(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func createSessionIfNeeded(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func updateSessionOptions(id: String, systemPrompt: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func closeSession(id: String) {}
    func shutdown() {}
    func preloadModel(onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String { "test-model" }
    func activeToolDescriptors() -> [DirectToolDescriptor] { [] }

    func sendPrompt(sessionID: String, prompt: String, attachments: [AgentRuntimeAttachment], onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> DirectAgentResponse {
        let call = DirectAgentToolCall(id: "shared-call", name: "local.writeFile", argumentsObject: ["path": "Live.swift"], argumentsJSON: "{}")
        let root = DirectAgentToolResult(output: "Updated", summary: "Updated", fileChanges: [
            .init(path: "Live.swift", oldText: nil, newText: "root source\n")
        ])
        await onEvent(.thought("thinking before root"))
        await onEvent(.toolCallStarted(call))
        await onEvent(.toolCallCompleted(call, root))
        await onEvent(.toolCallCompleted(call, root))
        await onEvent(.content("assistant still active"))
        let delegated = DirectAgentToolResult(output: "Updated", summary: "Updated", fileChanges: [
            .init(path: "Live.swift", oldText: "root source\n", newText: "delegated source\n")
        ])
        let event = DirectSubAgentToolEvent(
            agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .completed(delegated),
            rootSessionID: sessionID
        )
        await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .started, rootSessionID: sessionID))
        await handler?(event)
        await handler?(event)
        let next = DirectAgentToolCall(id: "next-call", name: "local.writeFile", argumentsObject: ["path": "Live.swift"], argumentsJSON: "{}")
        await handler?(.init(agentID: "worker", agentName: "worker", toolCall: next, lifecycle: .completed(
            DirectAgentToolResult(output: "Updated", summary: "Updated", fileChanges: [
                .init(path: "Live.swift", oldText: "delegated source\n", newText: "next source\n")
            ])
        ), rootSessionID: sessionID))
        await probe?()
        didProbe = true
        await onEvent(.content("generation ended"))
        return DirectAgentResponse(text: "generation ended", stopReason: "end_turn", modelID: "test-model")
    }
}

private actor CompletionArtifactBackend: AgentRuntimeBackend {
    let workspace: URL
    let delegated: Bool
    private var handler: DirectSubAgentToolEventHandler?
    private var probe: (@Sendable (Int) async -> Void)?

    init(workspace: URL, delegated: Bool) {
        self.workspace = workspace
        self.delegated = delegated
    }

    func setProbe(_ probe: @escaping @Sendable (Int) async -> Void) { self.probe = probe }
    func updateSubAgentToolEventHandler(_ handler: DirectSubAgentToolEventHandler?) { self.handler = handler }
    func createSession(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func createSessionIfNeeded(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func updateSessionOptions(id: String, systemPrompt: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func closeSession(id: String) {}
    func shutdown() {}
    func preloadModel(onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String { "test-model" }
    func activeToolDescriptors() -> [DirectToolDescriptor] { [] }

    func sendPrompt(sessionID: String, prompt: String, attachments: [AgentRuntimeAttachment], onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> DirectAgentResponse {
        await onEvent(.content("Preparing "))
        await onEvent(.content("edits\n"))
        let parent = DirectAgentToolCall(id: "parent", name: "agent.wait", argumentsObject: [:], argumentsJSON: "{}")
        if delegated { await onEvent(.toolCallStarted(parent)) }
        for stage in 1...2 {
            let call = DirectAgentToolCall(id: "shell-\(stage)", name: "local.exec", argumentsObject: ["command": "edit"], argumentsJSON: "{}")
            if delegated {
                await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .started, rootSessionID: sessionID))
            } else {
                await onEvent(.toolCallStarted(call))
            }
            try Data("stage \(stage)\n".utf8).write(to: workspace.appendingPathComponent("file.txt"))
            // A failed command may also have written files before exiting.
            let result = DirectAgentToolResult(output: "done", summary: "done", status: stage == 1 ? .completed : .failed)
            if delegated {
                await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .completed(result), rootSessionID: sessionID))
            } else {
                await onEvent(.toolCallCompleted(call, result))
            }
            await probe?(stage)
        }
        if delegated { await onEvent(.toolCallCompleted(parent, .init(output: "done", summary: "done"))) }
        await onEvent(.content("**Final "))
        await onEvent(.content("answer**\n"))
        // Exercise the safety-net reconciliation after the final model delta.
        try Data("late fallback\n".utf8).write(to: workspace.appendingPathComponent("file.txt"))
        return DirectAgentResponse(text: "Preparing edits\n**Final answer**\n", stopReason: "end_turn", modelID: "test-model")
    }
}

private actor ArtifactPublicationGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

/// The renderer's write count at each probe of ``DelegatedOverviewBackend``.
private actor DelegatedOverviewProbes {
    private(set) var stages: [String] = []
    private var eventCounts: [String: Int] = [:]

    func record(_ stage: String, eventCount: Int) {
        stages.append(stage)
        eventCounts[stage] = eventCount
    }

    func eventCount(_ stage: String) -> Int {
        eventCounts[stage] ?? 0
    }
}

/// A coordinator waiting for one sub-agent in progress, which writes a file:
/// the delegated call is probed once started and once completed.
private actor DelegatedOverviewBackend: AgentRuntimeBackend {
    private var handler: DirectSubAgentToolEventHandler?
    private var probe: (@Sendable (String) async -> Void)?

    func setProbe(_ probe: @escaping @Sendable (String) async -> Void) { self.probe = probe }
    func updateSubAgentToolEventHandler(_ handler: DirectSubAgentToolEventHandler?) { self.handler = handler }
    func createSession(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func createSessionIfNeeded(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func updateSessionOptions(id: String, systemPrompt: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func closeSession(id: String) {}
    func shutdown() {}
    func preloadModel(onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String { "test-model" }
    func activeToolDescriptors() -> [DirectToolDescriptor] { [] }

    func subAgentSnapshots() -> [DirectSubAgentRuntime.AgentSnapshot] {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return [DirectSubAgentRuntime.AgentSnapshot(
            id: "worker",
            name: "worker",
            role: "Writes the file",
            profileName: nil,
            status: .running,
            pending: true,
            configuredModelID: nil,
            modelID: nil,
            currentActivity: nil,
            currentActivityKind: nil,
            currentToolName: "local.writeFile",
            currentToolIsRunning: true,
            latestMetrics: nil,
            latestEventAt: date,
            latestOutput: nil,
            executionRevision: 1,
            latestError: nil,
            createdAt: date,
            updatedAt: date
        )]
    }

    func sendPrompt(sessionID: String, prompt: String, attachments: [AgentRuntimeAttachment], onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> DirectAgentResponse {
        let wait = DirectAgentToolCall(id: "wait", name: "agent.wait", argumentsObject: [:], argumentsJSON: "{}")
        await onEvent(.toolCallStarted(wait))
        let call = DirectAgentToolCall(id: "delegated-write", name: "local.writeFile", argumentsObject: ["path": "Delegated.swift"], argumentsJSON: "{}")
        await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .started, rootSessionID: sessionID))
        await probe?("started")
        let result = DirectAgentToolResult(output: "Updated", summary: "Updated", fileChanges: [
            .init(path: "Delegated.swift", oldText: nil, newText: "delegated source\n")
        ])
        await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .completed(result), rootSessionID: sessionID))
        await probe?("completed")
        await onEvent(.toolCallCompleted(wait, .init(output: "done", summary: "done")))
        await onEvent(.content("delegation ended"))
        return DirectAgentResponse(text: "delegation ended", stopReason: "end_turn", modelID: "test-model")
    }
}
