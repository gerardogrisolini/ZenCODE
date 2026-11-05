//
//  ZenMentionSuggestionsTests.swift
//  ZenApp
//
//  @mention matching and completion (mirroring `TerminalPromptCompletion` and
//  `TerminalPromptEditor.acceptSuggestion`), when the composer refreshes the
//  mention roster, the unified suggestion rows and the summaries of the
//  mention rows.
//

import Foundation
import Testing
import ZenCODECore

@testable import ZenAppControls

private typealias Mention = SharedChatMentionParser.Suggestion

/// The catalogue as the session builds it: `@coordinator` and `@all` first,
/// then the active agents.
private let catalogue: [Mention] = [
    Mention(handle: "coordinator", target: .coordinator),
    Mention(handle: "all", target: .all),
    Mention(handle: "builder", target: .agent(name: "Builder")),
    Mention(handle: "builder-2", target: .agent(name: "Builder")),
    Mention(handle: "reviewer", target: .agent(name: "Reviewer"))
]

@Suite("ZenMentionSuggestions matching")
struct ZenMentionMatchingTests {
    private func handles(_ draft: String, cursor: Int? = nil, in mentions: [Mention] = catalogue) -> [String] {
        ZenMentionSuggestions.matches(for: draft, cursor: cursor, in: mentions).map(\.handle)
    }

    @Test("a lone @ lists the whole catalogue in display order")
    func loneAtListsAll() {
        #expect(handles("@") == ["coordinator", "all", "builder", "builder-2", "reviewer"])
    }

    @Test("prefix matches keep the catalogue order")
    func prefixMatchesInDisplayOrder() {
        #expect(handles("@b") == ["builder", "builder-2"])
        #expect(handles("@builder") == ["builder", "builder-2"])
        #expect(handles("@builder-") == ["builder-2"])
        #expect(handles("@co") == ["coordinator"])
        #expect(handles("@a") == ["all"])
        #expect(handles("@x").isEmpty)
    }

    @Test("matching is case-sensitive, like the terminal")
    func caseSensitive() {
        #expect(handles("@Co").isEmpty)
        #expect(handles("@ALL").isEmpty)
    }

    @Test("an exact match comes first")
    func exactMatchFirst() {
        // The command of a mention ends with a space, so the exact comparison
        // of the terminal (`command == prefix`) is only reachable with a
        // catalogue whose commands are typed without it.
        let exact = ZenMentionSuggestions.ordered(
            candidates: [
                Mention(handle: "builder-2", target: .agent(name: "B2")),
                Mention(handle: "builder", target: .agent(name: "B"))
            ],
            prefix: "@builder "
        )
        #expect(exact.map(\.handle) == ["builder"])
        // A prefix that is not exact keeps the catalogue order.
        #expect(
            ZenMentionSuggestions.ordered(candidates: catalogue, prefix: "@builder").map(\.handle)
                == ["builder", "builder-2"]
        )
        // Typing the handle and a space leaves the token: nothing completes.
        #expect(handles("@builder ").isEmpty)
    }

    @Test("a mention is completed only in a single-line draft")
    func singleLineOnly() {
        #expect(handles("@co\n").isEmpty)
        #expect(handles("@co\nsecond line").isEmpty)
        #expect(handles("first\n@co").isEmpty)
        #expect(handles("@co\t").isEmpty)
        #expect(handles("@co\u{00A0}").isEmpty)
        #expect(handles("@co\u{2028}x").isEmpty)
    }

    @Test("only the leading token completes")
    func leadingTokenOnly() {
        #expect(handles("").isEmpty)
        #expect(handles("co").isEmpty)
        #expect(handles("hello @co").isEmpty)
        #expect(handles("/help @co").isEmpty)
        #expect(handles("a@co").isEmpty)
        // Leading spaces are harmless: the router trims them.
        #expect(handles("  @co") == ["coordinator"])
        #expect(handles("  @") == ["coordinator", "all", "builder", "builder-2", "reviewer"])
    }

    @Test("the cursor must be inside the leading token")
    func cursorInsideTheToken() {
        // "@co| text": the cursor is at the end of the token.
        #expect(handles("@co text", cursor: 3) == ["coordinator"])
        // "@coordinator |text": the cursor is after the token, in the message.
        #expect(handles("@coordinator text", cursor: 13).isEmpty)
        #expect(handles("@coordinator text", cursor: 17).isEmpty)
        // "@co text|": the cursor moved into a later token.
        #expect(handles("@co text", cursor: 8).isEmpty)
        // "@co |text".
        #expect(handles("@co text", cursor: 4).isEmpty)
        // In the leading spaces, before the token.
        #expect(handles("  @co", cursor: 1).isEmpty)
        #expect(handles("  @co", cursor: 0).isEmpty)
        // Without a cursor the end of the draft is used.
        #expect(handles("@co") == ["coordinator"])
        // A cursor outside the draft is clamped.
        #expect(handles("@co", cursor: 99) == ["coordinator"])
        // Before the first character the prefix is empty, as in the terminal:
        // every mention is listed and the whole token is still replaced.
        #expect(handles("@co", cursor: -3) == handles("@"))
    }

    @Test("the prefix is measured up to the cursor and the whole token is replaced")
    func prefixUpToTheCursor() {
        let context = ZenMentionSuggestions.completionContext(in: Array("@coord text"), cursor: 3)
        #expect(context?.prefix == "@co")
        #expect(context?.replacementRange == 0..<6)
        #expect(handles("@coord text", cursor: 3) == ["coordinator"])

        let leading = ZenMentionSuggestions.completionContext(in: Array("  @all"), cursor: 6)
        #expect(leading?.prefix == "@all")
        #expect(leading?.replacementRange == 2..<6)
    }

    @Test("an empty catalogue completes nothing")
    func emptyCatalogue() {
        #expect(handles("@", in: []).isEmpty)
        #expect(handles("@co", in: []).isEmpty)
    }

    @Test("a draft starts a mention after its literal leading spaces")
    func startsMention() {
        #expect(ZenMentionSuggestions.startsMention("@"))
        #expect(ZenMentionSuggestions.startsMention("@coordinator hello"))
        #expect(ZenMentionSuggestions.startsMention("  @all"))
        #expect(!ZenMentionSuggestions.startsMention(""))
        #expect(!ZenMentionSuggestions.startsMention("   "))
        #expect(!ZenMentionSuggestions.startsMention("hello @all"))
        #expect(!ZenMentionSuggestions.startsMention("/help"))
        #expect(!ZenMentionSuggestions.startsMention("\n@all"))
    }
}

@Suite("ZenMentionSuggestions roster refresh")
struct ZenMentionRefreshTests {
    private func refreshes(_ old: String, _ oldCursor: Int? = nil, to new: String, _ newCursor: Int? = nil) -> Bool {
        ZenMentionSuggestions.refreshesMentions(from: old, oldCursor: oldCursor, to: new, newCursor: newCursor)
    }

    @Test("typing the @ that starts a mention refreshes the roster")
    func typingTheAt() {
        #expect(refreshes("", to: "@"))
        #expect(refreshes("  ", to: "  @"))
        // Not a leading mention: nothing to refresh.
        #expect(!refreshes("hello ", to: "hello @"))
    }

    @Test("a cursor inside the token refreshes the roster when it comes from outside it")
    func cursorComesIntoTheToken() {
        // "@coord hi|" → "@co|ord hi": from the message into the token.
        #expect(refreshes("@coord hi", 9, to: "@coord hi", 3))
        // A pasted "@co|ord".
        #expect(refreshes("", to: "@coord", 3))
        // "@co|ord\n" → "@co|ord": the draft becomes a single line again.
        #expect(refreshes("@coord\n", 3, to: "@coord", 3))
        // Moving inside the token: it was completing already.
        #expect(!refreshes("@coord", 6, to: "@coord", 3))
        #expect(!refreshes("@co", to: "@coo"))
    }

    @Test("typing the message after a mention refreshes nothing")
    func typingTheMessage() {
        let typed = Array("@coordinator hi")
        let steps = (0..<typed.count).map { length in
            refreshes(String(typed.prefix(length)), to: String(typed.prefix(length + 1)))
        }
        // Only the @ that started the mention refreshed it.
        #expect(steps == [true] + Array(repeating: false, count: typed.count - 1))
        // Accepting a suggestion leaves the token: nothing to refresh.
        #expect(!refreshes("@co", to: "@coordinator ", 13))
    }

    @Test("moving the cursor back into the token refreshes the roster")
    func cursorMovesBack() {
        // "@coordinator hi|" → "@coord|inator hi".
        #expect(refreshes("@coordinator hi", 15, to: "@coordinator hi", 6))
        // "@coordinator hi|" → "@coordinator| hi": the end of the token.
        #expect(refreshes("@coordinator hi", 15, to: "@coordinator hi", 12))
        // "@coordinator |hi": still in the message.
        #expect(!refreshes("@coordinator hi", 15, to: "@coordinator hi", 13))
    }
}

@Suite("ZenMentionSuggestions acceptance")
struct ZenMentionAcceptanceTests {
    private func accept(
        _ handle: String,
        in draft: String,
        cursor: Int? = nil
    ) -> ZenCommandSuggestions.Acceptance? {
        guard let mention = catalogue.first(where: { $0.handle == handle }) else { return nil }
        return ZenMentionSuggestions.accept(mention, in: draft, cursor: cursor)
    }

    @Test("accepting replaces the token with '@handle ' and parks the cursor after the space")
    func replacesTheToken() {
        #expect(accept("coordinator", in: "@co") == .init(draft: "@coordinator ", cursor: 13, submits: false))
        #expect(accept("all", in: "@") == .init(draft: "@all ", cursor: 5, submits: false))
        #expect(accept("reviewer", in: "@r") == .init(draft: "@reviewer ", cursor: 10, submits: false))
    }

    @Test("accepting never submits")
    func neverSubmits() {
        for handle in catalogue.map(\.handle) {
            let acceptance = accept(handle, in: "@", cursor: 1)
            #expect(acceptance?.submits == false, "\(handle)")
        }
    }

    @Test("the whole token under the cursor is replaced and the rest of the line is kept")
    func keepsTheRestOfTheLine() {
        // "@co|ord": the typed prefix is "@co", the replacement covers "@coord".
        #expect(
            accept("coordinator", in: "@coord", cursor: 3)
                == .init(draft: "@coordinator ", cursor: 13, submits: false)
        )
        // Like the terminal editor, the suggestion's trailing space is added
        // even when a space already follows the token.
        #expect(
            accept("reviewer", in: "@r check this", cursor: 2)
                == .init(draft: "@reviewer  check this", cursor: 10, submits: false)
        )
        // Leading spaces stay.
        #expect(accept("all", in: "  @a", cursor: 4) == .init(draft: "  @all ", cursor: 7, submits: false))
    }

    @Test("nothing is accepted outside the leading token of a single-line draft")
    func nothingOutsideTheLeadingToken() {
        #expect(accept("all", in: "hello @a") == nil)
        #expect(accept("all", in: "@a\nmore") == nil)
        #expect(accept("all", in: "@all text", cursor: 9) == nil)
        #expect(accept("all", in: "/help") == nil)
        #expect(accept("all", in: "") == nil)
    }

    @Test("the accepted draft closes the list")
    func acceptedDraftClosesTheList() {
        let accepted = accept("coordinator", in: "@co")?.draft ?? ""
        #expect(accepted == "@coordinator ")
        #expect(ZenMentionSuggestions.matches(for: accepted, in: catalogue).isEmpty)
        // And a mention without text still starts one, so the owner refreshes.
        #expect(ZenMentionSuggestions.startsMention(accepted))
    }
}

@Suite("ZenMentionSuggestions summaries")
struct ZenMentionSummaryTests {
    @Test("the reserved mentions and the agents are worded like the terminal")
    func summaries() {
        #expect(
            ZenMentionSuggestions.summary(for: Mention(handle: "coordinator", target: .coordinator))
                == "message the live coordinator"
        )
        #expect(
            ZenMentionSuggestions.summary(for: Mention(handle: "all", target: .all))
                == "message the coordinator and all active agent instances"
        )
        #expect(
            ZenMentionSuggestions.summary(for: Mention(handle: "builder", target: .agent(name: "Builder")))
                == "message active agent: Builder"
        )
    }

    @Test("an agent's name is made inline-safe and stays on one line")
    func agentNameIsInlineSafe() {
        let multiline = ZenMentionSuggestions.summary(
            for: Mention(handle: "x", target: .agent(name: "Plan\nner \t of\nthings"))
        )
        #expect(multiline == "message active agent: Plan ner of things")
        #expect(!multiline.contains { $0.isNewline })

        // Terminal controls become inert visible text.
        let escape = ZenMentionSuggestions.summary(
            for: Mention(handle: "x", target: .agent(name: "bad\u{1B}[31mname"))
        )
        #expect(!escape.unicodeScalars.contains("\u{1B}"))
        #expect(escape.hasPrefix("message active agent: bad"))

        // A blank name reads "unnamed agent".
        #expect(
            ZenMentionSuggestions.summary(for: Mention(handle: "x", target: .agent(name: " \n ")))
                == "message active agent: unnamed agent"
        )
    }
}

@Suite("ZenSuggestionRow")
struct ZenSuggestionRowTests {
    private let commands: [ChatCommandDescriptor] = [
        ChatCommandDescriptor(command: "/help", summary: "show the commands", help: "/help"),
        ChatCommandDescriptor(command: "/save", summary: "save the session", help: "/save <name>", requiresArgument: true),
        ChatCommandDescriptor(command: "/tasks", summary: "inspect tasks", help: "/tasks"),
        // A command descriptor that starts like a mention is not a mention.
        ChatCommandDescriptor(command: "@coordinator", summary: "stale", help: "@coordinator")
    ]

    private func rows(_ draft: String, cursor: Int? = nil) -> [ZenSuggestionRow] {
        ZenSuggestionRow.rows(for: draft, cursor: cursor, commands: commands, mentions: catalogue)
    }

    @Test("mention rows show '@handle' and the summary")
    func mentionRowText() {
        let rows = rows("@")
        #expect(rows.map(\.title) == ["@coordinator", "@all", "@builder", "@builder-2", "@reviewer"])
        #expect(rows[0].summary == "message the live coordinator")
        #expect(rows[1].summary == "message the coordinator and all active agent instances")
        #expect(rows[2].summary == "message active agent: Builder")
        #expect(rows.allSatisfy { $0.isMention })
    }

    @Test("command rows show the command and its summary, unchanged")
    func commandRowText() {
        let rows = rows("/")
        #expect(rows.map(\.title) == ["/help", "/save", "/tasks"])
        #expect(rows.map(\.summary) == ["show the commands", "save the session", "inspect tasks"])
        #expect(rows.allSatisfy { !$0.isMention })
        // The rows are the descriptors of ZenCommandSuggestions.
        #expect(
            rows.map(\.source)
                == ZenCommandSuggestions.matches(for: "/", in: commands).map { .command($0) }
        )
    }

    @Test("slash commands and their arguments are unaffected by the mentions")
    func slashCommandsUnaffected() {
        #expect(rows("/s").map(\.title) == ["/save"])
        #expect(rows("/tasks re").map(\.title) == ["retry"])
        #expect(rows("/tasks re").allSatisfy { !$0.isMention })
        #expect(rows("/x").isEmpty)
        // With no mentions at all the command rows are the same.
        #expect(
            ZenSuggestionRow.rows(for: "/s", commands: commands, mentions: [])
                == ZenSuggestionRow.rows(for: "/s", commands: commands, mentions: catalogue)
        )
    }

    @Test("a command-style @ descriptor does not leak into the mention rows or the slash rows")
    func commandsDoNotProduceMentions() {
        // The mention rows come from the catalogue only.
        #expect(rows("@co").map(\.title) == ["@coordinator"])
        #expect(rows("@co").allSatisfy { $0.isMention })
        #expect(ZenSuggestionRow.rows(for: "@co", commands: commands, mentions: []).isEmpty)
        #expect(rows("/").map(\.title) == ["/help", "/save", "/tasks"])
    }

    @Test("a draft that is not a leading mention or a command offers nothing")
    func nothingElsewhere() {
        #expect(rows("").isEmpty)
        #expect(rows("hello").isEmpty)
        #expect(rows("hello @co").isEmpty)
        #expect(rows("@co\nsecond").isEmpty)
        #expect(rows("@coordinator hello", cursor: 18).isEmpty)
        #expect(rows("/save x").isEmpty)
    }

    @Test("Return and Tab on a mention only complete it")
    func mentionAcceptanceNeverSubmits() {
        let row = ZenSuggestionRow(mention: catalogue[0])
        let tab = row.accept(in: "@co", submitting: false)
        let enter = row.accept(in: "@co", submitting: true)
        #expect(tab == .init(draft: "@coordinator ", cursor: 13, submits: false))
        #expect(enter == tab)
        #expect(row.accept(in: "hello", submitting: true) == nil)
    }

    @Test("commands accept exactly as before")
    func commandAcceptanceUnchanged() {
        let help = ZenSuggestionRow(command: commands[0])
        #expect(help.accept(in: "/he", submitting: true) == .init(draft: "/help", cursor: 5, submits: true))
        #expect(help.accept(in: "/he", submitting: false) == .init(draft: "/help", cursor: 5, submits: false))
        let save = ZenSuggestionRow(command: commands[1])
        #expect(save.accept(in: "/sa", submitting: true) == .init(draft: "/save ", cursor: 6, submits: false))
        #expect(help.accept(in: "@co", submitting: true) == nil)
    }

    @Test("the navigator walks and wraps over mention rows")
    func navigatorOverRows() {
        let rows = rows("@")
        var navigator = ZenSuggestionNavigator()
        #expect(navigator.highlighted(in: rows)?.title == "@coordinator")
        navigator.move(by: 1, count: rows.count)
        #expect(navigator.highlighted(in: rows)?.title == "@all")
        navigator.move(by: -2, count: rows.count)
        #expect(navigator.highlighted(in: rows)?.title == "@reviewer")
        navigator.move(by: 1, count: rows.count)
        #expect(navigator.highlighted(in: rows)?.title == "@coordinator")
        // An edit restarts from the first mention; Esc hides until the next edit.
        navigator.move(by: 3, count: rows.count)
        navigator.draftChanged(to: "@b")
        #expect(navigator.highlightedIndex == 0)
        navigator.dismiss(draft: "@b")
        #expect(navigator.isDismissed(for: "@b"))
        navigator.draftChanged(to: "@bu")
        #expect(!navigator.isDismissed(for: "@bu"))
    }

    @Test("the composer actions default to a no-op mention refresh")
    @MainActor
    func actionsDefault() {
        var refreshed = 0
        let actions = ZenComposerActions(refreshMentions: { refreshed += 1 })
        actions.refreshMentions()
        #expect(refreshed == 1)
        ZenComposerActions().refreshMentions()
        #expect(refreshed == 1)
    }
}
