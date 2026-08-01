//
//  TerminalMarkdownPalette.swift
//  ZenCODE
//

import Foundation

/// ANSI colors shared by Markdown and code-block rendering.
///
/// Palette detection deliberately reads only process environment metadata. It
/// never asks the terminal for a color or emits an OSC query, so construction is
/// safe on redirected output and cannot block waiting for a TTY response.
struct TerminalMarkdownPalette: Equatable, Sendable {
    enum Appearance: Equatable, Sendable {
        case dark
        case light
    }

    let appearance: Appearance
    let inlineCodeForeground: String
    let inlineCodeBackground: String
    let codeForeground: String
    let codeBackground: String
    let codeHeaderForeground: String
    let codeHeaderBackground: String
    let headingStyles: [String]
    let syntaxKeyword: String
    let syntaxType: String
    let syntaxString: String
    let syntaxComment: String
    let syntaxNumber: String
    let syntaxAttribute: String
    let syntaxFunction: String
    let syntaxProperty: String
    let diffAddition: String
    let diffRemoval: String
    let diffHunk: String
    let diffHeader: String

    static let dark = TerminalStyle.Markdown.darkPalette
    static let light = TerminalStyle.Markdown.lightPalette

    /// Process-wide palette selected once from startup environment metadata.
    /// Explicit `current(environment:)` calls remain available for tests and
    /// hosts that need deterministic injection.
    static let detected = TerminalMarkdownPalette.current()

    /// Production palette. The environment read is non-interactive and does
    /// not touch terminal input/output.
    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalMarkdownPalette {
        palette(for: appearance(environment: environment))
    }

    /// Injection point used by deterministic tests and hosts that already know
    /// their terminal theme.
    static func palette(for appearance: Appearance) -> TerminalMarkdownPalette {
        switch appearance {
        case .dark:
            return .dark
        case .light:
            return .light
        }
    }

    /// Reads the conventional `COLORFGBG` background component. Only the final
    /// component is authoritative; malformed or unsupported values fall back to
    /// dark. Standard and xterm-256 indices are classified by perceived RGB
    /// brightness, avoiding the common mistake of treating bright black (8) as
    /// a light background merely because its numeric index is above 7.
    static func appearance(environment: [String: String]) -> Appearance {
        guard let value = environment["COLORFGBG"] else {
            return .dark
        }
        let components = value.split(separator: ";", omittingEmptySubsequences: false)
        guard let finalComponent = components.last else {
            return .dark
        }
        let token = finalComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let background = Int(token),
              let (red, green, blue) = xtermRGB(for: background) else {
            return .dark
        }
        let perceivedBrightness = 299 * red + 587 * green + 114 * blue
        return perceivedBrightness > 128_000 ? .light : .dark
    }

    private static func xtermRGB(for index: Int) -> (Int, Int, Int)? {
        let standard: [(Int, Int, Int)] = [
            (0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0),
            (0, 0, 128), (128, 0, 128), (0, 128, 128), (192, 192, 192),
            (128, 128, 128), (255, 0, 0), (0, 255, 0), (255, 255, 0),
            (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)
        ]
        if standard.indices.contains(index) {
            return standard[index]
        }
        if (16...231).contains(index) {
            let componentValues = [0, 95, 135, 175, 215, 255]
            let offset = index - 16
            return (
                componentValues[offset / 36],
                componentValues[(offset / 6) % 6],
                componentValues[offset % 6]
            )
        }
        if (232...255).contains(index) {
            let level = 8 + (index - 232) * 10
            return (level, level, level)
        }
        return nil
    }
}
