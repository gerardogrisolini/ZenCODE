//
//  TerminalChatRenderingTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 29/05/26.
//

import Foundation
import Markdown
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
    func toolOutputSpacingLeavesABlankRowAfterUnterminatedAssistantContent() {
        var trailingNewlineCount = 0
        TerminalChat.updateTrailingNewlineCount(
            afterPreserving: "Risposta del modello.",
            trailingNewlineCount: &trailingNewlineCount
        )

        let separator = TerminalChat.chatSpacingNormalized(
            "\n\n",
            trailingNewlineCount: &trailingNewlineCount
        )

        #expect("Risposta del modello.\(separator)🛠️ tool" == "Risposta del modello.\n\n🛠️ tool")
        #expect(trailingNewlineCount == 2)
    }

    @Test
    func boldSectionBreakSeparatesGluedSectionTitleAcrossDeltas() {
        var state = TerminalChatBoldBreakState()

        let chunks = ["Fixed it incorrectly.", "*", "*Identifying bugs** done"]
        var rendered = chunks
            .map { TerminalChat.normalizedBoldSectionBreak($0, state: &state) }
            .joined()
        rendered += TerminalChat.flushBoldSectionBreak(state: &state)

        #expect(rendered == "Fixed it incorrectly.\n**Identifying bugs** done")
    }

    @Test
    func boldSectionBreakSeparatesBackToBackBoldTitles() {
        var state = TerminalChatBoldBreakState()

        let chunks = ["**Planning isolated test execution**", "**Analyzing ANSI cursor**"]
        var rendered = chunks
            .map { TerminalChat.normalizedBoldSectionBreak($0, state: &state) }
            .joined()
        rendered += TerminalChat.flushBoldSectionBreak(state: &state)

        #expect(
            rendered ==
            "**Planning isolated test execution**\n**Analyzing ANSI cursor**"
        )
    }

    @Test
    func boldSectionBreakDoesNotBreakBeforeClosingMarkerAfterPeriod() {
        var state = TerminalChatBoldBreakState()

        let rendered = TerminalChat.normalizedBoldSectionBreak(
            "**Done.** next",
            state: &state
        ) + TerminalChat.flushBoldSectionBreak(state: &state)

        #expect(rendered == "**Done.** next")
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
    func thinkingFormatterHidesGPTReasoningSummaryComments() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )

        let rendered = formatter.consume("""
        Improving activePlan whitespace handling

        <!--
        """) + formatter.consume("""
         -->**Planning improved plan approval messaging**

        <!-- -->**Adding plan recording status flag**
        """) + formatter.finish()

        #expect(!rendered.contains("<!-- -->"))
        #expect(rendered.contains("\u{1B}[1mPlanning improved plan approval messaging\u{1B}[0m"))
        #expect(rendered.contains("\u{1B}[1mAdding plan recording status flag\u{1B}[0m"))
    }

    @Test
    func markdownFormatterHidesStandaloneHTMLComment() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        let rendered = formatter.consume("<!-- internal note -->\n") + formatter.finish()

        #expect(!rendered.contains("<!-- internal note -->"))
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
            "🛠️  local.applyPatch:",
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
            result: result
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
    func statusBarSubscriptionUsageOmitsUnavailableWindow() {
        let weeklyOnly = DirectAgentSubscriptionUsageStatus(
            provider: "ChatGPT",
            dailyUsedPercent: nil,
            weeklyUsedPercent: 42
        )
        let dailyOnly = DirectAgentSubscriptionUsageStatus(
            provider: "ChatGPT",
            dailyUsedPercent: 10,
            weeklyUsedPercent: nil
        )

        #expect(TerminalStatusBar.subscriptionUsageFragment(weeklyOnly) == "w:42%")
        #expect(TerminalStatusBar.subscriptionUsageFragment(dailyOnly) == "d:10%")
    }

    @Test
    func statusBarShowsAccessModeDotOnlyForFullAccess() {
        let statusBar = TerminalStatusBar(isEnabled: false)
        var defaultState = TerminalStatusBar.State()
        defaultState.latestModelID = "test-model"

        let defaultText = statusBar.statusTextLocked(state: &defaultState)
        #expect(defaultText == "test-model")
        #expect(TerminalStatusBar.accessModeStatusFragment(.standard) == nil)

        var fullAccessState = defaultState
        fullAccessState.localExecAccessMode = .fullAccess
        fullAccessState.latestModelRuntime = "local"
        let fullAccessText = statusBar.statusTextLocked(state: &fullAccessState)
        let redDot = "\u{1B}[31m●\u{1B}[0m"
        #expect(fullAccessText == "test-model · local · \(redDot)")
        #expect(!fullAccessText.contains("mode full access"))
    }

    @Test
    func statusBarPlacesAccessModeDotImmediatelyBeforeFiles() {
        let statusBar = TerminalStatusBar(isEnabled: false)
        var state = TerminalStatusBar.State()
        state.localExecAccessMode = .fullAccess
        state.latestModelID = "test-model"
        state.latestGitStatusSummary = TerminalGitStatusSummary(
            changedFileCount: 3,
            additions: 12,
            deletions: 4
        )

        let statusText = statusBar.statusTextLocked(state: &state)
        let redDot = "\u{1B}[31m●\u{1B}[0m"

        #expect(statusText.contains("test-model · \(redDot) · \u{1B}[38;5;81m3\u{1B}[0m files"))
    }

    @Test
    func statusBarSynchronizesFromCurrentRunnerAccessMode() async throws {
        let runner = AgentCoreSessionRunner()
        #expect(await runner.toggleLocalExecAccessMode() == .fullAccess)
        let terminal = try makeTerminalForToolInterleavingTest(sessionRunner: runner)

        await terminal.synchronizeLocalExecAccessModeStatusBar()

        let accessMode = await terminal.statusBar.state.localExecAccessMode
        #expect(accessMode == .fullAccess)
    }

    @Test
    func statusBarResetPreservesFullAccessMode() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        await statusBar.update(localExecAccessMode: .fullAccess)

        await statusBar.reset()

        let accessMode = await statusBar.state.localExecAccessMode
        #expect(accessMode == .fullAccess)
    }

    @Test
    func statusBarRejectsStaleInputPanelSnapshots() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        await statusBar.updateInputPanel(
            text: "latest",
            cursorIndex: 6,
            modeText: "Prompt",
            helpText: "Help",
            revision: 2
        )
        await statusBar.updateInputPanel(
            text: "stale",
            cursorIndex: 5,
            modeText: "Prompt",
            helpText: "Help",
            revision: 1
        )

        #expect(await statusBar.state.inputPanelState?.text == "latest")

        await statusBar.clearInputPanel(revision: 3)
        await statusBar.updateInputPanel(
            text: "stale after clear",
            cursorIndex: 17,
            modeText: "Prompt",
            helpText: "Help",
            revision: 2
        )
        #expect(await statusBar.state.inputPanelState == nil)
    }

    @Test
    func narrowPanelHelpKeepsAccessShortcutVisible() {
        let line = TerminalStatusBar.inputPanelModeLineText(
            modeText: "Prompt",
            helpText: "Enter queue · Option+Enter newline · Ctrl+T tools · Ctrl+A access · Esc stop",
            compactHelpText: "Ctrl+T · Ctrl+A access",
            width: 36
        )

        #expect(line.contains("Ctrl+T"))
        #expect(line.contains("Ctrl+A access"))
        #expect(TerminalStatusBar.visibleCharacterCount(line) <= 36)
    }

    @Test
    func runtimeHelpListsCtrlAAccessModeShortcutAfterCtrlT() throws {
        let terminal = try makeTerminalForToolInterleavingTest()
        let help = terminal.renderHelpTextForCurrentAgent()

        #expect(
            help.contains(
                "Ctrl+T toggles compact/full tool output.\n"
                    + "Ctrl+A toggles default/full access for local.exec approvals in the interactive panel."
            )
        )
    }

    @Test
    func generationOnlyAllowsCommandsWithConcurrencySafeState() {
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/help"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/tasks"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/tasks list"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/tasks retry task-1"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/telegram"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/telegram on"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/telegram off"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/open"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/changes"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/plan status"))
    }

    @Test
    func interleavedModeMessageClearsCompactToolRewriteState() async throws {
        let terminal = try makeTerminalForToolInterleavingTest()
        let toolCall = DirectAgentToolCall(
            id: "compact-tool",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await terminal.writeToolCallStarted(toolCall)

        await terminal.writeAccessModeChangeMessage(.fullAccess)
        let snapshot = await terminal.renderCoordinator.snapshot()

        #expect(snapshot.activeCompactToolCallID == nil)
        #expect(snapshot.activeCompactToolRenderedRowCount == 0)
    }

    @Test
    func interleavedModeMessageClearsDetailedToolRewriteState() async throws {
        let terminal = try makeTerminalForToolInterleavingTest()
        let toolCall = DirectAgentToolCall(
            id: "detailed-tool",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await terminal.renderCoordinator.setToolOutputDetailLevel(.expanded)
        await terminal.writeToolCallStarted(toolCall)

        await terminal.writeAccessModeChangeMessage(.standard)
        let snapshot = await terminal.renderCoordinator.snapshot()

        #expect(snapshot.activeDetailedToolCallID == nil)
        #expect(snapshot.activeDetailedToolRenderedRowCount == 0)
    }

    @Test
    func taskOverviewWaitsForCompactToolCompletion() async throws {
        let runner = AgentCoreSessionRunner(taskGraphStore: nil)
        let terminal = try makeTerminalForToolInterleavingTest(sessionRunner: runner)
        let orchestrator = await runner.taskOrchestrator
        _ = try await orchestrator.createGraph(
            sessionID: terminal.sessionID,
            id: "render-interleaving",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(id: "first", title: "First"),
                TaskDefinition(id: "second", title: "Second"),
            ]
        )
        let toolCall = DirectAgentToolCall(
            id: "wait-tool",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await terminal.writeToolCallStarted(toolCall)

        await terminal.publishTaskGraphOverviewIfChanged(
            observedSessionID: terminal.sessionID
        )
        let deferredSnapshot = await terminal.renderCoordinator.snapshot()

        #expect(deferredSnapshot.lastRenderedTaskGraphOverviewSignature == nil)
        #expect(deferredSnapshot.activeCompactToolCallID == toolCall.id)
        #expect(deferredSnapshot.activeCompactToolRenderedRowCount > 0)
        #expect(deferredSnapshot.deferredTaskGraphOverviewRender)
        #expect(!(await terminal.shouldPublishDeferredTaskGraphOverview()))

        await terminal.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )
        #expect(await terminal.shouldPublishDeferredTaskGraphOverview())
        await terminal.publishTaskGraphOverviewIfChanged(
            observedSessionID: terminal.sessionID
        )
        let renderedSnapshot = await terminal.renderCoordinator.snapshot()

        #expect(renderedSnapshot.activeCompactToolCallID == nil)
        #expect(renderedSnapshot.activeCompactToolRenderedRowCount == 0)
        #expect(renderedSnapshot.lastRenderedTaskGraphOverviewSignature != nil)
        #expect(!renderedSnapshot.deferredTaskGraphOverviewRender)
    }

    @Test
    func subAgentOverviewWaitsForDetailedToolCompletion() async throws {
        let terminal = try makeTerminalForToolInterleavingTest(
            sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil)
        )
        let toolCall = DirectAgentToolCall(
            id: "wait-tool",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await terminal.renderCoordinator.setToolOutputDetailLevel(.expanded)
        await terminal.writeToolCallStarted(toolCall)

        await terminal.renderSubAgentOverview(force: true)
        let deferredSnapshot = await terminal.renderCoordinator.snapshot()

        #expect(deferredSnapshot.lastRenderedSubAgentOverviewSignature == nil)
        #expect(deferredSnapshot.activeDetailedToolCallID == toolCall.id)
        #expect(deferredSnapshot.activeDetailedToolRenderedRowCount > 0)

        await terminal.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )
        await terminal.renderSubAgentOverview(force: true)
        let renderedSnapshot = await terminal.renderCoordinator.snapshot()

        #expect(renderedSnapshot.activeDetailedToolCallID == nil)
        #expect(renderedSnapshot.activeDetailedToolRenderedRowCount == 0)
        #expect(renderedSnapshot.lastRenderedSubAgentOverviewSignature != nil)
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
    func statusBarRejectsStaleGitRefreshResults() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        let staleGeneration = await statusBar.beginGitStatusRefresh()
        let currentGeneration = await statusBar.beginGitStatusRefresh()
        let stale = TerminalGitStatusSummary(
            changedFileCount: 1,
            additions: 1,
            deletions: 0
        )
        let current = TerminalGitStatusSummary(
            changedFileCount: 2,
            additions: 4,
            deletions: 1
        )

        _ = await statusBar.update(
            gitStatusSummary: current,
            refreshGeneration: currentGeneration
        )
        _ = await statusBar.update(
            gitStatusSummary: stale,
            refreshGeneration: staleGeneration
        )
        #expect(await statusBar.state.latestGitStatusSummary == current)
    }

    @Test
    func statusBarVisibleCharacterCountIgnoresANSISequences() {
        let colored = "git \u{1B}[38;5;114m+12\u{1B}[0m \u{1B}[38;5;203m-4\u{1B}[0m"

        #expect(TerminalStatusBar.visibleCharacterCount(colored) == "git +12 -4".count)
    }

    @Test
    func statusBarRendersSubscriptionPrefillAndGenerationTokenCounts() {
        let metrics = ChatGPTSubscriptionGenerationClient
            .chatGPTSubscriptionVisibleMetrics(
                DirectAgentGenerationMetrics(
                    promptTokenCount: 120,
                    cachedPromptTokenCount: 800,
                    promptTokensPerSecond: 60,
                    completionTokenCount: 32,
                    completionTokensPerSecond: 8
                )
            )

        #expect(
            TerminalStatusBar.generationTokenCountsFragment(metrics) == "c:800 p:120 g:32"
        )
    }

    @Test
    func statusBarKeepsLatestAnalyticsAfterCompletionAndCancellation() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        let metrics = DirectAgentGenerationMetrics(
            promptTokenCount: 120,
            cachedPromptTokenCount: 800,
            promptTokensPerSecond: 60,
            completionTokenCount: 32,
            completionTokensPerSecond: 8,
            responseDurationSeconds: 4
        )
        let contextWindow = DirectAgentContextWindowStatus(
            usedTokens: 952,
            maxTokens: 10_000,
            modelID: "test-model",
            isApproximate: true
        )

        await statusBar.beginRequest()
        await statusBar.setProcessing(true)
        _ = await statusBar.update(metrics: metrics)
        _ = await statusBar.update(contextWindow: contextWindow)
        await statusBar.setProcessing(false)

        var state = await statusBar.state
        #expect(state.latestMetrics?.promptTokenCount == 120)
        #expect(state.latestMetrics?.completionTokenCount == 32)
        #expect(state.latestMetrics?.responseDurationSeconds == 4)
        #expect(state.latestContextWindow?.usedTokens == 952)
        #expect(state.latestContextWindow?.maxTokens == 10_000)

        await statusBar.beginRequest()
        await statusBar.setProcessing(true)
        // Esc stops the request without requiring another metrics update.
        await statusBar.setProcessing(false)

        state = await statusBar.state
        #expect(state.latestMetrics?.promptTokenCount == 120)
        #expect(state.latestMetrics?.completionTokenCount == 32)
        #expect(state.latestMetrics?.responseDurationSeconds == 4)
        #expect(state.latestContextWindow?.usedTokens == 952)
        #expect(state.latestContextWindow?.maxTokens == 10_000)
    }

    @Test
    func statusBarFirstMetricsOfNewRequestReplacePreviousAnalytics() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: 120,
                cachedPromptTokenCount: 800,
                promptTokensPerSecond: 60,
                completionTokenCount: 32,
                completionTokensPerSecond: 8,
                responseDurationSeconds: 4
            )
        )

        await statusBar.beginRequest()

        #expect(await statusBar.state.latestMetrics?.promptTokenCount == 120)
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: nil,
                promptTokensPerSecond: nil,
                completionTokenCount: 5,
                completionTokensPerSecond: 2
            )
        )

        let state = await statusBar.state
        #expect(state.latestMetrics?.promptTokenCount == nil)
        #expect(state.latestMetrics?.cachedPromptTokenCount == nil)
        #expect(state.latestMetrics?.promptTokensPerSecond == nil)
        #expect(state.latestMetrics?.completionTokenCount == 5)
        #expect(state.latestMetrics?.completionTokensPerSecond == 2)
        #expect(state.latestMetrics?.responseDurationSeconds == nil)
    }

    @Test
    func statusBarGenerationTokenCountsFragmentIsCompactAndOptional() {
        let metrics = DirectAgentGenerationMetrics(
            promptTokenCount: 15_000,
            promptTokensPerSecond: nil,
            completionTokenCount: 20_000,
            completionTokensPerSecond: nil
        )
        let unavailableMetrics = DirectAgentGenerationMetrics(
            promptTokenCount: nil,
            promptTokensPerSecond: nil,
            completionTokenCount: nil,
            completionTokensPerSecond: nil
        )

        #expect(TerminalStatusBar.generationTokenCountsFragment(metrics) == "p:15k g:20k")
        #expect(TerminalStatusBar.generationTokenCountsFragment(unavailableMetrics) == nil)
    }

    @Test
    func statusBarGenerationTokenCountsShowsReportedCacheMiss() {
        let metrics = DirectAgentGenerationMetrics(
            promptTokenCount: 15_000,
            cachedPromptTokenCount: 0,
            promptTokensPerSecond: nil,
            completionTokenCount: 2_000,
            completionTokensPerSecond: nil
        )

        #expect(
            TerminalStatusBar.generationTokenCountsFragment(metrics) == "c:0 p:15k g:2.0k"
        )
    }

    @Test
    func statusBarTextPlacesGenerationTokenCountsAfterTime() {
        let statusBar = TerminalStatusBar(isEnabled: false)
        var state = TerminalStatusBar.State()
        state.latestMetrics = DirectAgentGenerationMetrics(
            promptTokenCount: 15_000,
            promptTokensPerSecond: nil,
            completionTokenCount: 20_000,
            completionTokensPerSecond: nil,
            responseDurationSeconds: 12
        )

        #expect(
            statusBar.statusTextLocked(state: &state)
                .contains("35.0k/-- · 0:00:12 · p:15k g:20k")
        )
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
    func markdownFormatterReservesChatInsetForTables() {
        let renderWidth = 60
        let longItem = Array(repeating: "long plan item", count: 24).joined(separator: " ")
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: renderWidth,
            supportsHyperlinks: false
        )

        let rendered = formatter.consume("""
        | # | Plan item | Status |
        | ---: | --- | --- |
        | 1 | \(longItem) | `in_progress` |

        """) + formatter.finish()
        var isAtLineStart = true
        let insetRendered = TerminalChat.chatLineInsetApplied(
            to: rendered,
            prefix: " ",
            isAtLineStart: &isAtLineStart
        )
        let boxRows = insetRendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains("│") || $0.contains("─") }

        #expect(!boxRows.isEmpty)
        #expect(boxRows.allSatisfy {
            TerminalANSIText.visibleWidth($0) <= renderWidth
        })
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
    func markdownFormatterRendersFencedCodeBlockWithSyntaxHighlighting() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        let rendered = formatter.consume("```swift\nlet x = 1\n```\n") + formatter.finish()

        // Fence delimiter lines are dimmed and preserved verbatim.
        #expect(rendered.contains("\u{1B}[90m```swift\u{1B}[0m"))
        #expect(rendered.contains("\u{1B}[90m```\u{1B}[0m"))
        // Body is routed through the code renderer: `let` is a keyword.
        #expect(rendered.contains("\u{1B}[38;5;141mlet\u{1B}[0m"))
        #expect(rendered.contains("x = "))
    }

    @Test
    func markdownFormatterDoesNotParseMarkdownInsideCodeFence() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        let rendered = formatter.consume("```\n- not a list\n**not bold**\n```\n")
            + formatter.finish()

        // Content inside the fence keeps its literal markers instead of being
        // converted to a bullet or bold run.
        #expect(rendered.contains("- not a list"))
        #expect(rendered.contains("**not bold**"))
        #expect(!rendered.contains("•"))
    }

    @Test
    func markdownFormatterWrapsLongPlainLinesToFixedWidth() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 20,
            supportsHyperlinks: false
        )
        let line = Array(repeating: "word", count: 12).joined(separator: " ")

        let rendered = formatter.consume(line + "\n") + formatter.finish()

        let visibleRows = rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { TerminalANSIText.visibleWidth(String($0)) }
        // One column is reserved for the chat inset, so rows stay within 19.
        #expect(visibleRows.allSatisfy { $0 <= 19 })
        #expect(visibleRows.contains { $0 > 0 })
        #expect(rendered.contains("word"))
    }

    @Test
    func markdownFormatterDoesNotWrapTableBoxDrawing() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 12,
            supportsHyperlinks: false
        )

        _ = formatter.consume("| Column A | Column B |\n")
        let rendered = formatter.consume("| --- | --- |\n| value 1 | value 2 |\n")
            + formatter.finish()

        // Box-drawing rows are emitted intact even though they exceed the narrow
        // render width; wrapping them would corrupt the table layout.
        #expect(rendered.contains("┌"))
        #expect(rendered.contains("│"))
        let boxRows = rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains("│") || $0.contains("─") }
        #expect(!boxRows.isEmpty)
        // Every box-drawing row exceeds the render width, proving wrapIfNeeded
        // left the table untouched instead of breaking it across lines.
        #expect(boxRows.allSatisfy { TerminalANSIText.visibleWidth($0) > 12 })
    }

    @Test
    func markdownFormatterRendersMultiLineBlockQuote() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        let rendered = formatter.consume("> first line\n> second line\n")
            + formatter.finish()

        // Blockquote lines stream incrementally (one rendered as the next
        // arrives), yet produce the same visual result as a single block.
        #expect(rendered.contains("first line"))
        #expect(rendered.contains("second line"))
        // Literal blockquote markers are consumed by the renderer.
        #expect(!rendered.contains("> first line"))
    }

    @Test
    func markdownFormatterStreamsListItemByItem() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // The first item is complete as soon as the second top-level marker
        // arrives, so it is rendered before finish() is ever called.
        let streamed = formatter.consume("- alpha\n- beta\n")
        #expect(streamed.contains("alpha"))
        #expect(streamed.contains("•"))
        // The last item stays buffered until the stream ends.
        #expect(!streamed.contains("beta"))

        let tail = formatter.finish()
        #expect(tail.contains("beta"))
    }

    @Test
    func markdownFormatterStreamsOrderedListPreservingNumbers() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        let streamed = formatter.consume("1. first\n2. second\n")
        // Each item flushes independently but keeps its source start number.
        #expect(streamed.contains("1."))
        #expect(streamed.contains("first"))
        #expect(!streamed.contains("second"))

        let tail = formatter.finish()
        #expect(tail.contains("2."))
        #expect(tail.contains("second"))
    }

    @Test
    func markdownFormatterStreamsLazyOrderedListWithAscendingNumbers() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // The common lazy "1./1./1." convention must render as 1./2./3. even
        // though each item is flushed as a standalone document while streaming.
        let streamed = formatter.consume("1. alpha\n1. beta\n1. gamma\n") + formatter.finish()
        let plain = TerminalANSIText.stripANSI(streamed)

        #expect(plain.contains("1. alpha"))
        #expect(plain.contains("2. beta"))
        #expect(plain.contains("3. gamma"))
        // The lazy source markers must not leak through unchanged.
        #expect(!plain.contains("1. beta"))
        #expect(!plain.contains("1. gamma"))
    }

    @Test
    func markdownFormatterStreamsNestedListMatchingWholeBlock() {
        var streaming = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        let source = "- top\n  - nested\n- top two\n"

        // Feed the nested list one line per delta.
        var streamed = ""
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            streamed += streaming.consume(line + "\n")
        }
        streamed += streaming.finish()

        // Independent oracle: render the whole block directly through the
        // markdown renderer, bypassing the stream formatter entirely. Using a
        // second copy of the (modified) formatter would not be independent.
        var expectedRenderer = TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: false,
            renderWidth: 79
        )
        let expected = expectedRenderer.visit(Document(parsing: source)) + "\n"

        // Streaming line by line produces the same rendering as parsing the
        // whole block at once: nested structure and indentation are preserved.
        #expect(streamed == expected)
        #expect(streamed.contains("•"))
        #expect(streamed.contains("◦"))
    }

    @Test
    func markdownFormatterStreamsBlockQuoteIncrementally() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // The first quote line is rendered as soon as the next one arrives.
        let streamed = formatter.consume("> first line\n> second line\n")
        #expect(streamed.contains("first line"))
        #expect(!streamed.contains("> first line"))
        // The last quote line stays buffered until the stream ends.
        #expect(!streamed.contains("second line"))

        let tail = formatter.finish()
        #expect(tail.contains("second line"))
    }

    @Test
    func markdownFormatterStreamsTableWithManyRowsIntact() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // A confirmed table with more rows than the soft safety limit (16) must
        // stay intact: it is never split mid-table by the safety flush.
        var source = "| A | B |\n| --- | --- |\n"
        for row in 1...20 {
            source += "| \(row) | \(row * 10) |\n"
        }

        let rendered = formatter.consume(source) + formatter.finish()

        // The whole table renders as a single box-drawing block.
        #expect(rendered.contains("┌"))
        #expect(rendered.contains("└"))
        // The last row is present, proving no rows were dropped or spilled out
        // as literal text by an early safety flush.
        #expect(rendered.contains("200"))
        // Only one table border block exists (a single ┌ line).
        #expect(rendered.components(separatedBy: "┌").count - 1 == 1)
    }

    @Test
    func markdownFormatterStreamsListItemWithManyNestedChildren() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // A single top-level item with many nested children exceeds the soft
        // safety limit (16 lines). The hierarchy must be preserved: the nested
        // children must never be promoted to top-level bullets.
        var source = "- parent\n"
        for child in 1...20 {
            source += "  - child \(child)\n"
        }

        let rendered = formatter.consume(source) + formatter.finish()

        // The last nested child is present and stays nested (◦ glyph), proving
        // the safety flush did not truncate the item mid-structure.
        #expect(rendered.contains("child 20"))
        #expect(rendered.contains("◦"))
        // Exactly one top-level bullet (•) for the parent item.
        let topLevelBullets = rendered.components(separatedBy: "•").count - 1
        #expect(topLevelBullets == 1)
    }

    @Test
    func markdownFormatterThinkingPreservesMultilineBoldInBlockQuote() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )

        // A bold span that straddles two quote lines. Streaming line by line
        // would make each `**` unbalanced and the thinking formatter would drop
        // both markers; the blockquote must buffer until the span closes.
        let streamed = formatter.consume("> **first line\n> second line**\n") + formatter.finish()

        // Both strong markers survived and the bold run rendered.
        #expect(streamed.contains("\u{1B}[1mfirst line"))
        #expect(streamed.contains("second line\u{1B}[0m"))
        // No stray literal markers leaked into the output.
        #expect(!streamed.contains("**"))
    }

    @Test
    func markdownFormatterStreamsBulletToOrderedTransitionRenumbered() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // A bullet item followed (with a blank line, still inside the list
        // block) by lazy "1./1." ordered items. The ordered segment must
        // restart numbering from 1 and ascend to 2, not stay "1./1.".
        let streamed = formatter.consume("- bullet\n\n1. first\n1. second\n") + formatter.finish()
        let plain = TerminalANSIText.stripANSI(streamed)

        #expect(plain.contains("1. first"))
        #expect(plain.contains("2. second"))
        #expect(!plain.contains("1. second"))
        // A blank line separates the two list-type blocks (matching the document
        // renderer) rather than concatenating them directly.
        #expect(plain.contains("\n\n1. first"))
    }

    @Test
    func markdownFormatterStreamsOrderedBulletOrderedRestartsFromOne() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // ordered → bullet → ordered: each type change starts a new list block,
        // so the second ordered segment restarts at 1./2. (not continues 3./4.).
        let streamed = formatter.consume(
            "1. alpha\n1. beta\n\n- bullet\n\n1. gamma\n1. delta\n"
        ) + formatter.finish()
        let plain = TerminalANSIText.stripANSI(streamed)

        #expect(plain.contains("1. alpha"))
        #expect(plain.contains("2. beta"))
        #expect(plain.contains("1. gamma"))
        #expect(plain.contains("2. delta"))
        // The second ordered segment did not inherit the counter.
        #expect(!plain.contains("3. gamma"))
        #expect(!plain.contains("4. delta"))
        // Blank separators appear at both type-change boundaries (the rendered
        // bullet glyph is •, not the literal source marker).
        #expect(plain.contains("2. beta\n\n• bullet"))
        #expect(plain.contains("bullet\n\n1. gamma"))
    }

    @Test
    func markdownFormatterStreamsFirstItemBeyondCharLimitPreservesHierarchy() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // A single top-level item whose first line alone exceeds the soft char
        // limit (2000), followed by nested children. The children must not be
        // orphaned: the item stays buffered until the hard cap, preserving
        // hierarchy.
        let longWord = String(repeating: "x", count: 2100)
        var source = "- \(longWord)\n"
        for child in 1...3 {
            source += "  - child \(child)\n"
        }

        let rendered = formatter.consume(source) + formatter.finish()

        // The children stayed nested (◦), proving the item was not flushed
        // mid-structure by the soft char limit.
        #expect(rendered.contains("child 3"))
        #expect(rendered.contains("◦"))
        let topLevelBullets = rendered.components(separatedBy: "•").count - 1
        #expect(topLevelBullets == 1)
    }

    @Test
    func markdownFormatterUnbalancedBlockQuoteFlushesWithinHardCap() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )

        // A blockquote with an opener `**` that is never closed. It must keep
        // buffering past the soft cap but eventually flush at the hard cap
        // (80 lines) instead of buffering indefinitely.
        var source = "> **unclosed bold\n"
        for line in 1...85 {
            source += "> filler line \(line)\n"
        }

        // consume() alone must produce output (the hard cap forced a flush)
        // rather than buffering everything indefinitely.
        let partial = formatter.consume(source)
        #expect(!partial.isEmpty)
        #expect(partial.contains("unclosed bold"))

        // finish() drains the remainder, so the whole quote is rendered.
        let rendered = partial + formatter.finish()
        #expect(rendered.contains("filler line 85"))
    }

    @Test
    func markdownFormatterStrayCloserInBlockQuoteDoesNotBlockIndefinitely() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )

        // A stray closer `**` with no preceding opener can never pair, so the
        // balance guard would block forever without the hard cap.
        var source = "> stray**\n"
        for line in 1...85 {
            source += "> line \(line)\n"
        }

        let rendered = formatter.consume(source)

        // The hard cap forced a flush; the formatter did not hang.
        #expect(!rendered.isEmpty)
        #expect(rendered.contains("stray"))
    }

    @Test
    func markdownFormatterHandlesIntMaxOrderedMarkerWithoutCrash() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // A pathological ordered marker at Int.max (19 digits) must not crash
        // the renumbering arithmetic (overflow would trap). It renders verbatim.
        let streamed = formatter.consume(
            "9223372036854775807. item\n9223372036854775807. item\n"
        ) + formatter.finish()

        // No crash: the items rendered and the huge number is preserved verbatim
        // (renumbering is skipped for out-of-range values).
        #expect(streamed.contains("9223372036854775807"))
        #expect(streamed.contains("item"))
    }

    @Test
    func markdownFormatterRenumbersNineDigitOrderedMarkers() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // Swift Markdown accepts up to 9-digit ordered markers. Two lazy markers
        // at 10000000 (8 digits) must renumber to 10000000./10000001.
        let streamed8 = formatter.consume(
            "10000000. item\n10000000. item\n"
        ) + formatter.finish()
        let plain8 = TerminalANSIText.stripANSI(streamed8)
        #expect(plain8.contains("10000000. item"))
        #expect(plain8.contains("10000001. item"))

        // 9-digit markers are also valid and renumber correctly.
        var formatter9 = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )
        let streamed9 = formatter9.consume(
            "999999998. item\n999999998. item\n"
        ) + formatter9.finish()
        let plain9 = TerminalANSIText.stripANSI(streamed9)
        #expect(plain9.contains("999999998. item"))
        #expect(plain9.contains("999999999. item"))
    }

    @Test
    func markdownFormatterLeavesTenDigitOrderedMarkerVerbatimWithoutCrash() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // 10 digits exceed the markdown limit (9). Renumbering is skipped, the
        // marker renders verbatim, and no overflow crash occurs.
        let streamed = formatter.consume(
            "1000000000. item\n1000000000. item\n"
        ) + formatter.finish()
        let plain = TerminalANSIText.stripANSI(streamed)

        // Both items render verbatim with the original number.
        #expect(plain.contains("1000000000. item"))
        // No incremented number appears.
        #expect(!plain.contains("1000000001"))
    }

    @Test
    func markdownFormatterDoesNotClassifyTenDigitMarkerAsListTransition() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // A bullet item followed by a 10-digit marker. Swift Markdown treats the
        // 10-digit line as a lazy continuation of the bullet item (indented
        // under it), NOT as a new list block. The formatter must buffer it as a
        // continuation line so the rendered structure matches the document
        // parser exactly.
        let source = "- bullet\n1000000000. first\n"
        let streamed = formatter.consume(source) + formatter.finish()

        // Independent oracle: render the whole document directly through the
        // markdown renderer, bypassing the stream formatter. Using a second
        // formatter copy would not be independent.
        var expectedRenderer = TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: false,
            renderWidth: 79
        )
        let expected = expectedRenderer.visit(Document(parsing: source)) + "\n"

        // The streaming output matches the full-document rendering: the 10-digit
        // line stays inside the list item as a lazy continuation (indented under
        // the bullet), not flushed as a separate paragraph.
        #expect(streamed == expected)

        let plain = TerminalANSIText.stripANSI(streamed)
        // The 10-digit line is present and indented as a continuation.
        #expect(plain.contains("1000000000. first"))
        // No block separator between the bullet and the continuation line.
        #expect(!plain.contains("\n\n1000000000."))
    }

    @Test
    func markdownFormatterStopsRenumberingAtNineDigitBoundary() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        // Starting at 999_999_999 (9 digits, the max valid marker). The second
        // item would renumber to 1_000_000_000 (10 digits), which Swift Markdown
        // treats as plain text. The formatter must stop renumbering there and
        // leave the marker verbatim, keeping the output coherent with the parser.
        let streamed = formatter.consume(
            "999999999. alpha\n999999999. beta\n"
        ) + formatter.finish()
        let plain = TerminalANSIText.stripANSI(streamed)

        // First item renumbered to its start number.
        #expect(plain.contains("999999999. alpha"))
        // Second item is left verbatim — not renumbered to 1000000000, which
        // would be parsed as a paragraph and lose ordered styling.
        #expect(plain.contains("999999999. beta"))
        // No 10-digit number was generated.
        #expect(!plain.contains("1000000000"))
    }

    @Test
    func markdownFormatterThinkingPreservesBoldInLongBlockQuote() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )

        // A blockquote whose first line (with the `**` opener) exceeds the soft
        // char cap (2000). The soft-cap safety flush must not fire mid-span;
        // the blockquote keeps buffering until the `**` closes so the bold run
        // survives in the thinking formatter.
        let longBody = String(repeating: "x", count: 2050)
        let streamed = formatter.consume("> **\(longBody)\n> close**\n") + formatter.finish()

        // Both strong markers survived and the bold run rendered.
        #expect(streamed.contains("\u{1B}[1m"))
        #expect(streamed.contains("close"))
        #expect(!streamed.contains("**"))
    }

    @Test
    func markdownFormatterStreamsTableIntactUntilComplete() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)

        // The header stays buffered while the table is still only a candidate.
        let header = formatter.consume("| A | B |\n")
        #expect(header == "")

        let rendered = formatter.consume("| --- | --- |\n| 1 | 2 |\n") + formatter.finish()
        // Once complete, the full table (with box drawing) is rendered intact.
        #expect(rendered.contains("┌"))
        #expect(rendered.contains("A"))
        #expect(rendered.contains("1"))
    }

    @Test
    func markdownFormatterStreamsCodeFenceWithoutParsingBody() {
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 80,
            supportsHyperlinks: false
        )

        let opened = formatter.consume("```swift\n")
        // The opening fence streams immediately.
        #expect(opened.contains("\u{1B}[90m```swift\u{1B}[0m"))

        let body = formatter.consume("- not a list\n**not bold**\n")
        // Inside the fence, markdown markers are preserved verbatim.
        #expect(body.contains("- not a list"))
        #expect(body.contains("**not bold**"))
        #expect(!body.contains("•"))

        let closed = formatter.consume("```\n") + formatter.finish()
        #expect(closed.contains("\u{1B}[90m```\u{1B}[0m"))
    }

    @Test
    func markdownFormatterStreamsProseUnchanged() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)

        let first = formatter.consume("Plain prose line.\n")
        let blank = formatter.consume("\n")

        #expect(first == "Plain prose line.\n")
        #expect(blank == "\n")
        #expect(formatter.finish() == "")
    }

    @Test
    func dimmedANSISequenceMapsHeadingAccentToMutedSteel() {
        let dimmed = TerminalChat.dimmedANSISequence(
            "\u{1B}[1;38;5;75m",
            gray: "\u{1B}[90m",
            reset: "\u{1B}[0m"
        )

        // Bold is preserved and the bright heading accent is remapped to the
        // muted steel-teal (109) used inside the dimmed thinking stream.
        #expect(dimmed == "\u{1B}[1;38;5;109m")
    }

    @Test
    func dimmedANSISequenceMapsInlineCodeAccentToMutedTan() {
        let dimmed = TerminalChat.dimmedANSISequence(
            "\u{1B}[38;5;180m",
            gray: "\u{1B}[90m",
            reset: "\u{1B}[0m"
        )

        #expect(dimmed == "\u{1B}[38;5;144m")
    }

    @Test
    func dimmedANSISequenceCollapsesResetToGray() {
        let dimmed = TerminalChat.dimmedANSISequence(
            "\u{1B}[0m",
            gray: "\u{1B}[90m",
            reset: "\u{1B}[0m"
        )

        #expect(dimmed == "\u{1B}[0m\u{1B}[90m")
    }

    @Test
    func dimmedANSISequenceFallsBackToGrayForUnmappedColor() {
        let dimmed = TerminalChat.dimmedANSISequence(
            "\u{1B}[38;5;200m",
            gray: "\u{1B}[90m",
            reset: "\u{1B}[0m"
        )

        // An accent without a muted mapping degrades to plain gray (90).
        #expect(dimmed == "\u{1B}[90m")
    }

    @Test
    func mutedThoughtAccentMapsKnownAccentFamilies() {
        #expect(TerminalChat.mutedThoughtAccent(for: 75) == 109)
        #expect(TerminalChat.mutedThoughtAccent(for: 180) == 144)
        #expect(TerminalChat.mutedThoughtAccent(for: 108) == 108)
        #expect(TerminalChat.mutedThoughtAccent(for: 200) == nil)
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

        #expect(visibleLines[1] == "👥 Sub-Agents:")
        #expect(rendered.hasPrefix("\n"))
        #expect(rendered.hasSuffix("\n"))
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
        #expect(rendered.contains("▸ current:"))
        #expect(rendered.contains("tool: search.grep"))
        #expect(rendered.contains("activity: reading project files"))
    }

    @Test
    func subAgentOverviewRendersActivityWithoutCurrentTool() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_3",
            name: "planner",
            role: "Planner",
            status: .running,
            pending: true,
            currentActivity: "reading project files",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalChat.renderSubAgentOverview([snapshot]))

        #expect(rendered.contains("▸ current:"))
        #expect(rendered.contains("activity: reading project files"))
        #expect(!rendered.contains("tool:"))
    }

    @Test
    func subAgentOverviewRendersCurrentActivityAcrossMultipleWrappedLines() {
        let longActivity = String(
            repeating: "analysing renderer state while checking delegated agent progress ",
            count: 5
        ) + "ENDCURRENT"
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_current",
            name: "worker",
            role: "worker",
            status: .running,
            pending: true,
            currentActivity: longActivity,
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalChat.renderSubAgentOverview([snapshot]))
        let visibleLines = rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }

        #expect(rendered.contains("▸ current:"))
        #expect(rendered.contains("activity:"))
        #expect(rendered.contains("ENDCURRENT"))

        let currentIndex = visibleLines.firstIndex { $0.contains("▸ current:") }
        let idIndex = visibleLines.firstIndex { $0.contains("id: agent_current") }
        #expect(currentIndex != nil)
        #expect(idIndex != nil)
        if let currentIndex, let idIndex {
            #expect(idIndex - currentIndex > 2)
        }
    }

    @Test
    func subAgentOverviewRendersCurrentContentPreviewWhenAvailable() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_preview",
            name: "writer",
            role: "writer",
            status: .running,
            pending: true,
            currentActivity: "thinking through the answer",
            latestContentPreview: "Drafting the final summary for the delegated investigation",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalChat.renderSubAgentOverview([snapshot]))

        #expect(rendered.contains("▸ current:"))
        #expect(rendered.contains("activity: thinking through the answer"))
        #expect(rendered.contains("preview: Drafting the final summary"))
    }

    @Test
    func inlineTextCollapsesNewlinesAndCarriageReturns() {
        #expect(TerminalChat.inlineText("a\nb\r\nc\rd  ") == "a b c d")
        #expect(TerminalChat.inlineText("  hello world  ") == "hello world")
        #expect(TerminalChat.inlineText("line1\r\nline2") == "line1 line2")
    }

    @Test
    func subAgentOverviewDoesNotTruncateLongOutputWithEllipsisDots() {
        let longOutput = String(repeating: "word ", count: 40) + "ENDMARKER"
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_long",
            name: "worker",
            role: "worker",
            status: .idle,
            pending: false,
            latestOutput: longOutput,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalChat.renderSubAgentOverview([snapshot]))

        #expect(rendered.contains("ENDMARKER"))
        #expect(!rendered.contains("..."))
    }

    @Test
    func subAgentOverviewCapsWrappedDetailToThreeLines() {
        let hugeOutput = String(repeating: "alpha bravo charlie delta ", count: 60)
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_flood",
            name: "worker",
            role: "worker",
            status: .idle,
            pending: false,
            latestOutput: hugeOutput,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = ansiStripped(TerminalChat.renderSubAgentOverview([snapshot]))
        let visibleLines = rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }

        #expect(rendered.contains("…"))
        #expect(visibleLines.count <= 12)
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

    private func makeTerminalForToolInterleavingTest(
        sessionRunner: AgentCoreSessionRunner? = nil
    ) throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-tool-rendering", isDirectory: true)
        )
        return TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: sessionRunner
        )
    }
}
