//
//  TerminalInteractiveLineReaderTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite
struct TerminalInteractiveLineReaderTests {
    /// A roster notification can be lost (the terminal queue evicts exactly
    /// this event class first, and the coordinator publishes it only on a
    /// signature change). The panel therefore pulls the live mention catalogue
    /// while the operator edits a mention token, so every active agent is
    /// offered instead of only the reserved broadcast handles.
    @Test
    func mentionDraftPullsLiveMentionSuggestions() async {
        let reader = TerminalInteractiveLineReader()
        await reader.setPanelCommandSuggestions([
            TerminalCommandSuggestion(command: "/help", summary: "help"),
            TerminalCommandSuggestion(command: "@coordinator ", summary: "coordinator"),
            TerminalCommandSuggestion(command: "@all ", summary: "all")
        ])
        reader.setPanelMentionSuggestionsProvider {
            [
                TerminalCommandSuggestion(command: "@coordinator ", summary: "coordinator"),
                TerminalCommandSuggestion(command: "@all ", summary: "all"),
                TerminalCommandSuggestion(command: "@dev ", summary: "message active agent: dev")
            ]
        }

        await reader.setPanelText("@")
        await reader.refreshPanelMentionSuggestionsIfNeeded()

        let commands = reader.state.withLock { $0.panelCommandSuggestions.map(\.command) }
        #expect(commands == ["/help", "@coordinator ", "@all ", "@dev "])
    }

    @Test
    func commandSuggestionWindowKeepsSelectedSuggestionVisible() {
        let suggestions = (0..<10).map { index in
            TerminalCommandSuggestion(
                command: "/command\(index)",
                summary: "summary \(index)"
            )
        }

        #expect(
            TerminalInteractiveLineReader.visiblePanelCommandSuggestionWindow(
                suggestions: suggestions,
                selectedIndex: 0,
                maximumLineCount: 6
            ).map(\.index) == [0, 1, 2, 3, 4, 5]
        )
        #expect(
            TerminalInteractiveLineReader.visiblePanelCommandSuggestionWindow(
                suggestions: suggestions,
                selectedIndex: 5,
                maximumLineCount: 6
            ).map(\.index) == [0, 1, 2, 3, 4, 5]
        )
        #expect(
            TerminalInteractiveLineReader.visiblePanelCommandSuggestionWindow(
                suggestions: suggestions,
                selectedIndex: 6,
                maximumLineCount: 6
            ).map(\.index) == [1, 2, 3, 4, 5, 6]
        )
        #expect(
            TerminalInteractiveLineReader.visiblePanelCommandSuggestionWindow(
                suggestions: suggestions,
                selectedIndex: 9,
                maximumLineCount: 6
            ).map(\.index) == [4, 5, 6, 7, 8, 9]
        )
    }

    @Test
    func pastedTextNormalizesCarriageReturnsToNewlines() {
        let bytes = Array("first\r\nsecond\rthird".utf8)

        #expect(
            TerminalInteractiveLineReader.normalizedPastedText(bytes: bytes) == "first\nsecond\nthird"
        )
    }

    @Test
    func redrawSequenceReusesCurrentLine() {
        let sequence = TerminalInteractiveLineReader.redrawSequence(
            prompt: "Feature id: ",
            buffer: Array("github"),
            cursorIndex: 6,
            terminalColumns: 80
        ).sequence

        #expect(sequence == "\r\u{1B}[2KFeature id: github")
        #expect(!sequence.hasPrefix("\n"))
    }

    @Test
    func redrawLayoutPlacesCursorBeforeAndAfterExplicitNewline() {
        let buffer = Array("one\ntwo")
        let beforeNewline = TerminalInteractiveLineReader.renderLayout(
            prompt: "> ",
            buffer: buffer,
            cursorIndex: 3,
            terminalColumns: 20
        )
        let afterNewline = TerminalInteractiveLineReader.renderLayout(
            prompt: "> ",
            buffer: buffer,
            cursorIndex: 4,
            terminalColumns: 20
        )

        #expect(beforeNewline.text == "> one\r\ntwo")
        #expect(beforeNewline.lineCount == 2)
        #expect(beforeNewline.cursorRow == 0)
        #expect(beforeNewline.cursorColumn == 5)
        #expect(afterNewline.cursorRow == 1)
        #expect(afterNewline.cursorColumn == 0)
        #expect(
            TerminalInteractiveLineReader.redrawSequence(
                prompt: "> ",
                buffer: buffer,
                cursorIndex: 3,
                terminalColumns: 20
            ).sequence == "\r\u{1B}[2K> one\r\ntwo\u{1B}[1A\r\u{1B}[5C"
        )
        #expect(
            TerminalInteractiveLineReader.redrawSequence(
                prompt: "> ",
                buffer: buffer,
                cursorIndex: 4,
                terminalColumns: 20
            ).sequence == "\r\u{1B}[2K> one\r\ntwo\r"
        )
    }

    @Test
    func redrawLayoutTraversesSoftWrappedRows() {
        let buffer = Array("abcdef")
        let beforeWrappedCharacter = TerminalInteractiveLineReader.renderLayout(
            prompt: ">",
            buffer: buffer,
            cursorIndex: 3,
            terminalColumns: 5
        )
        let afterWrappedCharacter = TerminalInteractiveLineReader.renderLayout(
            prompt: ">",
            buffer: buffer,
            cursorIndex: 4,
            terminalColumns: 5
        )

        #expect(beforeWrappedCharacter.text == ">abc\r\ndef")
        #expect(beforeWrappedCharacter.lineCount == 2)
        #expect(beforeWrappedCharacter.cursorRow == 0)
        #expect(beforeWrappedCharacter.cursorColumn == 4)
        #expect(afterWrappedCharacter.cursorRow == 1)
        #expect(afterWrappedCharacter.cursorColumn == 1)
        #expect(
            TerminalInteractiveLineReader.redrawSequence(
                prompt: ">",
                buffer: buffer,
                cursorIndex: 3,
                terminalColumns: 5
            ).sequence == "\r\u{1B}[2K>abc\r\ndef\u{1B}[1A\r\u{1B}[4C"
        )
        #expect(
            TerminalInteractiveLineReader.redrawSequence(
                prompt: ">",
                buffer: buffer,
                cursorIndex: 4,
                terminalColumns: 5
            ).sequence == "\r\u{1B}[2K>abc\r\ndef\r\u{1B}[1C"
        )
    }

    @Test
    func redrawClearsPreviousFootprintWhenDraftShrinks() {
        #expect(
            TerminalInteractiveLineReader.renderLayout(
                prompt: "",
                buffer: Array("abcde"),
                cursorIndex: 5,
                terminalColumns: 5
            ).lineCount == 2
        )
        #expect(
            TerminalInteractiveLineReader.renderLayout(
                prompt: "",
                buffer: Array("abc"),
                cursorIndex: 3,
                terminalColumns: 5
            ).lineCount == 1
        )
        #expect(
            TerminalInteractiveLineReader.redrawSequence(
                prompt: "",
                buffer: Array("x"),
                cursorIndex: 1,
                previousLineCount: 3,
                previousCursorRow: 2,
                terminalColumns: 5
            ).sequence == "\r\u{1B}[2A\u{1B}[0Jx"
        )
    }

    @Test
    func shiftReturnKeyDecodesKittyCSIUSequence() {
        // kitty keyboard protocol: CSI 13;2u (Shift+Enter).
        #expect(
            TerminalInteractiveLineReader.shiftReturnKey(
                components: ["13", "2"],
                keyCodeIndex: 0,
                modifierIndex: 1
            ) == .newline
        )
        // CSI 13u (plain Enter reported in CSI-u form).
        #expect(
            TerminalInteractiveLineReader.shiftReturnKey(
                components: ["13"],
                keyCodeIndex: 0,
                modifierIndex: 1
            ) == .enter
        )
        // Alt+Enter (bits 0b10) submits like Enter; only Shift inserts a
        // newline, also together with Alt.
        #expect(
            TerminalInteractiveLineReader.shiftReturnKey(
                components: ["13", "3"],
                keyCodeIndex: 0,
                modifierIndex: 1
            ) == .enter
        )
        #expect(
            TerminalInteractiveLineReader.shiftReturnKey(
                components: ["13", "4"],
                keyCodeIndex: 0,
                modifierIndex: 1
            ) == .newline
        )
    }

    @Test
    func controlShortcutsDecodeKittyAndModifyOtherKeysSequences() {
        let reader = TerminalInteractiveLineReader()

        // The legacy raw C0 byte remains the baseline encoding for Ctrl+O.
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x0F) == .toggleSharedChatReader)
        // Ctrl+Y is the cross-platform alternative (Ctrl+O is intercepted on macOS).
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x19) == .toggleSharedChatReader)
        #expect(reader.keyFromCSI(Array("121;5u".utf8)) == .toggleSharedChatReader)
        #expect(reader.keyFromCSI(Array("27;5;121~".utf8)) == .toggleSharedChatReader)
        #expect(reader.keyFromCSI(Array("97;5u".utf8)) == .home)
        #expect(reader.keyFromCSI(Array("27;5;97~".utf8)) == .home)
        #expect(reader.keyFromCSI(Array("103;5u".utf8)) == .toggleAccessMode)
        #expect(reader.keyFromCSI(Array("27;5;103~".utf8)) == .toggleAccessMode)
        #expect(reader.keyFromCSI(Array("111;5u".utf8)) == .toggleSharedChatReader)
        #expect(reader.keyFromCSI(Array("27;5;111~".utf8)) == .toggleSharedChatReader)
        #expect(reader.keyFromCSI(Array("116;5u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("27;5;116~".utf8)) == .unknown)

        // Readline motion shortcuts distinguish Control from Alt; Alt+B and
        // Alt+F are not shortcuts.
        #expect(reader.keyFromCSI(Array("98;5u".utf8)) == .left)
        #expect(reader.keyFromCSI(Array("98;3u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("102;5u".utf8)) == .right)
        #expect(reader.keyFromCSI(Array("102;3u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("112;5u".utf8)) == .up)
        #expect(reader.keyFromCSI(Array("110;5u".utf8)) == .down)
        #expect(reader.keyFromCSI(Array("60;3u".utf8)) == .bufferStart)
        #expect(reader.keyFromCSI(Array("62;3u".utf8)) == .bufferEnd)

        // An explicit Kitty press event and additional modifiers retain Control.
        #expect(reader.keyFromCSI(Array("97;5:1u".utf8)) == .home)
        #expect(reader.keyFromCSI(Array("116;7u".utf8)) == .unknown)
    }

    @Test
    func carriageReturnStillDecodesAsEnter() {
        let reader = TerminalInteractiveLineReader()

        #expect(TerminalInteractiveLineReader.controlKey(for: 0x0D) == .enter)
        #expect(reader.keyFromCSI(Array("13;5u".utf8)) == .enter)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x14) == nil)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x01) == .home)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x05) == .end)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x02) == .left)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x06) == .right)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x10) == .up)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x0E) == .down)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x07) == .toggleAccessMode)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x0F) == .toggleSharedChatReader)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x19) == .toggleSharedChatReader)
    }

    @Test
    func metaPrefixedAndReadlineEscapeSequencesDecodeDraftMotion() {
        let pipe = Pipe()
        let reader = TerminalInteractiveLineReader(
            rawInput: TerminalRawInput(
                fileDescriptor: pipe.fileHandleForReading.fileDescriptor
            )
        )

        func decode(_ bytes: [UInt8]) -> TerminalInteractiveLineReader.Key? {
            pipe.fileHandleForWriting.write(Data(bytes))
            return reader.readKey(pollTimeoutMilliseconds: 500)
        }

        // macOS terminals configured with Option as Meta prefix the plain
        // cursor sequence with ESC instead of sending a CSI modifier.
        #expect(decode([0x1B, 0x1B, 0x5B, 0x44]) == .wordLeft)
        #expect(decode([0x1B, 0x1B, 0x5B, 0x43]) == .wordRight)
        #expect(decode([0x1B, 0x1B, 0x4F, 0x48]) == .bufferStart)
        #expect(decode([0x1B, 0x1B, 0x4F, 0x46]) == .bufferEnd)
        // Option+Delete is a plain Delete, not a word deletion.
        #expect(decode([0x1B, 0x1B, 0x5B, 0x33, 0x7E]) == .delete)

        // Readline draft-wide motion, reachable without Home/End keys.
        #expect(decode([0x1B, 0x3C]) == .bufferStart)
        #expect(decode([0x1B, 0x3E]) == .bufferEnd)

        pipe.fileHandleForWriting.closeFile()
    }

    /// The sub-agent detail pages its transcript with PgUp/PgDn, so the
    /// decoder reports them as their own keys whatever modifier the terminal
    /// adds, while the neighbouring tilde prefixes keep their meaning.
    @Test
    func tildeSequencesDecodePageKeysWithoutChangingExistingPrefixes() {
        let pipe = Pipe()
        let reader = TerminalInteractiveLineReader(
            rawInput: TerminalRawInput(
                fileDescriptor: pipe.fileHandleForReading.fileDescriptor
            )
        )

        func decode(_ bytes: [UInt8]) -> TerminalInteractiveLineReader.Key? {
            pipe.fileHandleForWriting.write(Data(bytes))
            return reader.readKey(pollTimeoutMilliseconds: 500)
        }

        #expect(decode(Array("\u{1B}[5~".utf8)) == .pageUp)
        #expect(decode(Array("\u{1B}[6~".utf8)) == .pageDown)
        #expect(decode(Array("\u{1B}[5;5~".utf8)) == .pageUp)
        #expect(decode(Array("\u{1B}[6;2~".utf8)) == .pageDown)
        // Option as Meta prefixes the plain sequence with another ESC.
        #expect(decode(Array("\u{1B}\u{1B}[5~".utf8)) == .pageUp)
        pipe.fileHandleForWriting.closeFile()

        #expect(reader.keyFromCSI(Array("5~".utf8)) == .pageUp)
        #expect(reader.keyFromCSI(Array("6~".utf8)) == .pageDown)
        #expect(reader.keyFromCSI(Array("5;3~".utf8)) == .pageUp)
        #expect(reader.keyFromCSI(Array("6;5~".utf8)) == .pageDown)

        #expect(reader.keyFromCSI(Array("1~".utf8)) == .home)
        #expect(reader.keyFromCSI(Array("7~".utf8)) == .home)
        #expect(reader.keyFromCSI(Array("1;5~".utf8)) == .bufferStart)
        #expect(reader.keyFromCSI(Array("2~".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("3~".utf8)) == .delete)
        #expect(reader.keyFromCSI(Array("3;5~".utf8)) == .deleteWordAfter)
        #expect(reader.keyFromCSI(Array("4~".utf8)) == .end)
        #expect(reader.keyFromCSI(Array("8~".utf8)) == .end)
        #expect(reader.keyFromCSI(Array("4;5~".utf8)) == .bufferEnd)
        #expect(reader.keyFromCSI(Array("201~".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("15~".utf8)) == .unknown)
    }

    @Test
    func oscSequencesDrainPayloadThroughBELAndST() {
        let pipe = Pipe()
        let reader = TerminalInteractiveLineReader(
            rawInput: TerminalRawInput(
                fileDescriptor: pipe.fileHandleForReading.fileDescriptor
            )
        )

        // OSC payload is allowed to contain printable bytes and line breaks;
        // BEL terminates it without leaking the payload into the draft.
        pipe.fileHandleForWriting.write(
            Data([0x1B, 0x5D] + Array("0;title\nsecond line".utf8) + [0x07, 0x78])
        )
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .unknown)
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .character("x"))

        // ST (`ESC \\`) is the other common OSC terminator.
        pipe.fileHandleForWriting.write(
            Data([0x1B, 0x5D] + Array("8;;https://example.com\nlabel".utf8) + [0x1B, 0x5C, 0x79])
        )
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .unknown)
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .character("y"))

        pipe.fileHandleForWriting.closeFile()
    }

    @Test
    func unknownMultilineEscapeSequenceDoesNotLeakBytesIntoDraft() {
        let pipe = Pipe()
        let reader = TerminalInteractiveLineReader(
            rawInput: TerminalRawInput(
                fileDescriptor: pipe.fileHandleForReading.fileDescriptor
            )
        )

        // Generic escape sequences have no dependable final-byte range. The
        // entire multiline burst must be drained until the inter-byte timeout.
        pipe.fileHandleForWriting.write(
            Data([0x1B, 0x3F] + Array("vendor line one\nvendor line two\nvendor line three\n".utf8))
        )
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .unknown)

        // Write after the drain has returned to prove no payload byte remains
        // queued as draft input.
        pipe.fileHandleForWriting.write(Data([0x78]))
        #expect(reader.readKey(pollTimeoutMilliseconds: 500) == .character("x"))

        pipe.fileHandleForWriting.closeFile()
    }

    @Test
    func cancellableConsentReadDistinguishesTimeoutByteAndEOF() {
        let pipe = Pipe()
        let rawInput = TerminalRawInput(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor
        )

        #expect(rawInput.readByteResult(timeoutMilliseconds: 5) == .timedOut)
        pipe.fileHandleForWriting.write(Data([0x72]))
        #expect(rawInput.readByteResult(timeoutMilliseconds: 100) == .byte(0x72))
        pipe.fileHandleForWriting.closeFile()
        #expect(rawInput.readByteResult(timeoutMilliseconds: 100) == .endOfInput)

        let closedPipe = Pipe()
        let reader = TerminalInteractiveLineReader(
            rawInput: TerminalRawInput(
                fileDescriptor: closedPipe.fileHandleForReading.fileDescriptor
            )
        )
        closedPipe.fileHandleForWriting.closeFile()
        #expect(reader.readSingleKey(prompt: "", shouldCancel: { false }) == nil)
    }

    @Test
    func accessModeToggleEventPreservesPanelTextAndCursor() async {
        let reader = TerminalInteractiveLineReader()
        reader.withPanelLock { state in
            state.panelBuffer = Array("hello")
            state.panelCursorIndex = 2
        }
        let events = Mutex<[TerminalPromptInputEvent]>([])

        await reader.handlePanelKey(.toggleAccessMode) { event in
            events.withLock { $0.append(event) }
        }

        let capturedEvents = events.withLock { $0 }
        #expect(capturedEvents.count == 1)
        if case .toggleAccessModeRequested = capturedEvents.first {
            // Expected event.
        } else {
            Issue.record("Expected toggleAccessModeRequested")
        }
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "hello")
        #expect(reader.withPanelLock { $0.panelCursorIndex } == 2)
        #expect(reader.withPanelLock {
            reader.panelHelpTextLocked(state: $0).contains("Ctrl+G access")
        })
        #expect(reader.withPanelLock {
            reader.panelCompactHelpTextLocked(state: $0) == "Enter send · Esc clear · Ctrl+G access · Ctrl+Y chat"
        })
    }

    @Test
    func consentPanelResumePreservesDraftHistoryAndSuggestionState() {
        let reader = TerminalInteractiveLineReader()
        let suggestions = [
            TerminalCommandSuggestion(command: "/one", summary: "one"),
            TerminalCommandSuggestion(command: "/two", summary: "two"),
            TerminalCommandSuggestion(command: "/three", summary: "three")
        ]
        reader.withPanelLock { state in
            state.panelBuffer = Array("unfinished prompt")
            state.panelCursorIndex = 4
            state.historyIndex = 1
            state.draftBeforeHistory = Array("original draft")
            state.panelCommandSuggestions = suggestions
            state.panelCommandSuggestionIndex = 2
        }

        reader.finishPanelStop(clearPanel: false)

        let prepared = reader.preparePanelForStart(
            statusBar: TerminalStatusBar(isEnabled: false),
            commandSuggestions: suggestions,
            preservingState: true
        )

        #expect(prepared == .admitted)
        #expect(reader.withPanelLock { String($0.panelBuffer) } == "unfinished prompt")
        #expect(reader.withPanelLock { $0.panelCursorIndex } == 4)
        #expect(reader.withPanelLock { $0.historyIndex } == 1)
        #expect(reader.withPanelLock { String($0.draftBeforeHistory) } == "original draft")
        #expect(reader.withPanelLock { $0.panelCommandSuggestionIndex } == 2)
    }
}
