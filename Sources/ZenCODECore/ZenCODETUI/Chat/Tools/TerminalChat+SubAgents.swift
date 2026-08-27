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

    func installSubAgentToolEventHandlerIfNeeded() async {
        guard !didInstallSubAgentToolEventHandler else {
            return
        }
        didInstallSubAgentToolEventHandler = true
        await sessionRunner.updateSubAgentToolEventHandler { [weak self] event in
            await self?.writeSubAgentToolEvent(event)
        }
    }

    // MARK: - Live refresh during agent.* tool calls

    /// Starts a periodic refresh of the sub-agent overview so agent status,
    /// model-authored activity, and the latest canonical tool rows remain visible
    /// while a blocking `agent.*` tool call such as `agent.wait` is executing.
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
        let toolPresentations = await renderCoordinator.subAgentToolPresentationSnapshot()
        await refreshStatusBarGitStatusSummaryForCompletedSubAgents(snapshots)
        guard force || !snapshots.isEmpty else {
            await renderCoordinator.clearSubAgentOverview(
                revision: publicationRevision
            )
            return
        }
        let signature = Self.subAgentOverviewSignature(snapshots)
            + "\u{1C}tools:\(toolPresentations.revision)"
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
            toolPresentationsByAgentID: toolPresentations.presentationsByAgentID,
            rowBudget: Self.subAgentOverviewRowBudget(
                forInPlaceRows: maximumInPlaceRows
            )
        ) + "\n"
        let partialResponses = Self.subAgentPartialResponses(snapshots)
        let responses = Self.subAgentMarkdownResponses(snapshots)
        _ = await renderCoordinator.renderSubAgentOverview(
            signature: signature,
            text: overview,
            partialResponses: partialResponses,
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
            includesFinalResponses: true,
            toolPresentationsByAgentID: [:]
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
        toolPresentationsByAgentID: [
            String: TerminalChatRenderCoordinator.SubAgentToolPresentation
        ],
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
                    toolPresentationsByAgentID: toolPresentationsByAgentID,
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
        rowBudget: Int?,
        toolPresentationsByAgentID: [
            String: TerminalChatRenderCoordinator.SubAgentToolPresentation
        ] = [:]
    ) -> [String] {
        let rendered = renderSubAgentOverview(
            snapshots,
            modelTitleResolver: { $0 },
            includesFinalResponses: false,
            toolPresentationsByAgentID: toolPresentationsByAgentID,
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
        toolPresentationsByAgentID: [
            String: TerminalChatRenderCoordinator.SubAgentToolPresentation
        ],
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
                if let model = renderSubAgentModelLine(
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
                toolPresentation: matchingSubAgentToolPresentation(
                    for: snapshot,
                    in: toolPresentationsByAgentID
                ),
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
        guard let model = renderSubAgentModelLine(
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

    /// The model row, extended in place with the agent's cache/prefill/generated
    /// counters.
    ///
    /// The counters deliberately share the model row instead of claiming a row
    /// of their own: the overview has a strict row budget and an extra row per
    /// agent would push activity and responses out of view. If no model is
    /// available, the row remains absent and the counters wait for a later
    /// snapshot that can render them inline.
    private nonisolated static func renderSubAgentModelLine(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        modelTitleResolver: (String) -> String
    ) -> String? {
        guard let model = renderSubAgentModel(
            snapshot,
            modelTitleResolver: modelTitleResolver
        ) else {
            return nil
        }
        guard let metrics = subAgentMetricsFragment(snapshot) else {
            return model
        }
        return "\(model) \(dimText("·")) \(metrics)"
    }

    /// Renders the `c:` cached / `p:` prefill / `g:` generated counters with the
    /// same abbreviations the status bar uses, keeping the labels muted and the
    /// values on the metadata value color.
    nonisolated static func subAgentMetricsFragment(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String? {
        guard let metrics = snapshot.latestMetrics else {
            return nil
        }
        let counters: [(String, Int)] = [
            metrics.cachedPromptTokenCount.map { ("c:", $0) },
            metrics.promptTokenCount.map { ("p:", $0) },
            metrics.completionTokenCount.map { ("g:", $0) }
        ].compactMap(\.self)
        guard !counters.isEmpty else {
            return nil
        }
        return counters
            .map { label, value in
                subAgentMetricText(
                    label: label,
                    value: TerminalStatusBar.tokenCountText(value)
                )
            }
            .joined(separator: " ")
    }

    private nonisolated static func renderSubAgentModel(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        modelTitleResolver: (String) -> String
    ) -> String? {
        guard let modelID = snapshot.configuredModelID?.nilIfBlank
            ?? snapshot.modelID?.nilIfBlank else {
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

    /// Stable affordance shown while an agent is reasoning but has no
    /// renderable paragraph yet. Presentation owns this string: the runtime
    /// reports the thinking phase through `currentActivityKind`.
    nonisolated static let thinkingPlaceholder = "🤔 thinking…"

    private nonisolated static func renderSubAgentActivityLines(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        toolPresentation:
            TerminalChatRenderCoordinator.SubAgentToolPresentation? = nil,
        density: SubAgentOverviewDensity = .full
    ) -> [SubAgentOverviewLine] {
        let currentToolName = snapshot.currentToolName?.nilIfBlank
        let currentActivity = snapshot.currentActivity?.nilIfBlank
        var lines: [SubAgentOverviewLine] = []

        switch snapshot.currentActivityKind {
        case .thinking:
            // Mirror the coordinator's two-level thinking layout: its stable
            // title is always emitted first, and the model-authored paragraph
            // occupies the separate rewrite slot below it. Therefore a new
            // paragraph can replace only the value without ever turning the
            // title into a growing transcript.
            lines.append(
                .regular(
                    colorText(thinkingPlaceholder, code: TerminalStyle.Thinking.title),
                    maxWrappedLines: 1
                )
            )
            // Reasoning is model-authored text printed straight into the
            // terminal, so neutralize it through the shared metadata sanitizer:
            // ESC (CSI/OSC), BEL, C1 and bidi/zero-width controls become spaces
            // and cannot move the cursor or corrupt the rows rewritten in place.
            if let paragraph = currentActivity.flatMap(sanitizedMetadataText) {
                lines.append(
                    subAgentOverviewEntryLine(
                        colorText(paragraph, code: TerminalStyle.Thinking.body),
                        density: density
                    )
                )
            }
        case .content, nil:
            if let currentActivity {
                lines.append(
                    subAgentOverviewEntryLine(
                        "💬 \(inlineText(currentActivity))",
                        density: density
                    )
                )
            }
        }

        if let currentToolName {
            if let toolPresentation {
                lines.append(
                    contentsOf: renderSubAgentToolLines(
                        toolPresentation,
                        density: density
                    )
                )
            } else {
                lines.append(
                    subAgentToolFallbackLine(
                        name: currentToolName,
                        target: snapshot.currentToolTarget?.nilIfBlank,
                        density: density
                    )
                )
            }
        }

        if lines.isEmpty, snapshot.pending {
            lines.append(
                .regular(
                    colorText(thinkingPlaceholder, code: TerminalStyle.Thinking.title),
                    maxWrappedLines: 1
                )
            )
        }

        if let limit = density.activityLineLimit, lines.count > limit {
            // A constrained presentation may omit the replaceable value, but
            // never the thinking header. This retains the coordinator's stable
            // title even in the one-row dense fallback.
            lines = snapshot.currentActivityKind == .thinking
                ? Array(lines.prefix(limit))
                : Array(lines.suffix(limit))
        }

        return lines
    }

    private nonisolated static func matchingSubAgentToolPresentation(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot,
        in presentationsByAgentID: [
            String: TerminalChatRenderCoordinator.SubAgentToolPresentation
        ]
    ) -> TerminalChatRenderCoordinator.SubAgentToolPresentation? {
        guard let currentToolName = snapshot.currentToolName?.nilIfBlank,
              let presentation = presentationsByAgentID[snapshot.id],
              presentation.toolCall.name == currentToolName else {
            return nil
        }
        return presentation
    }

    /// Uses the canonical tool row factory, changing only the available width
    /// and the three-column placement owned by the sub-agent section.
    private nonisolated static func renderSubAgentToolLines(
        _ presentation: TerminalChatRenderCoordinator.SubAgentToolPresentation,
        density: SubAgentOverviewDensity
    ) -> [SubAgentOverviewLine] {
        guard density == .full || density == .compact else {
            return [
                subAgentToolFallbackLine(
                    name: presentation.toolCall.name,
                    target: ToolCallPresentation.displayToolTarget(
                        for: presentation.toolCall
                    ),
                    density: density
                )
            ]
        }

        let result: DirectAgentToolResult?
        switch presentation.lifecycle {
        case .started:
            result = nil
        case let .completed(completedResult, _, _):
            result = completedResult
        }
        let wrapWidth = subAgentOverviewWrapWidth(indentation: 3)
        let rows = toolPresentationRows(
            for: presentation.toolCall,
            result: result,
            statusDetail: presentation.lifecycle.compactStatusDetail,
            contentInsetWidth: 0,
            // The canonical renderer reserves its own final safety column.
            columnWidth: wrapWidth + 1
        )
        let reset = TerminalStyle.reset
        var lines = rows.compactRows.enumerated().map { index, row in
            let text = AgentOutput.standardErrorIsTerminal
                ? "\(renderCompactToolLine(row.plainText, isTitle: index == 0))\(reset)"
                : row.plainText
            return SubAgentOverviewLine.complete(text)
        }
        guard density == .full else {
            return lines
        }

        let codeLanguage = codeLanguageHint(for: presentation.toolCall)
        lines.append(contentsOf: rows.detailRows.map { row in
            let text = AgentOutput.standardErrorIsTerminal
                ? "\(renderDetailedToolRow(row, codeLanguage: codeLanguage))\(reset)"
                : row.plainText
            return SubAgentOverviewLine.complete(text)
        })
        return lines
    }

    /// Compatibility projection used before a lossless lifecycle event arrives
    /// (and by non-terminal/static snapshot consumers).
    private nonisolated static func subAgentToolFallbackLine(
        name: String,
        target: String?,
        density: SubAgentOverviewDensity
    ) -> SubAgentOverviewLine {
        let tool = colorText(inlineText(name), code: TerminalStyle.Tool.title)
        let parameter = (target?.nilIfBlank).map {
            colorText(" \(inlineText($0))", code: TerminalStyle.Tool.value)
        } ?? ""
        let text = "🛠️  \(tool)\(parameter)"
        return density == .full
            ? subAgentOverviewEntryLine(text, density: density)
            : .regular(
                text,
                maxWrappedLines: 1,
                clipsOverflowWithoutEllipsis: true
            )
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

    /// Extracts the same completed assistant blocks shown as 💬 activity rows.
    /// Content appears here only after the runtime reaches a tool boundary, so
    /// Telegram receives semantic partial responses rather than token deltas.
    nonisolated static func subAgentPartialResponses(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> [TerminalChatRenderCoordinator.SubAgentPartialResponse] {
        snapshots.compactMap { snapshot in
            guard snapshot.currentActivityKind == .content,
                  let content = snapshot.currentActivity?.nilIfBlank else {
                return nil
            }
            let name = snapshot.name.nilIfBlank ?? snapshot.id
            return TerminalChatRenderCoordinator.SubAgentPartialResponse(
                token: [
                    snapshot.id,
                    "partial",
                    String(snapshot.currentActivityRevision)
                ].joined(separator: "\u{1F}"),
                heading: "💬 Response from \(inlineText(name)):",
                markdown: content
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

    /// Same palette as `subAgentMetadataText`, but the counters keep their
    /// compact `label:value` shape without a separating space.
    nonisolated static func subAgentMetricText(
        label: String,
        value: String,
        ansiEnabled: Bool = AgentOutput.standardErrorIsTerminal
    ) -> String {
        guard ansiEnabled else {
            return "\(label)\(value)"
        }
        return "\(TerminalStyle.Text.muted)\(label)\(TerminalStyle.reset)"
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
            // Keep the semantic tool marker (including its two-column gap)
            // intact while still accounting for it in the first row's width.
            // Generic word wrapping normalizes repeated ASCII spaces.
            let semanticPrefix = line.text.hasPrefix("🛠️  ") ? "🛠️  " : ""
            let wrappingText = semanticPrefix.isEmpty
                ? line.text
                : String(line.text.dropFirst(semanticPrefix.count))
            var wordWrapped = TerminalANSIText.wrap(
                wrappingText,
                width: wrapWidth,
                startingAtColumn: TerminalANSIText.visibleWidth(semanticPrefix)
            ).components(separatedBy: "\n")
            if !semanticPrefix.isEmpty, !wordWrapped.isEmpty {
                wordWrapped[0] = semanticPrefix + wordWrapped[0]
            }
            var wrapped = wordWrapped.allSatisfy({
                TerminalANSIText.visibleWidth($0) <= wrapWidth
            }) ? wordWrapped : TerminalANSIText.wrapPreservingWhitespace(
                line.text,
                width: wrapWidth
            )
            let maxWrappedLines = max(1, line.maxWrappedLines)
            if wrapped.count > maxWrappedLines {
                let ellipsis = AgentOutput.standardErrorIsTerminal ? "\(reset)…" : "…"
                wrapped = Array(wrapped.prefix(maxWrappedLines))
                let lastIndex = maxWrappedLines - 1
                wrapped[lastIndex] = TerminalANSIText.truncate(
                    wrapped[lastIndex],
                    to: wrapWidth,
                    ellipsis: ellipsis,
                    ellipsisWidth: 1
                )
            }
            for wrappedLine in wrapped {
                output.append("\(linePrefix)\(prefix)\(wrappedLine)")
            }
        }
        return output
    }

    private nonisolated static func subAgentOverviewWrapWidth(
        indentation: Int
    ) -> Int {
        let columns = terminalColumnCount()
        let horizontalInset = terminalBoxHorizontalInset(columns: columns)
        let contentWidth = max(
            40,
            columns - horizontalInset - subAgentOverviewReservedColumns
        )
        return max(1, contentWidth - max(0, indentation))
    }

    /// Columns left unused on every row so the section keeps its in-place
    /// rewrite slot.
    ///
    /// One column is taken by the inset the chat renderer prepends to each
    /// physical row and one is left free because a row reaching the final column
    /// wraps in a terminal-dependent way. Sub-agent rows use the shared ANSI- and
    /// display-width-aware wrapping primitive, so CJK and other double-width
    /// graphemes remain inside the same physical-row budget as ASCII content.
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
                snapshot.configuredModelID?.nilIfBlank ?? "",
                snapshot.modelID?.nilIfBlank ?? "",
                // The kind participates in the signature: the same text can be
                // rendered as reasoning or as a message, and a phase change
                // with no visible activity still changes the placeholder row.
                snapshot.currentActivityKind?.rawValue ?? "",
                snapshot.currentActivity?.nilIfBlank ?? "",
                snapshot.currentToolName?.nilIfBlank ?? "",
                snapshot.currentToolTarget?.nilIfBlank ?? "",
                // The counters share the model row, so a metrics update alone
                // changes the rendered overview and must invalidate it.
                subAgentMetricsSignature(snapshot),
                hasResponse ? "response" : "",
                snapshot.latestError?.nilIfBlank ?? ""
            ].joined(separator: "\u{1F}")
        }
        .joined(separator: "\u{1E}")
    }

    /// Identity of the counters rendered on the model row, built from the raw
    /// values so any reported change is detected even when the abbreviated
    /// text happens to stay the same.
    private nonisolated static func subAgentMetricsSignature(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        guard let metrics = snapshot.latestMetrics else {
            return ""
        }
        return [
            metrics.cachedPromptTokenCount.map(String.init) ?? "",
            metrics.promptTokenCount.map(String.init) ?? "",
            metrics.completionTokenCount.map(String.init) ?? ""
        ].joined(separator: "/")
    }
}
