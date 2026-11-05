//
//  ZenThoughtView.swift
//  ZenApp
//
//  A block of model reasoning, like the terminal's thinking section.
//

import Foundation
import SwiftUI
import ZenAppTheme

/// A block of model reasoning in the terminal's thinking color, muted and
/// italic, titled "Thinking". It is expanded while it streams and collapses to
/// a one-line preview once closed; the title toggles it either way.
public struct ZenThoughtView: View {
    private let text: String
    private let isStreaming: Bool

    /// The operator's choice, which overrides the streaming default.
    @State private var expansionOverride: Bool?
    @Environment(\.zenPalette) private var palette

    /// - Parameters:
    ///   - text: The reasoning text.
    ///   - isStreaming: `true` while the model is still reasoning.
    public init(text: String, isStreaming: Bool) {
        self.text = text
        self.isStreaming = isStreaming
    }

    private var isExpanded: Bool {
        expansionOverride ?? isStreaming
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    expansionOverride = !isExpanded
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ZenDisclosureChevron(isExpanded: isExpanded)
                    Text("Thinking")
                        .fontWeight(.medium)
                        .layoutPriority(1)
                    if isStreaming {
                        ZenStreamingIndicator(color: palette.thinking)
                    }
                    if !isExpanded, let preview = ZenTranscriptText.firstLinePreview(text) {
                        Text(preview)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .italic()
                .foregroundStyle(palette.thinking)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Collapses the reasoning" : "Expands the reasoning")

            if isExpanded, !text.isEmpty {
                Text(ZenTranscriptText.bounded(text, limit: ZenTranscriptText.longTextLimit))
                    .italic()
                    .foregroundStyle(palette.thinking)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 18)
            }
        }
    }
}

#Preview("Thought") {
    VStack(alignment: .leading, spacing: 16) {
        ZenThoughtView(
            text: "The user wants collapsed tool calls.\nI should check the render coordinator first.",
            isStreaming: true
        )
        ZenThoughtView(
            text: "The overview is fenced after the final response.\nNothing else to change.",
            isStreaming: false
        )
    }
    .padding()
    .frame(width: 520)
}
