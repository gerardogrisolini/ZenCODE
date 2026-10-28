//
//  ZenCronMailPlainText.swift
//  ZenCODE
//

import Foundation
import Markdown

/// Turns the Markdown answer of a scheduled run into the plain text that goes
/// in the body of the message Mail.app sends.
///
/// Mail.app accepts only plain text as a message body (the scripting
/// dictionary's `html content` property does nothing), so Markdown syntax
/// would arrive as literal `**`, `#` and `|` characters. The conversion keeps
/// the structure (paragraphs, lists, quotes) and spells out what plain text
/// cannot show (links, tables) in a form that reads well unformatted:
///
/// - Top-level blocks are separated by one blank line and the text ends with
///   one line break; an empty document is the empty string.
/// - Headings, emphasis and code spans keep only their text. Line breaks of
///   the source, soft or hard, are kept as line breaks.
/// - Lists use `•` (`◦` from the second level), `N.` from the list's start
///   index, and `[ ]` / `[x]` in place of the bullet for task items. The
///   lines of an item, nested lists included, align with the text after its
///   marker.
/// - Links read `text (url)`; the url is left out when it only repeats the
///   text. Images read `alt (url)`.
/// - Code blocks are indented by four spaces, block quotes get a `│ ` prefix
///   and thematic breaks are a line of `─`.
/// - A table has no portable plain-text layout (Mail's default format does not
///   guarantee spaces for alignment), so each body row becomes a block of
///   `Header: value` lines, and a table without body rows is its headers on
///   one line.
/// - `<br>` is a line break; any other raw HTML stays literal.
/// - The text is the author's: straight quotes, `--` and `...` are not turned
///   into their typographic forms (a flag such as `--jsonl` must stay one).
/// - No line ends with a space or a tab: Mail sends plain text as
///   `format=flowed`, where the recipient's client joins a line that ends with
///   a space to the next one.
enum ZenCronMailPlainText {
    nonisolated static func render(markdown: String) -> String {
        var renderer = Renderer()
        return renderer.visit(Document(parsing: markdown, options: .disableSmartOpts))
    }

    nonisolated private static func isLineBreakTag(_ rawHTML: String) -> Bool {
        ["<br>", "<br/>", "<br />"].contains(rawHTML.lowercased())
    }

    private struct Renderer: MarkupVisitor {
        typealias Result = String

        private static let thematicBreakWidth = 40
        private static let firstLevelBullet = "•"
        private static let nestedBullet = "◦"
        private static let quotePrefix = "│"
        private static let codeIndent = "    "

        /// How many lists enclose the markup being rendered, the one being
        /// rendered included.
        private var listDepth = 0

        // MARK: - Fallback

        /// Containers that have no rendering of their own (emphasis,
        /// strikethrough and the like) show the content of their children.
        mutating func defaultVisit(_ markup: Markup) -> String {
            renderInlines(of: markup)
        }

        // MARK: - Blocks

        mutating func visitDocument(_ document: Document) -> String {
            listDepth = 0
            let text = renderBlocks(of: document).joined(separator: "\n\n")
            return Self.finish(text)
        }

        mutating func visitParagraph(_ paragraph: Paragraph) -> String {
            renderInlines(of: paragraph)
        }

        mutating func visitHeading(_ heading: Heading) -> String {
            renderInlines(of: heading)
        }

        mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
            String(repeating: "─", count: Self.thematicBreakWidth)
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
            var code = codeBlock.code
            if code.hasSuffix("\n") {
                code.removeLast()
            }
            return code
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? "" : Self.codeIndent + $0 }
                .joined(separator: "\n")
        }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
            renderBlocks(of: blockQuote)
                .joined(separator: "\n\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? Self.quotePrefix : Self.quotePrefix + " " + $0 }
                .joined(separator: "\n")
        }

        mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
            var raw = html.rawHTML
            if raw.hasSuffix("\n") {
                raw.removeLast()
            }
            // A block that is only a line break adds nothing to the blank line
            // that already separates blocks.
            return ZenCronMailPlainText.isLineBreakTag(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                ? ""
                : raw
        }

        // MARK: - Lists

        mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
            listDepth += 1
            defer { listDepth -= 1 }
            let bullet = listDepth == 1 ? Self.firstLevelBullet : Self.nestedBullet
            var items: [String] = []
            for item in unorderedList.listItems {
                items.append(renderItem(item, marker: bullet, isOrdered: false))
            }
            return items.joined(separator: "\n")
        }

        mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
            listDepth += 1
            defer { listDepth -= 1 }
            var number = orderedList.startIndex
            var items: [String] = []
            for item in orderedList.listItems {
                items.append(renderItem(item, marker: "\(number).", isOrdered: true))
                number += 1
            }
            return items.joined(separator: "\n")
        }

        /// One item: its marker, then its content with every line after the
        /// first aligned under the text that follows the marker. A task item's
        /// box takes the place of a bullet and follows the number of an
        /// ordered item.
        private mutating func renderItem(
            _ item: ListItem,
            marker: String,
            isOrdered: Bool
        ) -> String {
            let box: String?
            switch item.checkbox {
            case .checked:
                box = "[x]"
            case .unchecked:
                box = "[ ]"
            case nil:
                box = nil
            }
            let prefix: String
            if let box {
                prefix = isOrdered ? "\(marker) \(box) " : "\(box) "
            } else {
                prefix = "\(marker) "
            }

            // Consecutive paragraphs are separated by a blank line; a nested
            // list follows the text it belongs to directly.
            var content = ""
            var previous: Markup?
            for child in item.children {
                let rendered = visit(child)
                guard !rendered.isEmpty else {
                    continue
                }
                if let previous {
                    let startsNestedList = child is UnorderedList || child is OrderedList
                    content += startsNestedList && previous is Paragraph ? "\n" : "\n\n"
                }
                content += rendered
                previous = child
            }

            let indent = String(repeating: " ", count: prefix.count)
            return content
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .map { index, line in (index == 0 ? prefix : indent) + line }
                .joined(separator: "\n")
        }

        // MARK: - Tables

        mutating func visitTable(_ table: Table) -> String {
            var headers: [String] = []
            for cell in table.head.cells {
                headers.append(singleLine(renderInlines(of: cell)))
            }

            var rows: [[String]] = []
            var hasBodyRows = false
            for row in table.body.rows {
                hasBodyRows = true
                var lines: [String] = []
                var column = 0
                for cell in row.cells {
                    defer { column += 1 }
                    let value = singleLine(renderInlines(of: cell))
                    guard !value.isEmpty else {
                        continue
                    }
                    let header = column < headers.count ? headers[column] : ""
                    lines.append(header.isEmpty ? value : "\(header): \(value)")
                }
                if !lines.isEmpty {
                    rows.append(lines)
                }
            }

            guard hasBodyRows else {
                return headers.filter { !$0.isEmpty }.joined(separator: " · ")
            }
            return rows
                .map { $0.joined(separator: "\n") }
                .joined(separator: "\n\n")
        }

        /// A table cell on one line: the line breaks inside it become single
        /// spaces.
        private func singleLine(_ text: String) -> String {
            text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        // MARK: - Inlines

        mutating func visitText(_ text: Text) -> String {
            text.string
        }

        mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
            inlineCode.code
        }

        mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
            "\n"
        }

        mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
            "\n"
        }

        mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
            ZenCronMailPlainText.isLineBreakTag(inlineHTML.rawHTML) ? "\n" : inlineHTML.rawHTML
        }

        mutating func visitLink(_ link: Link) -> String {
            let text = renderInlines(of: link)
            guard let destination = link.destination, !destination.isEmpty else {
                return text
            }
            if text.isEmpty {
                return destination
            }
            if text == destination || destination == "mailto:" + text {
                return text
            }
            return "\(text) (\(destination))"
        }

        mutating func visitImage(_ image: Image) -> String {
            let alt = renderInlines(of: image)
            guard let source = image.source, !source.isEmpty else {
                return alt
            }
            return alt.isEmpty ? source : "\(alt) (\(source))"
        }

        // MARK: - Helpers

        /// The rendering of every child that has one, in order.
        private mutating func renderBlocks(of markup: Markup) -> [String] {
            var blocks: [String] = []
            for child in markup.children {
                let rendered = visit(child)
                if !rendered.isEmpty {
                    blocks.append(rendered)
                }
            }
            return blocks
        }

        private mutating func renderInlines(of markup: Markup) -> String {
            var text = ""
            for child in markup.children {
                text += visit(child)
            }
            return text
        }

        /// Removes the spaces and tabs that end a line and the line breaks that
        /// end the text, then ends the text with one line break. Nothing is left
        /// of a document that has no visible content.
        private static func finish(_ text: String) -> String {
            var lines = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    var line = Substring(line)
                    while let last = line.last, last == " " || last == "\t" {
                        line.removeLast()
                    }
                    return String(line)
                }
            while let last = lines.last, last.isEmpty {
                lines.removeLast()
            }
            guard !lines.isEmpty else {
                return ""
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }
}
