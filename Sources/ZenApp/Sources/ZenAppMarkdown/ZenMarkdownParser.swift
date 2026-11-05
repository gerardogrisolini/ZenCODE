//
//  ZenMarkdownParser.swift
//  ZenApp
//
//  Converts Markdown into `ZenMarkdownBlock`s with swift-markdown (CommonMark
//  plus the GFM tables, strikethrough, autolink and task-list extensions).
//

import Foundation
import Markdown

/// Parses Markdown into the block model drawn by `ZenMarkdownView`.
///
/// Parsing never fails: any string, including a partial document received
/// while streaming, produces blocks. An unterminated code fence becomes a
/// code block running to the end of the input, as CommonMark specifies.
public enum ZenMarkdownParser {
    /// Parses `markdown` into blocks.
    public static func blocks(from markdown: String) -> [ZenMarkdownBlock] {
        var builder = ZenMarkdownBlockBuilder()
        return builder.visit(Document(parsing: markdown))
    }

    /// Completed documents, parsed once per distinct string.
    private static let documentCache = ZenMarkdownCache<String, [ZenMarkdownBlock]>(capacity: 256)
    /// Partial documents of active streams, kept apart so the many short-lived
    /// prefixes of a stream never evict completed documents.
    private static let streamingCache = ZenMarkdownCache<String, [ZenMarkdownBlock]>(capacity: 16)
    /// The parsed stable prefixes of the active streams.
    static let streamAnchors = ZenMarkdownStreamAnchors(capacity: 16)

    /// `blocks(from:)` through a bounded memo, so a view rebuilt with the same
    /// string does not parse it again.
    ///
    /// A streaming document is parsed incrementally: the blocks of the stable
    /// prefix of its previous version are reused and only the tail is parsed
    /// (``ZenMarkdownStreamingParser``), with the same result as a full parse;
    /// it is looked up among the partial documents only. A completed document
    /// is parsed whole, once, and frees the anchors of its stream.
    static func cachedBlocks(from markdown: String, isStreaming: Bool) -> [ZenMarkdownBlock] {
        guard isStreaming else {
            if let cached = documentCache.value(for: markdown) {
                return cached
            }
            streamAnchors.removeAnchors(within: markdown)
            let parsed = blocks(from: markdown)
            documentCache.insert(parsed, for: markdown)
            return parsed
        }
        return streamingCache.value(for: markdown) {
            streamingBlocks(from: markdown)
        }
    }

    /// `markdown` parsed from the anchor of an earlier version of it, which
    /// is then replaced by the new anchor.
    static func streamingBlocks(from markdown: String) -> [ZenMarkdownBlock] {
        let result = ZenMarkdownStreamingParser.parse(
            markdown,
            reusing: streamAnchors.bestAnchor(for: markdown)
        )
        if let anchor = result.anchor {
            streamAnchors.record(anchor)
        }
        return result.blocks
    }
}

// MARK: - Blocks

/// Builds the block model from a swift-markdown tree.
struct ZenMarkdownBlockBuilder: MarkupVisitor {
    typealias Result = [ZenMarkdownBlock]

    mutating func defaultVisit(_ markup: any Markup) -> [ZenMarkdownBlock] {
        visitChildren(of: markup)
    }

    mutating func visitDocument(_ document: Document) -> [ZenMarkdownBlock] {
        visitChildren(of: document)
    }

    mutating func visitHeading(_ heading: Heading) -> [ZenMarkdownBlock] {
        [.heading(level: min(max(heading.level, 1), 6), content: Self.inline(of: heading))]
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> [ZenMarkdownBlock] {
        [.paragraph(Self.inline(of: paragraph))]
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> [ZenMarkdownBlock] {
        [.list(ordered: false, start: 1, items: listItems(of: unorderedList))]
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> [ZenMarkdownBlock] {
        let start = Int(clamping: orderedList.startIndex)
        return [.list(ordered: true, start: start, items: listItems(of: orderedList))]
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> [ZenMarkdownBlock] {
        [.quote(visitChildren(of: blockQuote))]
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> [ZenMarkdownBlock] {
        let language = codeBlock.language?.trimmingCharacters(in: .whitespaces)
        var code = codeBlock.code
        if code.hasSuffix("\n") {
            code.removeLast()
        }
        return [.code(language: language?.isEmpty == false ? language : nil, code: code)]
    }

    mutating func visitTable(_ table: Table) -> [ZenMarkdownBlock] {
        let header = table.head.cells.map { Self.inline(of: $0) }
        let rows = table.body.rows.map { row in
            Array(row.cells.map { Self.inline(of: $0) })
        }
        let alignments = table.columnAlignments.map(Self.alignment)
        return [.table(header: Array(header), alignments: alignments, rows: Array(rows))]
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> [ZenMarkdownBlock] {
        [.thematicBreak]
    }

    mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) -> [ZenMarkdownBlock] {
        var html = htmlBlock.rawHTML
        while html.hasSuffix("\n") {
            html.removeLast()
        }
        // An HTML comment is invisible in rendered Markdown.
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || (trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->")) {
            return []
        }
        return [.html(html)]
    }

    private mutating func visitChildren(of markup: any Markup) -> [ZenMarkdownBlock] {
        var blocks: [ZenMarkdownBlock] = []
        for child in markup.children {
            blocks += visit(child)
        }
        return blocks
    }

    private mutating func listItems(of list: any ListItemContainer) -> [ZenMarkdownListItem] {
        list.listItems.map { item in
            ZenMarkdownListItem(
                checkbox: item.checkbox.map { $0 == .checked ? .checked : .unchecked },
                blocks: visitChildren(of: item)
            )
        }
    }

    private static func inline(of markup: any Markup) -> ZenMarkdownInline {
        var builder = ZenMarkdownInlineBuilder()
        return builder.visitChildren(of: markup)
    }

    private static func alignment(_ alignment: Table.ColumnAlignment?) -> ZenMarkdownTableAlignment {
        switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        case nil: .none
        @unknown default: .none
        }
    }
}

// MARK: - Inlines

/// Builds semantic `AttributedString`s from inline swift-markdown nodes; the
/// current emphasis and link state is carried down the tree.
struct ZenMarkdownInlineBuilder: MarkupVisitor {
    typealias Result = AttributedString

    private var intent: InlinePresentationIntent = []
    private var link: URL?

    mutating func defaultVisit(_ markup: any Markup) -> AttributedString {
        visitChildren(of: markup)
    }

    mutating func visitText(_ text: Markdown.Text) -> AttributedString {
        run(text.string)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> AttributedString {
        run(" ")
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> AttributedString {
        run("\n")
    }

    mutating func visitStrong(_ strong: Strong) -> AttributedString {
        with(intent: .stronglyEmphasized) { $0.visitChildren(of: strong) }
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> AttributedString {
        with(intent: .emphasized) { $0.visitChildren(of: emphasis) }
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> AttributedString {
        with(intent: .strikethrough) { $0.visitChildren(of: strikethrough) }
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> AttributedString {
        with(intent: .code) { $0.run(inlineCode.code) }
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> AttributedString {
        // Comments are invisible; other inline HTML is shown as code.
        if inlineHTML.rawHTML.hasPrefix("<!--") {
            return AttributedString()
        }
        return with(intent: .code) { $0.run(inlineHTML.rawHTML) }
    }

    mutating func visitLink(_ link: Markdown.Link) -> AttributedString {
        with(link: link.destination) { $0.visitChildren(of: link) }
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) -> AttributedString {
        with(intent: .code) { $0.run(symbolLink.destination ?? "") }
    }

    mutating func visitImage(_ image: Markdown.Image) -> AttributedString {
        with(link: image.source) { builder in
            let alt = builder.visitChildren(of: image)
            return alt.characters.isEmpty ? builder.run("image") : alt
        }
    }

    mutating func visitChildren(of markup: any Markup) -> AttributedString {
        var result = AttributedString()
        for child in markup.children {
            result.append(visit(child))
        }
        return result
    }

    /// A run of `text` with the current attributes.
    private func run(_ text: String) -> AttributedString {
        var run = AttributedString(text)
        if !intent.isEmpty {
            run.inlinePresentationIntent = intent
        }
        if let link {
            run.link = link
        }
        return run
    }

    private mutating func with(
        intent added: InlinePresentationIntent,
        _ body: (inout Self) -> AttributedString
    ) -> AttributedString {
        let saved = intent
        intent.formUnion(added)
        defer { intent = saved }
        return body(&self)
    }

    private mutating func with(
        link destination: String?,
        _ body: (inout Self) -> AttributedString
    ) -> AttributedString {
        let saved = link
        if let destination, !destination.isEmpty, let url = URL(string: destination) {
            link = url
        }
        defer { link = saved }
        return body(&self)
    }
}
