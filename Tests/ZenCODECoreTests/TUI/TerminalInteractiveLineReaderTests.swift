//
//  TerminalInteractiveLineReaderTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Synchronization
import Testing
@testable import ZenCODECore

@Suite
struct TerminalInteractiveLineReaderTests {
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
            cursorIndex: 6
        )

        #expect(sequence == "\r\u{1B}[2KFeature id: github")
        #expect(!sequence.hasPrefix("\n"))
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

        #expect(reader.keyFromCSI(Array("97;5u".utf8)) == .toggleAccessMode)
        #expect(reader.keyFromCSI(Array("27;5;97~".utf8)) == .toggleAccessMode)
        #expect(reader.keyFromCSI(Array("116;5u".utf8)) == .toggleToolDetails)
        #expect(reader.keyFromCSI(Array("27;5;116~".utf8)) == .toggleToolDetails)

        // An explicit Kitty press event and additional modifiers retain Control.
        #expect(reader.keyFromCSI(Array("97;5:1u".utf8)) == .toggleAccessMode)
        #expect(reader.keyFromCSI(Array("116;7u".utf8)) == .toggleToolDetails)
    }

    @Test
    func controlShortcutsRejectWrongModifiersAndKeyCodes() {
        let reader = TerminalInteractiveLineReader()

        #expect(reader.keyFromCSI(Array("97;2u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("27;3;97~".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("108;5u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("27;5;117~".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("97;5:2u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("97;5:3u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("97;5:4u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("97;5:u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("1;5;97~".utf8)) != .toggleAccessMode)
        #expect(reader.keyFromCSI(Array("27;5:1;97~".utf8)) == .unknown)

        #expect(reader.keyFromCSI(Array("103;5u".utf8)) == .unknown)
        #expect(reader.keyFromCSI(Array("109;5u".utf8)) == .unknown)
    }

    @Test
    func carriageReturnStillDecodesAsEnter() {
        let reader = TerminalInteractiveLineReader()

        #expect(TerminalInteractiveLineReader.controlKey(for: 0x0D) == .enter)
        #expect(reader.keyFromCSI(Array("13;5u".utf8)) == .enter)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x14) == .toggleToolDetails)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x01) == .toggleAccessMode)
        #expect(TerminalInteractiveLineReader.controlKey(for: 0x07) == nil)
    }

    @Test
    func accessModeToggleEventPreservesPanelTextAndCursor() async {
        let reader = TerminalInteractiveLineReader()
        reader.panelBuffer = Array("hello")
        reader.panelCursorIndex = 2
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
        #expect(String(reader.panelBuffer) == "hello")
        #expect(reader.panelCursorIndex == 2)
        #expect(reader.panelHelpTextLocked().contains("Ctrl+T tools · Ctrl+A access"))
        #expect(reader.panelCompactHelpTextLocked() == "Ctrl+T · Ctrl+A access")
    }

    @Test
    func redrawSequenceRestoresCursorPosition() {
        let sequence = TerminalInteractiveLineReader.redrawSequence(
            prompt: "Feature id: ",
            buffer: Array("github"),
            cursorIndex: 3
        )

        #expect(sequence == "\r\u{1B}[2KFeature id: github\u{1B}[3D")
    }

}
