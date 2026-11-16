//
//  PresentationDocument.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import Markdown

/// Backend-neutral presentation tree. It is deliberately transient and contains
/// only user-visible content: transport metadata and tool payloads have no
/// representation here, and neither has reasoning (the Telegram thinking
/// message is a plain text with entities, see
/// ``TerminalTelegramTurnActivity/thoughtMessage(_:)``).
struct PresentationDocument: Sendable, Equatable {
    var blocks: [PresentationBlock]

    init(markdown: String) {
        var renderer = PresentationMarkdownRenderer()
        blocks = renderer.visit(Document(parsing: PresentationSanitizer.visibleText(markdown)))
    }

    var plainText: String {
        PresentationBlock.plainText(of: blocks)
    }
}

enum PresentationBlock: Sendable, Equatable {
    case paragraph(PresentationText)
    case heading(level: Int, text: PresentationText)
    case preformatted(code: String, language: String?)
    case list(PresentationList)
    case quote([PresentationBlock])
    case table(PresentationTable)
    case divider

    var plainText: String {
        switch self {
        case let .paragraph(text): text.plainText
        case let .heading(_, text): text.plainText
        case let .preformatted(code, _): code
        case let .list(list): list.plainText
        case let .quote(blocks): Self.quoted(Self.plainText(of: blocks))
        case let .table(table): table.plainText
        case .divider: "———"
        }
    }

    /// The plain-text projection of a sequence of blocks, as the document and
    /// a quotation join them: blank-line separated, empty blocks left out.
    static func plainText(of blocks: [PresentationBlock]) -> String {
        blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// `text` with every line preceded by `> `; empty stays empty.
    private static func quoted(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n")
    }
}

struct PresentationList: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case unordered
        case ordered(start: Int)
    }

    var kind: Kind
    var items: [PresentationListItem]

    /// The number an ordered list shows at `index`, counting from its start;
    /// `nil` for an unordered list.
    func number(at index: Int) -> Int? {
        guard case let .ordered(start) = kind else { return nil }
        return start + index
    }

    var plainText: String {
        items.indices.map(plainText(ofItemAt:)).joined(separator: "\n")
    }

    /// The item at `index` as ``plainText`` shows it: its marker, then its
    /// blocks one per line.
    func plainText(ofItemAt index: Int) -> String {
        let item = items[index]
        let marker = switch item.checkbox {
        case .checked: "☑"
        case .unchecked: "☐"
        case nil: number(at: index).map { "\($0)." } ?? "•"
        }
        let body = item.blocks.map(\.plainText).joined(separator: "\n")
        return "\(marker) \(body)"
    }
}

struct PresentationListItem: Sendable, Equatable {
    enum Checkbox: Sendable, Equatable {
        case unchecked
        case checked
    }

    var blocks: [PresentationBlock]
    /// The task-list box of the item; `nil` for an ordinary item.
    var checkbox: Checkbox? = nil
}

/// A table of inline-formatted cells: the header row first, then the body.
struct PresentationTable: Sendable, Equatable {
    enum Alignment: Sendable, Equatable {
        case left
        case center
        case right
    }

    /// One alignment per column, `left` where the source sets none.
    var alignments: [Alignment]
    var header: [PresentationText]
    var rows: [[PresentationText]]

    var columnCount: Int {
        ([alignments.count, header.count] + rows.map(\.count)).max() ?? 0
    }

    /// One line per row, header first, cells joined by ` | `.
    var plainText: String {
        ([header] + rows).filter { !$0.isEmpty }
            .map(Self.plainText(ofRow:))
            .joined(separator: "\n")
    }

    /// The line of one row in ``plainText``: its cells joined by ` | `.
    static func plainText(ofRow row: [PresentationText]) -> String {
        row.map(\.plainText).joined(separator: " | ")
    }
}

struct PresentationText: Sendable, Equatable {
    var runs: [PresentationTextRun]

    init(runs: [PresentationTextRun]) {
        self.runs = runs
    }

    var plainText: String { runs.map(\.plainText).joined() }
}

enum PresentationTextRun: Sendable, Equatable {
    case plain(String)
    case code(String)
    case emphasis(PresentationText)
    case strong(PresentationText)
    case strikethrough(PresentationText)
    case link(label: PresentationText, url: URL)

    var plainText: String {
        switch self {
        case let .plain(text), let .code(text): text
        case let .emphasis(text), let .strong(text), let .strikethrough(text): text.plainText
        case let .link(label, _): label.plainText
        }
    }
}

enum PresentationSanitizer {
    /// The wire-invisible controls and bidi overrides that
    /// ``visibleText(_:)`` removes, built once.
    private static let forbiddenScalars = CharacterSet(charactersIn:
        "\u{0000}\u{0001}\u{0002}\u{0003}\u{0004}\u{0005}\u{0006}\u{0007}\u{0008}\u{000B}\u{000C}\u{000E}\u{000F}" +
        "\u{0010}\u{0011}\u{0012}\u{0013}\u{0014}\u{0015}\u{0016}\u{0017}\u{0018}\u{0019}\u{001A}\u{001B}\u{001C}\u{001D}\u{001E}\u{001F}" +
        "\u{007F}\u{202A}\u{202B}\u{202D}\u{202E}\u{202C}\u{2066}\u{2067}\u{2068}\u{2069}"
    )

    /// Removes wire-invisible controls and bidi overrides while retaining normal
    /// whitespace. This protects client rendering without trying to redact the
    /// caller's already-approved visible answer.
    static func visibleText(_ value: String) -> String {
        String(value.unicodeScalars.filter { !forbiddenScalars.contains($0) })
    }
}

private struct PresentationMarkdownRenderer: MarkupVisitor {
    typealias Result = [PresentationBlock]

    mutating func defaultVisit(_ markup: Markup) -> [PresentationBlock] {
        markup.children.flatMap { visit($0) }
    }

    mutating func visitDocument(_ document: Document) -> [PresentationBlock] {
        document.children.flatMap { visit($0) }
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> [PresentationBlock] {
        [.paragraph(renderInline(paragraph))]
    }

    mutating func visitHeading(_ heading: Heading) -> [PresentationBlock] {
        [.heading(level: min(max(heading.level, 1), 6), text: renderInline(heading))]
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> [PresentationBlock] {
        let code = codeBlock.code.hasSuffix("\n") ? String(codeBlock.code.dropLast()) : codeBlock.code
        return [.preformatted(code: PresentationSanitizer.visibleText(code), language: codeBlock.language)]
    }

    /// Raw HTML is kept as the text it was written, never interpreted.
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> [PresentationBlock] {
        let raw = html.rawHTML.hasSuffix("\n") ? String(html.rawHTML.dropLast()) : html.rawHTML
        return [.paragraph(PresentationText(runs: [.plain(PresentationSanitizer.visibleText(raw))]))]
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> [PresentationBlock] {
        [.quote(blockQuote.children.flatMap { visit($0) })]
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> [PresentationBlock] {
        [.divider]
    }

    mutating func visitTable(_ table: Table) -> [PresentationBlock] {
        let alignments = table.columnAlignments.map { alignment -> PresentationTable.Alignment in
            switch alignment {
            case .center: .center
            case .right: .right
            case .left, nil: .left
            }
        }
        return [.table(PresentationTable(
            alignments: alignments,
            header: table.head.cells.map { renderInline($0) },
            rows: table.body.rows.map { row in row.cells.map { renderInline($0) } }
        ))]
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> [PresentationBlock] {
        [.list(PresentationList(kind: .unordered, items: unorderedList.listItems.map { renderItem($0) }))]
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> [PresentationBlock] {
        [.list(PresentationList(
            kind: .ordered(start: Int(clamping: orderedList.startIndex)),
            items: orderedList.listItems.map { renderItem($0) }
        ))]
    }

    private mutating func renderItem(_ item: ListItem) -> PresentationListItem {
        let checkbox: PresentationListItem.Checkbox? = switch item.checkbox {
        case .checked: .checked
        case .unchecked: .unchecked
        case nil: nil
        }
        return PresentationListItem(blocks: item.children.flatMap { visit($0) }, checkbox: checkbox)
    }

    private func renderInline(_ markup: Markup) -> PresentationText {
        PresentationText(runs: markup.children.flatMap(renderRun))
    }

    private func renderRun(_ markup: Markup) -> [PresentationTextRun] {
        if let text = markup as? Text { return [.plain(PresentationSanitizer.visibleText(text.string))] }
        if let code = markup as? InlineCode { return [.code(PresentationSanitizer.visibleText(code.code))] }
        if let emphasis = markup as? Emphasis {
            return [.emphasis(PresentationText(runs: emphasis.children.flatMap(renderRun)))]
        }
        if let strong = markup as? Strong {
            return [.strong(PresentationText(runs: strong.children.flatMap(renderRun)))]
        }
        if let strikethrough = markup as? Strikethrough {
            return [.strikethrough(PresentationText(runs: strikethrough.children.flatMap(renderRun)))]
        }
        if let html = markup as? InlineHTML { return [.plain(PresentationSanitizer.visibleText(html.rawHTML))] }
        if let link = markup as? Link {
            return linkRuns(label: link.children.flatMap(renderRun), destination: link.destination)
        }
        if let image = markup as? Image {
            // An image is a link labelled with its alternative text, or with
            // its source when it has none.
            let alt = image.children.flatMap(renderRun)
            let label = PresentationText(runs: alt).plainText.isEmpty
                ? image.source.map { [.plain(PresentationSanitizer.visibleText($0))] } ?? []
                : alt
            return linkRuns(label: label, destination: image.source)
        }
        if markup is SoftBreak { return [.plain("\n")] }
        if markup is LineBreak { return [.plain("\n")] }
        return markup.children.flatMap(renderRun)
    }

    /// The runs of a link: an `https` or `tg` destination stays a link; an
    /// `http` one is never clickable but keeps its URL in the text, as
    /// `label (url)`, or `url` alone when the label is empty or the URL itself;
    /// any other scheme, a relative or an invalid destination keeps only the
    /// label.
    private func linkRuns(label: [PresentationTextRun], destination: String?) -> [PresentationTextRun] {
        guard let destination = destination.map(PresentationSanitizer.visibleText),
              let url = URL(string: destination),
              let scheme = url.scheme?.lowercased() else {
            return label
        }
        switch scheme {
        case "https", "tg":
            return [.link(label: PresentationText(runs: label), url: url)]
        case "http":
            let labelText = PresentationText(runs: label).plainText
            if labelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || labelText == destination {
                return [.plain(destination)]
            }
            return label + [.plain(" (\(destination))")]
        default:
            return label
        }
    }
}
