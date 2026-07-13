//
//  TerminalChat+MetricsRendering.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    public func writeMetricsStatus(_ metrics: DirectAgentGenerationMetrics) async {
        _ = await statusBar.update(metrics: metrics)
        guard Self.shouldPrintMetricsForAutomation(),
              metrics.completionTokensPerSecond != nil else {
            return
        }
        await writeChatError(
            "\n[ZenCODE] \(Self.metricsSummary(metrics))\n"
        )
    }

    public func writeContextWindowStatus(_ status: DirectAgentContextWindowStatus) async {
        _ = await statusBar.update(contextWindow: status)
    }

    public func writeSubscriptionUsageStatus(_ status: DirectAgentSubscriptionUsageStatus) async {
        _ = await statusBar.update(subscriptionUsage: status)
    }

    public func compactGenerationSummary(_ message: String) -> String {
        if let range = message.range(of: "\n  Cache:") {
            return String(message[..<range.lowerBound])
        }
        if let range = message.range(of: "\nCache:") {
            return String(message[..<range.lowerBound])
        }
        if let range = message.range(of: "; cache ") {
            return String(message[..<range.lowerBound])
        }
        return message
    }

    public static func shouldPrintMetricsForAutomation() -> Bool {
        ProcessInfo.processInfo.environment["ZENCODE_PRINT_METRICS"] == "1"
    }

    public static func metricsSummary(_ metrics: DirectAgentGenerationMetrics) -> String {
        let total = metrics.totalTokenCount.map(String.init) ?? "--"
        let prefill = metrics.promptTokenCount.map(String.init) ?? "--"
        let cache = metrics.cachedPromptTokenCount.map(String.init) ?? "--"
        let output = metrics.completionTokenCount.map(String.init) ?? "--"
        let promptRate = metrics.promptTokensPerSecond.map {
            String(format: "%.1f", $0)
        } ?? "--"
        let generationRate = metrics.completionTokensPerSecond.map {
            String(format: "%.1f", $0)
        } ?? "--"
        let duration = metrics.responseDurationSeconds.map(Self.durationText) ?? "--"
        return "tokens \(total) | pre \(prefill) | cache \(cache) | prompt \(promptRate)/s | out \(output) | gen \(generationRate)/s | time \(duration)"
    }

    public static func durationText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else {
            return "--"
        }
        if value < 60 {
            return String(format: "%.1fs", value)
        }
        let roundedSeconds = Int(value.rounded())
        let minutes = roundedSeconds / 60
        let seconds = roundedSeconds % 60
        if minutes < 60 {
            return String(format: "%d:%02d", minutes, seconds)
        }
        let hours = minutes / 60
        return String(format: "%d:%02d:%02d", hours, minutes % 60, seconds)
    }
}
