//
//  ZenStatusFormatting.swift
//  ZenApp
//
//  The status-bar text of the app, formatted exactly like the terminal UI's
//  status bar (`TerminalStatusBar+Metrics.swift` and `statusTextLocked`).
//

import Foundation
import ZenCODECore

/// One styled run of a status-bar fragment.
///
/// The terminal status bar mutes the `c:` / `p:` / `g:` / `d:` / `w:` labels,
/// colors the git counters, and draws the full-access dot red; every other
/// run keeps the bar's neutral foreground. The view maps each ``Style`` to a
/// `ZenPalette` color.
public struct ZenStatusRun: Equatable, Sendable {
    /// The color role of a run.
    public enum Style: Equatable, Sendable {
        /// The bar's neutral foreground (`TerminalStyle.Text.secondary`).
        case plain
        /// A muted label (`TerminalStyle.Text.muted`).
        case label
        /// The changed-file count (`TerminalStyle.FileChange.count`).
        case fileCount
        /// The added-line count (`TerminalStyle.FileChange.addition`).
        case fileAddition
        /// The deleted-line count (`TerminalStyle.FileChange.deletion`).
        case fileDeletion
        /// The full-access dot (`TerminalStyle.Status.failure`).
        case fullAccess
    }

    public let text: String
    public let style: Style

    public init(_ text: String, style: Style = .plain) {
        self.text = text
        self.style = style
    }
}

/// One fragment of the status line, in the terminal UI's order.
public struct ZenStatusFragment: Equatable, Sendable, Identifiable {
    /// What the fragment shows; also its identity, since each kind appears at
    /// most once.
    public enum Kind: Hashable, Sendable {
        /// The red dot shown in full access
        /// (`TerminalStatusBar.accessModeStatusFragment`).
        case accessMode
        /// The activity spinner shown while a prompt is generating.
        case activity
        /// Model display name and thinking selection.
        case model
        /// Context window `used/max`.
        case contextWindow
        /// Live elapsed time, or the duration of the last response.
        case duration
        /// Cached / prompt / generated token counts.
        case tokenCounts
        /// Prefill and generation throughput.
        case throughput
        /// Subscription usage percentages.
        case subscriptionUsage
        /// Git working-tree summary.
        case gitStatus
    }

    public let kind: Kind
    /// The styled text; empty for ``Kind/activity``, which the view draws as a
    /// spinner.
    public let runs: [ZenStatusRun]
    /// Fill fraction (0...1) of the context-window gauge; `nil` when the
    /// window size is unknown or for other kinds.
    public let gaugeFraction: Double?

    public var id: Kind { kind }

    /// The fragment's text without styles.
    public var text: String {
        runs.map(\.text).joined()
    }

    public init(kind: Kind, runs: [ZenStatusRun], gaugeFraction: Double? = nil) {
        self.kind = kind
        self.runs = runs
        self.gaugeFraction = gaugeFraction
    }
}

/// The formatting rules of the terminal UI's status bar, shared by
/// ``ZenStatusBar``. Every function returns the same text as its
/// `TerminalStatusBar` counterpart for the same input.
public enum ZenStatusFormatting {
    /// The separator between fragments.
    public static let separator = " · "

    // MARK: - Access mode

    /// The dot of the full-access fragment.
    public static let fullAccessDot = "●"
    /// What VoiceOver reads for the full-access dot.
    public static let fullAccessAccessibilityLabel = "Full access"

    /// The red dot in full access, `nil` in the default mode
    /// (`TerminalStatusBar.accessModeStatusFragment`).
    static func accessModeRuns(_ mode: AgentLocalExecAccessMode) -> [ZenStatusRun]? {
        switch mode {
        case .standard:
            nil
        case .fullAccess:
            [ZenStatusRun(fullAccessDot, style: .fullAccess)]
        }
    }

    // MARK: - Model

    /// The last path component of a model ID
    /// (`TerminalStatusBar.modelDisplayName`).
    public static func modelDisplayName(_ modelID: String) -> String {
        modelID
            .split(separator: "/")
            .last
            .map(String.init) ?? modelID
    }

    /// `"<model> · <thinking>"`, or the model alone without a thinking
    /// selection (`TerminalStatusBar.modelStatusFragment`).
    public static func modelText(
        modelID: String,
        thinking: AgentThinkingSelection?
    ) -> String {
        let modelName = modelDisplayName(modelID)
        guard let thinking else {
            return modelName
        }
        return "\(modelName) · \(thinking.displayTitle)"
    }

    // MARK: - Git

    /// `"N files +A -D"` (`TerminalStatusBar.gitStatusFragment` without its
    /// escapes).
    public static func gitStatusText(_ summary: TerminalGitStatusSummary) -> String {
        gitStatusRuns(summary).map(\.text).joined()
    }

    static func gitStatusRuns(_ summary: TerminalGitStatusSummary) -> [ZenStatusRun] {
        [
            ZenStatusRun("\(summary.changedFileCount)", style: .fileCount),
            ZenStatusRun(" files "),
            ZenStatusRun("+\(summary.additions)", style: .fileAddition),
            ZenStatusRun(" "),
            ZenStatusRun("-\(summary.deletions)", style: .fileDeletion)
        ]
    }

    // MARK: - Token counts

    /// `"used/max"`; `"0.0k"` without a used count and `"--"` without a
    /// positive maximum (`TerminalStatusBar.tokenWindowText`).
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
        return "\(usedText)/\(contextWindowLimitText(maxTokens))"
    }

    /// The context-window size: `%.1fm`, `%.1fk`, or the plain count
    /// (`TerminalStatusBar.contextWindowLimitText`).
    public static func contextWindowLimitText(_ value: Int) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000)
        }
        if absoluteValue >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    /// The tokens used in the context window: `%.1fm`, `%.1fk`, or the plain
    /// count (`TerminalStatusBar.contextTokenCountText`).
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
    /// `%.1fk` from a thousand, else the plain count
    /// (`TerminalStatusBar.tokenCountText`).
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

    /// `"c:<cached> p:<prompt> g:<generated>"` with only the known counters;
    /// `nil` when none is known
    /// (`TerminalStatusBar.generationTokenCountsFragment`).
    public static func generationTokenCountsText(
        _ metrics: DirectAgentGenerationMetrics
    ) -> String? {
        generationTokenCountsRuns(metrics).map { $0.map(\.text).joined() }
    }

    static func generationTokenCountsRuns(
        _ metrics: DirectAgentGenerationMetrics
    ) -> [ZenStatusRun]? {
        let fragments: [[ZenStatusRun]] = [
            metrics.cachedPromptTokenCount.map { labeled("c:", tokenCountText($0)) },
            metrics.promptTokenCount.map { labeled("p:", tokenCountText($0)) },
            metrics.completionTokenCount.map { labeled("g:", tokenCountText($0)) }
        ].compactMap(\.self)

        guard !fragments.isEmpty else {
            return nil
        }
        return joined(fragments, separator: " ")
    }

    // MARK: - Throughput

    /// The throughput label, a single one with the `tok/s` unit at the end
    /// (`TerminalStatusBar.generationThroughputFragment`). While the prompt is
    /// evaluated it shows the progress and the prefill rate once measurable
    /// (`p:1.2k/8.0k 512.0 tok/s`, `p:0/8.0k`); otherwise the known speeds
    /// (`p:512.0 g:42.1 tok/s`). `nil` without anything usable.
    public static func throughputText(_ metrics: DirectAgentGenerationMetrics) -> String? {
        throughputRuns(metrics).map { $0.map(\.text).joined() }
    }

    static func throughputRuns(_ metrics: DirectAgentGenerationMetrics) -> [ZenStatusRun]? {
        guard let throughput = metrics.throughput else {
            return nil
        }
        let prefillRate = throughput.prefillTokensPerSecond.flatMap(throughputRateText)
        let unit = "tok/s"

        if let processed = throughput.processedTokens,
           let target = throughput.targetTokens {
            let progress = labeled("p:", "\(tokenCountText(processed))/\(tokenCountText(target))")
            guard let prefillRate else {
                return progress
            }
            return progress + [ZenStatusRun(" \(prefillRate) \(unit)")]
        }

        let segments: [[ZenStatusRun]] = [
            prefillRate.map { labeled("p:", $0) },
            throughput.generationTokensPerSecond
                .flatMap(throughputRateText)
                .map { labeled("g:", $0) }
        ].compactMap(\.self)
        guard !segments.isEmpty else {
            return nil
        }
        return joined(segments, separator: " ") + [ZenStatusRun(" \(unit)")]
    }

    /// One decimal for every speed; `nil` for a value that is not a finite,
    /// non-negative speed (`TerminalStatusBar.throughputRateText`).
    public static func throughputRateText(_ value: Double) -> String? {
        guard value.isFinite, value >= 0 else {
            return nil
        }
        return String(format: "%.1f", value)
    }

    // MARK: - Subscription usage

    /// `"d:<daily> w:<weekly>"` with only the known windows; `nil` without
    /// values (`TerminalStatusBar.subscriptionUsageFragment`).
    public static func subscriptionUsageText(
        _ status: DirectAgentSubscriptionUsageStatus
    ) -> String? {
        subscriptionUsageRuns(status).map { $0.map(\.text).joined() }
    }

    static func subscriptionUsageRuns(
        _ status: DirectAgentSubscriptionUsageStatus
    ) -> [ZenStatusRun]? {
        guard status.hasValues else {
            return nil
        }
        let fragments: [[ZenStatusRun]] = [
            status.dailyUsedPercent.map { labeled("d:", usagePercentText($0)) },
            status.weeklyUsedPercent.map { labeled("w:", usagePercentText($0)) }
        ].compactMap(\.self)
        return joined(fragments, separator: " ")
    }

    /// A usage percentage clamped to 0...100: whole from 10% (and at 0%),
    /// one decimal below; `"--"` when not finite
    /// (`TerminalStatusBar.usagePercentText`).
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

    // MARK: - Durations

    /// `h:mm:ss`; `"--"` for a negative or non-finite value
    /// (`TerminalStatusBar.durationText`).
    public static func durationText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else {
            return "--"
        }
        let style = Duration.TimeFormatStyle(pattern: .hourMinuteSecond)
        return Duration
            .seconds(value)
            .formatted(style)
    }

    /// The whole seconds elapsed from `start` to `now`, truncated like the
    /// terminal's live timer (`Duration.components.seconds`).
    public static func elapsedSeconds(since start: Date, now: Date) -> Double {
        let interval = now.timeIntervalSince(start)
        guard interval.isFinite else {
            return 0
        }
        return interval.rounded(.towardZero)
    }

    // MARK: - Paths

    /// `path` with the home-directory prefix replaced by `~`, like the
    /// terminal consent card.
    public static func abbreviatedPath(
        _ path: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        guard !homeDirectory.isEmpty else { return path }
        if path == homeDirectory { return "~" }
        if path.hasPrefix(homeDirectory + "/") {
            return "~" + String(path.dropFirst(homeDirectory.count))
        }
        return path
    }

    // MARK: - Status line

    /// The fragments of the status line in the terminal UI's order
    /// (`TerminalStatusBar.statusTextLocked`): the full-access dot, spinner
    /// and model, context window, elapsed time or last response duration,
    /// token counts, throughput, subscription usage, git summary.
    ///
    /// - Parameter now: The instant the live elapsed time is measured at.
    public static func fragments(
        for state: ZenStatusBarState,
        now: Date = Date()
    ) -> [ZenStatusFragment] {
        let tokensUsed = state.contextWindow?.usedTokens
            ?? state.metrics?.totalTokenCount
        var fragments: [ZenStatusFragment] = []

        if let runs = accessModeRuns(state.localExecAccessMode) {
            fragments.append(ZenStatusFragment(kind: .accessMode, runs: runs))
        }
        if let modelID = state.modelID {
            if state.isGenerating {
                fragments.append(ZenStatusFragment(kind: .activity, runs: []))
            }
            fragments.append(ZenStatusFragment(
                kind: .model,
                runs: [ZenStatusRun(modelText(modelID: modelID, thinking: state.thinking))]
            ))
        }
        if tokensUsed != nil || state.contextWindow?.maxTokens != nil {
            let contextText = tokenWindowText(
                usedTokens: state.contextWindow?.usedTokens,
                metricUsedTokens: tokensUsed,
                maxTokens: state.contextWindow?.maxTokens
            )
            fragments.append(ZenStatusFragment(
                kind: .contextWindow,
                runs: [ZenStatusRun(contextText)],
                gaugeFraction: contextFraction(
                    usedTokens: tokensUsed,
                    maxTokens: state.contextWindow?.maxTokens
                )
            ))
        }
        if state.isGenerating, let start = state.turnStartedAt {
            let elapsed = elapsedSeconds(since: start, now: now)
            fragments.append(ZenStatusFragment(
                kind: .duration,
                runs: [ZenStatusRun(durationText(elapsed))]
            ))
        } else if let duration = state.metrics?.responseDurationSeconds {
            fragments.append(ZenStatusFragment(
                kind: .duration,
                runs: [ZenStatusRun(durationText(duration))]
            ))
        }
        if let metrics = state.metrics,
           let runs = generationTokenCountsRuns(metrics) {
            fragments.append(ZenStatusFragment(kind: .tokenCounts, runs: runs))
        }
        if let metrics = state.metrics,
           let runs = throughputRuns(metrics) {
            fragments.append(ZenStatusFragment(kind: .throughput, runs: runs))
        }
        if let usage = state.subscriptionUsage,
           let runs = subscriptionUsageRuns(usage) {
            fragments.append(ZenStatusFragment(kind: .subscriptionUsage, runs: runs))
        }
        if let gitStatus = state.gitStatus {
            fragments.append(ZenStatusFragment(kind: .gitStatus, runs: gitStatusRuns(gitStatus)))
        }
        return fragments
    }

    /// The plain status line: the terminal UI's status text without its
    /// spinner frame, fragments joined by `" · "`.
    public static func statusText(
        for state: ZenStatusBarState,
        now: Date = Date()
    ) -> String {
        fragments(for: state, now: now)
            .filter { $0.kind != .activity }
            .map(\.text)
            .joined(separator: separator)
    }

    /// The context-window fill fraction, clamped to 0...1.
    static func contextFraction(usedTokens: Int?, maxTokens: Int?) -> Double? {
        guard let maxTokens, maxTokens > 0 else {
            return nil
        }
        let used = Double(usedTokens ?? 0)
        return min(max(used / Double(maxTokens), 0), 1)
    }

    // MARK: - Helpers

    private static func labeled(_ label: String, _ value: String) -> [ZenStatusRun] {
        [ZenStatusRun(label, style: .label), ZenStatusRun(value)]
    }

    private static func joined(_ fragments: [[ZenStatusRun]], separator: String) -> [ZenStatusRun] {
        var runs: [ZenStatusRun] = []
        for (index, fragment) in fragments.enumerated() {
            if index > 0 {
                runs.append(ZenStatusRun(separator))
            }
            runs.append(contentsOf: fragment)
        }
        return runs
    }
}
