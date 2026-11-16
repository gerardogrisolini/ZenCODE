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

    @Test
    func modeTextNamesWhatVoiceModeDoesAfterTheQueue() async {
        let reader = TerminalInteractiveLineReader()
        func modeText() -> String {
            reader.withPanelLock { reader.panelModeTextLocked(state: $0) }
        }
        reader.withPanelLock { state in
            state.panelPendingAttachmentCount = 2
            state.panelQueuedPromptCount = 1
        }
        #expect(modeText() == "Prompt · attach 2 · queued 1")

        // Reading aloud wins over the pause, the pause over the start.
        let expectations: [(VoiceModeSessionState, String)] = [
            (VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: false), "voice on"),
            (VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: false, isStarting: true), "voice starting"),
            (VoiceModeSessionState(isOn: true, isPaused: true, isSpeaking: false), "voice paused"),
            (VoiceModeSessionState(isOn: true, isPaused: true, isSpeaking: false, isStarting: true), "voice paused"),
            (VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: true), "voice reading"),
            (VoiceModeSessionState(isOn: true, isPaused: true, isSpeaking: true, isStarting: true), "voice reading"),
        ]
        for (voiceState, voiceText) in expectations {
            await reader.setPanelVoiceState(voiceState)
            #expect(modeText() == "Prompt · attach 2 · queued 1 · \(voiceText)", "\(voiceState)")
        }

        // Off, nothing; nor with stale flags.
        await reader.setPanelVoiceState(.off)
        #expect(modeText() == "Prompt · attach 2 · queued 1")
        await reader.setPanelVoiceState(VoiceModeSessionState(isOn: false, isPaused: true, isSpeaking: true, isStarting: true))
        #expect(modeText() == "Prompt · attach 2 · queued 1")

        // Only in the ordinary mode text: an overlay and the accent menu
        // replace it whole.
        await reader.setPanelVoiceState(VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: false))
        reader.withPanelLock { state in
            state.panelPendingAttachmentCount = 0
            state.panelQueuedPromptCount = 0
            state.panelIsProcessing = true
        }
        #expect(modeText() == "Next prompt · voice on")
        reader.withPanelLock { $0.panelOverlayOverride = TerminalPanelModeOverride(modeText: "Overlay", helpText: "Help") }
        #expect(modeText() == "Overlay")
        reader.withPanelLock { state in
            state.panelOverlayOverride = nil
            state.panelIsProcessing = false
            state.panelSupportsPressAndHold = true
            let context = reader.editorContextLocked(state: state)
            for timestamp in [UInt64(0), 500, 550, 600, 650] {
                _ = state.editor.apply(.character("a"), context: context, timestampMilliseconds: timestamp)
            }
        }
        #expect(reader.withPanelLock { $0.editor.pressAndHoldMenu != nil })
        #expect(modeText().hasPrefix("Accent "))
        #expect(!modeText().contains("voice"))
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
        // The production entry point of an override; with the routing mode
        // closed, the override alone dismisses the menu.
        reader.setSubAgentDetailMode(
            .closed,
            panelModeOverride: TerminalPanelModeOverride(modeText: "Overlay", helpText: "Help")
        )
        #expect(reader.withPanelLock { $0.editor.pressAndHoldMenu == nil })
        reader.setSubAgentDetailMode(.closed, panelModeOverride: nil)

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
        let chat = TerminalChat(configuration: configuration, stdinIsTerminal: false, telegramTransportFactory: nil)
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
