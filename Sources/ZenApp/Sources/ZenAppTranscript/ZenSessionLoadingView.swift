//
//  ZenSessionLoadingView.swift
//  ZenApp
//
//  The loading indicator of a window while a saved session loads.
//

import Foundation
import SwiftUI
import ZenAppTheme

/// The loading indicator of a window while the saved session `name` loads,
/// centered in place of the conversation: a large spinner in the accent
/// color (``ZenLoadingRing``), `Loading “<name>”…`, and the step the load
/// is at.
public struct ZenSessionLoadingView: View {
    private let name: String
    private let step: String?

    @Environment(\.zenPalette) private var palette

    /// - Parameters:
    ///   - name: The name of the saved session that loads.
    ///   - step: The step the load is at, on the line under the name; `nil`
    ///     for none.
    public init(name: String, step: String? = nil) {
        self.name = name
        self.step = step
    }

    public var body: some View {
        let title = Self.title(for: name)
        VStack(spacing: 18) {
            ZenLoadingRing(color: palette.accent)
                .frame(width: ZenLoadingRing.diameter, height: ZenLoadingRing.diameter)
            VStack(spacing: 4) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(palette.textSecondary)
                if let step {
                    Text(step)
                        .font(.callout)
                        .foregroundStyle(palette.textSubtle)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(title: title, step: step))
    }

    /// `Loading “<name>”…`, with `name` on one line
    /// (``ZenTranscriptText/inline(_:limit:)``).
    static func title(for name: String) -> String {
        "Loading “\(ZenTranscriptText.inline(name, limit: 160) ?? name)”…"
    }

    /// The title, then the step when there is one.
    static func accessibilityLabel(title: String, step: String?) -> String {
        guard let step else { return title }
        return "\(title) \(step)"
    }
}

/// A large spinner: an arc of `color` turning once a second over a faint
/// track of the same color. Drawn by SwiftUI, so it stays sharp at any size,
/// where the system spinner stops at 32 points.
struct ZenLoadingRing: View {
    let color: Color

    /// The side of the ring, in points.
    static let diameter: CGFloat = 64
    /// The width of its stroke, in points.
    static let lineWidth: CGFloat = 6
    /// The part of the circle the arc covers.
    static let arcFraction: CGFloat = 0.28

    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            ZStack {
                Circle()
                    .stroke(color.opacity(0.18), lineWidth: Self.lineWidth)
                Circle()
                    .trim(from: 0, to: Self.arcFraction)
                    .stroke(color, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
            .padding(Self.lineWidth / 2)
        }
        .accessibilityHidden(true)
    }
}

#Preview("Loading dark") {
    ZenSessionLoadingView(name: "Refactor the session host", step: "Loading the model and tools…")
        .frame(width: 640, height: 420)
        .preferredColorScheme(.dark)
}

#Preview("Loading light") {
    ZenSessionLoadingView(name: "Refactor the session host", step: "Reading the saved session…")
        .frame(width: 640, height: 420)
        .preferredColorScheme(.light)
}
