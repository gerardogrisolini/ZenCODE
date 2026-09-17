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
    func catalogueHasStableLowercaseAndExplicitUppercaseVariants() {
        let expected: [(Character, String, Character, String)] = [
            ("a", "àáâäæãåā", "A", "ÀÁÂÄÆÃÅĀ"),
            ("e", "èéêëēėę", "E", "ÈÉÊËĒĖĘ"),
            ("i", "ìíîïīį", "I", "ÌÍÎÏĪĮ"),
            ("o", "òóôöœøōõ", "O", "ÒÓÔÖŒØŌÕ"),
            ("u", "ùúûüū", "U", "ÙÚÛÜŪ"),
            ("c", "çćč", "C", "ÇĆČ"),
            ("n", "ñń", "N", "ÑŃ"),
            ("s", "ßśš", "S", "ẞŚŠ"),
            ("y", "ýÿ", "Y", "ÝŸ"),
            ("z", "žźż", "Z", "ŽŹŻ")
        ]

        for (lowercase, lowercaseVariants, uppercase, uppercaseVariants) in expected {
            #expect(TerminalPressAndHold.variants(for: lowercase) == Array(lowercaseVariants))
            #expect(TerminalPressAndHold.variants(for: uppercase) == Array(uppercaseVariants))
        }
        #expect(TerminalPressAndHold.variants(for: "b") == nil)
        #expect(TerminalPressAndHold.supportedBases.count == 20)
        #expect(Set(TerminalPressAndHold.supportedBases).count == 20)
        #expect(expected.allSatisfy { entry in
            (TerminalPressAndHold.variants(for: entry.0)?.count ?? 0) <= 8
                && (TerminalPressAndHold.variants(for: entry.2)?.count ?? 0) <= 8
        })
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
    func thresholdBoundariesAreInclusiveAndOutsideValuesDoNotTrigger() {
        #expect(editorAfterTyping(at: [0, 250, 300, 350, 450]).pressAndHoldMenu != nil)
        #expect(editorAfterTyping(at: [0, 249, 299, 349, 449]).pressAndHoldMenu == nil)
        #expect(editorAfterTyping(at: [0, 1_500, 1_510, 1_520, 1_530]).pressAndHoldMenu != nil)
        #expect(editorAfterTyping(at: [0, 1_501, 1_511, 1_521, 1_531]).pressAndHoldMenu == nil)

        #expect(editorAfterTyping(at: [0, 500, 508, 516, 524]).pressAndHoldMenu != nil)
        #expect(editorAfterTyping(at: [0, 500, 507, 515, 523]).pressAndHoldMenu == nil)
        #expect(editorAfterTyping(at: [0, 500, 650, 800, 950]).pressAndHoldMenu != nil)
        #expect(editorAfterTyping(at: [0, 500, 651, 801, 951]).pressAndHoldMenu == nil)

        #expect(editorAfterTyping(at: [0, 250, 300, 350, 449]).pressAndHoldMenu == nil)
        #expect(editorAfterTyping(at: [0, 250, 300, 350, 450]).pressAndHoldMenu != nil)
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
    func invalidIntervalRestartsAtTheLatestCharacterWithoutLosingPreviousText() {
        let editor = editorAfterTyping(at: [0, 200, 500, 550, 600, 650])
        #expect(editor.pressAndHoldMenu != nil)
        // The first event is outside the candidate that restarted at 200 ms.
        #expect(String(editor.buffer) == "aa")
        #expect(editor.pressAndHoldMenu?.replacementIndex == 1)
    }

    @Test
    func earlierDuplicatesSuffixAndGraphemeIndicesRemainUntouched() {
        let prefix = "aa 🙂e\u{301}\n"
        let initial = prefix + "TAIL"
        let insertionIndex = Array(prefix).count
        let editor = openMenu(
            initialText: initial,
            cursorIndex: insertionIndex
        )

        #expect(String(editor.buffer) == prefix + "aTAIL")
        #expect(editor.cursorIndex == insertionIndex + 1)
        #expect(editor.pressAndHoldMenu?.replacementIndex == insertionIndex)
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
    func differentInputEndsResidualSuppressionWithoutBlockingLaterLetters() {
        var editor = openMenu()
        #expect(editor.apply(.cancel, context: context, timestampMilliseconds: 700) == .changed)
        #expect(editor.apply(.character("b"), context: context, timestampMilliseconds: 710) == .changed)
        #expect(editor.apply(.character("a"), context: context, timestampMilliseconds: 720) == .changed)
        #expect(String(editor.buffer) == "aba")
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
