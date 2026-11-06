//
//  RemoteGenerationRoundTextTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 06/11/26.
//

import Testing
@testable import ZenCODECore

@Suite
struct RemoteGenerationRoundTextTests {
    @Test
    func emptyAccumulatedTextAppendsRoundTextAsIs() {
        var text = ""
        RemoteGenerationClient.appendRoundText("Hello", to: &text)
        #expect(text == "Hello")
    }

    @Test
    func emptyRoundTextLeavesAccumulatedTextUnchanged() {
        var text = "Hello"
        RemoteGenerationClient.appendRoundText("", to: &text)
        #expect(text == "Hello")

        var empty = ""
        RemoteGenerationClient.appendRoundText("", to: &empty)
        #expect(empty.isEmpty)
    }

    @Test
    func gluedRoundsAreSeparatedByLineBreak() {
        var text = "A."
        RemoteGenerationClient.appendRoundText("## B", to: &text)
        #expect(text == "A.\n## B")
    }

    @Test
    func accumulatedTextEndingWithNewlineIsNotSeparatedAgain() {
        var text = "A.\n"
        RemoteGenerationClient.appendRoundText("## B", to: &text)
        #expect(text == "A.\n## B")
    }

    @Test
    func roundTextStartingWithNewlineIsNotSeparatedAgain() {
        var text = "A."
        RemoteGenerationClient.appendRoundText("\n## B", to: &text)
        #expect(text == "A.\n## B")
    }

    @Test
    func accumulatedTextEndingWithCRLFIsNotSeparatedAgain() {
        var text = "A.\r\n"
        RemoteGenerationClient.appendRoundText("## B", to: &text)
        #expect(text == "A.\r\n## B")
    }

    @Test
    func threeConsecutiveRoundsAreEachSeparated() {
        var text = ""
        RemoteGenerationClient.appendRoundText("One.", to: &text)
        RemoteGenerationClient.appendRoundText("Two.", to: &text)
        RemoteGenerationClient.appendRoundText("Three.", to: &text)
        #expect(text == "One.\nTwo.\nThree.")
    }
}
