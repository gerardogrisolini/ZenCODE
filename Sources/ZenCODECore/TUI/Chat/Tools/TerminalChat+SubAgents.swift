//
//  TerminalChat+SubAgents.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    struct SubAgentOverviewLine {
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
        let observedSessionID = sessionID
        let history = fileArtifactHistory
        await sessionRunner.updateSubAgentToolEventHandler { [weak self] event in
            await self?.writeSubAgentToolEvent(
                event, sessionID: observedSessionID, history: history
            )
        }
    }

    // MARK: - Live refresh during agent.* tool calls

    /// Starts a periodic overview refresh so sub-agent status stays visible while
    /// a blocking `agent.*` tool call such as `agent.wait` is executing. Each
    /// tick reuses the signature-deduped `renderSubAgentOverview(force:)`, so an
    /// unchanged snapshot writes nothing. Idempotent.
    ///
    /// - Note: ``subAgentOverviewRefreshTask`` is touched only from the serial
    ///   event-delivery context (``AgentCoreSessionRunner`` delivers callbacks
    ///   sequentially), so start and stop never race; the task never reads it.
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

    /// Stops the periodic refresh and **drains** the task before the final render,
    /// so no in-flight tick can publish a stale overview afterwards (the
    /// publish-A-after-B race a bare `cancel()` would leave open). Idempotent.
    func stopSubAgentOverviewRefresh() async {
        let task = subAgentOverviewRefreshTask
        subAgentOverviewRefreshTask = nil
        task?.cancel()
        await task?.value
        await renderSubAgentOverview(force: false)
    }

    public func renderSubAgentOverview(
        force: Bool,
        rememberSignature: Bool = true,
        isAutomatic: Bool = true
    ) async {
        // Reserve before awaiting the runtime snapshot: a later callback must
        // fence this publication if this snapshot returns after it.
        let publicationRevision = await renderCoordinator.beginOverviewPublication(.subAgents)
        let snapshots = await sessionRunner.subAgentSnapshots()
        let toolPresentations = await renderCoordinator.subAgentToolPresentationSnapshot()
        await refreshStatusBarGitStatusSummaryForCompletedSubAgents(snapshots)
        let maximumInPlaceRows = await statusBar.scrollableOutputRowCapacity()
        guard force || !snapshots.isEmpty else {
            await renderCoordinator.clearSubAgentOverview(
                revision: publicationRevision,
                maximumInPlaceRows: maximumInPlaceRows,
                origin: isAutomatic ? .automatic : .explicit
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
            origin: isAutomatic ? .automatic : .explicit,
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

    /// Presentation density of the sub-agent section. The live section is replaced
    /// in place only while it fits the scrolling region; denser variants keep that
    /// rewrite slot when many agents run, instead of appending a copy per refresh.
    enum SubAgentOverviewDensity: CaseIterable {
        /// Every metadata line, with multi-row activity and detail text.
        case full
        /// Status header, agent/model identity, and capped activity lines.
        case compact
        /// Status header plus a single activity line, without separators.
        case dense
        /// One row per agent: status header with an inline activity fragment.
        case inline

        var includesSeparators: Bool {
            self == .full || self == .compact
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
            case .full: nil
            case .compact: 2
            case .dense, .inline: 1
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
        rows.map { max(1, $0 - subAgentOverviewReservedRows) }
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
        renderSubAgentOverview(
            snapshots,
            modelTitleResolver: { $0 },
            includesFinalResponses: false,
            toolPresentationsByAgentID: toolPresentationsByAgentID,
            rowBudget: rowBudget
        )
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
    }

    /// Exercises the delegated ANSI surface without redirecting process-global
    /// descriptors: SwiftPM normally captures stderr even when run in a PTY.
    nonisolated static func renderSubAgentToolRowsForTesting(
        _ presentation: TerminalChatRenderCoordinator.SubAgentToolPresentation
    ) -> [String] {
        subAgentOverviewRows(renderSubAgentToolLines(
            presentation,
            density: .full,
            standardErrorIsTerminal: true
        ))
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
            lines.append(contentsOf: activityLines)
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
        return subAgentInlineFragment(snapshot).map { "\(header)  \(dimText("·")) \($0)" } ?? header
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
        let notice = String(repeating: " ", count: terminalBoxHorizontalInset(columns: columns) + 3)
            + dimText("… \(hiddenCount) more")
        return header + kept + [notice]
    }

    private nonisolated static func renderSubAgentSummary(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> String {
        let completedCount = snapshots.filter { snapshot in
            snapshot.status == .idle && snapshot.latestOutput?.nilIfBlank != nil
        }.count
        func count(_ status: DirectSubAgentRuntime.Status) -> Int {
            snapshots.filter { $0.status == status }.count
        }
        let counted: [(Int, String, String?)] = [
            (snapshots.filter(\.pending).count, "▸ %d active", TerminalStyle.Status.active),
            (completedCount, "✓ %d completed", TerminalStyle.Status.success),
            (count(.standby), "◇ %d standby", TerminalStyle.Status.inactive),
            (count(.failed), "✗ %d failed", TerminalStyle.Status.failure),
            (count(.closed), "· %d closed", nil)
        ]
        let segments = counted.filter { $0.0 > 0 }.map { number, format, code in
            let text = format.replacingOccurrences(of: "%d", with: String(number))
            return code.map { colorText(text, code: $0) } ?? dimText(text)
        }
        return (["\(snapshots.count) total"] + segments).joined(separator: " ")
    }

    private nonisolated static func renderSubAgentHeader(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        let name = snapshot.name.nilIfBlank ?? snapshot.id
        let marker = coloredStatusMarker(for: snapshot)
        let badge = statusBadge(for: snapshot)
        return "\(marker) \(boldText(name))  \(badge)"
    }

    /// The model row, extended with the agent's cache/prefill/generated counters.
    /// The counters share the row because the overview has a strict row budget;
    /// without a model the row is absent and they wait for a later snapshot.
    private nonisolated static func renderSubAgentModelLine(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        modelTitleResolver: (String) -> String
    ) -> String? {
        guard let model = renderSubAgentModel(snapshot, modelTitleResolver: modelTitleResolver) else {
            return nil
        }
        return subAgentMetricsFragment(snapshot).map { "\(model) \(dimText("·")) \($0)" } ?? model
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

    /// Resolves a sub-agent model identifier into a human-readable title: the
    /// hosted manifest title if known, else the model name of an unresolved
    /// `remoteapi:<uuid>:<modelID>` identifier, else the identifier unchanged.
    public nonisolated static func resolvedSubAgentModelTitle(
        for modelID: String,
        hostedModel: AgentSettingsModelManifest? = nil
    ) -> String {
        if let hostedModel {
            return AgentModelCatalogPresentation.modelTitle(for: hostedModel)
        }
        return ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix(modelID) ?? modelID
    }

    /// Returns the significant model name when `modelID` is an internal
    /// `remoteapi:<uuid>:<modelName>` identifier, otherwise `nil`.
    public nonisolated static func subAgentModelNameStrippingRemoteAPIPrefix(
        _ modelID: String
    ) -> String? {
        ModelNamePresentation.subAgentModelNameStrippingRemoteAPIPrefix(modelID)
    }

    /// Returns the bare model name from a binding identifier when the provider
    /// is already shown separately. Reuses the remote-API UUID stripping and
    /// adds a fallback for provider-scoped identifiers such as
    /// `chatgpt:gpt-5.6-terra`, taking only the segment after the last colon.
    public nonisolated static func strippedModelNameForBinding(
        _ modelID: String,
        modelProvider: String?
    ) -> String {
        ModelNamePresentation.strippedModelNameForBinding(modelID, modelProvider: modelProvider)
    }
}
