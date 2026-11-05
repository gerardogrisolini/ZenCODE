//
//  ZenTaskGraphCard.swift
//  ZenApp
//
//  The task-graph overview, like the terminal's `🫧 Tasks:` section.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// The session's task graph on a content card: the header with the
/// graph state and the per-status counts, then one row per task in the
/// graph's order with its status glyph and color, id, title, complexity,
/// assignee, and dependencies.
public struct ZenTaskGraphCard: View {
    private let overview: ChatTaskGraphOverview

    @Environment(\.zenPalette) private var palette

    /// - Parameter overview: The graph and its task views, as the session
    ///   publishes them.
    public init(overview: ChatTaskGraphOverview) {
        self.overview = overview
    }

    public var body: some View {
        let graph = overview.graph
        let tasks = overview.tasks.sorted { lhs, rhs in
            lhs.task.order != rhs.task.order ? lhs.task.order < rhs.task.order : lhs.task.id < rhs.task.id
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("🫧 Tasks")
                    .font(.headline)
                    .foregroundStyle(palette.accent)
                Spacer(minLength: 8)
                ZenStateBadge(
                    text: graph.state.rawValue,
                    color: ZenTranscriptStatus.role(for: graph.state).color(in: palette)
                )
            }
            Text(AttributedString.zen(zenSummaryRuns(ZenTranscriptStatus.taskSummarySegments(tasks), palette: palette)))
                .font(ZenFonts.monoSmall)
            Text(AttributedString.zen([
                ZenTextRun(text: "graph ", color: palette.textMuted),
                ZenTextRun(text: ZenTranscriptText.inline(graph.id, limit: 120) ?? graph.id, color: palette.inlineCodeForeground),
                ZenTextRun(text: "  ·  revision ", color: palette.textMuted),
                ZenTextRun(text: "\(graph.revision)", color: palette.inlineCodeForeground)
            ]))
            .font(.caption.monospaced())

            if tasks.isEmpty {
                Text("No tasks.")
                    .font(.callout)
                    .foregroundStyle(palette.textMuted)
            } else {
                ZenSeparator()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tasks, id: \.task.id) { view in
                        ZenTaskRow(view: view)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zenContentCard(cornerRadius: 14)
    }
}

/// One task of the overview.
struct ZenTaskRow: View {
    let view: TaskRecordView

    @Environment(\.zenPalette) private var palette

    var body: some View {
        let task = view.task
        let color = ZenTranscriptStatus.role(for: task.status).color(in: palette)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ZenTranscriptStatus.glyph(for: task.status))
                .font(ZenFonts.monoSmall.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 14)
                .help(task.status.rawValue)
            VStack(alignment: .leading, spacing: 2) {
                Text(AttributedString.zen([
                    ZenTextRun(text: ZenTranscriptText.inline(task.id, limit: 120) ?? task.id, color: palette.inlineCodeForeground),
                    ZenTextRun(text: "  ", color: palette.textPrimary),
                    ZenTextRun(text: ZenTranscriptText.inline(task.title) ?? "", color: palette.textPrimary)
                ]))
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !metadata.isEmpty {
                    Text(AttributedString.zen(metadata))
                        .font(.caption)
                        .lineLimit(3)
                }
            }
        }
    }

    /// `complexity`, assignee, dependencies, and what the task waits for,
    /// joined with `·`.
    private var metadata: [ZenTextRun] {
        let task = view.task
        var parts: [[ZenTextRun]] = [[
            ZenTextRun(text: "complexity ", color: palette.textMuted),
            ZenTextRun(text: "\(task.complexity)/10", color: palette.textSecondary)
        ]]
        if let agentID = task.assigneeAgentID {
            parts.append([
                ZenTextRun(text: "assignee ", color: palette.textMuted),
                ZenTextRun(text: ZenTranscriptText.inline(agentID, limit: 120) ?? agentID, color: palette.inlineCodeForeground)
            ])
        }
        if !task.dependsOn.isEmpty {
            parts.append([
                ZenTextRun(text: "depends on ", color: palette.textMuted),
                ZenTextRun(text: task.dependsOn.joined(separator: ", "), color: palette.inlineCodeForeground)
            ])
        }
        if !view.blockedBy.isEmpty {
            parts.append([
                ZenTextRun(text: "waits for ", color: palette.textMuted),
                ZenTextRun(text: view.blockedBy.joined(separator: ", "), color: palette.statusQueued)
            ])
        } else if let reason = ZenTranscriptText.nonBlank(view.blockedReason),
                  !view.isRunnable,
                  task.status != .completed {
            parts.append([ZenTextRun(text: ZenTranscriptText.inline(reason) ?? reason, color: palette.textMuted)])
        }
        var runs: [ZenTextRun] = []
        for (index, part) in parts.enumerated() {
            if index > 0 {
                runs.append(ZenTextRun(text: "  ·  ", color: palette.statusInactive))
            }
            runs.append(contentsOf: part)
        }
        return runs
    }
}

/// A small capsule naming a state in its status color.
struct ZenStateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(color.opacity(0.6)))
            .fixedSize()
    }
}

#Preview("Task graph") {
    let records = [
        TaskRecord(id: "scaffold", title: "Create the package", order: 0, status: .completed),
        TaskRecord(
            id: "transcript-views",
            title: "Transcript leaf views",
            order: 1,
            status: .inProgress,
            dependsOn: ["scaffold"],
            activeAttemptID: "a1",
            attempts: [TaskAttempt(id: "a1", ordinal: 1, agentID: "agent_132dd052", executor: .subAgent, status: .running, startedAt: .now)],
            complexity: 6
        ),
        TaskRecord(id: "integration", title: "Compose the transcript", order: 2, dependsOn: ["transcript-views"]),
        TaskRecord(id: "release", title: "Ship", order: 3, status: .failed, complexity: 3)
    ]
    let graph = TaskGraphSnapshot(id: "goal-1", source: .workflow, state: .active, revision: 7, tasks: records)
    let views = records.map { record in
        TaskRecordView(
            graphID: graph.id,
            graphRevision: graph.revision,
            graphState: graph.state,
            task: record,
            isRunnable: record.status != .pending,
            blockedBy: record.id == "integration" ? ["transcript-views"] : [],
            blockedReason: nil,
            dependents: []
        )
    }
    ZenTaskGraphCard(overview: ChatTaskGraphOverview(graph: graph, tasks: views))
        .padding()
        .frame(width: 560)
}
