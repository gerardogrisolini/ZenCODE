//
//  TerminalPromptInputPanelTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Covers the layers around the pure editor: how bytes become semantic keys,
/// and what the one-row panel reports back to the operator.
@Suite
struct TerminalPromptInputPanelTests {
    // MARK: - Key decoding

    @Test
    func modifiedCursorSequencesDecodeWordMotionAndBufferEnds() {
        let reader = TerminalInteractiveLineReader()

        // Unmodified arrows and Home/End are unchanged.
        #expect(reader.keyFromCSI(Array("D".utf8)) == .left)
        #expect(reader.keyFromCSI(Array("C".utf8)) == .right)
        #expect(reader.keyFromCSI(Array("H".utf8)) == .home)
        #expect(reader.keyFromCSI(Array("F".utf8)) == .end)

        // Alt and Ctrl are both accepted for word motion because the two
        // conventions are split across terminals and platforms.
        #expect(reader.keyFromCSI(Array("1;3D".utf8)) == .wordLeft)
        #expect(reader.keyFromCSI(Array("1;5D".utf8)) == .wordLeft)
        #expect(reader.keyFromCSI(Array("1;3C".utf8)) == .wordRight)
        #expect(reader.keyFromCSI(Array("1;5C".utf8)) == .wordRight)

        // rxvt-style sequences omit the leading parameter.
        #expect(reader.keyFromCSI(Array("5D".utf8)) == .wordLeft)
        #expect(reader.keyFromCSI(Array("3C".utf8)) == .wordRight)
        #expect(reader.keyFromCSI(Array("1D".utf8)) == .left)

        #expect(reader.keyFromCSI(Array("1;5H".utf8)) == .bufferStart)
        #expect(reader.keyFromCSI(Array("1;5F".utf8)) == .bufferEnd)
        #expect(reader.keyFromCSI(Array("1;6H".utf8)) == .bufferStart)
        #expect(reader.keyFromCSI(Array("1;3H".utf8)) == .home)
    }

    @Test
    func csiUAndModifyOtherKeysPreserveFundamentalControlsAndShortcuts() {
        let reader = TerminalInteractiveLineReader()

        // Enhanced keyboard protocols must preserve keys that are already C0
        // bytes in the legacy path.  Test both CSI-u and modifyOtherKeys.
        #expect(reader.keyFromCSI(Array("27u".utf8)) == .cancel)
        #expect(reader.keyFromCSI(Array("9u".utf8)) == .tab)
        #expect(reader.keyFromCSI(Array("127u".utf8)) == .backspace)
        #expect(reader.keyFromCSI(Array("4u".utf8)) == .endOfInput)
        #expect(reader.keyFromCSI(Array("5u".utf8)) == .end)
        #expect(reader.keyFromCSI(Array("11u".utf8)) == .clearAfterCursor)
        #expect(reader.keyFromCSI(Array("21u".utf8)) == .clearBeforeCursor)
        #expect(reader.keyFromCSI(Array("23u".utf8)) == .deleteWordBefore)

        #expect(reader.keyFromCSI(Array("27;1;27~".utf8)) == .cancel)
        #expect(reader.keyFromCSI(Array("27;1;9~".utf8)) == .tab)
        #expect(reader.keyFromCSI(Array("27;1;127~".utf8)) == .backspace)
        #expect(reader.keyFromCSI(Array("27;1;4~".utf8)) == .endOfInput)
        #expect(reader.keyFromCSI(Array("27;1;11~".utf8)) == .clearAfterCursor)
        #expect(reader.keyFromCSI(Array("27;1;21~".utf8)) == .clearBeforeCursor)

        // Modified C0 codes are not their unmodified command bindings:
        // otherwise Shift/Alt+Tab would accept the selected completion.
        #expect(reader.keyFromCSI(Array("9;2u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("9;3u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("18;2u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("27;2;9~".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("27;3;9~".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("27;2;18~".utf8)) == .unknown)

        // Terminals can instead encode Ctrl as a modifier on the printable
        // letter.  Ctrl+D must stay end-of-input, never Alt+D/delete-word.
        #expect(reader.keyFromCSI(Array("100;5u".utf8)) == .endOfInput)
        #expect(reader.keyFromCSI(Array("27;5;100~".utf8)) == .endOfInput)
        #expect(reader.keyFromCSI(Array("107;5u".utf8)) == .clearAfterCursor)
        #expect(reader.keyFromCSI(Array("27;5;107~".utf8)) == .clearAfterCursor)
        #expect(reader.keyFromCSI(Array("117;5u".utf8)) == .clearBeforeCursor)
        #expect(reader.keyFromCSI(Array("27;5;117~".utf8)) == .clearBeforeCursor)

        #expect(reader.keyFromCSI(Array("119;5u".utf8)) == .deleteWordBefore)
        #expect(reader.keyFromCSI(Array("101;5u".utf8)) == .end)
        // Alt+B, Alt+F and Alt+D are not shortcuts.
        #expect(reader.keyFromCSI(Array("98;3u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("102;3u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("100;3u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("127;3u".utf8)) == .clearDraft)
        #expect(reader.keyFromCSI(Array("27;3;127~".utf8)) == .clearDraft)

        // Each shortcut demands its own modifier, so an unrelated combination
        // is not silently swallowed.
        #expect(reader.keyFromCSI(Array("114;3u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("97;3u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("98;5u".utf8)) == .left)
        #expect(reader.keyFromCSI(Array("100;5u".utf8)) == .endOfInput)
    }

    @Test
    func legacyMetaEscapePrefixesDecodeWordShortcuts() {
        func key(for bytes: [UInt8]) -> TerminalInteractiveLineReader.Key {
            let pipe = Pipe()
            let reader = TerminalInteractiveLineReader(
                rawInput: TerminalRawInput(
                    fileDescriptor: pipe.fileHandleForReading.fileDescriptor
                )
            )
            pipe.fileHandleForWriting.write(Data(bytes))
            defer { pipe.fileHandleForWriting.closeFile() }
            guard case let .key(key) = reader.readKeyResult(pollTimeoutMilliseconds: 200) else {
                return .unknown
            }
            return key
        }

        // `ESC b` / `ESC f` are Terminal.app's default Option+←/→.
        #expect(key(for: [0x1B, 0x62]) == .wordLeft)
        #expect(key(for: [0x1B, 0x66]) == .wordRight)
        // Option+B/F with Shift and Option+D are not shortcuts.
        #expect(key(for: [0x1B, 0x42]) == .unknown)
        #expect(key(for: [0x1B, 0x46]) == .unknown)
        #expect(key(for: [0x1B, 0x64]) == .unknown)
        #expect(key(for: [0x1B, 0x44]) == .unknown)
        // `ESC CR` (Terminal.app Shift+Enter, Meta Option+Enter) and `ESC LF`
        // insert a newline.
        #expect(key(for: [0x1B, 0x0D]) == .newline)
        #expect(key(for: [0x1B, 0x0A]) == .newline)
        #expect(key(for: [0x1B, 0x7F]) == .clearDraft)
        #expect(key(for: [0x1B, 0x08]) == .clearDraft)
        // Meta-prefixed CSI-u backspace (Option configured as Esc+).
        #expect(key(for: [0x1B, 0x1B, 0x5B] + Array("127;1u".utf8)) == .clearDraft)
        #expect(key(for: [0x17]) == .deleteWordBefore)
        #expect(key(for: [0x7F]) == .backspace)
    }

    // MARK: - Panel metadata and help

    @Test
    func helpTextFollowsTheModeThePromptIsIn() {
        let reader = TerminalInteractiveLineReader()

        let idleHelp = reader.withPanelLock { reader.panelHelpTextLocked(state: $0) }
        #expect(idleHelp.contains("Enter send"))
        #expect(!idleHelp.contains("Shift/Option+Enter newline"))
        #expect(idleHelp.contains("Ctrl+G access"))
        #expect(!idleHelp.contains("Ctrl+R history"))

        reader.withPanelLock { $0.panelIsProcessing = true }
        let generatingHelp = reader.withPanelLock { reader.panelHelpTextLocked(state: $0) }
        #expect(generatingHelp.contains("Enter queue"))
        #expect(!generatingHelp.contains("Shift/Option+Enter newline"))
        #expect(generatingHelp.contains("Esc stop"))
        #expect(
            reader.withPanelLock { reader.panelCompactHelpTextLocked(state: $0) }
                == "Enter queue · Esc stop · Ctrl+G access · Ctrl+Y chat"
        )

        reader.withPanelLock { state in
            state.panelIsProcessing = false
            state.panelCommandSuggestions = [
                TerminalCommandSuggestion(command: "/feature", summary: "manage features")
            ]
            state.panelBuffer = Array("/fea")
            state.panelCursorIndex = 4
        }
        #expect(
            reader.withPanelLock { reader.panelHelpTextLocked(state: $0) }
                == "↑/↓ select · Tab complete · Enter choose · Esc dismiss"
        )
        #expect(reader.withPanelLock { reader.panelCompactHelpTextLocked(state: $0) } == nil)

        // Processing takes precedence over the visible completion menu: Esc
        // stops the current generation instead of merely dismissing the menu.
        reader.withPanelLock { $0.panelIsProcessing = true }
        #expect(
            reader.withPanelLock { reader.panelHelpTextLocked(state: $0) }
                == "↑/↓ select · Tab complete · Enter choose · Esc stop"
        )


    }

    // MARK: - Panel key handling

    @Test
    func historyRetainsAllSubmissionsBeyondTwoHundredIncludingRepeats() {
        let reader = TerminalInteractiveLineReader()
        let submissions = (0..<512).map { "prompt \($0)" } + ["/new", "/new", "/setup"]

        reader.recordHistory(" \n\t")
        for line in submissions {
            reader.recordHistory(line)
        }

        #expect(reader.commandHistory == submissions)
        var editor = TerminalPromptEditor()
        let context = TerminalPromptEditorContext(history: reader.commandHistory)
        for line in submissions.reversed() {
            #expect(editor.apply(.up, context: context) == .changed)
            #expect(String(editor.buffer) == line)
        }
        #expect(editor.historyIndex == 0)
        #expect(String(editor.buffer) == "prompt 0")
        #expect(TerminalInteractiveLineReader().commandHistory.isEmpty)
    }

    @Test
    func panelRecordsSlashInputsBeforeDispatchAndRecallsThemWithoutMenus() async {
        let reader = TerminalInteractiveLineReader()
        reader.withPanelLock { state in
            state.panelCommandSuggestions = [
                TerminalCommandSuggestion(command: "/new", summary: "new conversation"),
                TerminalCommandSuggestion(command: "/plan", summary: "plan work", requiresArgument: true)
            ]
        }
        let submissions = ["a prompt", "/new", "/plan"]
        let events = Mutex<[String]>([])
        let historyAtDispatch = Mutex<[[String]]>([])
        let onEvent: @Sendable (TerminalPromptInputEvent) async -> Void = { event in
            guard case let .submitted(line) = event else { return }
            events.withLock { $0.append(line) }
            historyAtDispatch.withLock { $0.append(reader.commandHistory) }
        }

        for line in submissions {
            await reader.handlePanelKey(.paste(line), onEvent: onEvent)
            // A dismissed menu allows even an incomplete slash command to be
            // submitted; recalling it must not silently complete it later.
            if line.hasPrefix("/") {
                await reader.handlePanelKey(.cancel, onEvent: onEvent)
            }
            await reader.handlePanelKey(.enter, onEvent: onEvent)
        }
        #expect(events.withLock { $0 } == submissions)
        #expect(historyAtDispatch.withLock { $0 } == [
            ["a prompt"], ["a prompt", "/new"], submissions
        ])

        for line in submissions.reversed() {
            await reader.handlePanelKey(.up, onEvent: onEvent)
            #expect(reader.withPanelLock { String($0.panelBuffer) } == line)
            #expect(reader.withPanelLock { reader.panelCommandSuggestionLinesLocked(state: $0) }.isEmpty)
        }
        for line in submissions.dropFirst() {
            await reader.handlePanelKey(.down, onEvent: onEvent)
            #expect(reader.withPanelLock { String($0.panelBuffer) } == line)
        }
        await reader.handlePanelKey(.down, onEvent: onEvent)
        #expect(reader.withPanelLock { $0.panelBuffer.isEmpty })

        await reader.handlePanelKey(.up, onEvent: onEvent)
        await reader.handlePanelKey(.enter, onEvent: onEvent)
        #expect(events.withLock { $0 } == submissions + ["/plan"])
        #expect(reader.commandHistory == submissions + ["/plan"])
        #expect(reader.withPanelLock { $0.panelBuffer.isEmpty })
    }

    @Test
    func panelStartResetsDismissalButResumePreservesTheDraft() {
        let reader = TerminalInteractiveLineReader()
        reader.withPanelLock { state in
            state.panelBuffer = Array("unfinished")
            state.panelCursorIndex = 3
            state.editor.areSuggestionsDismissed = true
        }
        reader.finishPanelStop(clearPanel: false)

        #expect(
            reader.preparePanelForStart(
                statusBar: TerminalStatusBar(isEnabled: false),
                commandSuggestions: [],
                preservingState: true
            ) == .admitted
        )
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "unfinished")

        reader.finishPanelStop(clearPanel: false)
        #expect(
            reader.preparePanelForStart(
                statusBar: TerminalStatusBar(isEnabled: false),
                commandSuggestions: [],
                preservingState: false
            ) == .admitted
        )
        #expect(reader.withPanelLock { $0.panelBuffer.isEmpty })
        #expect(reader.withPanelLock { !$0.editor.areSuggestionsDismissed })
    }

    @Test
    func livePanelPassesSyntheticTimestampsAndPickerConsumesEnterBeforeSubmit() async {
        let reader = TerminalInteractiveLineReader()
        reader.withPanelLock { state in
            state.panelSupportsPressAndHold = true
        }
        let events = Mutex<[TerminalPromptInputEvent]>([])

        for timestamp in [UInt64(0), 500, 550, 600, 650] {
            await reader.handlePanelKey(
                .character("a"),
                timestampMilliseconds: timestamp
            ) { event in
                events.withLock { $0.append(event) }
            }
        }

        #expect(reader.withPanelLock { $0.editor.pressAndHoldMenu != nil })
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "a")
        await reader.handlePanelKey(.enter, timestampMilliseconds: 700) { event in
            events.withLock { $0.append(event) }
        }
        #expect(events.withLock { $0.isEmpty })
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "à")

        await reader.handlePanelKey(.enter, timestampMilliseconds: 710) { event in
            events.withLock { $0.append(event) }
        }
        let submittedLines = events.withLock { events in
            events.compactMap { event -> String? in
                guard case let .submitted(line) = event else { return nil }
                return line
            }
        }
        #expect(submittedLines == ["à"])
    }

    @Test
    func transientPickerResetsAcrossPanelOwnershipChanges() async {
        let reader = TerminalInteractiveLineReader()
        func installMenu() {
            reader.withPanelLock { state in
                state.panelSupportsPressAndHold = true
                let context = reader.editorContextLocked(state: state)
                for timestamp in [UInt64(0), 500, 550, 600, 650] {
                    _ = state.editor.apply(
                        .character("a"),
                        context: context,
                        timestampMilliseconds: timestamp
                    )
                }
            }
        }

        installMenu()
        await reader.setPanelText("replacement")
        #expect(reader.withPanelLock { $0.editor.pressAndHoldMenu == nil })

        installMenu()
        await reader.setPanelOverlay(
            TerminalPanelModeOverride(modeText: "Overlay", helpText: "Help")
        )
        #expect(reader.withPanelLock { $0.editor.pressAndHoldMenu == nil })
        await reader.setPanelOverlay(nil)

        installMenu()
        reader.setSharedChatReaderOpen(true)
        #expect(reader.withPanelLock { $0.editor.pressAndHoldMenu == nil })
        #expect(reader.withPanelLock { !reader.editorContextLocked(state: $0).supportsPressAndHold })
        reader.setSharedChatReaderOpen(false)

        installMenu()
        #expect(
            reader.preparePanelForStart(
                statusBar: TerminalStatusBar(isEnabled: false),
                commandSuggestions: [],
                preservingState: true
            ) == .admitted
        )
        #expect(reader.withPanelLock { $0.editor.pressAndHoldMenu == nil })
        reader.abandonPanelStart()

        installMenu()
        _ = reader.takePanelTaskForStop()
        #expect(reader.withPanelLock { $0.editor.pressAndHoldMenu == nil })
        reader.finishPanelStop(clearPanel: false)
    }

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

@ChatSessionActor
@Suite
struct TerminalPromptAttachmentSyncTests {
    @Test
    func consumingPromptAttachmentsImmediatelyClearsThePanelBadge() async throws {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-prompt-attachments", isDirectory: true)
        )
        let chat = TerminalChat(configuration: configuration, stdinIsTerminal: false)
        chat.pendingAttachments = [
            AgentRuntimeAttachment(
                kind: .image,
                data: Data([0]),
                contentType: "image/png",
                originalFilename: "photo.png"
            )
        ]

        await chat.synchronizePanelPendingAttachmentCount()
        #expect(chat.interactiveReader.withPanelLock { $0.panelPendingAttachmentCount } == 1)

        let attempt = chat.promptAttempt(prompt: "describe this image")
        #expect(attempt.attachments.count == 1)
        #expect(chat.pendingAttachments.isEmpty)

        // This is the same synchronization made by startGeneration immediately
        // after `promptAttempt` consumes the staged local attachments.
        await chat.synchronizePanelPendingAttachmentCount()
        #expect(chat.interactiveReader.withPanelLock { $0.panelPendingAttachmentCount } == 0)
    }
}
