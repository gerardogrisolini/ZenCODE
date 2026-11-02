//
//  InlineTextTruncation.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Count-based, single-line truncation shared by the terminal (startup box,
/// overviews, Telegram) and the menus the session controller builds.
///
/// **Count-based family.** Limits are measured in extended grapheme clusters
/// (`String.count`), so a double-width emoji or CJK glyph is one unit even when
/// it renders in two terminal columns. This deliberately differs from the
/// width-aware ``TerminalANSIText/truncate(_:to:)``: routing these helpers
/// through that core would silently change startup, overview, and Telegram
/// output.
enum InlineTextTruncation {
    /// Collapses `text` to a single line and truncates it to at most `limit`
    /// grapheme clusters, appending an `...` ellipsis when content is cut and
    /// the marker fits the supplied budget. The `...` glyph has a
    /// three-cluster budget, while its measurement remains count-based.
    nonisolated static func truncatedInline(_ text: String, limit: Int) -> String {
        let singleLine = inlineText(text)
        return truncatedByCount(singleLine, limit: limit, ellipsis: "...")
    }

    /// Shared count-based truncation core for the inline (non-width) family.
    /// Cuts `text` to at most `limit` grapheme clusters, reserving room for
    /// `ellipsis` and appending it only when content is actually removed.
    ///
    /// This mirrors the parametric-ellipsis shape of the width-based core
    /// ``TerminalANSIText/truncate(_:to:ellipsis:ellipsisWidth:)`` so the two
    /// families read consistently, but it deliberately measures with
    /// `String.count`/`prefix` (one unit per grapheme) instead of visible
    /// columns. Callers are expected to have already flattened newlines
    /// (e.g. via ``inlineText(_:)``). No ANSI handling is performed because the
    /// count-based callers never carry escape sequences.
    nonisolated static func truncatedByCount(
        _ text: String,
        limit: Int,
        ellipsis: String = "..."
    ) -> String {
        let boundedLimit = max(0, limit)
        guard text.count > boundedLimit else {
            return text
        }
        // The count-based contract is still an upper bound even when there is
        // insufficient room for the ellipsis. In that case preserve the prefix
        // without a marker instead of passing a negative count to `prefix`.
        guard boundedLimit >= ellipsis.count else {
            return String(text.prefix(boundedLimit))
        }
        return String(text.prefix(boundedLimit - ellipsis.count)) + ellipsis
    }

    /// `text` on one line: line breaks become spaces, and the ends are
    /// trimmed.
    nonisolated static func inlineText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
