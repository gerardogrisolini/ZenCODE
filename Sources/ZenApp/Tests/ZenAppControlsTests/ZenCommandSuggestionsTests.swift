//
//  ZenCommandSuggestionsTests.swift
//  ZenApp
//
//  Slash-command matching and completion (mirroring the terminal editor),
//  the suggestion navigator and the composer's pure rules.
//

import Foundation
import SwiftUI
import Testing
import ZenCODECore

@testable import ZenAppControls

@Suite("ZenCommandSuggestions")
struct ZenCommandSuggestionsTests {
    private let commands: [ChatCommandDescriptor] = [
        ChatCommandDescriptor(command: "/help", summary: "help", help: "/help"),
        ChatCommandDescriptor(command: "/sessions", summary: "sessions", help: "/sessions"),
        ChatCommandDescriptor(command: "/skills", summary: "skills", help: "/skills"),
        ChatCommandDescriptor(command: "/save", summary: "save", help: "/save <name>", requiresArgument: true),
        ChatCommandDescriptor(command: "/session", summary: "alias", help: "/session"),
        ChatCommandDescriptor(command: "@coordinator", summary: "mention", help: "@coordinator")
    ]

    private func names(_ draft: String) -> [String] {
        ZenCommandSuggestions.matches(for: draft, in: commands).map(\.command)
    }

    @Test("prefix matches keep the display order")
    func prefixMatchesInDisplayOrder() {
        #expect(names("/s") == ["/sessions", "/skills", "/save", "/session"])
        #expect(names("/sk") == ["/skills"])
        #expect(names("/x").isEmpty)
    }

    @Test("an exact match comes first")
    func exactMatchFirst() {
        #expect(names("/session") == ["/session", "/sessions"])
        #expect(names("/help") == ["/help"])
    }

    @Test("a lone slash lists every slash command")
    func loneSlashListsAll() {
        #expect(names("/") == ["/help", "/sessions", "/skills", "/save", "/session"])
    }

    @Test("only a single slash token without whitespace is completed")
    func onlySingleSlashToken() {
        #expect(names("").isEmpty)
        #expect(names("help").isEmpty)
        #expect(names(" /help").isEmpty)
        #expect(names("/save ").isEmpty)
        #expect(names("/s x").isEmpty)
        #expect(names("/s\n").isEmpty)
        #expect(names("/s\t").isEmpty)
        #expect(names("@co").isEmpty)
    }

    @Test("completion adds a space to commands that need an argument")
    func completion() {
        #expect(ZenCommandSuggestions.completion(for: commands[0]) == "/help")
        #expect(ZenCommandSuggestions.completion(for: commands[3]) == "/save ")
        // Return sends a complete command, and only completes one that needs
        // an argument (TerminalPromptEditor.acceptSuggestion).
        #expect(ZenCommandSuggestions.submitsOnReturn(commands[0]))
        #expect(!ZenCommandSuggestions.submitsOnReturn(commands[3]))
        // The completed argument form no longer matches, so the list closes.
        #expect(names(ZenCommandSuggestions.completion(for: commands[3])).isEmpty)
    }
}

/// The completion rules of the terminal editor (`TerminalPromptEditorTests`),
/// for the shared commands the app offers.
@Suite("ZenCommandSuggestions arguments")
struct ZenCommandArgumentSuggestionsTests {
    /// The catalog of the terminal tests.
    private let commandCatalog: [ChatCommandDescriptor] = [
        ChatCommandDescriptor(command: "/tasks", summary: "inspect tasks", help: "/tasks"),
        ChatCommandDescriptor(command: "/feature", summary: "manage features", help: "/feature"),
        ChatCommandDescriptor(command: "/featurex", summary: "another prefix match", help: "/featurex"),
        ChatCommandDescriptor(command: "/plan", summary: "plan work", help: "/plan", requiresArgument: true)
    ]

    /// The shared commands, as the app offers them.
    private let shared = ChatCommandRegistry.sharedDescriptors

    private func names(_ draft: String, cursor: Int? = nil, in commands: [ChatCommandDescriptor]) -> [String] {
        ZenCommandSuggestions.matches(for: draft, cursor: cursor, in: commands).map(\.command)
    }

    /// Accepts the first suggestion, like Return (`submitting`) or Tab.
    private func acceptFirst(
        _ draft: String,
        cursor: Int? = nil,
        in commands: [ChatCommandDescriptor],
        submitting: Bool
    ) -> ZenCommandSuggestions.Acceptance? {
        guard let first = ZenCommandSuggestions.matches(for: draft, cursor: cursor, in: commands).first else {
            return nil
        }
        return ZenCommandSuggestions.accept(first, in: draft, cursor: cursor, submitting: submitting)
    }

    @Test("the prefix is measured up to the cursor and the whole token is replaced")
    func prefixUpToTheCursor() {
        let context = ZenCommandSuggestions.completionContext(in: Array("/feature"), cursor: 4)
        #expect(context?.kind == .command)
        #expect(context?.prefix == "/fea")
        #expect(context?.replacementRange == 0..<8)

        let tab = acceptFirst("/feature", cursor: 4, in: commandCatalog, submitting: false)
        #expect(tab == .init(draft: "/feature", cursor: 8, submits: false))
    }

    @Test("completion replaces only the command token and keeps the rest of the line")
    func keepsTheRestOfTheLine() {
        let tab = acceptFirst("/fea trailing text", cursor: 4, in: commandCatalog, submitting: false)
        #expect(tab == .init(draft: "/feature trailing text", cursor: 8, submits: false))
    }

    @Test("Return sends a complete command but only separates one needing an argument")
    func returnSendsOrSeparates() {
        #expect(acceptFirst("/fea", in: commandCatalog, submitting: true) == .init(draft: "/feature", cursor: 8, submits: true))
        #expect(acceptFirst("/pl", in: commandCatalog, submitting: true) == .init(draft: "/plan ", cursor: 6, submits: false))
    }

    @Test("Return sends a command that requires an argument when its operand is there")
    func existingOperandIsSent() {
        let attach = [ChatCommandDescriptor(command: "/attach", summary: "attach files", help: "/attach", requiresArgument: true)]
        #expect(
            acceptFirst("/attach photo.png", cursor: 7, in: attach, submitting: true)
                == .init(draft: "/attach photo.png", cursor: 7, submits: true)
        )
        // The same rule holds for a required subcommand operand.
        let tasks = [ChatCommandDescriptor(command: "/tasks", summary: "tasks", help: "/tasks")]
        #expect(
            acceptFirst("/tasks retry task-42", cursor: 12, in: tasks, submitting: true)
                == .init(draft: "/tasks retry task-42", cursor: 12, submits: true)
        )
    }

    @Test("arguments complete only for commands the operator can run")
    func argumentsOfKnownCommandsOnly() {
        #expect(names("/tasks re", in: commandCatalog) == ["retry"])
        #expect(acceptFirst("/tasks re", in: commandCatalog, submitting: true) == .init(draft: "/tasks retry ", cursor: 13, submits: false))
        #expect(acceptFirst("/tasks sta", in: commandCatalog, submitting: true) == .init(draft: "/tasks status", cursor: 13, submits: true))

        // A command missing from the visible list offers nothing, so a hidden
        // command cannot leak through its arguments.
        #expect(names("/skills a", in: commandCatalog).isEmpty)
        #expect(names("/skills a", in: shared) == ["all", "add"])
    }

    @Test("arguments stop after the first slot")
    func onlyTheFirstSlot() {
        #expect(ZenCommandSuggestions.completionContext(in: Array("/tasks show abc"), cursor: 15) == nil)
        #expect(ZenCommandSuggestions.completionContext(in: Array("/tasks sh"), cursor: 9)?.kind == .argument(command: "/tasks"))
    }

    @Test("completion uses the exact case and the literal-space grammar of the dispatcher")
    func exactCaseAndLiteralSpaces() {
        #expect(names("/TASKS re", in: commandCatalog).isEmpty)
        #expect(names("/tasks\tre", cursor: 6, in: commandCatalog).isEmpty)
        #expect(ZenCommandSuggestions.completionContext(in: Array("/tasks\tre"), cursor: 6) == nil)

        let attach = ZenCommandSuggestions.argumentSuggestions(for: "/attach")
        #expect(attach.map(\.command) == ["list", "delete"])
        #expect(attach.first(where: { $0.command == "delete" })?.requiresArgument == true)
    }

    @Test("multi-line and non-slash drafts never offer completions")
    func multiLineAndProse() {
        #expect(names("/feature\nsecond line", in: commandCatalog).isEmpty)
        #expect(names("no slash here", in: commandCatalog).isEmpty)
        #expect(names("/tasks re\n", in: commandCatalog).isEmpty)
    }

    @Test("task and changes arguments include the parser aliases")
    func tasksAndChanges() {
        let tasks = ZenCommandSuggestions.argumentSuggestions(for: "/tasks")
        #expect(tasks.map(\.command) == ["status", "list", "ls", "show", "get", "retry", "cancel", "clear"])
        #expect(tasks.first(where: { $0.command == "get" })?.requiresArgument == true)
        #expect(ZenCommandSuggestions.argumentSuggestions(for: "/changes").map(\.command) == ["diff", "--diff"])
    }

    @Test("agent and tool arguments; the terminal's log viewer is not offered")
    func agentsAndTools() {
        #expect(ZenCommandSuggestions.argumentSuggestions(for: "/agents").map(\.command) == ["list", "ls", "status"])
        #expect(
            ZenCommandSuggestions.argumentSuggestions(for: "/tools").map(\.command)
                == ["all", "none", "off", "clear", "disabled"]
        )
        #expect(names("/tools lo", in: shared).isEmpty)
    }

    @Test("skill arguments list and select every static parameter")
    func skills() {
        let arguments = ZenCommandSuggestions.argumentSuggestions(for: "/skills")
        #expect(arguments.map(\.command) == ["all", "none", "add", "install", "uninstall"])
        #expect(arguments.first(where: { $0.command == "add" })?.requiresArgument == true)
        #expect(arguments.first(where: { $0.command == "install" })?.requiresArgument == true)
        #expect(arguments.first(where: { $0.command == "uninstall" })?.requiresArgument == false)

        let skills = [ChatCommandDescriptor(command: "/skills", summary: "manage skills", help: "/skills")]
        #expect(names("/skills un", in: skills) == ["uninstall"])
        #expect(acceptFirst("/skills un", in: skills, submitting: true) == .init(draft: "/skills uninstall", cursor: 17, submits: true))
    }

    @Test("session and plan arguments; the checkpoint tree commands are not offered")
    func sessionsAndPlan() {
        #expect(
            ZenCommandSuggestions.argumentSuggestions(for: "/sessions").map(\.command)
                == ["save", "new", "compact", "delete", "restore"]
        )
        #expect(names("/sessions t", in: shared).isEmpty)
        #expect(names("/sessions b", in: shared).isEmpty)
        #expect(names("/sessions c", in: shared) == ["compact"])
        let plan = ZenCommandSuggestions.argumentSuggestions(for: "/plan")
        #expect(plan.map(\.command) == ["save", "load", "list", "delete", "status", "approve", "clear"])
        #expect(plan.first(where: { $0.command == "delete" })?.requiresArgument == true)
    }

    @Test("other commands keep their first slot and offer nothing beyond it")
    func nothingBeyondTheFirstSlot() {
        #expect(names("/sessions ", in: shared) == ZenCommandSuggestions.argumentSuggestions(for: "/sessions").map(\.command))
        #expect(names("/tasks sh", in: shared) == ["show"])
        for text in ["/sessions save x ", "/sessions save x", "/tasks list x", "/tasks show ", "/tasks show abc"] {
            #expect(names(text, in: shared).isEmpty, "\(text)")
            #expect(acceptFirst(text, in: shared, submitting: false) == nil, "\(text)")
        }
    }

    @Test("the catalog covers shared commands only, and every argument names its line")
    func catalogShape() {
        let sharedCommands = Set(shared.map(\.command))
        for (command, arguments) in ZenCommandSuggestions.argumentsByCommand {
            #expect(sharedCommands.contains(command), "\(command)")
            for argument in arguments {
                #expect(argument.help == "\(command) \(argument.command)")
                #expect(!argument.command.contains(" "))
            }
        }
        #expect(
            Set(ZenCommandSuggestions.argumentsByCommand.keys)
                == ["/sessions", "/tasks", "/plan", "/agents", "/tools", "/attach", "/changes", "/skills"]
        )
    }

    @Test("Tab on an argument that needs an operand leaves a space for it")
    func tabLeavesASpace() {
        #expect(acceptFirst("/plan del", in: shared, submitting: false) == .init(draft: "/plan delete ", cursor: 13, submits: false))
        // An operand already there is kept: no space is added.
        #expect(
            acceptFirst("/plan del x", cursor: 9, in: shared, submitting: false)
                == .init(draft: "/plan delete x", cursor: 12, submits: false)
        )
    }
}

@Suite("ZenSuggestionNavigator")
struct ZenSuggestionNavigatorTests {
    private let matches = [
        ChatCommandDescriptor(command: "/a", summary: "", help: ""),
        ChatCommandDescriptor(command: "/b", summary: "", help: ""),
        ChatCommandDescriptor(command: "/c", summary: "", help: "")
    ]

    @Test("the highlight wraps around like the terminal")
    func highlightWraps() {
        var navigator = ZenSuggestionNavigator()
        #expect(navigator.highlighted(in: matches)?.command == "/a")
        navigator.move(by: -1, count: 3)
        #expect(navigator.highlighted(in: matches)?.command == "/c")
        navigator.move(by: 1, count: 3)
        #expect(navigator.highlighted(in: matches)?.command == "/a")
        navigator.move(by: 1, count: 3)
        navigator.move(by: 1, count: 3)
        #expect(navigator.highlightedIndex == 2)
        navigator.move(by: 1, count: 0)
        #expect(navigator.highlightedIndex == 0)
        #expect(navigator.highlighted(in: []) == nil)
    }

    @Test("an edit restarts from the first suggestion")
    func editRestartsHighlight() {
        var navigator = ZenSuggestionNavigator()
        navigator.move(by: 2, count: 3)
        navigator.draftChanged(to: "/s")
        #expect(navigator.highlightedIndex == 0)
    }

    @Test("the highlight is clamped to a shorter list")
    func highlightClamped() {
        var navigator = ZenSuggestionNavigator()
        navigator.move(by: 2, count: 3)
        #expect(navigator.boundedIndex(count: 2) == 1)
        #expect(navigator.highlighted(in: Array(matches.prefix(1)))?.command == "/a")
    }

    @Test("a cursor move restarts from the first suggestion and keeps the list dismissed")
    func cursorMoveRestartsHighlight() {
        var navigator = ZenSuggestionNavigator()
        navigator.move(by: 2, count: 3)
        navigator.dismiss(draft: "/tasks s")
        navigator.cursorMoved()
        #expect(navigator.highlightedIndex == 0)
        #expect(navigator.isDismissed(for: "/tasks s"))
    }

    @Test("an edit restarts the argument list from its first suggestion")
    func editsRestartTheArgumentList() {
        let tasks = [ChatCommandDescriptor(command: "/tasks", summary: "tasks", help: "/tasks")]
        var navigator = ZenSuggestionNavigator()
        var matches = ZenCommandSuggestions.matches(for: "/tasks ", in: tasks)
        navigator.move(by: 7, count: matches.count)
        #expect(navigator.highlighted(in: matches)?.command == "clear")

        navigator.draftChanged(to: "/tasks c")
        matches = ZenCommandSuggestions.matches(for: "/tasks c", in: tasks)
        #expect(navigator.highlighted(in: matches)?.command == "cancel")

        navigator.draftChanged(to: "/tasks ")
        matches = ZenCommandSuggestions.matches(for: "/tasks ", in: tasks)
        #expect(navigator.highlighted(in: matches)?.command == "status")
    }

    @Test("Esc hides the list until the draft changes")
    func escapeDismissesUntilEdit() {
        var navigator = ZenSuggestionNavigator()
        navigator.dismiss(draft: "/s")
        #expect(navigator.isDismissed(for: "/s"))
        navigator.draftChanged(to: "/s")
        #expect(navigator.isDismissed(for: "/s"))
        navigator.draftChanged(to: "/se")
        #expect(!navigator.isDismissed(for: "/se"))
        #expect(!navigator.isDismissed(for: "/s"))
    }
}

@Suite("ZenComposerLogic")
struct ZenComposerLogicTests {
    @Test("Send when idle, Stop while busy, both with a draft to queue")
    func buttonVisibility() {
        #expect(ZenComposerLogic.buttons(isBusy: false, draft: "") == .init(showsSend: true, showsStop: false))
        #expect(ZenComposerLogic.buttons(isBusy: false, draft: "hi") == .init(showsSend: true, showsStop: false))
        #expect(ZenComposerLogic.buttons(isBusy: true, draft: "") == .init(showsSend: false, showsStop: true))
        #expect(ZenComposerLogic.buttons(isBusy: true, draft: " \n") == .init(showsSend: false, showsStop: true))
        #expect(ZenComposerLogic.buttons(isBusy: true, draft: "next") == .init(showsSend: true, showsStop: true))
    }

    @Test("a blank draft cannot be sent")
    func canSend() {
        #expect(!ZenComposerLogic.canSend(draft: ""))
        #expect(!ZenComposerLogic.canSend(draft: "  \n\t"))
        #expect(ZenComposerLogic.canSend(draft: " x "))
    }

    @Test("only file URLs are dropped")
    func droppedFiles() {
        let file = URL(filePath: "/tmp/image.png")
        let web = URL(string: "https://example.com/a.png")!
        #expect(ZenComposerLogic.droppedFiles([file, web]) == [file])
    }

    @Test("a queued chip shows the prompt on one line")
    func chipText() {
        #expect(ZenComposerLogic.chipText("first line\n  second\n\nthird ") == "first line second third")
    }

    @Test("history keys need the cursor on the first or last line")
    func boundaryLines() {
        let text = "one\ntwo\nthree"
        let start = text.startIndex
        let inSecond = text.index(start, offsetBy: 5)
        let inThird = text.index(start, offsetBy: 10)

        #expect(ZenComposerLogic.cursorIsOnBoundaryLine(text, selection: start..<start, movingUp: true))
        #expect(!ZenComposerLogic.cursorIsOnBoundaryLine(text, selection: start..<start, movingUp: false))
        #expect(!ZenComposerLogic.cursorIsOnBoundaryLine(text, selection: inSecond..<inSecond, movingUp: true))
        #expect(!ZenComposerLogic.cursorIsOnBoundaryLine(text, selection: inSecond..<inSecond, movingUp: false))
        #expect(ZenComposerLogic.cursorIsOnBoundaryLine(text, selection: inThird..<inThird, movingUp: false))
        // Without a selection the cursor is at the end.
        #expect(ZenComposerLogic.cursorIsOnBoundaryLine(text, selection: nil, movingUp: false))
        #expect(!ZenComposerLogic.cursorIsOnBoundaryLine(text, selection: nil, movingUp: true))
        #expect(ZenComposerLogic.cursorIsOnBoundaryLine("single", selection: nil, movingUp: true))
        #expect(ZenComposerLogic.cursorIsOnBoundaryLine("", selection: nil, movingUp: false))
    }

    @Test("Shift/Option+Return inserts a newline at the cursor")
    func insertingNewline() {
        let text = "hello world"
        let cursor = text.index(text.startIndex, offsetBy: 5)
        let edit = ZenComposerLogic.insertingNewline(into: text, replacing: cursor..<cursor)
        #expect(edit.text == "hello\n world")
        #expect(edit.text.distance(from: edit.text.startIndex, to: edit.cursor) == 6)

        let selected = ZenComposerLogic.insertingNewline(
            into: text,
            replacing: cursor..<text.index(cursor, offsetBy: 6)
        )
        #expect(selected.text == "hello\n")
        #expect(selected.cursor == selected.text.endIndex)

        let atEnd = ZenComposerLogic.insertingNewline(into: "abc", replacing: nil)
        #expect(atEnd.text == "abc\n")
        #expect(atEnd.cursor == atEnd.text.endIndex)
    }

    @Test("Return: newline with Shift/Option, then the input method, then the suggestion, then send")
    func returnAction() {
        func action(_ modifiers: EventModifiers, suggestion: Bool = false, marked: Bool = false) -> ZenComposerLogic.ReturnAction {
            ZenComposerLogic.returnAction(modifiers: modifiers, hasSuggestion: suggestion, hasMarkedText: marked)
        }
        #expect(action([]) == .submit)
        #expect(action(.shift) == .insertNewline)
        #expect(action(.option) == .insertNewline)
        #expect(action(.shift, marked: true) == .insertNewline)
        #expect(action([], suggestion: true) == .acceptSuggestion)
        // While an input method composes, Return commits the composition,
        // even over a highlighted suggestion.
        #expect(action([], suggestion: true, marked: true) == .passThrough)
        // A plain Return while an input method composes commits the
        // composition instead of sending the draft.
        #expect(action([], marked: true) == .passThrough)
    }

    @Test("the cursor is the insertion point inside the draft, the end otherwise")
    func cursorOffset() {
        let text = "/tasks re"
        let middle = text.index(text.startIndex, offsetBy: 3)
        #expect(ZenComposerLogic.cursorOffset(in: text, selection: middle..<middle) == 3)
        #expect(ZenComposerLogic.cursorOffset(in: text, selection: text.endIndex..<text.endIndex) == 9)
        #expect(ZenComposerLogic.cursorOffset(in: text, selection: text.startIndex..<middle) == nil)
        #expect(ZenComposerLogic.cursorOffset(in: text, selection: nil) == nil)
        // A selection left over from a longer draft is ignored.
        let longer = "/tasks retry task-42"
        let stale = longer.index(longer.startIndex, offsetBy: 15)
        #expect(ZenComposerLogic.cursorOffset(in: text, selection: stale..<stale) == nil)
    }

    @Test("queued items are identified values")
    func queuedItem() {
        let id = UUID()
        let item = ZenComposerQueuedItem(id: id, text: "x")
        #expect(item == ZenComposerQueuedItem(id: id, text: "x"))
        #expect(item != ZenComposerQueuedItem(text: "x"))
    }
}
