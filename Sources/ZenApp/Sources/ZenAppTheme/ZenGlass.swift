//
//  ZenGlass.swift
//  ZenApp
//
//  Shared Liquid Glass helpers and fonts of the ZenCODE app.
//

import Foundation
import SwiftUI

extension View {
    /// Wraps the view in a Liquid Glass card, optionally tinted.
    ///
    /// - Parameters:
    ///   - tint: Color tinting the glass at a low opacity; `nil` keeps it neutral.
    ///   - cornerRadius: Corner radius of the card.
    ///   - padding: Padding between the content and the card edge.
    public func zenGlassCard(
        tint: Color? = nil,
        cornerRadius: CGFloat = 16,
        padding: CGFloat = 12
    ) -> some View {
        self
            .padding(padding)
            .glassEffect(
                tint.map { Glass.regular.tint($0.opacity(0.18)) } ?? .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
    }
}

/// Fonts shared by the monospaced parts of the app (code, tool output).
public enum ZenFonts {
    public static let mono: Font = .system(.body, design: .monospaced)
    public static let monoSmall: Font = .system(.callout, design: .monospaced)
}
