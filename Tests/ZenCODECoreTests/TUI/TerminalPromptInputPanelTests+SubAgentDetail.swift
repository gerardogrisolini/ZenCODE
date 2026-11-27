//
//  TerminalPromptInputPanelTests+SubAgentDetail.swift
//  ZenCODE
//
//  Tests of how the prompt input panel routes keys while the sub-agent detail
//  is open, and of the panel event recorder they use.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

extension TerminalPromptInputPanelTests {
    // MARK: - Sub-agent detail

    /// The key map of each mode: the agent list binds `Enter` and `q` too
    /// (`q` as the list's own close, distinct from `Esc`'s), an agent's
    /// detail only the scrolling keys and `Esc` (the open panel swallows
    /// every other key), a closed detail nothing.
    @Test
    func subAgentDetailKeyMapDependsOnTheMode() {
        typealias Reader = TerminalInteractiveLineReader
        let navigation: [(Reader.Key, TerminalSubAgentDetailAction)] = [
            (.up, .scrollUp),
            (.down, .scrollDown),
            (.pageUp, .pageUp),
            (.pageDown, .pageDown),
            (.home, .top),
            (.bufferStart, .top),
            (.end, .bottom),
            (.bufferEnd, .bottom),
            (.cancel, .close)
        ]
        let listOnly: [(Reader.Key, TerminalSubAgentDetailAction)] = [
            (.enter, .confirm),
            (.newline, .confirm),
            (.character("q"), .closeList),
            (.character("Q"), .closeList)
        ]
        let unbound: [Reader.Key] = [
            .character("x"),
            .paste("q"),
            .tab,
            .backspace,
            .left,
            .right,
            .wordLeft,
            .toggleAccessMode,
            .toggleSharedChatReader,
            .endOfInput,
            .unknown
        ]

        for (key, action) in navigation + listOnly {
            #expect(Reader.subAgentDetailAction(for: key, mode: .list) == action)
            #expect(Reader.subAgentDetailAction(for: key, mode: .closed) == nil)
        }
        for (key, action) in navigation {
            #expect(Reader.subAgentDetailAction(for: key, mode: .detail) == action)
        }
        for (key, _) in listOnly {
            #expect(Reader.subAgentDetailAction(for: key, mode: .detail) == nil)
        }
        for key in unbound {
            for mode: Reader.SubAgentDetailMode in [.closed, .list, .detail] {
                #expect(Reader.subAgentDetailAction(for: key, mode: mode) == nil)
            }
        }
    }

    /// The `/artifacts` panel routes the keys as the `/subagent` detail does
    /// and has its own mode, `Artifacts`, with the same help (drawn in the
    /// panel's bottom border) in the list and in a file's diff.
    @Test
    func theArtifactsPanelShowsItsModeWithTheHelpOfTheSubAgentDetail() {
        typealias Mode = TerminalInteractiveLineReader.SubAgentDetailMode
        #expect(TerminalChat.artifactsPanelModeOverride(for: .closed) == nil)
        #expect(TerminalChat.artifactsPanelModeOverride(for: .list) == TerminalChat.artifactsListPanelOverride)
        #expect(TerminalChat.artifactsPanelModeOverride(for: .detail) == TerminalChat.artifactsDetailPanelOverride)
        for mode: Mode in [.list, .detail] {
            let artifacts = TerminalChat.artifactsPanelModeOverride(for: mode)
            let subAgent = TerminalChat.subAgentPanelModeOverride(for: mode)
            #expect(artifacts?.modeText == "Artifacts")
            #expect(subAgent?.modeText == "Sub-agent")
            #expect(artifacts?.helpText == subAgent?.helpText)
            #expect(TerminalDetailPanel.Kind.artifacts.panelModeOverride(for: mode) == artifacts)
            #expect(TerminalDetailPanel.Kind.subAgent.panelModeOverride(for: mode) == subAgent)
        }
        #expect(TerminalChat.artifactsListPanelOverride.helpText == "↑↓ choose · Enter open · Esc close")
        #expect(TerminalChat.artifactsDetailPanelOverride.helpText == "↑↓ PgUp PgDn Home End scroll · Esc close")
        #expect(TerminalDetailPanel.Kind.artifacts.consentClosedMessage == "Artifacts panel closed: a tool asks for consent.\n")
        #expect(TerminalDetailPanel.Kind.subAgent.consentClosedMessage == "Sub-agent detail closed: a tool asks for consent.\n")
    }

    /// The diff that the `/artifacts` panel opened from its list says that Esc
    /// goes back; the list and the closed panel do not change.
    @Test
    func theArtifactsDiffOpenedFromTheListSaysThatEscGoesBack() {
        let back = TerminalChat.artifactsListDetailPanelOverride
        #expect(back.modeText == "Artifacts")
        #expect(back.helpText == "↑↓ PgUp PgDn Home End scroll · Esc back")
        #expect(TerminalChat.artifactsPanelModeOverride(for: .detail, detailReturnsToList: true) == back)
        #expect(TerminalDetailPanel.Kind.artifacts.panelModeOverride(for: .detail, detailReturnsToList: true) == back)
        #expect(TerminalChat.artifactsPanelModeOverride(for: .detail, detailReturnsToList: false)
            == TerminalChat.artifactsDetailPanelOverride)
        #expect(TerminalChat.artifactsPanelModeOverride(for: .list, detailReturnsToList: true)
            == TerminalChat.artifactsListPanelOverride)
        #expect(TerminalChat.artifactsPanelModeOverride(for: .closed, detailReturnsToList: true) == nil)
    }

    /// The detail that `/subagent` opened from its agent list says that Esc
    /// goes back; the detail opened directly, the list, and the closed panel
    /// do not change.
    @Test
    func theSubAgentDetailOpenedFromTheListSaysThatEscGoesBack() {
        let back = TerminalChat.subAgentListDetailPanelOverride
        #expect(back.modeText == "Sub-agent")
        #expect(back.helpText == "↑↓ PgUp PgDn Home End scroll · Esc back")
        #expect(TerminalChat.subAgentPanelModeOverride(for: .detail, detailReturnsToList: true) == back)
        #expect(TerminalDetailPanel.Kind.subAgent.panelModeOverride(for: .detail, detailReturnsToList: true) == back)
        #expect(TerminalChat.subAgentPanelModeOverride(for: .detail, detailReturnsToList: false)
            == TerminalChat.subAgentDetailPanelOverride)
        #expect(TerminalChat.subAgentPanelModeOverride(for: .detail) == TerminalChat.subAgentDetailPanelOverride)
        #expect(TerminalChat.subAgentDetailPanelOverride.helpText == "↑↓ PgUp PgDn Home End scroll · Esc close")
        #expect(TerminalChat.subAgentPanelModeOverride(for: .list, detailReturnsToList: true)
            == TerminalChat.subAgentListPanelOverride)
        #expect(TerminalChat.subAgentPanelModeOverride(for: .closed, detailReturnsToList: true) == nil)
        // Both panels say the same thing in their own mode.
        #expect(TerminalChat.artifactsListDetailPanelOverride.helpText == back.helpText)
    }

    /// While the `/subagent` agent list is open every key it binds becomes a
    /// detail action, and none of them reaches the draft or history.
    @Test
    func subAgentListMapsItsKeysToDetailActions() async {
        let reader = TerminalInteractiveLineReader()
        reader.withPanelLock { state in
            state.history = ["earlier"]
            state.panelBuffer = Array("draft")
            state.panelCursorIndex = 2
        }
        reader.setSubAgentDetailMode(.list, panelModeOverride: TerminalChat.subAgentListPanelOverride)
        let recorder = TerminalPanelEventRecorder()
        let expectations: [(TerminalInteractiveLineReader.Key, TerminalSubAgentDetailAction)] = [
            (.up, .scrollUp),
            (.down, .scrollDown),
            (.pageUp, .pageUp),
            (.pageDown, .pageDown),
            (.home, .top),
            (.bufferStart, .top),
            (.end, .bottom),
            (.bufferEnd, .bottom),
            (.enter, .confirm),
            (.newline, .confirm),
            (.character("q"), .closeList),
            (.character("Q"), .closeList),
            (.cancel, .close)
        ]

        for (key, _) in expectations {
            await reader.handlePanelKey(key, timestampMilliseconds: 100, onEvent: recorder.onEvent)
        }

        #expect(recorder.detailActions.withLock { $0 } == expectations.map { $0.1 })
        #expect(recorder.otherEvents.withLock { $0 }.isEmpty)
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "draft")
        #expect(reader.withPanelLock { $0.panelCursorIndex } == 2)
        #expect(reader.withPanelLock { $0.history } == ["earlier"])
        #expect(reader.withPanelLock { $0.historyIndex } == nil)
    }

    /// Both open modes are modal: the agent list and an agent's detail own
    /// every key the input panel reads but end-of-input. A key the mode binds
    /// becomes its action; every other one, the reader's message keys,
    /// `Ctrl+Y`, `Ctrl+G` and a paste included, is swallowed, and the
    /// shared-chat reader is not even asked. Only a closed panel leaves the
    /// keys to the reader and the draft.
    @Test(arguments: [
        TerminalInteractiveLineReader.SubAgentDetailMode.list,
        .detail
    ])
    func anOpenPanelRoutesEveryKeyToItselfAndSwallowsTheUnboundOnes(
        _ mode: TerminalInteractiveLineReader.SubAgentDetailMode
    ) {
        typealias Reader = TerminalInteractiveLineReader
        let keys: [Reader.Key] = [
            .character("x"), .character("q"), .character("Q"), .character("@"), .character("/"),
            .paste("pasted"), .enter, .newline, .tab, .backspace, .delete,
            .left, .right, .up, .down, .pageUp, .pageDown, .home, .end, .bufferStart, .bufferEnd,
            .wordLeft, .wordRight, .deleteWordBefore, .deleteWordAfter,
            .clearDraft, .clearBeforeCursor, .clearAfterCursor,
            .toggleAccessMode, .toggleSharedChatReader, .cancel, .unknown
        ]
        for key in keys {
            var askedTheReader = false
            let route = Reader.panelKeyRoute(for: key, subAgentDetailMode: mode) {
                askedTheReader = true
                return true
            }
            if let action = Reader.subAgentDetailAction(for: key, mode: mode) {
                #expect(route == .subAgentDetail(action))
            } else {
                #expect(route == .swallowedByDetailPanel)
            }
            #expect(!askedTheReader)
        }
        // End-of-input keeps its meaning, and a closed panel gives the reader
        // its message keys back.
        #expect(Reader.panelKeyRoute(for: .endOfInput, subAgentDetailMode: mode) { true } == .editor)
        #expect(Reader.panelKeyRoute(for: .left, subAgentDetailMode: .closed) { true }
            == .sharedChatReader(.previousMessage))
        #expect(Reader.panelKeyRoute(for: .character("x"), subAgentDetailMode: .closed) { true } == .editor)
    }

    /// Behind an agent's detail the draft never changes: text (`q` and `Q`
    /// included), a paste, editing and cursor keys, completion and `Enter`
    /// are swallowed, so nothing is typed, completed or sent, and neither
    /// `Ctrl+Y` nor `Ctrl+G` reaches the chat loop. The draft, its cursor and
    /// the history stay as they were until the panel closes; the
    /// press-and-hold picker stays off.
    @Test
    func subAgentDetailIsModalAndLeavesTheDraftUntouched() async {
        let reader = TerminalInteractiveLineReader()
        reader.withPanelLock { state in
            state.panelSupportsPressAndHold = true
            state.history = ["earlier"]
            state.panelBuffer = Array("draft")
            state.panelCursorIndex = 2
            state.panelCommandSuggestions = [
                TerminalCommandSuggestion(command: "/subagent", summary: "Open a sub-agent")
            ]
        }
        reader.setSubAgentDetailMode(.detail, panelModeOverride: TerminalChat.subAgentDetailPanelOverride)
        #expect(reader.withPanelLock { !reader.editorContextLocked(state: $0).supportsPressAndHold })
        let recorder = TerminalPanelEventRecorder()
        let keys: [TerminalInteractiveLineReader.Key] = [
            .character("q"),
            .character("Q"),
            .character("x"),
            .character("/"),
            .paste(" pasted text\nsecond line"),
            .backspace,
            .delete,
            .left,
            .right,
            .tab,
            .clearDraft,
            .toggleAccessMode,
            .toggleSharedChatReader,
            .newline,
            .enter
        ]

        for key in keys {
            await reader.handlePanelKey(key, timestampMilliseconds: 100, onEvent: recorder.onEvent)
        }
        // A held vowel would open the accent picker in a plain prompt.
        for timestamp in [UInt64(1_000), 1_500, 1_550, 1_600, 1_650] {
            await reader.handlePanelKey(
                .character("a"),
                timestampMilliseconds: timestamp,
                onEvent: recorder.onEvent
            )
        }

        #expect(recorder.detailActions.withLock { $0 }.isEmpty)
        #expect(recorder.otherEvents.withLock { $0 }.isEmpty)
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "draft")
        #expect(reader.withPanelLock { $0.panelCursorIndex } == 2)
        #expect(reader.withPanelLock { $0.history } == ["earlier"])
        #expect(reader.withPanelLock { $0.historyIndex } == nil)
        #expect(reader.withPanelLock { $0.editor.pressAndHoldMenu == nil })
        // The detail is still open: the routing is the chat loop's to change.
        #expect(reader.withPanelLock { $0.panelSubAgentDetailMode } == .detail)

        // Its keys still reach the panel.
        await reader.handlePanelKey(.pageDown, onEvent: recorder.onEvent)
        #expect(recorder.detailActions.withLock { $0 } == [.pageDown])
        #expect(recorder.otherEvents.withLock { $0 }.isEmpty)

        // Once the panel closes, the same draft takes the keys again.
        reader.setSubAgentDetailMode(.closed, panelModeOverride: nil)
        await reader.handlePanelKey(.character("!"), onEvent: recorder.onEvent)
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "dr!aft")
    }

    /// With the shared-chat reader also open, an agent's detail keeps its
    /// scrolling keys and the reader, hidden behind the panel, receives none:
    /// its message keys are swallowed like any other key the detail does not
    /// bind.
    @Test
    func anOpenDetailHidesTheSharedChatReaderFromTheKeys() async {
        let reader = TerminalInteractiveLineReader()
        reader.setSharedChatReaderOpen(true)
        reader.setSubAgentDetailMode(.detail, panelModeOverride: TerminalChat.subAgentDetailPanelOverride)
        let recorder = TerminalPanelEventRecorder()

        for key: TerminalInteractiveLineReader.Key in [.up, .home, .left, .right, .character("q")] {
            await reader.handlePanelKey(key, onEvent: recorder.onEvent)
        }

        #expect(recorder.detailActions.withLock { $0 } == [.scrollUp, .top])
        #expect(recorder.otherEvents.withLock { $0 }.isEmpty)
        #expect(reader.withPanelLock { $0.panelBuffer.isEmpty })
    }

    /// `Esc` in the detail only closes it, in the list and in an agent's
    /// detail: a running generation must keep going, so the panel never
    /// reports `cancelRequested` for it.
    @Test(arguments: [
        TerminalInteractiveLineReader.SubAgentDetailMode.list,
        .detail
    ])
    func escapeClosesSubAgentDetailWithoutCancellingTheGeneration(
        _ mode: TerminalInteractiveLineReader.SubAgentDetailMode
    ) async {
        let reader = TerminalInteractiveLineReader()
        reader.withPanelLock { state in
            state.panelIsProcessing = true
            state.panelBuffer = Array("next")
            state.panelCursorIndex = 4
        }
        reader.setSubAgentDetailMode(mode, panelModeOverride: TerminalChat.subAgentPanelModeOverride(for: mode))
        let recorder = TerminalPanelEventRecorder()

        await reader.handlePanelKey(.cancel, onEvent: recorder.onEvent)
        #expect(recorder.detailActions.withLock { $0 } == [.close])
        #expect(recorder.otherEvents.withLock { $0 }.isEmpty)
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "next")

        // Once the detail is closed the same key stops the generation again.
        reader.setSubAgentDetailMode(.closed, panelModeOverride: nil)
        await reader.handlePanelKey(.cancel, onEvent: recorder.onEvent)
        #expect(recorder.detailActions.withLock { $0 } == [.close])
        #expect(recorder.otherEvents.withLock { $0 } == ["cancelRequested"])
    }

    /// A consent prompt stops and resumes the panel while the detail stays on
    /// screen, so neither transition (nor a fresh start) changes how the
    /// detail routes the keys.
    @Test(arguments: [
        TerminalInteractiveLineReader.SubAgentDetailMode.list,
        .detail
    ])
    func subAgentDetailModeSurvivesPanelStopAndResume(
        _ mode: TerminalInteractiveLineReader.SubAgentDetailMode
    ) async {
        let reader = TerminalInteractiveLineReader()
        let statusBar = TerminalStatusBar(isEnabled: false)
        reader.setSubAgentDetailMode(mode, panelModeOverride: TerminalChat.subAgentPanelModeOverride(for: mode))
        func currentMode() -> TerminalInteractiveLineReader.SubAgentDetailMode {
            reader.withPanelLock { $0.panelSubAgentDetailMode }
        }

        reader.finishPanelStart(task: Task(name: "ZenCODE.Tests.completed-panel-loop") {})
        await reader.stopPanelInput(clearPanel: false)
        #expect(currentMode() == mode)

        #expect(
            reader.preparePanelForStart(
                statusBar: statusBar,
                commandSuggestions: [],
                preservingState: true
            ) == .admitted
        )
        reader.finishPanelStart(task: Task(name: "ZenCODE.Tests.completed-panel-loop") {})
        #expect(currentMode() == mode)

        await reader.stopPanelInput()
        #expect(currentMode() == mode)
        #expect(
            reader.preparePanelForStart(
                statusBar: statusBar,
                commandSuggestions: [],
                preservingState: false
            ) == .admitted
        )
        reader.abandonPanelStart()
        #expect(currentMode() == mode)

        let recorder = TerminalPanelEventRecorder()
        await reader.handlePanelKey(.character("q"), onEvent: recorder.onEvent)
        await reader.handlePanelKey(.cancel, onEvent: recorder.onEvent)
        switch mode {
        case .list:
            // `q` closes the list (as its own action) and so does `Esc`.
            #expect(recorder.detailActions.withLock { $0 } == [.closeList, .close])
        case .detail, .closed:
            // `q` is swallowed by an agent's detail; only `Esc` closes it.
            #expect(recorder.detailActions.withLock { $0 } == [.close])
        }
        #expect(reader.withPanelLock { $0.panelBuffer.isEmpty })
    }

    /// Closing the detail gives the keys back to the draft, where page keys
    /// remain no-ops that touch neither the draft, the history nor a picker.
    @Test(arguments: [
        TerminalInteractiveLineReader.SubAgentDetailMode.list,
        .detail
    ])
    func closedSubAgentDetailReturnsKeysToTheDraftAndIgnoresPageKeys(
        _ mode: TerminalInteractiveLineReader.SubAgentDetailMode
    ) async {
        let reader = TerminalInteractiveLineReader()
        reader.withPanelLock { $0.history = ["earlier"] }
        reader.setSubAgentDetailMode(mode, panelModeOverride: TerminalChat.subAgentPanelModeOverride(for: mode))
        reader.setSubAgentDetailMode(.closed, panelModeOverride: nil)
        let recorder = TerminalPanelEventRecorder()

        await reader.handlePanelKey(.character("q"), onEvent: recorder.onEvent)
        await reader.handlePanelKey(.pageUp, onEvent: recorder.onEvent)
        await reader.handlePanelKey(.pageDown, onEvent: recorder.onEvent)

        #expect(recorder.detailActions.withLock { $0 }.isEmpty)
        #expect(recorder.otherEvents.withLock { $0 }.isEmpty)
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "q")
        #expect(reader.withPanelLock { $0.panelCursorIndex } == 1)
        #expect(reader.withPanelLock { $0.historyIndex } == nil)

        var editor = TerminalPromptEditor()
        editor.buffer = Array("draft")
        editor.cursorIndex = 2
        let context = TerminalPromptEditorContext(history: ["earlier"])
        #expect(editor.apply(.pageUp, context: context) == .ignored)
        #expect(editor.apply(.pageDown, context: context) == .ignored)
        #expect(editor.buffer == Array("draft"))
        #expect(editor.cursorIndex == 2)
        #expect(editor.historyIndex == nil)

        // An open accent picker treats page keys like any unknown key.
        let pickerContext = TerminalPromptEditorContext(supportsPressAndHold: true)
        var pickerEditor = TerminalPromptEditor()
        for timestamp in [UInt64(0), 500, 550, 600, 650] {
            _ = pickerEditor.apply(
                .character("a"),
                context: pickerContext,
                timestampMilliseconds: timestamp
            )
        }
        #expect(pickerEditor.pressAndHoldMenu != nil)
        #expect(pickerEditor.apply(.pageDown, context: pickerContext, timestampMilliseconds: 700) == .ignored)
        #expect(pickerEditor.pressAndHoldMenu != nil)
    }
}

/// Records what the panel dispatched. `TerminalPromptInputEvent` is not
/// `Equatable`, so detail actions are kept typed and every other event is
/// reduced to its description.
private final class TerminalPanelEventRecorder: Sendable {
    let detailActions = Mutex<[TerminalSubAgentDetailAction]>([])
    let otherEvents = Mutex<[String]>([])

    var onEvent: @Sendable (TerminalPromptInputEvent) async -> Void {
        { [self] event in
            if case let .subAgentDetail(action) = event {
                detailActions.withLock { $0.append(action) }
            } else {
                otherEvents.withLock { $0.append(String(describing: event)) }
            }
        }
    }
}
