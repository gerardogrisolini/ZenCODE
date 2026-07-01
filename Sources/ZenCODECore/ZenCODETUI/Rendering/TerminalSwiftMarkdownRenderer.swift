//
//  TerminalSwiftMarkdownRenderer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation
import Markdown

struct TerminalSwiftMarkdownRenderer: MarkupVisitor {
    typealias Result = String

    private static let reset = "\u{1B}[0m"
    private static let bold = "\u{1B}[1m"
    private static let italic = "\u{1B}[3m"
    private static let strikethrough = "\u{1B}[9m"
    private static let dim = "\u{1B}[90m"
    private static let code = "\u{1B}[38;5;180m"
    private static let bullet = "\u{1B}[38;5;244m"
    private static let link = "\u{1B}[38;5;75m"
    private static let quoteBar = "\u{1B}[38;5;108m"
    private static let tableBorder = "\u{1B}[38;5;240m"
    private static let tableHeader = "\u{1B}[1;38;5;81m"

    /// Per-level heading styles, brightest/boldest for top-level headings and
    /// progressively softer for deeper levels so the hierarchy reads visually.
    private static let headingStyles: [String] = [
        "\u{1B}[1;38;5;81m",   // h1 - bold cyan
        "\u{1B}[1;38;5;75m",   // h2 - bold azure
        "\u{1B}[1;38;5;111m",  // h3 - bold periwinkle
        "\u{1B}[38;5;111m",    // h4 - periwinkle
        "\u{1B}[38;5;110m",    // h5 - steel
        "\u{1B}[38;5;109m"     // h6 - muted steel
    ]

    /// Bullet glyphs per nesting depth, cycling for deeper levels.
    private static let bulletGlyphs = ["•", "◦", "▪", "‣"]

    /// Visible-column bounds used when drawing thematic breaks.
    private static let maxRuleWidth = 80
    private static let defaultRuleWidth = 40
    private static let minRuleWidth = 8

    /// Indentation applied per nested-list level.
    private static let nestedIndent = "  "

    /// True when the host terminal advertises OSC 8 hyperlink support. Most
    /// modern terminals do; fall back to inline `<url>` annotations otherwise.
    let supportsHyperlinks: Bool

    /// Visible width of a checkbox marker (`[x] ` or `[ ] `), including the
    /// trailing space. Used to compute continuation indentation for list items.
    private static let checkboxMarkerWidth = 4

    /// Maximum visible width of a URL in the non-hyperlink fallback before it
    /// is truncated with an ellipsis. Keeps long URLs from disrupting layout.
    private static let maxFallbackURLWidth = 40

    /// Visible width used for horizontal rules. Wrapping is handled by the
    /// stream formatter and table alignment is based on measured cell content.
    let renderWidth: Int

    private static let nestedListLinePrefix = "\u{E000}"

    private var listDepth = 0

    init(supportsHyperlinks: Bool = false, renderWidth: Int = 0) {
        self.supportsHyperlinks = supportsHyperlinks
        self.renderWidth = renderWidth
    }

    mutating func defaultVisit(_ markup: Markup) -> String {
        renderChildren(of: markup)
    }

    mutating func visitDocument(_ document: Document) -> String {
        listDepth = 0
        defer { listDepth = 0 }
        let rendered = renderChildren(of: document, separator: "\n\n")
        // Safety fallback: strip any nested-list line markers that leaked
        // through due to an unexpected control-flow path. The marker uses a
        // Private Use Area character that would render as an invisible glyph
        // if it reached the terminal.
        if rendered.contains(Self.nestedListLinePrefix) {
            return rendered.replacingOccurrences(of: Self.nestedListLinePrefix, with: "")
        }
        return rendered
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        renderChildren(of: paragraph)
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let level = max(1, min(heading.level, Self.headingStyles.count))
        let style = Self.headingStyles[level - 1]
        let prefix = String(repeating: "#", count: level)
        let body = renderChildren(of: heading)
        return applyStyle(style, to: "\(prefix) \(body)")
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        let body = renderChildren(of: blockQuote, separator: "\n")
        // Each line gets a quote bar prefix. Continuation lines from nested
        // blocks (lists, code blocks) are indented to align with the text
        // column after the bar, keeping the quote visually coherent.
        let prefix = "\(Self.quoteBar)▌\(Self.reset) "
        let indent = String(repeating: " ", count: 2)
        let quoted = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if line.isEmpty {
                    return "\(Self.quoteBar)▌\(Self.reset)"
                }
                // Lines already indented from nested content get aligned
                // under the quote text column.
                if line.first == " " || line.first == "\t" {
                    return "\(prefix)\(applyStyle(Self.dim, to: "\(indent)\(line)"))"
                }
                return "\(prefix)\(applyStyle(Self.dim, to: String(line)))"
            }
            .joined(separator: "\n")
        return quoted
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        listDepth += 1
        defer { listDepth -= 1 }
        let glyph = Self.bulletGlyphs[(listDepth - 1) % Self.bulletGlyphs.count]
        var renderedItems: [String] = []
        for item in unorderedList.listItems {
            renderedItems.append(renderListItem(item, marker: glyph))
        }
        let rendered = indentNestedList(renderedItems.joined(separator: "\n"))
        return listDepth > 1 ? markNestedListLines(rendered) : rendered
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        listDepth += 1
        defer { listDepth -= 1 }
        var number = Int(orderedList.startIndex)
        var renderedItems: [String] = []
        for item in orderedList.listItems {
            renderedItems.append(renderListItem(item, marker: "\(number)."))
            number += 1
        }
        let rendered = indentNestedList(renderedItems.joined(separator: "\n"))
        return listDepth > 1 ? markNestedListLines(rendered) : rendered
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        renderChildren(of: listItem, separator: "\n")
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let fence = codeBlock.language.map { "```\($0)" } ?? "```"
        let trimmedCode = codeBlock.code.hasSuffix("\n")
        ? String(codeBlock.code.dropLast())
        : codeBlock.code
        return [
            "\(Self.dim)\(fence)\(Self.reset)",
            TerminalCodeBlockRenderer.renderBlock(
                trimmedCode,
                language: codeBlock.language
            ),
            "\(Self.dim)```\(Self.reset)"
        ].joined(separator: "\n")
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        let width = renderWidth > 0 ? min(renderWidth, Self.maxRuleWidth) : Self.defaultRuleWidth
        return "\(Self.dim)\(String(repeating: "─", count: max(Self.minRuleWidth, width)))\(Self.reset)"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "\(Self.code)\(inlineCode.code)\(Self.reset)"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        applyStyle(Self.bold, to: renderChildren(of: strong))
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        applyStyle(Self.italic, to: renderChildren(of: emphasis))
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        applyStyle(Self.strikethrough, to: renderChildren(of: strikethrough))
    }

    mutating func visitLink(_ link: Link) -> String {
        let label = renderChildren(of: link)
        guard let destination = link.destination,
            !destination.isEmpty,
            TerminalANSIText.stripANSI(label) != destination else {
            return label
        }
        if supportsHyperlinks {
            let open = "\u{1B}]8;;\(destination)\u{1B}\u{5C}"
            let close = "\u{1B}]8;;\u{1B}\u{5C}"
            return "\(open)\(applyStyle(Self.link, to: label))\(close)"
        }
        let displayURL: String
        if destination.count > Self.maxFallbackURLWidth {
            displayURL = String(destination.prefix(Self.maxFallbackURLWidth - 1)) + "…"
        } else {
            displayURL = destination
        }
        return "\(applyStyle(Self.link, to: label)) \(Self.dim)<\(displayURL)>\(Self.reset)"
    }

    mutating func visitImage(_ image: Image) -> String {
        let label = renderChildren(of: image)
        let alt = label.isEmpty ? "image" : label
        guard let source = image.source, !source.isEmpty else {
            return "\(Self.dim)🖼 \(alt)\(Self.reset)"
        }
        return "\(Self.dim)🖼 \(alt) <\(source)>\(Self.reset)"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        "\(Self.code)\(inlineHTML.rawHTML)\(Self.reset)"
    }

    mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) -> String {
        "\(Self.dim)\(htmlBlock.rawHTML)\(Self.reset)"
    }

    mutating func visitTable(_ table: Table) -> String {
        renderTable(table)
    }

    /// Soft breaks (single newline in source) are rendered as a newline in the
    /// terminal. Unlike HTML, where a soft break may collapse to a space, the
    /// TUI benefits from preserving the line break for readability.
    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    /// Hard breaks (two trailing spaces or a backslash) are also rendered as a
    /// newline, matching the visual intent of the author.
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "\n"
    }

    mutating func visitText(_ text: Text) -> String {
        text.string
    }

    private mutating func renderChildren(
        of markup: Markup,
        separator: String = ""
    ) -> String {
        var rendered: [String] = []
        for child in markup.children {
            rendered.append(visit(child))
        }
        return rendered.joined(separator: separator)
    }

    private func applyStyle(_ style: String, to content: String) -> String {
        let restyled = content.replacingOccurrences(
            of: Self.reset,
            with: "\(Self.reset)\(style)"
        )
        return "\(style)\(restyled)\(Self.reset)"
    }

    /// Indents the rendered content of a nested list one level deeper than its
    /// parent so the hierarchy is visible. Top-level lists stay flush left.
    private func indentNestedList(_ content: String) -> String {
        guard listDepth > 1 else {
            return content
        }
        return content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.nestedIndent + $0 }
            .joined(separator: "\n")
    }

    /// Marks lines that came from a nested list so the parent list item can avoid
    /// applying paragraph continuation indentation to them. The marker is private
    /// to this renderer and is stripped before output is returned.
    private func markNestedListLines(_ content: String) -> String {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self.nestedListLinePrefix + $0 }
            .joined(separator: "\n")
    }

    private func unmarkNestedListLine(_ line: String) -> (line: String, isNestedListLine: Bool) {
        guard line.hasPrefix(Self.nestedListLinePrefix) else {
            return (line, false)
        }
        return (String(line.dropFirst(Self.nestedListLinePrefix.count)), true)
    }

    private mutating func renderListItem(
        _ listItem: ListItem,
        marker: String
    ) -> String {
        let checkbox = listItem.checkbox.map {
            switch $0 {
            case .checked:
                return "\(Self.code)[x]\(Self.reset) "
            case .unchecked:
                return "\(Self.bullet)[ ]\(Self.reset) "
            }
        } ?? ""
        let checkboxWidth = listItem.checkbox == nil ? 0 : Self.checkboxMarkerWidth
        let content = renderChildren(of: listItem, separator: "\n")
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let renderedMarker = "\(Self.bullet)\(marker)\(Self.reset)"
        guard let firstRawLine = lines.first else {
            return "\(renderedMarker) \(checkbox)"
        }

        let firstLine = unmarkNestedListLine(firstRawLine).line
        let continuationIndent = String(repeating: " ", count: marker.count + checkboxWidth + 1)
        let first = "\(renderedMarker) \(checkbox)\(firstLine)"
        let rest = lines.dropFirst()
            .map { rawLine -> String in
                let line = unmarkNestedListLine(rawLine)
                if line.isNestedListLine {
                    return "\n\(line.line)"
                }
                return "\n\(continuationIndent)\(line.line)"
            }
            .joined()
        return first + rest
    }

    // MARK: - Tables

    private mutating func renderTable(_ table: Table) -> String {
        var headerCells: [String] = []
        for cell in table.head.cells {
            headerCells.append(renderChildren(of: cell))
        }

        var bodyRows: [[String]] = []
        for row in table.body.rows {
            var cells: [String] = []
            for cell in row.cells {
                cells.append(renderChildren(of: cell))
            }
            bodyRows.append(cells)
        }

        let columnCount = max(headerCells.count, bodyRows.map(\.count).max() ?? 0)
        guard columnCount > 0 else {
            return ""
        }

        headerCells = padCells(headerCells, to: columnCount)
        bodyRows = bodyRows.map { padCells($0, to: columnCount) }

        var widths = [Int](repeating: 0, count: columnCount)
        for (index, cell) in headerCells.enumerated() {
            widths[index] = max(widths[index], TerminalANSIText.visibleWidth(cell))
        }
        for row in bodyRows {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], TerminalANSIText.visibleWidth(cell))
            }
        }

        // When the terminal width is known, shrink columns so the table fits.
        // Account for borders: each column has 1 space of padding on each side
        // plus a border character, plus the leftmost border.
        if renderWidth > 0 {
            let overhead = columnCount * 3 + 1
            let available = max(renderWidth - overhead, columnCount)
            let total = widths.reduce(0, +)
            if total > available {
                let minColumnWidth = 3
                // Proportionally shrink each column, ensuring a minimum width.
                let scale = Double(available) / Double(total)
                widths = widths.map { max(minColumnWidth, Int(Double($0) * scale)) }
                // Flooring at `minColumnWidth` can push the sum back above
                // `available`, making the row exceed `renderWidth`. Trim the
                // widest columns until it fits (or all are at the minimum).
                var currentTotal = widths.reduce(0, +)
                while currentTotal > available,
                      let widest = widths.indices.max(by: { widths[$0] < widths[$1] }),
                      widths[widest] > minColumnWidth {
                    widths[widest] -= 1
                    currentTotal -= 1
                }
                // Truncate cell content to the new widths.
                headerCells = headerCells.enumerated().map { index, cell in
                    TerminalANSIText.truncate(cell, to: widths[index])
                }
                bodyRows = bodyRows.map { row in
                    row.enumerated().map { index, cell in
                        TerminalANSIText.truncate(cell, to: widths[index])
                    }
                }
            }
        }

        let alignments = columnAlignments(for: table, columnCount: columnCount)

        var lines: [String] = []
        lines.append(renderTableBorder(widths: widths, kind: .top))
        lines.append(renderTableRow(headerCells, widths: widths, alignments: alignments, isHeader: true))
        lines.append(renderTableBorder(widths: widths, kind: .middle))
        for row in bodyRows {
            lines.append(renderTableRow(row, widths: widths, alignments: alignments, isHeader: false))
        }
        lines.append(renderTableBorder(widths: widths, kind: .bottom))
        return lines.joined(separator: "\n")
    }

    private func padCells(_ cells: [String], to count: Int) -> [String] {
        guard cells.count < count else {
            return cells
        }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    private func columnAlignments(
        for table: Table,
        columnCount: Int
    ) -> [Table.ColumnAlignment?] {
        var alignments = table.columnAlignments
        if alignments.count < columnCount {
            alignments += Array(repeating: nil, count: columnCount - alignments.count)
        } else if alignments.count > columnCount {
            alignments = Array(alignments.prefix(columnCount))
        }
        return alignments
    }

    private enum TableBorderKind {
        case top, middle, bottom
    }

    private func renderTableBorder(widths: [Int], kind: TableBorderKind) -> String {
        let (left, joint, right): (String, String, String)
        switch kind {
        case .top:
            (left, joint, right) = ("┌", "┬", "┐")
        case .middle:
            (left, joint, right) = ("├", "┼", "┤")
        case .bottom:
            (left, joint, right) = ("└", "┴", "┘")
        }
        let segments = widths.map { String(repeating: "─", count: $0 + 2) }
        return "\(Self.tableBorder)\(left)\(segments.joined(separator: joint))\(right)\(Self.reset)"
    }

    private func renderTableRow(
        _ cells: [String],
        widths: [Int],
        alignments: [Table.ColumnAlignment?],
        isHeader: Bool
    ) -> String {
        var rendered: [String] = []
        for (index, cell) in cells.enumerated() {
            let width = widths[index]
            let alignment = alignments.indices.contains(index) ? alignments[index] : nil
            let padded = padCell(cell, to: width, alignment: alignment)
            let styled = isHeader ? styleTableHeaderCell(padded) : padded
            rendered.append(" \(styled) ")
        }
        let separator = "\(Self.tableBorder)│\(Self.reset)"
        return separator + rendered.joined(separator: separator) + separator
    }

    private func styleTableHeaderCell(_ cell: String) -> String {
        applyStyle(Self.tableHeader, to: cell)
    }

    private func padCell(
        _ cell: String,
        to width: Int,
        alignment: Table.ColumnAlignment?
    ) -> String {
        let visible = TerminalANSIText.visibleWidth(cell)
        let padding = max(0, width - visible)
        switch alignment {
        case .right:
            return String(repeating: " ", count: padding) + cell
        case .center:
            let left = padding / 2
            let right = padding - left
            return String(repeating: " ", count: left) + cell + String(repeating: " ", count: right)
        default:
            return cell + String(repeating: " ", count: padding)
        }
    }
}
