//
//  TerminalChat+ToolRendering.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    /// A detailed tool row before terminal rendering. Side-by-side diff cells
    /// are kept in separate fields instead of being encoded into the text, so
    /// no byte sequence in the payload — ANSI, Unicode or otherwise — can be
    /// mistaken for the column boundary.
    enum DetailedToolRow: Sendable, Equatable {
        case text(String)
        case diff(DetailedToolDiffCells)

        /// Marker-free textual projection used for row accounting, wrapping
        /// fallbacks, tests and any non-terminal consumer.
        var plainText: String {
            switch self {
            case let .text(line):
                return line
            case let .diff(cells):
                return cells.plainText
            }
        }
    }

    /// A single side-by-side diff row. Both cells are already padded to the
    /// column width, so the divider position is a layout property instead of
    /// something parsed back out of the content.
    struct DetailedToolDiffCells: Sendable, Equatable {
        static let divider = " │ "

        let indentation: String
        let oldCell: String
        let newCell: String

        var plainText: String {
            "\(indentation)\(oldCell)\(Self.divider)\(newCell)"
        }
    }

    public func writeToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        let maximumInPlaceRows = await statusBar.scrollableOutputRowCapacity()
        await renderCoordinator.writeToolCallStarted(
            toolCall,
            maximumInPlaceRows: maximumInPlaceRows
        )
    }

    public func writeToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) async {
        let maximumInPlaceRows = await statusBar.scrollableOutputRowCapacity()
        await renderCoordinator.writeToolCallCompleted(
            toolCall,
            result: result,
            maximumInPlaceRows: maximumInPlaceRows
        )
    }

    public func toggleToolDetailsOutput() async {
        await renderCoordinator.toggleToolDetailsOutput()
    }

    func writeAccessModeChangeMessage(_ accessMode: AgentLocalExecAccessMode) async {
        await renderCoordinator.writeAccessModeChangeMessage(accessMode)
    }

    nonisolated static func compactToolTerminalText(
        _ lines: [String],
        lineInset: String,
        newline: Bool = false,
        terminator: String = "\n"
    ) -> String {
        let reset = "\u{1B}[0m"
        let suffix = newline ? "\n" : ""
        let text = lines
            .enumerated()
            .map { index, line in
                "\r\u{1B}[2K\(lineInset)\(Self.renderCompactToolLine(line, isTitle: index == 0))\(reset)"
            }
            .joined(separator: "\n")
        return "\(text)\(terminator)\(suffix)"
    }

        /// Colors a compact tool line within the orange family: the title row keeps
    /// the full orange identity color, while the target/status row drops to a
    /// lighter peach-orange so the block stays readable instead of flat
    /// monochromatic orange.
    nonisolated static func renderCompactToolLine(
        _ line: String,
        isTitle: Bool
    ) -> String {
        if isTitle {
            return "\(toolTitleColor)\(line)"
        }
        return "\(toolValueColor)\(line)"
    }

    nonisolated static func compactToolLines(
        for toolCall: DirectAgentToolCall,
        statusIcon: String,
        contentInsetWidth: Int = 0,
        columnWidth: Int? = nil
    ) -> [String] {
        let title = ToolCallPresentation.toolTitle(for: toolCall)
        let icon = ToolCallPresentation.toolIcon(for: toolCall.name)
        guard let target = ToolCallPresentation.displayToolTarget(for: toolCall),
              title.hasSuffix(target) else {
            return ["\(icon)  \(title) \(statusIcon)"]
        }

        let action = title
            .dropLast(target.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else {
            return ["\(icon)  \(title) \(statusIcon)"]
        }
        return [
            "\(icon)  \(action):",
            compactToolStatusLine(
                target: target,
                statusIcon: statusIcon,
                contentInsetWidth: contentInsetWidth,
                columnWidth: columnWidth
            )
        ]
    }

    nonisolated static func compactToolStatusLine(
        target: String,
        statusIcon: String,
        contentInsetWidth: Int = 0,
        columnWidth: Int? = nil
    ) -> String {
        let resolvedColumns = columnWidth ?? terminalColumnCount()
        let columns = max(0, resolvedColumns - contentInsetWidth)
        let suffixWidth = displayWidth(statusIcon)
        // Reserve one extra trailing column so the rendered line (inset + target
        // + " " + status icon) never occupies the full terminal width. A line
        // that is exactly terminal-width triggers ambiguous auto-wrap behavior:
        // terminals without deferred wrap advance the cursor an extra row, so
        // the in-place rewrite on completion moves up one row too few and leaves
        // the previous title line behind, duplicating the tool header.
        let safeLineWidth = max(0, columns - 1)
        let textWidthLimit = safeLineWidth - suffixWidth - 1
        guard textWidthLimit > 0 else {
            return suffixWidth <= safeLineWidth ? statusIcon : ""
        }
        let fittedTarget = fitDisplayWidth(
            compactToolInlineTarget(target),
            width: textWidthLimit
        )
        guard !fittedTarget.isEmpty else {
            return suffixWidth <= safeLineWidth ? statusIcon : ""
        }
        return "\(fittedTarget) \(statusIcon)"
    }

    nonisolated static func renderedTerminalRowCount(
        for lines: [String],
        contentInsetWidth: Int = 0,
        columnWidth: Int? = nil
    ) -> Int {
        let resolvedColumns = columnWidth ?? terminalColumnCount()
        let columns = max(1, resolvedColumns - contentInsetWidth)
        return lines.reduce(0) { result, line in
            let segments = line.split(
                omittingEmptySubsequences: false,
                whereSeparator: \.isNewline
            )
            return result + segments.reduce(0) { segmentResult, segment in
                let width = max(1, displayWidth(String(segment)))
                return segmentResult + max(1, (width + columns - 1) / columns)
            }
        }
    }

    /// Reflows detailed tool rows before they are rendered in an in-place
    /// block. One terminal cell remains unused on every row because a line
    /// ending in the final column has terminal-dependent auto-wrap behavior;
    /// that would make the cursor position disagree with the saved row count
    /// used to redraw the tool on completion.
    nonisolated static func safelyWrappedDetailedToolRows(
        _ rows: [DetailedToolRow],
        contentInsetWidth: Int = 0,
        columnWidth: Int? = nil
    ) -> [DetailedToolRow] {
        let resolvedColumns = columnWidth ?? terminalColumnCount()
        let contentColumns = max(1, resolvedColumns - contentInsetWidth)
        let safeLineWidth = max(1, contentColumns - 1)

        return rows.flatMap { row -> [DetailedToolRow] in
            switch row {
            case let .text(line):
                return wrappedDetailedToolTextLines(line, width: safeLineWidth)
                    .map(DetailedToolRow.text)
            case let .diff(cells):
                return wrappedDetailedToolDiffRows(cells, width: safeLineWidth)
            }
        }
    }

    nonisolated static func safelyWrappedDetailedToolLines(
        _ lines: [String],
        contentInsetWidth: Int = 0,
        columnWidth: Int? = nil
    ) -> [String] {
        safelyWrappedDetailedToolRows(
            lines.map(DetailedToolRow.text),
            contentInsetWidth: contentInsetWidth,
            columnWidth: columnWidth
        )
        .map(\.plainText)
    }

    private nonisolated static func wrappedDetailedToolTextLines(
        _ line: String,
        width: Int
    ) -> [String] {
        // Code snippets begin with at least two spaces. Keep their leading
        // indentation on continuations so expanded code styling remains
        // consistent after a hard wrap.
        let leadingSpaces = String(line.prefix { $0 == " " })
        let hangingIndent = line.hasPrefix("  ") ? leadingSpaces : ""
        return TerminalANSIText.wrapPreservingWhitespace(
            line,
            width: width,
            hangingIndent: hangingIndent
        )
    }

    /// Reflows a side-by-side row by wrapping each cell inside its own column
    /// budget and re-pairing the resulting fragments. The two columns stay
    /// aligned and independently highlightable; nothing is parsed back out of
    /// the payload text to find the divider.
    private nonisolated static func wrappedDetailedToolDiffRows(
        _ cells: DetailedToolDiffCells,
        width: Int
    ) -> [DetailedToolRow] {
        guard displayWidth(cells.plainText) > width else {
            return [.diff(cells)]
        }

        let dividerWidth = displayWidth(DetailedToolDiffCells.divider)
        let indentWidth = displayWidth(cells.indentation)
        let columnWidth = (width - indentWidth - dividerWidth) / 2
        guard columnWidth > 0 else {
            // No room for two columns: degrade to stacked text rows rather
            // than emitting a row wider than the terminal.
            return (
                wrappedDetailedToolTextLines(
                    "\(cells.indentation)\(cells.oldCell)",
                    width: width
                )
                + wrappedDetailedToolTextLines(
                    "\(cells.indentation)\(cells.newCell)",
                    width: width
                )
            ).map(DetailedToolRow.text)
        }

        let oldFragments = TerminalANSIText.wrapPreservingWhitespace(
            cells.oldCell,
            width: columnWidth
        )
        let newFragments = TerminalANSIText.wrapPreservingWhitespace(
            cells.newCell,
            width: columnWidth
        )
        let rowCount = max(1, max(oldFragments.count, newFragments.count))
        return (0..<rowCount).map { index in
            let oldFragment = index < oldFragments.count ? oldFragments[index] : ""
            let newFragment = index < newFragments.count ? newFragments[index] : ""
            return .diff(DetailedToolDiffCells(
                indentation: cells.indentation,
                oldCell: paddedToColumnWidth(oldFragment, width: columnWidth),
                newCell: paddedToColumnWidth(newFragment, width: columnWidth)
            ))
        }
    }

    private nonisolated static func paddedToColumnWidth(
        _ text: String,
        width: Int
    ) -> String {
        text + String(repeating: " ", count: max(0, width - displayWidth(text)))
    }

    nonisolated static func compactToolInlineTarget(_ target: String) -> String {
        target
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    nonisolated static func fitDisplayWidth(_ text: String, width: Int) -> String {
        guard displayWidth(text) > width else {
            return text
        }
        guard width > 0 else {
            return ""
        }
        guard width > 3 else {
            // There is no room for the three-column ellipsis. Keep the prior
            // no-ellipsis fallback, but make it genuinely width-aware: a wide
            // grapheme cannot be copied into a one-cell budget.
            var output = ""
            var outputWidth = 0
            for character in text {
                let characterWidth = TerminalANSIText.visibleWidth(of: character)
                guard outputWidth + characterWidth <= width else {
                    break
                }
                output.append(character)
                outputWidth += characterWidth
            }
            return output
        }
        // Delegate the grapheme-safe cut to the shared width-aware core,
        // keeping the "..." ellipsis (width 3). The core measures each grapheme
        // with `visibleWidth(of:)`, so this no longer allocates a `String` per
        // character. `fitDisplayWidth` inputs carry no ANSI, so the core's
        // escape handling is a no-op and the output is byte-identical to the
        // previous inline loop.
        return TerminalANSIText.truncate(
            text,
            to: width,
            ellipsis: "...",
            ellipsisWidth: 3
        )
    }

    nonisolated static func displayWidth(_ text: String) -> Int {
        TerminalANSIText.visibleWidth(text)
    }

    /// Renders a structured detailed row. A side-by-side row draws its two
    /// cells from separate fields, so each is tokenized independently and no
    /// payload sequence can be mistaken for the divider.
    nonisolated static func renderDetailedToolRow(
        _ row: DetailedToolRow,
        codeLanguage: String? = nil
    ) -> String {
        switch row {
        case let .text(line):
            return renderDetailedToolLine(line, codeLanguage: codeLanguage)
        case let .diff(cells):
            return renderDiffCodeAreaLine(
                indentation: cells.indentation,
                oldCell: cells.oldCell,
                newCell: cells.newCell,
                language: codeLanguage
            )
        }
    }

    nonisolated static func renderDetailedToolLine(
        _ line: String,
        codeLanguage: String? = nil
    ) -> String {
        if line.hasPrefix("  ") || line.hasPrefix("    ") {
            return renderCodeAreaLine(line, language: codeLanguage)
        }
        // Split labeled metadata rows ("label: value") so the label keeps a
        // muted orange while the value drops to gray, keeping the block within
        // the orange family without being flat monochromatic. The title row
        // (icon + tool name, no leading label colon) stays full orange.
        if let colonIndex = line.firstIndex(of: ":"),
           isDetailedToolLabel(line[..<colonIndex]) {
            let label = line[...colonIndex]
            let value = line[line.index(after: colonIndex)...]
            return "\(toolLabelColor)\(label)\(toolValueColor)\(value)"
        }
        return "\(toolTitleColor)\(line)"
    }

    /// Renders a code snippet row of the expanded tool block: the line is
    /// syntax-highlighted for the target file's language and painted over a
    /// dark background that extends to the right edge of the terminal, so the
    /// whole code area reads as one framed block. Highlight resets emitted by
    /// the code renderer are re-anchored to the background color so token
    /// colors never punch holes in the frame.
    nonisolated static func renderCodeAreaLine(
        _ line: String,
        language: String?
    ) -> String {
        let clearToEnd = "\u{1B}[K"
        return "\(codeAreaBackgroundColor)\(renderCodeAreaFragment(line, language: language))\(clearToEnd)"
    }

    /// The old and new cells of a side-by-side diff must be tokenized as two
    /// independent source lines. In particular, a line comment or an unterminated
    /// string on the old side must not color the divider and hide highlighting on
    /// the new side.
    nonisolated static func renderDiffCodeAreaLine(
        indentation: String,
        oldCell: String,
        newCell: String,
        language: String?
    ) -> String {
        let clearToEnd = "\u{1B}[K"
        let divider = DetailedToolDiffCells.divider
        return "\(codeAreaBackgroundColor)\(indentation)\(renderCodeAreaFragment(oldCell, language: language))\(codeAreaBackgroundColor)\(divider)\(renderCodeAreaFragment(newCell, language: language))\(clearToEnd)"
    }

    private nonisolated static func renderCodeAreaFragment(
        _ line: String,
        language: String?
    ) -> String {
        let reset = "\u{1B}[0m"
        return TerminalCodeBlockRenderer
            .renderLine(line, language: language)
            .replacingOccurrences(of: reset, with: "\(reset)\(codeAreaBackgroundColor)")
    }

    /// Returns whether the text before the first colon looks like a metadata
    /// label (single lowercase word) rather than part of the tool title.
    nonisolated static func isDetailedToolLabel(_ candidate: Substring) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return false
        }
        return trimmed.allSatisfy { $0.isLowercase || $0.isLetter }
    }

                // Orange-family palette: full identity orange for titles, a muted
    // terracotta for labels, and a light peach-orange for values so the whole
    // tool block stays within the orange family while keeping a readable
    // hierarchy.
    nonisolated static let toolTitleColor = "\u{1B}[38;5;208m"
    nonisolated static let toolLabelColor = "\u{1B}[38;5;173m"
    nonisolated static let toolValueColor = "\u{1B}[38;5;215m"
    // Dark gray background framing the code areas of expanded tool blocks,
    // matching the background used for submitted prompts.
    nonisolated static let codeAreaBackgroundColor = "\u{1B}[48;5;236m"
    nonisolated static let expandedSnippetLineLimit = 100
    nonisolated static let expandedSnippetCharacterLimit = 10_000
}
