//
//  ZenCommandSuggestions.swift
//  ZenApp
//
//  Slash-command suggestions of the composer, matched and completed like the
//  terminal UI's prompt editor (`TerminalPromptCompletion` and
//  `TerminalPromptEditor.acceptSuggestion`).
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// Matching and completion of slash commands and of their first argument in
/// the composer draft, with the rules of the terminal editor:
///
/// - Only a single-line draft that starts with `/` and holds no whitespace
///   other than literal spaces is completed.
/// - The token under the cursor is matched up to the cursor, and accepting a
///   suggestion replaces the whole token (editing `/fea|ture` matches `/fea`
///   and still replaces `/feature`).
/// - The leading token completes the command; the slot after it completes
///   the command's first argument from a static catalog
///   (``argumentsByCommand``), for commands the operator can run only; later
///   slots are never completed.
/// - Matching is case-sensitive, with the exact match first.
public enum ZenCommandSuggestions {
    /// What the cursor is completing in a draft.
    struct CompletionContext: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// The leading `/command` token.
            case command
            /// The first argument of `command`, i.e. its subcommand slot.
            case argument(command: String)
        }

        let kind: Kind
        /// The characters of the draft replaced when a suggestion is
        /// accepted: the whole token under the cursor.
        let replacementRange: Range<Int>
        /// The token between its start and the cursor, used for matching.
        let prefix: String
    }

    /// The draft after accepting a suggestion.
    struct Acceptance: Equatable, Sendable {
        /// The new draft.
        let draft: String
        /// The cursor in `draft`, in characters.
        let cursor: Int
        /// Whether the draft is sent as well: Return on a suggestion that is
        /// complete as typed.
        let submits: Bool
    }

    /// The suggestions for the token under the cursor, ordered with the exact
    /// matches first (so Return never picks a longer neighbour of a complete
    /// command).
    ///
    /// Command suggestions are elements of `commands`; argument suggestions
    /// carry the bare argument in ``ChatCommandDescriptor/command`` (`save`
    /// for `/sessions save`) and are offered only after a command among
    /// `commands`, so a hidden command never leaks through its arguments.
    ///
    /// - Parameter cursor: The cursor in `draft`, in characters; `nil` is
    ///   the end of the draft.
    public static func matches(
        for draft: String,
        cursor: Int? = nil,
        in commands: [ChatCommandDescriptor]
    ) -> [ChatCommandDescriptor] {
        guard let context = completionContext(in: Array(draft), cursor: cursor) else {
            return []
        }
        switch context.kind {
        case .command:
            guard !context.prefix.isEmpty else {
                return []
            }
            return ordered(candidates: commands.filter { $0.command.hasPrefix("/") }, prefix: context.prefix)
        case let .argument(command):
            guard commands.contains(where: { $0.command == command }) else {
                return []
            }
            return ordered(candidates: argumentSuggestions(for: command), prefix: context.prefix)
        }
    }

    /// The draft that accepting the command `descriptor` leaves when the
    /// draft is the command token alone: the command, followed by a space
    /// when it requires an argument. Argument suggestions and drafts with
    /// more text go through ``accept(_:in:cursor:submitting:)``.
    public static func completion(for descriptor: ChatCommandDescriptor) -> String {
        descriptor.requiresArgument ? descriptor.command + " " : descriptor.command
    }

    /// Whether accepting `descriptor` with Return also submits it when the
    /// draft is the command token alone: a command that needs an argument
    /// only completes, every other one is sent.
    public static func submitsOnReturn(_ descriptor: ChatCommandDescriptor) -> Bool {
        !descriptor.requiresArgument
    }

    /// Accepts `suggestion` for the token under the cursor
    /// (`TerminalPromptEditor.acceptSuggestion`): the token is replaced and
    /// the cursor follows it. A suggestion that requires an argument submits
    /// only when an operand already follows it; otherwise it parks the cursor
    /// after a separating space. Any other suggestion submits when
    /// `submitting` (Return) and only completes otherwise (Tab, click).
    ///
    /// `nil` when nothing in the draft is being completed.
    static func accept(
        _ suggestion: ChatCommandDescriptor,
        in draft: String,
        cursor: Int? = nil,
        submitting: Bool
    ) -> Acceptance? {
        var buffer = Array(draft)
        guard let context = completionContext(in: buffer, cursor: cursor) else {
            return nil
        }
        let replacement = Array(suggestion.command)
        buffer.replaceSubrange(context.replacementRange, with: replacement)
        var newCursor = context.replacementRange.lowerBound + replacement.count

        guard suggestion.requiresArgument else {
            return Acceptance(draft: String(buffer), cursor: newCursor, submits: submitting)
        }
        if hasArgument(in: buffer, after: newCursor) {
            // A complete command with an existing operand is sent as typed.
            return Acceptance(draft: String(buffer), cursor: newCursor, submits: submitting)
        }
        // Not complete yet: park the cursor after a separator instead of
        // sending an unusable line.
        if newCursor >= buffer.count || buffer[newCursor] != " " {
            buffer.insert(" ", at: newCursor)
        }
        newCursor += 1
        return Acceptance(draft: String(buffer), cursor: newCursor, submits: false)
    }

    // MARK: - Token under the cursor

    /// Classifies the token under the cursor
    /// (`TerminalPromptCompletion.completion`); `nil` when nothing is
    /// completed there.
    static func completionContext(in buffer: [Character], cursor: Int?) -> CompletionContext? {
        guard !buffer.contains("\n"),
              !buffer.contains(where: { $0.isWhitespace && $0 != " " }),
              buffer.first == "/" else {
            return nil
        }
        let cursor = min(max(0, cursor ?? buffer.count), buffer.count)
        let commandEnd = buffer.firstIndex(of: " ") ?? buffer.count
        if cursor <= commandEnd {
            return CompletionContext(
                kind: .command,
                replacementRange: 0..<commandEnd,
                prefix: String(buffer[0..<cursor])
            )
        }

        var start = cursor
        while start > commandEnd, buffer[start - 1] != " " {
            start -= 1
        }
        var end = cursor
        while end < buffer.count, buffer[end] != " " {
            end += 1
        }

        let command = String(buffer[0..<commandEnd])
        let precedingArguments = buffer[commandEnd..<start].split(separator: " ")
        guard precedingArguments.isEmpty else {
            // Later slots are free-form ids, paths or text for every command
            // the app offers.
            return nil
        }
        return CompletionContext(
            kind: .argument(command: command),
            replacementRange: start..<end,
            prefix: String(buffer[start..<cursor])
        )
    }

    /// The candidates that start with `prefix`, the exact matches first.
    static func ordered(
        candidates: [ChatCommandDescriptor],
        prefix: String
    ) -> [ChatCommandDescriptor] {
        let matches = candidates.filter { $0.command.hasPrefix(prefix) }
        let exactMatches = matches.filter { $0.command == prefix }
        guard !exactMatches.isEmpty else {
            return matches
        }
        return exactMatches + matches.filter { $0.command != prefix }
    }

    /// Whether an operand follows `index`, with the literal-space grammar of
    /// the command dispatcher.
    private static func hasArgument(in buffer: [Character], after index: Int) -> Bool {
        let start = min(max(0, index), buffer.count)
        guard start < buffer.count, buffer[start] == " " else {
            return false
        }
        return buffer[(start + 1)...].contains { $0 != " " }
    }

    // MARK: - Argument catalog

    /// The first-argument suggestions of `command`; empty for a command
    /// without a static vocabulary.
    static func argumentSuggestions(for command: String) -> [ChatCommandDescriptor] {
        argumentsByCommand[command] ?? []
    }

    /// The first arguments of the shared commands the app offers, ported from
    /// `TerminalPromptCompletionCatalog.argumentsByCommand` of the terminal
    /// UI. Entries that need a further operand are marked `requiresArgument`,
    /// so accepting them types a separator instead of sending an incomplete
    /// line.
    ///
    /// Deliberately left out, because they do not work in the app:
    /// - `/tools logs`: the terminal's log viewer, a channel command the app
    ///   answers as not available;
    /// - `/sessions tree`, `/sessions branches`, `/sessions checkpoint`: no
    ///   handler runs them, so the shared `/sessions` would save the session
    ///   under that name.
    ///
    /// No command of the app completes the slots after its first argument
    /// (in the terminal only `/cron` does, and the app does not offer it).
    static let argumentsByCommand: [String: [ChatCommandDescriptor]] = [
        "/sessions": [
            argument("/sessions", "save", "save the current session"),
            argument("/sessions", "new", "start a new session"),
            argument("/sessions", "compact", "compact the context"),
            argument("/sessions", "memory", "show the memory block of the last prompt"),
            argument("/sessions", "delete", "delete a saved session"),
            argument("/sessions", "restore", "restore from a checkpoint")
        ],
        "/tasks": [
            argument("/tasks", "status", "show the task graph"),
            argument("/tasks", "list", "list tasks"),
            argument("/tasks", "ls", "list tasks"),
            argument("/tasks", "show", "show one task by id", requiresArgument: true),
            argument("/tasks", "get", "show one task by id", requiresArgument: true),
            argument("/tasks", "retry", "retry a failed task", requiresArgument: true),
            argument("/tasks", "cancel", "cancel a task", requiresArgument: true),
            argument("/tasks", "clear", "clear the task graphs")
        ],
        "/plan": [
            argument("/plan", "save", "persist the current plan and its queue"),
            argument("/plan", "load", "restore the first unfinished saved draft"),
            argument("/plan", "list", "list saved plans"),
            argument("/plan", "delete", "delete saved plans by id, prefix, or all", requiresArgument: true),
            argument("/plan", "status", "show plan progress"),
            argument("/plan", "approve", "approve and start the plan"),
            argument("/plan", "clear", "discard the active plan in this session")
        ],
        "/agents": [
            argument("/agents", "list", "list agent profiles"),
            argument("/agents", "ls", "list agent profiles"),
            argument("/agents", "status", "list agent profiles")
        ],
        "/tools": [
            argument("/tools", "all", "select all tool groups"),
            argument("/tools", "none", "clear the tool selection"),
            argument("/tools", "off", "clear the tool selection"),
            argument("/tools", "clear", "clear the tool selection"),
            argument("/tools", "disabled", "clear the tool selection")
        ],
        "/attach": [
            argument("/attach", "list", "show pending attachments"),
            argument("/attach", "delete", "remove pending attachments", requiresArgument: true)
        ],
        "/changes": [
            argument("/changes", "diff", "include patches"),
            argument("/changes", "--diff", "include patches")
        ],
        "/skills": [
            argument("/skills", "all", "select all installed skills"),
            argument("/skills", "none", "clear the skill selection"),
            argument("/skills", "add", "install from GitHub or a local path", requiresArgument: true),
            argument("/skills", "install", "install from GitHub or a local path", requiresArgument: true),
            argument("/skills", "uninstall", "uninstall selected app-installed skills")
        ]
    ]

    /// An argument suggestion: the bare argument as the command, with the
    /// full line as its help.
    private static func argument(
        _ command: String,
        _ argument: String,
        _ summary: String,
        requiresArgument: Bool = false
    ) -> ChatCommandDescriptor {
        ChatCommandDescriptor(
            command: argument,
            summary: summary,
            help: "\(command) \(argument)",
            requiresArgument: requiresArgument
        )
    }
}

/// Keyboard state of the suggestion list: the highlighted row and the draft
/// for which Esc dismissed the list.
///
/// Like the terminal editor, every edit and every cursor move restarts from
/// the first suggestion, an edit brings a dismissed list back, and ↑/↓ wrap
/// around.
struct ZenSuggestionNavigator: Equatable {
    private(set) var highlightedIndex = 0
    private(set) var dismissedDraft: String?

    /// Whether Esc dismissed the list for this exact draft.
    func isDismissed(for draft: String) -> Bool {
        dismissedDraft == draft
    }

    /// Esc: hides the list until the draft changes.
    mutating func dismiss(draft: String) {
        dismissedDraft = draft
    }

    /// Any edit of the draft.
    mutating func draftChanged(to draft: String) {
        highlightedIndex = 0
        if dismissedDraft != draft {
            dismissedDraft = nil
        }
    }

    /// The cursor moved: completion follows the token at the cursor, so the
    /// highlight restarts from the first suggestion (a dismissed list stays
    /// hidden, like the terminal editor).
    mutating func cursorMoved() {
        highlightedIndex = 0
    }

    /// ↑ (`-1`) or ↓ (`+1`), wrapping around `count` rows.
    mutating func move(by delta: Int, count: Int) {
        guard count > 0 else {
            highlightedIndex = 0
            return
        }
        highlightedIndex = ((highlightedIndex + delta) % count + count) % count
    }

    /// The highlighted row clamped to `count` rows.
    func boundedIndex(count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, highlightedIndex), count - 1)
    }

    /// The highlighted row of `matches` (command descriptors or
    /// ``ZenSuggestionRow``s), `nil` when there is none.
    func highlighted<Row>(in matches: [Row]) -> Row? {
        guard !matches.isEmpty else { return nil }
        return matches[boundedIndex(count: matches.count)]
    }
}

/// The glass list of suggestions shown above the composer field: the slash
/// command or the `@mention` in the accent color, its summary in the
/// suggestion color.
struct ZenCommandSuggestionList: View {
    @Environment(\.zenPalette) private var palette
    let matches: [ZenSuggestionRow]
    let highlightedIndex: Int
    let monospaced: Bool
    let onSelect: (Int) -> Void

    private static let rowHeight: CGFloat = 26
    private static let maximumVisibleRows = 6

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.offset) { index, suggestion in
                        row(suggestion, isHighlighted: index == highlightedIndex)
                            .id(index)
                            .onTapGesture { onSelect(index) }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.automatic)
            .frame(height: listHeight)
            .onChange(of: highlightedIndex) { _, newValue in
                proxy.scrollTo(newValue)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityLabel(accessibilityLabel)
    }

    /// The list is either all commands or all mentions.
    private var accessibilityLabel: String {
        matches.first?.isMention == true ? "Mention suggestions" : "Command suggestions"
    }

    private var listHeight: CGFloat {
        CGFloat(min(matches.count, Self.maximumVisibleRows)) * Self.rowHeight + 12
    }

    private func row(_ suggestion: ZenSuggestionRow, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Text(suggestion.title)
                .font(monospaced ? ZenFonts.monoSmall : .callout.weight(.medium))
                .foregroundStyle(palette.accent)
            Text(suggestion.summary)
                .font(.callout)
                .foregroundStyle(palette.suggestion)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 8)
                    .fill(palette.accent.opacity(0.18))
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}
