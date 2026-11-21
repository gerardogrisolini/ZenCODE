//
//  TerminalSubAgentOverviewLayout+Overview.swift
//  ZenCODE
//
//  The terminal's sub-agent section: its density variants within the rows
//  it may replace in place, the full and compact entries with their metadata
//  and model rows, and the elision of the agents that do not fit. The inline
//  rows and the responses a remote chat reuses live with the layout in
//  ZenCODERuntime.
//

import Foundation
import ToolCore
import ZenCODERuntime

extension TerminalSubAgentOverviewLayout {
    // MARK: - Overview

    /// Physical rows the surrounding chat output adds to the section: the
    /// leading blank row, the trailing blank row kept by the `"\n\n"`
    /// terminator, and one spare row so a section sized exactly like the
    /// scrolling region still leaves the cursor inside it.
    private static let reservedRows = 3

    /// Converts the rows available for an in-place replacement into the row
    /// budget the section content may occupy. `nil` (no terminal, or no started
    /// status bar) leaves the presentation unbounded.
    static func overviewRowBudget(
        forInPlaceRows rows: Int?
    ) -> Int? {
        rows.map { max(1, $0 - reservedRows) }
    }

    /// The whole section for `snapshots`, framed by the blank rows the chat
    /// output adds. It takes the richest ``Density`` whose rows fit
    /// `rowBudget` (the richest one without a budget) and elides the agents
    /// that even the densest one cannot fit (`elidedRows(_:rowBudget:)`).
    /// An empty overview says so under the summary.
    static func render(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        modelTitleResolver: (String) -> String,
        toolPresentationsByAgentID: [
            String: TerminalChatRenderCoordinator.SubAgentToolPresentation
        ],
        rowBudget: Int? = nil
    ) -> String {
        guard !snapshots.isEmpty else {
            return renderLines([
                .summary(summaryText(snapshots)),
                .regular("No delegated sub-agents.")
            ])
        }

        // Step down through the density variants until the section fits the
        // rows it may replace in place. An unbounded budget always keeps the
        // richest presentation.
        var rows: [String] = []
        for density in Density.allCases {
            rows = overviewRows(
                overviewLines(
                    snapshots,
                    modelTitleResolver: modelTitleResolver,
                    toolPresentationsByAgentID: toolPresentationsByAgentID,
                    density: density
                )
            )
            guard let rowBudget, rows.count > rowBudget else {
                break
            }
        }

        if let rowBudget {
            rows = elidedRows(rows, rowBudget: rowBudget)
        }
        return joinedRows(rows)
    }

    private static func overviewLines(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        modelTitleResolver: (String) -> String,
        toolPresentationsByAgentID: [
            String: TerminalChatRenderCoordinator.SubAgentToolPresentation
        ],
        density: Density
    ) -> [Line] {
        var lines = [Line.summary(summaryText(snapshots))]

        for snapshot in snapshots {
            if density.includesSeparators {
                lines.append(.regular("", maxWrappedLines: 1))
            }
            lines.append(
                contentsOf: entryLines(
                    snapshot,
                    modelTitleResolver: modelTitleResolver,
                    toolPresentation: matchingToolPresentation(
                        for: snapshot,
                        in: toolPresentationsByAgentID
                    ),
                    density: density,
                    includesActivity: true
                )
            )
        }

        return lines
    }

    /// The lines of one agent's entry at `density`, without the separator
    /// that precedes it in the overview: the status header, the metadata the
    /// density keeps, the current activity when `includesActivity` is `true`,
    /// and the latest error. The inline density folds the whole
    /// entry, activity fragment included, into a single row.
    static func entryLines(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        modelTitleResolver: (String) -> String,
        toolPresentation: TerminalChatRenderCoordinator.SubAgentToolPresentation?,
        density: Density,
        includesActivity: Bool
    ) -> [Line] {
        if density == .inline {
            return [.regular(inlineEntry(snapshot), maxWrappedLines: 1)]
        }

        var lines = [Line.regular(headerText(snapshot))]
        if density.includesMetadata {
            lines.append(
                .regular(
                    metadataText(label: "id:", value: snapshot.id),
                    maxWrappedLines: 1
                )
            )
            if let profileName = snapshot.profileName?.nilIfBlank {
                lines.append(
                    .regular(metadataText(label: "agent:", value: profileName))
                )
            }
            if let taskID = snapshot.taskID?.nilIfBlank {
                var taskText = metadataText(
                    label: "task:",
                    value: InlineTextTruncation.inlineText(taskID)
                )
                if let attempt = snapshot.taskAttemptOrdinal {
                    taskText += " · " + metadataText(
                        label: "attempt:",
                        value: String(attempt)
                    )
                }
                lines.append(.regular(taskText, maxWrappedLines: 2))
            }
            if let model = modelLine(
                snapshot,
                modelTitleResolver: modelTitleResolver
            ) {
                lines.append(.regular(model))
            }
        } else if density.includesAgentAndModel {
            lines.append(
                .regular(
                    agentAndModel(
                        snapshot,
                        modelTitleResolver: modelTitleResolver
                    ),
                    maxWrappedLines: 1
                )
            )
        }
        if includesActivity {
            lines.append(
                contentsOf: activityLines(
                    snapshot,
                    toolPresentation: toolPresentation,
                    density: density
                )
            )
        }
        if let detail = detailLine(snapshot, density: density) {
            lines.append(detail)
        }
        return lines
    }

    /// Keeps the essential agent identity on one row when the full metadata
    /// presentation no longer fits the terminal.
    private static func agentAndModel(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        modelTitleResolver: (String) -> String
    ) -> String {
        let agent = snapshot.profileName?.nilIfBlank
            ?? snapshot.name.nilIfBlank
            ?? snapshot.id
        let agentText = metadataText(
            label: "agent:",
            value: InlineTextTruncation.inlineText(agent)
        )
        guard let model = modelLine(
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
    private static func elidedRows(
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
        let notice = String(repeating: " ", count: 3)
            + dimText("… \(hiddenCount) more")
        return header + kept + [notice]
    }

    /// The model row, extended with the agent's cache/prefill/generated counters.
    /// The counters share the row because the overview has a strict row budget;
    /// without a model the row is absent and they wait for a later snapshot.
    private static func modelLine(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        modelTitleResolver: (String) -> String
    ) -> String? {
        guard let model = modelText(snapshot, modelTitleResolver: modelTitleResolver) else {
            return nil
        }
        return metricsFragment(snapshot).map { "\(model) \(dimText("·")) \($0)" } ?? model
    }

    /// Renders the `c:` cached / `p:` prefill / `g:` generated counters with the
    /// same abbreviations the status bar uses, keeping the labels muted and the
    /// values on the metadata value color.
    static func metricsFragment(
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
                metricText(
                    label: label,
                    value: StatusMetricsFormatting.tokenCountText(value)
                )
            }
            .joined(separator: " ")
    }

    /// The `model:` metadata text of the agent's configured model (the model
    /// the backend reported when none is configured), titled by
    /// `modelTitleResolver`, without the token counters of `modelLine`;
    /// `nil` without a model.
    static func modelText(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        modelTitleResolver: (String) -> String
    ) -> String? {
        modelTitle(snapshot, modelTitleResolver: modelTitleResolver).map {
            metadataText(label: "model:", value: $0)
        }
    }

    /// The title of the agent's configured model (the model the backend
    /// reported when none is configured), by `modelTitleResolver`, on one
    /// line; `nil` without a model. It is the value of ``modelText(_:modelTitleResolver:)``
    /// alone, without the label. The `/subagent` list reuses it.
    static func modelTitle(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        modelTitleResolver: (String) -> String
    ) -> String? {
        guard let modelID = snapshot.configuredModelID?.nilIfBlank
            ?? snapshot.modelID?.nilIfBlank else {
            return nil
        }
        return InlineTextTruncation.inlineText(modelTitleResolver(modelID))
    }

    private static func matchingToolPresentation(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot,
        in presentationsByAgentID: [
            String: TerminalChatRenderCoordinator.SubAgentToolPresentation
        ]
    ) -> TerminalChatRenderCoordinator.SubAgentToolPresentation? {
        guard let currentToolName = snapshot.currentToolName?.nilIfBlank,
              !ToolRenderingPolicy.shouldSuppressToolRendering(for: currentToolName),
              let presentation = presentationsByAgentID[snapshot.id],
              presentation.toolCall.name == currentToolName else {
            return nil
        }
        return presentation
    }

    // MARK: - Styling

    /// Keeps metadata labels muted while matching Task inline-code values.
    /// The `/subagent` list reuses it, so its rows match the detail header.
    static func metadataText(
        label: String,
        value: String,
        ansiEnabled: Bool = AgentOutput.standardErrorIsTerminal
    ) -> String {
        labeledText(label: label, value: value, separator: " ", ansiEnabled: ansiEnabled)
    }

    /// Same palette as `metadataText`, but the counters keep their
    /// compact `label:value` shape without a separating space.
    private static func metricText(
        label: String,
        value: String,
        ansiEnabled: Bool = AgentOutput.standardErrorIsTerminal
    ) -> String {
        labeledText(label: label, value: value, separator: "", ansiEnabled: ansiEnabled)
    }

    private static func labeledText(
        label: String,
        value: String,
        separator: String,
        ansiEnabled: Bool
    ) -> String {
        guard ansiEnabled else {
            return "\(label)\(separator)\(value)"
        }
        return "\(TerminalStyle.Text.muted)\(label)\(TerminalStyle.reset)\(separator)"
            + "\(TerminalMarkdownPalette.detected.inlineCodeForeground)\(value)\(TerminalStyle.reset)"
    }
}
