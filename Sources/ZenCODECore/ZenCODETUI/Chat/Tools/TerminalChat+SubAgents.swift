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
        /// Dynamic agent activity is most useful at its trailing edge: thought
        /// and response streams append new text, so the first wrapped rows soon
        /// become stale.
        let showsLatestWrappedLines: Bool

        static func summary(_ text: String) -> SubAgentOverviewLine {
            SubAgentOverviewLine(
                text: text,
                indentation: 3,
                maxWrappedLines: 3,
                dimPrefix: true,
                showsLatestWrappedLines: false
            )
        }

        static func regular(
            _ text: String,
            maxWrappedLines: Int = 3
        ) -> SubAgentOverviewLine {
            SubAgentOverviewLine(
                text: text,
                indentation: 3,
                maxWrappedLines: maxWrappedLines,
                dimPrefix: false,
                showsLatestWrappedLines: false
            )
        }

        static func latest(
            _ text: String,
            maxWrappedLines: Int = 3
        ) -> SubAgentOverviewLine {
            SubAgentOverviewLine(
                text: text,
                indentation: 3,
                maxWrappedLines: maxWrappedLines,
                dimPrefix: false,
                showsLatestWrappedLines: true
            )
        }

        static func current(
            _ text: String,
            maxWrappedLines: Int = 3
        ) -> SubAgentOverviewLine {
            SubAgentOverviewLine(
                text: text,
                indentation: 6,
                maxWrappedLines: maxWrappedLines,
                dimPrefix: false,
                showsLatestWrappedLines: true
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

    // MARK: - Live refresh during agent.* tool calls

    /// Starts a periodic refresh of the sub-agent overview so progress
    /// (current activity and tool) remains visible while a blocking `agent.*`
    /// tool call such as `agent.wait` is executing.
    ///
    /// Each tick reuses the existing signature-deduped publication path
    /// (`renderSubAgentOverview(force:)`): when the snapshot signature has not
    /// changed since the last render the coordinator short-circuits and no
    /// output is written.
    ///
    /// Idempotent — calling it while a task is already running is a no-op.
    ///
    /// - Note: ``subAgentOverviewRefreshTask`` is accessed only from the serial
    ///   event-delivery context: ``AgentCoreSessionRunner`` delivers ``onEvent``
    ///   callbacks sequentially (one at a time via cooperative await), which
    ///   is the expected contract for all session backends. The guard-and-assign
    ///   in `start` and the read-and-nil in `stop` are therefore never
    ///   concurrent. The refresh task itself never touches this property.
    func startSubAgentOverviewRefreshIfNeeded() {
        guard subAgentOverviewRefreshTask == nil else { return }
        let interval = subAgentOverviewRefreshInterval
        let tickHook = onSubAgentOverviewTick
        subAgentOverviewRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if let tickHook {
                    await tickHook()
                }
                guard !Task.isCancelled, let self else { return }
                await self.renderSubAgentOverview(force: false)
            }
        }
    }

    /// Stops the periodic refresh and **drains** the running task before
    /// publishing a final snapshot.
    ///
    /// The drain (`await task.value`) guarantees that no in-flight tick can
    /// publish a stale overview after this method returns: a tick suspended in
    /// `subAgentSnapshots()` or the coordinator actor completes (or exits via
    /// cancellation) before the final render runs, eliminating the
    /// publish-A-after-B race that a bare `cancel()` would leave open.
    ///
    /// Idempotent — safe to call when no task is running.
    func stopSubAgentOverviewRefresh() async {
        let task = subAgentOverviewRefreshTask
        subAgentOverviewRefreshTask = nil
        task?.cancel()
        await task?.value
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
        let resolver = subAgentModelTitleResolver()
        let overview = Self.renderSubAgentOverview(
            snapshots,
            modelTitleResolver: resolver
        ) + "\n\n"
        _ = await renderCoordinator.renderSubAgentOverview(
            signature: signature,
            text: overview,
            force: force,
            rememberSignature: rememberSignature
        )
    }

    public static func renderSubAgentOverview(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        modelTitleResolver: (String) -> String = { $0 }
    ) -> String {
        var lines = [SubAgentOverviewLine.summary(renderSubAgentSummary(snapshots))]

        if snapshots.isEmpty {
            lines.append(.regular("No delegated sub-agents."))
            return renderSubAgentOverviewLines(lines)
        }

        for snapshot in snapshots {
            lines.append(.regular(renderSubAgentHeader(snapshot)))
            lines.append(.regular(dimText("id: \(snapshot.id)"), maxWrappedLines: 1))
            if !snapshot.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(.regular("\(dimText("role:")) \(snapshot.role)"))
            }
            if let profileName = snapshot.profileName?.nilIfBlank {
                lines.append(.regular("\(dimText("agent:")) \(profileName)"))
            }
            if let taskID = snapshot.taskID?.nilIfBlank {
                var taskText = "\(dimText("task:")) \(inlineText(taskID))"
                if let attempt = snapshot.taskAttemptOrdinal {
                    taskText += " · \(dimText("attempt:")) \(attempt)"
                }
                lines.append(.regular(taskText, maxWrappedLines: 2))
            }
            if let model = renderSubAgentModel(
                snapshot,
                modelTitleResolver: modelTitleResolver
            ) {
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
        let name = snapshot.name.nilIfBlank ?? snapshot.id
        let marker = coloredStatusMarker(for: snapshot)
        let badge = statusBadge(for: snapshot)
        return "\(marker) \(boldText(name))  \(badge)"
    }

    private static func renderSubAgentModel(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        modelTitleResolver: (String) -> String
    ) -> String? {
        guard let modelID = snapshot.modelID?.nilIfBlank else {
            return nil
        }
        var text = modelTitleResolver(modelID)
        if let runtime = snapshot.modelRuntime?.nilIfBlank {
            text += " · \(runtime)"
        }
        return "\(dimText("model:")) \(inlineText(text))"
    }

    /// Builds the model title resolver used by the instance overview renderer.
    private func subAgentModelTitleResolver() -> (String) -> String {
        { modelID in
            Self.resolvedSubAgentModelTitle(
                for: modelID,
                hostedModel: self.hostedModelManifest(for: modelID)
            )
        }
    }

    /// Resolves a sub-agent model identifier into a human-readable title.
    ///
    /// Resolution order:
    /// 1. Hosted model manifest (from the active configuration) →
    ///    `AgentModelCatalogPresentation.modelTitle(for:)`, which includes the
    ///    provider when it distinguishes the model.
    /// 2. Internal `remoteapi:<uuid>:<modelID>` identifier that did not resolve
    ///    against the catalog → the significant model name, with the internal
    ///    provider UUID prefix removed.
    /// 3. Any other identifier → returned unchanged.
    public static func resolvedSubAgentModelTitle(
        for modelID: String,
        hostedModel: AgentSettingsModelManifest? = nil
    ) -> String {
        if let hostedModel {
            return AgentModelCatalogPresentation.modelTitle(for: hostedModel)
        }
        if let stripped = subAgentModelNameStrippingRemoteAPIPrefix(modelID) {
            return stripped
        }
        return modelID
    }

    /// Returns the significant model name when `modelID` is an internal
    /// `remoteapi:<uuid>:<modelName>` identifier, otherwise `nil`.
    public static func subAgentModelNameStrippingRemoteAPIPrefix(
        _ modelID: String
    ) -> String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("remoteapi:") else {
            return nil
        }
        let afterPrefix = trimmed.dropFirst("remoteapi:".count)
        guard !afterPrefix.isEmpty else {
            return nil
        }
        guard let colonRange = afterPrefix.range(of: ":") else {
            return nil
        }
        let providerSegment = afterPrefix[afterPrefix.startIndex..<colonRange.lowerBound]
        let modelName = afterPrefix[colonRange.upperBound...]
        guard UUID(uuidString: String(providerSegment)) != nil,
              !modelName.isEmpty else {
            return nil
        }
        return String(modelName)
    }

    private static func renderSubAgentActivityLines(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> [SubAgentOverviewLine] {
        let currentToolName = snapshot.currentToolName?.nilIfBlank
        let currentActivity = snapshot.currentActivity?.nilIfBlank
        guard currentToolName != nil || currentActivity != nil else {
            return []
        }

        let label = colorText("▸ current:", code: "\u{1B}[38;5;208m")
        var lines = [SubAgentOverviewLine.regular(label, maxWrappedLines: 1)]

        if let currentToolName {
            lines.append(
                .current("\(dimText("tool:")) \(inlineText(currentToolName))")
            )
        }

        if let currentActivity,
           !isToolOnlyActivity(currentActivity, currentToolName: currentToolName) {
            lines.append(
                .current("\(dimText("activity:")) \(inlineText(currentActivity))")
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
            return .latest("\(label) \(inlineText(latestError))")
        }

        guard let latestOutput = snapshot.latestOutput?.nilIfBlank else {
            if snapshot.pending && !hasCurrentActivity {
                let label = colorText("▸ working:", code: "\u{1B}[38;5;208m")
                return .latest("\(label) \(dimText("pending response"))")
            }
            return nil
        }

        if snapshot.pending {
            let label = colorText("▸ working:", code: "\u{1B}[38;5;208m")
            return .latest("\(label) \(inlineText(latestOutput))")
        }
        let label = colorText("✓ result:", code: "\u{1B}[32m")
        return .latest("\(label) \(inlineText(latestOutput))")
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
            ? "👥 \(orange)Sub-Agents:\(reset)"
            : "👥 Sub-Agents:"

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
                let ellipsis = AgentOutput.standardErrorIsTerminal ? "\(reset)…" : "…"
                if line.showsLatestWrappedLines {
                    wrapped = Array(wrapped.suffix(maxWrappedLines))
                    wrapped[0] = "\(ellipsis)\(wrapped[0])"
                } else {
                    wrapped = Array(wrapped.prefix(maxWrappedLines))
                    let lastIndex = maxWrappedLines - 1
                    wrapped[lastIndex] += ellipsis
                }
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
                snapshot.profileName?.nilIfBlank ?? "",
                snapshot.status.rawValue,
                snapshot.pending ? "pending" : "idle",
                snapshot.modelID?.nilIfBlank ?? "",
                snapshot.modelRuntime?.nilIfBlank ?? "",
                snapshot.currentActivity?.nilIfBlank ?? "",
                snapshot.currentToolName?.nilIfBlank ?? "",
                snapshot.latestOutput?.nilIfBlank ?? "",
                snapshot.latestError?.nilIfBlank ?? ""
            ].joined(separator: "\u{1F}")
        }
        .joined(separator: "\u{1E}")
    }
}
