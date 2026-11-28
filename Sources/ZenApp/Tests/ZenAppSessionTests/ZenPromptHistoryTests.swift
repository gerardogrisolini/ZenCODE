//
//  ZenPromptHistoryTests.swift
//  ZenAppSessionTests
//

import Foundation
import Testing
@testable import ZenAppSession

@Suite
struct ZenPromptHistoryTests {
    @Test("Recording trims, skips blanks and repeats in a row")
    func recording() {
        var history = ZenPromptHistory()
        history.record("  one ")
        history.record("")
        history.record("one")
        history.record("two")
        history.record("one")
        #expect(history.entries == ["one", "two", "one"])
    }

    @Test("↑ walks back from the newest entry, ↓ walks forward and gives the draft back")
    func navigation() {
        var history = ZenPromptHistory(entries: ["a", "b", "c"])
        #expect(history.recallNext(currentDraft: "draft") == nil)
        #expect(history.recallPrevious(currentDraft: "draft") == "c")
        #expect(history.recallPrevious(currentDraft: "c") == "b")
        #expect(history.recallPrevious(currentDraft: "b") == "a")
        // Nothing older: nothing changes.
        #expect(history.recallPrevious(currentDraft: "a") == nil)
        #expect(history.recallNext(currentDraft: "a") == "b")
        #expect(history.recallNext(currentDraft: "b") == "c")
        #expect(history.recallNext(currentDraft: "c") == "draft")
        #expect(history.index == nil)
        #expect(history.recallNext(currentDraft: "draft") == nil)
    }

    @Test("Editing a recalled entry ends the recall")
    func editingEndsRecall() {
        var history = ZenPromptHistory(entries: ["a", "b"])
        #expect(history.recallPrevious(currentDraft: "") == "b")
        // The operator edited "b": ↓ changes nothing, ↑ starts over from the newest.
        #expect(history.recallNext(currentDraft: "b!") == nil)
        #expect(history.recallPrevious(currentDraft: "b!") == "b")
        #expect(history.recallNext(currentDraft: "b") == "b!")
    }

    @Test("An empty history recalls nothing")
    func emptyHistory() {
        var history = ZenPromptHistory()
        #expect(history.recallPrevious(currentDraft: "x") == nil)
        #expect(history.recallNext(currentDraft: "x") == nil)
    }
}
