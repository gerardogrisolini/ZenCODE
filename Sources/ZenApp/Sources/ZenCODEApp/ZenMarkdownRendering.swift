//
//  ZenMarkdownRendering.swift
//  ZenApp
//
//  The Markdown renderer and the code highlighter the app installs for the
//  transcript views.
//

import Foundation
import SwiftUI
import ZenAppMarkdown
import ZenAppTheme
import ZenAppTranscript

extension ZenMarkdownRenderer {
    /// Renders every Markdown text of the transcript (assistant text,
    /// Markdown notices) with ``ZenMarkdownView``.
    static let zenMarkdownView = ZenMarkdownRenderer { text, isStreaming in
        AnyView(ZenMarkdownView(text, isStreaming: isStreaming))
    }
}

extension ZenCodeHighlighter {
    /// Colors the source lines of the file-artifact diffs with
    /// ``ZenSyntaxHighlighter``, one line at a time as the terminal does.
    static let zenSyntaxHighlighter = ZenCodeHighlighter { line, language, palette in
        ZenSyntaxHighlighter.attributedString(line, language: language, palette: palette)
    }
}
