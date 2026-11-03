//
//  ZenStatusBar.swift
//  ZenApp
//
//  The one-line status bar under the composer: the terminal UI's status
//  fragments, in its order and colors.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// Everything the status bar shows, mirroring the state of the terminal UI's
/// `TerminalStatusBar`.
public struct ZenStatusBarState: Equatable, Sendable {
    /// A prompt is generating: the spinner and the live elapsed time show.
    public var isGenerating: Bool
    /// When the running turn started, for the live elapsed time.
    public var turnStartedAt: Date?
    /// The model in use; the model fragment (and the spinner) need it.
    public var modelID: String?
    /// The thinking selection shown after the model name.
    public var thinking: AgentThinkingSelection?
    /// The selected agent, shown at the trailing edge.
    public var agentName: String?
    /// The latest generation metrics of the session.
    public var metrics: DirectAgentGenerationMetrics?
    /// The latest context-window status.
    public var contextWindow: DirectAgentContextWindowStatus?
    /// The latest subscription usage.
    public var subscriptionUsage: DirectAgentSubscriptionUsageStatus?
    /// The git working-tree summary of the workspace.
    public var gitStatus: TerminalGitStatusSummary?
    /// The workspace folder, shown abbreviated at the trailing edge.
    public var workspace: URL?

    public init(
        isGenerating: Bool = false,
        turnStartedAt: Date? = nil,
        modelID: String? = nil,
        thinking: AgentThinkingSelection? = nil,
        agentName: String? = nil,
        metrics: DirectAgentGenerationMetrics? = nil,
        contextWindow: DirectAgentContextWindowStatus? = nil,
        subscriptionUsage: DirectAgentSubscriptionUsageStatus? = nil,
        gitStatus: TerminalGitStatusSummary? = nil,
        workspace: URL? = nil
    ) {
        self.isGenerating = isGenerating
        self.turnStartedAt = turnStartedAt
        self.modelID = modelID
        self.thinking = thinking
        self.agentName = agentName
        self.metrics = metrics
        self.contextWindow = contextWindow
        self.subscriptionUsage = subscriptionUsage
        self.gitStatus = gitStatus
        self.workspace = workspace
    }
}

/// The status line under the composer.
///
/// The leading side lists the terminal UI's fragments joined by `" · "`
/// (formatted by ``ZenStatusFormatting``): a spinner while generating, model
/// and thinking, the context window with a small gauge, the live elapsed time
/// (refreshed every second) or the last response duration, token counts,
/// throughput, subscription usage, and the git summary. The trailing side
/// shows the agent name and the abbreviated workspace.
public struct ZenStatusBar: View {
    @Environment(\.zenPalette) private var palette
    private let state: ZenStatusBarState

    public init(state: ZenStatusBarState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 12) {
            if state.isGenerating, let start = state.turnStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    leading(now: context.date)
                }
            } else {
                leading(now: Date())
            }
            Spacer(minLength: 12)
            if let trailing = ZenStatusFormatting.trailingText(for: state) {
                Text(trailing)
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(palette.textSecondary)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }

    private func leading(now: Date) -> some View {
        let fragments = ZenStatusFormatting.fragments(for: state, now: now)
        return HStack(spacing: 0) {
            ForEach(Array(fragments.enumerated()), id: \.element.id) { index, fragment in
                if index > 0 {
                    Text(ZenStatusFormatting.separator)
                }
                fragmentView(fragment)
            }
        }
        .lineLimit(1)
        .layoutPriority(1)
    }

    @ViewBuilder
    private func fragmentView(_ fragment: ZenStatusFragment) -> some View {
        switch fragment.kind {
        case .activity:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(palette.accent)
                .scaleEffect(0.7)
                .frame(width: 14, height: 14)
        case .contextWindow:
            HStack(spacing: 5) {
                styledText(fragment.runs)
                if let fraction = fragment.gaugeFraction {
                    ZenContextGauge(fraction: fraction)
                }
            }
        default:
            styledText(fragment.runs)
        }
    }

    private func styledText(_ runs: [ZenStatusRun]) -> Text {
        var text = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            part.foregroundColor = color(for: run.style)
            text.append(part)
        }
        return Text(text)
    }

    private func color(for style: ZenStatusRun.Style) -> Color {
        switch style {
        case .plain: palette.textSecondary
        case .label: palette.textMuted
        case .fileCount: palette.fileCount
        case .fileAddition: palette.fileAddition
        case .fileDeletion: palette.fileDeletion
        }
    }
}

/// The small linear gauge next to the context-window counter.
struct ZenContextGauge: View {
    @Environment(\.zenPalette) private var palette
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(palette.textMuted.opacity(0.35))
            .frame(width: 32, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(palette.accentCount)
                    .frame(width: max(2, 32 * fraction), height: 4)
            }
            .accessibilityLabel("Context window")
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

#Preview("Status bar – generating") {
    ZenStatusBar(state: ZenStatusBarState(
        isGenerating: true,
        turnStartedAt: Date().addingTimeInterval(-42),
        modelID: "remote-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
        thinking: .high,
        agentName: "Developer",
        metrics: DirectAgentGenerationMetrics(
            promptTokenCount: 120,
            cachedPromptTokenCount: 800,
            completionTokenCount: 32,
            throughput: DirectAgentGenerationThroughput(
                phase: .generation,
                prefillTokensPerSecond: 512,
                generationTokensPerSecond: 41.2
            )
        ),
        contextWindow: DirectAgentContextWindowStatus(
            usedTokens: 35_000,
            maxTokens: 128_000,
            modelID: "Qwen3-Coder",
            isApproximate: false
        ),
        subscriptionUsage: DirectAgentSubscriptionUsageStatus(
            provider: "ChatGPT",
            dailyUsedPercent: 12,
            weeklyUsedPercent: 4.5
        ),
        gitStatus: TerminalGitStatusSummary(changedFileCount: 3, additions: 12, deletions: 4),
        workspace: URL(filePath: NSHomeDirectory()).appending(path: "Projects/ZenCODE")
    ))
    .padding()
    .frame(width: 900)
}

#Preview("Status bar – idle") {
    ZenStatusBar(state: ZenStatusBarState(
        modelID: "openai/gpt-5",
        metrics: DirectAgentGenerationMetrics(
            promptTokenCount: 15_000,
            completionTokenCount: 20_000,
            responseDurationSeconds: 12
        ),
        workspace: URL(filePath: "/tmp/project")
    ))
    .padding()
    .frame(width: 700)
}
