//
//  TerminalSubAgentOverviewLayout+PhysicalRows.swift
//  ZenCODE
//
//  Physical rows of the sub-agent overview: wrapping the logical lines to the
//  terminal width while keeping the in-place rewrite slot.
//

import Foundation
import ToolCore
import ZenCODERuntime

extension TerminalSubAgentOverviewLayout {
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
