//
//  TerminalChat+SubAgents+Presentation.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    /// Stable affordance shown while an agent is reasoning but has no
    /// renderable paragraph yet. Presentation owns this string: the runtime
    /// reports the thinking phase through `currentActivityKind`.
    nonisolated static let thinkingPlaceholder = "🤔 thinking…"

    private nonisolated static var thinkingPlaceholderLine: SubAgentOverviewLine {
        .regular(colorText(thinkingPlaceholder, code: TerminalStyle.Thinking.title), maxWrappedLines: 1)
    }

    nonisolated static func renderSubAgentActivityLines(
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
            lines.append(thinkingPlaceholderLine)
            if let paragraph = currentActivity.flatMap({ renderSubAgentThinkingMarkdown($0) }) {
                lines.append(
                    subAgentOverviewEntryLine(paragraph, density: density)
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

        if let currentToolName,
           !shouldSuppressToolRendering(for: currentToolName) {
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

    /// Formats the replaceable reasoning value with the coordinator's Markdown
    /// and muted thinking styles, bounded by the existing overview width.
    nonisolated static func renderSubAgentThinkingMarkdown(
        _ source: String,
        standardErrorIsTerminal: Bool = AgentOutput.standardErrorIsTerminal,
        renderWidth: Int? = nil
    ) -> String? {
        let sanitized = sanitizedSubAgentThinkingText(source, preservingTabs: true)
        guard !sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var boldBreakState = TerminalChatBoldBreakState()
        var normalized = TerminalChatTextFormatting.normalizedBoldSectionBreak(
            sanitized,
            state: &boldBreakState
        )
        normalized += TerminalChatTextFormatting.flushBoldSectionBreak(state: &boldBreakState)
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: standardErrorIsTerminal,
            renderWidth: renderWidth ?? subAgentOverviewWrapWidth(indentation: 3),
            // Only renderer-owned SGR may reach the in-place slot, never OSC.
            supportsHyperlinks: false,
            removesUnbalancedStrongMarkers: true
        )
        let rendered = formatter.consume(normalized) + formatter.finish()
        // Markdown entities can decode to controls too. Reapply the safety
        // boundary after parsing, allowing only SGR for the thinking style pass.
        return TerminalChatTextFormatting.renderThoughtMarkdown(
            sanitizedSubAgentThinkingText(rendered, preservingSGR: true),
            standardErrorIsTerminal: standardErrorIsTerminal
        )
    }

    private nonisolated static func sanitizedSubAgentThinkingText(
        _ source: String,
        preservingTabs: Bool = false,
        preservingSGR: Bool = false
    ) -> String {
        // Preserve structural LF, and TAB only before Markdown so the shared
        // parser and code renderer own indentation and tab-stop expansion.
        // The post-parse safety pass still neutralizes any remaining TAB.
        let source = source.replacingOccurrences(of: "\r\n", with: "\n")
        var sanitized = ""
        sanitized.reserveCapacity(source.count)
        var cursor = source.startIndex
        while cursor < source.endIndex {
            if preservingSGR, source[cursor...].hasPrefix("\u{1B}[") {
                var end = source.index(cursor, offsetBy: 2)
                while end < source.endIndex, "0123456789;".contains(source[end]) {
                    end = source.index(after: end)
                }
                if end < source.endIndex, source[end] == "m" {
                    sanitized += source[cursor...end]
                    cursor = source.index(after: end)
                    continue
                }
            }
            let character = source[cursor]
            let isStructuralWhitespace = character == "\n" || (preservingTabs && character == "\t")
            let isControl = !isStructuralWhitespace && character.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    || scalar.properties.isBidiControl
                    || scalar.properties.isJoinControl
            }
            sanitized.append(isControl ? " " : character)
            cursor = source.index(after: cursor)
        }
        return sanitized
    }

    nonisolated static func matchingSubAgentToolPresentation(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot,
        in presentationsByAgentID: [
            String: TerminalChatRenderCoordinator.SubAgentToolPresentation
        ]
    ) -> TerminalChatRenderCoordinator.SubAgentToolPresentation? {
        guard let currentToolName = snapshot.currentToolName?.nilIfBlank,
              !shouldSuppressToolRendering(for: currentToolName),
              let presentation = presentationsByAgentID[snapshot.id],
              presentation.toolCall.name == currentToolName else {
            return nil
        }
        return presentation
    }

    /// Uses the canonical tool row factory, changing only the available width
    /// and the three-column placement owned by the sub-agent section.
    nonisolated static func renderSubAgentToolLines(
        _ presentation: TerminalChatRenderCoordinator.SubAgentToolPresentation,
        density: SubAgentOverviewDensity,
        standardErrorIsTerminal: Bool = AgentOutput.standardErrorIsTerminal
    ) -> [SubAgentOverviewLine] {
        guard !shouldSuppressToolRendering(for: presentation.toolCall.name) else {
            return []
        }
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
        if case let .completed(completedResult, _, _) = presentation.lifecycle {
            result = completedResult
        } else {
            result = nil
        }
        let wrapWidth = subAgentOverviewWrapWidth(indentation: 3)
        let rows = toolPresentationRows(
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
                ? "\(renderCompactToolLine(row.plainText, isTitle: index == 0))\(reset)"
                : row.plainText
            return SubAgentOverviewLine.complete(text)
        }
        guard density == .full else {
            return lines
        }

        let codeLanguage = codeLanguageHint(for: presentation.toolCall)
        lines.append(contentsOf: rows.detailRows.map { row in
            SubAgentOverviewLine.complete(
                standardErrorIsTerminal
                    ? renderDetailedToolRow(
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

    nonisolated static func renderSubAgentDetail(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        includesFinalResponse: Bool,
        density: SubAgentOverviewDensity = .full
    ) -> SubAgentOverviewLine? {
        if let latestError = snapshot.latestError?.nilIfBlank {
            return subAgentOverviewEntryLine("❌ \(inlineText(latestError))", density: density)
        }

        guard includesFinalResponse,
              !snapshot.pending,
              let latestOutput = snapshot.latestContentPreview?.nilIfBlank
                ?? snapshot.latestOutput?.nilIfBlank else {
            return nil
        }
        return subAgentOverviewEntryLine("✅ \(inlineText(latestOutput))", density: density)
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
                heading: "💬 \(inlineText(name)):",
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
            return [snapshot.id, String(snapshot.latestOutputRevision)].joined(separator: "\u{1F}")
        }

        var digest: UInt64 = 14_695_981_039_346_656_037
        for byte in output.utf8 {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return [snapshot.id, String(digest, radix: 16)].joined(separator: "\u{1F}")
    }

    nonisolated static func statusBadge(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        colorText("[\(displayStatus(for: snapshot).uppercased())]", code: statusColorCode(for: snapshot))
    }

    nonisolated static func boldText(_ text: String) -> String {
        colorText(text, code: TerminalStyle.Attribute.bold)
    }

    nonisolated static func dimText(_ text: String) -> String {
        colorText(text, code: TerminalStyle.Text.muted)
    }

    /// Keeps metadata labels muted while matching Task inline-code values.
    nonisolated static func subAgentMetadataText(
        label: String,
        value: String,
        ansiEnabled: Bool = AgentOutput.standardErrorIsTerminal
    ) -> String {
        labeledText(label: label, value: value, separator: " ", ansiEnabled: ansiEnabled)
    }

    /// Same palette as `subAgentMetadataText`, but the counters keep their
    /// compact `label:value` shape without a separating space.
    nonisolated static func subAgentMetricText(
        label: String,
        value: String,
        ansiEnabled: Bool = AgentOutput.standardErrorIsTerminal
    ) -> String {
        labeledText(label: label, value: value, separator: "", ansiEnabled: ansiEnabled)
    }

    private nonisolated static func labeledText(
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

    nonisolated static func colorText(_ text: String, code: String) -> String {
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

    nonisolated static func coloredStatusMarker(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        colorText("●", code: statusColorCode(for: snapshot))
    }

    nonisolated static func renderSubAgentOverviewLines(_ lines: [SubAgentOverviewLine]) -> String {
        joinedSubAgentOverviewRows(subAgentOverviewRows(lines))
    }

    nonisolated static func joinedSubAgentOverviewRows(_ rows: [String]) -> String {
        "\n\(rows.joined(separator: "\n"))\n"
    }

    /// Physical rows of the section, title first, so a caller can measure the
    /// presentation before publishing it.
    nonisolated static func subAgentOverviewRows(
        _ lines: [SubAgentOverviewLine]
    ) -> [String] {
        let columns = terminalColumnCount()
        let horizontalInset = terminalBoxHorizontalInset(columns: columns)
        let contentWidth = subAgentOverviewContentWidth(columns: columns, horizontalInset: horizontalInset)
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
        let contentWidth = subAgentOverviewContentWidth(
            columns: columns,
            horizontalInset: terminalBoxHorizontalInset(columns: columns)
        )
        return max(1, contentWidth - max(0, indentation))
    }

    private nonisolated static func subAgentOverviewContentWidth(columns: Int, horizontalInset: Int) -> Int {
        max(40, columns - horizontalInset - subAgentOverviewReservedColumns)
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
        ChatSubAgentOverview.signature(for: snapshots)
    }
}
