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
/// tool row is the call's title and, once the call ended, its outcome.
enum TerminalTelegramTurnActivity {
    /// The longest tool title an activity row shows, in characters.
    static let maximumToolTitleLength = 200
    /// The longest row of the sub-agent status message, in characters.
    static let maximumStatusRowLength = 160
    /// The summary of the thinking message's expandable block.
    static let thinkingHeading = "💭 Thinking"
    /// The first line of the sub-agent status message.
    static let subAgentStatusHeading = "🤖 Sub-agent"

    /// How a tool call of an activity row ended.
    enum ToolOutcome: Sendable, Equatable {
        case succeeded
        case failed
    }

    // MARK: - Tool activity

    /// One row of an activity message: a neutral marker while the call runs,
    /// then only its outcome.
    static func toolRow(title: String, outcome: ToolOutcome?) -> String {
        let marker = switch outcome {
        case nil: "⏳"
        case .succeeded: "✅"
        case .failed: "❌"
        }
        return "\(marker) \(title)"
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

    /// The most paragraphs the thinking message's block holds; the rest of
    /// the text joins the last one.
    static let maximumThoughtParagraphs = 50

    /// The thinking message as a rich document: one closed, expandable
    /// details block titled ``thinkingHeading`` whose paragraphs are the
    /// reasoning as plain text runs (never parsed as Markdown).
    static func thoughtDocument(_ thought: String) -> PresentationDocument {
        let paragraphs = thoughtParagraphs(thought).map {
            PresentationBlock.paragraph(PresentationText($0))
        }
        return PresentationDocument(blocks: [
            .details(
                summary: PresentationText(thinkingHeading),
                blocks: paragraphs,
                isOpen: false
            ),
        ])
    }

    /// The thinking message without rich messages: the heading, a blank
    /// line, and the reasoning in italic through an entity that covers it,
    /// offsets in UTF-16 code units of the text as the wire bounds it.
    static func thoughtFallback(
        _ thought: String
    ) -> (text: String, entities: [TerminalTelegramMessageEntity]) {
        let prefix = "\(thinkingHeading)\n\n"
        let body = PresentationSanitizer.visibleText(thought)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = TerminalTelegramAPIClient.boundedMessageText(prefix + body)
        let offset = prefix.utf16.count
        let length = text.utf16.count - offset
        guard !body.isEmpty, length > 0 else {
            return (text, [])
        }
        return (text, [.italic(offset: offset, length: length)])
    }

    /// The paragraphs of a reasoning block: the text between blank lines,
    /// trimmed, at most ``maximumThoughtParagraphs``.
    private static func thoughtParagraphs(_ thought: String) -> [String] {
        let normalized = thought
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard paragraphs.count > maximumThoughtParagraphs else {
            return paragraphs
        }
        let kept = paragraphs.prefix(maximumThoughtParagraphs - 1)
        let rest = paragraphs.dropFirst(maximumThoughtParagraphs - 1).joined(separator: "\n\n")
        return Array(kept) + [rest]
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
