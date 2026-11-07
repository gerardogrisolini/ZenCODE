//
//  TerminalTelegramTurnActivity.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The presentation of what a turn presented in Telegram shows besides its
/// responses: the rows of a tool-activity message, the thinking message, and
/// the turn's sub-agent status message.
///
/// Every text shaped here is model output (a tool title, a reasoning block, a
/// sub-agent name or activity) and therefore untrusted: it is reduced to
/// visible characters and sent as plain text, or styled by entity, never
/// parsed as Markdown or HTML. No tool argument or result reaches it: a
/// tool row is the call's title and, once the call ended, its outcome and
/// elapsed time.
enum TerminalTelegramTurnActivity {
    /// The longest tool title an activity row shows, in characters.
    static let maximumToolTitleLength = 200
    /// The longest row of the sub-agent status message, in characters.
    static let maximumStatusRowLength = 160
    /// The marker that opens the thinking message, inside the quotation of
    /// the reasoning and followed by a space.
    static let thinkingMarker = "💭"
    /// The first line of the sub-agent status message.
    static let subAgentStatusHeading = "🤖 Sub-agent"

    /// How a tool call of an activity row ended.
    enum ToolOutcome: Sendable, Equatable {
        case succeeded
        case failed
    }

    // MARK: - Tool activity

    /// One row of an activity message: a neutral marker while the call runs,
    /// then only its outcome and, when known, its elapsed time after the
    /// title, formatted as the terminal formats it
    /// (``ToolCallPresentation/elapsedTimeText(_:)``, e.g. `✅ Read file 1.25s`).
    /// A running row never shows a time.
    static func toolRow(title: String, outcome: ToolOutcome?, elapsed: Duration? = nil) -> String {
        let marker = switch outcome {
        case nil: "⏳"
        case .succeeded: "✅"
        case .failed: "❌"
        }
        guard outcome != nil, let elapsed else {
            return "\(marker) \(title)"
        }
        return "\(marker) \(title) \(ToolCallPresentation.elapsedTimeText(elapsed))"
    }

    /// The title of a tool call as an activity row shows it: one line, at
    /// most ``maximumToolTitleLength`` characters.
    static func toolTitle(_ title: String) -> String {
        singleLine(title, maximumLength: maximumToolTitleLength).nilIfBlank ?? "tool"
    }

    // MARK: - Thinking

    /// A reasoning block as the thinking message carries it: trimmed, at most
    /// ``TerminalTelegramTurnProgressReporter/maximumMessageLength``
    /// characters, an ellipsis included when it was cut; `nil` when blank.
    static func boundedThought(_ text: String) -> String? {
        let visible = PresentationSanitizer.visibleText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return nil }
        return InlineTextTruncation.truncatedByCount(
            visible,
            limit: TerminalTelegramTurnProgressReporter.maximumMessageLength,
            ellipsis: "…"
        )
    }

    /// The thinking message: a plain text made of ``thinkingMarker``, a
    /// space, and the reasoning reduced to visible characters. One
    /// expandable blockquote covers the whole text (collapsed to its first
    /// lines, expanded with a tap), so no heading or blank line sits outside
    /// it and the collapsed message is only those lines; an italic covers
    /// the reasoning. Both are entities, offsets in UTF-16 code units of the
    /// text as the wire bounds it. It is never a rich message and never
    /// parsed as Markdown or HTML: the reasoning is model output, so any
    /// markup in it stays literal.
    static func thoughtMessage(
        _ thought: String
    ) -> (text: String, entities: [TerminalTelegramMessageEntity]) {
        let prefix = "\(thinkingMarker) "
        let body = PresentationSanitizer.visibleText(thought)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = TerminalTelegramAPIClient.boundedMessageText(prefix + body)
        let offset = prefix.utf16.count
        let length = text.utf16.count - offset
        guard !body.isEmpty, length > 0 else {
            return (text, [])
        }
        return (text, [
            .expandableBlockquote(offset: 0, length: text.utf16.count),
            .italic(offset: offset, length: length),
        ])
    }

    // MARK: - Sub-agent status

    /// The sub-agent status message: ``subAgentStatusHeading`` over `rows`,
    /// each a single line of at most ``maximumStatusRowLength`` characters;
    /// `nil` without rows.
    static func subAgentStatusText(rows: [String]) -> String? {
        let lines = rows
            .map { singleLine($0, maximumLength: maximumStatusRowLength) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return ([subAgentStatusHeading, ""] + lines).joined(separator: "\n")
    }

    // MARK: - Text

    /// `text` as one plain line: visible characters only (terminal styling
    /// and wire-invisible controls removed), every line break and tab turned
    /// into a space, the ends trimmed, and cut to `maximumLength` characters
    /// with an ellipsis.
    static func singleLine(_ text: String, maximumLength: Int) -> String {
        let visible = PresentationSanitizer.visibleText(TerminalANSIText.stripANSI(text))
        let line = visible
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return InlineTextTruncation.truncatedByCount(line, limit: maximumLength, ellipsis: "…")
    }
}
