//
//  TerminalPromptEditorTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite
struct TerminalPromptEditorTests {
    private func makeEditor(
        _ text: String,
        cursorIndex: Int? = nil
    ) -> TerminalPromptEditor {
        var editor = TerminalPromptEditor()
        editor.buffer = Array(text)
        editor.cursorIndex = cursorIndex ?? editor.buffer.count
        return editor
    }

    private var commandCatalog: [TerminalCommandSuggestion] {
        [
            TerminalCommandSuggestion(command: "/tasks", summary: "inspect tasks"),
            TerminalCommandSuggestion(command: "/feature", summary: "manage features"),
            TerminalCommandSuggestion(command: "/featurex", summary: "another prefix match"),
            TerminalCommandSuggestion(command: "/plan", summary: "plan work", requiresArgument: true)
        ]
    }

    // MARK: - Line and buffer motion

    @Test
    func homeAndEndActOnTheLogicalLineWhileBufferShortcutsSpanTheDraft() {
        var editor = makeEditor("one\ntwo\nthree", cursorIndex: 5)
        let context = TerminalPromptEditorContext()

        #expect(editor.apply(.home, context: context) == .changed)
        #expect(editor.cursorIndex == 4)

        #expect(editor.apply(.end, context: context) == .changed)
        #expect(editor.cursorIndex == 7)

        #expect(editor.apply(.bufferStart, context: context) == .changed)
        #expect(editor.cursorIndex == 0)

        #expect(editor.apply(.bufferEnd, context: context) == .changed)
        #expect(editor.cursorIndex == 13)

        // Already parked at the target: nothing observable changes, so the
        // caller can skip the redraw.
        #expect(editor.apply(.bufferEnd, context: context) == .ignored)
    }

    @Test
    func verticalMotionKeepsThePreferredColumnAcrossShortLines() {
        var editor = makeEditor("abcdefgh\nxy\nlmnopqrs", cursorIndex: 6)
        let context = TerminalPromptEditorContext()

        // Down onto a short line clamps to its end …
        #expect(editor.apply(.down, context: context) == .changed)
        #expect(editor.cursorIndex == 11)
        #expect(editor.visualColumn(of: editor.cursorIndex) == 2)

        // … and continuing down restores the remembered column instead of
        // staying truncated.
        #expect(editor.apply(.down, context: context) == .changed)
        #expect(editor.visualColumn(of: editor.cursorIndex) == 6)

        // A horizontal intent forgets the column.
        #expect(editor.apply(.left, context: context) == .changed)
        #expect(editor.preferredVisualColumn == nil)
    }

    @Test
    func verticalMotionUsesTerminalColumnsForWideCombiningAndTabCharacters() {
        // `界` is two cells, `é` is one grapheme/one cell, and the tab advances
        // to the next eight-cell stop.  Moving through a short line must retain
        // that nine-cell preferred column for the final line.
        var editor = makeEditor("界e\u{301}\tX\nab\n界e\u{301}\tX", cursorIndex: 4)
        let context = TerminalPromptEditorContext()

        #expect(editor.visualColumn(of: editor.cursorIndex) == 9)
        #expect(editor.apply(.down, context: context) == .changed)
        #expect(editor.visualColumn(of: editor.cursorIndex) == 2)
        #expect(editor.apply(.down, context: context) == .changed)
        #expect(editor.visualColumn(of: editor.cursorIndex) == 9)
        #expect(editor.cursorIndex == editor.buffer.count)
    }

    @Test
    func verticalMotionFallsBackToHistoryAtTheBufferEdges() {
        var editor = makeEditor("one\ntwo", cursorIndex: 5)
        let context = TerminalPromptEditorContext(history: ["older", "newer"])

        // Second line: up stays inside the draft.
        #expect(editor.apply(.up, context: context) == .changed)
        #expect(editor.cursorIndex == 1)
        #expect(editor.historyIndex == nil)

        // Top line: up leaves the draft and enters the history.
        #expect(editor.apply(.up, context: context) == .changed)
        #expect(String(editor.buffer) == "newer")
        #expect(editor.historyIndex == 1)
        #expect(String(editor.draftBeforeHistory) == "one\ntwo")

        // While navigation is active the arrows keep walking the history.
        #expect(editor.apply(.up, context: context) == .changed)
        #expect(String(editor.buffer) == "older")

        #expect(editor.apply(.down, context: context) == .changed)
        #expect(String(editor.buffer) == "newer")

        // Leaving the newest entry restores the original draft.
        #expect(editor.apply(.down, context: context) == .changed)
        #expect(String(editor.buffer) == "one\ntwo")
        #expect(editor.historyIndex == nil)
    }

    @Test
    func downWithoutHistoryNavigationAtTheLastLineIsANoOp() {
        var editor = makeEditor("only line")
        let context = TerminalPromptEditorContext(history: ["older"])

        #expect(editor.apply(.down, context: context) == .ignored)
        #expect(String(editor.buffer) == "only line")
    }

    // MARK: - Word motion and deletion

    @Test
    func wordMotionGroupsLettersDigitsAndPunctuationSeparately() {
        var editor = makeEditor("let value = foo.bar(42)", cursorIndex: 0)
        let context = TerminalPromptEditorContext()

        _ = editor.apply(.wordRight, context: context)
        #expect(editor.cursorIndex == 3)
        _ = editor.apply(.wordRight, context: context)
        #expect(editor.cursorIndex == 9)
        _ = editor.apply(.wordRight, context: context)
        #expect(editor.cursorIndex == 11)

        editor.cursorIndex = editor.buffer.count
        _ = editor.apply(.wordLeft, context: context)
        #expect(String(editor.buffer[editor.cursorIndex...]) == ")")
    }

    @Test
    func wordDeletionRemovesOneGroupOnEitherSideOfTheCursor() {
        var editor = makeEditor("alpha beta gamma", cursorIndex: 10)
        let context = TerminalPromptEditorContext()

        #expect(editor.apply(.deleteWordBefore, context: context) == .changed)
        #expect(String(editor.buffer) == "alpha  gamma")

        editor = makeEditor("alpha beta gamma", cursorIndex: 5)
        #expect(editor.apply(.deleteWordAfter, context: context) == .changed)
        #expect(String(editor.buffer) == "alpha gamma")

        editor = makeEditor("", cursorIndex: 0)
        #expect(editor.apply(.deleteWordBefore, context: context) == .ignored)
        #expect(editor.apply(.deleteWordAfter, context: context) == .ignored)
    }

    @Test
    func clearDraftRemovesTheWholeBufferFromAnyCursorPosition() {
        var editor = makeEditor("alpha beta\ngamma", cursorIndex: 6)
        let context = TerminalPromptEditorContext()

        #expect(editor.apply(.clearDraft, context: context) == .changed)
        #expect(editor.buffer.isEmpty)
        #expect(editor.cursorIndex == 0)

        #expect(editor.apply(.clearDraft, context: context) == .ignored)
    }

    @Test
    func wordBoundariesTreatUnicodeLettersDigitsAndSymbolsConsistently() {
        var editor = makeEditor("café_東京 42—done", cursorIndex: 0)
        let context = TerminalPromptEditorContext()

        _ = editor.apply(.wordRight, context: context)
        #expect(String(editor.buffer[..<editor.cursorIndex]) == "café_東京")
        _ = editor.apply(.wordRight, context: context)
        #expect(String(editor.buffer[..<editor.cursorIndex]) == "café_東京 42")
        _ = editor.apply(.wordRight, context: context)
        #expect(String(editor.buffer[..<editor.cursorIndex]) == "café_東京 42—")
        _ = editor.apply(.wordRight, context: context)
        #expect(String(editor.buffer[..<editor.cursorIndex]) == "café_東京 42—done")

        editor = makeEditor("café_東京 42—done")
        #expect(editor.apply(.deleteWordBefore, context: context) == .changed)
        #expect(String(editor.buffer) == "café_東京 42—")
    }

    // MARK: - Reverse history search

    @Test
    func reverseSearchAcceptsTheMatchWithoutSubmittingIt() {
        var editor = makeEditor("draft")
        let context = TerminalPromptEditorContext(
            history: ["first prompt", "second prompt", "third"]
        )

        #expect(editor.apply(.reverseSearch, context: context) == .changed)
        #expect(editor.reverseSearch != nil)

        #expect(editor.apply(.character("prompt"), context: context) == .changed)
        #expect(editor.reverseSearch?.matchIndex == 1)
        #expect(String(editor.buffer) == "second prompt")

        // Ctrl+R again steps to the older match.
        #expect(editor.apply(.reverseSearch, context: context) == .changed)
        #expect(editor.reverseSearch?.matchIndex == 0)
        #expect(String(editor.buffer) == "first prompt")

        // …and the newer one comes back with the down arrow.
        #expect(editor.apply(.down, context: context) == .changed)
        #expect(editor.reverseSearch?.matchIndex == 1)
        #expect(String(editor.buffer) == "second prompt")

        #expect(editor.apply(.enter, context: context) == .changed)
        #expect(editor.reverseSearch == nil)
        #expect(String(editor.buffer) == "second prompt")
        #expect(editor.cursorIndex == editor.buffer.count)
    }

    @Test
    func reverseSearchCancelRestoresTheOriginalDraftAndCursor() {
        var editor = makeEditor("half typed draft", cursorIndex: 4)
        let context = TerminalPromptEditorContext(history: ["something else"])

        _ = editor.apply(.reverseSearch, context: context)
        _ = editor.apply(.character("some"), context: context)
        #expect(editor.reverseSearch?.matchIndex == 0)

        #expect(editor.apply(.cancel, context: context) == .changed)
        #expect(editor.reverseSearch == nil)
        #expect(String(editor.buffer) == "half typed draft")
        #expect(editor.cursorIndex == 4)
    }

    @Test
    func reverseSearchBackspaceNarrowsTheQueryAndKeepsSearching() {
        var editor = makeEditor("")
        let context = TerminalPromptEditorContext(history: ["alpha", "beta"])

        _ = editor.apply(.reverseSearch, context: context)
        _ = editor.apply(.character("bex"), context: context)
        #expect(editor.reverseSearch?.matchIndex == nil)

        #expect(editor.apply(.backspace, context: context) == .changed)
        #expect(String(editor.reverseSearch?.query ?? []) == "be")
        #expect(editor.reverseSearch?.matchIndex == 1)
    }

    @Test
    func reverseSearchIsSuppressedWhileAnOverlayOwnsThePrompt() {
        var editor = makeEditor("draft")
        let context = TerminalPromptEditorContext(
            history: ["alpha"],
            isOverlayActive: true
        )

        #expect(editor.apply(.reverseSearch, context: context) == .ignored)
        #expect(editor.reverseSearch == nil)
    }

    // MARK: - Completions

    @Test
    func slashPrefixIsMeasuredUpToTheCursorAndReplacesTheWholeToken() {
        let completion = TerminalPromptCompletion.completion(
            buffer: Array("/feature"),
            cursorIndex: 4
        )

        #expect(completion?.kind == .command)
        #expect(completion?.prefix == "/fea")
        #expect(completion?.replacementRange == 0..<8)

        var editor = makeEditor("/feature", cursorIndex: 4)
        let context = TerminalPromptEditorContext(suggestions: commandCatalog)

        #expect(editor.apply(.tab, context: context) == .changed)
        #expect(String(editor.buffer) == "/feature")
        #expect(editor.cursorIndex == 8)
    }

    @Test
    func completionReplacesOnlyTheCommandTokenAndKeepsTheRestOfTheLine() {
        var editor = makeEditor("/fea trailing text", cursorIndex: 4)
        let context = TerminalPromptEditorContext(suggestions: commandCatalog)

        #expect(editor.apply(.tab, context: context) == .changed)
        #expect(String(editor.buffer) == "/feature trailing text")
        #expect(editor.cursorIndex == 8)
    }

    @Test
    func enterSubmitsACompleteCommandButOnlySeparatesOneNeedingAnArgument() {
        var editor = makeEditor("/fea")
        let context = TerminalPromptEditorContext(suggestions: commandCatalog)

        #expect(editor.apply(.enter, context: context) == .submitted("/feature"))
        #expect(editor.buffer.isEmpty)

        editor = makeEditor("/pl")
        #expect(editor.apply(.enter, context: context) == .changed)
        #expect(String(editor.buffer) == "/plan ")
        #expect(editor.cursorIndex == 6)
    }

    @Test
    func enterSendsARequiredArgumentCommandWithoutChangingItsExistingOperand() {
        let suggestions = [
            TerminalCommandSuggestion(
                command: "/attach",
                summary: "attach files",
                requiresArgument: true
            )
        ]
        let context = TerminalPromptEditorContext(suggestions: suggestions)
        var editor = makeEditor("/attach photo.png", cursorIndex: 7)

        #expect(editor.apply(.enter, context: context) == .submitted("/attach photo.png"))
        #expect(editor.buffer.isEmpty)

        // The same rule holds for a required subcommand operand.
        editor = makeEditor("/tasks retry task-42", cursorIndex: 12)
        let taskContext = TerminalPromptEditorContext(
            suggestions: [TerminalCommandSuggestion(command: "/tasks", summary: "tasks")]
        )
        #expect(editor.apply(.enter, context: taskContext) == .submitted("/tasks retry task-42"))
    }

    @Test
    func argumentCompletionsCoverSubcommandsOfKnownCommandsOnly() {
        var editor = makeEditor("/tasks re")
        let context = TerminalPromptEditorContext(suggestions: commandCatalog)

        #expect(editor.visibleSuggestions(context: context).map(\.command) == ["retry"])
        #expect(editor.apply(.enter, context: context) == .changed)
        #expect(String(editor.buffer) == "/tasks retry ")

        editor = makeEditor("/tasks sta")
        #expect(editor.apply(.enter, context: context) == .submitted("/tasks status"))

        // A command that is not in the visible catalogue offers nothing, so a
        // hidden command cannot leak through its subcommands.
        editor = makeEditor("/telegram o")
        #expect(editor.visibleSuggestions(context: context).isEmpty)
    }

    @Test
    func argumentCompletionsStopAfterTheSubcommandSlot() {
        #expect(
            TerminalPromptCompletion.completion(
                buffer: Array("/tasks show abc"),
                cursorIndex: 15
            ) == nil
        )
        #expect(
            TerminalPromptCompletion.completion(
                buffer: Array("/tasks sh"),
                cursorIndex: 9
            )?.kind == .argument(command: "/tasks")
        )
    }

    @Test
    func completionUsesTheExactCaseAndLiteralSpaceGrammarOfTheDispatcher() {
        let context = TerminalPromptEditorContext(suggestions: commandCatalog)
        var editor = makeEditor("/TASKS re")
        #expect(editor.visibleSuggestions(context: context).isEmpty)

        editor = makeEditor("/tasks\tre", cursorIndex: 6)
        #expect(editor.visibleSuggestions(context: context).isEmpty)
        #expect(
            TerminalPromptCompletion.completion(
                buffer: Array("/tasks\tre"),
                cursorIndex: 6
            ) == nil
        )

        let attach = TerminalPromptCompletionCatalog.argumentSuggestions(for: "/attach")
        #expect(attach.first(where: { $0.command == "delete" })?.requiresArgument == true)
    }

    @Test
    func multiLineAndNonSlashDraftsNeverOfferCompletions() {
        var editor = makeEditor("/feature\nsecond line")
        let context = TerminalPromptEditorContext(suggestions: commandCatalog)
        #expect(editor.visibleSuggestions(context: context).isEmpty)

        editor = makeEditor("no slash here")
        #expect(editor.visibleSuggestions(context: context).isEmpty)
    }

    @Test
    func escapeDismissesTheMenuWithoutDestroyingTheDraftAndAnEditBringsItBack() {
        var editor = makeEditor("/fea")
        let context = TerminalPromptEditorContext(suggestions: commandCatalog)

        #expect(!editor.visibleSuggestions(context: context).isEmpty)
        #expect(editor.apply(.cancel, context: context) == .changed)
        #expect(String(editor.buffer) == "/fea")
        #expect(editor.visibleSuggestions(context: context).isEmpty)

        #expect(editor.apply(.character("t"), context: context) == .changed)
        #expect(
            editor.visibleSuggestions(context: context).map(\.command)
                == ["/feature", "/featurex"]
        )
    }

    @Test
    func suggestionSelectionIsReconciledWheneverTheMatchSetShrinks() {
        var editor = makeEditor("/f")
        let context = TerminalPromptEditorContext(suggestions: commandCatalog)

        #expect(editor.visibleSuggestions(context: context).count == 2)
        _ = editor.apply(.down, context: context)
        #expect(editor.suggestionIndex == 1)

        // Narrowing to a single match must not leave the selection dangling.
        _ = editor.apply(.character("eaturex"), context: context)
        #expect(editor.visibleSuggestions(context: context).map(\.command) == ["/featurex"])
        #expect(editor.suggestionIndex == 0)
    }

    @Test
    func editsAndCursorMovesResetSuggestionSelectionToTheFirstMatch() {
        let context = TerminalPromptEditorContext(
            suggestions: [TerminalCommandSuggestion(command: "/tasks", summary: "tasks")]
        )
        var editor = makeEditor("/tasks ")

        // `clear` is initially the last subcommand. Selecting it then editing
        // must not retain that numeric position into the newly ordered match
        // list.
        for _ in 0..<5 {
            _ = editor.apply(.down, context: context)
        }
        #expect(editor.suggestionIndex == 5)
        #expect(editor.visibleSuggestions(context: context)[editor.suggestionIndex].command == "clear")

        _ = editor.apply(.character("c"), context: context)
        #expect(editor.suggestionIndex == 0)
        #expect(editor.visibleSuggestions(context: context).first?.command == "cancel")

        _ = editor.apply(.backspace, context: context)
        #expect(editor.suggestionIndex == 0)
        #expect(editor.visibleSuggestions(context: context).first?.command == "status")

        // Moving through the token changes the completion context as well, so
        // it follows the same deterministic first-match policy.
        _ = editor.apply(.character("c"), context: context)
        editor.suggestionIndex = 1
        _ = editor.apply(.left, context: context)
        #expect(editor.suggestionIndex == 0)
    }

    @Test
    func featureArgumentCompletionsIncludeEveryParserActionThatNeedsAnID() {
        let arguments = TerminalPromptCompletionCatalog.argumentSuggestions(for: "/feature")
        let idActions = ["enable", "disable", "delete", "build", "validate"]

        for action in idActions {
            #expect(arguments.first(where: { $0.command == action })?.requiresArgument == true)
        }

        var editor = makeEditor("/feature en")
        let context = TerminalPromptEditorContext(suggestions: commandCatalog)
        #expect(editor.visibleSuggestions(context: context).map(\.command) == ["enable"])
        #expect(editor.apply(.enter, context: context) == .changed)
        #expect(String(editor.buffer) == "/feature enable ")
    }

    @Test
    func suggestionSelectionWrapsAroundTheMatchList() {
        var editor = makeEditor("/fea")
        let context = TerminalPromptEditorContext(suggestions: commandCatalog)

        _ = editor.apply(.up, context: context)
        #expect(editor.suggestionIndex == 1)
        _ = editor.apply(.down, context: context)
        #expect(editor.suggestionIndex == 0)
    }

    @Test
    func fallbackReaderContextHasNoMenuAndKeepsTheDraftOnEscape() {
        var editor = makeEditor("/fea")
        let context = TerminalPromptEditorContext(
            suggestions: commandCatalog,
            supportsCompletions: false,
            clearsDraftOnCancel: false
        )

        #expect(editor.visibleSuggestions(context: context).isEmpty)
        #expect(editor.apply(.tab, context: context) == .ignored)
        #expect(editor.apply(.cancel, context: context) == .ignored)
        #expect(String(editor.buffer) == "/fea")
        #expect(editor.apply(.enter, context: context) == .submitted("/fea"))
    }

    // MARK: - Cancellation and end of input

    @Test
    func escapeStopsGenerationWhileProcessingAndClearsTheDraftOtherwise() {
        var editor = makeEditor("queued text")
        let processing = TerminalPromptEditorContext(isProcessing: true)

        #expect(editor.apply(.cancel, context: processing) == .cancelRequested)
        #expect(String(editor.buffer) == "queued text")

        #expect(editor.apply(.cancel, context: TerminalPromptEditorContext()) == .changed)
        #expect(editor.buffer.isEmpty)
    }

    @Test
    func escapeStopsGenerationEvenWhenCommandSuggestionsAreVisible() {
        var editor = makeEditor("/fea")
        let context = TerminalPromptEditorContext(
            suggestions: commandCatalog,
            isProcessing: true
        )

        #expect(!editor.visibleSuggestions(context: context).isEmpty)
        #expect(editor.apply(.cancel, context: context) == .cancelRequested)
        #expect(String(editor.buffer) == "/fea")
        #expect(!editor.areSuggestionsDismissed)
    }

    @Test
    func endOfInputOnlyEndsTheSessionWhenTheDraftIsEmpty() {
        var editor = makeEditor("text")
        let context = TerminalPromptEditorContext()

        #expect(editor.apply(.endOfInput, context: context) == .ignored)

        editor = makeEditor("")
        #expect(editor.apply(.endOfInput, context: context) == .endOfInput)
    }
}
