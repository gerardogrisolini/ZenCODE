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

    /// The pull is scoped to mention editing: a slash-command draft must not
    /// query the shared-chat roster on every keystroke.
    @Test
    func slashCommandDraftDoesNotPullMentionSuggestions() async {
        let reader = TerminalInteractiveLineReader()
        await reader.setPanelCommandSuggestions([
            TerminalCommandSuggestion(command: "/help", summary: "help")
        ])
        let didCallProvider = Mutex(false)
        reader.setPanelMentionSuggestionsProvider {
            didCallProvider.withLock { $0 = true }
            return []
        }

        await reader.setPanelText("/he")
        await reader.refreshPanelMentionSuggestionsIfNeeded()

        #expect(didCallProvider.withLock { $0 } == false)
        let commands = reader.state.withLock { $0.panelCommandSuggestions.map(\.command) }
        #expect(commands == ["/help"])
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
    func commandSuggestionWindowBoundsOutOfRangeSelection() {
        let suggestions = (0..<4).map { index in
            TerminalCommandSuggestion(
                command: "/command\(index)",
                summary: "summary \(index)"
            )
        }

        #expect(
            TerminalInteractiveLineReader.visiblePanelCommandSuggestionWindow(
                suggestions: suggestions,
                selectedIndex: 99,
                maximumLineCount: 6
            ).map(\.index) == [0, 1, 2, 3]
        )
    }

    @Test
    func commandSuggestionsPreferExactCommandBeforePrefixMatches() {
        let suggestions = [
            TerminalCommandSuggestion(command: "/feature", summary: "create/manage features"),
            TerminalCommandSuggestion(command: "/featurex", summary: "another prefix match")
        ]

        let matches = TerminalInteractiveLineReader.matchingPanelCommandSuggestions(
            text: "/feature",
            cursorIndex: "/feature".count,
            suggestions: suggestions
        )

        #expect(matches.map(\.command) == ["/feature", "/featurex"])
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
        )

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
            ) == "\r\u{1B}[2K> one\r\ntwo\u{1B}[1A\r\u{1B}[5C"
        )
        #expect(
            TerminalInteractiveLineReader.redrawSequence(
                prompt: "> ",
                buffer: buffer,
                cursorIndex: 4,
                terminalColumns: 20
            ) == "\r\u{1B}[2K> one\r\ntwo\r"
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
            ) == "\r\u{1B}[2K>abc\r\ndef\u{1B}[1A\r\u{1B}[4C"
        )
        #expect(
            TerminalInteractiveLineReader.redrawSequence(
                prompt: ">",
                buffer: buffer,
                cursorIndex: 4,
                terminalColumns: 5
            ) == "\r\u{1B}[2K>abc\r\ndef\r\u{1B}[1C"
        )
    }

    @Test
    func redrawLayoutPreservesANSIPromptSequencesAsZeroWidthTokens() {
        let prompt = "\u{1B}[38;5;208m> \u{1B}[0m"
        let layout = TerminalInteractiveLineReader.renderLayout(
            prompt: prompt,
            buffer: Array("abcd"),
            cursorIndex: 2,
            terminalColumns: 5
        )

        // The visible prompt is two cells wide, so the first physical row can
        // contain exactly `> ab`. In particular, the renderer must not count
        // or split either ANSI sequence while inserting its CRLF.
        #expect(layout.text == "\u{1B}[38;5;208m> \u{1B}[0mab\r\ncd")
        #expect(layout.lineCount == 2)
        #expect(layout.cursorRow == 0)
        #expect(layout.cursorColumn == 4)
        #expect(
            TerminalInteractiveLineReader.redrawSequence(
                prompt: prompt,
                buffer: Array("abcd"),
                cursorIndex: 2,
                terminalColumns: 5
            ) == "\r\u{1B}[2K\u{1B}[38;5;208m> \u{1B}[0mab\r\ncd\u{1B}[1A\r\u{1B}[4C"
        )
    }

    @Test
    func redrawLayoutExpandsTabsAtDeterministicStops() {
        let buffer = Array("ab\tc")
        let layout = TerminalInteractiveLineReader.renderLayout(
            prompt: "",
            buffer: buffer,
            cursorIndex: 3,
            terminalColumns: 9
        )

        // At column two, a tab advances six cells to the next eight-cell tab
        // stop. The following character therefore wraps deterministically.
        #expect(layout.text == "ab      \r\nc")
        #expect(layout.lineCount == 2)
        #expect(layout.cursorRow == 0)
        #expect(layout.cursorColumn == 8)
        #expect(
            TerminalInteractiveLineReader.redrawSequence(
                prompt: "",
                buffer: buffer,
                cursorIndex: 3,
                terminalColumns: 9
            ) == "\r\u{1B}[2Kab      \r\nc\u{1B}[1A\r\u{1B}[8C"
        )
    }

    @Test
    func redrawClearsPreviousFootprintWhenDraftShrinks() {
        #expect(
            TerminalInteractiveLineReader.lineCount(
                for: Array("abcde"),
                terminalColumns: 5
            ) == 2
        )
        #expect(
            TerminalInteractiveLineReader.lineCount(
                for: Array("abc"),
                terminalColumns: 5
            ) == 1
        )
        #expect(
            TerminalInteractiveLineReader.redrawSequence(
                prompt: "",
                buffer: Array("x"),
                cursorIndex: 1,
                previousLineCount: 3,
                previousCursorRow: 2,
                terminalColumns: 5
            ) == "\r\u{1B}[2A\u{1B}[0Jx"
        )
    }

    @Test
    func homeAndEndStayWithinCurrentLogicalLine() {
        let buffer = Array("first\nsecond\nthird")

        #expect(
            TerminalInteractiveLineReader.homeCursorIndex(
                in: buffer,
                cursorIndex: 8
            ) == 6
        )
        #expect(
            TerminalInteractiveLineReader.endCursorIndex(
                in: buffer,
                cursorIndex: 8
            ) == 12
        )
        #expect(
            TerminalInteractiveLineReader.homeCursorIndex(
                in: buffer,
                cursorIndex: 12
            ) == 6
        )
        #expect(
            TerminalInteractiveLineReader.endCursorIndex(
                in: buffer,
                cursorIndex: 14
            ) == buffer.count
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
        // Alt+Enter (bits 0b10) also inserts a newline, consistent with the
        // legacy ESC+CR (Option+Enter) fallback.
        #expect(
            TerminalInteractiveLineReader.shiftReturnKey(
                components: ["13", "3"],
                keyCodeIndex: 0,
                modifierIndex: 1
            ) == .newline
        )
    }

    @Test
    func shiftReturnKeyDecodesModifyOtherKeysSequence() {
        // xterm modifyOtherKeys: CSI 27;2;13~ (Shift+Enter).
        #expect(
            TerminalInteractiveLineReader.shiftReturnKey(
                components: ["27", "2", "13"],
                keyCodeIndex: 2,
                modifierIndex: 1
            ) == .newline
        )
        // CSI 27;1;13~ (Enter without modifiers).
        #expect(
            TerminalInteractiveLineReader.shiftReturnKey(
                components: ["27", "1", "13"],
                keyCodeIndex: 2,
                modifierIndex: 1
            ) == .enter
        )
    }

    @Test
    func shiftReturnKeyIgnoresNonReturnKeyCodes() {
        #expect(
            TerminalInteractiveLineReader.shiftReturnKey(
                components: ["97", "2"],
                keyCodeIndex: 0,
                modifierIndex: 1
            ) == nil
        )
        #expect(
            TerminalInteractiveLineReader.shiftReturnKey(
                components: [],
                keyCodeIndex: 0,
                modifierIndex: 1
            ) == nil
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
        #expect(reader.keyFromCSI(Array("116;5u".utf8)) == .toggleToolDetails)
        #expect(reader.keyFromCSI(Array("27;5;116~".utf8)) == .toggleToolDetails)

        // Readline motion shortcuts distinguish Control from Alt.
        #expect(reader.keyFromCSI(Array("98;5u".utf8)) == .left)
        #expect(reader.keyFromCSI(Array("98;3u".utf8)) == .wordLeft)
        #expect(reader.keyFromCSI(Array("102;5u".utf8)) == .right)
        #expect(reader.keyFromCSI(Array("102;3u".utf8)) == .wordRight)
        #expect(reader.keyFromCSI(Array("112;5u".utf8)) == .up)
        #expect(reader.keyFromCSI(Array("110;5u".utf8)) == .down)
        #expect(reader.keyFromCSI(Array("60;3u".utf8)) == .bufferStart)
        #expect(reader.keyFromCSI(Array("62;3u".utf8)) == .bufferEnd)

        // An explicit Kitty press event and additional modifiers retain Control.
        #expect(reader.keyFromCSI(Array("97;5:1u".utf8)) == .home)
        #expect(reader.keyFromCSI(Array("116;7u".utf8)) == .toggleToolDetails)
    }

    @Test
    func controlShortcutsRejectWrongModifiersAndKeyCodes() {
        let reader = TerminalInteractiveLineReader()

        #expect(reader.keyFromCSI(Array("97;2u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("27;3;97~".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("108;5u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("27;5;113~".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("97;5:2u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("97;5:3u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("97;5:4u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("97;5:u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("1;5;97~".utf8)) == .bufferStart)
        #expect(reader.keyFromCSI(Array("27;5:1;97~".utf8)) == .unknown)

        #expect(reader.keyFromCSI(Array("104;5u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("109;5u".utf8)) == .unknown)
    }

    @Test
    func carriageReturnStillDecodesAsEnter() {
        let reader = TerminalInteractiveLineReader()

        #expect(TerminalInteractiveLineReader.controlKey(for: 0x0D) == .enter)
        #expect(reader.keyFromCSI(Array("13;5u".utf8)) == .enter)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x14) == .toggleToolDetails)
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
        #expect(decode([0x1B, 0x1B, 0x5B, 0x33, 0x7E]) == .deleteWordAfter)

        // Readline draft-wide motion, reachable without Home/End keys.
        #expect(decode([0x1B, 0x3C]) == .bufferStart)
        #expect(decode([0x1B, 0x3E]) == .bufferEnd)

        pipe.fileHandleForWriting.closeFile()
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
            reader.panelHelpTextLocked(state: $0).contains("Ctrl+T tools · Ctrl+G access")
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

    @Test
    func redrawSequenceRestoresCursorPosition() {
        let sequence = TerminalInteractiveLineReader.redrawSequence(
            prompt: "Feature id: ",
            buffer: Array("github"),
            cursorIndex: 3,
            terminalColumns: 80
        )

        #expect(sequence == "\r\u{1B}[2KFeature id: github\r\u{1B}[15C")
    }

    @Test
    func lineCountCountsExplicitNewlines() {
        #expect(TerminalInteractiveLineReader.lineCount(for: Array("")) == 1)
        #expect(TerminalInteractiveLineReader.lineCount(for: Array("single line")) == 1)
        #expect(TerminalInteractiveLineReader.lineCount(for: Array("one\ntwo")) == 2)
        #expect(TerminalInteractiveLineReader.lineCount(for: Array("a\nb\nc")) == 3)
        #expect(TerminalInteractiveLineReader.lineCount(for: Array("\ntwo")) == 2)
    }

    @Test
    func redrawSequenceClearsMultipleRowsForMultilineBuffer() {
        // After a newline was inserted the previous render spanned two rows.
        // The redraw must move up one row and erase to the end of the display
        // before reprinting, so earlier rows do not accumulate on screen.
        let sequence = TerminalInteractiveLineReader.redrawSequence(
            prompt: "Goal: ",
            buffer: Array("line one\nline two"),
            cursorIndex: 17,
            previousLineCount: 2,
            previousCursorRow: 1,
            terminalColumns: 80
        )

        #expect(sequence == "\r\u{1B}[1A\u{1B}[0JGoal: line one\r\nline two")
    }

    @Test
    func redrawSequenceClearsThreeRowsForGrowingMultilineBuffer() {
        let sequence = TerminalInteractiveLineReader.redrawSequence(
            prompt: "Goal: ",
            buffer: Array("a\nb\nc"),
            cursorIndex: 5,
            previousLineCount: 3,
            previousCursorRow: 2,
            terminalColumns: 80
        )

        #expect(sequence == "\r\u{1B}[2A\u{1B}[0JGoal: a\r\nb\r\nc")
    }

    @Test
    func redrawSequenceShrinksBackToSingleRow() {
        // When the newline is deleted the buffer is single-line again, but the
        // previous render still spanned two rows; the redraw must clear both.
        let sequence = TerminalInteractiveLineReader.redrawSequence(
            prompt: "Goal: ",
            buffer: Array("no newline"),
            cursorIndex: 10,
            previousLineCount: 2,
            previousCursorRow: 1,
            terminalColumns: 80
        )

        #expect(sequence == "\r\u{1B}[1A\u{1B}[0JGoal: no newline")
    }

}
