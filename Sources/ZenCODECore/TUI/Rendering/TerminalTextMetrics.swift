//
//  TerminalTextMetrics.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Measures text and terminal geometry for the renderers: the display width of
/// a text, the physical rows it occupies, and the width of the terminal.
///
/// The width of the terminal itself is probed and cached by ``TerminalWidth``;
/// the display width of a text is the ANSI-aware measure of
/// ``TerminalANSIText``.
enum TerminalTextMetrics {
    /// Columns assumed when the standard error reports no terminal width.
    private static let fallbackColumnCount = 100

    /// Number of terminal columns `text` occupies, ignoring ANSI escape
    /// sequences and counting wide glyphs as two.
    static func displayWidth(_ text: String) -> Int {
        TerminalANSIText.visibleWidth(text)
    }

    /// Physical rows `lines` occupy once written. Each line break starts a new
    /// row, an empty line takes one, and a row that exceeds the usable columns
    /// (`columnWidth`, the terminal width when `nil`, minus the content inset;
    /// never fewer than one) wraps onto the next.
    static func renderedTerminalRowCount(
        for lines: [String],
        contentInsetWidth: Int = 0,
        columnWidth: Int? = nil
    ) -> Int {
        let resolvedColumns = columnWidth ?? terminalColumnCount()
        let columns = max(1, resolvedColumns - contentInsetWidth)
        return lines.reduce(0) { result, line in
            let segments = line.split(
                omittingEmptySubsequences: false,
                whereSeparator: \.isNewline
            )
            return result + segments.reduce(0) { segmentResult, segment in
                let width = max(1, displayWidth(String(segment)))
                return segmentResult + max(1, (width + columns - 1) / columns)
            }
        }
    }

    /// Width of the terminal on the standard error, `100` when it reports
    /// none. The probe is cached briefly (see ``TerminalWidth``);
    /// `forceRefresh` bypasses the cache, as right before a destructive
    /// cursor operation.
    static func terminalColumnCount(forceRefresh: Bool = false) -> Int {
        TerminalWidth.current(
            descriptors: [AgentOutput.standardError.fileDescriptor],
            fallback: fallbackColumnCount,
            forceRefresh: forceRefresh
        )
    }
}
