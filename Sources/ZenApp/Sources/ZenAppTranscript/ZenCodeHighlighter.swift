//
//  ZenCodeHighlighter.swift
//  ZenApp
//
//  The injectable syntax highlighter of the source lines of the transcript's
//  file-artifact diffs.
//

import Foundation
import SwiftUI
import ZenAppTheme

/// Colors one line of source code.
///
/// The diffs of the file artifacts color their source lines as the terminal
/// does, one line at a time, with the highlighter installed in the environment
/// (`\.zenCodeHighlighter`). The module cannot depend on the Markdown target,
/// which owns the highlighter, so the default leaves every line to the colors
/// of its diff row; the app installs the real highlighter at the root of the
/// window.
public struct ZenCodeHighlighter: Sendable {
    private let highlightLine: @Sendable (String, String, ZenPalette) -> AttributedString?

    /// Creates a highlighter.
    ///
    /// - Parameter highlight: Colors a line (without its terminator) in a
    ///   language (`TerminalChat.codeLanguageHint(forPath:)`) with a palette;
    ///   `nil` leaves the line to the colors of its diff row.
    public init(
        _ highlight: @escaping @Sendable (_ line: String, _ language: String, _ palette: ZenPalette) -> AttributedString?
    ) {
        self.highlightLine = highlight
    }

    /// `line` colored in `language` with `palette`, or `nil` to leave it to
    /// the colors of its diff row.
    public func highlight(_ line: String, language: String, palette: ZenPalette) -> AttributedString? {
        highlightLine(line, language, palette)
    }

    /// The default highlighter: it colors nothing, so every line keeps the
    /// colors of its diff row.
    public static let plain = ZenCodeHighlighter { _, _, _ in nil }
}

extension EnvironmentValues {
    /// The highlighter of the source lines of the file-artifact diffs, read
    /// with `@Environment(\.zenCodeHighlighter)`. Defaults to
    /// ``ZenCodeHighlighter/plain``.
    @Entry public var zenCodeHighlighter: ZenCodeHighlighter = .plain
}
