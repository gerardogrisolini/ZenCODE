//
//  TerminalSubAgentOverviewLayout+Activity.swift
//  ZenCODE
//
//  Activity and detail rows of the terminal's sub-agent overview: the current
//  tool with its canonical rows or the thinking line with its rendered
//  paragraph, and the latest error. The inline activity and the completed
//  Markdown responses live with the layout in ZenCODERuntime.
//

import Foundation
import ToolCore
import ZenCODERuntime

extension TerminalSubAgentOverviewLayout {
    // MARK: - Activity and detail

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

    static func detailLine(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        density: Density = .full
    ) -> Line? {
        guard let latestError = snapshot.latestError?.nilIfBlank else {
            return nil
        }
        return entryLine("❌ \(InlineTextTruncation.inlineText(latestError))", density: density)
    }
}
