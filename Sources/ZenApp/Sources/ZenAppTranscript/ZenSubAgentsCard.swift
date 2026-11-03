//
//  ZenSubAgentsCard.swift
//  ZenApp
//
//  The sub-agents in progress, like the terminal's `👥 Sub-Agents:` section.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// The session's sub-agents in progress (queued or running) on a content card:
/// the header with their count, then one row per agent with its status color,
/// name and badge, live elapsed time, role, profile, task and attempt, model
/// and token counters, current activity (reasoning, message, or tool), and
/// latest error. The card draws nothing while no sub-agent is in progress, and
/// never shows the final response of an agent: a finished agent leaves it.
///
/// With an `onSelect` callback every row is a button that reports the agent's
/// id, so the host can open the agent's transcript; without it the rows are
/// static, with selectable text.
public struct ZenSubAgentsCard: View {
    private let overview: ChatSubAgentOverview
    private let onSelect: ((String) -> Void)?

    @Environment(\.zenPalette) private var palette

    /// - Parameters:
    ///   - overview: The sub-agent snapshots, as the session publishes them.
    ///     Only the ones in progress are shown, in the given order.
    ///   - onSelect: Called with the id of the agent whose row was clicked.
    ///     `nil` leaves the rows static.
    public init(overview: ChatSubAgentOverview, onSelect: ((String) -> Void)? = nil) {
        self.overview = overview
        self.onSelect = onSelect
    }

    public var body: some View {
        let snapshots = Self.visibleSnapshots(overview.snapshots)
        if !snapshots.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("👥 Sub-Agents")
                        .font(.headline)
                        .foregroundStyle(palette.accent)
                    Text(AttributedString.zen(zenSummaryRuns(
                        Self.summarySegments(snapshots),
                        palette: palette
                    )))
                    .font(ZenFonts.monoSmall)
                }
                .textSelection(.enabled)
                ZenSeparator()
                // The rows carry their own padding, which the highlight of a
                // clickable row fills; the negative padding keeps their text
                // aligned with the header.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(snapshots, id: \.id) { snapshot in
                        ZenSubAgentRow(snapshot: snapshot, onSelect: onSelect)
                    }
                }
                .padding(.horizontal, -ZenSubAgentRow.horizontalInset)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .zenContentCard(cornerRadius: 14)
        }
    }

    /// The snapshots the card shows: the ones in progress (queued or running),
    /// in the given order.
    nonisolated static func visibleSnapshots(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> [DirectSubAgentRuntime.AgentSnapshot] {
        snapshots.filter(\.pending)
    }

    /// The summary line under the title: the number of agents in progress.
    nonisolated static func summarySegments(
        _ visible: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> [ZenStatusSegment] {
        [ZenStatusSegment(text: "\(visible.count) in progress", role: nil)]
    }
}

/// What a sub-agent is doing right now, as the terminal's activity rows
/// decide it: the reasoning or the message in progress, and the tool it runs.
struct ZenSubAgentActivity: Equatable {
    /// The model phase `currentActivity` belongs to.
    enum Phase: Equatable {
        /// Reasoning, with the paragraph in progress when there is one.
        case thinking(paragraph: String?)
        /// Writing the given message.
        case message(String)
        /// No activity text.
        case none
    }

    let phase: Phase
    /// The tool the agent runs, `nil` when there is none or it is hidden.
    let toolName: String?
    /// Whether the agent is pending with nothing else to show, so the row
    /// holds the thinking placeholder.
    let showsThinkingPlaceholder: Bool

    init(_ snapshot: DirectSubAgentRuntime.AgentSnapshot) {
        let text = snapshot.currentActivity.flatMap { ZenTranscriptText.inline($0, limit: 400) }
        switch snapshot.currentActivityKind {
        case .thinking:
            phase = .thinking(paragraph: text)
        case .content, nil:
            phase = text.map { .message($0) } ?? .none
        @unknown default:
            phase = text.map { .message($0) } ?? .none
        }
        toolName = ZenTranscriptText.nonBlank(snapshot.currentToolName)
            .flatMap { ZenToolCallFormatting.isHidden(toolName: $0) ? nil : ZenTranscriptText.inline($0, limit: 120) }
        showsThinkingPlaceholder = snapshot.pending && phase == .none && toolName == nil
    }
}

/// One sub-agent of the overview: a button when `onSelect` is set, else static.
/// ``ZenSubAgentDetailCard`` shows the same row without the activity.
struct ZenSubAgentRow: View {
    /// The horizontal padding of a row, between its text and the edge of its
    /// highlight.
    static let horizontalInset: CGFloat = 8

    let snapshot: DirectSubAgentRuntime.AgentSnapshot
    var onSelect: ((String) -> Void)?
    /// Shows the current activity (reasoning, message, tool, placeholder)
    /// under the metadata.
    var showsActivity = true

    @State private var isHovered = false
    @Environment(\.zenPalette) private var palette

    var body: some View {
        if let onSelect {
            Button {
                onSelect(snapshot.id)
            } label: {
                padded
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(palette.accent.opacity(isHovered ? 0.10 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .pointerStyle(.link)
            .help("Show the sub-agent transcript")
            .accessibilityLabel(Text("Sub-agent \(name)"))
            .accessibilityHint(Text("Shows the sub-agent transcript"))
        } else {
            padded
                .textSelection(.enabled)
        }
    }

    private var padded: some View {
        content
            .padding(.horizontal, Self.horizontalInset)
            .padding(.vertical, 6)
    }

    private var name: String {
        ZenTranscriptText.inline(snapshot.name, limit: 120) ?? snapshot.id
    }

    private var content: some View {
        let color = ZenTranscriptStatus.role(for: snapshot).color(in: palette)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("●")
                .foregroundStyle(color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(palette.textPrimary)
                    ZenStateBadge(text: ZenTranscriptStatus.displayStatus(for: snapshot), color: color)
                    Spacer(minLength: 8)
                    elapsed
                }
                ForEach(Array(Self.metadataLines(for: snapshot, palette: palette).enumerated()), id: \.offset) { _, line in
                    Text(AttributedString.zen(line))
                        .font(.caption)
                        .lineLimit(2)
                }
                if showsActivity {
                    activity
                }
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

    // MARK: - Metadata

    /// The metadata lines under the title, each only when it has something to
    /// say, with muted labels and values in the inline-code color:
    ///
    /// - `role: <role>  ·  agent: <profile>`
    /// - `task: <id>  ·  attempt: <n>` (the attempt only with a task)
    /// - `model: <model>  ·  c:… p:… g:…` (cache, prefill, and generated
    ///   tokens; the counters alone when the model is unknown)
    nonisolated static func metadataLines(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot,
        palette: ZenPalette
    ) -> [[ZenTextRun]] {
        func labeled(_ label: String, _ value: String) -> [ZenTextRun] {
            [
                ZenTextRun(text: label + " ", color: palette.textMuted),
                ZenTextRun(text: value, color: palette.inlineCodeForeground)
            ]
        }
        func inline(_ value: String?) -> String? {
            value.flatMap { ZenTranscriptText.inline($0, limit: 120) }
        }

        var identity: [[ZenTextRun]] = []
        if let role = inline(snapshot.role) {
            identity.append(labeled("role:", role))
        }
        if let profile = inline(snapshot.profileName) {
            identity.append(labeled("agent:", profile))
        }

        var task: [[ZenTextRun]] = []
        if let taskID = inline(snapshot.taskID) {
            task.append(labeled("task:", taskID))
            if let attempt = snapshot.taskAttemptOrdinal {
                task.append(labeled("attempt:", String(attempt)))
            }
        }

        var model: [[ZenTextRun]] = []
        if let modelID = inline(ZenTranscriptText.nonBlank(snapshot.configuredModelID)
            ?? ZenTranscriptText.nonBlank(snapshot.modelID)) {
            model.append(labeled("model:", modelID))
        }
        if let counters = tokenRuns(snapshot.latestMetrics, palette: palette) {
            model.append(counters)
        }

        return [identity, task, model]
            .filter { !$0.isEmpty }
            .map { parts in
                var runs: [ZenTextRun] = []
                for (index, part) in parts.enumerated() {
                    if index > 0 { runs.append(ZenTextRun(text: "  ·  ", color: palette.textMuted)) }
                    runs.append(contentsOf: part)
                }
                return runs
            }
    }

    /// `c:48.0k p:1.2k g:312`, the counters the metrics have, or `nil` when
    /// none: cached prompt, prompt, and generated tokens.
    private nonisolated static func tokenRuns(
        _ metrics: DirectAgentGenerationMetrics?,
        palette: ZenPalette
    ) -> [ZenTextRun]? {
        guard let metrics else { return nil }
        let counters: [(String, Int)] = [
            metrics.cachedPromptTokenCount.map { ("c:", $0) },
            metrics.promptTokenCount.map { ("p:", $0) },
            metrics.completionTokenCount.map { ("g:", $0) }
        ].compactMap(\.self)
        guard !counters.isEmpty else { return nil }
        var runs: [ZenTextRun] = []
        for (index, counter) in counters.enumerated() {
            if index > 0 { runs.append(ZenTextRun(text: " ", color: palette.textMuted)) }
            runs.append(ZenTextRun(text: counter.0, color: palette.textMuted))
            runs.append(ZenTextRun(
                text: ZenTranscriptStatus.tokenCountText(counter.1),
                color: palette.inlineCodeForeground
            ))
        }
        return runs
    }

    // MARK: - Activity

    /// The reasoning, the message, or the tool the agent is on, like the
    /// terminal's activity rows.
    @ViewBuilder
    private var activity: some View {
        let current = ZenSubAgentActivity(snapshot)
        VStack(alignment: .leading, spacing: 2) {
            switch current.phase {
            case .thinking(let paragraph):
                thinkingRow(paragraph)
            case .message(let text):
                Text("💬 \(text)")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(3)
            case .none:
                EmptyView()
            }
            if let toolName = current.toolName {
                Text(AttributedString.zen(toolRuns(toolName)))
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            if current.showsThinkingPlaceholder {
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

    private func thinkingRow(_ paragraph: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("🤔 thinking…")
            if let paragraph {
                Text(paragraph)
                    .lineLimit(3)
            }
        }
        .font(.caption)
        .italic()
        .foregroundStyle(palette.thinking)
    }
}

#Preview("Sub-agents") {
    ZenSubAgentsCard(overview: ChatSubAgentOverview(snapshots: ZenSubAgentPreviewData.snapshots))
        .padding()
        .frame(width: 560)
}

#Preview("Sub-agents (selectable)") {
    ZenSubAgentsCard(
        overview: ChatSubAgentOverview(snapshots: ZenSubAgentPreviewData.snapshots),
        onSelect: { _ in }
    )
    .padding()
    .frame(width: 560)
}

/// The preview fixtures: a running agent with a tool and tokens, a queued one,
/// a thinking one, and an idle one the card must leave out.
private enum ZenSubAgentPreviewData {
    static var snapshots: [DirectSubAgentRuntime.AgentSnapshot] {
        let now = Date.now
        return [
            DirectSubAgentRuntime.AgentSnapshot(
                id: "agent_1",
                taskID: "transcript-views",
                taskAttemptOrdinal: 2,
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
                profileName: "Reviewer",
                status: .queued,
                pending: true,
                latestOutput: nil,
                latestError: nil,
                createdAt: now.addingTimeInterval(-8),
                updatedAt: now
            ),
            DirectSubAgentRuntime.AgentSnapshot(
                id: "agent_3",
                name: "planner",
                role: "Planner",
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
                id: "agent_4",
                name: "builder",
                role: "Builder",
                status: .idle,
                pending: false,
                latestOutput: "Done.",
                latestError: nil,
                createdAt: now.addingTimeInterval(-400),
                updatedAt: now.addingTimeInterval(-30)
            )
        ]
    }
}
