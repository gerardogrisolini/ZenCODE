//
//  TerminalChatRenderingTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 29/05/26.
//
import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalChatRenderingTests {
    @Test
    func removingLeadingLineBreaksPreservesContent() {

        #expect(TerminalChat.removingLeadingLineBreaks("\n\nCiao") == "Ciao")
        #expect(TerminalChat.removingLeadingLineBreaks("\r\nCiao") == "Ciao")
        #expect(TerminalChat.removingLeadingLineBreaks("Ciao") == "Ciao")
        #expect(TerminalChat.removingLeadingLineBreaks("\n\n") == "")
    }

    @Test
    func chatLineInsetIsAppliedOnlyAtLineStarts() {
        var isAtLineStart = true
        #expect(
            TerminalChat.chatLineInsetApplied(
                to: "ciao\nmondo",
                prefix: " ",
                isAtLineStart: &isAtLineStart
            ) == " ciao\n mondo"
        )
        #expect(isAtLineStart == false)

        #expect(
            TerminalChat.chatLineInsetApplied(
                to: "!",
                prefix: " ",
                isAtLineStart: &isAtLineStart
            ) == "!"
        )
        #expect(isAtLineStart == false)

        #expect(
            TerminalChat.chatLineInsetApplied(
                to: "\nOK",
                prefix: " ",
                isAtLineStart: &isAtLineStart
            ) == "\n OK"
        )
    }

    @Test
    func chatSpacingNormalizationLimitsVisibleBlankRowsAcrossWrites() {
        var trailingNewlineCount = 0

        let first = TerminalChat.chatSpacingNormalized(
            "Thinking\n\n",
            trailingNewlineCount: &trailingNewlineCount
        )
        let second = TerminalChat.chatSpacingNormalized(
            "\n🛠️  Read\n\n\nNext",
            trailingNewlineCount: &trailingNewlineCount
        )

        #expect(first == "Thinking\n\n")
        #expect(second == "🛠️  Read\n\nNext")
        #expect(!("\(first)\(second)".contains("\n\n\n")))
        #expect(trailingNewlineCount == 0)
    }

    @Test
    func boldSectionBreakSeparatesGluedSectionTitleAcrossDeltas() {
        var state = TerminalChatBoldBreakState()

        let chunks = ["Fixed it incorrectly.", "*", "*Identifying bugs** done"]
        var rendered = chunks
            .map { TerminalChat.normalizedBoldSectionBreak($0, state: &state) }
            .joined()
        rendered += TerminalChat.flushBoldSectionBreak(state: &state)

        #expect(rendered == "Fixed it incorrectly.\n\n**Identifying bugs** done")
    }

    @Test
    func boldSectionBreakLeavesPlainBoldAndOrderedListsIntact() {
        var state = TerminalChatBoldBreakState()

        let plainBold = TerminalChat.normalizedBoldSectionBreak(
            "Use **bold** here",
            state: &state
        ) + TerminalChat.flushBoldSectionBreak(state: &state)
        #expect(plainBold == "Use **bold** here")

        var listState = TerminalChatBoldBreakState()
        let orderedList = TerminalChat.normalizedBoldSectionBreak(
            "1. First. 2. Second",
            state: &listState
        ) + TerminalChat.flushBoldSectionBreak(state: &listState)
        #expect(orderedList == "1. First. 2. Second")
    }

    @Test
    func thoughtNormalizationDoesNotAddBulletsAcrossDeltas() {
        var state = TerminalChatBoldBreakState()
        let chunks = [" Analizzo il bug.", " Verifico i test", ".", " Scrivo la fix"]
        let rendered = chunks
            .map { TerminalChat.normalizedBoldSectionBreak($0, state: &state) }
            .joined()

        #expect(rendered == " Analizzo il bug. Verifico i test. Scrivo la fix")
        #expect(!rendered.contains("•"))
    }

    @Test
    func thoughtNormalizationLeavesPlainNumbersInline() {
        var state = TerminalChatBoldBreakState()
        let rendered = TerminalChat.normalizedBoldSectionBreak(
            "Uso la versione 1.2. Poi continuo",
            state: &state
        )

        #expect(rendered == "Uso la versione 1.2. Poi continuo")
    }

    @Test
    func markdownFormatterStillFormatsExplicitThinkingMarkdown() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )
        let rendered = formatter.consume("- Primo\n- Secondo\n") + formatter.finish()

        #expect(rendered.contains("•"))
        #expect(rendered.contains("Primo"))
        #expect(rendered.contains("Secondo"))
    }

    @Test
    func markdownFormatterCompactsLooseListBlankLines() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )
        let rendered = formatter.consume("1. Primo\n\n2. Secondo\n") + formatter.finish()

        #expect(rendered.contains("Primo"))
        #expect(rendered.contains("Secondo"))
        #expect(!rendered.contains("\n\n"))
    }



    @Test
    func thinkingFormatterRemovesUnbalancedStrongMarkers() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )

        let rendered = formatter.consume("a. **renderListItem handles indentation.\n\n ** If it fails, keep the words.\n")

        #expect(!rendered.contains("**"))
        #expect(rendered.contains("renderListItem handles indentation."))
        #expect(rendered.contains("If it fails, keep the words."))
    }

    @Test
    func thinkingFormatterKeepsBalancedStrongMarkersRenderable() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )

        let rendered = formatter.consume("This is **important**.\n")

        #expect(rendered.contains("\u{1B}[1mimportant\u{1B}[0m"))
        #expect(!rendered.contains("**important**"))
    }

    @Test
    func applyPatchCompactRenderingShowsPatchFileOnSeparateLine() {
        let patch = """
        *** Begin Patch
        *** Update File: Sources/App.swift
        @@
        -old
        +new
        *** End Patch
        """
        let toolCall = DirectAgentToolCall(
            id: "patch",
            name: "local.applyPatch",
            argumentsObject: ["patch": patch],
            argumentsJSON: "{}"
        )

        let lines = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "✅",
            contentInsetWidth: 0
        )

        #expect(lines == [
            "🛠️  Edit:",
            "Sources/App.swift ✅"
        ])
    }

    @Test
    func applyPatchDetailRenderingShowsPatchFileInChangeLine() {
        let patch = """
        *** Begin Patch
        *** Update File: Sources/App.swift
        @@
        -old
        +new
        *** End Patch
        """
        let toolCall = DirectAgentToolCall(
            id: "patch",
            name: "local.applyPatch",
            argumentsObject: ["patch": patch],
            argumentsJSON: "{}"
        )
        let result = DirectAgentToolResult(output: "Done", summary: "Done")

        let lines = TerminalChat.detailedToolCallCompletedLines(
            for: toolCall,
            result: result,
            level: .medium
        )

        #expect(lines.contains("change: patch Sources/App.swift"))
    }

    @Test
    func systemMessageColoringWrapsNonBlankLines() {
        let rendered = TerminalChat.systemMessageColorApplied(
            to: "Tool details: full\n",
            isEnabled: true
        )

        #expect(rendered.hasPrefix("\u{1B}[38;5;110mTool details: full\u{1B}[0m\n"))
        #expect(rendered.hasSuffix("\n"))
    }

    @Test
    func startupInlineTextWrapsWithoutEllipsis() {
        #expect(TerminalChat.wrapInline("Commands: /help, /models, /agents", width: 18) == [
            "Commands: /help,",
            "/models, /agents"
        ])
        #expect(!TerminalChat.fitInline("Commands: /help, /models, /agents", width: 18).contains("..."))
    }

    @Test
    func statusBarModelFragmentIncludesThinkingSelection() {
        #expect(
            TerminalStatusBar.modelStatusFragment(
                modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
                thinkingSelection: .high
            ) == "Qwen3-Coder-30B-A3B-Instruct-4bit · High"
        )
        #expect(
            TerminalStatusBar.modelStatusFragment(
                modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
                thinkingSelection: nil
            ) == "Qwen3-Coder-30B-A3B-Instruct-4bit"
        )
    }

    @Test
    func statusBarGitFragmentShowsDiffSummary() {
        let summary = TerminalGitStatusSummary(
            changedFileCount: 3,
            additions: 12,
            deletions: 4
        )

        let rendered = TerminalStatusBar.gitStatusFragment(summary: summary)

        #expect(rendered.contains("\u{1B}[38;5;81m3\u{1B}[0m files"))
        #expect(rendered.contains("\u{1B}[38;5;114m+12\u{1B}[0m"))
        #expect(rendered.contains("\u{1B}[38;5;203m-4\u{1B}[0m"))
        #expect(TerminalStatusBar.visibleCharacterCount(rendered) == "3 files +12 -4".count)
    }

    @Test
    func statusBarVisibleCharacterCountIgnoresANSISequences() {
        let colored = "git \u{1B}[38;5;114m+12\u{1B}[0m \u{1B}[38;5;203m-4\u{1B}[0m"

        #expect(TerminalStatusBar.visibleCharacterCount(colored) == "git +12 -4".count)
    }

    @Test
    func gitNumstatSummaryCountsFilesAdditionsAndDeletions() {
        let output = """
        10	2	Sources/App.swift
        -	-	Assets/Icon.png
        1	0	Tests/AppTests.swift
        """

        #expect(
            TerminalChat.gitNumstatSummary(from: output) == TerminalGitStatusSummary(
                changedFileCount: 3,
                additions: 11,
                deletions: 2
            )
        )
    }

    @Test
    func gitStatusSummaryReturnsNilOutsideGitRepository() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-chat-git-status-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let summary = await TerminalChat.gitStatusSummary(in: directory)

        #expect(summary == nil)
    }

    @Test
    func markdownFormatterStylesHeadingsAndInlineCode() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)

        let rendered = formatter.consume("## Titolo con `codice`\n")

        #expect(rendered.contains("\u{1B}[1;38;5;75m## Titolo con"))
        #expect(rendered.contains("\u{1B}[38;5;180mcodice\u{1B}[0m"))
        #expect(rendered.hasSuffix("\n"))
    }

    @Test
    func markdownFormatterStreamsLongPlainLinesWithoutParsing() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)
        let plain = String(repeating: "a", count: 241)

        #expect(formatter.consume(plain) == plain)
        #expect(formatter.finish() == "")
    }

    @Test
    func markdownFormatterKeepsPotentialMarkdownBufferedUntilNewline() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)
        let partial = "## " + String(repeating: "a", count: 241)

        #expect(formatter.consume(partial) == "")
        #expect(formatter.consume("\n").contains("\u{1B}[1;38;5;75m"))
    }

    @Test
    func markdownFormatterEmitsStreamingBlankLineChunks() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)

        let first = formatter.consume("First paragraph.\n")
        let blank = formatter.consume("\n")
        let second = formatter.consume("Second paragraph.\n")

        #expect(first == "First paragraph.\n")
        #expect(blank == "\n")
        #expect(second == "Second paragraph.\n")
    }

    @Test
    func preservedSpacingTracksTrailingNewlinesThroughANSI() {
        var trailingNewlineCount = 0

        TerminalChat.updateTrailingNewlineCount(
            afterPreserving: "\u{1B}[90mthinking\n\u{1B}[0m",
            trailingNewlineCount: &trailingNewlineCount
        )

        #expect(trailingNewlineCount == 1)
    }

    @Test
    func markdownFormatterDoesNotBufferInlinePipelineAsTableCandidate() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)

        let rendered = formatter.consume("Use `cat file | grep foo | sort` now.\n")

        #expect(!rendered.isEmpty)
        #expect(rendered.contains("cat file"))
        #expect(formatter.finish() == "")
    }

    @Test
    func markdownFormatterRendersPipeTableAfterDelimiter() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)

        let header = formatter.consume("| A | B |\n")
        let rendered = formatter.consume("| --- | --- |\n| 1 | 2 |\n") + formatter.finish()

        #expect(header == "")
        #expect(rendered.contains("┌"))
        #expect(rendered.contains("A"))
        #expect(rendered.contains("1"))
    }

    @Test
    func markdownFormatterFlushesLongListsDuringStreaming() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)
        let list = (1...81)
            .map { "- item \($0)" }
            .joined(separator: "\n") + "\n"

        let rendered = formatter.consume(list)

        #expect(!rendered.isEmpty)
        #expect(rendered.contains("item 1"))
        #expect(rendered.contains("item 80"))
    }

    @Test
    func toolAndStatusWidthsUseTerminalCellWidth() {
        #expect(TerminalChat.displayWidth("🛠️ Tool") == TerminalANSIText.visibleWidth("🛠️ Tool"))
        #expect(TerminalChat.displayWidth("e\u{301}") == 1)
        #expect(TerminalStatusBar.visibleCharacterCount("🛠️ Tool") == 7)
        #expect(TerminalStatusBar.visibleCharacterCount("你好") == 4)
    }

    @Test
    func inputPanelRowsRespectWideCharacters() {
        let rows = TerminalStatusBar.inputPanelDisplayRows(
            text: "你好世界",
            cursorIndex: 4,
            contentWidth: 6,
            maxRows: 10
        )

        #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) <= 6 })
        #expect(rows.count == 3)
    }

    @Test
    func subAgentOverviewRendersPlainWrappedStatusWithoutBoxDrawing() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_1",
            name: "swift-scan",
            role: "swift-scan",
            isolationMode: .report,
            status: .closed,
            pending: false,
            latestOutput: "Trovati 3 file `.swift`: 1. `./Tests/ZenCODECoreTests/AgentCoreSessionRunnerTests.swift` 2. `./Tests/ZenCODECoreTests/MLXMemoryServiceTests.swift` 3. `./Tests/ZenCODECoreTests/VeryLongFileNameThatShouldWrapInsideTheBox.swift`",
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = TerminalChat.renderSubAgentOverview([snapshot])
        let visibleLines = rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { ansiStripped(String($0)) }

        #expect(visibleLines.first == "🤖 Sub-Agents")
        #expect(!rendered.contains("┌"))
        #expect(!rendered.contains("│"))
        #expect(!rendered.contains("└"))
        #expect(visibleLines.allSatisfy { $0.count <= 122 })
    }

    @Test
    func subAgentOverviewRendersModelAndCurrentActivity() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_2",
            name: "planner",
            role: "Planner",
            isolationMode: .report,
            status: .running,
            pending: true,
            modelID: "gpt-5",
            modelRuntime: "remote",
            currentActivity: "reading project files",
            currentToolName: "search.grep",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalChat.renderSubAgentOverview([snapshot]))

        #expect(rendered.contains("model: gpt-5 · remote"))
        #expect(rendered.contains("tool: search.grep"))
    }

    @Test
    func subAgentOverviewRendersActivityWithoutCurrentTool() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_3",
            name: "planner",
            role: "Planner",
            isolationMode: .report,
            status: .running,
            pending: true,
            currentActivity: "reading project files",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalChat.renderSubAgentOverview([snapshot]))

        #expect(rendered.contains("activity: reading project files"))
        #expect(!rendered.contains("tool:"))
    }

    @Test
    func failureMessageColoringWrapsNonBlankLines() {
        let rendered = TerminalChat.failureMessageColorApplied(
            to: "ZenCODE: HTTP 402\n\nRetry later.\n",
            isEnabled: true
        )

        #expect(rendered.hasPrefix("\u{1B}[38;5;203mZenCODE: HTTP 402\u{1B}[0m\n\n"))
        #expect(rendered.contains("\u{1B}[38;5;203mRetry later.\u{1B}[0m\n"))
        #expect(rendered.hasSuffix("\n"))
    }
}
