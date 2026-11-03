//
//  ZenMarkdownCodeBlockView.swift
//  ZenApp
//
//  Fenced code blocks: a header bar with the language and a Copy button over
//  a horizontally scrolling, syntax-highlighted or diff-colored body.
//

import AppKit
import Foundation
import SwiftUI
import ZenAppTheme

/// How a code block body is drawn; computed once per distinct block.
enum ZenMarkdownCodePresentation: Equatable, Sendable {
    /// Syntax-highlighted source.
    case source([ZenSyntaxToken])
    /// A unified diff, one classified row per line.
    case diff([ZenDiffLine])

    private struct Key: Hashable, Sendable {
        var language: String?
        var code: String
    }

    private static let cache = ZenMarkdownCache<Key, ZenMarkdownCodePresentation>(capacity: 256)
    /// The open (last) block of a streaming document, whose code changes with
    /// every token: kept apart so its versions never evict completed blocks.
    private static let streamingCache = ZenMarkdownCache<Key, ZenMarkdownCodePresentation>(capacity: 16)

    /// The presentation of a block: a diff when the fence says `diff`/`patch`
    /// or when an untagged (or unknown-language) block looks like a unified
    /// diff, highlighted source otherwise. Computed once per distinct
    /// (language, code): a block that does not change is never highlighted
    /// again.
    ///
    /// - Parameter isStreaming: `true` for a block that may still change (see
    ///   `ZenMarkdownView.isOpenBlock`).
    static func make(language: String?, code: String, isStreaming: Bool = false) -> ZenMarkdownCodePresentation {
        let key = Key(language: language, code: code)
        if let cached = cache.value(for: key) {
            return cached
        }
        return (isStreaming ? streamingCache : cache).value(for: key) {
            if isDiff(language: language, code: code) {
                return .diff(ZenDiff.classify(code))
            }
            return .source(ZenSyntaxHighlighter.highlight(code, language: language))
        }
    }

    /// The presentation already cached for a block, without computing it.
    static func cachedPresentation(
        language: String?,
        code: String,
        isStreaming: Bool = false
    ) -> ZenMarkdownCodePresentation? {
        (isStreaming ? streamingCache : cache).value(for: Key(language: language, code: code))
    }

    static func isDiff(language: String?, code: String) -> Bool {
        if ZenDiff.isDiffLanguage(language) {
            return true
        }
        return !ZenSyntaxHighlighter.supportsLanguage(language) && ZenDiff.looksLikeUnifiedDiff(code)
    }

    /// The header title, as in the terminal UI: `Code`, `Code · Swift`,
    /// `Code · Diff`.
    static func title(language: String?, isDiff: Bool) -> String {
        if isDiff {
            return "Code · Diff"
        }
        guard let language = ZenSyntaxHighlighter.normalizedLanguage(language) else {
            return "Code"
        }
        return "Code · \(language.prefix(1).uppercased())\(language.dropFirst())"
    }
}

/// A fenced code block.
struct ZenMarkdownCodeBlockView: View {
    let language: String?
    let code: String
    @Environment(\.zenPalette) private var palette
    @Environment(\.zenMarkdownIsStreaming) private var isStreaming
    @State private var copied = false
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        let presentation = ZenMarkdownCodePresentation.make(language: language, code: code, isStreaming: isStreaming)
        VStack(alignment: .leading, spacing: 0) {
            header(isDiff: presentation.isDiff)
            ScrollView(.horizontal) {
                content(presentation)
                    .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                viewportWidth = width
            }
        }
        .background(palette.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(isDiff: Bool) -> some View {
        HStack(spacing: 8) {
            Text(ZenMarkdownCodePresentation.title(language: language, isDiff: isDiff))
                .font(.caption.bold())
                .foregroundStyle(palette.codeHeaderForeground)
            Spacer(minLength: 8)
            Button(action: copy) {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.codeHeaderForeground)
            .help("Copy code")
        }
        .textSelection(.disabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.codeHeaderBackground)
        .task(id: copied) {
            guard copied else {
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    @ViewBuilder
    private func content(_ presentation: ZenMarkdownCodePresentation) -> some View {
        switch presentation {
        case let .source(tokens):
            Text(ZenSyntaxHighlighter.attributedString(for: tokens, palette: palette))
                .font(Self.codeFont)
                .foregroundStyle(palette.codeForeground)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 12)
                .frame(minWidth: viewportWidth, alignment: .leading)
        case let .diff(lines):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    diffRow(lines[index])
                }
            }
        }
    }

    /// One diff line on a full-width row (at least the viewport width).
    private func diffRow(_ line: ZenDiffLine) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(line.kind == .hunk ? Self.codeFont.bold() : Self.codeFont)
            .foregroundStyle(foreground(for: line.kind))
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 12)
            .frame(minWidth: viewportWidth, maxWidth: .infinity, alignment: .leading)
            .background(background(for: line.kind))
    }

    private func foreground(for kind: ZenDiffLineKind) -> Color {
        switch kind {
        case .addition: palette.diffAddition
        case .removal: palette.diffRemoval
        case .hunk: palette.diffHunk
        case .header: palette.diffHeader
        case .context, .plain: palette.codeForeground
        }
    }

    private func background(for kind: ZenDiffLineKind) -> Color {
        switch kind {
        case .addition: palette.diffAdditionBackground
        case .removal: palette.diffRemovalBackground
        default: palette.codeBackground
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        copied = true
    }

    private static let codeFont = Font.system(.body, design: .monospaced)
}

extension ZenMarkdownCodePresentation {
    /// Whether the block is drawn as a diff.
    var isDiff: Bool {
        if case .diff = self {
            return true
        }
        return false
    }
}
