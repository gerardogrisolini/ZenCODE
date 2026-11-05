//
//  ZenMarkdownBlock.swift
//  ZenApp
//
//  The palette-independent model produced by `ZenMarkdownParser` and drawn by
//  `ZenMarkdownView`.
//

import Foundation

/// Inline Markdown content: an `AttributedString` carrying only semantic
/// attributes, never colors or fonts, so the same parse serves the light and
/// dark palettes.
///
/// - `inlinePresentationIntent`: `.stronglyEmphasized` (strong),
///   `.emphasized` (emphasis), `.strikethrough` and `.code` (inline code and
///   inline HTML).
/// - `link`: the destination of links, autolinks and images (an image is its
///   alt text linked to its source).
///
/// `ZenMarkdownInlineStyle` turns it into a displayable string with the
/// `ZenPalette` colors.
public typealias ZenMarkdownInline = AttributedString

/// One block of a parsed Markdown document.
public enum ZenMarkdownBlock: Equatable, Sendable {
    /// An ATX or setext heading; `level` is 1 through 6.
    case heading(level: Int, content: ZenMarkdownInline)
    /// A paragraph of inline content.
    case paragraph(ZenMarkdownInline)
    /// A bulleted (`ordered == false`) or numbered list; `start` is the number
    /// of the first item (1 for bulleted lists).
    case list(ordered: Bool, start: Int, items: [ZenMarkdownListItem])
    /// A block quote with its nested blocks.
    case quote([ZenMarkdownBlock])
    /// A fenced or indented code block. `language` is the first word of the
    /// fence info string, `nil` when absent; `code` has no trailing newline.
    case code(language: String?, code: String)
    /// A GFM table. `alignments` has one entry per column; body rows may be
    /// shorter or longer than the header and are normalized by the view.
    case table(
        header: [ZenMarkdownInline],
        alignments: [ZenMarkdownTableAlignment],
        rows: [[ZenMarkdownInline]]
    )
    /// A horizontal rule (`---`, `***`, `___`).
    case thematicBreak
    /// A raw HTML block, shown verbatim.
    case html(String)
}

/// One item of a `ZenMarkdownBlock.list`.
public struct ZenMarkdownListItem: Equatable, Sendable {
    /// The GFM task-list state (`- [ ]` / `- [x]`), `nil` for plain items.
    public var checkbox: ZenMarkdownCheckbox?
    /// The item content: paragraphs, nested lists, code blocks and so on.
    public var blocks: [ZenMarkdownBlock]

    /// Creates a list item.
    public init(checkbox: ZenMarkdownCheckbox? = nil, blocks: [ZenMarkdownBlock]) {
        self.checkbox = checkbox
        self.blocks = blocks
    }
}

/// The state of a GFM task-list checkbox.
public enum ZenMarkdownCheckbox: Equatable, Sendable {
    /// `- [x]`
    case checked
    /// `- [ ]`
    case unchecked
}

/// The alignment of a GFM table column, from its delimiter row.
public enum ZenMarkdownTableAlignment: Equatable, Sendable {
    /// No colon in the delimiter row (`---`): rendered leading.
    case none
    /// `:---`
    case left
    /// `:---:`
    case center
    /// `---:`
    case right
}
