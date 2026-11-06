//
//  ZenStatusFormattingTests.swift
//  ZenApp
//
//  Parity of the status-bar formatting with `TerminalStatusBar` (the same
//  inputs and outputs as the terminal UI's tests).
//

import Foundation
import Testing
import ZenCODECore

@testable import ZenAppControls

@Suite("ZenStatusFormatting")
struct ZenStatusFormattingTests {
    // MARK: - Model

    @Test("the model fragment includes the thinking selection")
    func modelFragmentIncludesThinkingSelection() {
        #expect(
            ZenStatusFormatting.modelText(
                modelID: "remote-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
                thinking: .high
            ) == "Qwen3-Coder-30B-A3B-Instruct-4bit · High"
        )
        #expect(
            ZenStatusFormatting.modelText(
                modelID: "remote-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
                thinking: nil
            ) == "Qwen3-Coder-30B-A3B-Instruct-4bit"
        )
        #expect(ZenStatusFormatting.modelDisplayName("gpt-5") == "gpt-5")
        #expect(ZenStatusFormatting.modelDisplayName("a/b/c") == "c")
        #expect(ZenStatusFormatting.modelDisplayName("") == "")
    }

    // MARK: - Counters

    @Test("token counters follow the k/m rules of the terminal")
    func tokenCountRules() {
        #expect(ZenStatusFormatting.tokenCountText(0) == "0")
        #expect(ZenStatusFormatting.tokenCountText(999) == "999")
        #expect(ZenStatusFormatting.tokenCountText(1_000) == "1.0k")
        #expect(ZenStatusFormatting.tokenCountText(2_000) == "2.0k")
        #expect(ZenStatusFormatting.tokenCountText(4_100) == "4.1k")
        #expect(ZenStatusFormatting.tokenCountText(9_999) == "10.0k")
        #expect(ZenStatusFormatting.tokenCountText(10_000) == "10k")
        #expect(ZenStatusFormatting.tokenCountText(15_500) == "15k")
        #expect(ZenStatusFormatting.tokenCountText(25_000) == "25k")
        #expect(ZenStatusFormatting.tokenCountText(1_000_000) == "1.0m")
        #expect(ZenStatusFormatting.tokenCountText(-1_500) == "-1.5k")

        #expect(ZenStatusFormatting.contextTokenCountText(952) == "952")
        #expect(ZenStatusFormatting.contextTokenCountText(35_000) == "35.0k")
        #expect(ZenStatusFormatting.contextTokenCountText(1_500_000) == "1.5m")
        #expect(ZenStatusFormatting.contextWindowLimitText(10_000) == "10.0k")
        #expect(ZenStatusFormatting.contextWindowLimitText(128_000) == "128.0k")
        #expect(ZenStatusFormatting.contextWindowLimitText(1_000_000) == "1.0m")
        #expect(ZenStatusFormatting.contextWindowLimitText(512) == "512")
    }

    @Test("the context window shows used/max with the terminal fallbacks")
    func tokenWindowText() {
        #expect(ZenStatusFormatting.tokenWindowText(usedTokens: nil, metricUsedTokens: nil, maxTokens: nil) == "0.0k/--")
        #expect(ZenStatusFormatting.tokenWindowText(usedTokens: 952, metricUsedTokens: nil, maxTokens: 10_000) == "952/10.0k")
        #expect(ZenStatusFormatting.tokenWindowText(usedTokens: nil, metricUsedTokens: 35_000, maxTokens: nil) == "35.0k/--")
        #expect(ZenStatusFormatting.tokenWindowText(usedTokens: nil, metricUsedTokens: 35_000, maxTokens: 0) == "35.0k/--")
        #expect(ZenStatusFormatting.tokenWindowText(usedTokens: 1_200, metricUsedTokens: 99, maxTokens: 128_000) == "1.2k/128.0k")
    }

    @Test("generation token counts are compact and optional")
    func generationTokenCounts() {
        #expect(
            ZenStatusFormatting.generationTokenCountsText(
                DirectAgentGenerationMetrics(promptTokenCount: 120, cachedPromptTokenCount: 800, completionTokenCount: 32)
            ) == "c:800 p:120 g:32"
        )
        #expect(
            ZenStatusFormatting.generationTokenCountsText(
                DirectAgentGenerationMetrics(promptTokenCount: 15_000, completionTokenCount: 20_000)
            ) == "p:15k g:20k"
        )
        #expect(
            ZenStatusFormatting.generationTokenCountsText(
                DirectAgentGenerationMetrics(promptTokenCount: nil, completionTokenCount: nil)
            ) == nil
        )
        #expect(
            ZenStatusFormatting.generationTokenCountsText(
                DirectAgentGenerationMetrics(promptTokenCount: 15_000, cachedPromptTokenCount: 0, completionTokenCount: 2_000)
            ) == "c:0 p:15k g:2.0k"
        )
        #expect(
            ZenStatusFormatting.generationTokenCountsText(
                DirectAgentGenerationMetrics(promptTokenCount: 200, cachedPromptTokenCount: 4_100, completionTokenCount: 25)
            ) == "c:4.1k p:200 g:25"
        )
    }

    @Test("token-count labels are muted, values plain")
    func generationTokenCountsStyles() throws {
        let runs = try #require(
            ZenStatusFormatting.generationTokenCountsRuns(
                DirectAgentGenerationMetrics(promptTokenCount: 120, completionTokenCount: 32)
            )
        )
        #expect(runs == [
            ZenStatusRun("p:", style: .label),
            ZenStatusRun("120"),
            ZenStatusRun(" "),
            ZenStatusRun("g:", style: .label),
            ZenStatusRun("32")
        ])
    }

    // MARK: - Throughput

    @Test("the throughput shows the prefill progress with and without a rate")
    func throughputPrefillProgress() {
        func metrics(processed: Int, target: Int, rate: Double?) -> DirectAgentGenerationMetrics {
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

        #expect(ZenStatusFormatting.throughputText(metrics(processed: 1_200, target: 8_000, rate: 512)) == "p:1.2k/8.0k 512.0 tok/s")
        #expect(ZenStatusFormatting.throughputText(metrics(processed: 0, target: 8_000, rate: nil)) == "p:0/8.0k")
        #expect(ZenStatusFormatting.throughputText(metrics(processed: 800, target: 25_000, rate: 64.26)) == "p:800/25k 64.3 tok/s")
        #expect(ZenStatusFormatting.throughputText(metrics(processed: 10, target: 100, rate: .infinity)) == "p:10/100")
        #expect(ZenStatusFormatting.throughputText(metrics(processed: 10, target: 100, rate: -3)) == "p:10/100")
    }

    @Test("live prefill progress ignores the generation rate")
    func liveProgressIgnoresGenerationRate() {
        let metrics = DirectAgentGenerationMetrics(
            promptTokenCount: nil,
            completionTokenCount: nil,
            throughput: DirectAgentGenerationThroughput(
                phase: .prefill,
                prefillTokensPerSecond: 512,
                generationTokensPerSecond: 42.1,
                processedTokens: 1_200,
                targetTokens: 8_000
            )
        )
        #expect(ZenStatusFormatting.throughputText(metrics) == "p:1.2k/8.0k 512.0 tok/s")
    }

    @Test("the throughput shows both speeds in one label")
    func throughputBothSpeeds() {
        func fragment(prefill: Double?, generation: Double?) -> String? {
            ZenStatusFormatting.throughputText(
                DirectAgentGenerationMetrics(
                    promptTokenCount: nil,
                    completionTokenCount: nil,
                    throughput: DirectAgentGenerationThroughput(
                        phase: .generation,
                        prefillTokensPerSecond: prefill,
                        generationTokensPerSecond: generation
                    )
                )
            )
        }

        #expect(fragment(prefill: 512, generation: 42.1) == "p:512.0 g:42.1 tok/s")
        #expect(fragment(prefill: 612.34, generation: 43.2) == "p:612.3 g:43.2 tok/s")
        #expect(fragment(prefill: 1_234.6, generation: 41.23) == "p:1234.6 g:41.2 tok/s")
        #expect(fragment(prefill: 512, generation: nil) == "p:512.0 tok/s")
        #expect(fragment(prefill: nil, generation: 42.1) == "g:42.1 tok/s")
        #expect(fragment(prefill: .nan, generation: 42.1) == "g:42.1 tok/s")
        #expect(fragment(prefill: 512, generation: -1) == "p:512.0 tok/s")
        #expect(fragment(prefill: nil, generation: nil) == nil)
        #expect(fragment(prefill: .infinity, generation: .nan) == nil)
    }

    @Test("the generation rate has one decimal")
    func throughputGenerationRate() {
        func fragment(_ rate: Double?) -> String? {
            ZenStatusFormatting.throughputText(
                DirectAgentGenerationMetrics(
                    promptTokenCount: nil,
                    completionTokenCount: nil,
                    throughput: DirectAgentGenerationThroughput(phase: .generation, generationTokensPerSecond: rate)
                )
            )
        }

        #expect(fragment(41.23) == "g:41.2 tok/s")
        #expect(fragment(0) == "g:0.0 tok/s")
        #expect(fragment(99.94) == "g:99.9 tok/s")
        #expect(fragment(100) == "g:100.0 tok/s")
        #expect(fragment(100.44) == "g:100.4 tok/s")
        #expect(fragment(1_234.6) == "g:1234.6 tok/s")
        #expect(fragment(nil) == nil)
        #expect(fragment(-1) == nil)
        #expect(fragment(.nan) == nil)
        #expect(fragment(.infinity) == nil)
    }

    @Test("no throughput without a throughput")
    func throughputAbsent() {
        let metrics = DirectAgentGenerationMetrics(promptTokenCount: 120, cachedPromptTokenCount: 800, completionTokenCount: 32)
        #expect(ZenStatusFormatting.throughputText(metrics) == nil)
    }

    @Test("throughput labels are muted, values and unit plain")
    func throughputStyles() throws {
        let prefill = DirectAgentGenerationMetrics(
            promptTokenCount: nil,
            completionTokenCount: nil,
            throughput: DirectAgentGenerationThroughput(phase: .prefill, processedTokens: 0, targetTokens: 8_000)
        )
        #expect(ZenStatusFormatting.throughputRuns(prefill) == [
            ZenStatusRun("p:", style: .label),
            ZenStatusRun("0/8.0k")
        ])

        let both = DirectAgentGenerationMetrics(
            promptTokenCount: nil,
            completionTokenCount: nil,
            throughput: DirectAgentGenerationThroughput(
                phase: .generation,
                prefillTokensPerSecond: 512,
                generationTokensPerSecond: 42.1
            )
        )
        #expect(ZenStatusFormatting.throughputRuns(both) == [
            ZenStatusRun("p:", style: .label),
            ZenStatusRun("512.0"),
            ZenStatusRun(" "),
            ZenStatusRun("g:", style: .label),
            ZenStatusRun("42.1"),
            ZenStatusRun(" tok/s")
        ])
    }

    // MARK: - Usage, durations, git

    @Test("subscription usage omits the unavailable window")
    func subscriptionUsage() {
        let weeklyOnly = DirectAgentSubscriptionUsageStatus(provider: "ChatGPT", dailyUsedPercent: nil, weeklyUsedPercent: 42)
        let dailyOnly = DirectAgentSubscriptionUsageStatus(provider: "ChatGPT", dailyUsedPercent: 10, weeklyUsedPercent: nil)
        let both = DirectAgentSubscriptionUsageStatus(provider: "ChatGPT", dailyUsedPercent: 10, weeklyUsedPercent: 42)
        let none = DirectAgentSubscriptionUsageStatus(provider: "ChatGPT", dailyUsedPercent: nil, weeklyUsedPercent: nil)

        #expect(ZenStatusFormatting.subscriptionUsageText(weeklyOnly) == "w:42%")
        #expect(ZenStatusFormatting.subscriptionUsageText(dailyOnly) == "d:10%")
        #expect(ZenStatusFormatting.subscriptionUsageText(both) == "d:10% w:42%")
        #expect(ZenStatusFormatting.subscriptionUsageText(none) == nil)
        #expect(ZenStatusFormatting.subscriptionUsageRuns(both) == [
            ZenStatusRun("d:", style: .label),
            ZenStatusRun("10%"),
            ZenStatusRun(" "),
            ZenStatusRun("w:", style: .label),
            ZenStatusRun("42%")
        ])
    }

    @Test("usage percentages: whole from 10%, one decimal below, clamped")
    func usagePercent() {
        #expect(ZenStatusFormatting.usagePercentText(0) == "0%")
        #expect(ZenStatusFormatting.usagePercentText(4.5) == "4.5%")
        #expect(ZenStatusFormatting.usagePercentText(9.96) == "10.0%")
        #expect(ZenStatusFormatting.usagePercentText(10) == "10%")
        #expect(ZenStatusFormatting.usagePercentText(12.4) == "12%")
        #expect(ZenStatusFormatting.usagePercentText(12.5) == "13%")
        #expect(ZenStatusFormatting.usagePercentText(150) == "100%")
        #expect(ZenStatusFormatting.usagePercentText(-3) == "0%")
        #expect(ZenStatusFormatting.usagePercentText(.nan) == "--")
    }

    @Test("durations are h:mm:ss, invalid values --")
    func durations() {
        #expect(ZenStatusFormatting.durationText(0) == "0:00:00")
        #expect(ZenStatusFormatting.durationText(12) == "0:00:12")
        #expect(ZenStatusFormatting.durationText(3_725) == "1:02:05")
        #expect(ZenStatusFormatting.durationText(-1) == "--")
        #expect(ZenStatusFormatting.durationText(.infinity) == "--")
        #expect(ZenStatusFormatting.durationText(.nan) == "--")

        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(ZenStatusFormatting.elapsedSeconds(since: start, now: start.addingTimeInterval(42.9)) == 42)
        #expect(ZenStatusFormatting.elapsedSeconds(since: start, now: start) == 0)
    }

    @Test("the git fragment shows the diff summary with its colors")
    func gitStatus() {
        let summary = TerminalGitStatusSummary(changedFileCount: 3, additions: 12, deletions: 4)
        #expect(ZenStatusFormatting.gitStatusText(summary) == "3 files +12 -4")
        #expect(ZenStatusFormatting.gitStatusRuns(summary) == [
            ZenStatusRun("3", style: .fileCount),
            ZenStatusRun(" files "),
            ZenStatusRun("+12", style: .fileAddition),
            ZenStatusRun(" "),
            ZenStatusRun("-4", style: .fileDeletion)
        ])
    }

    // MARK: - Status line

    @Test("the status line places the token counts after the time")
    func statusLineTokenCountsAfterTime() {
        let state = ZenStatusBarState(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: 15_000,
                completionTokenCount: 20_000,
                responseDurationSeconds: 12
            )
        )
        #expect(ZenStatusFormatting.statusText(for: state).contains("35.0k/-- · 0:00:12 · p:15k g:20k"))
    }

    @Test("the status line places the throughput right after the token counts")
    func statusLineThroughputAfterTokenCounts() {
        let state = ZenStatusBarState(
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: 120,
                cachedPromptTokenCount: 800,
                completionTokenCount: 32,
                responseDurationSeconds: 12,
                throughput: DirectAgentGenerationThroughput(
                    phase: .generation,
                    prefillTokensPerSecond: 512,
                    generationTokensPerSecond: 41.2
                )
            ),
            subscriptionUsage: DirectAgentSubscriptionUsageStatus(provider: "test", dailyUsedPercent: 12, weeklyUsedPercent: nil)
        )
        #expect(
            ZenStatusFormatting.statusText(for: state)
                .contains("0:00:12 · c:800 p:120 g:32 · p:512.0 g:41.2 tok/s · d:12%")
        )
    }

    @Test("every fragment in the terminal order")
    func fullStatusLineOrder() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let state = ZenStatusBarState(
            isGenerating: true,
            turnStartedAt: start,
            modelID: "mlx/Qwen3-Coder",
            thinking: .medium,
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: 120,
                completionTokenCount: 32,
                responseDurationSeconds: 99,
                throughput: DirectAgentGenerationThroughput(phase: .generation, generationTokensPerSecond: 30)
            ),
            contextWindow: DirectAgentContextWindowStatus(
                usedTokens: 32_000,
                maxTokens: 128_000,
                modelID: "Qwen3-Coder",
                isApproximate: false
            ),
            subscriptionUsage: DirectAgentSubscriptionUsageStatus(provider: "p", dailyUsedPercent: 5, weeklyUsedPercent: 50),
            gitStatus: TerminalGitStatusSummary(changedFileCount: 2, additions: 7, deletions: 1)
        )
        let now = start.addingTimeInterval(65.4)
        let fragments = ZenStatusFormatting.fragments(for: state, now: now)

        #expect(fragments.map(\.kind) == [
            .activity, .model, .contextWindow, .duration, .tokenCounts, .throughput, .subscriptionUsage, .gitStatus
        ])
        // The live elapsed time wins over the last response duration.
        #expect(
            ZenStatusFormatting.statusText(for: state, now: now)
                == "Qwen3-Coder · Medium · 32.0k/128.0k · 0:01:05 · p:120 g:32 · g:30.0 tok/s · d:5.0% w:50% · 2 files +7 -1"
        )
        #expect(fragments.first { $0.kind == .contextWindow }?.gaugeFraction == 0.25)
    }

    @Test("the spinner needs a model, like the terminal loader")
    func spinnerNeedsModel() {
        var state = ZenStatusBarState(isGenerating: true, turnStartedAt: Date())
        #expect(!ZenStatusFormatting.fragments(for: state).contains { $0.kind == .activity })
        state.modelID = "gpt-5"
        #expect(ZenStatusFormatting.fragments(for: state).first?.kind == .activity)
        state.isGenerating = false
        #expect(!ZenStatusFormatting.fragments(for: state).contains { $0.kind == .activity })
    }

    @Test("full access shows a red dot first, before the spinner and the model")
    func fullAccessDotComesFirst() throws {
        var state = ZenStatusBarState(
            isGenerating: true,
            turnStartedAt: Date(),
            modelID: "mlx/Qwen3-Coder",
            gitStatus: TerminalGitStatusSummary(changedFileCount: 1, additions: 2, deletions: 0),
            localExecAccessMode: .fullAccess
        )
        let fragments = ZenStatusFormatting.fragments(for: state)
        #expect(fragments.map(\.kind) == [.accessMode, .activity, .model, .duration, .gitStatus])
        let dot = try #require(fragments.first)
        #expect(dot.runs == [ZenStatusRun("●", style: .fullAccess)])
        #expect(ZenStatusFormatting.fullAccessAccessibilityLabel == "Full access")
        // The terminal's text without its escapes: the dot, then the rest.
        state.isGenerating = false
        #expect(ZenStatusFormatting.statusText(for: state) == "● · Qwen3-Coder · 1 files +2 -0")
        // Alone, with nothing else to show.
        #expect(
            ZenStatusFormatting.fragments(for: ZenStatusBarState(localExecAccessMode: .fullAccess)).map(\.kind)
                == [.accessMode]
        )
    }

    @Test("the default mode shows no access-mode fragment")
    func defaultModeHasNoDot() {
        let state = ZenStatusBarState(modelID: "gpt-5", localExecAccessMode: .standard)
        #expect(ZenStatusFormatting.fragments(for: state).map(\.kind) == [.model])
        #expect(ZenStatusFormatting.statusText(for: state) == "gpt-5")
        #expect(ZenStatusBarState().localExecAccessMode == .standard)
    }

    @Test("voice mode off shows no voice fragment")
    func voiceOffHasNoFragment() {
        let state = ZenStatusBarState(modelID: "gpt-5", voice: .off)
        #expect(ZenStatusFormatting.fragments(for: state).map(\.kind) == [.model])
        #expect(ZenStatusBarState().voice == .off)
        #expect(ZenVoiceIndicator(.off) == nil)
        // Off wins over stale paused or speaking flags.
        #expect(ZenVoiceIndicator(VoiceModeSessionState(isOn: false, isPaused: true, isSpeaking: true)) == nil)
    }

    @Test("the voice indicator: listening, paused, reading aloud, which wins")
    func voiceIndicatorStates() {
        let listening = ZenVoiceIndicator(VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: false))
        #expect(listening == .listening)
        #expect(listening?.symbolName == "mic.fill")
        #expect(listening?.label == "Voice mode: listening")
        #expect(listening?.style == .voiceActive)

        let paused = ZenVoiceIndicator(VoiceModeSessionState(isOn: true, isPaused: true, isSpeaking: false))
        #expect(paused == .paused)
        #expect(paused?.symbolName == "mic.slash")
        #expect(paused?.label == "Voice mode: paused")
        #expect(paused?.style == .voicePaused)

        let reading = ZenVoiceIndicator(VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: true))
        #expect(reading == .readingAloud)
        #expect(reading?.symbolName == "waveform")
        #expect(reading?.label == "Voice mode: reading aloud")
        #expect(reading?.style == .voiceActive)

        // Reading aloud has precedence over the pause.
        #expect(ZenVoiceIndicator(VoiceModeSessionState(isOn: true, isPaused: true, isSpeaking: true)) == .readingAloud)
    }

    @Test("the voice fragment follows the red dot, before the spinner and the model, and has no text")
    func voiceFragmentOrder() throws {
        let voice = VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: false)
        var state = ZenStatusBarState(
            isGenerating: true,
            turnStartedAt: Date(),
            modelID: "mlx/Qwen3-Coder",
            localExecAccessMode: .fullAccess,
            voice: voice
        )
        let fragments = ZenStatusFormatting.fragments(for: state)
        #expect(fragments.map(\.kind) == [.accessMode, .voice, .activity, .model, .duration])
        let fragment = try #require(fragments.first { $0.kind == .voice })
        #expect(fragment.runs.isEmpty)
        #expect(fragment.voiceIndicator == .listening)
        #expect(fragments.allSatisfy { $0.kind == .voice || $0.voiceIndicator == nil })
        // The plain line leaves the symbol out, like the spinner.
        state.isGenerating = false
        #expect(ZenStatusFormatting.statusText(for: state) == "● · Qwen3-Coder")
        // In the default mode it comes first; alone, with nothing else to show.
        state.localExecAccessMode = .standard
        #expect(ZenStatusFormatting.fragments(for: state).map(\.kind) == [.voice, .model])
        #expect(ZenStatusFormatting.fragments(for: ZenStatusBarState(voice: voice)).map(\.kind) == [.voice])
    }

    @Test("while generating without a start the last duration shows")
    func generatingWithoutStartShowsLastDuration() {
        let state = ZenStatusBarState(
            isGenerating: true,
            metrics: DirectAgentGenerationMetrics(promptTokenCount: nil, completionTokenCount: nil, responseDurationSeconds: 4)
        )
        #expect(ZenStatusFormatting.statusText(for: state) == "0:00:04")
    }

    @Test("an empty state has no fragment")
    func emptyState() {
        #expect(ZenStatusFormatting.fragments(for: ZenStatusBarState()).isEmpty)
    }

    @Test("the gauge fraction is clamped and needs a window size")
    func gaugeFraction() {
        #expect(ZenStatusFormatting.contextFraction(usedTokens: 50, maxTokens: 100) == 0.5)
        #expect(ZenStatusFormatting.contextFraction(usedTokens: 500, maxTokens: 100) == 1)
        #expect(ZenStatusFormatting.contextFraction(usedTokens: nil, maxTokens: 100) == 0)
        #expect(ZenStatusFormatting.contextFraction(usedTokens: 50, maxTokens: nil) == nil)
        #expect(ZenStatusFormatting.contextFraction(usedTokens: 50, maxTokens: 0) == nil)
    }

    @Test("a path under the home folder is abbreviated with ~")
    func abbreviatedPath() {
        #expect(ZenStatusFormatting.abbreviatedPath("/Users/me", homeDirectory: "/Users/me") == "~")
        #expect(ZenStatusFormatting.abbreviatedPath("/Users/me/x", homeDirectory: "/Users/me") == "~/x")
        #expect(ZenStatusFormatting.abbreviatedPath("/Users/meme", homeDirectory: "/Users/me") == "/Users/meme")
        #expect(ZenStatusFormatting.abbreviatedPath("/tmp", homeDirectory: "") == "/tmp")
    }
}
