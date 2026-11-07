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

    // MARK: - History recall

    @Test(arguments: ["/tasks", "/plan", "/fea", "/feature l", "/plan inspect this", "first\nsecond"], [true, false])
    func enterSubmitsRecalledInputWithoutAcceptingCompletion(line: String, supportsCompletions: Bool) {
        var editor = TerminalPromptEditor()
        let context = TerminalPromptEditorContext(
            history: [line],
            suggestions: commandCatalog,
            supportsCompletions: supportsCompletions
        )

        #expect(editor.apply(.up, context: context) == .changed)
        #expect(editor.visibleSuggestions(context: context).isEmpty)
        #expect(editor.apply(.enter, context: context) == .submitted(line))
        #expect(editor.buffer.isEmpty)
        #expect(editor.historyIndex == nil)
        #expect(editor.draftBeforeHistory.isEmpty)
    }

    @Test
    func editingRecalledSlashCommandRestoresOrdinaryCompletionNavigation() {
        var editor = TerminalPromptEditor()
        let context = TerminalPromptEditorContext(
            history: ["older", "/featurex"],
            suggestions: commandCatalog
        )

        _ = editor.apply(.up, context: context)
        #expect(editor.apply(.backspace, context: context) == .changed)
        #expect(editor.historyIndex == nil)
        #expect(String(editor.buffer) == "/feature")
        #expect(editor.visibleSuggestions(context: context).map(\.command) == ["/feature", "/featurex"])

        #expect(editor.apply(.down, context: context) == .changed)
        #expect(editor.suggestionIndex == 1)
        #expect(String(editor.buffer) == "/feature")
        #expect(editor.apply(.enter, context: context) == .submitted("/featurex"))
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
    func editsAndCursorMovesResetSuggestionSelectionToTheFirstMatch() {
        let context = TerminalPromptEditorContext(
            suggestions: [TerminalCommandSuggestion(command: "/tasks", summary: "tasks")]
        )
        var editor = makeEditor("/tasks ")

        // `clear` is initially the last subcommand. Selecting it then editing
        // must not retain that numeric position into the newly ordered match
        // list.
        for _ in 0..<7 {
            _ = editor.apply(.down, context: context)
        }
        #expect(editor.suggestionIndex == 7)
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
    func skillArgumentCompletionsListAndSelectEveryStaticParameter() {
        let arguments = TerminalPromptCompletionCatalog.argumentSuggestions(for: "/skills")
        #expect(arguments.map(\.command) == ["all", "none", "add", "install", "uninstall"])
        #expect(arguments.first(where: { $0.command == "add" })?.requiresArgument == true)
        #expect(arguments.first(where: { $0.command == "install" })?.requiresArgument == true)
        #expect(arguments.first(where: { $0.command == "uninstall" })?.requiresArgument == false)

        let context = TerminalPromptEditorContext(
            suggestions: [TerminalCommandSuggestion(command: "/skills", summary: "manage skills")]
        )
        var editor = makeEditor("/skills un")
        #expect(editor.visibleSuggestions(context: context).map(\.command) == ["uninstall"])
        #expect(editor.apply(.enter, context: context) == .submitted("/skills uninstall"))
    }

    // MARK: - Completion after the subcommand and guide rows

    private var cronContext: TerminalPromptEditorContext {
        TerminalPromptEditorContext(suggestions: [
            TerminalCommandSuggestion(command: "/cron", summary: "schedule prompts"),
            TerminalCommandSuggestion(command: "/sessions", summary: "manage sessions"),
            TerminalCommandSuggestion(command: "/tasks", summary: "inspect tasks")
        ])
    }

    @Test
    func tabOnAScheduleAliasInsertsItAndLeavesASpaceForThePrompt() {
        var editor = makeEditor("/cron add ")

        #expect(editor.visibleSuggestions(context: cronContext).first?.command == "@hourly")
        #expect(editor.apply(.tab, context: cronContext) == .changed)
        #expect(String(editor.buffer) == "/cron add @hourly ")
        #expect(editor.cursorIndex == editor.buffer.count)
        // The prompt slot now explains itself; `-f` is its only alternative.
        #expect(editor.visibleSuggestions(context: cronContext).map(\.command) == ["<prompt>", "-f"])
    }

    @Test
    func enterOnAScheduleAliasCompletesItButNeverSendsAnIncompleteLine() {
        var editor = makeEditor("/cron add @d")

        #expect(editor.apply(.enter, context: cronContext) == .changed)
        #expect(String(editor.buffer) == "/cron add @daily ")
        #expect(editor.cursorIndex == editor.buffer.count)
    }

    @Test(arguments: [
        "/cron add 0",
        "/cron add 0 9 ",
        "/cron add @daily ",
        "/cron add @daily Summarize",
        "/cron add 0 9 * * 1-5 Summ",
        "/cron remove ",
        "/cron run 3",
        "/cron mailto "
    ])
    func tabOnAGuideChangesNothing(text: String) {
        var editor = makeEditor(text)
        let selected = editor.visibleSuggestions(context: cronContext)[editor.suggestionIndex]
        #expect(selected.isHint)

        #expect(editor.apply(.tab, context: cronContext) == .ignored)
        #expect(String(editor.buffer) == text)
        #expect(editor.cursorIndex == editor.buffer.count)
        #expect(editor.suggestionIndex == 0)
    }

    @Test(arguments: [
        "/cron mailto ",
        "/cron add 0",
        "/cron add @daily Summarize open PRs",
        "/cron add 0 9 * * 1-5 Summarize open PRs",
        "/cron remove ",
        "/cron remove 2"
    ])
    func enterOnAGuideSendsTheLineExactlyAsTyped(text: String) {
        var editor = makeEditor(text)

        #expect(editor.apply(.enter, context: cronContext) == .submitted(text))
        #expect(editor.buffer.isEmpty)
        #expect(editor.cursorIndex == 0)
    }

    @Test
    func arrowsCycleThroughTheMailToGuideAndItsValues() {
        let text = "/cron mailto "

        // The guide is selected first, so Enter cannot pick `none` by accident.
        var editor = makeEditor(text)
        #expect(editor.suggestionIndex == 0)

        _ = editor.apply(.down, context: cronContext)
        #expect(editor.apply(.enter, context: cronContext) == .submitted("/cron mailto none"))

        editor = makeEditor(text)
        _ = editor.apply(.up, context: cronContext)
        #expect(editor.visibleSuggestions(context: cronContext)[editor.suggestionIndex].command == "default")
        #expect(editor.apply(.enter, context: cronContext) == .submitted("/cron mailto default"))

        // Wrapping past the last value comes back to the guide.
        editor = makeEditor(text)
        for _ in 0..<3 {
            _ = editor.apply(.down, context: cronContext)
        }
        #expect(editor.suggestionIndex == 0)
        #expect(editor.apply(.enter, context: cronContext) == .submitted(text))
    }

    @Test
    func otherCommandsKeepTheirFirstSlotAndOfferNothingBeyondIt() {
        var editor = makeEditor("/sessions ")
        #expect(
            editor.visibleSuggestions(context: cronContext)
                == TerminalPromptCompletionCatalog.argumentSuggestions(for: "/sessions")
        )
        editor = makeEditor("/tasks sh")
        #expect(editor.visibleSuggestions(context: cronContext).map(\.command) == ["show"])

        for text in ["/sessions save x ", "/sessions save x", "/tasks list x", "/tasks show ", "/tasks show abc"] {
            editor = makeEditor(text)
            #expect(editor.visibleSuggestions(context: cronContext).isEmpty, "\(text)")
            #expect(editor.apply(.tab, context: cronContext) == .ignored, "\(text)")
            #expect(String(editor.buffer) == text)
            #expect(editor.apply(.enter, context: cronContext) == .submitted(text), "\(text)")
        }
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
    func endOfInputOnlyEndsTheSessionWhenTheDraftIsEmpty() {
        var editor = makeEditor("text")
        let context = TerminalPromptEditorContext()

        #expect(editor.apply(.endOfInput, context: context) == .ignored)

        editor = makeEditor("")
        #expect(editor.apply(.endOfInput, context: context) == .endOfInput)
    }

    @Test
    func activeAgentMentionHandlesAreUniqueSafeReadableAndRouteByID() async {
        let catalog = SharedChatMentionCatalog()
        let participants = [
            AgentSharedChat.Participant(id: "planner-1", name: "Planning Agent", kind: .agent),
            AgentSharedChat.Participant(id: "planner-2", name: "Planning Agent", kind: .agent),
            AgentSharedChat.Participant(id: "reviewer", name: "Code Reviewer", kind: .agent),
            AgentSharedChat.Participant(id: "\u{1B}[31m odd", name: "review\r\u{7F}\u{85}", kind: .agent),
            AgentSharedChat.Participant(id: "inactive", name: "inactive", kind: .agent, isActive: false),
            AgentSharedChat.Participant(id: "coordinator", name: "coordinator", kind: .coordinator)
        ]
        let handleMap = await catalog.handleMap(for: participants)
        let suggestions = TerminalChat.sharedChatMentionSuggestions(
            for: participants,
            handleMap: handleMap
        )
        let commands = suggestions.map(\.command)

        // Reserved (@all, @coordinator) + 4 active agents.
        #expect(commands.count == 6)
        #expect(Set(commands).count == commands.count)
        #expect(commands.contains("@all "))
        #expect(commands.contains("@coordinator "))
        // Readable handles are derived from the display name, not opaque Base64.
        #expect(commands.contains("@planning-agent "))
        #expect(commands.contains("@planning-agent-2 "))
        #expect(commands.contains("@code-reviewer "))
        // Sanitised: control/escape characters dropped, leaving a clean slug.
        let oddHandle = handleMap.first(where: { $0.value == "\u{1B}[31m odd" })?.key
        #expect(oddHandle == "review")
        #expect(commands.contains("@review "))
        // Every suggestion is terminal-safe: no ESC, DEL, CR or control bytes.
        #expect(suggestions.allSatisfy { suggestion in
            !suggestion.command.unicodeScalars.contains { scalar in
                scalar.value == 0x1B
                    || scalar.value == 0x7F
                    || scalar.value < 0x20
                    || (0x80...0x9F).contains(scalar.value)
            }
            && !suggestion.summary.unicodeScalars.contains { scalar in
                scalar.value == 0x1B
                    || scalar.value == 0x7F
                    || scalar.value == 0x0D
                    || scalar.value < 0x20
                    || (0x80...0x9F).contains(scalar.value)
            }
        })

        // Routing is always by stable id behind the readable handle.
        for participant in participants where participant.kind == .agent && participant.isActive {
            let handle = handleMap.first(where: { $0.value == participant.id })?.key
            let resolved = handle.flatMap { handleMap[$0] }
            #expect(resolved == participant.id)
            #expect(
                TerminalChat.sharedChatMentionRoute(
                    from: "@\(handle ?? "x") inspect the work",
                    readableHandles: handleMap
                ) == TerminalChat.SharedChatMentionRoute(
                    destination: .direct([participant.id]),
                    text: "inspect the work"
                )
            )
        }
        #expect(TerminalChat.sharedChatMentionRoute(
            from: "@all report status",
            readableHandles: handleMap
        ) == TerminalChat.SharedChatMentionRoute(destination: .all, text: "report status"))
        #expect(TerminalChat.sharedChatMentionRoute(
            from: "@COORDINATOR report status",
            readableHandles: handleMap
        ) == TerminalChat.SharedChatMentionRoute(destination: .coordinator, text: "report status"))
        // A raw display name is not a handle: only catalogue handles route.
        #expect(TerminalChat.sharedChatMentionRoute(
            from: "@Planning Agent ambiguous",
            readableHandles: handleMap
        ) == nil)
        #expect(TerminalChat.parseSharedChatMention(from: "@all", readableHandles: handleMap)
            == .missingText(destination: .all))
        #expect(TerminalChat.parseSharedChatMention(
            from: "@coordinator   ",
            readableHandles: handleMap
        ) == .missingText(destination: .coordinator))
        let firstHandle = handleMap.first(where: { $0.value == participants[0].id })?.key
        #expect(TerminalChat.parseSharedChatMention(
            from: "@\(firstHandle ?? "x")",
            readableHandles: handleMap
        ) == .missingText(destination: .direct([participants[0].id])))
        #expect(TerminalChat.parseSharedChatMention(
            from: "@not-a-live-mention",
            readableHandles: handleMap
        ) == .none)

        // Hidden backward compatibility: the legacy @agent-Base64 spelling
        // still resolves to the same stable id, even though it is never offered
        // by the autocomplete list.
        let compatHandle = TerminalChat.sharedChatMentionHandle(forParticipantID: participants[0].id)
        #expect(
            TerminalChat.sharedChatMentionRoute(
                from: "@\(compatHandle) legacy routing",
                readableHandles: [:]
            ) == TerminalChat.SharedChatMentionRoute(
                destination: .direct([participants[0].id]),
                text: "legacy routing"
            )
        )

        // Aliases are never recycled: a second participant with the same name
        // gets a fresh suffix even after the first left the roster.
        let staleMap = await catalog.handleMap(for: [participants[0]])
        #expect(staleMap["planning-agent"] == participants[0].id)
        let reissueMap = await catalog.handleMap(
            for: [AgentSharedChat.Participant(id: "planner-3", name: "Planning Agent", kind: .agent)]
        )
        #expect(reissueMap["planning-agent-3"] != nil)
        // A session reset clears the alias space.
        await catalog.reset()
        let freshMap = await catalog.handleMap(
            for: [AgentSharedChat.Participant(id: "planner-3", name: "Planning Agent", kind: .agent)]
        )
        #expect(freshMap["planning-agent"] == "planner-3")
    }

    @Test
    func agentsNamedAllOrCoordinatorGetSuffixedHandlesThatRouteToTheirId() async {
        let catalog = SharedChatMentionCatalog()
        let participants = [
            AgentSharedChat.Participant(id: "all-id", name: "all", kind: .agent),
            AgentSharedChat.Participant(id: "coord-id", name: "Coordinator", kind: .agent),
        ]
        let handleMap = await catalog.handleMap(for: participants)
        let suggestions = TerminalChat.sharedChatMentionSuggestions(
            for: participants,
            handleMap: handleMap
        )
        let commands = suggestions.map(\.command)

        // The colliding agents are still suggested, under their suffixed
        // handles; the bare broadcast spellings appear exactly once as the
        // reserved mentions and are never duplicated as direct-agent handles.
        #expect(commands.contains("@all-2 "))
        #expect(commands.contains("@coordinator-2 "))
        #expect(commands.filter { $0 == "@all " }.count == 1)
        #expect(commands.filter { $0 == "@coordinator " }.count == 1)

        // The parser routes the suffixed handles to the right agent ids…
        #expect(
            TerminalChat.sharedChatMentionRoute(
                from: "@all-2 inspect the diff",
                readableHandles: handleMap
            ) == TerminalChat.SharedChatMentionRoute(
                destination: .direct(["all-id"]),
                text: "inspect the diff"
            )
        )
        #expect(
            TerminalChat.sharedChatMentionRoute(
                from: "@coordinator-2 inspect the diff",
                readableHandles: handleMap
            ) == TerminalChat.SharedChatMentionRoute(
                destination: .direct(["coord-id"]),
                text: "inspect the diff"
            )
        )
        // …while the unsuffixed spellings keep their broadcast meaning.
        #expect(
            TerminalChat.sharedChatMentionRoute(
                from: "@all inspect the diff",
                readableHandles: handleMap
            ) == TerminalChat.SharedChatMentionRoute(destination: .all, text: "inspect the diff")
        )
        #expect(
            TerminalChat.sharedChatMentionRoute(
                from: "@coordinator inspect the diff",
                readableHandles: handleMap
            ) == TerminalChat.SharedChatMentionRoute(
                destination: .coordinator,
                text: "inspect the diff"
            )
        )
    }
}
