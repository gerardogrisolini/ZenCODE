//
//  ZenAssistantTextView.swift
//  ZenApp
//
//  A block of assistant text, rendered as Markdown.
//

import Foundation
import SwiftUI
import ZenAppTheme

/// A block of assistant text, rendered by the environment's
/// ``ZenMarkdownRenderer``, with a subtle accent indicator while it streams.
public struct ZenAssistantTextView: View {
    private let text: String
    private let isStreaming: Bool

    @Environment(\.zenMarkdownRenderer) private var renderer

    /// - Parameters:
    ///   - text: The Markdown source of the block.
    ///   - isStreaming: `true` while the model is still writing the block.
    public init(text: String, isStreaming: Bool) {
        self.text = text
        self.isStreaming = isStreaming
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !text.isEmpty {
                renderer.render(text, isStreaming: isStreaming)
            }
            if isStreaming {
                ZenStreamingIndicator()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Assistant text") {
    VStack(alignment: .leading, spacing: 16) {
        ZenAssistantTextView(
            text: "The transcript now groups **tool calls** under each turn.\n\n- compact line\n- expandable details",
            isStreaming: false
        )
        ZenAssistantTextView(text: "Reading the render coordinator", isStreaming: true)
    }
    .padding()
    .frame(width: 520)
}
