//
//  ZenSubAgentsCard.swift
//  ZenApp
//
//  The sub-agent overview, like the terminal's `👥 Sub-Agents:` section.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// The session's sub-agents on a content card: the header with the
/// per-status counts, then one row per agent snapshot with its status color,
/// name and badge, profile, model and token counters, current activity
/// (reasoning, message, or tool), latest error, and elapsed time.
public struct ZenSubAgentsCard: View {
    private let overview: ChatSubAgentOverview

    @Environment(\.zenPalette) private var palette

    /// - Parameter overview: The sub-agent snapshots, as the session
    ///   publishes them.
    public init(overview: ChatSubAgentOverview) {
        self.overview = overview
    }

    public var body: some View {
        let snapshots = overview.snapshots
        VStack(alignment: .leading, spacing: 8) {
            Text("👥 Sub-Agents")
                .font(.headline)
                .foregroundStyle(palette.accent)
            Text(AttributedString.zen(zenSummaryRuns(
                ZenTranscriptStatus.subAgentSummarySegments(snapshots),
                palette: palette
            )))
            .font(ZenFonts.monoSmall)
            if !snapshots.isEmpty {
                ZenSeparator()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshots, id: \.id) { snapshot in
                        ZenSubAgentRow(snapshot: snapshot)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zenContentCard(cornerRadius: 14)
    }
}

/// One sub-agent of the overview.
struct ZenSubAgentRow: View {
    let snapshot: DirectSubAgentRuntime.AgentSnapshot

    @Environment(\.zenPalette) private var palette

    var body: some View {
        let color = ZenTranscriptStatus.role(for: snapshot).color(in: palette)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("●")
                .foregroundStyle(color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ZenTranscriptText.inline(snapshot.name, limit: 120) ?? snapshot.id)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(palette.textPrimary)
                    ZenStateBadge(text: ZenTranscriptStatus.displayStatus(for: snapshot), color: color)
                    Spacer(minLength: 8)
                    elapsed
                }
                if !metadata.isEmpty {
                    Text(AttributedString.zen(metadata))
                        .font(.caption)
                        .lineLimit(2)
                }
                activity
                if let error = ZenTranscriptText.inline(snapshot.latestError ?? "", limit: 400) {
                    Text("❌ \(error)")
                        .font(.caption)
                        .foregroundStyle(palette.failureMessage)
                        .lineLimit(3)
                }
            }
        }
    }

    /// The elapsed time: live while the agent works, else from its creation
    /// to its latest update.
    @ViewBuilder
    private var elapsed: some View {
        Group {
            if snapshot.pending {
                Text(snapshot.createdAt, style: .timer)
            } else {
                Text(ZenTranscriptStatus.elapsedText(snapshot.updatedAt.timeIntervalSince(snapshot.createdAt)))
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(palette.toolDuration)
    }

    /// `agent: <profile>  ·  model: <model>  ·  c:… p:… g:…`
    private var metadata: [ZenTextRun] {
        var parts: [[ZenTextRun]] = []
        if let profile = snapshot.profileName.flatMap({ ZenTranscriptText.inline($0, limit: 120) }) {
            parts.append(labeled("agent:", profile))
        }
        if let model = (ZenTranscriptText.nonBlank(snapshot.configuredModelID) ?? ZenTranscriptText.nonBlank(snapshot.modelID))
            .flatMap({ ZenTranscriptText.inline($0, limit: 120) }) {
            parts.append(labeled("model:", model))
        }
        if let metrics = snapshot.latestMetrics {
            let counters: [(String, Int)] = [
                metrics.cachedPromptTokenCount.map { ("c:", $0) },
                metrics.promptTokenCount.map { ("p:", $0) },
                metrics.completionTokenCount.map { ("g:", $0) }
            ].compactMap(\.self)
            if !counters.isEmpty {
                var runs: [ZenTextRun] = []
                for (index, counter) in counters.enumerated() {
                    if index > 0 { runs.append(ZenTextRun(text: " ", color: palette.textMuted)) }
                    runs.append(ZenTextRun(text: counter.0, color: palette.textMuted))
                    runs.append(ZenTextRun(
                        text: ZenTranscriptStatus.tokenCountText(counter.1),
                        color: palette.inlineCodeForeground
                    ))
                }
                parts.append(runs)
            }
        }
        var runs: [ZenTextRun] = []
        for (index, part) in parts.enumerated() {
            if index > 0 { runs.append(ZenTextRun(text: "  ·  ", color: palette.textMuted)) }
            runs.append(contentsOf: part)
        }
        return runs
    }

    private func labeled(_ label: String, _ value: String) -> [ZenTextRun] {
        [
            ZenTextRun(text: label + " ", color: palette.textMuted),
            ZenTextRun(text: value, color: palette.inlineCodeForeground)
        ]
    }

    /// The reasoning, the message, or the tool the agent is on, like the
    /// terminal's activity rows.
    @ViewBuilder
    private var activity: some View {
        let activityText = snapshot.currentActivity.flatMap { ZenTranscriptText.inline($0, limit: 400) }
        let toolName = ZenTranscriptText.nonBlank(snapshot.currentToolName)
            .flatMap { ZenToolCallFormatting.isHidden(toolName: $0) ? nil : ZenTranscriptText.inline($0, limit: 120) }
        VStack(alignment: .leading, spacing: 2) {
            switch snapshot.currentActivityKind {
            case .thinking:
                thinkingRow(activityText)
            case .content, nil:
                contentRow(activityText)
            @unknown default:
                contentRow(activityText)
            }
            if let toolName {
                Text(AttributedString.zen(toolRuns(toolName)))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if snapshot.pending, activityText == nil, toolName == nil, snapshot.currentActivityKind != .thinking {
                thinkingRow(nil)
            }
        }
    }

    /// `🛠️ <tool>  <target>` in the tool colors.
    private func toolRuns(_ toolName: String) -> [ZenTextRun] {
        var runs = [
            ZenTextRun(text: ToolCallPresentation.toolIcon(for: toolName) + " ", color: palette.toolTitle),
            ZenTextRun(text: toolName, color: palette.toolTitle, isBold: true)
        ]
        if let target = snapshot.currentToolTarget.flatMap({ ZenTranscriptText.inline($0, limit: 300) }) {
            runs.append(ZenTextRun(text: "  " + target, color: palette.toolValue))
        }
        return runs
    }

    /// `💬 <message>`, when the agent is writing.
    @ViewBuilder
    private func contentRow(_ activityText: String?) -> some View {
        if let activityText {
            Text("💬 \(activityText)")
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(2)
        }
    }

    private func thinkingRow(_ paragraph: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("🤔 thinking…")
            if let paragraph {
                Text(paragraph)
                    .lineLimit(2)
            }
        }
        .font(.caption)
        .italic()
        .foregroundStyle(palette.thinking)
    }
}

#Preview("Sub-agents") {
    let now = Date.now
    let snapshots = [
        DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_1",
            name: "transcript-dev",
            role: "Developer",
            profileName: "Developer",
            status: .running,
            pending: true,
            configuredModelID: "claude-opus",
            currentToolName: "local.exec",
            currentToolTarget: "swift build --target ZenAppTranscript",
            latestMetrics: DirectAgentGenerationMetrics(
                promptTokenCount: 1_250,
                cachedPromptTokenCount: 48_000,
                completionTokenCount: 312
            ),
            latestOutput: nil,
            latestError: nil,
            createdAt: now.addingTimeInterval(-95),
            updatedAt: now
        ),
        DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_2",
            name: "reviewer",
            role: "Reviewer",
            status: .running,
            pending: true,
            currentActivity: "Checking the palette usage in every view.",
            currentActivityKind: .thinking,
            latestOutput: nil,
            latestError: nil,
            createdAt: now.addingTimeInterval(-20),
            updatedAt: now
        ),
        DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_3",
            name: "builder",
            role: "Builder",
            status: .idle,
            pending: false,
            latestOutput: "Done.",
            latestError: nil,
            createdAt: now.addingTimeInterval(-400),
            updatedAt: now.addingTimeInterval(-30)
        ),
        DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_4",
            name: "tester",
            role: "Tester",
            status: .failed,
            pending: false,
            latestOutput: nil,
            latestError: "The test target does not build.",
            createdAt: now.addingTimeInterval(-200),
            updatedAt: now.addingTimeInterval(-60)
        )
    ]
    ZenSubAgentsCard(overview: ChatSubAgentOverview(snapshots: snapshots))
        .padding()
        .frame(width: 560)
}
