//
//  TerminalCheckboxMenuRenderingTests.swift
//  ZenCODE
//

import Testing
@testable import ZenCODECore

@Suite
struct TerminalCheckboxMenuRenderingTests {
    @Test
    func clearFrameSequenceClearsOnlyMenuRowsAndKeepsCursorInsideFrame() {
        let frame = TerminalCheckboxMenu.RenderedFrame(row: 10, height: 3)

        let sequence = TerminalCheckboxMenu.clearFrameSequence(
            frame: frame,
            terminalRows: 24
        )

        #expect(
            sequence == "\u{1B}[10;1H\u{1B}[2K"
                + "\u{1B}[11;1H\u{1B}[2K"
                + "\u{1B}[12;1H\u{1B}[2K"
                + "\u{1B}[12;1H"
        )
        #expect(!sequence.contains("\u{1B}[J"))
        #expect(!sequence.contains("\u{1B}[13;1H"))
    }
}
