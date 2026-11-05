//
//  ZenMarkdownView.swift
//  ZenApp
//
//  Native SwiftUI rendering of Markdown in the terminal UI colors.
//

import Foundation
import SwiftUI
import ZenAppTheme

/// Renders Markdown with native SwiftUI views in the `ZenPalette` colors of
/// the current color scheme: headings, paragraphs, emphasis, strong,
/// strikethrough, inline code, links, nested and task lists, quotes, GFM
/// tables, thematic breaks and fenced code blocks with a header, a Copy
/// button, syntax highlighting and diff coloring. Text is selectable.
///
/// Each distinct string is parsed once (a bounded cache shared by all
/// instances), so rebuilding the view with the same text is cheap. While the
/// text streams, only its changed tail is parsed again, and the code blocks
/// above the last block keep their highlighting.
public struct ZenMarkdownView: View {
    private let blocks: [ZenMarkdownBlock]
    private let isStreaming: Bool

    /// Creates a view for `markdown`.
    ///
    /// - Parameters:
    ///   - markdown: The Markdown source; it may be a partial document.
    ///   - isStreaming: Pass `true` while `markdown` is still growing. The
    ///     rendering is the same (an unterminated code fence already renders
    ///     as code), but the text is parsed incrementally from the stable
    ///     prefix of its previous version, and the short-lived versions of
    ///     the stream (and of its last block) are cached apart so they never
    ///     evict completed documents.
    public init(_ markdown: String, isStreaming: Bool = false) {
        blocks = ZenMarkdownParser.cachedBlocks(from: markdown, isStreaming: isStreaming)
        self.isStreaming = isStreaming
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                ZenMarkdownBlockView(block: blocks[index])
                    .environment(
                        \.zenMarkdownIsStreaming,
                        Self.isOpenBlock(at: index, count: blocks.count, isStreaming: isStreaming)
                    )
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether the top-level block at `index` may still change: the last
    /// block of a streaming document. Appending text never changes the
    /// blocks before it, so their code is highlighted once, in the cache of
    /// completed blocks.
    nonisolated static func isOpenBlock(at index: Int, count: Int, isStreaming: Bool) -> Bool {
        isStreaming && index == count - 1
    }
}

// MARK: - Environment

private struct ZenMarkdownDimmedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ZenMarkdownListDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

private struct ZenMarkdownIsStreamingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether body text is drawn dimmed (inside block quotes).
    var zenMarkdownDimmed: Bool {
        get { self[ZenMarkdownDimmedKey.self] }
        set { self[ZenMarkdownDimmedKey.self] = newValue }
    }

    /// Whether the current block may still change: the last top-level block
    /// of a streaming `ZenMarkdownView`, and everything inside it.
    var zenMarkdownIsStreaming: Bool {
        get { self[ZenMarkdownIsStreamingKey.self] }
        set { self[ZenMarkdownIsStreamingKey.self] = newValue }
    }

    /// The number of lists enclosing the current view.
    var zenMarkdownListDepth: Int {
        get { self[ZenMarkdownListDepthKey.self] }
        set { self[ZenMarkdownListDepthKey.self] = newValue }
    }
}

// MARK: - Blocks

/// A vertical stack of blocks.
struct ZenMarkdownBlockStack: View {
    let blocks: [ZenMarkdownBlock]
    let spacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks.indices, id: \.self) { index in
                ZenMarkdownBlockView(block: blocks[index])
            }
        }
    }
}

/// One block.
struct ZenMarkdownBlockView: View {
    let block: ZenMarkdownBlock
    @Environment(\.zenPalette) private var palette

    var body: some View {
        switch block {
        case let .heading(level, content):
            ZenMarkdownText(
                content,
                font: ZenMarkdownBlockView.headingFont(level: level),
                color: palette.headings[min(max(level, 1), palette.headings.count) - 1]
            )
            .padding(.top, level <= 2 ? 4 : 2)
            .accessibilityAddTraits(.isHeader)
        case let .paragraph(content):
            ZenMarkdownText(content, font: .body)
        case let .list(ordered, start, items):
            ZenMarkdownListView(ordered: ordered, start: start, items: items)
        case let .quote(blocks):
            ZenMarkdownQuoteView(blocks: blocks)
        case let .code(language, code):
            ZenMarkdownCodeBlockView(language: language, code: code)
        case let .table(header, alignments, rows):
            ZenMarkdownTableView(header: header, alignments: alignments, rows: rows)
        case .thematicBreak:
            Rectangle()
                .fill(palette.markdownTableBorder)
                .frame(maxWidth: .infinity)
                .frame(height: 1)
                .padding(.vertical, 4)
        case let .html(html):
            Text(html)
                .font(.body.monospaced())
                .foregroundStyle(palette.markdownDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Levels 1–3 are bold; sizes decrease with the level.
    static func headingFont(level: Int) -> Font {
        switch level {
        case 1: .title.bold()
        case 2: .title2.bold()
        case 3: .title3.bold()
        case 4: .body
        case 5: .callout
        default: .subheadline
        }
    }
}

/// Inline content as a wrapping, selectable `Text`.
struct ZenMarkdownText: View {
    let content: ZenMarkdownInline
    let font: Font
    /// Overrides the body color (headings, table headers).
    let color: Color?
    @Environment(\.zenPalette) private var palette
    @Environment(\.zenMarkdownDimmed) private var dimmed

    init(_ content: ZenMarkdownInline, font: Font, color: Color? = nil) {
        self.content = content
        self.font = font
        self.color = color
    }

    var body: some View {
        Text(ZenMarkdownInlineStyle.styled(content, font: font, palette: palette))
            .font(font)
            .foregroundStyle(color ?? (dimmed ? palette.markdownDim : palette.textPrimary))
            .tint(palette.markdownLink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Lists

/// A bulleted or numbered list; nested lists indent under their item text.
struct ZenMarkdownListView: View {
    /// Bullet glyphs by nesting depth, as in the terminal UI.
    static let bulletGlyphs = ["•", "◦", "▪", "‣"]

    let ordered: Bool
    let start: Int
    let items: [ZenMarkdownListItem]
    @Environment(\.zenPalette) private var palette
    @Environment(\.zenMarkdownListDepth) private var depth

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(at: index)
                    if let checkbox = items[index].checkbox {
                        checkboxView(checkbox)
                    }
                    ZenMarkdownBlockStack(blocks: items[index].blocks, spacing: 4)
                }
            }
        }
        .environment(\.zenMarkdownListDepth, depth + 1)
    }

    /// The bullet or number, right-aligned to the widest number of the list.
    private func marker(at index: Int) -> some View {
        let text = ordered ? "\(start + index)." : Self.bulletGlyphs[depth % Self.bulletGlyphs.count]
        let widest = ordered ? "\(start + max(items.count - 1, 0))." : text
        return ZStack(alignment: .trailing) {
            Text(widest).hidden()
            Text(text)
        }
        .font(.body.monospacedDigit())
        .foregroundStyle(palette.markdownBullet)
        .accessibilityHidden(!ordered)
    }

    private func checkboxView(_ checkbox: ZenMarkdownCheckbox) -> some View {
        let checked = checkbox == .checked
        return Image(systemName: checked ? "checkmark.square.fill" : "square")
            .font(.body)
            .foregroundStyle(checked ? palette.inlineCodeForeground : palette.markdownBullet)
            .accessibilityLabel(checked ? "Completed" : "Not completed")
    }
}

// MARK: - Quotes

/// A block quote: a `markdownQuoteBar` bar beside dimmed content.
struct ZenMarkdownQuoteView: View {
    let blocks: [ZenMarkdownBlock]
    @Environment(\.zenPalette) private var palette

    var body: some View {
        ZenMarkdownBlockStack(blocks: blocks, spacing: 6)
            .environment(\.zenMarkdownDimmed, true)
            .padding(.leading, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(palette.markdownQuoteBar)
                    .frame(width: 3)
            }
    }
}
