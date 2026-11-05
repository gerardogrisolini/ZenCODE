//
//  ZenMentionSuggestions.swift
//  ZenApp
//
//  Shared-chat `@mention` suggestions of the composer, matched and completed
//  like the terminal UI's prompt editor (`TerminalPromptCompletion`'s
//  `.mention` kind and `TerminalPromptEditor.acceptSuggestion`), and the row
//  model that lets the suggestion list show slash commands and mentions alike.
//

import Foundation
import ZenCODECore

/// Matching and completion of the leading `@mention` of the composer draft,
/// with the rules of the terminal editor:
///
/// - Only a single-line draft that holds no whitespace other than literal
///   spaces is completed, and only its leading `@name` token: leading spaces
///   are harmless (the shared-chat router trims them), but a mention after
///   prose, or a cursor in a later token, completes nothing, because the
///   router would treat the accepted result as ordinary coordinator text.
/// - The token is matched up to the cursor, and accepting a suggestion
///   replaces the whole token (editing `@co|ord` matches `@co` and still
///   replaces `@coord`).
/// - Matching is case-sensitive on the suggestion's ``SharedChatMentionParser/Suggestion/command``
///   (`@handle` and one space), with the exact match first.
/// - A mention needs a message, so accepting one only completes: it never
///   sends the draft, not even with Return.
public enum ZenMentionSuggestions {
    /// What the cursor is completing in a draft: the leading mention token.
    struct CompletionContext: Equatable, Sendable {
        /// The characters of the draft replaced when a suggestion is
        /// accepted: the whole token under the cursor.
        let replacementRange: Range<Int>
        /// The token between its start and the cursor, used for matching.
        let prefix: String
    }

    /// The suggestions for the leading mention under the cursor, ordered with
    /// the exact matches first.
    ///
    /// - Parameters:
    ///   - cursor: The cursor in `draft`, in characters; `nil` is the end of
    ///     the draft.
    ///   - mentions: The mention catalogue, in display order.
    public static func matches(
        for draft: String,
        cursor: Int? = nil,
        in mentions: [SharedChatMentionParser.Suggestion]
    ) -> [SharedChatMentionParser.Suggestion] {
        guard let context = completionContext(in: Array(draft), cursor: cursor) else {
            return []
        }
        return ordered(candidates: mentions, prefix: context.prefix)
    }

    /// The one-line description of a mention in the suggestion list, as the
    /// terminal UI words it. An agent's name is made inline-safe (controls
    /// made inert, whitespace runs folded into one space), so the row never
    /// spans lines.
    public static func summary(for suggestion: SharedChatMentionParser.Suggestion) -> String {
        switch suggestion.target {
        case .coordinator:
            "message the live coordinator"
        case .all:
            "message the coordinator and all active agent instances"
        case let .agent(name):
            "message active agent: \(SharedChatMentionParser.inlineTerminalSafeText(name))"
        }
    }

    /// Whether `draft` begins with a mention (after any literal leading
    /// spaces), whatever the cursor completes.
    public static func startsMention(_ draft: String) -> Bool {
        draft.first(where: { $0 != " " }) == "@"
    }

    /// Accepts `suggestion` for the leading mention under the cursor
    /// (`TerminalPromptEditor.acceptSuggestion`): the whole token is replaced
    /// by the suggestion's command (`@handle` and one space) and the cursor
    /// follows it. It never submits: a mention without a message is invalid.
    ///
    /// `nil` when no leading mention is being completed.
    static func accept(
        _ suggestion: SharedChatMentionParser.Suggestion,
        in draft: String,
        cursor: Int? = nil
    ) -> ZenCommandSuggestions.Acceptance? {
        var buffer = Array(draft)
        guard let context = completionContext(in: buffer, cursor: cursor) else {
            return nil
        }
        let replacement = Array(suggestion.command)
        buffer.replaceSubrange(context.replacementRange, with: replacement)
        return ZenCommandSuggestions.Acceptance(
            draft: String(buffer),
            cursor: context.replacementRange.lowerBound + replacement.count,
            submits: false
        )
    }

    /// Whether the composer asks its owner for a fresh mention roster
    /// (`ZenComposerActions.refreshMentions`) as the draft and the cursor go
    /// from `oldDraft`/`oldCursor` to `newDraft`/`newCursor`: only when the
    /// cursor starts completing the leading mention (it completes one now and
    /// did not before), so the operator typing one, or coming back to edit
    /// one, refreshes the roster, while typing the message after the mention
    /// or moving inside the token refreshes nothing. A cursor of `nil` is the
    /// end of its draft.
    static func refreshesMentions(
        from oldDraft: String,
        oldCursor: Int?,
        to newDraft: String,
        newCursor: Int?
    ) -> Bool {
        completionContext(in: Array(newDraft), cursor: newCursor) != nil
            && completionContext(in: Array(oldDraft), cursor: oldCursor) == nil
    }

    // MARK: - Token under the cursor

    /// Classifies the token under the cursor
    /// (`TerminalPromptCompletion.mentionCompletion`); `nil` when no leading
    /// mention is completed there.
    static func completionContext(in buffer: [Character], cursor: Int?) -> CompletionContext? {
        guard !buffer.contains("\n"),
              !buffer.contains(where: { $0.isWhitespace && $0 != " " }) else {
            return nil
        }
        let cursor = min(max(0, cursor ?? buffer.count), buffer.count)
        var start = cursor
        while start > 0, buffer[start - 1] != " " {
            start -= 1
        }
        let firstTokenStart = buffer.firstIndex { $0 != " " } ?? buffer.count
        guard start == firstTokenStart, start < buffer.count, buffer[start] == "@" else {
            return nil
        }
        var end = cursor
        while end < buffer.count, buffer[end] != " " {
            end += 1
        }
        return CompletionContext(
            replacementRange: start..<end,
            prefix: String(buffer[start..<cursor])
        )
    }

    /// The candidates whose command starts with `prefix`, the exact matches
    /// first (`TerminalPromptCompletion.ordered`).
    static func ordered(
        candidates: [SharedChatMentionParser.Suggestion],
        prefix: String
    ) -> [SharedChatMentionParser.Suggestion] {
        let matches = candidates.filter { $0.command.hasPrefix(prefix) }
        let exactMatches = matches.filter { $0.command == prefix }
        guard !exactMatches.isEmpty else {
            return matches
        }
        return exactMatches + matches.filter { $0.command != prefix }
    }
}

/// One row of the composer's suggestion list: a slash command (or a command
/// argument) or a shared-chat mention, with what the list shows of it and how
/// accepting it edits the draft.
struct ZenSuggestionRow: Equatable, Sendable {
    /// What the row stands for.
    enum Source: Equatable, Sendable {
        case command(ChatCommandDescriptor)
        case mention(SharedChatMentionParser.Suggestion)
    }

    let source: Source

    init(command descriptor: ChatCommandDescriptor) {
        source = .command(descriptor)
    }

    init(mention suggestion: SharedChatMentionParser.Suggestion) {
        source = .mention(suggestion)
    }

    /// The first column, in the accent color: the command (or the bare
    /// argument), or the mention as `@handle`.
    var title: String {
        switch source {
        case let .command(descriptor):
            descriptor.command
        case let .mention(suggestion):
            "@\(suggestion.handle)"
        }
    }

    /// The second column, in the suggestion color.
    var summary: String {
        switch source {
        case let .command(descriptor):
            descriptor.summary
        case let .mention(suggestion):
            ZenMentionSuggestions.summary(for: suggestion)
        }
    }

    var isMention: Bool {
        if case .mention = source {
            return true
        }
        return false
    }

    /// The rows for the token under the cursor: the leading mention takes
    /// precedence, as in the terminal editor (a draft cannot be both, because
    /// a slash command starts with `/` and a mention with `@`).
    static func rows(
        for draft: String,
        cursor: Int? = nil,
        commands: [ChatCommandDescriptor],
        mentions: [SharedChatMentionParser.Suggestion]
    ) -> [ZenSuggestionRow] {
        let buffer = Array(draft)
        if ZenMentionSuggestions.completionContext(in: buffer, cursor: cursor) != nil {
            return ZenMentionSuggestions.matches(for: draft, cursor: cursor, in: mentions)
                .map(ZenSuggestionRow.init(mention:))
        }
        return ZenCommandSuggestions.matches(for: draft, cursor: cursor, in: commands)
            .map(ZenSuggestionRow.init(command:))
    }

    /// The draft after accepting the row for the token under the cursor.
    /// `submitting` is Return: a mention never submits; a command submits when
    /// it is complete (see ``ZenCommandSuggestions``).
    func accept(in draft: String, cursor: Int? = nil, submitting: Bool) -> ZenCommandSuggestions.Acceptance? {
        switch source {
        case let .command(descriptor):
            ZenCommandSuggestions.accept(descriptor, in: draft, cursor: cursor, submitting: submitting)
        case let .mention(suggestion):
            ZenMentionSuggestions.accept(suggestion, in: draft, cursor: cursor)
        }
    }
}
