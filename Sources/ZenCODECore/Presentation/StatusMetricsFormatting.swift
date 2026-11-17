//
//  StatusMetricsFormatting.swift
//  ZenCODE
//
//  The text of the status metrics the terminal status bar and the macOS app
//  show: token counts, the context window, speeds, subscription usage, and
//  durations. Styling stays with each channel.
//

import Foundation

/// The channel-neutral text of the status metrics.
public enum StatusMetricsFormatting {
    /// `"used/max"`: the used tokens (`usedTokens`, else `metricUsedTokens`)
    /// and the context window, with `"0.0k"` without a used count and `"--"`
    /// without a positive maximum.
    public static func tokenWindowText(
        usedTokens: Int?,
        metricUsedTokens: Int?,
        maxTokens: Int?
    ) -> String {
        let resolvedUsedTokens = usedTokens ?? metricUsedTokens
        let usedText = resolvedUsedTokens.map(contextTokenCountText) ?? "0.0k"
        guard let maxTokens, maxTokens > 0 else {
            return "\(usedText)/--"
        }
        return "\(usedText)/\(contextTokenCountText(maxTokens))"
    }

    /// A context-window size or the tokens used in it: `%.1fm` from a
    /// million, `%.1fk` from a thousand, else the plain count.
    public static func contextTokenCountText(_ value: Int) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000)
        }
        if absoluteValue >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    /// A token counter: `%.1fm` from a million, whole `k` from ten thousand,
    /// `%.1fk` from a thousand, else the plain count.
    public static func tokenCountText(_ value: Int) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000)
        }
        if absoluteValue >= 10_000 {
            return "\(value / 1_000)k"
        }
        if absoluteValue >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    /// One decimal (`%.1f`) for every speed, prefill and generation alike;
    /// `nil` for a value that is not a finite, non-negative speed.
    public static func throughputRateText(_ value: Double) -> String? {
        guard value.isFinite, value >= 0 else {
            return nil
        }
        return String(format: "%.1f", value)
    }

    /// A usage percentage clamped to 0...100: whole from 10% (and at 0%), one
    /// decimal below; `"--"` when not finite.
    public static func usagePercentText(_ value: Double) -> String {
        guard value.isFinite else {
            return "--"
        }
        let clamped = min(max(value, 0), 100)
        if clamped >= 10 || clamped == 0 {
            return "\(Int(clamped.rounded()))%"
        }
        return String(format: "%.1f%%", clamped)
    }

    /// `h:mm:ss`; `"--"` for a negative or non-finite value.
    public static func durationText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else {
            return "--"
        }
        let style = Duration.TimeFormatStyle(pattern: .hourMinuteSecond)
        return Duration
            .seconds(value)
            .formatted(style)
    }
}
