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
