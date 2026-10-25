//
//  TerminalPromptCompletion.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// What the cursor is currently completing inside a slash-command draft.
///
/// The prefix is always measured *up to the cursor* while the replacement
/// covers the whole token: editing in the middle of `/fea|ture` must match
/// `/fea` and still replace `/feature`, otherwise the accepted completion
/// leaves the old suffix behind.
struct TerminalPromptCompletion: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The leading `/command` token.
        case command
        /// The first argument of a known command, i.e. its subcommand slot.
        case argument(command: String)
        /// A slot after the first argument of a command with a static later
        /// vocabulary (see `TerminalPromptCompletionCatalog`). The arguments
        /// already typed before the token under the cursor travel with it,
        /// because what a slot means depends on them.
        case laterArgument(command: String, precedingArguments: [String])
        /// The leading `@name` token of a single-line prompt.
        case mention
    }

    let kind: Kind
    /// Character range in the buffer replaced when a suggestion is accepted.
    let replacementRange: Range<Int>
    /// Text between the token start and the cursor, used for matching.
    let prefix: String

    /// Argument completions carry the bare token, command completions the full
    /// `/command`, so the inserted text is simply the suggestion's command.
    func replacementText(for suggestion: TerminalCommandSuggestion) -> String {
        suggestion.command
    }

    /// Classifies the token under the cursor.
    ///
    /// Only single-line drafts participate in completion. Slash commands and
    /// shared-chat `@name` mentions are restricted to the leading token, which
    /// mirrors the shared-chat router grammar exactly.
    static func completion(
        buffer: [Character],
        cursorIndex: Int
    ) -> TerminalPromptCompletion? {
        guard !buffer.contains("\n"),
              !buffer.contains(where: { $0.isWhitespace && $0 != " " }) else {
            return nil
        }

        let cursor = min(max(0, cursorIndex), buffer.count)
        if let mention = mentionCompletion(buffer: buffer, cursorIndex: cursor) {
            return mention
        }
        guard buffer.first == "/" else {
            return nil
        }
        let commandEnd = buffer.firstIndex { $0 == " " } ?? buffer.count
        if cursor <= commandEnd {
            return TerminalPromptCompletion(
                kind: .command,
                replacementRange: 0..<commandEnd,
                prefix: String(buffer[0..<cursor])
            )
        }

        var start = cursor
        while start > commandEnd, !isSeparator(buffer[start - 1]) {
            start -= 1
        }
        var end = cursor
        while end < buffer.count, !isSeparator(buffer[end]) {
            end += 1
        }

        // Slots after the first argument depend on the arguments before them,
        // which only a command with its own static vocabulary can interpret.
        // Every other command stops at its subcommand slot, exactly as the
        // dispatcher offers nothing deeper to complete.
        let command = String(buffer[0..<commandEnd])
        let precedingArguments = buffer[commandEnd..<start]
            .split(separator: " ")
            .map { String($0) }
        guard precedingArguments.isEmpty else {
            guard TerminalPromptCompletionCatalog.completesLaterArguments(of: command) else {
                return nil
            }
            return TerminalPromptCompletion(
                kind: .laterArgument(command: command, precedingArguments: precedingArguments),
                replacementRange: start..<end,
                prefix: String(buffer[start..<cursor])
            )
        }

        return TerminalPromptCompletion(
            kind: .argument(command: command),
            replacementRange: start..<end,
            prefix: String(buffer[start..<cursor])
        )
    }

    /// Suggestions for the token under the cursor, ordered with exact matches
    /// first so `Enter` never picks a longer neighbour of a complete command.
    static func matches(
        buffer: [Character],
        cursorIndex: Int,
        commands: [TerminalCommandSuggestion]
    ) -> [TerminalCommandSuggestion] {
        guard let completion = completion(buffer: buffer, cursorIndex: cursorIndex) else {
            return []
        }

        let candidates: [TerminalCommandSuggestion]
        switch completion.kind {
        case .command:
            guard !completion.prefix.isEmpty else {
                return []
            }
            candidates = commands.filter { $0.command.hasPrefix("/") }
        case .mention:
            candidates = commands.filter { $0.command.hasPrefix("@") }
        case let .argument(command):
            // Offer arguments only for commands the current agent can actually
            // run, so a hidden command never leaks through its subcommands.
            guard commands.contains(where: { $0.command == command }) else {
                return []
            }
            candidates = TerminalPromptCompletionCatalog.argumentSuggestions(for: command)
        case let .laterArgument(command, precedingArguments):
            // Same guard as above. The catalogue matches the prefix itself and
            // returns the final list: its guide rows are placeholders such as
            // `<minute>` that the typed prefix must not filter out.
            guard commands.contains(where: { $0.command == command }) else {
                return []
            }
            return TerminalPromptCompletionCatalog.laterArgumentSuggestions(
                for: command,
                precedingArguments: precedingArguments,
                prefix: completion.prefix
            )
        }

        return ordered(candidates: candidates, prefix: completion.prefix)
    }

    static func ordered(
        candidates: [TerminalCommandSuggestion],
        prefix: String
    ) -> [TerminalCommandSuggestion] {
        let matches = candidates.filter { candidate in
            candidate.command.hasPrefix(prefix)
        }
        let exactMatches = matches.filter { candidate in
            candidate.command == prefix
        }
        guard !exactMatches.isEmpty else {
            return matches
        }
        return exactMatches + matches.filter { candidate in
            candidate.command != prefix
        }
    }

    private static func mentionCompletion(
        buffer: [Character],
        cursorIndex: Int
    ) -> TerminalPromptCompletion? {
        var start = cursorIndex
        while start > 0, buffer[start - 1] != " " {
            start -= 1
        }
        // Shared-chat routing recognises a leading mention only. Leading spaces
        // are harmless because the router trims them, but do not offer a
        // completion after prose (or when the cursor moved into a later token),
        // because accepting it would produce a prompt the router treats as
        // ordinary coordinator text.
        let firstTokenStart = buffer.firstIndex { $0 != " " } ?? buffer.count
        guard start == firstTokenStart, start < buffer.count, buffer[start] == "@" else {
            return nil
        }
        var end = cursorIndex
        while end < buffer.count, buffer[end] != " " {
            end += 1
        }
        return TerminalPromptCompletion(
            kind: .mention,
            replacementRange: start..<end,
            prefix: String(buffer[start..<cursorIndex])
        )
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == " "
    }
}

/// Static subcommand vocabulary of the slash commands.
///
/// Every entry mirrors a branch the dispatcher really accepts (see
/// `TerminalChat+Commands` and the individual handlers); nothing here is
/// aspirational, because suggesting a subcommand that then fails to parse is
/// worse than suggesting nothing. Entries that need a further operand are
/// marked `requiresArgument` so accepting them types a separator instead of
/// sending an incomplete line.
enum TerminalPromptCompletionCatalog {
    static func argumentSuggestions(for command: String) -> [TerminalCommandSuggestion] {
        argumentsByCommand[command] ?? []
    }

    /// Whether `command` also completes the slots after its first argument.
    ///
    /// Only `/cron` does: its operands (schedule, cron fields, entry number,
    /// mail recipient) form a small static grammar, whereas the later operands
    /// of every other command are free-form ids, paths or text.
    static func completesLaterArguments(of command: String) -> Bool {
        command == "/cron"
    }

    /// Suggestions for a slot after the first argument.
    ///
    /// `precedingArguments` are the complete arguments before the token under
    /// the cursor (the subcommand first) and `prefix` is that token up to the
    /// cursor. The result is final: already matched against `prefix` and
    /// ordered, because its guide rows (`isHint`) are placeholders the prefix
    /// must not filter out. Every command other than `/cron` yields nothing.
    static func laterArgumentSuggestions(
        for command: String,
        precedingArguments: [String],
        prefix: String
    ) -> [TerminalCommandSuggestion] {
        guard completesLaterArguments(of: command) else {
            return []
        }
        return cronLaterArgumentSuggestions(precedingArguments: precedingArguments, prefix: prefix)
    }

    static let argumentsByCommand: [String: [TerminalCommandSuggestion]] = [
        "/sessions": [
            TerminalCommandSuggestion(command: "save", summary: "save the current session"),
            TerminalCommandSuggestion(command: "new", summary: "start a new session"),
            TerminalCommandSuggestion(command: "compact", summary: "compact the context"),
            TerminalCommandSuggestion(command: "delete", summary: "delete a saved session"),
            TerminalCommandSuggestion(command: "tree", summary: "show the checkpoint tree"),
            TerminalCommandSuggestion(command: "branches", summary: "list branch leaves"),
            TerminalCommandSuggestion(command: "checkpoint", summary: "create a checkpoint"),
            TerminalCommandSuggestion(command: "restore", summary: "restore from a checkpoint")
        ],
        "/tasks": [
            TerminalCommandSuggestion(command: "status", summary: "show the task graph"),
            TerminalCommandSuggestion(command: "list", summary: "list tasks"),
            TerminalCommandSuggestion(command: "ls", summary: "list tasks"),
            TerminalCommandSuggestion(
                command: "show",
                summary: "show one task by id",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "get",
                summary: "show one task by id",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "retry",
                summary: "retry a failed task",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "cancel",
                summary: "cancel a task",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(command: "clear", summary: "clear the task graphs")
        ],
        "/plan": [
            TerminalCommandSuggestion(command: "save", summary: "persist the current plan"),
            TerminalCommandSuggestion(command: "load", summary: "restore the newest saved draft"),
            TerminalCommandSuggestion(command: "list", summary: "list saved plans"),
            TerminalCommandSuggestion(
                command: "delete",
                summary: "delete saved plans by id, prefix, or all",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(command: "status", summary: "show plan progress"),
            TerminalCommandSuggestion(command: "approve", summary: "approve and start the plan"),
            TerminalCommandSuggestion(
                command: "clear",
                summary: "discard the active plan in this session"
            )
        ],
        "/agents": [
            TerminalCommandSuggestion(command: "list", summary: "list agent profiles"),
            TerminalCommandSuggestion(command: "ls", summary: "list agent profiles"),
            TerminalCommandSuggestion(command: "status", summary: "list agent profiles")
        ],
        "/tools": [
            TerminalCommandSuggestion(command: "all", summary: "select all tool groups"),
            TerminalCommandSuggestion(command: "none", summary: "clear the tool selection"),
            TerminalCommandSuggestion(command: "off", summary: "clear the tool selection"),
            TerminalCommandSuggestion(command: "clear", summary: "clear the tool selection"),
            TerminalCommandSuggestion(command: "disabled", summary: "clear the tool selection"),
            TerminalCommandSuggestion(command: "logs", summary: "open the system log viewer")
        ],
        "/feature": [
            TerminalCommandSuggestion(command: "list", summary: "enable/disable features"),
            TerminalCommandSuggestion(command: "ls", summary: "enable/disable features"),
            TerminalCommandSuggestion(command: "status", summary: "print known features"),
            TerminalCommandSuggestion(command: "reload", summary: "reload feature packages"),
            TerminalCommandSuggestion(
                command: "enable",
                summary: "enable a feature by id",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "disable",
                summary: "disable a feature by id",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "edit",
                summary: "edit a feature by id",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "modify",
                summary: "edit a feature by id",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "update",
                summary: "edit a feature by id",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "promote",
                summary: "promote a feature by id",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "delete",
                summary: "delete a feature by id",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "build",
                summary: "build a feature by id",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "validate",
                summary: "validate a feature by id",
                requiresArgument: true
            )
        ],
        "/attach": [
            TerminalCommandSuggestion(command: "list", summary: "show pending attachments"),
            TerminalCommandSuggestion(
                command: "delete",
                summary: "remove pending attachments",
                requiresArgument: true
            )
        ],
        "/changes": [
            TerminalCommandSuggestion(command: "diff", summary: "include patches"),
            TerminalCommandSuggestion(command: "--diff", summary: "include patches")
        ],
        "/telegram": [
            TerminalCommandSuggestion(command: "on", summary: "start Telegram control"),
            TerminalCommandSuggestion(command: "off", summary: "stop Telegram control")
        ],
        "/cron": [
            TerminalCommandSuggestion(
                command: "list",
                summary: "show scheduled prompts with their numbers"
            ),
            TerminalCommandSuggestion(
                command: "add",
                summary: "[json] <schedule> [-f <path>] <prompt> · e.g. @daily Summarize PRs",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "remove",
                summary: "<n> · delete entry n from /cron list",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "run",
                summary: "<n> · run entry n now, as cron would",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "mailto",
                summary: "[address|none|default] · where cron mails results"
            )
        ],
        "/voice": [
            TerminalCommandSuggestion(command: "on", summary: "start voice mode"),
            TerminalCommandSuggestion(command: "off", summary: "stop voice mode"),
            TerminalCommandSuggestion(command: "pause", summary: "stop listening and reading aloud"),
            TerminalCommandSuggestion(command: "resume", summary: "listen and read aloud again")
        ],
        "/skills": [
            TerminalCommandSuggestion(command: "all", summary: "select all installed skills"),
            TerminalCommandSuggestion(command: "none", summary: "clear the skill selection"),
            TerminalCommandSuggestion(
                command: "add",
                summary: "install from GitHub or a local path",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "install",
                summary: "install from GitHub or a local path",
                requiresArgument: true
            ),
            TerminalCommandSuggestion(
                command: "uninstall",
                summary: "uninstall selected app-installed skills"
            )
        ]
    ]
}
