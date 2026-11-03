//
//  ZenMarkdownRendering.swift
//  ZenApp
//
//  The Markdown renderer the app installs for the transcript views.
//

import Foundation
import SwiftUI
import ZenAppMarkdown
import ZenAppTranscript

extension ZenMarkdownRenderer {
    /// Renders every Markdown text of the transcript (assistant text,
    /// Markdown notices) with ``ZenMarkdownView``.
    static let zenMarkdownView = ZenMarkdownRenderer { text, isStreaming in
        AnyView(ZenMarkdownView(text, isStreaming: isStreaming))
    }
}
