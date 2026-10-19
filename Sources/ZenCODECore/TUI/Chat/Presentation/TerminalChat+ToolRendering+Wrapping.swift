//
//  TerminalChat+ToolRendering+Wrapping.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

extension TerminalChat {
    /// Reflows detailed tool rows before they are rendered in an in-place
    /// block. One terminal cell remains unused on every row because a line
    /// ending in the final column has terminal-dependent auto-wrap behavior;
    /// that would make the cursor position disagree with the saved row count
    /// used to redraw the tool on completion.
    nonisolated static func safelyWrappedDetailedToolRows(
        _ rows: [DetailedToolRow],
        contentInsetWidth: Int = 0,
        columnWidth: Int? = nil,
        codeLanguage: String? = nil
    ) -> [DetailedToolRow] {
        let resolvedColumns = columnWidth ?? terminalColumnCount()
        let contentColumns = max(1, resolvedColumns - contentInsetWidth)
        let safeLineWidth = max(1, contentColumns - 1)

        return rows.flatMap { row -> [DetailedToolRow] in
            switch row {
            case let .text(line):
                return wrappedDetailedToolTextLines(line, width: safeLineWidth)
                    .map(DetailedToolRow.text)
            case let .parameter(line, highlightsJSON):
                return wrappedDetailedToolTextLines(line, width: safeLineWidth)
                    .map { .parameter($0, highlightsJSON: highlightsJSON) }
            case let .code(line):
                return wrappedDetailedToolCodeRows(
                    line,
                    width: safeLineWidth,
                    codeLanguage: codeLanguage
                )
            case let .diff(cells):
                return wrappedDetailedToolDiffRows(
                    cells,
                    width: safeLineWidth,
                    codeLanguage: codeLanguage
                )
            case let .unifiedDiff(line):
                return wrappedDetailedToolUnifiedDiffRows(
                    line,
                    width: safeLineWidth,
                    codeLanguage: codeLanguage
                )
            }
        }
    }

    /// Reflows a source or unified-diff line within its single code column. Only
    /// the content is highlighted and wrapped; continuation rows (built by `row`)
    /// repeat neither the line number nor re-highlight. A terminal narrower than
    /// the gutter degrades to the text fallback instead of exceeding the width.
    nonisolated static func wrappedDetailedToolSourceRows(
        plainText: String,
        prefix: String,
        content: String,
        unwrapped: DetailedToolRow,
        width: Int,
        codeLanguage: String?,
        row: (_ index: Int, _ fragment: String) -> DetailedToolRow
    ) -> [DetailedToolRow] {
        guard displayWidth(plainText) > width else {
            return [unwrapped]
        }
        let prefixWidth = displayWidth(prefix)
        guard prefixWidth < width else {
            return wrappedDetailedToolTextLines(plainText, width: width).map(DetailedToolRow.text)
        }
        let highlighted = codeLanguage.map { renderCodeAreaFragment(content, language: $0) } ?? content
        return TerminalANSIText.wrapPreservingWhitespace(highlighted, width: width - prefixWidth)
            .enumerated()
            .map { row($0.offset, $0.element) }
    }

    nonisolated static func wrappedDetailedToolCodeRows(
        _ line: DetailedToolCodeLine,
        width: Int,
        codeLanguage: String?
    ) -> [DetailedToolRow] {
        wrappedDetailedToolSourceRows(
            plainText: line.plainText,
            prefix: line.prefix,
            content: line.content,
            unwrapped: .code(line),
            width: width,
            codeLanguage: codeLanguage
        ) { index, fragment in
            let wrappedLine = index == 0 ? line : line.continuation
            return .code(DetailedToolCodeLine(
                indentation: wrappedLine.indentation,
                lineNumber: wrappedLine.lineNumber,
                content: fragment,
                contentIsPreHighlighted: codeLanguage != nil
            ))
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

    nonisolated static func wrappedDetailedToolTextLines(
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
    nonisolated static func wrappedDetailedToolDiffRows(
        _ cells: DetailedToolDiffCells,
        width: Int,
        codeLanguage: String?
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

        func fragments(_ cell: String) -> [String] {
            TerminalANSIText.wrapPreservingWhitespace(
                codeLanguage.map { renderDiffCellFragment(cell, language: $0) } ?? cell,
                width: columnWidth
            )
        }
        let oldFragments = fragments(cells.oldCell)
        let newFragments = fragments(cells.newCell)
        let paddingStyle = codeLanguage == nil ? "" : codeAreaBackgroundColor
        return (0..<max(1, oldFragments.count, newFragments.count)).map { index in
            .diff(DetailedToolDiffCells(
                indentation: cells.indentation,
                oldCell: paddedToColumnWidth(
                    index < oldFragments.count ? oldFragments[index] : "",
                    width: columnWidth,
                    paddingStyle: paddingStyle
                ),
                newCell: paddedToColumnWidth(
                    index < newFragments.count ? newFragments[index] : "",
                    width: columnWidth,
                    paddingStyle: paddingStyle
                ),
                cellsArePreHighlighted: codeLanguage != nil
            ))
        }
    }

    nonisolated static func wrappedDetailedToolUnifiedDiffRows(
        _ line: DetailedToolUnifiedDiffLine,
        width: Int,
        codeLanguage: String?
    ) -> [DetailedToolRow] {
        wrappedDetailedToolSourceRows(
            plainText: line.plainText,
            prefix: line.prefix,
            content: line.content,
            unwrapped: .unifiedDiff(line),
            width: width,
            codeLanguage: codeLanguage
        ) { index, fragment in
            let wrappedLine = index == 0 ? line : line.continuation
            return .unifiedDiff(DetailedToolUnifiedDiffLine(
                indentation: wrappedLine.indentation,
                marker: wrappedLine.marker,
                lineNumber: wrappedLine.lineNumber,
                content: fragment,
                contentIsPreHighlighted: codeLanguage != nil
            ))
        }
    }

    nonisolated static func paddedToColumnWidth(
        _ text: String,
        width: Int,
        paddingStyle: String = ""
    ) -> String {
        let padding = max(0, width - displayWidth(text))
        guard padding > 0 else {
            return text
        }
        return "\(text)\(paddingStyle)\(String(repeating: " ", count: padding))"
    }
}
