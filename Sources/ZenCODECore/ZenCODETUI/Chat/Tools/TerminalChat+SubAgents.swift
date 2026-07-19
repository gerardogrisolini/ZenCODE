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
                indentation: 3,
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
                indentation: 3,
                maxWrappedLines: maxWrappedLines,
                dimPrefix: false
            )
        }

        /// Complete model messages are emitted only after their delta stream has
        /// reached a semantic boundary. Do not tail-truncate them: the update is
        /// published once, with the whole message kept together.
        static func complete(
            _ text: String,
            indentation: Int = 3
        ) -> SubAgentOverviewLine {
            SubAgentOverviewLine(
                text: text,
                indentation: indentation,
                maxWrappedLines: .max,
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
            modelTitleResolver: resolver,
            includesFinalResponses: false
        ) + "\n\n"
        let responses = Self.subAgentMarkdownResponses(snapshots)
        _ = await renderCoordinator.renderSubAgentOverview(
            signature: signature,
            text: overview,
            responses: responses,
            force: force,
            rememberSignature: rememberSignature
        )
    }

    public static func renderSubAgentOverview(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        modelTitleResolver: (String) -> String = { $0 }
    ) -> String {
        renderSubAgentOverview(
            snapshots,
            modelTitleResolver: modelTitleResolver,
            includesFinalResponses: true
        )
    }

    private static func renderSubAgentOverview(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        modelTitleResolver: (String) -> String,
        includesFinalResponses: Bool
    ) -> String {
        var lines = [SubAgentOverviewLine.summary(renderSubAgentSummary(snapshots))]

        if snapshots.isEmpty {
            lines.append(.regular("No delegated sub-agents."))
            return renderSubAgentOverviewLines(lines)
        }

        for snapshot in snapshots {
            lines.append(.regular("", maxWrappedLines: 1))
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
                includesFinalResponse: includesFinalResponses
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
        return "\(dimText("model:")) \(inlineText(modelTitleResolver(modelID)))"
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
        var lines: [SubAgentOverviewLine] = []

        if let currentActivity {
            if currentActivity == "🤔 Thinking…" {
                lines.append(.regular(currentActivity, maxWrappedLines: 1))
            } else {
                lines.append(.complete("💬 \(inlineText(currentActivity))"))
            }
        }

        if let currentToolName {
            let target = snapshot.currentToolTarget?.nilIfBlank
            let title = target.map { "\(currentToolName) \($0)" } ?? currentToolName
            lines.append(.complete("🛠️  \(inlineText(title))"))
        }

        if lines.isEmpty, snapshot.pending {
            lines.append(.regular("🤔 Thinking…", maxWrappedLines: 1))
        }

        return lines
    }

    private static func renderSubAgentDetail(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        includesFinalResponse: Bool
    ) -> SubAgentOverviewLine? {
        if let latestError = snapshot.latestError?.nilIfBlank {
            return .complete("❌ \(inlineText(latestError))", indentation: 3)
        }

        guard includesFinalResponse,
              !snapshot.pending,
              let latestOutput = snapshot.latestContentPreview?.nilIfBlank
                ?? snapshot.latestOutput?.nilIfBlank else {
            return nil
        }
        return .complete("✅ \(inlineText(latestOutput))", indentation: 3)
    }

    /// Extracts completed model responses from the snapshot presentation. The
    /// surrounding overview remains pre-rendered terminal text, while each
    /// response stays as source Markdown so the coordinator can format it with
    /// the same renderer used for normal assistant messages.
    static func subAgentMarkdownResponses(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> [TerminalChatRenderCoordinator.SubAgentMarkdownResponse] {
        snapshots.compactMap { snapshot in
            guard !snapshot.pending,
                  snapshot.latestError?.nilIfBlank == nil,
                  let output = snapshot.latestContentPreview?.nilIfBlank
                    ?? snapshot.latestOutput?.nilIfBlank else {
                return nil
            }
            let name = snapshot.name.nilIfBlank ?? snapshot.id
            return TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
                token: subAgentResponseToken(snapshot: snapshot, output: output),
                heading: "   ✅ Response from \(inlineText(name)):\n",
                markdown: output
            )
        }
    }

    /// Produces a compact deterministic identity for one completion. Runtime
    /// snapshots carry a monotonic completion revision, so metadata-only changes
    /// (for example closing an agent) cannot make an old response appear new.
    /// The digest is a fallback for manually constructed legacy snapshots.
    private static func subAgentResponseToken(
        snapshot: DirectSubAgentRuntime.AgentSnapshot,
        output: String
    ) -> String {
        if snapshot.latestOutputRevision > 0 {
            return [snapshot.id, String(snapshot.latestOutputRevision)]
                .joined(separator: "\u{1F}")
        }

        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in output.utf8 {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return [snapshot.id, String(digest, radix: 16)]
            .joined(separator: "\u{1F}")
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
                wrapped = Array(wrapped.prefix(maxWrappedLines))
                let lastIndex = maxWrappedLines - 1
                wrapped[lastIndex] += ellipsis
            }
            for wrappedLine in wrapped {
                output.append("\(linePrefix)\(prefix)\(wrappedLine)")
            }
        }
        return "\n\(output.joined(separator: "\n"))\n"
    }

    static func subAgentOverviewSignature(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> String {
        snapshots.map { snapshot in
            let hasResponse = snapshot.latestContentPreview?.nilIfBlank != nil
                || snapshot.latestOutput?.nilIfBlank != nil
            return [
                snapshot.id,
                snapshot.name,
                snapshot.role,
                snapshot.profileName?.nilIfBlank ?? "",
                snapshot.status.rawValue,
                snapshot.pending ? "pending" : "idle",
                snapshot.modelID?.nilIfBlank ?? "",
                snapshot.currentActivity?.nilIfBlank ?? "",
                snapshot.currentToolName?.nilIfBlank ?? "",
                snapshot.currentToolTarget?.nilIfBlank ?? "",
                hasResponse ? "response" : "",
                snapshot.latestError?.nilIfBlank ?? ""
            ].joined(separator: "\u{1F}")
        }
        .joined(separator: "\u{1E}")
    }
}
