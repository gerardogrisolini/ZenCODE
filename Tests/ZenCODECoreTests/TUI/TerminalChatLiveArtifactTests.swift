import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
@TerminalChatActor
struct TerminalChatLiveArtifactTests {
    @Test
    nonisolated func rootAndDelegatedArtifactsAppearBeforeGenerationReturns() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await AppStorageDirectory.withSupportDirectoryURL(directory.appendingPathComponent("support")) {
            try await Task(name: "ZenCODE.Tests.live-artifacts") { @TerminalChatActor in
                let renderer = makeRenderer()
                let backend = LiveArtifactBackend()
                let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
                let terminal = try makeTerminal(directory, renderer: renderer, runner: runner)
                await backend.setProbe {
                    let output = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                    for row in ["1 │ +root source", "1 │ +delegated source", "1 │ +next source"] {
                        #expect(output.components(separatedBy: row).count - 1 == 1)
                    }
                    #expect(!output.contains("🪬 Artifacts"))
                    #expect(!output.contains("Turn 1 —"))
                    // The fake model has not returned its response yet.
                    #expect(!output.contains("generation ended"))
                    let history = await terminal.fileArtifactHistory
                    #expect(await history.snapshot().isEmpty)
                }
                let success = try await terminal.generateResponse(attempt: TerminalPromptAttempt(
                    prompt: "edit files", attachments: [], origin: .local,
                    locksResponseLanguage: false, purpose: .normal
                ))
                #expect(success.response.text == "generation ended")
                #expect(await backend.didProbeBeforeReturning())
                let output = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                for row in ["1 │ +root source", "1 │ +delegated source", "1 │ +next source"] {
                    #expect(output.components(separatedBy: row).count - 1 == 1)
                }
                #expect(!output.contains("🪬 Artifacts"))
                #expect(!output.contains("Turn 1 —"))
                #expect(terminal.activeFileArtifactTurn == nil)
                await runner.shutdown()
            }.value
        }
    }

    @Test
    func liveAndArtifactsCommandUseTheSameMarkdownRenderer() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        let context = try #require(await terminal.beginFileArtifactTurn())
        let change = OperationFileChange(path: "Deleted.swift", oldText: "let removed = 1\n", newText: nil)
        await terminal.publishLiveFileArtifacts(result([change]), callID: "delete", context: context)
        let liveEvents = await renderer.capturedWriteEvents()
        #expect(liveEvents.allSatisfy { $0.channel == .standardError })
        let live = liveEvents.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(live.hasPrefix("**deleted `Deleted.swift`**  +0 -1"))
        #expect(live.contains("1 │ -let removed = 1"))
        #expect(!live.contains("🪬 Artifacts"))
        #expect(!live.contains("Turn 1 —"))
        let summary = TurnFileChangeSummary(entries: [
            .init(path: "Deleted.swift", additions: 0, deletions: 1, status: .deleted,
                  isBinary: false, existedBefore: true,
                  beforeDataBase64: Data("let removed = 1\n".utf8).base64EncodedString(), patch: nil)
        ])
        _ = await context.history.sealTurn(context.id)
        _ = await context.history.finishTurn(context.id, summary: summary, matchingLivePaths: [], workingDirectory: directory)
        await terminal.handleArtifactsCommand()
        let commandEvents = await renderer.capturedWriteEvents().dropFirst(liveEvents.count)
        #expect(commandEvents.allSatisfy { $0.channel == .standardError })
        let command = commandEvents.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(command.hasPrefix("🪬 Artifacts"))
        #expect(command.contains("### Turn 1 — 1 file"))
        #expect(command.hasSuffix(live))
    }

    @Test(arguments: [false, true], [false, true])
    nonisolated func opaqueArtifactsAppearAtEachCompletionAndFinalAnswerPrecedesSummary(
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
            try await Task(name: "ZenCODE.Tests.artifact-ordering") { @TerminalChatActor in
                let renderer = makeRenderer(isTerminal: isTerminal)
                let backend = CompletionArtifactBackend(workspace: workspace, delegated: delegated)
                let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
                let terminal = try makeTerminal(workspace, renderer: renderer, runner: runner)
                await backend.setProbe { stage in
                    let output = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                    #expect(output.contains("Preparing edits"))
                    #expect(output.components(separatedBy: "1 │ +stage \(stage)").count - 1 == 1)
                    #expect(!output.contains("Final answer"))
                    #expect(!output.contains("Summary"))
                }
                let success = try await terminal.generateResponse(attempt: TerminalPromptAttempt(
                    prompt: "edit files", attachments: [], origin: .local,
                    locksResponseLanguage: false, purpose: .normal
                ))
                let beforeFinish = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                #expect(beforeFinish.contains("1 │ +late fallback"))
                #expect(!beforeFinish.contains("Final answer"))
                await terminal.finishPromptResult(.success(success))
                let output = TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
                for text in ["Preparing edits", "1 │ +stage 1", "1 │ +stage 2", "1 │ +late fallback", "Final answer"] {
                    #expect(output.components(separatedBy: text).count - 1 == 1)
                }
                let artifact = try #require(output.range(of: "1 │ +late fallback"))
                let answer = try #require(output.range(of: "Final answer"))
                let summary = try #require(output.range(of: "Summary"))
                #expect(artifact.lowerBound < answer.lowerBound)
                #expect(answer.lowerBound < summary.lowerBound)
                let tail = output[answer.upperBound..<summary.lowerBound]
                #expect(!tail.contains("file.txt"))
                #expect(!tail.contains("│"))
                #expect(success.fileChangeSummary?.entries.first?.beforeDataBase64 == Data("initial\n".utf8).base64EncodedString())
                #expect(await terminal.fileArtifactHistory.snapshot().count == 1)
                await runner.shutdown()
            }.value
        }
    }

    @Test(arguments: [false, true])
    func modifiedLiveAndPatchHistoryShareOneHighlightedDiff(isTerminal: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer(isTerminal: isTerminal)
        let terminal = try makeTerminal(directory, renderer: renderer)
        let context = try #require(await terminal.beginFileArtifactTurn())
        let old = "let value = 1\n"
        let new = "let value = 2\n"
        await terminal.publishLiveFileArtifacts(
            result([OperationFileChange(path: "Value.swift", oldText: old, newText: new)]),
            callID: "modify", context: context
        )
        let liveEvents = await renderer.capturedWriteEvents()
        let live = liveEvents.map(\.text).joined()
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
        await terminal.handleArtifactsCommand()
        let history = await renderer.capturedWriteEvents().dropFirst(liveEvents.count).map(\.text).joined()
        let liveBodyStart = try #require(live.range(of: "modified")).lowerBound
        let historyBodyStart = try #require(history.range(of: "modified")).lowerBound
        #expect(live[liveBodyStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            == history[historyBodyStart...].trimmingCharacters(in: .whitespacesAndNewlines))
        let visibleLive = TerminalANSIText.stripANSI(live)
        let visibleHistory = TerminalANSIText.stripANSI(history)
        #expect(!visibleLive.contains("🪬 Artifacts"))
        #expect(!visibleLive.contains("Turn 1 —"))
        #expect(visibleHistory.contains("🪬 Artifacts"))
        #expect(visibleHistory.contains("Turn 1 — 1 file"))
        for output in [live, history] {
            let visible = TerminalANSIText.stripANSI(output)
            #expect(visible.contains("1 │ -let value = 1"))
            #expect(visible.contains("1 │ +let value = 2"))
            #expect(!visible.contains("Before"))
            #expect(!visible.contains("After"))
            if isTerminal {
                let palette = TerminalMarkdownPalette.detected
                #expect(output.contains(palette.diffAdditionBackground))
                #expect(output.contains(palette.diffRemovalBackground))
                #expect(output.contains("\(palette.syntaxKeyword)let"))
                #expect(visible.components(separatedBy: "Code · Diff · Swift").count - 1 == 1)
            } else {
                #expect(!output.contains("\u{1B}"))
            }
        }
    }

    @Test(arguments: [false, true])
    func changesDiffAliasesPreserveSummaryAndUseArtifactsRenderer(isTerminal: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer(isTerminal: isTerminal)
        let terminal = try makeTerminal(directory, renderer: renderer)
        let summary = TurnFileChangeSummary(entries: [
            .init(path: "Value.swift", additions: 1, deletions: 1, status: .modified,
                  isBinary: false, existedBefore: true,
                  beforeDataBase64: Data("let value = 1\n".utf8).base64EncodedString(),
                  patch: "@@ -1,1 +1,1 @@\n-let value = 1\n+let value = 2\n"),
        ])
        terminal.lastFileChangeSummary = summary
        await terminal.fileArtifactHistory.append(
            summary: summary, sessionID: terminal.sessionID, workingDirectory: directory
        )

        await terminal.handleChangesCommand("/changes")
        let summaryEvents = await renderer.capturedWriteEvents()
        let summaryOutput = summaryEvents.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(TerminalANSIText.stripANSI(summaryOutput)
            == TerminalChat.renderFileChangeSummary(summary).trimmingCharacters(in: .whitespacesAndNewlines))
        await terminal.handleArtifactsCommand()
        let history = await renderer.capturedWriteEvents().dropFirst(summaryEvents.count).map(\.text).joined()
        let historyBodyStart = try #require(history.range(of: "modified")).lowerBound
        let historyBody = history[historyBodyStart...].trimmingCharacters(in: .whitespacesAndNewlines)

        var aliasOutputs: [String] = []
        for command in ["/changes diff", "/changes --diff"] {
            let count = await renderer.capturedWriteEvents().count
            await terminal.handleChangesCommand(command)
            let output = await renderer.capturedWriteEvents().dropFirst(count).map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output.hasPrefix(summaryOutput))
            let body = String(output.dropFirst(summaryOutput.count))
            let bodyStart = try #require(body.range(of: "modified")).lowerBound
            #expect(body[bodyStart...].trimmingCharacters(in: .whitespacesAndNewlines) == historyBody)
            let visible = TerminalANSIText.stripANSI(output)
            #expect(visible.contains("1 │ -let value = 1"))
            #expect(visible.contains("1 │ +let value = 2"))
            #expect(!visible.contains("🪬 Artifacts"))
            #expect(!visible.contains("Turn 1 —"))
            if isTerminal {
                let palette = TerminalMarkdownPalette.detected
                #expect(output.contains(palette.diffAdditionBackground))
                #expect(output.contains(palette.diffRemovalBackground))
                #expect(output.contains("\(palette.syntaxKeyword)let"))
            } else {
                #expect(!output.contains("\u{1B}"))
            }
            aliasOutputs.append(output)
        }
        #expect(aliasOutputs[0] == aliasOutputs[1])
        #expect(await renderer.capturedWriteEvents().allSatisfy { $0.channel == .standardError })
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
            await terminal.fileArtifactHistory.append(
                summary: summary, sessionID: terminal.sessionID, workingDirectory: directory
            )
        }
        terminal.lastFileChangeSummary = summaries[1]
        let before = await terminal.fileArtifactHistory.snapshot()
        for command in ["/changes diff", "/changes --diff", "/changes diff"] {
            let count = await renderer.capturedWriteEvents().count
            await terminal.handleChangesCommand(command)
            let output = await renderer.capturedWriteEvents().dropFirst(count).map(\.text).joined()
            #expect(output.contains("Latest.swift"))
            #expect(!output.contains("Earlier.swift"))
            #expect(await terminal.fileArtifactHistory.snapshot() == before)
            #expect(terminal.lastFileChangeSummary == summaries[1])
        }
        let count = await renderer.capturedWriteEvents().count
        await terminal.handleArtifactsCommand()
        let history = await renderer.capturedWriteEvents().dropFirst(count).map(\.text).joined()
        #expect(history.contains("Earlier.swift"))
        #expect(history.contains("Latest.swift"))
        #expect(history.contains("### Turn 1 — 1 file"))
        #expect(history.contains("### Turn 2 — 1 file"))
        #expect(await terminal.fileArtifactHistory.snapshot() == before)
        #expect(await renderer.capturedWriteEvents().allSatisfy { $0.channel == .standardError })
        // Rendering /changes must not even reserve a hidden history number.
        let next = await terminal.fileArtifactHistory.append(
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
        terminal.lastFileChangeSummary = TurnFileChangeSummary(entries: [
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
        await terminal.handleChangesCommand("/changes diff")
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
        #expect(await terminal.fileArtifactHistory.snapshot().isEmpty)
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
        #expect(await terminal.fileArtifactHistory.snapshot().isEmpty)
    }

    @Test(arguments: ["/changes", "/changes diff", "/changes --diff"])
    func changesWithoutSummaryKeepsExistingMessage(command: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        await terminal.handleChangesCommand(command)
        let events = await renderer.capturedWriteEvents()
        #expect(events.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            == "No tracked file changes.")
        #expect(events.allSatisfy { $0.channel == .standardError })
        #expect(await terminal.fileArtifactHistory.snapshot().isEmpty)
    }

    @Test(arguments: ["assistant", "thought"])
    func delegatedArtifactPreservesSplitCodeFenceInTTY(_ stream: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer(isTerminal: true)
        let reference = makeRenderer(isTerminal: true)
        let terminal = try makeTerminal(directory, renderer: renderer)
        let context = try #require(await terminal.beginFileArtifactTurn())
        // Keep both an open fence and an incomplete source line across the
        // delegated completion. The continuation must not restart Markdown.
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
        let referencePrefixCount = await reference.capturedWriteEvents().count
        let deferred = await renderer.renderTaskGraphOverview(
            signature: "split-fence", markdown: "## Deferred fence overview\n"
        )
        #expect(deferred == .deferred)
        await terminal.writeSubAgentToolEvent(
            .init(
                agentID: "worker", agentName: "worker",
                toolCall: call("split-fence", path: "Artifact.swift"),
                lifecycle: .completed(result([
                    OperationFileChange(path: "Artifact.swift", oldText: nil, newText: "let artifact = 42\n")
                ]))
            ),
            sessionID: context.sessionID, history: context.history
        )
        let afterArtifact = await renderer.capturedWriteEvents()
        let visibleBeforeContinuation = TerminalANSIText.stripANSI(afterArtifact.map(\.text).joined())
        let artifactPosition = try #require(visibleBeforeContinuation.range(of: "added Artifact.swift"))
        let firstCodePosition = try #require(visibleBeforeContinuation.range(of: "let first = 1"))
        let overviewPosition = try #require(visibleBeforeContinuation.range(of: "Deferred fence overview"))
        #expect(firstCodePosition.lowerBound < artifactPosition.lowerBound)
        #expect(artifactPosition.lowerBound < overviewPosition.lowerBound)
        #expect(visibleBeforeContinuation.contains("1 │ +let artifact = 42"))
        #expect(!visibleBeforeContinuation.contains("🪬 Artifacts"))
        #expect(!visibleBeforeContinuation.contains("Turn 1 —"))
        #expect(!visibleBeforeContinuation.contains("Prose after fence"))
        #expect(await context.history.snapshot().isEmpty)

        for target in [renderer, reference] {
            if stream == "thought" {
                await target.writeThought(remaining)
            } else {
                await target.writeAssistantContent(remaining)
            }
            await target.finishStreamingOutput()
        }
        let continuation = await renderer.capturedWriteEvents().dropFirst(afterArtifact.count).map(\.text).joined()
        let expectedContinuation = await reference.capturedWriteEvents().dropFirst(referencePrefixCount).map(\.text).joined()
        // Compare the ANSI output too: source highlighting and post-fence prose
        // must match an uninterrupted stream, with no new thinking/bubble label.
        #expect(continuation == expectedContinuation)
        let visibleContinuation = TerminalANSIText.stripANSI(continuation)
        #expect(visibleContinuation.contains("let second = \"**literal**\""))
        #expect(visibleContinuation.contains("Prose after fence"))
        #expect(!visibleContinuation.contains("**Prose after fence**"))
        #expect(!visibleContinuation.contains("```"))
        #expect(!visibleContinuation.contains("Code"))
        #expect(!visibleContinuation.contains("🪬 Artifacts"))
    }

    @Test
    func finalFallbackOmitsUnchangedLiveFilesButShowsLaterOpaqueEdits() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: directory)
        let context = try #require(await terminal.beginFileArtifactTurn())
        for path in ["same.txt", "later.txt", "final.txt"] {
            try Data("before\n".utf8).write(to: directory.appendingPathComponent(path))
            await coordinator.captureBaselineIfNeeded(forAgentToolCall: call(path, path: path))
        }
        let changes = [
            OperationFileChange(path: "same.txt", oldText: "before\n", newText: "live\n"),
            OperationFileChange(path: "later.txt", oldText: "before\n", newText: "live\n")
        ]
        await terminal.publishLiveFileArtifacts(result(changes), callID: "live", context: context)
        try Data("live\n".utf8).write(to: directory.appendingPathComponent("same.txt"))
        try Data("opaque after live\n".utf8).write(to: directory.appendingPathComponent("later.txt"))
        try Data("final only\n".utf8).write(to: directory.appendingPathComponent("final.txt"))
        let liveCount = await renderer.capturedWriteEvents().count
        let summary = await terminal.collectFileChangeSummaryIfNeeded(
            from: coordinator, sessionID: context.sessionID, history: context.history, turnID: context.id
        )
        #expect(summary?.fileCount == 3)
        let fallback = await renderer.capturedWriteEvents().dropFirst(liveCount).map(\.text).joined()
        #expect(!fallback.contains("🪬 Artifacts"))
        #expect(!fallback.contains("Turn 1 —"))
        #expect(!fallback.contains("same.txt"))
        #expect(fallback.contains("later.txt"))
        #expect(fallback.contains("opaque after live"))
        #expect(fallback.contains("final.txt"))
        #expect(fallback.contains("1 │ +final only"))
        let turns = await terminal.fileArtifactHistory.snapshot()
        #expect(turns.count == 1)
        #expect(turns.first?.number == 1)
        #expect(turns.first?.artifacts.count == 3)
        #expect(terminal.lastFileChangeSummary == summary)
        let count = await renderer.capturedWriteEvents().count
        #expect(await terminal.collectFileChangeSummaryIfNeeded(
            from: coordinator, sessionID: context.sessionID, history: context.history, turnID: context.id
        ) == nil)
        #expect(await renderer.capturedWriteEvents().count == count)
    }

    @Test
    func finalReconciliationDrainsPendingPublicationBeforeSealingHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: directory)
        let context = try #require(await terminal.beginFileArtifactTurn(coordinator: coordinator))
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
            await terminal.collectFileChangeSummaryIfNeeded(
                from: coordinator, sessionID: context.sessionID, history: context.history, turnID: context.id
            )
        }
        #expect(!context.acceptsPublications)
        #expect(await renderer.capturedWriteEvents().isEmpty)
        await gate.release()
        #expect(await finalization.value?.fileCount == 1)
        let output = await renderer.capturedWriteEvents().map(\.text).joined()
        #expect(output.components(separatedBy: "1 │ +pending source").count - 1 == 1)
        #expect(terminal.activeFileArtifactTurn == nil)
    }

    @Test
    func resetRejectsStaleRootDelegateAndFinalEvidenceEvenWithSameSessionID() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = makeRenderer()
        let terminal = try makeTerminal(directory, renderer: renderer)
        let old = try #require(await terminal.beginFileArtifactTurn())
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: directory)
        await coordinator.captureBaselineIfNeeded(forAgentToolCall: call("call", path: "stale.txt"))
        try Data("stale\n".utf8).write(to: directory.appendingPathComponent("stale.txt"))
        let evidence = result([OperationFileChange(path: "stale.txt", oldText: nil, newText: "stale\n")])
        terminal.resetFileArtifactState()
        let current = try #require(await terminal.beginFileArtifactTurn())
        await terminal.publishLiveFileArtifacts(evidence, callID: "call", context: old)
        await terminal.writeSubAgentToolEvent(
            .init(agentID: "worker", agentName: "worker", toolCall: call("call", path: "stale.txt"), lifecycle: .completed(evidence)),
            sessionID: old.sessionID, history: old.history
        )
        #expect(await terminal.collectFileChangeSummaryIfNeeded(
            from: coordinator, sessionID: old.sessionID, history: old.history, turnID: old.id
        ) == nil)
        #expect(await renderer.capturedWriteEvents().isEmpty)
        #expect(terminal.lastFileChangeSummary == nil)
        #expect(await terminal.fileArtifactHistory.snapshot().isEmpty)
        await terminal.publishLiveFileArtifacts(evidence, callID: "call", context: current)
        let output = await renderer.capturedWriteEvents().map(\.text).joined()
        #expect(output.contains("**added `stale.txt`**  +1 -0"))
        #expect(output.contains("1 │ +stale"))
        #expect(!output.contains("🪬 Artifacts"))
        #expect(!output.contains("Turn 1 —"))
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
        let event = DirectSubAgentToolEvent(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .completed(delegated))
        await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .started))
        await handler?(event)
        await handler?(event)
        let next = DirectAgentToolCall(id: "next-call", name: "local.writeFile", argumentsObject: ["path": "Live.swift"], argumentsJSON: "{}")
        await handler?(.init(agentID: "worker", agentName: "worker", toolCall: next, lifecycle: .completed(
            DirectAgentToolResult(output: "Updated", summary: "Updated", fileChanges: [
                .init(path: "Live.swift", oldText: "delegated source\n", newText: "next source\n")
            ])
        )))
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
                await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .started))
            } else {
                await onEvent(.toolCallStarted(call))
            }
            try Data("stage \(stage)\n".utf8).write(to: workspace.appendingPathComponent("file.txt"))
            // A failed command may also have written files before exiting.
            let result = DirectAgentToolResult(output: "done", summary: "done", status: stage == 1 ? .completed : .failed)
            if delegated {
                await handler?(.init(agentID: "worker", agentName: "worker", toolCall: call, lifecycle: .completed(result)))
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
