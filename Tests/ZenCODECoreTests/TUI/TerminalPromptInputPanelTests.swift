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
    func controlBytesDecodeWordDeletionAndLineEnds() {
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x17) == .deleteWordBefore)
        // Existing bindings must keep their meaning.
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x05) == .end)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x15) == .clearBeforeCursor)
    }

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
    func tildeSequencesDecodeBufferEndsAndForwardWordDeletion() {
        let reader = TerminalInteractiveLineReader()

        #expect(reader.keyFromCSI(Array("7~".utf8)) == .home)
        #expect(reader.keyFromCSI(Array("8~".utf8)) == .end)
        #expect(reader.keyFromCSI(Array("7;5~".utf8)) == .bufferStart)
        #expect(reader.keyFromCSI(Array("8;5~".utf8)) == .bufferEnd)
        #expect(reader.keyFromCSI(Array("3~".utf8)) == .delete)
        #expect(reader.keyFromCSI(Array("3;5~".utf8)) == .deleteWordAfter)
        #expect(reader.keyFromCSI(Array("3;3~".utf8)) == .deleteWordAfter)
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
        #expect(reader.keyFromCSI(Array("98;3u".utf8)) == .wordLeft)
        #expect(reader.keyFromCSI(Array("102;3u".utf8)) == .wordRight)
        #expect(reader.keyFromCSI(Array("100;3u".utf8)) == .deleteWordAfter)
        #expect(reader.keyFromCSI(Array("127;3u".utf8)) == .clearDraft)
        #expect(reader.keyFromCSI(Array("27;3;127~".utf8)) == .clearDraft)

        // Each shortcut demands its own modifier, so an unrelated combination
        // is not silently swallowed.
        #expect(reader.keyFromCSI(Array("114;3u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("97;3u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("98;5u".utf8)) == .left)
        #expect(reader.keyFromCSI(Array("100;3u".utf8)) == .deleteWordAfter)
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

        #expect(key(for: [0x1B, 0x62]) == .wordLeft)
        #expect(key(for: [0x1B, 0x66]) == .wordRight)
        #expect(key(for: [0x1B, 0x64]) == .deleteWordAfter)
        #expect(key(for: [0x1B, 0x7F]) == .clearDraft)
        #expect(key(for: [0x1B, 0x08]) == .clearDraft)
        // Meta-prefixed CSI-u backspace (Option configured as Esc+).
        #expect(key(for: [0x1B, 0x1B, 0x5B] + Array("127;1u".utf8)) == .clearDraft)
        #expect(key(for: [0x17]) == .deleteWordBefore)
        #expect(key(for: [0x7F]) == .backspace)
    }

    // MARK: - Panel metadata and help

    @Test
    func modeTextSummarisesMultilineAttachmentsAndQueue() {
        let reader = TerminalInteractiveLineReader()
        reader.withPanelLock { state in
            state.panelBuffer = Array("first\nsecond\nthird")
            state.panelCursorIndex = 7
            state.panelPendingAttachmentCount = 2
            state.panelQueuedPromptCount = 3
        }

        let modeText = reader.withPanelLock { reader.panelModeTextLocked(state: $0) }
        #expect(modeText == "Prompt · ln 2/3 · attach 2 · queued 3")
    }

    @Test
    func modeTextStaysCompactForASingleLineDraftWithoutExtras() {
        let reader = TerminalInteractiveLineReader()
        reader.withPanelLock { state in
            state.panelBuffer = Array("hello")
            state.panelCursorIndex = 5
        }

        #expect(reader.withPanelLock { reader.panelModeTextLocked(state: $0) } == "Prompt")
    }

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

    @Test
    func compactIdleHelpKeepsThePrimaryPromptActionsAndAccessShortcut() {
        let reader = TerminalInteractiveLineReader()

        #expect(
            reader.withPanelLock { reader.panelCompactHelpTextLocked(state: $0) }
                == "Enter send · Esc clear · Ctrl+G access · Ctrl+Y chat"
        )
    }

    @Test
    func suggestionLinesAreAPureProjectionOfTheSelection() {
        let reader = TerminalInteractiveLineReader()
        reader.withPanelLock { state in
            state.panelCommandSuggestions = [
                TerminalCommandSuggestion(command: "/feature", summary: "manage features"),
                TerminalCommandSuggestion(command: "/featurex", summary: "another")
            ]
            state.panelBuffer = Array("/fea")
            state.panelCursorIndex = 4
            state.panelCommandSuggestionIndex = 1
        }

        let lines = reader.withPanelLock { reader.panelCommandSuggestionLinesLocked(state: $0) }
        #expect(lines.count == 2)
        #expect(lines[1].hasPrefix("›"))
        // Rendering must not repair the selection behind the reducer's back.
        #expect(reader.withPanelLock { $0.panelCommandSuggestionIndex } == 1)
    }

    // MARK: - Panel key handling

    @Test
    func panelSubmitRecordsHistoryAndClearsTheDraft() async {
        let reader = TerminalInteractiveLineReader()
        reader.withPanelLock { state in
            state.panelBuffer = Array("a prompt")
            state.panelCursorIndex = 8
        }
        let events = Mutex<[TerminalPromptInputEvent]>([])

        await reader.handlePanelKey(.enter) { event in
            events.withLock { $0.append(event) }
        }

        #expect(events.withLock { $0.count } == 1)
        #expect(reader.withPanelLock { $0.history } == ["a prompt"])
        #expect(reader.withPanelLock { $0.panelBuffer.isEmpty })
    }

    @Test
    func historyIsCappedAndDropsTheOldestEntriesFirst() {
        let reader = TerminalInteractiveLineReader()
        let cap = TerminalInteractiveLineReader.maximumHistoryEntryCount

        for index in 0..<(cap + 10) {
            reader.recordHistory("prompt \(index)")
        }

        let history = reader.withPanelLock { $0.history }
        #expect(history.count == cap)
        #expect(history.first == "prompt 10")
        #expect(history.last == "prompt \(cap + 9)")
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

    @Test(.timeLimit(.minutes(1)))
    func slowPanelRenderDoesNotDelayContinuousHoldInput() async {
        let renderGate = TerminalSlowPanelRenderGate()
        defer {
            Task(name: "ZenCODE.Tests.release-slow-panel-render") {
                await renderGate.release()
            }
        }

        let reader = TerminalInteractiveLineReader()
        let outputWriteCount = Mutex(0)
        let statusBar = TerminalStatusBar(isEnabled: true) { _ in
            outputWriteCount.withLock { $0 += 1 }
        }
        await statusBar.configureForTesting(row: 14, columns: 80)
        reader.withPanelLock { state in
            state.panelStatusBar = statusBar
            state.panelSupportsPressAndHold = true
            state.panelRenderBeforeUpdateForTesting = {
                await renderGate.recordRender()
            }
        }

        let input = TerminalTimedPanelKeyFeed(
            results: [
                (.key(.character("a")), 0),
                (.key(.character("a")), 500),
                (.key(.character("a")), 550),
                (.key(.character("a")), 600),
                (.key(.character("a")), 650),
                (.endOfInput, 700)
            ],
            renderGate: renderGate
        )
        let events = Mutex<[TerminalPromptInputEvent]>([])
        let loop = Task(name: "ZenCODE.Tests.continuous-held-panel-input") {
            await reader.runPanelInputLoop(
                statusBar: statusBar,
                onEvent: { event in
                    events.withLock { $0.append(event) }
                },
                readNextTimedResult: { token in
                    await input.next(token: token)
                }
            )
        }

        // The feed waits for the first renderer suspension before returning the
        // second read. Therefore loop completion before this release proves the
        // actual input loop consumed every repeat while its first repaint was
        // still slow, retaining their source timestamps instead of a burst.
        await loop.value
        #expect(await input.readCount == 6)
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "a")
        #expect(events.withLock { $0.count } == 1)

        await renderGate.release()
        await terminalWaitUntil { outputWriteCount.withLock { $0 >= 2 } }

        // End-of-input resets the transient reducer menu but intentionally does
        // not redraw; the final pending projection is the menu opened by the
        // valid hold sequence. That makes the render itself evidence that the
        // repeats were consumed continuously by `runPanelInputLoop`.
        #expect(await statusBar.state.inputPanelState?.text == "a")
        #expect(await statusBar.state.inputPanelState?.modeText == "Accent a 1/8 à")
        #expect(await renderGate.renderCount == 2)
        #expect(outputWriteCount.withLock { $0 } == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func pickerDismissalReplacesThePendingSlowRenderSnapshot() async {
        let renderGate = TerminalSlowPanelRenderGate()
        defer {
            Task(name: "ZenCODE.Tests.release-dismissed-panel-render") {
                await renderGate.release()
            }
        }

        let reader = TerminalInteractiveLineReader()
        let outputWriteCount = Mutex(0)
        let statusBar = TerminalStatusBar(isEnabled: true) { _ in
            outputWriteCount.withLock { $0 += 1 }
        }
        await statusBar.configureForTesting(row: 14, columns: 80)
        reader.withPanelLock { state in
            state.panelStatusBar = statusBar
            state.panelSupportsPressAndHold = true
            state.panelRenderBeforeUpdateForTesting = {
                await renderGate.recordRender()
            }
        }

        let firstKey = Task(name: "ZenCODE.Tests.first-picker-key") {
            await reader.handlePanelKey(.character("a"), timestampMilliseconds: 0) { _ in }
        }
        await renderGate.waitUntilFirstRenderStarts()
        for timestamp in [UInt64(500), 550, 600, 650] {
            await reader.handlePanelKey(.character("a"), timestampMilliseconds: timestamp) { _ in }
        }
        #expect(reader.withPanelLock { $0.editor.pressAndHoldMenu?.base } == "a")

        await reader.handlePanelKey(.cancel, timestampMilliseconds: 700) { _ in }
        #expect(reader.withPanelLock { $0.editor.pressAndHoldMenu == nil })
        await reader.handlePanelKey(.character("b"), timestampMilliseconds: 710) { _ in }

        await renderGate.release()
        await firstKey.value
        await terminalWaitUntil { outputWriteCount.withLock { $0 >= 2 } }

        #expect(await statusBar.state.inputPanelState?.text == "ab")
        #expect(await statusBar.state.inputPanelState?.modeText == "Prompt")
        #expect(await renderGate.renderCount == 2)
        #expect(outputWriteCount.withLock { $0 } == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppingPanelFencesAnInFlightRenderAndDropsThePendingSnapshot() async {
        let renderGate = TerminalSlowPanelRenderGate()
        defer {
            Task(name: "ZenCODE.Tests.release-stopped-panel-render") {
                await renderGate.release()
            }
        }

        let reader = TerminalInteractiveLineReader()
        let statusBar = TerminalStatusBar(isEnabled: false)
        reader.withPanelLock { state in
            state.panelStatusBar = statusBar
            state.panelBuffer = Array("first")
            state.panelCursorIndex = 5
            state.panelRenderBeforeUpdateForTesting = {
                await renderGate.recordRender()
            }
        }
        reader.finishPanelStart(task: Task(name: "ZenCODE.Tests.completed-panel-loop") {})

        reader.requestPanelRender()
        await renderGate.waitUntilFirstRenderStarts()
        reader.withPanelLock { state in
            state.panelBuffer = Array("pending")
            state.panelCursorIndex = 7
        }
        reader.requestPanelRender()

        let didStop = Mutex(false)
        let stop = Task(name: "ZenCODE.Tests.stop-panel-with-slow-render") {
            await reader.stopPanelInput()
            didStop.withLock { $0 = true }
        }
        await terminalWaitUntil {
            reader.withPanelLock { $0.pendingPanelRender == nil }
        }

        // Stop discards the queued frame before joining the independently
        // running renderer. It must not return while that renderer can still
        // reach the terminal, and the test must not enqueue a replacement frame
        // merely to observe the drain.
        #expect(reader.withPanelLock { $0.pendingPanelRender == nil })
        #expect(!didStop.withLock { $0 })

        await renderGate.release()
        await stop.value
        #expect(await statusBar.state.inputPanelState == nil)
        #expect(reader.withPanelLock { $0.panelLifecycle == .idle })
        #expect(await renderGate.renderCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func preservingStopJoinsTheRendererAndDiscardsItsPendingSnapshot() async {
        let renderGate = TerminalSlowPanelRenderGate()
        defer {
            Task(name: "ZenCODE.Tests.release-preserving-stop-render") {
                await renderGate.release()
            }
        }

        let reader = TerminalInteractiveLineReader()
        let statusBar = TerminalStatusBar(isEnabled: false)
        await statusBar.updateInputPanel(
            text: "preserved",
            cursorIndex: 9,
            modeText: "Prompt",
            helpText: "Enter"
        )
        reader.withPanelLock { state in
            state.panelStatusBar = statusBar
            state.panelBuffer = Array("in-flight")
            state.panelCursorIndex = 9
            state.panelRenderBeforeUpdateForTesting = {
                await renderGate.recordRender()
            }
        }
        reader.finishPanelStart(task: Task(name: "ZenCODE.Tests.completed-preserved-panel-loop") {})

        reader.requestPanelRender()
        await renderGate.waitUntilFirstRenderStarts()
        reader.withPanelLock { state in
            state.panelBuffer = Array("pending")
            state.panelCursorIndex = 7
        }
        reader.requestPanelRender()

        let didStop = Mutex(false)
        let stop = Task(name: "ZenCODE.Tests.preserve-panel-with-slow-render") {
            await reader.stopPanelInput(clearPanel: false)
            didStop.withLock { $0 = true }
        }
        await terminalWaitUntil {
            reader.withPanelLock { $0.pendingPanelRender == nil }
        }

        #expect(await statusBar.state.inputPanelState?.text == "preserved")
        #expect(reader.withPanelLock { $0.pendingPanelRender == nil })
        #expect(!didStop.withLock { $0 })

        await renderGate.release()
        await stop.value

        // The already-owned frame completed before the handoff, the queued one
        // never painted, and `clearPanel: false` retained both display and draft.
        #expect(await statusBar.state.inputPanelState?.text == "in-flight")
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "pending")
        #expect(reader.withPanelLock { $0.panelStatusBar == nil })
        #expect(reader.withPanelLock { $0.panelLifecycle == .idle })
        #expect(await renderGate.renderCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitRefreshCompletesAfterItsRevisionWhileNewerFramesContinue() async {
        let renderGate = TerminalSequencedPanelRenderGate()
        defer {
            Task(name: "ZenCODE.Tests.release-sequenced-panel-renders") {
                await renderGate.releaseAll()
            }
        }

        let reader = TerminalInteractiveLineReader()
        let statusBar = TerminalStatusBar(isEnabled: false)
        reader.withPanelLock { state in
            state.panelStatusBar = statusBar
            state.panelBuffer = Array("initial")
            state.panelCursorIndex = 7
            state.panelRenderBeforeUpdateForTesting = {
                await renderGate.recordRender()
            }
        }

        reader.requestPanelRender()
        await renderGate.waitUntilRenderCount(1)

        let didRefresh = Mutex(false)
        reader.withPanelLock { state in
            state.panelBuffer = Array("explicit")
            state.panelCursorIndex = 8
        }
        let refresh = Task(name: "ZenCODE.Tests.explicit-panel-refresh") {
            await reader.renderPanel()
            didRefresh.withLock { $0 = true }
        }
        await terminalWaitUntil {
            reader.withPanelLock { $0.pendingPanelRender?.text == "explicit" }
        }

        // Supersede the explicit frame while the first render is held. Its
        // waiter must be satisfied when this newer revision is applied.
        reader.withPanelLock { state in
            state.panelBuffer = Array("superseding")
            state.panelCursorIndex = 11
        }
        reader.requestPanelRender()
        await renderGate.release(render: 1)
        await renderGate.waitUntilRenderCount(2)

        // Keep a still-newer frame queued so the renderer cannot become globally
        // idle after applying the revision that satisfies `refresh`.
        reader.withPanelLock { state in
            state.panelBuffer = Array("newer")
            state.panelCursorIndex = 5
        }
        reader.requestPanelRender()
        await renderGate.release(render: 2)
        await renderGate.waitUntilRenderCount(3)
        await terminalWaitUntil { didRefresh.withLock { $0 } }

        #expect(reader.withPanelLock { $0.isPanelRenderInFlight })
        #expect(didRefresh.withLock { $0 })

        for text in ["continuous-1", "continuous-2"] {
            reader.withPanelLock { state in
                state.panelBuffer = Array(text)
                state.panelCursorIndex = text.count
            }
            reader.requestPanelRender()
        }
        #expect(reader.withPanelLock { $0.pendingPanelRender?.text == "continuous-2" })

        await renderGate.releaseAll()
        await refresh.value
        await terminalWaitUntil {
            reader.withPanelLock { !$0.isPanelRenderInFlight }
        }
        #expect(await statusBar.state.inputPanelState?.text == "continuous-2")
        #expect(await renderGate.renderCount == 4)
    }

    @Test
    func pickerEscapeFollowedByBaseTraversesRawParserAndDismissesWithoutDraining() async {
        let pipe = Pipe()
        defer {
            pipe.fileHandleForWriting.closeFile()
            pipe.fileHandleForReading.closeFile()
        }
        let reader = TerminalInteractiveLineReader(
            rawInput: TerminalRawInput(
                fileDescriptor: pipe.fileHandleForReading.fileDescriptor
            ),
            consentInputOwnership: TerminalConsentInputOwnership()
        )
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
        #expect(reader.withPanelLock { $0.editor.pressAndHoldMenu?.base } == "a")

        // A terminal may queue another repeat immediately after the physical
        // Esc. The picker-aware parser consumes that one repeat as part of the
        // dismissal but must leave the rest of the raw stream untouched.
        pipe.fileHandleForWriting.write(Data([0x1B, 0x61, 0x61]))
        let token = TerminalBlockingReadToken()
        let dismissal = TerminalInteractiveLineReader.readPanelKeyResult(
            reader: reader,
            token: token
        )
        #expect(dismissal == .pickerEscape(consumedRepeat: "a"))
        await reader.handlePanelKey(
            .cancel,
            timestampMilliseconds: 4_000,
            consumedPickerRepeat: dismissal?.consumedPickerRepeat
        ) { event in
            events.withLock { $0.append(event) }
        }
        #expect(reader.withPanelLock {
            $0.editor.pressAndHoldSuppression?.lastRepeatTimestampMilliseconds
        } == 4_000)

        #expect(reader.withPanelLock { $0.editor.pressAndHoldMenu == nil })
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "a")

        let remainingRepeat = TerminalInteractiveLineReader.readPanelKeyResult(
            reader: reader,
            token: token
        )
        #expect(remainingRepeat == .key(.character("a")))
        if case let .key(key) = remainingRepeat {
            await reader.handlePanelKey(key, timestampMilliseconds: 4_010) { event in
                events.withLock { $0.append(event) }
            }
        }

        // The reducer's existing residual-repeat suppression consumes the byte
        // without restoring the picker or inserting another base character.
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "a")
        #expect(events.withLock { $0.isEmpty })
    }

    @Test
    func pickerAwareEscapeKeepsCSI_SS3_MetaAndDisabledPanelParsingUnchanged() {
        let pipe = Pipe()
        defer {
            pipe.fileHandleForWriting.closeFile()
            pipe.fileHandleForReading.closeFile()
        }
        let reader = TerminalInteractiveLineReader(
            rawInput: TerminalRawInput(
                fileDescriptor: pipe.fileHandleForReading.fileDescriptor
            ),
            consentInputOwnership: TerminalConsentInputOwnership()
        )
        reader.withPanelLock { state in
            state.panelSupportsPressAndHold = true
            let context = reader.editorContextLocked(state: state)
            for timestamp in [UInt64(0), 500, 550, 600, 650] {
                _ = state.editor.apply(
                    .character("O"),
                    context: context,
                    timestampMilliseconds: timestamp
                )
            }
        }
        let token = TerminalBlockingReadToken()

        func decode(_ bytes: [UInt8]) -> TerminalInteractiveLineReader.KeyReadResult? {
            pipe.fileHandleForWriting.write(Data(bytes))
            return TerminalInteractiveLineReader.readPanelKeyResult(
                reader: reader,
                token: token
            )
        }

        #expect(decode([0x1B, 0x5B, 0x44]) == .key(.left))
        // `O` is also SS3's introducer; a complete sequence still wins.
        #expect(decode([0x1B, 0x4F, 0x44]) == .key(.left))
        #expect(decode([0x1B, 0x1B, 0x5B, 0x44]) == .key(.wordLeft))
        #expect(decode([0x1B, 0x4F, 0x4F]) == .pickerEscape(consumedRepeat: "O"))
        #expect(decode([]) == .key(.character("O")))

        let disabledPipe = Pipe()
        defer {
            disabledPipe.fileHandleForWriting.closeFile()
            disabledPipe.fileHandleForReading.closeFile()
        }
        let disabledReader = TerminalInteractiveLineReader(
            rawInput: TerminalRawInput(
                fileDescriptor: disabledPipe.fileHandleForReading.fileDescriptor
            ),
            consentInputOwnership: TerminalConsentInputOwnership()
        )
        disabledReader.withPanelLock { state in
            for timestamp in [UInt64(0), 500, 550, 600, 650] {
                _ = state.editor.apply(
                    .character("a"),
                    context: TerminalPromptEditorContext(supportsPressAndHold: true),
                    timestampMilliseconds: timestamp
                )
            }
            state.panelSupportsPressAndHold = false
        }
        #expect(disabledReader.withPanelLock { $0.editor.pressAndHoldMenu != nil })
        #expect(disabledReader.withPanelLock { !$0.panelSupportsPressAndHold })
        disabledPipe.fileHandleForWriting.write(Data([0x1B, 0x61]))
        #expect(
            TerminalInteractiveLineReader.readPanelKeyResult(
                reader: disabledReader,
                token: TerminalBlockingReadToken()
            ) == .key(.unknown)
        )
    }

    @Test
    func accentProjectionPrecedesCompletionsAndDescribesPickerActions() {
        let reader = TerminalInteractiveLineReader()
        reader.withPanelLock { state in
            state.panelSupportsPressAndHold = true
            state.panelCommandSuggestions = [
                TerminalCommandSuggestion(command: "/accent", summary: "command")
            ]
            state.panelBuffer = ["/"]
            state.panelCursorIndex = 1
            let context = reader.editorContextLocked(state: state)
            for timestamp in [UInt64(0), 500, 550, 600, 650] {
                _ = state.editor.apply(
                    .character("a"),
                    context: context,
                    timestampMilliseconds: timestamp
                )
            }
        }

        let projection = reader.withPanelLock {
            reader.panelSuggestionProjectionLocked(state: $0)
        }
        #expect(projection.lines.count == 8)
        #expect(projection.lines[0] == "› 1 à")
        #expect(projection.selectedIndex == 0)
        #expect(
            reader.withPanelLock { reader.panelModeTextLocked(state: $0) }
                == "Accent a 1/8 à"
        )
        #expect(
            reader.withPanelLock { reader.panelHelpTextLocked(state: $0) }
                == "1–8 choose · ←/→ ↑/↓ select · Enter choose · Esc dismiss"
        )
        #expect(
            reader.withPanelLock { reader.panelCompactHelpTextLocked(state: $0) }
                == "1–8 choose · arrows select · Enter choose · Esc dismiss"
        )
        #expect(reader.withPanelLock { reader.activeCommandSuggestionsLocked(state: $0).isEmpty })
    }

    @Test
    func selectedAccentWindowSurvivesSixRowAndLowHeightClipping() async {
        let lines = (1...8).map { "choice \($0)" }
        let sixRows = TerminalStatusBar.inputPanelSuggestionWindow(
            lines: lines,
            selectedIndex: 7,
            maximumLineCount: 6
        )
        #expect(sixRows.lines == Array(lines[2...7]))
        #expect(sixRows.selectedIndex == 5)

        let twoRows = TerminalStatusBar.inputPanelSuggestionWindow(
            lines: sixRows.lines,
            selectedIndex: sixRows.selectedIndex,
            maximumLineCount: 2
        )
        #expect(twoRows.lines == Array(lines[6...7]))
        #expect(twoRows.selectedIndex == 1)

        let noRows = TerminalStatusBar.inputPanelSuggestionWindow(
            lines: lines,
            selectedIndex: 7,
            maximumLineCount: 0
        )
        #expect(noRows.lines.isEmpty)
        #expect(noRows.selectedIndex == nil)

        let statusBar = TerminalStatusBar(isEnabled: false)
        await statusBar.updateInputPanel(
            text: "a",
            cursorIndex: 1,
            modeText: "Accent a 8/8 ā",
            helpText: "choose",
            suggestionLines: lines,
            suggestionSelectedIndex: 7,
            revision: 2
        )
        #expect(await statusBar.state.inputPanelState?.suggestionLines == Array(lines[2...7]))
        #expect(await statusBar.state.inputPanelState?.suggestionSelectedIndex == 5)

        // A stale resize/render snapshot cannot restore an older selection.
        await statusBar.updateInputPanel(
            text: "a",
            cursorIndex: 1,
            modeText: "Accent a 1/8 à",
            helpText: "choose",
            suggestionLines: lines,
            suggestionSelectedIndex: 0,
            revision: 1
        )
        #expect(await statusBar.state.inputPanelState?.modeText == "Accent a 8/8 ā")
    }

    @Test(arguments: [false, true])
    func minimumViewportRendererKeepsSelectedAccentInModeRowWithoutMenuRows(hasUnreadChat: Bool) async {
        let reader = TerminalInteractiveLineReader()
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
            _ = state.editor.apply(
                .left,
                context: context,
                timestampMilliseconds: 700
            )
        }
        #expect(reader.withPanelLock { reader.panelModeTextLocked(state: $0) } == "Accent a 8/8 ā")

        let output = Mutex("")
        let statusBar = TerminalStatusBar(isEnabled: true) { text in
            output.withLock { $0 += text }
        }
        // Eight rows is the minimum supported panel height; twenty columns
        // produce exactly sixteen useful content cells inside the box.
        await statusBar.configureForTesting(row: 8, columns: 20)
        reader.withPanelLock { $0.panelStatusBar = statusBar }
        await reader.renderPanel()
        if hasUnreadChat {
            // Discard the earlier badge-free frame: only the final repaint is
            // evidence that the accent survived arrival of an unread message.
            output.withLock { $0 = "" }
            await statusBar.setSharedChatReader(
                entries: [TerminalSharedChatReaderEntry(id: UUID(), route: "Agent → Coordinator", text: "message")],
                unreadCount: 1,
                isExpanded: false
            )
            #expect(await statusBar.state.sharedChatReaderDock?.unreadCount == 1)
        }

        let rendered = output.withLock { $0 }
        #expect(!rendered.contains("› 8 ā"))
        #expect(rendered.contains("Accent a 8/8 ā"))
        #expect(await statusBar.state.inputPanelState?.prioritizesModeText == true)
        #expect(await statusBar.scrollableOutputRowCapacity() == TerminalStatusBar.minimumScrollableRows)
        if hasUnreadChat {
            // Outside the picker the badge retains its original precedence.
            output.withLock { $0 = "" }
            await reader.handlePanelKey(.cancel, timestampMilliseconds: 710) { _ in }
            await reader.renderPanel()
            #expect(await statusBar.state.inputPanelState?.prioritizesModeText == false)
            #expect(output.withLock { $0.contains("Chat: 1 unread") })
        }
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
}

/// Suspends exactly the first renderer task without blocking its executor or
/// the status-bar actor. The test releases it after proving later input was
/// reduced, which creates a real happens-before edge rather than a sleep.
private actor TerminalSlowPanelRenderGate {
    private(set) var renderCount = 0
    private var isReleased = false
    private var firstRenderContinuation: CheckedContinuation<Void, Never>?
    private var firstRenderWaiters: [CheckedContinuation<Void, Never>] = []

    func recordRender() async {
        renderCount += 1
        guard renderCount == 1 else {
            return
        }
        let waiters = firstRenderWaiters
        firstRenderWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            firstRenderContinuation = continuation
        }
    }

    func waitUntilFirstRenderStarts() async {
        guard renderCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            firstRenderWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        firstRenderContinuation?.resume()
        firstRenderContinuation = nil
    }
}

/// Holds each renderer invocation independently so a test can apply one
/// revision while proving that a newer one still keeps the renderer active.
private actor TerminalSequencedPanelRenderGate {
    private(set) var renderCount = 0
    private var releasesAllRenders = false
    private var releasedRenders: Set<Int> = []
    private var renderContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var countWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    func recordRender() async {
        renderCount += 1
        let currentRender = renderCount
        let readyWaiters = countWaiters.filter { $0.count <= currentRender }
        countWaiters.removeAll { $0.count <= currentRender }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
        guard !releasesAllRenders, !releasedRenders.contains(currentRender) else {
            return
        }
        await withCheckedContinuation { continuation in
            renderContinuations[currentRender] = continuation
        }
    }

    func waitUntilRenderCount(_ count: Int) async {
        guard renderCount < count else {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters.append((count: count, continuation: continuation))
        }
    }

    func release(render: Int) {
        releasedRenders.insert(render)
        renderContinuations.removeValue(forKey: render)?.resume()
    }

    func releaseAll() {
        releasesAllRenders = true
        let continuations = renderContinuations.values
        renderContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

/// A deterministic replacement for the blocking terminal transport. It yields
/// the first key, then waits until the renderer has suspended before exposing
/// the remaining already-timestamped keys to the same panel loop.
private actor TerminalTimedPanelKeyFeed {
    private let results: [(result: TerminalInteractiveLineReader.KeyReadResult, timestamp: UInt64)]
    private let renderGate: TerminalSlowPanelRenderGate
    private var nextIndex = 0

    var readCount: Int {
        nextIndex
    }

    init(
        results: [(TerminalInteractiveLineReader.KeyReadResult, UInt64)],
        renderGate: TerminalSlowPanelRenderGate
    ) {
        self.results = results.map { (result: $0.0, timestamp: $0.1) }
        self.renderGate = renderGate
    }

    func next(
        token: TerminalBlockingReadToken
    ) async -> TerminalInteractiveLineReader.TimedPanelKeyReadResult? {
        guard !token.isCancelled(), nextIndex < results.count else {
            return nil
        }
        if nextIndex == 1 {
            await renderGate.waitUntilFirstRenderStarts()
        }
        let next = results[nextIndex]
        nextIndex += 1
        return TerminalInteractiveLineReader.TimedPanelKeyReadResult(
            result: next.result,
            timestampMilliseconds: next.timestamp
        )
    }
}

@TerminalChatActor
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
