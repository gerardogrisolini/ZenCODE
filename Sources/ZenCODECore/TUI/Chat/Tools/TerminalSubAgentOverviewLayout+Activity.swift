//
//  TerminalSubAgentOverviewLayout+Activity.swift
//  ZenCODE
//
//  Activity, detail and response rows of the sub-agent overview: the current
//  tool or thinking line, the latest error and the completed Markdown
//  responses.
//

import Foundation
import ToolCore

extension TerminalSubAgentOverviewLayout {
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

    static func detailLine(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        density: Density = .full
    ) -> Line? {
        guard let latestError = snapshot.latestError?.nilIfBlank else {
            return nil
        }
        return entryLine("❌ \(InlineTextTruncation.inlineText(latestError))", density: density)
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
}
