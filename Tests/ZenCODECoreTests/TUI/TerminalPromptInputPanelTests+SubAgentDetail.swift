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
    /// detail only the scrolling keys and `Esc`, a closed detail nothing.
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
    /// and shows its own mode, `Artifacts`, with the same help in the list and
    /// in a file's diff.
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

    /// Below an agent's detail the operator keeps typing and sending: text
    /// (`q` and `Q` included), paste, editing and cursor keys reach the
    /// draft and `Enter` submits it, while the press-and-hold picker stays
    /// off as with the shared-chat reader.
    @Test
    func subAgentDetailLeavesTypingAndSendingToTheDraft() async {
        let reader = TerminalInteractiveLineReader()
        reader.withPanelLock { $0.panelSupportsPressAndHold = true }
        reader.setSubAgentDetailMode(.detail, panelModeOverride: TerminalChat.subAgentDetailPanelOverride)
        #expect(reader.withPanelLock { !reader.editorContextLocked(state: $0).supportsPressAndHold })
        let recorder = TerminalPanelEventRecorder()
        let keys: [TerminalInteractiveLineReader.Key] = [
            .character("q"),
            .character("Q"),
            .character("x"),
            .paste(" yz"),
            .backspace,
            .left,
            .character("!"),
            .right
        ]

        for key in keys {
            await reader.handlePanelKey(key, timestampMilliseconds: 100, onEvent: recorder.onEvent)
        }
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "qQx !y")
        #expect(reader.withPanelLock { $0.panelCursorIndex } == 6)

        // A held vowel would open the accent picker in a plain prompt.
        for timestamp in [UInt64(1_000), 1_500, 1_550, 1_600, 1_650] {
            await reader.handlePanelKey(
                .character("a"),
                timestampMilliseconds: timestamp,
                onEvent: recorder.onEvent
            )
        }
        #expect(reader.withPanelLock { $0.editor.pressAndHoldMenu == nil })

        await reader.handlePanelKey(.enter, timestampMilliseconds: 2_000, onEvent: recorder.onEvent)

        let line = "qQx !yaaaaa"
        #expect(recorder.detailActions.withLock { $0 }.isEmpty)
        #expect(
            recorder.otherEvents.withLock { $0 }
                == [String(describing: TerminalPromptInputEvent.submitted(line))]
        )
        #expect(reader.withPanelLock { $0.panelBuffer.isEmpty })
        #expect(reader.withPanelLock { $0.history.last } == line)
        // The detail is still open: the routing is the chat loop's to change.
        #expect(reader.withPanelLock { $0.panelSubAgentDetailMode } == .detail)
    }

    /// With the shared-chat reader also open, an agent's detail keeps its
    /// scrolling keys and the reader receives the message keys it binds.
    @Test
    func subAgentDetailComesBeforeTheSharedChatReader() async {
        let reader = TerminalInteractiveLineReader()
        reader.setSharedChatReaderOpen(true)
        reader.setSubAgentDetailMode(.detail, panelModeOverride: TerminalChat.subAgentDetailPanelOverride)
        let recorder = TerminalPanelEventRecorder()

        for key: TerminalInteractiveLineReader.Key in [.up, .home, .left, .right, .character("q")] {
            await reader.handlePanelKey(key, onEvent: recorder.onEvent)
        }

        #expect(recorder.detailActions.withLock { $0 } == [.scrollUp, .top])
        #expect(
            recorder.otherEvents.withLock { $0 } == [
                String(describing: TerminalPromptInputEvent.sharedChatReaderNavigation(.previousMessage)),
                String(describing: TerminalPromptInputEvent.sharedChatReaderNavigation(.nextMessage))
            ]
        )
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "q")
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
            #expect(reader.withPanelLock { $0.panelBuffer.isEmpty })
        case .detail, .closed:
            // `q` is text below an agent's detail; only `Esc` closes it.
            #expect(recorder.detailActions.withLock { $0 } == [.close])
            #expect(reader.withPanelLock { String($0.panelBuffer) } == "q")
        }
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
