//
//  TerminalTaskGraphLayout.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Lays out the task graph as the Markdown the terminal renders and Telegram
/// reuses (it requests the plain form and strips what remains): the summary of
/// the statuses, the identity of the graph, and one header and detail rows per
/// task. A pure function of the graph and its tasks; with `ansiEnabled` the
/// summary segments and the header carry the terminal's colors.
enum TerminalTaskGraphLayout {
    static func markdown(
        graph: TaskGraphSnapshot,
        tasks: [TaskRecordView],
        ansiEnabled: Bool = AgentOutput.standardErrorIsTerminal
    ) -> String {
        let completed = tasks.filter { $0.task.status == .completed }.count
        let running = tasks.filter { $0.task.status == .inProgress }.count
        let validating = tasks.filter { $0.task.status == .awaitingValidation }.count
        let waiting = tasks.filter { $0.task.status == .pending }.count
        let blocked = tasks.filter { $0.task.status == .blocked }.count
        let failed = tasks.filter { $0.task.status == .failed }.count

        var summary = ["\(tasks.count) total"]
        if running > 0 {
            summary.append(
                summarySegment(
                    "▸ \(running) running",
                    color: TerminalStyle.Status.active,
                    ansiEnabled: ansiEnabled
                )
            )
        }
        if completed > 0 {
            summary.append(
                summarySegment(
                    "✓ \(completed) completed",
                    color: TerminalStyle.Status.success,
                    ansiEnabled: ansiEnabled
                )
            )
        }
        if validating > 0 {
            summary.append(
                summarySegment(
                    "◇ \(validating) awaiting validation",
                    color: TerminalStyle.Status.inactive,
                    ansiEnabled: ansiEnabled
                )
            )
        }
        if waiting > 0 {
            summary.append(
                summarySegment(
                    "◇ \(waiting) waiting",
                    color: TerminalStyle.Status.inactive,
                    ansiEnabled: ansiEnabled
                )
            )
        }
        if blocked > 0 {
            summary.append(
                summarySegment(
                    "⊘ \(blocked) blocked",
                    color: TerminalStyle.Status.queued,
                    ansiEnabled: ansiEnabled
                )
            )
        }
        if failed > 0 {
            summary.append(
                summarySegment(
                    "✗ \(failed) failed",
                    color: TerminalStyle.Status.failure,
                    ansiEnabled: ansiEnabled
                )
            )
        }

        let orange = TerminalStyle.Accent.primary
        let reset = TerminalStyle.reset
        let taskHeader = ansiEnabled ? "\(orange)Tasks:\(reset)" : "Tasks:"
        var lines = [
            "🫧 \(taskHeader)",
            summary.joined(separator: " "),
            "",
            "**Graph:** `\(graph.id)` · **state:** `\(graph.state.rawValue)` · **revision:** `\(graph.revision)`",
        ]
        if tasks.isEmpty {
            lines.append("No tasks.")
            return lines.joined(separator: "\n") + "\n"
        }

        for view in tasks.sorted(by: { lhs, rhs in
            if lhs.task.order != rhs.task.order { return lhs.task.order < rhs.task.order }
            return lhs.task.id < rhs.task.id
        }) {
            let marker: String
            switch view.task.status {
            case .completed: marker = "✓"
            case .inProgress: marker = "▸"
            case .awaitingValidation: marker = "◇"
            case .blocked: marker = "⊘"
            case .failed: marker = "✗"
            case .cancelled: marker = "—"
            case .pending: marker = "○"
            }
            var suffix: [String] = []
            suffix.append("complexity: `\(view.task.complexity)/10`")
            if let agentID = view.task.assigneeAgentID {
                suffix.append(agentID)
            }
            if !view.blockedBy.isEmpty {
                suffix.append("waits: " + view.blockedBy.map { "`\($0)`" }.joined(separator: ", "))
            } else if let reason = view.blockedReason,
                      !view.isRunnable,
                      view.task.status != .completed {
                suffix.append(reason)
            }
            let metadata = suffix.joined(separator: " · ")
            lines.append("\(marker) `\(view.task.id)`  \(ChatSessionNoticeText.escapedTaskMarkdown(view.task.title))")
            lines.append(contentsOf: detailLines(metadata, ansiEnabled: ansiEnabled))
        }
        return lines.joined(separator: "\n   ") + "\n\n"
    }

    /// Renders task metadata as indented detail lines under the task's header
    /// line. Long descriptive content wraps to hanging-indent continuation
    /// lines, so verbose reasons stay readable inside the vertical task block.
    /// Returned rows carry only the detail-relative indent: the section join
    /// adds the shared three-space task indent on top of every row.
    private static func detailLines(
        _ metadata: String,
        ansiEnabled: Bool = AgentOutput.standardErrorIsTerminal
    ) -> [String] {
        guard !metadata.isEmpty else {
            return []
        }
        let detailPrefix = summarySegment(
            "· ",
            color: TerminalStyle.Status.inactive,
            ansiEnabled: ansiEnabled
        )
        let wrapWidth = max(40, TerminalTextMetrics.terminalColumnCount() - 20)
        // Word-wrapping (`wrap`) collapses repeated internal spaces past the
        // wrap threshold and leaves single tokens wider than `width` intact.
        // Reflow at visible cell boundaries instead: internal spacing and
        // content are preserved exactly, and over-long tokens are split at the
        // column limit so no detail row exceeds the wrap width.
        return TerminalANSIText.wrapPreservingWhitespace(
            detailPrefix + metadata,
            width: wrapWidth,
            hangingIndent: "    "
        )
            .enumerated()
            .map { index, row in index == 0 ? "  " + row : row }
    }

    static func summarySegment(
        _ text: String,
        color: String,
        ansiEnabled: Bool
    ) -> String {
        ansiEnabled ? "\(color)\(text)\(TerminalStyle.reset)" : text
    }
}
