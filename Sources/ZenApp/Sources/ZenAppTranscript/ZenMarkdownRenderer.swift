//
//  ZenMarkdownRenderer.swift
//  ZenApp
//
//  The injectable Markdown renderer of the transcript views.
//

import Foundation
import SwiftUI
import ZenAppTheme

/// Renders a Markdown string as a view.
///
/// Every Markdown text of the transcript (assistant text, Markdown-channel
/// notices) goes through the renderer installed in the environment
/// (`\.zenMarkdownRenderer`). The module cannot depend on the Markdown target,
/// so the default renders the source as plain selectable text; the app
/// installs the real Markdown view at the root of the transcript.
public struct ZenMarkdownRenderer: Sendable {
    private let renderBody: @MainActor @Sendable (String, Bool) -> AnyView

    /// Creates a renderer.
    ///
    /// - Parameter render: Builds the view of a Markdown source. The second
    ///   argument is `true` while the text is still streaming, so a renderer
    ///   can tolerate an unterminated block (an open code fence, a half
    ///   table) or skip expensive work.
    public init(_ render: @escaping @MainActor @Sendable (String, Bool) -> AnyView) {
        self.renderBody = render
    }

    /// The view of `text`; `isStreaming` is `true` while the text grows.
    @MainActor
    public func render(_ text: String, isStreaming: Bool) -> AnyView {
        renderBody(text, isStreaming)
    }

    /// The default renderer: the source as plain selectable text in the
    /// primary text color, without Markdown formatting.
    public static let plain = ZenMarkdownRenderer { text, _ in
        AnyView(ZenPlainMarkdownText(text: text))
    }
}

extension EnvironmentValues {
    /// The renderer of every Markdown text of the transcript, read with
    /// `@Environment(\.zenMarkdownRenderer)`. Defaults to
    /// ``ZenMarkdownRenderer/plain``.
    @Entry public var zenMarkdownRenderer: ZenMarkdownRenderer = .plain
}

/// The default rendering of a Markdown source: plain, selectable, bounded.
struct ZenPlainMarkdownText: View {
    let text: String

    @Environment(\.zenPalette) private var palette

    var body: some View {
        Text(ZenTranscriptText.bounded(text, limit: ZenTranscriptText.longTextLimit))
            .foregroundStyle(palette.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
