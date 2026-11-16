//
//  TerminalChatRenderingTests+StatusBarAnalytics.swift
//  ZenCODE
//
//  Tests for the terminal status bar git refresh, analytics retention,
//  throughput label and git numstat summary.
//

import Foundation
import Markdown
import Testing
@testable import ZenCODECore

extension TerminalChatRenderingTests {
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
    func completedSubAgentFileMutationRequestsGitStatusRefresh() {
        let mutation = DirectAgentToolCall(
            id: "mutation",
            name: "local.editFile",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        let read = DirectAgentToolCall(
            id: "read",
            name: "local.readFile",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        let result = DirectAgentToolResult(output: "Updated", summary: "Updated")

        #expect(!TerminalChat.shouldRefreshGitStatus(for: DirectSubAgentToolEvent(
            agentID: "worker",
            agentName: "worker",
            toolCall: mutation,
            lifecycle: .started
        )))
        #expect(TerminalChat.shouldRefreshGitStatus(for: DirectSubAgentToolEvent(
            agentID: "worker",
            agentName: "worker",
            toolCall: mutation,
            lifecycle: .completed(result)
        )))
        #expect(!TerminalChat.shouldRefreshGitStatus(for: DirectSubAgentToolEvent(
            agentID: "worker",
            agentName: "worker",
            toolCall: read,
            lifecycle: .completed(result)
        )))
    }

    @Test
    func statusBarRendersSubscriptionPrefillAndGenerationTokenCounts() {
        let metrics = ChatGPTSubscriptionGenerationClient
            .chatGPTSubscriptionVisibleMetrics(
                DirectAgentGenerationMetrics(
                    promptTokenCount: 120,
                    cachedPromptTokenCount: 800,
                    completionTokenCount: 32,
                )
            )

        #expect(
            TerminalStatusBar.styledGenerationTokenCountsFragment(metrics)
                .map(TerminalANSIText.stripANSI) == "c:800 p:120 g:32"
        )
    }

    @Test
    func statusBarKeepsLatestAnalyticsAfterCompletionAndCancellation() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        let metrics = DirectAgentGenerationMetrics(
            promptTokenCount: 120,
            cachedPromptTokenCount: 800,
            completionTokenCount: 32,
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
                completionTokenCount: 32,
                responseDurationSeconds: 4
            )
        )

        await statusBar.beginRequest()

        #expect(await statusBar.state.latestMetrics?.promptTokenCount == 120)
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: nil,
                completionTokenCount: 5,
            )
        )

        let state = await statusBar.state
        #expect(state.latestMetrics?.promptTokenCount == nil)
        #expect(state.latestMetrics?.cachedPromptTokenCount == nil)
        #expect(state.latestMetrics?.completionTokenCount == 5)
        #expect(state.latestMetrics?.responseDurationSeconds == nil)
    }

    // MARK: - DS4 throughput label

    @Test
    func throughputFragmentShowsPrefillProgressWithAndWithoutRate() {
        func metrics(
            processed: Int,
            target: Int,
            rate: Double?
        ) -> DirectAgentGenerationMetrics {
            DirectAgentGenerationMetrics(
                promptTokenCount: nil,
                completionTokenCount: nil,
                throughput: DirectAgentGenerationThroughput(
                    phase: .prefill,
                    prefillTokensPerSecond: rate,
                    processedTokens: processed,
                    targetTokens: target
                )
            )
        }

        #expect(
            TerminalStatusBar.styledGenerationThroughputFragment(
                metrics(processed: 1_200, target: 8_000, rate: 512)
            ).map(TerminalANSIText.stripANSI) == "p:1.2k/8.0k 512.0 tok/s"
        )
        #expect(
            TerminalStatusBar.styledGenerationThroughputFragment(
                metrics(processed: 0, target: 8_000, rate: nil)
            ).map(TerminalANSIText.stripANSI) == "p:0/8.0k"
        )
        #expect(
            TerminalStatusBar.styledGenerationThroughputFragment(
                metrics(processed: 800, target: 25_000, rate: 64.26)
            ).map(TerminalANSIText.stripANSI) == "p:800/25k 64.3 tok/s"
        )
        // An unusable rate is dropped, the progress stays.
        #expect(
            TerminalStatusBar.styledGenerationThroughputFragment(
                metrics(processed: 10, target: 100, rate: .infinity)
            ).map(TerminalANSIText.stripANSI) == "p:10/100"
        )
        #expect(
            TerminalStatusBar.styledGenerationThroughputFragment(
                metrics(processed: 10, target: 100, rate: -3)
            ).map(TerminalANSIText.stripANSI) == "p:10/100"
        )
    }

    @Test
    func statusBarLiveThroughputKeepsPreviousCountersUntilTheFinalSnapshot() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        let previousThroughput = DirectAgentGenerationThroughput(phase: .generation, generationTokensPerSecond: 30)
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: 120,
                cachedPromptTokenCount: 800,
                completionTokenCount: 32,
                responseDurationSeconds: 4,
                contextTokenCount: 952,
                clearsPromptMetrics: true,
                replacesPreviousMetrics: true,
                throughput: previousThroughput
            )
        )

        await statusBar.beginRequest()
        let prefill = DirectAgentGenerationThroughput(
            phase: .prefill, processedTokens: 0, targetTokens: 8_000
        )
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: nil,
                completionTokenCount: nil,
                throughput: prefill,
                isLiveProgress: true
            )
        )

        // The live event neither wipes the previous counters nor uses up the
        // replacement reserved for the first metrics event of the request.
        var state = await statusBar.state
        #expect(state.shouldReplaceMetricsOnNextUpdate)
        #expect(state.latestMetrics?.promptTokenCount == 120)
        #expect(state.latestMetrics?.cachedPromptTokenCount == 800)
        #expect(state.latestMetrics?.completionTokenCount == 32)
        #expect(state.latestMetrics?.responseDurationSeconds == 4)
        #expect(state.latestMetrics?.throughput == prefill)

        let generation = DirectAgentGenerationThroughput(phase: .generation, generationTokensPerSecond: 41.2)
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: nil,
                completionTokenCount: nil,
                throughput: generation,
                isLiveProgress: true
            )
        )
        state = await statusBar.state
        #expect(state.shouldReplaceMetricsOnNextUpdate)
        #expect(state.latestMetrics?.promptTokenCount == 120)
        #expect(state.latestMetrics?.throughput == generation)

        // The round's final snapshot replaces the counters and the throughput.
        let finalThroughput = DirectAgentGenerationThroughput(
            phase: .generation, prefillTokensPerSecond: 512, generationTokensPerSecond: 39.9
        )
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: 5_000,
                cachedPromptTokenCount: 4_000,
                completionTokenCount: 77,
                responseDurationSeconds: 9,
                contextTokenCount: 9_077,
                clearsPromptMetrics: true,
                replacesPreviousMetrics: true,
                throughput: finalThroughput
            )
        )
        state = await statusBar.state
        #expect(!state.shouldReplaceMetricsOnNextUpdate)
        #expect(state.latestMetrics?.promptTokenCount == 5_000)
        #expect(state.latestMetrics?.cachedPromptTokenCount == 4_000)
        #expect(state.latestMetrics?.completionTokenCount == 77)
        #expect(state.latestMetrics?.responseDurationSeconds == 9)
        #expect(state.latestMetrics?.throughput == finalThroughput)
        #expect(state.latestMetrics?.isLiveProgress == false)
    }

    @Test
    func statusBarFinalSnapshotWithoutThroughputClearsTheLabel() async {
        let statusBar = TerminalStatusBar(isEnabled: false)
        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: nil,
                completionTokenCount: nil,
                throughput: DirectAgentGenerationThroughput(phase: .generation, generationTokensPerSecond: 41.2),
                isLiveProgress: true
            )
        )
        #expect(await statusBar.state.latestMetrics?.throughput != nil)

        _ = await statusBar.update(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: 10,
                completionTokenCount: 5,
                clearsPromptMetrics: true,
                replacesPreviousMetrics: true
            )
        )

        #expect(await statusBar.state.latestMetrics?.throughput == nil)
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
}
