//
//  TerminalChat+SubAgents.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

extension TerminalChat {
    private struct SubAgentOverviewLine {
        let text: String
        let indentation: Int
        let maxWrappedLines: Int
        let dimPrefix: Bool

        static func summary(_ text: String) -> SubAgentOverviewLine {
            SubAgentOverviewLine(
                text: text,
                indentation: 2,
                maxWrappedLines: 3,
                dimPrefix: true
            )
        }

        static func regular(
            _ text: String,
            maxWrappedLines: Int = 3
        ) -> SubAgentOverviewLine {
            SubAgentOverviewLine(
                text: text,
                indentation: 2,
                maxWrappedLines: maxWrappedLines,
                dimPrefix: false
            )
        }

        static func current(
            _ text: String,
            maxWrappedLines: Int = 6
        ) -> SubAgentOverviewLine {
            SubAgentOverviewLine(
                text: text,
                indentation: 4,
                maxWrappedLines: maxWrappedLines,
                dimPrefix: false
            )
        }
    }

    public func publishSubAgentOverviewIfChanged(
        relatedToolName: String? = nil
    ) async {
        if let relatedToolName,
           !DirectSubAgentRuntime.isSubAgentToolName(relatedToolName) {
            return
        }

        await renderSubAgentOverview(force: false)
    }

    public func renderSubAgentOverview(
        force: Bool,
        rememberSignature: Bool = true
    ) async {
        let snapshots = await sessionRunner.subAgentSnapshots()
        guard force || !snapshots.isEmpty else {
            return
        }
        let signature = Self.subAgentOverviewSignature(snapshots)
        guard force || signature != lastRenderedSubAgentOverviewSignature else {
            return
        }

        if rememberSignature {
            lastRenderedSubAgentOverviewSignature = signature
        }

        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        writeChatError(
            Self.renderSubAgentOverview(snapshots) + "\n\n"
        )
    }

    public static func renderSubAgentOverview(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> String {
        var lines = [SubAgentOverviewLine.summary(renderSubAgentSummary(snapshots))]

        if snapshots.isEmpty {
            lines.append(.regular("No delegated sub-agents."))
            return renderSubAgentOverviewLines(lines)
        }

        for (index, snapshot) in snapshots.enumerated() {
            if index > 0 {
                lines.append(.regular("", maxWrappedLines: 1))
            }
            lines.append(.regular(renderSubAgentHeader(snapshot)))
            if !snapshot.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(.regular("\(dimText("role:")) \(snapshot.role)"))
            }
            if let taskID = snapshot.taskID?.nilIfBlank {
                var taskText = "\(dimText("task:")) \(inlineText(taskID))"
                if let attempt = snapshot.taskAttemptOrdinal {
                    taskText += " · \(dimText("attempt:")) \(attempt)"
                }
                lines.append(.regular(taskText, maxWrappedLines: 2))
            }
            if let model = renderSubAgentModel(snapshot) {
                lines.append(.regular(model))
            }
            let activityLines = renderSubAgentActivityLines(snapshot)
            if !activityLines.isEmpty {
                lines.append(contentsOf: activityLines)
            }
            if let detail = renderSubAgentDetail(
                snapshot,
                hasCurrentActivity: !activityLines.isEmpty
            ) {
                lines.append(detail)
            }
            lines.append(.regular(dimText("id: \(snapshot.id)"), maxWrappedLines: 1))
        }

        return renderSubAgentOverviewLines(lines)
    }

    private static func renderSubAgentSummary(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> String {
        let activeCount = snapshots.filter(\.pending).count
        let completedCount = snapshots.filter { snapshot in
            snapshot.status == .idle && snapshot.latestOutput?.nilIfBlank != nil
        }.count
        let failedCount = snapshots.filter { $0.status == .failed }.count
        let closedCount = snapshots.filter { $0.status == .closed }.count

        var segments = ["\(snapshots.count) total"]
        if activeCount > 0 {
            segments.append(colorText("▸ \(activeCount) active", code: "\u{1B}[38;5;208m"))
        }
        if completedCount > 0 {
            segments.append(colorText("✓ \(completedCount) completed", code: "\u{1B}[32m"))
        }
        if failedCount > 0 {
            segments.append(colorText("✗ \(failedCount) failed", code: "\u{1B}[31m"))
        }
        if closedCount > 0 {
            segments.append(dimText("· \(closedCount) closed"))
        }
        return segments.joined(separator: " ")
    }

    private static func renderSubAgentHeader(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        let age = relativeAgeText(since: snapshot.updatedAt)
        let name = snapshot.name.nilIfBlank ?? snapshot.id
        let marker = coloredStatusMarker(for: snapshot)
        let badge = statusBadge(for: snapshot)
        let meta = dimText("\(snapshot.isolationMode.rawValue) · updated \(age)")
        return "\(marker) \(boldText(name))  \(badge)  \(meta)"
    }

    private static func renderSubAgentModel(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String? {
        guard let modelID = snapshot.modelID?.nilIfBlank else {
            return nil
        }
        var text = modelID
        if let runtime = snapshot.modelRuntime?.nilIfBlank {
            text += " · \(runtime)"
        }
        return "\(dimText("model:")) \(inlineText(text))"
    }

    private static func renderSubAgentActivityLines(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> [SubAgentOverviewLine] {
        let currentToolName = snapshot.currentToolName?.nilIfBlank
        let currentActivity = snapshot.currentActivity?.nilIfBlank
        let latestContentPreview = snapshot.latestContentPreview?.nilIfBlank
        guard currentToolName != nil || currentActivity != nil || latestContentPreview != nil else {
            return []
        }

        let label = colorText("▸ current:", code: "\u{1B}[38;5;208m")
        var lines = [SubAgentOverviewLine.regular(label, maxWrappedLines: 1)]

        if let currentToolName {
            lines.append(
                .current("\(dimText("tool:")) \(inlineText(currentToolName))", maxWrappedLines: 2)
            )
        }

        if let currentActivity,
           !isToolOnlyActivity(currentActivity, currentToolName: currentToolName) {
            lines.append(
                .current("\(dimText("activity:")) \(inlineText(currentActivity))")
            )
        }

        if let latestContentPreview,
           !hasSameInlineText(latestContentPreview, as: currentActivity) {
            lines.append(
                .current("\(dimText("preview:")) \(inlineText(latestContentPreview))")
            )
        }

        return lines
    }

    private static func renderSubAgentDetail(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        hasCurrentActivity: Bool
    ) -> SubAgentOverviewLine? {
        if let latestError = snapshot.latestError?.nilIfBlank {
            let label = colorText("✗ error:", code: "\u{1B}[31m")
            return .regular("\(label) \(inlineText(latestError))")
        }

        guard let latestOutput = snapshot.latestOutput?.nilIfBlank else {
            if snapshot.pending && !hasCurrentActivity {
                let label = colorText("▸ working:", code: "\u{1B}[38;5;208m")
                return .regular("\(label) \(dimText("pending response"))")
            }
            return nil
        }

        if snapshot.pending {
            let label = colorText("▸ working:", code: "\u{1B}[38;5;208m")
            return .regular("\(label) \(inlineText(latestOutput))")
        }
        let label = colorText("✓ result:", code: "\u{1B}[32m")
        return .regular("\(label) \(inlineText(latestOutput))")
    }

    private static func isToolOnlyActivity(
        _ activity: String,
        currentToolName: String?
    ) -> Bool {
        guard let currentToolName else {
            return false
        }
        return inlineText(activity) == "running \(currentToolName)"
    }

    private static func hasSameInlineText(
        _ lhs: String,
        as rhs: String?
    ) -> Bool {
        guard let rhs else {
            return false
        }
        return inlineText(lhs) == inlineText(rhs)
    }

    private static func statusBadge(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        let text = displayStatus(for: snapshot).uppercased()
        guard AgentOutput.standardErrorIsTerminal else {
            return "[\(text)]"
        }

        let color: String
        switch snapshot.status {
        case .queued:
            color = "\u{1B}[33m"
        case .running:
            color = "\u{1B}[38;5;208m"
        case .idle:
            color = snapshot.latestOutput?.nilIfBlank == nil
                ? "\u{1B}[90m"
                : "\u{1B}[32m"
        case .failed:
            color = "\u{1B}[31m"
        case .closed:
            color = "\u{1B}[90m"
        }
        return "\(color)[\(text)]\u{1B}[0m"
    }

    private static func boldText(_ text: String) -> String {
        AgentOutput.standardErrorIsTerminal ? "\u{1B}[1m\(text)\u{1B}[0m" : text
    }

    private static func dimText(_ text: String) -> String {
        AgentOutput.standardErrorIsTerminal ? "\u{1B}[90m\(text)\u{1B}[0m" : text
    }

    private static func colorText(_ text: String, code: String) -> String {
        AgentOutput.standardErrorIsTerminal ? "\(code)\(text)\u{1B}[0m" : text
    }

    private static func displayStatus(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        if snapshot.status == .idle,
           snapshot.latestOutput?.nilIfBlank != nil {
            return "completed"
        }
        return snapshot.status.rawValue
    }

    private static func coloredStatusMarker(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        let marker = "●"
        guard AgentOutput.standardErrorIsTerminal else {
            return marker
        }

        let color: String
        switch snapshot.status {
        case .queued:
            color = "\u{1B}[33m"
        case .running:
            color = "\u{1B}[38;5;208m"
        case .idle:
            color = snapshot.latestOutput?.nilIfBlank == nil
                ? "\u{1B}[90m"
                : "\u{1B}[32m"
        case .failed:
            color = "\u{1B}[31m"
        case .closed:
            color = "\u{1B}[90m"
        }
        return "\(color)\(marker)\u{1B}[0m"
    }

    private static func renderSubAgentOverviewLines(_ lines: [SubAgentOverviewLine]) -> String {
        let columns = terminalColumnCount()
        let horizontalInset = terminalBoxHorizontalInset(columns: columns)
        let contentWidth = max(40, columns - horizontalInset)
        let linePrefix = String(repeating: " ", count: horizontalInset)
        let orange = "\u{1B}[38;5;208m"
        let dim = "\u{1B}[90m"
        let reset = "\u{1B}[0m"
        let title = AgentOutput.standardErrorIsTerminal
            ? "👥 \(orange)Sub-Agents\(reset)"
            : "👥 Sub-Agents"

        var output = ["\(linePrefix)\(title)"]
        for line in lines {
            let indentation = max(0, line.indentation)
            let indentationText = String(repeating: " ", count: indentation)
            let prefix = line.dimPrefix && AgentOutput.standardErrorIsTerminal
                ? "\(dim)\(indentationText)\(reset)"
                : indentationText
            let wrapWidth = max(1, contentWidth - indentation)
            var wrapped = fitInline(line.text, width: wrapWidth)
                .components(separatedBy: "\n")
            let maxWrappedLines = max(1, line.maxWrappedLines)
            if wrapped.count > maxWrappedLines {
                wrapped = Array(wrapped.prefix(maxWrappedLines))
                let lastIndex = maxWrappedLines - 1
                let ellipsis = AgentOutput.standardErrorIsTerminal ? "\(reset)…" : "…"
                wrapped[lastIndex] += ellipsis
            }
            for wrappedLine in wrapped {
                output.append("\(linePrefix)\(prefix)\(wrappedLine)")
            }
        }
        return "\n\(output.joined(separator: "\n"))\n"
    }

    private static func subAgentOverviewSignature(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> String {
        snapshots.map { snapshot in
            [
                snapshot.id,
                snapshot.name,
                snapshot.role,
                snapshot.isolationMode.rawValue,
                snapshot.status.rawValue,
                snapshot.pending ? "pending" : "idle",
                snapshot.modelID?.nilIfBlank ?? "",
                snapshot.modelRuntime?.nilIfBlank ?? "",
                snapshot.currentActivity?.nilIfBlank ?? "",
                snapshot.currentToolName?.nilIfBlank ?? "",
                snapshot.latestContentPreview?.nilIfBlank ?? "",
                snapshot.latestOutput?.nilIfBlank ?? "",
                snapshot.latestError?.nilIfBlank ?? ""
            ].joined(separator: "\u{1F}")
        }
        .joined(separator: "\u{1E}")
    }

    private static func relativeAgeText(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date).rounded()))
        if seconds < 60 {
            return "\(seconds)s ago"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }

        return "\(hours / 24)d ago"
    }
}
