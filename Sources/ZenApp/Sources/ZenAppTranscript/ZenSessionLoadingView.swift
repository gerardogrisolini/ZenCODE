//
//  ZenSessionLoadingView.swift
//  ZenApp
//
//  The empty state of a window while a saved session loads.
//

import Foundation
import SwiftUI
import ZenAppTheme

/// The empty state of a window while the saved session `name` loads, in
/// place of the welcome view: a spinner in the accent color and
/// `Loading “<name>”…`.
public struct ZenSessionLoadingView: View {
    private let name: String

    @Environment(\.zenPalette) private var palette

    /// - Parameter name: The name of the saved session that loads.
    public init(name: String) {
        self.name = name
    }

    public var body: some View {
        let title = Self.title(for: name)
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(palette.accent)
            Text(title)
                .font(.callout)
                .foregroundStyle(palette.textSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    /// `Loading “<name>”…`, with `name` on one line
    /// (``ZenTranscriptText/inline(_:limit:)``).
    static func title(for name: String) -> String {
        "Loading “\(ZenTranscriptText.inline(name, limit: 160) ?? name)”…"
    }
}

#Preview("Loading dark") {
    ZenSessionLoadingView(name: "Refactor the session host")
        .frame(width: 640, height: 420)
        .preferredColorScheme(.dark)
}

#Preview("Loading light") {
    ZenSessionLoadingView(name: "Refactor the session host")
        .frame(width: 640, height: 420)
        .preferredColorScheme(.light)
}
