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
    func sharedChatMentionCompletionIsLimitedToTheLeadingToken() {
        let participantID = "agent-1"
        let mention = "@\(TerminalChat.sharedChatMentionHandle(forParticipantID: participantID))"
        let suggestion = TerminalCommandSuggestion(
            command: "\(mention) ",
            summary: "message active agent"
        )

        #expect(
            TerminalPromptCompletion.matches(
                buffer: Array(mention),
                cursorIndex: mention.count,
                commands: [suggestion]
            ) == [suggestion]
        )

        // The router parses only an initial mention. A completion after prose
        // must therefore be absent instead of inserting an unrouteable handle.
        let proseBeforeMention = "Please ask \(mention)"
        #expect(
            TerminalPromptCompletion.completion(
                buffer: Array(proseBeforeMention),
                cursorIndex: proseBeforeMention.count
            ) == nil
        )
        #expect(
            TerminalPromptCompletion.matches(
                buffer: Array(proseBeforeMention),
                cursorIndex: proseBeforeMention.count,
                commands: [suggestion]
            ).isEmpty
        )
        #expect(
            TerminalChat.sharedChatMentionRoute(
                from: "Please ask \(mention) to review this"
            ) == nil
        )

        // Moving the cursor to a later mention in a leading-mention draft is
        // equally non-routable, even though the draft started with `@`.
        let laterMention = "\(mention) review this with \(mention)"
        #expect(
            TerminalPromptCompletion.completion(
                buffer: Array(laterMention),
                cursorIndex: laterMention.count
            ) == nil
        )
        #expect(
            TerminalPromptCompletion.matches(
                buffer: Array(laterMention),
                cursorIndex: laterMention.count,
                commands: [suggestion]
            ).isEmpty
        )
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

    @Test
    func sharedChatMessagesRenderInsideAWidthBoundedCard() {
        let card = TerminalChat.renderSharedChatCard(
            route: "@planner → coordinator",
            text: "  A long live message that must wrap cleanly. 中😀e\u{0301}\n\tSecond line.\u{1B}\u{7F}\u{85}\r",
            terminalColumns: 40,
            usesColor: false
        )
        let lines = card.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        #expect(lines.first?.hasPrefix("╭─ Shared chat · ") == true)
        #expect(lines.dropLast().allSatisfy {
            TerminalANSIText.visibleWidth($0) == 36
        })
        #expect(lines.dropLast().last == "╰──────────────────────────────────╯")
        #expect(lines.contains { $0.hasPrefix("│   A long") })
        #expect(card.contains("␛"))
        #expect(card.contains("␡"))
        #expect(card.contains("␍"))
        #expect(card.contains("<C1-85>"))
        #expect(!card.unicodeScalars.contains { scalar in
            scalar.value == 0x1B
                || scalar.value == 0x7F
                || scalar.value == 0x0D
                || (scalar.value < 0x20 && scalar.value != 0x0A)
                || (0x80...0x9F).contains(scalar.value)
        })
    }

    @Test
    func sharedChatCardFallsBackToPlainWidthBoundedRowsOnNarrowTerminals() {
        for columns in [1, 4, 11] {
            let card = TerminalChat.renderSharedChatCard(
                route: "中😀",
                text: "  indented\n中😀e\u{0301}",
                terminalColumns: columns,
                usesColor: true
            )
            let rows = card.split(separator: "\n", omittingEmptySubsequences: false)
                .dropLast()
                .map(String.init)

            #expect(!card.contains("╭"))
            #expect(!card.contains("\u{1B}"))
            #expect(rows.allSatisfy {
                TerminalANSIText.visibleWidth($0) <= max(1, columns)
            })
        }
    }

    @Test
    func sharedChatCardsAndRenderingDedupKeepOperatorIdentityLocalToEachObserver() {
        let human = AgentSharedChat.Participant(
            id: "operator:room-1",
            name: "operator",
            kind: .operator
        )
        let agentNamedOperator = AgentSharedChat.Participant(
            id: "agent-operator",
            name: "operator",
            kind: .agent
        )
        let humanRoute = TerminalChat.sharedChatIncomingCardRoute(for: human)
        let agentRoute = TerminalChat.sharedChatIncomingCardRoute(for: agentNamedOperator)

        #expect(humanRoute == "Operator (human, id: operator:room-1) → Coordinator")
        #expect(agentRoute == "Agent (id: agent-operator, name: operator) → Coordinator")
        #expect(humanRoute != agentRoute)
        #expect(TerminalChat.renderSharedChatCard(
            route: humanRoute,
            text: "human message",
            terminalColumns: 120,
            usesColor: false
        ).contains("Operator (human, id: operator:room-1)"))
        #expect(TerminalChat.renderSharedChatCard(
            route: agentRoute,
            text: "agent message",
            terminalColumns: 120,
            usesColor: false
        ).contains("Agent (id: agent-operator, name: operator)"))

        let operatorMessage = AgentSharedChat.Message(
            roomID: "room-1",
            sender: human,
            recipientIDs: [AgentSharedChat.coordinatorID(for: "room-1")],
            text: "do not hide operator messages"
        )
        var firstObserverIDs = TerminalChat.SharedChatRenderedMessageIDs()
        #expect(TerminalChat.newlyReceivedSharedChatMessages(
            [operatorMessage],
            renderedMessageIDs: &firstObserverIDs
        ) == [operatorMessage])
        #expect(TerminalChat.newlyReceivedSharedChatMessages(
            [operatorMessage],
            renderedMessageIDs: &firstObserverIDs
        ).isEmpty)

        // A second terminal has a separate rendering history and must see the
        // same message once; there is no process-wide deduplication.
        var secondObserverIDs = TerminalChat.SharedChatRenderedMessageIDs()
        #expect(TerminalChat.newlyReceivedSharedChatMessages(
            [operatorMessage],
            renderedMessageIDs: &secondObserverIDs
        ) == [operatorMessage])
    }

    /// The rendering history of a long live session stays bounded. Eviction is
    /// FIFO and its capacity mirrors the transcript bound, so an evicted id can
    /// no longer be replayed by the Core and cannot produce a duplicate card.
    @Test
    func sharedChatRenderingHistoryIsBoundedAndEvictsOldestFirst() {
        let sender = AgentSharedChat.Participant(
            id: "agent-1",
            name: "worker",
            kind: .agent
        )
        func message(_ text: String) -> AgentSharedChat.Message {
            AgentSharedChat.Message(
                roomID: "room-1",
                sender: sender,
                recipientIDs: ["coordinator:room-1"],
                text: text
            )
        }

        let capacity = TerminalChat.SharedChatRenderedMessageIDs.capacity
        #expect(capacity == AgentSharedChat.maximumRetainedMessagesPerRoom)

        var history = TerminalChat.SharedChatRenderedMessageIDs()
        let first = message("first")
        #expect(TerminalChat.newlyReceivedSharedChatMessages(
            [first],
            renderedMessageIDs: &history
        ) == [first])

        let overflow = (0 ..< capacity).map { message("later \($0)") }
        #expect(TerminalChat.newlyReceivedSharedChatMessages(
            overflow,
            renderedMessageIDs: &history
        ).count == capacity)
        #expect(history.count == capacity)

        // The newest ids are still deduplicated, while the oldest ones were
        // evicted first and would be rendered again if the Core replayed them.
        #expect(TerminalChat.newlyReceivedSharedChatMessages(
            [overflow[capacity - 1]],
            renderedMessageIDs: &history
        ).isEmpty)
        #expect(TerminalChat.newlyReceivedSharedChatMessages(
            [first],
            renderedMessageIDs: &history
        ) == [first])
        #expect(TerminalChat.newlyReceivedSharedChatMessages(
            [overflow[0]],
            renderedMessageIDs: &history
        ) == [overflow[0]])
        #expect(history.count == capacity)

        history.removeAll()
        #expect(history.count == 0)
        #expect(TerminalChat.newlyReceivedSharedChatMessages(
            [first],
            renderedMessageIDs: &history
        ) == [first])
    }

    @Test
    func sharedChatCardUsesAppearanceAwareBluePaletteAndResetsBoldAtTheBorder() {
        let dark = TerminalChat.renderSharedChatCard(
            route: "route",
            text: "body",
            terminalColumns: 40,
            usesColor: true,
            appearance: .dark
        )
        let light = TerminalChat.renderSharedChatCard(
            route: "route",
            text: "body",
            terminalColumns: 40,
            usesColor: true,
            appearance: .light
        )

        #expect(dark.contains(TerminalStyle.SharedChat.darkPalette.border))
        #expect(dark.contains(TerminalStyle.SharedChat.darkPalette.title))
        #expect(light.contains(TerminalStyle.SharedChat.lightPalette.border))
        #expect(light.contains(TerminalStyle.SharedChat.lightPalette.title))
        #expect(dark.contains("\u{1B}[1;38;5;81mShared chat"))
        // The second border sequence occurs immediately after the bold title
        // and starts with SGR 22, preventing bold from leaking to the rule.
        #expect(dark.contains("\u{1B}[22;38;5;75m ─"))
        #expect(dark.split(separator: "\n").allSatisfy {
            $0.hasSuffix(TerminalStyle.reset)
        })
    }

    @Test
    func activeAgentMentionHandlesAreUniqueSafeAndRouteExactlyByID() {
        let participants = [
            AgentSharedChat.Participant(id: "planner-1", name: "Planning Agent", kind: .agent),
            AgentSharedChat.Participant(id: "planner-2", name: "Planning Agent", kind: .agent),
            AgentSharedChat.Participant(id: "all", name: "all", kind: .agent),
            AgentSharedChat.Participant(id: "\u{1B}[31m odd", name: "review\r\u{7F}\u{85}", kind: .agent),
            AgentSharedChat.Participant(id: "inactive", name: "inactive", kind: .agent, isActive: false),
            AgentSharedChat.Participant(id: "coordinator", name: "coordinator", kind: .coordinator)
        ]
        let suggestions = TerminalChat.sharedChatMentionSuggestions(for: participants)
        let commands = suggestions.map(\.command)

        #expect(commands.count == 6)
        #expect(Set(commands).count == commands.count)
        #expect(commands.contains("@all "))
        #expect(commands.contains("@coordinator "))
        let directCommands = commands.filter { $0.hasPrefix("@agent-") }
        #expect(directCommands.count == 4)
        #expect(directCommands.allSatisfy { command in
            command.hasPrefix("@agent-")
                && command.hasSuffix(" ")
                && command.dropLast().unicodeScalars.allSatisfy { scalar in
                    (scalar.value >= 0x41 && scalar.value <= 0x5A)
                        || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                        || (scalar.value >= 0x30 && scalar.value <= 0x39)
                        || scalar == "@"
                        || scalar == "-"
                        || scalar == "_"
                }
        })
        #expect(suggestions.allSatisfy { suggestion in
            !suggestion.summary.unicodeScalars.contains { scalar in
                scalar.value == 0x1B
                    || scalar.value == 0x7F
                    || scalar.value == 0x0D
                    || scalar.value < 0x20
                    || (0x80...0x9F).contains(scalar.value)
            }
        })

        for participant in participants where participant.kind == .agent && participant.isActive {
            let handle = TerminalChat.sharedChatMentionHandle(forParticipantID: participant.id)
            // A trailing C1 NEL is Unicode whitespace, so it is trimmed off the
            // raw line before sanitisation; CR and ESC inside the text are still
            // replaced by inert control pictures.
            #expect(
                TerminalChat.sharedChatMentionRoute(
                    from: "@\(handle) inspect\r\u{1B}\u{85}"
                ) == TerminalChat.SharedChatMentionRoute(
                    destination: .direct([participant.id]),
                    text: "inspect␍␛"
                )
            )
            #expect(
                TerminalChat.sharedChatMentionRoute(
                    from: "@\(handle) inspect\u{85}tail"
                ) == TerminalChat.SharedChatMentionRoute(
                    destination: .direct([participant.id]),
                    text: "inspect<C1-85>tail"
                )
            )
        }
        #expect(TerminalChat.sharedChatMentionRoute(from: "@all report status")
            == TerminalChat.SharedChatMentionRoute(destination: .all, text: "report status"))
        #expect(TerminalChat.sharedChatMentionRoute(from: "@COORDINATOR report status")
            == TerminalChat.SharedChatMentionRoute(destination: .coordinator, text: "report status"))
        #expect(TerminalChat.sharedChatMentionRoute(from: "@Planning Agent ambiguous") == nil)
        #expect(TerminalChat.parseSharedChatMention(from: "@all")
            == .missingText(destination: .all))
        #expect(TerminalChat.parseSharedChatMention(from: "@coordinator   ")
            == .missingText(destination: .coordinator))
        let firstHandle = TerminalChat.sharedChatMentionHandle(forParticipantID: participants[0].id)
        #expect(TerminalChat.parseSharedChatMention(from: "@\(firstHandle)")
            == .missingText(destination: .direct([participants[0].id])))
        #expect(TerminalChat.parseSharedChatMention(from: "@not-a-live-mention") == .none)
    }

    @Test
    func activeAgentMentionsAutocompleteAndRouteFromTheLeadingToken() {
        let plannerHandle = TerminalChat.sharedChatMentionHandle(forParticipantID: "planner-id")
        let reviewerHandle = TerminalChat.sharedChatMentionHandle(forParticipantID: "reviewer-id")
        let suggestions = [
            TerminalCommandSuggestion(command: "/tasks", summary: "tasks"),
            TerminalCommandSuggestion(command: "@\(plannerHandle) ", summary: "message active agent"),
            TerminalCommandSuggestion(command: "@\(reviewerHandle) ", summary: "message active agent")
        ]
        var editor = makeEditor("@agent-cGxh")
        let context = TerminalPromptEditorContext(suggestions: suggestions)

        #expect(editor.visibleSuggestions(context: context).map(\.command) == ["@\(plannerHandle) "])
        #expect(editor.apply(.tab, context: context) == .changed)
        #expect(String(editor.buffer) == "@\(plannerHandle) ")
        #expect(
            TerminalChat.sharedChatMentionRoute(from: "@\(plannerHandle) inspect the diff")
                == TerminalChat.SharedChatMentionRoute(
                    destination: .direct(["planner-id"]),
                    text: "inspect the diff"
                )
        )
    }
}
