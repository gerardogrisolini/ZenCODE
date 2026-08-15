//
//  TerminalChat+SubAgents.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    private struct SubAgentOverviewLine {
        let text: String
        let indentation: Int
        let maxWrappedLines: Int
        let dimPrefix: Bool
        let clipsOverflowWithoutEllipsis: Bool

        static func summary(_ text: String) -> SubAgentOverviewLine {
            SubAgentOverviewLine(
                text: text,
                indentation: 3,
                maxWrappedLines: 3,
                dimPrefix: true,
                clipsOverflowWithoutEllipsis: false
            )
        }

        static func regular(
            _ text: String,
            maxWrappedLines: Int = 3,
            clipsOverflowWithoutEllipsis: Bool = false
        ) -> SubAgentOverviewLine {
            SubAgentOverviewLine(
                text: text,
                indentation: 3,
                maxWrappedLines: maxWrappedLines,
                dimPrefix: false,
                clipsOverflowWithoutEllipsis: clipsOverflowWithoutEllipsis
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
                dimPrefix: false,
                clipsOverflowWithoutEllipsis: false
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
        subAgentOverviewRefreshTask = Task(name: "ZenCODE.TUI.sub-agent-overview-refresh") { [weak self] in
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
        // Reserve before awaiting the runtime snapshot: a later callback must
        // fence this publication if this snapshot returns after it.
        let publicationRevision = await renderCoordinator.beginOverviewPublication(.subAgents)
        let snapshots = await sessionRunner.subAgentSnapshots()
        await refreshStatusBarGitStatusSummaryForCompletedSubAgents(snapshots)
        guard force || !snapshots.isEmpty else {
            return
        }
        let signature = Self.subAgentOverviewSignature(snapshots)
        // The runtime marks the current wave while producing this snapshot.
        // The overview can also contain older standby/reused agents (or agents
        // active through shared chat), so array order is not a valid authority.
        let overviewBatchID = snapshots
            .first(where: \.isInCurrentOverviewWave)?
            .overviewBatchID?
            .uuidString
        let resolver = subAgentModelTitleResolver()
        let maximumInPlaceRows = await statusBar.scrollableOutputRowCapacity()
        let overview = Self.renderSubAgentOverview(
            snapshots,
            modelTitleResolver: resolver,
            includesFinalResponses: false,
            rowBudget: Self.subAgentOverviewRowBudget(
                forInPlaceRows: maximumInPlaceRows
            )
        ) + "\n\n"
        let responses = Self.subAgentMarkdownResponses(snapshots)
        _ = await renderCoordinator.renderSubAgentOverview(
            signature: signature,
            text: overview,
            responses: responses,
            revision: publicationRevision,
            force: force,
            rememberSignature: rememberSignature,
            overviewBatchID: overviewBatchID,
            maximumInPlaceRows: maximumInPlaceRows
        )
    }

    public nonisolated static func renderSubAgentOverview(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        modelTitleResolver: (String) -> String = { $0 }
    ) -> String {
        renderSubAgentOverview(
            snapshots,
            modelTitleResolver: modelTitleResolver,
            includesFinalResponses: true
        )
    }

    /// Presentation density of the sub-agent section.
    ///
    /// The live section is replaced in place on every refresh, which is only
    /// possible while it fits the terminal's scrolling region. When many agents
    /// run at once the full presentation no longer fits: without a denser
    /// variant the section would lose its rewrite slot and every refresh would
    /// append another full copy to the transcript instead of overwriting the
    /// previous one.
    private enum SubAgentOverviewDensity: CaseIterable {
        /// Every metadata line, with multi-row activity and detail text.
        case full
        /// Status header, agent/model identity, and capped activity lines.
        case compact
        /// Status header plus a single activity line, without separators.
        case dense
        /// One row per agent: status header with an inline activity fragment.
        case inline

        var includesSeparators: Bool {
            switch self {
            case .full, .compact:
                return true
            case .dense, .inline:
                return false
            }
        }

        var includesMetadata: Bool {
            self == .full
        }

        /// Rows a single activity or detail entry may occupy.
        var maximumEntryRows: Int {
            self == .full ? .max : 1
        }

        /// Activity lines kept per agent, or `nil` when all are kept.
        var activityLineLimit: Int? {
            switch self {
            case .full:
                return nil
            case .compact:
                return 2
            case .dense, .inline:
                return 1
            }
        }
    }

    /// Physical rows the surrounding chat output adds to the section: the
    /// leading blank row, the trailing blank row kept by the `"\n\n"`
    /// terminator, and one spare row so a section sized exactly like the
    /// scrolling region still leaves the cursor inside it.
    private nonisolated static let subAgentOverviewReservedRows = 3

    /// Converts the rows available for an in-place replacement into the row
    /// budget the section content may occupy. `nil` (no terminal, or no started
    /// status bar) leaves the presentation unbounded.
    nonisolated static func subAgentOverviewRowBudget(
        forInPlaceRows rows: Int?
    ) -> Int? {
        guard let rows else {
            return nil
        }
        return max(1, rows - subAgentOverviewReservedRows)
    }

    private nonisolated static func renderSubAgentOverview(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        modelTitleResolver: (String) -> String,
        includesFinalResponses: Bool,
        rowBudget: Int? = nil
    ) -> String {
        guard !snapshots.isEmpty else {
            return renderSubAgentOverviewLines([
                .summary(renderSubAgentSummary(snapshots)),
                .regular("No delegated sub-agents.")
            ])
        }

        // Step down through the density variants until the section fits the
        // rows it may replace in place. An unbounded budget always keeps the
        // richest presentation.
        var rows: [String] = []
        for density in SubAgentOverviewDensity.allCases {
            rows = subAgentOverviewRows(
                subAgentOverviewLines(
                    snapshots,
                    modelTitleResolver: modelTitleResolver,
                    includesFinalResponses: includesFinalResponses,
                    density: density
                )
            )
            guard let rowBudget, rows.count > rowBudget else {
                break
            }
        }

        if let rowBudget {
            rows = elidedSubAgentOverviewRows(rows, rowBudget: rowBudget)
        }
        return joinedSubAgentOverviewRows(rows)
    }

    /// Physical rows the live section would occupy for `rowBudget`, exposed so
    /// tests can assert the in-place invariants (row count and visible width)
    /// without driving a terminal.
    nonisolated static func renderSubAgentOverviewRowsForTesting(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        rowBudget: Int?
    ) -> [String] {
        let rendered = renderSubAgentOverview(
            snapshots,
            modelTitleResolver: { $0 },
            includesFinalResponses: false,
            rowBudget: rowBudget
        )
        return rendered
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
    }

    private nonisolated static func subAgentOverviewLines(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        modelTitleResolver: (String) -> String,
        includesFinalResponses: Bool,
        density: SubAgentOverviewDensity
    ) -> [SubAgentOverviewLine] {
        var lines = [SubAgentOverviewLine.summary(renderSubAgentSummary(snapshots))]

        for snapshot in snapshots {
            if density.includesSeparators {
                lines.append(.regular("", maxWrappedLines: 1))
            }

            if density == .inline {
                lines.append(
                    .regular(renderSubAgentInlineEntry(snapshot), maxWrappedLines: 1)
                )
                continue
            }

            lines.append(.regular(renderSubAgentHeader(snapshot)))
            if density.includesMetadata {
                lines.append(
                    .regular(
                        subAgentMetadataText(label: "id:", value: snapshot.id),
                        maxWrappedLines: 1
                    )
                )
                if !snapshot.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append(
                        .regular(subAgentMetadataText(label: "role:", value: snapshot.role))
                    )
                }
                if let profileName = snapshot.profileName?.nilIfBlank {
                    lines.append(
                        .regular(subAgentMetadataText(label: "agent:", value: profileName))
                    )
                }
                if let taskID = snapshot.taskID?.nilIfBlank {
                    var taskText = subAgentMetadataText(
                        label: "task:",
                        value: inlineText(taskID)
                    )
                    if let attempt = snapshot.taskAttemptOrdinal {
                        taskText += " · " + subAgentMetadataText(
                            label: "attempt:",
                            value: String(attempt)
                        )
                    }
                    lines.append(.regular(taskText, maxWrappedLines: 2))
                }
                if let model = renderSubAgentModel(
                    snapshot,
                    modelTitleResolver: modelTitleResolver
                ) {
                    lines.append(.regular(model))
                }
            } else if density == .compact {
                lines.append(
                    .regular(
                        renderSubAgentAgentAndModel(
                            snapshot,
                            modelTitleResolver: modelTitleResolver
                        ),
                        maxWrappedLines: 1
                    )
                )
            }
            let activityLines = renderSubAgentActivityLines(
                snapshot,
                density: density
            )
            if !activityLines.isEmpty {
                lines.append(contentsOf: activityLines)
            }
            if let detail = renderSubAgentDetail(
                snapshot,
                includesFinalResponse: includesFinalResponses,
                density: density
            ) {
                lines.append(detail)
            }
        }

        return lines
    }

    /// Folds one agent into a single row: status header plus the most
    /// significant progress fragment.
    private nonisolated static func renderSubAgentInlineEntry(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        let header = renderSubAgentHeader(snapshot)
        guard let fragment = subAgentInlineFragment(snapshot) else {
            return header
        }
        return "\(header)  \(dimText("·")) \(fragment)"
    }

    private nonisolated static func subAgentInlineFragment(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String? {
        if let latestError = snapshot.latestError?.nilIfBlank {
            return "❌ \(inlineText(latestError))"
        }
        return renderSubAgentActivityLines(snapshot, density: .inline).first?.text
    }

    /// Keeps the essential agent identity on one row when the full metadata
    /// presentation no longer fits the terminal.
    private nonisolated static func renderSubAgentAgentAndModel(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        modelTitleResolver: (String) -> String
    ) -> String {
        let agent = snapshot.profileName?.nilIfBlank
            ?? snapshot.name.nilIfBlank
            ?? snapshot.id
        let agentText = subAgentMetadataText(
            label: "agent:",
            value: inlineText(agent)
        )
        guard let model = renderSubAgentModel(
            snapshot,
            modelTitleResolver: modelTitleResolver
        ) else {
            return agentText
        }
        return "\(agentText) \(dimText("·")) \(model)"
    }

    /// Trims a section that cannot fit even at the densest presentation,
    /// keeping the title, the aggregate summary, and as many agents as the
    /// budget allows followed by a count of the hidden ones.
    private nonisolated static func elidedSubAgentOverviewRows(
        _ rows: [String],
        rowBudget: Int
    ) -> [String] {
        guard rows.count > rowBudget else {
            return rows
        }
        // Title, summary and the elision notice need three rows; below that
        // there is nothing meaningful left to elide.
        guard rowBudget > 3 else {
            return Array(rows.prefix(max(1, rowBudget)))
        }

        let header = Array(rows.prefix(2))
        let entries = rows.dropFirst(2)
        let kept = Array(entries.prefix(max(0, rowBudget - header.count - 1)))
        let hiddenCount = entries.count - kept.count
        guard hiddenCount > 0 else {
            return header + kept
        }
        let columns = terminalColumnCount()
        let notice = "\(String(repeating: " ", count: terminalBoxHorizontalInset(columns: columns)))"
            + "\(String(repeating: " ", count: 3))\(dimText("… \(hiddenCount) more"))"
        return header + kept + [notice]
    }

    private nonisolated static func renderSubAgentSummary(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> String {
        let activeCount = snapshots.filter(\.pending).count
        let completedCount = snapshots.filter { snapshot in
            snapshot.status == .idle && snapshot.latestOutput?.nilIfBlank != nil
        }.count
        let standbyCount = snapshots.filter { $0.status == .standby }.count
        let failedCount = snapshots.filter { $0.status == .failed }.count
        let closedCount = snapshots.filter { $0.status == .closed }.count

        var segments = ["\(snapshots.count) total"]
        if activeCount > 0 {
            segments.append(colorText("▸ \(activeCount) active", code: TerminalStyle.Status.active))
        }
        if completedCount > 0 {
            segments.append(colorText("✓ \(completedCount) completed", code: TerminalStyle.Status.success))
        }
        if standbyCount > 0 {
            segments.append(colorText("◇ \(standbyCount) standby", code: TerminalStyle.Status.inactive))
        }
        if failedCount > 0 {
            segments.append(colorText("✗ \(failedCount) failed", code: TerminalStyle.Status.failure))
        }
        if closedCount > 0 {
            segments.append(dimText("· \(closedCount) closed"))
        }
        return segments.joined(separator: " ")
    }

    private nonisolated static func renderSubAgentHeader(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        let name = snapshot.name.nilIfBlank ?? snapshot.id
        let marker = coloredStatusMarker(for: snapshot)
        let badge = statusBadge(for: snapshot)
        return "\(marker) \(boldText(name))  \(badge)"
    }

    private nonisolated static func renderSubAgentModel(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        modelTitleResolver: (String) -> String
    ) -> String? {
        guard let modelID = snapshot.modelID?.nilIfBlank else {
            return nil
        }
        return subAgentMetadataText(
            label: "model:",
            value: inlineText(modelTitleResolver(modelID))
        )
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
    public nonisolated static func resolvedSubAgentModelTitle(
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
    public nonisolated static func subAgentModelNameStrippingRemoteAPIPrefix(
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

    /// Returns the bare model name from a binding identifier when the provider
    /// is already shown separately. Reuses the remote-API UUID stripping and
    /// adds a fallback for provider-scoped identifiers such as
    /// `chatgpt:gpt-5.6-terra`, taking only the segment after the last colon.
    public nonisolated static func strippedModelNameForBinding(
        _ modelID: String,
        modelProvider: String?
    ) -> String {
        if let stripped = subAgentModelNameStrippingRemoteAPIPrefix(modelID) {
            return stripped
        }
        guard modelProvider != nil,
              let colonRange = modelID.range(of: ":", options: .backwards) else {
            return modelID
        }
        let modelName = modelID[colonRange.upperBound...]
        return modelName.isEmpty ? modelID : String(modelName)
    }

    private nonisolated static func renderSubAgentActivityLines(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        density: SubAgentOverviewDensity = .full
    ) -> [SubAgentOverviewLine] {
        let currentToolName = snapshot.currentToolName?.nilIfBlank
        let currentActivity = snapshot.currentActivity?.nilIfBlank
        var lines: [SubAgentOverviewLine] = []

        if let currentActivity {
            if currentActivity == "🤔 thinking…" {
                lines.append(.regular(colorText(currentActivity, code: TerminalStyle.Thinking.title), maxWrappedLines: 1))
            } else {
                lines.append(
                    subAgentOverviewEntryLine(
                        "💬 \(inlineText(currentActivity))",
                        density: density
                    )
                )
            }
        }

        if let currentToolName {
            let target = snapshot.currentToolTarget?.nilIfBlank
            let tool = colorText(inlineText(currentToolName), code: TerminalStyle.Tool.title)
            let parameter = target.map {
                colorText(" \(inlineText($0))", code: TerminalStyle.Tool.value)
            } ?? ""
            lines.append(
                density == .full
                    ? subAgentOverviewEntryLine(
                        "🛠️  \(tool)\(parameter)",
                        density: density
                    )
                    : .regular(
                        "🛠️  \(tool)\(parameter)",
                        maxWrappedLines: 1,
                        clipsOverflowWithoutEllipsis: true
                    )
            )
        }

        if lines.isEmpty, snapshot.pending {
            lines.append(.regular(colorText("🤔 thinking…", code: TerminalStyle.Thinking.title), maxWrappedLines: 1))
        }

        // The most specific entry is appended last, so a capped presentation
        // keeps the running tool rather than the older activity line.
        if let limit = density.activityLineLimit, lines.count > limit {
            lines = Array(lines.suffix(limit))
        }

        return lines
    }

    /// Builds one activity or detail line at the requested density: unbounded
    /// for the full presentation, single-row for the denser variants.
    private nonisolated static func subAgentOverviewEntryLine(
        _ text: String,
        density: SubAgentOverviewDensity
    ) -> SubAgentOverviewLine {
        density.maximumEntryRows == .max
            ? .complete(text)
            : .regular(text, maxWrappedLines: density.maximumEntryRows)
    }

    private nonisolated static func renderSubAgentDetail(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        includesFinalResponse: Bool,
        density: SubAgentOverviewDensity = .full
    ) -> SubAgentOverviewLine? {
        if let latestError = snapshot.latestError?.nilIfBlank {
            return subAgentOverviewEntryLine(
                "❌ \(inlineText(latestError))",
                density: density
            )
        }

        guard includesFinalResponse,
              !snapshot.pending,
              let latestOutput = snapshot.latestContentPreview?.nilIfBlank
                ?? snapshot.latestOutput?.nilIfBlank else {
            return nil
        }
        return subAgentOverviewEntryLine(
            "✅ \(inlineText(latestOutput))",
            density: density
        )
    }

    /// Extracts completed model responses from the snapshot presentation. The
    /// surrounding overview remains pre-rendered terminal text, while each
    /// response stays as source Markdown so the coordinator can format it with
    /// the same renderer used for normal assistant messages.
    nonisolated static func subAgentMarkdownResponses(
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
    private nonisolated static func subAgentResponseToken(
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

    private nonisolated static func statusBadge(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        let text = displayStatus(for: snapshot).uppercased()
        guard AgentOutput.standardErrorIsTerminal else {
            return "[\(text)]"
        }

        let color = statusColorCode(for: snapshot)
        return "\(color)[\(text)]\(TerminalStyle.reset)"
    }

    private nonisolated static func boldText(_ text: String) -> String {
        colorText(text, code: TerminalStyle.Attribute.bold)
    }

    private nonisolated static func dimText(_ text: String) -> String {
        colorText(text, code: TerminalStyle.Text.muted)
    }

    /// Keeps metadata labels muted while matching Task inline-code values.
    nonisolated static func subAgentMetadataText(
        label: String,
        value: String,
        ansiEnabled: Bool = AgentOutput.standardErrorIsTerminal
    ) -> String {
        guard ansiEnabled else {
            return "\(label) \(value)"
        }
        return "\(TerminalStyle.Text.muted)\(label)\(TerminalStyle.reset) "
            + "\(TerminalMarkdownPalette.detected.inlineCodeForeground)\(value)\(TerminalStyle.reset)"
    }

    private nonisolated static func colorText(_ text: String, code: String) -> String {
        AgentOutput.standardErrorIsTerminal ? "\(code)\(text)\(TerminalStyle.reset)" : text
    }

    private nonisolated static func displayStatus(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        if snapshot.status == .idle,
           snapshot.latestOutput?.nilIfBlank != nil {
            return "completed"
        }
        return snapshot.status.rawValue
    }

    private nonisolated static func statusColorCode(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        switch snapshot.status {
        case .queued:
            return TerminalStyle.Status.queued
        case .running:
            return TerminalStyle.Status.active
        case .idle:
            return snapshot.latestOutput?.nilIfBlank == nil
                ? TerminalStyle.Status.inactive
                : TerminalStyle.Status.success
        case .standby:
            return TerminalStyle.Status.inactive
        case .failed:
            return TerminalStyle.Status.failure
        case .closed:
            return TerminalStyle.Status.inactive
        }
    }

    private nonisolated static func coloredStatusMarker(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        let marker = "●"
        guard AgentOutput.standardErrorIsTerminal else {
            return marker
        }

        let color = statusColorCode(for: snapshot)
        return "\(color)\(marker)\(TerminalStyle.reset)"
    }

    private nonisolated static func renderSubAgentOverviewLines(_ lines: [SubAgentOverviewLine]) -> String {
        joinedSubAgentOverviewRows(subAgentOverviewRows(lines))
    }

    private nonisolated static func joinedSubAgentOverviewRows(_ rows: [String]) -> String {
        "\n\(rows.joined(separator: "\n"))\n"
    }

    /// Physical rows of the section, title first, so a caller can measure the
    /// presentation before publishing it.
    private nonisolated static func subAgentOverviewRows(
        _ lines: [SubAgentOverviewLine]
    ) -> [String] {
        let columns = terminalColumnCount()
        let horizontalInset = terminalBoxHorizontalInset(columns: columns)
        let contentWidth = max(
            40,
            columns - horizontalInset - subAgentOverviewReservedColumns
        )
        let linePrefix = String(repeating: " ", count: horizontalInset)
        let orange = TerminalStyle.Accent.primary
        let dim = TerminalStyle.Text.muted
        let reset = TerminalStyle.reset
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
            if line.clipsOverflowWithoutEllipsis {
                let clipped = TerminalANSIText.truncate(
                    line.text,
                    to: wrapWidth,
                    ellipsis: "",
                    ellipsisWidth: 0
                )
                output.append("\(linePrefix)\(prefix)\(clipped)")
                continue
            }
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
        return output
    }

    /// Columns left unused on every row so the section keeps its in-place
    /// rewrite slot.
    ///
    /// One column is taken by the inset the chat renderer prepends to each
    /// physical row, one is left free because a row reaching the final column
    /// wraps in a terminal-dependent way, and one absorbs a single
    /// double-width glyph: rows are wrapped by grapheme count, while the
    /// rewrite invariant is measured in visible columns, and every row of this
    /// section carries at most one emoji marker. A row that still exceeds the
    /// terminal width (for example wide CJK content) is left untouched and the
    /// coordinator falls back to appending that refresh, which is the existing
    /// fail-safe. Truncating here instead would corrupt the full presentation,
    /// where complete activity, tool, and response text must stay intact.
    private nonisolated static let subAgentOverviewReservedColumns = 3

    nonisolated static func subAgentOverviewSignature(
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
