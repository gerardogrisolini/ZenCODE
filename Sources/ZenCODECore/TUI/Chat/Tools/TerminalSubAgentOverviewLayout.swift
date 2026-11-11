//
//  TerminalSubAgentOverviewLayout.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

/// Lays out the sub-agent overview: the section of rows that lists every
/// delegated agent, its status, metadata and current activity. It is made of
/// pure functions of the agent snapshots and the available width; the
/// publication, refresh and in-place rewrite of the section stay with
/// `TerminalChat` and the render coordinator.
///
/// The rows may carry the terminal's styling (when the standard error is a
/// terminal). Telegram reuses ``statusRows(_:)``, ``partialResponses(_:)`` and
/// ``markdownResponses(_:)`` and strips that styling itself.
enum TerminalSubAgentOverviewLayout {
    struct Line {
        let text: String
        let indentation: Int
        let maxWrappedLines: Int
        let dimPrefix: Bool
        let clipsOverflowWithoutEllipsis: Bool

        static func summary(_ text: String) -> Line {
            Line(
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
        ) -> Line {
            Line(
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
        ) -> Line {
            Line(
                text: text,
                indentation: indentation,
                maxWrappedLines: .max,
                dimPrefix: false,
                clipsOverflowWithoutEllipsis: false
            )
        }
    }

    /// The overview as compact rows for a remote chat, without the section's
    /// geometry: the summary row, then one row per agent at the inline
    /// density (status marker, name, status badge, and the current activity:
    /// the latest error, the reasoning placeholder, the latest assistant
    /// block, or the tool it runs). Rows may still carry the terminal's
    /// styling; the caller strips it. No row for an empty overview.
    static func statusRows(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> [String] {
        guard !snapshots.isEmpty else { return [] }
        return [summaryText(snapshots)] + snapshots.map(inlineEntry)
    }

    /// Presentation density of the sub-agent section. The live section is replaced
    /// in place only while it fits the scrolling region; denser variants keep that
    /// rewrite slot when many agents run, instead of appending a copy per refresh.
    enum Density: CaseIterable {
        /// Every metadata line, with multi-row activity and detail text.
        case full
        /// Status header, agent/model identity, and capped activity lines,
        /// with a blank separator row before each agent.
        case compact
        /// Status header plus a single activity line, with a blank separator
        /// row before each agent.
        case dense
        /// One row per agent: status header with an inline activity fragment.
        case inline

        /// Whether a blank row precedes each agent. Every multi-row
        /// presentation keeps it, so consecutive agents never run together.
        var includesSeparators: Bool {
            self != .inline
        }

        var includesMetadata: Bool {
            self == .full
        }

        /// Whether the entry keeps the single `agent:` / `model:` identity row
        /// in place of the full metadata lines.
        var includesAgentAndModel: Bool {
            self == .compact
        }

        /// Whether the running tool is laid out with the canonical tool rows
        /// instead of the one-row fallback.
        var usesCanonicalToolRows: Bool {
            switch self {
            case .full, .compact: true
            case .dense, .inline: false
            }
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
        includesFinalResponses: Bool,
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
            rows = elidedRows(rows, rowBudget: rowBudget)
        }
        return joinedRows(rows)
    }

    private static func overviewLines(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        modelTitleResolver: (String) -> String,
        includesFinalResponses: Bool,
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
                    includesFinalResponse: includesFinalResponses,
                    includesActivity: true
                )
            )
        }

        return lines
    }

    /// The lines of one agent's entry at `density`, without the separator
    /// that precedes it in the overview: the status header, the metadata the
    /// density keeps, the current activity when `includesActivity` is `true`,
    /// and the detail (the latest error, or the final response when
    /// `includesFinalResponse` is `true`). The inline density folds the whole
    /// entry, activity fragment included, into a single row.
    static func entryLines(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        modelTitleResolver: (String) -> String,
        toolPresentation: TerminalChatRenderCoordinator.SubAgentToolPresentation?,
        density: Density,
        includesFinalResponse: Bool,
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
            if !snapshot.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(
                    .regular(metadataText(label: "role:", value: snapshot.role))
                )
            }
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
        if let detail = detailLine(
            snapshot,
            includesFinalResponse: includesFinalResponse,
            density: density
        ) {
            lines.append(detail)
        }
        return lines
    }

    /// Folds one agent into a single row: status header plus the most
    /// significant progress fragment.
    private static func inlineEntry(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        let header = headerText(snapshot)
        return inlineFragment(snapshot).map { "\(header)  \(dimText("·")) \($0)" } ?? header
    }

    private static func inlineFragment(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String? {
        if let latestError = snapshot.latestError?.nilIfBlank {
            return "❌ \(InlineTextTruncation.inlineText(latestError))"
        }
        return activityLines(snapshot, density: .inline).first?.text
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

    private static func summaryText(
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

    private static func headerText(
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
                    value: TerminalStatusBar.tokenCountText(value)
                )
            }
            .joined(separator: " ")
    }

    private static func modelText(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        modelTitleResolver: (String) -> String
    ) -> String? {
        guard let modelID = snapshot.configuredModelID?.nilIfBlank
            ?? snapshot.modelID?.nilIfBlank else {
            return nil
        }
        return metadataText(
            label: "model:",
            value: InlineTextTruncation.inlineText(modelTitleResolver(modelID))
        )
    }

    // MARK: - Activity and detail

    private static var thinkingPlaceholderLine: Line {
        .regular(colorText(TerminalChat.thinkingPlaceholder, code: TerminalStyle.Thinking.title), maxWrappedLines: 1)
    }

    static func activityLines(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        toolPresentation:
            TerminalChatRenderCoordinator.SubAgentToolPresentation? = nil,
        density: Density = .full
    ) -> [Line] {
        let currentToolName = snapshot.currentToolName?.nilIfBlank
        let currentActivity = snapshot.currentActivity?.nilIfBlank
        var lines: [Line] = []

        switch snapshot.currentActivityKind {
        case .thinking:
            // Mirror the coordinator's two-level thinking layout: its stable
            // title is always emitted first, and the model-authored paragraph
            // occupies the separate rewrite slot below it. Therefore a new
            // paragraph can replace only the value without ever turning the
            // title into a growing transcript.
            lines.append(thinkingPlaceholderLine)
            if let paragraph = currentActivity.flatMap({ TerminalChat.renderSubAgentThinkingMarkdown($0) }) {
                lines.append(
                    entryLine(paragraph, density: density)
                )
            }
        case .content, nil:
            if let currentActivity {
                lines.append(
                    entryLine(
                        "💬 \(InlineTextTruncation.inlineText(currentActivity))",
                        density: density
                    )
                )
            }
        }

        if let currentToolName,
           !ToolRenderingPolicy.shouldSuppressToolRendering(for: currentToolName) {
            if let toolPresentation {
                lines.append(
                    contentsOf: toolLines(
                        toolPresentation,
                        density: density
                    )
                )
            } else {
                lines.append(
                    toolFallbackLine(
                        name: currentToolName,
                        target: snapshot.currentToolTarget?.nilIfBlank,
                        density: density
                    )
                )
            }
        }

        if lines.isEmpty, snapshot.pending {
            lines.append(thinkingPlaceholderLine)
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

    /// Uses the canonical tool row factory, changing only the available width
    /// and the three-column placement owned by the sub-agent section.
    private static func toolLines(
        _ presentation: TerminalChatRenderCoordinator.SubAgentToolPresentation,
        density: Density,
        standardErrorIsTerminal: Bool = AgentOutput.standardErrorIsTerminal
    ) -> [Line] {
        guard !ToolRenderingPolicy.shouldSuppressToolRendering(for: presentation.toolCall.name) else {
            return []
        }
        guard density.usesCanonicalToolRows else {
            return [
                toolFallbackLine(
                    name: presentation.toolCall.name,
                    target: ToolCallPresentation.displayToolTarget(
                        for: presentation.toolCall
                    ),
                    density: density
                )
            ]
        }

        let result: DirectAgentToolResult?
        if case let .completed(completedResult, _) = presentation.lifecycle {
            result = completedResult
        } else {
            result = nil
        }
        let wrapWidth = overviewWrapWidth(indentation: 3)
        let rows = TerminalChat.toolPresentationRows(
            for: presentation.toolCall,
            result: result,
            statusDetail: presentation.lifecycle.compactStatusDetail,
            contentInsetWidth: 0,
            // The canonical renderer reserves its own final safety column.
            columnWidth: wrapWidth + 1,
            includesSourceChanges: false
        )
        let reset = TerminalStyle.reset
        var lines = rows.compactRows.enumerated().map { index, row in
            let text = standardErrorIsTerminal
                ? "\(TerminalChat.renderCompactToolLine(row.plainText, isTitle: index == 0))\(reset)"
                : row.plainText
            return Line.complete(text)
        }
        guard density == .full else {
            return lines
        }

        let codeLanguage = ToolLanguageHint.hint(for: presentation.toolCall)
        lines.append(contentsOf: rows.detailRows.map { row in
            Line.complete(
                standardErrorIsTerminal
                    ? TerminalChat.renderDetailedToolRow(
                        row,
                        codeLanguage: codeLanguage,
                        contentWidth: rows.detailContentWidth
                    ) + reset
                    : row.plainText
            )
        })
        return lines
    }

    /// Compatibility projection used before a lossless lifecycle event arrives
    /// (and by non-terminal/static snapshot consumers).
    private static func toolFallbackLine(
        name: String,
        target: String?,
        density: Density
    ) -> Line {
        let tool = colorText(InlineTextTruncation.inlineText(name), code: TerminalStyle.Tool.title)
        let parameter = (target?.nilIfBlank).map {
            colorText(" \(InlineTextTruncation.inlineText($0))", code: TerminalStyle.Tool.value)
        } ?? ""
        let text = "🛠️  \(tool)\(parameter)"
        return density == .full
            ? entryLine(text, density: density)
            : .regular(
                text,
                maxWrappedLines: 1,
                clipsOverflowWithoutEllipsis: true
            )
    }

    /// Builds one activity or detail line at the requested density: unbounded
    /// for the full presentation, single-row for the denser variants.
    private static func entryLine(
        _ text: String,
        density: Density
    ) -> Line {
        density.maximumEntryRows == .max
            ? .complete(text)
            : .regular(text, maxWrappedLines: density.maximumEntryRows)
    }

    private static func detailLine(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        includesFinalResponse: Bool,
        density: Density = .full
    ) -> Line? {
        if let latestError = snapshot.latestError?.nilIfBlank {
            return entryLine("❌ \(InlineTextTruncation.inlineText(latestError))", density: density)
        }

        guard includesFinalResponse,
              !snapshot.pending,
              let latestOutput = snapshot.latestContentPreview?.nilIfBlank
                ?? snapshot.latestOutput?.nilIfBlank else {
            return nil
        }
        return entryLine("✅ \(InlineTextTruncation.inlineText(latestOutput))", density: density)
    }

    // MARK: - Responses

    /// Extracts completed model responses from the snapshot presentation. The
    /// surrounding overview remains pre-rendered terminal text, while each
    /// response stays as source Markdown so the coordinator can format it with
    /// the same renderer used for normal assistant messages.
    static func markdownResponses(
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
                token: responseToken(snapshot: snapshot, output: output),
                heading: "   ✅ Response from \(InlineTextTruncation.inlineText(name)):\n",
                markdown: output
            )
        }
    }

    /// Extracts the same completed assistant blocks shown as 💬 activity rows.
    /// Content appears here only after the runtime reaches a tool boundary, so
    /// Telegram receives semantic partial responses rather than token deltas.
    static func partialResponses(
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
                heading: "💬 \(InlineTextTruncation.inlineText(name)):",
                markdown: content
            )
        }
    }

    /// Produces a compact deterministic identity for one completion. Runtime
    /// snapshots carry a monotonic completion revision, so metadata-only changes
    /// (for example closing an agent) cannot make an old response appear new.
    /// The digest is a fallback for manually constructed legacy snapshots.
    private static func responseToken(
        snapshot: DirectSubAgentRuntime.AgentSnapshot,
        output: String
    ) -> String {
        if snapshot.latestOutputRevision > 0 {
            return [snapshot.id, String(snapshot.latestOutputRevision)].joined(separator: "\u{1F}")
        }

        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in output.utf8 {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return [snapshot.id, String(digest, radix: 16)].joined(separator: "\u{1F}")
    }

    // MARK: - Styling

    private static func statusBadge(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        colorText("[\(displayStatus(for: snapshot).uppercased())]", code: statusColorCode(for: snapshot))
    }

    private static func boldText(_ text: String) -> String {
        colorText(text, code: TerminalStyle.Attribute.bold)
    }

    private static func dimText(_ text: String) -> String {
        colorText(text, code: TerminalStyle.Text.muted)
    }

    /// Keeps metadata labels muted while matching Task inline-code values.
    private static func metadataText(
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

    private static func colorText(_ text: String, code: String) -> String {
        AgentOutput.standardErrorIsTerminal ? "\(code)\(text)\(TerminalStyle.reset)" : text
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

    private static func statusColorCode(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        switch snapshot.status {
        case .queued: TerminalStyle.Status.queued
        case .running: TerminalStyle.Status.active
        case .idle:
            snapshot.latestOutput?.nilIfBlank == nil
                ? TerminalStyle.Status.inactive
                : TerminalStyle.Status.success
        case .standby, .closed: TerminalStyle.Status.inactive
        case .failed: TerminalStyle.Status.failure
        }
    }

    private static func coloredStatusMarker(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        colorText("●", code: statusColorCode(for: snapshot))
    }

    // MARK: - Physical rows

    static func renderLines(_ lines: [Line]) -> String {
        joinedRows(overviewRows(lines))
    }

    static func joinedRows(_ rows: [String]) -> String {
        "\n\(rows.joined(separator: "\n"))\n"
    }

    /// Physical rows of the section, title first, so a caller can measure the
    /// presentation before publishing it.
    static func overviewRows(
        _ lines: [Line]
    ) -> [String] {
        overviewRows(lines, columns: TerminalTextMetrics.terminalColumnCount(), includesTitle: true)
    }

    /// Physical rows of `lines` laid out for `columns` terminal columns,
    /// preceded by the section title when `includesTitle` is `true`. The
    /// content width never drops below the section's 40-column minimum, so a
    /// caller with fewer columns bounds the rows itself.
    static func overviewRows(
        _ lines: [Line],
        columns: Int,
        includesTitle: Bool
    ) -> [String] {
        let contentWidth = overviewContentWidth(columns: columns)
        let orange = TerminalStyle.Accent.primary
        let dim = TerminalStyle.Text.muted
        let reset = TerminalStyle.reset
        let title = AgentOutput.standardErrorIsTerminal
            ? "👥 \(orange)Sub-Agents:\(reset)"
            : "👥 Sub-Agents:"

        var output = includesTitle ? [title] : []
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
                output.append("\(prefix)\(clipped)")
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
                output.append("\(prefix)\(wrappedLine)")
            }
        }
        return output
    }

    static func overviewWrapWidth(
        indentation: Int
    ) -> Int {
        let contentWidth = overviewContentWidth(
            columns: TerminalTextMetrics.terminalColumnCount()
        )
        return max(1, contentWidth - max(0, indentation))
    }

    private static func overviewContentWidth(columns: Int) -> Int {
        max(40, columns - reservedColumns)
    }

    /// Columns left unused on every row so the section keeps its in-place
    /// rewrite slot.
    ///
    /// One column is taken by the inset the chat renderer prepends to each
    /// physical row and one is left free because a row reaching the final column
    /// wraps in a terminal-dependent way. Sub-agent rows use the shared ANSI- and
    /// display-width-aware wrapping primitive, so CJK and other double-width
    /// graphemes remain inside the same physical-row budget as ASCII content.
    private static let reservedColumns = 3
}
