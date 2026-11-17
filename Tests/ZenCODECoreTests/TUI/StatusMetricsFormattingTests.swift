//
//  StatusMetricsFormattingTests.swift
//  ZenCODE
//
//  The text of the status metrics shared by the terminal status bar and the
//  macOS app.
//

import Testing
import ZenCODECore

@Suite("StatusMetricsFormatting")
struct StatusMetricsFormattingTests {
    @Test("token counters and context sizes follow their k/m rules")
    func tokenCountRules() {
        #expect(StatusMetricsFormatting.tokenCountText(0) == "0")
        #expect(StatusMetricsFormatting.tokenCountText(999) == "999")
        #expect(StatusMetricsFormatting.tokenCountText(1_000) == "1.0k")
        #expect(StatusMetricsFormatting.tokenCountText(2_000) == "2.0k")
        #expect(StatusMetricsFormatting.tokenCountText(4_100) == "4.1k")
        #expect(StatusMetricsFormatting.tokenCountText(9_999) == "10.0k")
        #expect(StatusMetricsFormatting.tokenCountText(10_000) == "10k")
        #expect(StatusMetricsFormatting.tokenCountText(15_500) == "15k")
        #expect(StatusMetricsFormatting.tokenCountText(25_000) == "25k")
        #expect(StatusMetricsFormatting.tokenCountText(1_000_000) == "1.0m")
        #expect(StatusMetricsFormatting.tokenCountText(-1_500) == "-1.5k")

        #expect(StatusMetricsFormatting.contextTokenCountText(952) == "952")
        #expect(StatusMetricsFormatting.contextTokenCountText(35_000) == "35.0k")
        #expect(StatusMetricsFormatting.contextTokenCountText(1_500_000) == "1.5m")
        #expect(StatusMetricsFormatting.contextTokenCountText(10_000) == "10.0k")
        #expect(StatusMetricsFormatting.contextTokenCountText(128_000) == "128.0k")
        #expect(StatusMetricsFormatting.contextTokenCountText(1_000_000) == "1.0m")
        #expect(StatusMetricsFormatting.contextTokenCountText(512) == "512")
    }

    @Test("the context window shows used/max with its fallbacks")
    func tokenWindow() {
        #expect(StatusMetricsFormatting.tokenWindowText(usedTokens: nil, metricUsedTokens: nil, maxTokens: nil) == "0.0k/--")
        #expect(StatusMetricsFormatting.tokenWindowText(usedTokens: 952, metricUsedTokens: nil, maxTokens: 10_000) == "952/10.0k")
        #expect(StatusMetricsFormatting.tokenWindowText(usedTokens: nil, metricUsedTokens: 35_000, maxTokens: nil) == "35.0k/--")
        #expect(StatusMetricsFormatting.tokenWindowText(usedTokens: nil, metricUsedTokens: 35_000, maxTokens: 0) == "35.0k/--")
        #expect(StatusMetricsFormatting.tokenWindowText(usedTokens: 1_200, metricUsedTokens: 99, maxTokens: 128_000) == "1.2k/128.0k")
    }

    @Test("usage percentages: whole from 10%, one decimal below, clamped")
    func usagePercent() {
        #expect(StatusMetricsFormatting.usagePercentText(0) == "0%")
        #expect(StatusMetricsFormatting.usagePercentText(4.5) == "4.5%")
        #expect(StatusMetricsFormatting.usagePercentText(9.96) == "10.0%")
        #expect(StatusMetricsFormatting.usagePercentText(10) == "10%")
        #expect(StatusMetricsFormatting.usagePercentText(12.4) == "12%")
        #expect(StatusMetricsFormatting.usagePercentText(12.5) == "13%")
        #expect(StatusMetricsFormatting.usagePercentText(150) == "100%")
        #expect(StatusMetricsFormatting.usagePercentText(-3) == "0%")
        #expect(StatusMetricsFormatting.usagePercentText(.nan) == "--")
    }

    @Test("durations are h:mm:ss, invalid values --")
    func durations() {
        #expect(StatusMetricsFormatting.durationText(0) == "0:00:00")
        #expect(StatusMetricsFormatting.durationText(12) == "0:00:12")
        #expect(StatusMetricsFormatting.durationText(3_725) == "1:02:05")
        #expect(StatusMetricsFormatting.durationText(-1) == "--")
        #expect(StatusMetricsFormatting.durationText(.infinity) == "--")
        #expect(StatusMetricsFormatting.durationText(.nan) == "--")
    }
}
