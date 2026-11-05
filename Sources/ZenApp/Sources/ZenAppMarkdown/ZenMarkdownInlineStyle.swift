//
//  ZenMarkdownInlineStyle.swift
//  ZenApp
//
//  Turns the semantic inline model into a displayable AttributedString with
//  the ZenPalette (terminal UI) colors.
//

import Foundation
import SwiftUI
import ZenAppTheme

/// Styling of `ZenMarkdownInline` content.
public enum ZenMarkdownInlineStyle {
    /// Applies fonts and palette colors to `inline`:
    /// strong is bold, emphasis italic, strikethrough struck through, inline
    /// code monospaced in `inlineCodeForeground` on `inlineCodeBackground`,
    /// and links (kept clickable through their `.link` attribute) in
    /// `markdownLink`. Runs without a dedicated color keep the foreground
    /// style of the enclosing `Text`.
    public static func styled(_ inline: ZenMarkdownInline, font: Font, palette: ZenPalette) -> AttributedString {
        var result = AttributedString()
        for run in inline.runs {
            var piece = AttributedString(inline[run.range])
            let intent = run.inlinePresentationIntent ?? []
            var runFont = font
            if intent.contains(.stronglyEmphasized) {
                runFont = runFont.bold()
            }
            if intent.contains(.emphasized) {
                runFont = runFont.italic()
            }
            if intent.contains(.code) {
                runFont = runFont.monospaced()
                piece.swiftUI.foregroundColor = palette.inlineCodeForeground
                piece.swiftUI.backgroundColor = palette.inlineCodeBackground
            }
            if intent.contains(.strikethrough) {
                piece.swiftUI.strikethroughStyle = .single
            }
            if run.link != nil {
                piece.swiftUI.foregroundColor = palette.markdownLink
            }
            piece.swiftUI.font = runFont
            result.append(piece)
        }
        return result
    }

    /// The characters of `inline` without attributes.
    public static func plainText(_ inline: ZenMarkdownInline) -> String {
        String(inline.characters)
    }
}
