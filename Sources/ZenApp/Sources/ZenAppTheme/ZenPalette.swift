//
//  ZenPalette.swift
//  ZenApp
//
//  The color palette of the app: the terminal UI's xterm-256 palette
//  (`TerminalStyle`) translated to SwiftUI colors, in dark and light variants.
//

import Foundation
import SwiftUI

/// Semantic colors of the app, named after the groups of `TerminalStyle` in
/// `ZenCODECore` so the SwiftUI app and the terminal UI read as one product.
///
/// Dark values mirror the terminal palette index for index. SGR 2 (dim) has no
/// SwiftUI counterpart and is rendered as a 0.5 opacity on the same color.
public struct ZenPalette: Sendable, Equatable {
    // MARK: - Text

    /// Mirrors `TerminalStyle.Text`.
    public internal(set) var textPrimary: Color = ZenXTerm256.color(15)
    public internal(set) var textSecondary: Color = ZenXTerm256.color(253)
    public internal(set) var textMuted: Color = ZenXTerm256.color(8)
    public internal(set) var textSubtle: Color = ZenXTerm256.color(250)
    public internal(set) var systemMessage: Color = ZenXTerm256.color(110)
    public internal(set) var operationalMessage: Color = ZenXTerm256.color(75)
    public internal(set) var failureMessage: Color = ZenXTerm256.color(203)

    // MARK: - Accent

    /// Mirrors `TerminalStyle.Accent`.
    public internal(set) var accent: Color = ZenXTerm256.color(208)
    public internal(set) var accentCount: Color = ZenXTerm256.color(81)

    // MARK: - Status

    /// Mirrors `TerminalStyle.Status`.
    public internal(set) var statusQueued: Color = ZenXTerm256.color(3)
    public internal(set) var statusActive: Color = ZenXTerm256.color(208)
    public internal(set) var statusSuccess: Color = ZenXTerm256.color(2)
    public internal(set) var statusFailure: Color = ZenXTerm256.color(1)
    public internal(set) var statusInactive: Color = ZenXTerm256.color(8)

    // MARK: - File changes

    /// Mirrors `TerminalStyle.FileChange`.
    public internal(set) var fileSummaryHeader: Color = ZenXTerm256.color(208)
    public internal(set) var fileCount: Color = ZenXTerm256.color(81)
    public internal(set) var fileMetadata: Color = ZenXTerm256.color(244)
    public internal(set) var fileHunk: Color = ZenXTerm256.color(141)
    public internal(set) var fileAddition: Color = ZenXTerm256.color(114)
    public internal(set) var fileDeletion: Color = ZenXTerm256.color(203)
    public internal(set) var filePath: Color = ZenXTerm256.color(15)
    public internal(set) var fileHint: Color = ZenXTerm256.color(250)

    // MARK: - Surfaces

    /// Mirrors `TerminalStyle.Surface` and `TerminalStyle.Prompt`.
    public internal(set) var surface: Color = ZenXTerm256.color(236)
    public internal(set) var promptBackground: Color = ZenXTerm256.color(236)
    public internal(set) var turnSeparator: Color = ZenXTerm256.color(8)

    // MARK: - Tool

    /// Mirrors `TerminalStyle.Tool`.
    public internal(set) var toolTitle: Color = ZenXTerm256.color(208)
    public internal(set) var toolLabel: Color = ZenXTerm256.color(173)
    public internal(set) var toolValue: Color = ZenXTerm256.color(215)
    public internal(set) var toolParameter: Color = ZenXTerm256.color(250)
    public internal(set) var toolDuration: Color = ZenXTerm256.color(8)
    public internal(set) var codeGutter: Color = ZenXTerm256.color(8)
    public internal(set) var toolCodeBackground: Color = ZenXTerm256.color(236)

    // MARK: - Shared chat

    /// Mirrors `TerminalStyle.SharedChat` (`darkPalette` / `lightPalette`).
    public internal(set) var chatBorder: Color = ZenXTerm256.color(60)
    public internal(set) var chatTitle: Color = ZenXTerm256.color(66)
    public internal(set) var chatBody: Color = ZenXTerm256.color(253)

    // MARK: - Chrome

    /// Mirrors `TerminalStyle.Chrome`; the dimmed frames (SGR 2) become 0.5 opacity.
    public internal(set) var promptBorder: Color = ZenXTerm256.color(208, opacity: 0.5)
    public internal(set) var menuBorder: Color = ZenXTerm256.color(208, opacity: 0.5)
    public internal(set) var startupLogo: Color = ZenXTerm256.color(130)
    public internal(set) var suggestion: Color = ZenXTerm256.color(8)

    // MARK: - Permission

    /// Mirrors `TerminalStyle.Permission`; the dimmed frame (SGR 2) becomes 0.5 opacity.
    public internal(set) var permissionBorder: Color = ZenXTerm256.color(81, opacity: 0.5)
    public internal(set) var permissionTitle: Color = ZenXTerm256.color(208)
    public internal(set) var permissionMarker: Color = ZenXTerm256.color(208)
    public internal(set) var permissionChoice: Color = ZenXTerm256.color(81)
    public internal(set) var permissionMetadata: Color = ZenXTerm256.color(244)

    // MARK: - Thinking

    /// Mirrors `TerminalStyle.Thinking`.
    public internal(set) var thinking: Color = ZenXTerm256.color(8)

    // MARK: - Markdown

    /// Mirrors `TerminalStyle.Markdown` (the shared styles and
    /// `darkPalette` / `lightPalette`).
    public internal(set) var markdownDim: Color = ZenXTerm256.color(8)
    public internal(set) var markdownBullet: Color = ZenXTerm256.color(244)
    public internal(set) var markdownLink: Color = ZenXTerm256.color(75)
    public internal(set) var markdownQuoteBar: Color = ZenXTerm256.color(108)
    public internal(set) var markdownTableBorder: Color = ZenXTerm256.color(240)
    public internal(set) var markdownTableHeader: Color = ZenXTerm256.color(81)
    public internal(set) var inlineCodeForeground: Color = ZenXTerm256.color(180)
    public internal(set) var inlineCodeBackground: Color = ZenXTerm256.color(236)
    public internal(set) var codeForeground: Color = ZenXTerm256.color(252)
    public internal(set) var codeBackground: Color = ZenXTerm256.color(236)
    public internal(set) var codeHeaderForeground: Color = ZenXTerm256.color(117)
    public internal(set) var codeHeaderBackground: Color = ZenXTerm256.color(238)
    /// Heading colors for levels 1 through 6.
    public internal(set) var headings: [Color] = [81, 75, 111, 111, 110, 109].map { ZenXTerm256.color($0) }
    public internal(set) var syntaxKeyword: Color = ZenXTerm256.color(141)
    public internal(set) var syntaxType: Color = ZenXTerm256.color(81)
    public internal(set) var syntaxString: Color = ZenXTerm256.color(114)
    public internal(set) var syntaxComment: Color = ZenXTerm256.color(244)
    public internal(set) var syntaxNumber: Color = ZenXTerm256.color(215)
    public internal(set) var syntaxAttribute: Color = ZenXTerm256.color(214)
    public internal(set) var syntaxFunction: Color = ZenXTerm256.color(117)
    public internal(set) var syntaxProperty: Color = ZenXTerm256.color(109)
    public internal(set) var diffAddition: Color = ZenXTerm256.color(114)
    public internal(set) var diffRemoval: Color = ZenXTerm256.color(210)
    public internal(set) var diffAdditionBackground: Color = ZenXTerm256.color(red: 30, green: 48, blue: 36)
    public internal(set) var diffRemovalBackground: Color = ZenXTerm256.color(red: 55, green: 32, blue: 35)
    public internal(set) var diffHunk: Color = ZenXTerm256.color(81)
    public internal(set) var diffHeader: Color = ZenXTerm256.color(180)

    /// The property defaults are the dark palette.
    init() {}

    // MARK: - Variants

    /// The dark palette: the terminal UI's dark values, index for index.
    public static let dark = ZenPalette()

    /// The light palette: the dark palette with the terminal UI's light
    /// Markdown and shared-chat values, and darker text and lighter surfaces
    /// readable on a light window.
    public static let light: ZenPalette = {
        var palette = ZenPalette.dark

        // Text and surfaces, adapted to a light background.
        palette.textPrimary = ZenXTerm256.color(235)
        palette.textSecondary = ZenXTerm256.color(238)
        palette.textSubtle = ZenXTerm256.color(242)
        palette.filePath = ZenXTerm256.color(235)
        // `TerminalStyle` aliases these to `Text.subtle`, which is 242 here.
        palette.fileHint = palette.textSubtle
        palette.toolParameter = palette.textSubtle
        palette.surface = ZenXTerm256.color(254)
        palette.promptBackground = ZenXTerm256.color(254)
        palette.toolCodeBackground = ZenXTerm256.color(254)

        // TerminalStyle.SharedChat.lightPalette.
        palette.chatBorder = ZenXTerm256.color(59)
        palette.chatTitle = ZenXTerm256.color(59)
        palette.chatBody = ZenXTerm256.color(235)

        // TerminalStyle.Markdown.lightPalette.
        palette.inlineCodeForeground = ZenXTerm256.color(94)
        palette.inlineCodeBackground = ZenXTerm256.color(254)
        palette.codeForeground = ZenXTerm256.color(235)
        palette.codeBackground = ZenXTerm256.color(254)
        palette.codeHeaderForeground = ZenXTerm256.color(25)
        palette.codeHeaderBackground = ZenXTerm256.color(252)
        palette.headings = [25, 31, 61, 61, 60, 59].map { ZenXTerm256.color($0) }
        palette.syntaxKeyword = ZenXTerm256.color(90)
        palette.syntaxType = ZenXTerm256.color(24)
        palette.syntaxString = ZenXTerm256.color(28)
        palette.syntaxComment = ZenXTerm256.color(242)
        palette.syntaxNumber = ZenXTerm256.color(130)
        palette.syntaxAttribute = ZenXTerm256.color(130)
        palette.syntaxFunction = ZenXTerm256.color(25)
        palette.syntaxProperty = ZenXTerm256.color(30)
        palette.diffAddition = ZenXTerm256.color(28)
        palette.diffRemoval = ZenXTerm256.color(124)
        palette.diffAdditionBackground = ZenXTerm256.color(194)
        palette.diffRemovalBackground = ZenXTerm256.color(224)
        palette.diffHunk = ZenXTerm256.color(25)
        palette.diffHeader = ZenXTerm256.color(94)

        return palette
    }()

    /// The palette matching a SwiftUI color scheme.
    public static func forColorScheme(_ scheme: ColorScheme) -> ZenPalette {
        switch scheme {
        case .light:
            return .light
        case .dark:
            return .dark
        @unknown default:
            return .dark
        }
    }
}

extension EnvironmentValues {
    /// The palette for the current color scheme, read with
    /// `@Environment(\.zenPalette)`.
    public var zenPalette: ZenPalette {
        ZenPalette.forColorScheme(colorScheme)
    }
}
