//
//  TerminalPressAndHoldTests.swift
//  ZenCODE
//

import Testing
@testable import ZenCODECore

@Suite
struct TerminalPressAndHoldTests {
    private var context: TerminalPromptEditorContext {
        TerminalPromptEditorContext(supportsPressAndHold: true)
    }

    private func editorAfterTyping(
        _ base: Character = "a",
        at timestamps: [UInt64],
        initialText: String = "",
        cursorIndex: Int? = nil
    ) -> TerminalPromptEditor {
        var editor = TerminalPromptEditor()
        editor.buffer = Array(initialText)
        editor.cursorIndex = cursorIndex ?? editor.buffer.count
        for timestamp in timestamps {
            _ = editor.apply(
                .character(String(base)),
                context: context,
                timestampMilliseconds: timestamp
            )
        }
        return editor
    }

    private func openMenu(
        base: Character = "a",
        initialText: String = "",
        cursorIndex: Int? = nil
    ) -> TerminalPromptEditor {
        editorAfterTyping(
            base,
            at: [0, 500, 550, 600, 650],
            initialText: initialText,
            cursorIndex: cursorIndex
        )
    }

    @Test
    func confirmedRepeatCollapsesOnlyTheTrackedRunAndKeepsTheBase() {
        var editor = TerminalPromptEditor()
        let timestamps: [UInt64] = [0, 500, 550, 600, 650]
        for (index, timestamp) in timestamps.enumerated() {
            let effect = editor.apply(
                .character("a"),
                context: context,
                timestampMilliseconds: timestamp
            )
            #expect(effect == .changed)
            #expect(String(editor.buffer) == (index == 4 ? "a" : String(repeating: "a", count: index + 1)))
        }
        #expect(editor.cursorIndex == 1)
        #expect(editor.pressAndHoldMenu?.base == "a")
        #expect(editor.pressAndHoldMenu?.selectedVariant == "à")
    }

    @Test
    func waitsFastBurstsSlowRepeatsAndEqualTimestampsNeverOpenByThemselves() {
        var single = editorAfterTyping(at: [0])
        #expect(
            single.apply(
                .unknown,
                context: context,
                timestampMilliseconds: 10_000
            ) == .ignored
        )
        #expect(single.pressAndHoldMenu == nil)
        #expect(String(single.buffer) == "a")

        let fast = editorAfterTyping(at: [0, 40, 80])
        #expect(fast.pressAndHoldMenu == nil)
        #expect(String(fast.buffer) == "aaa")

        let slow = editorAfterTyping(at: [0, 500, 800, 1_100, 1_400])
        #expect(slow.pressAndHoldMenu == nil)
        #expect(String(slow.buffer) == "aaaaa")

        let simultaneous = editorAfterTyping(at: [100, 100, 100, 100, 100])
        #expect(simultaneous.pressAndHoldMenu == nil)
        #expect(String(simultaneous.buffer) == "aaaaa")
    }

    @Test
    func pasteNeverStartsDetectionAndPasteDuringMenuClosesItNormally() {
        var editor = TerminalPromptEditor()
        #expect(
            editor.apply(
                .paste("aaaaa"),
                context: context,
                timestampMilliseconds: 0
            ) == .changed
        )
        #expect(String(editor.buffer) == "aaaaa")
        #expect(editor.pressAndHoldMenu == nil)

        editor = openMenu()
        #expect(
            editor.apply(
                .paste("aa"),
                context: context,
                timestampMilliseconds: 700
            ) == .changed
        )
        #expect(String(editor.buffer) == "aaa")
        #expect(editor.pressAndHoldMenu == nil)
    }

    @Test
    func arrowsWrapNumbersChooseAndInvalidNumbersLeaveMenuOpen() {
        var editor = openMenu()
        #expect(editor.apply(.left, context: context, timestampMilliseconds: 700) == .changed)
        #expect(editor.pressAndHoldMenu?.selectedIndex == 7)
        #expect(editor.apply(.right, context: context, timestampMilliseconds: 710) == .changed)
        #expect(editor.pressAndHoldMenu?.selectedIndex == 0)
        #expect(editor.apply(.up, context: context, timestampMilliseconds: 720) == .changed)
        #expect(editor.pressAndHoldMenu?.selectedIndex == 7)
        #expect(editor.apply(.down, context: context, timestampMilliseconds: 730) == .changed)
        #expect(editor.pressAndHoldMenu?.selectedIndex == 0)

        #expect(editor.apply(.character("0"), context: context, timestampMilliseconds: 740) == .ignored)
        #expect(editor.apply(.character("9"), context: context, timestampMilliseconds: 750) == .ignored)
        #expect(editor.pressAndHoldMenu?.selectedIndex == 0)
        #expect(String(editor.buffer) == "a")

        #expect(editor.apply(.character("8"), context: context, timestampMilliseconds: 760) == .changed)
        #expect(String(editor.buffer) == "ā")
        #expect(editor.pressAndHoldMenu == nil)
    }

    @Test
    func enterChoosesWithoutSubmittingAndEscapeDismissesWithoutCancellingProcessing() {
        var editor = openMenu()
        let processing = TerminalPromptEditorContext(
            isProcessing: true,
            supportsPressAndHold: true
        )

        #expect(editor.apply(.enter, context: processing, timestampMilliseconds: 700) == .changed)
        #expect(String(editor.buffer) == "à")
        #expect(editor.pressAndHoldMenu == nil)

        editor = openMenu()
        #expect(editor.apply(.cancel, context: processing, timestampMilliseconds: 700) == .changed)
        #expect(String(editor.buffer) == "a")
        #expect(editor.pressAndHoldMenu == nil)
    }

    @Test
    func editingKeysCloseTheMenuAndRunExactlyOnce() {
        var editor = openMenu()
        #expect(editor.apply(.backspace, context: context, timestampMilliseconds: 700) == .changed)
        #expect(editor.buffer.isEmpty)
        #expect(editor.pressAndHoldMenu == nil)

        editor = openMenu()
        #expect(editor.apply(.unknown, context: context, timestampMilliseconds: 700) == .ignored)
        #expect(editor.pressAndHoldMenu != nil)
        #expect(String(editor.buffer) == "a")
    }

    @Test
    func residualRepeatSuppressionIsInvisibleAndExpiresLocally() {
        var editor = openMenu()
        #expect(
            editor.apply(
                .character("a"),
                context: context,
                timestampMilliseconds: 700
            ) == .ignored
        )
        #expect(String(editor.buffer) == "a")
        #expect(editor.pressAndHoldMenu != nil)

        #expect(editor.apply(.enter, context: context, timestampMilliseconds: 710) == .changed)
        #expect(String(editor.buffer) == "à")
        #expect(
            editor.apply(
                .character("a"),
                context: context,
                timestampMilliseconds: 800
            ) == .ignored
        )
        #expect(String(editor.buffer) == "à")

        #expect(
            editor.apply(
                .character("a"),
                context: context,
                timestampMilliseconds: 1_021
            ) == .changed
        )
        #expect(String(editor.buffer) == "àa")
    }

    @Test
    func disabledCapabilityOrMissingTimestampPreservesOrdinaryRepeatedTyping() {
        var editor = TerminalPromptEditor()
        let disabled = TerminalPromptEditorContext()
        for timestamp in [UInt64(0), 500, 550, 600, 650] {
            _ = editor.apply(
                .character("a"),
                context: disabled,
                timestampMilliseconds: timestamp
            )
        }
        #expect(String(editor.buffer) == "aaaaa")
        #expect(editor.pressAndHoldMenu == nil)

        editor = TerminalPromptEditor()
        for _ in 0..<5 {
            _ = editor.apply(.character("a"), context: context)
        }
        #expect(String(editor.buffer) == "aaaaa")
        #expect(editor.pressAndHoldMenu == nil)
    }
}
