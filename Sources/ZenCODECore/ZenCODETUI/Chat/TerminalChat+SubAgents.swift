//
//  TerminalChat+SubAgents.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

extension TerminalChat {
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

    public func startSubAgentOverviewRefreshLoop() {
        guard subAgentOverviewRefreshTask == nil else {
            return
        }

        subAgentOverviewRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                guard let self else {
                    return
                }
                await self.renderSubAgentOverview(force: false)
            }
        }
    }

    public func stopSubAgentOverviewRefreshLoop() {
        subAgentOverviewRefreshTask?.cancel()
        subAgentOverviewRefreshTask = nil
    }

    public static func renderSubAgentOverview(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> String {
        var lines = [renderSubAgentSummary(snapshots)]

        if snapshots.isEmpty {
            lines.append("No delegated sub-agents.")
            return renderSubAgentOverviewLines(lines)
        }

        for (index, snapshot) in snapshots.enumerated() {
            if index > 0 {
                lines.append("")
            }
            lines.append(renderSubAgentHeader(snapshot))
            if !snapshot.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("\(dimText("role:")) \(snapshot.role)")
            }
            if let model = renderSubAgentModel(snapshot) {
                lines.append(model)
            }
            if let activity = renderSubAgentActivity(snapshot) {
                lines.append(activity)
            }
            if let detail = renderSubAgentDetail(snapshot) {
                lines.append(detail)
            }
            lines.append(dimText("id: \(snapshot.id)"))
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
        return "\(dimText("model:")) \(truncatedInline(text, limit: 180))"
    }

    private static func renderSubAgentActivity(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String? {
        if let currentToolName = snapshot.currentToolName?.nilIfBlank {
            let label = colorText("▸ tool:", code: "\u{1B}[38;5;208m")
            return "\(label) \(truncatedInline(currentToolName, limit: 180))"
        }
        guard let activity = snapshot.currentActivity?.nilIfBlank else {
            return nil
        }
        let label = colorText("▸ activity:", code: "\u{1B}[38;5;208m")
        return "\(label) \(truncatedInline(activity, limit: 180))"
    }

    private static func renderSubAgentDetail(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String? {
        if let latestError = snapshot.latestError?.nilIfBlank {
            let label = colorText("✗ error:", code: "\u{1B}[31m")
            return "\(label) \(truncatedInline(latestError, limit: 180))"
        }

        guard let latestOutput = snapshot.latestOutput?.nilIfBlank else {
            if snapshot.pending {
                let label = colorText("▸ working:", code: "\u{1B}[38;5;208m")
                return "\(label) \(dimText("pending response"))"
            }
            return nil
        }

        if snapshot.pending {
            let label = colorText("▸ working:", code: "\u{1B}[38;5;208m")
            return "\(label) \(truncatedInline(latestOutput, limit: 180))"
        }
        let label = colorText("✓ result:", code: "\u{1B}[32m")
        return "\(label) \(truncatedInline(latestOutput, limit: 180))"
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

    private static func renderSubAgentOverviewLines(_ lines: [String]) -> String {
        let columns = terminalColumnCount()
        let horizontalInset = terminalBoxHorizontalInset(columns: columns)
        let contentWidth = max(40, min(columns - horizontalInset, 180))
        let linePrefix = String(repeating: " ", count: horizontalInset)
        let orange = "\u{1B}[38;5;208m"
        let dim = "\u{1B}[90m"
        let reset = "\u{1B}[0m"
        let title = AgentOutput.standardErrorIsTerminal
            ? "👥 \(orange)Sub-Agents\(reset)"
            : "👥 Sub-Agents"

        var output = ["\(linePrefix)\(title)"]
        for (index, line) in lines.enumerated() {
            let prefix: String
            if index == 0 {
                prefix = AgentOutput.standardErrorIsTerminal ? "\(dim)  \(reset)" : "  "
            } else {
                prefix = "  "
            }
            for wrappedLine in fitInline(line, width: contentWidth - 2)
                .components(separatedBy: "\n") {
                output.append("\(linePrefix)\(prefix)\(wrappedLine)")
            }
        }
        return output.joined(separator: "\n")
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
                "\(snapshot.updatedAt.timeIntervalSince1970)",
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
