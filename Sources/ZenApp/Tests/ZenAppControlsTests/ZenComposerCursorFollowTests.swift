//
//  ZenComposerCursorFollowTests.swift
//  ZenApp
//
//  The composer's cursor after the owner changed the draft itself (the
//  app's voice dictation): the selection in characters, how it follows the
//  owner's rule, and the string indices of character offsets, which the
//  field maps to UTF-16.
//

import Foundation
import SwiftUI
import Testing

@testable import ZenAppControls

@Suite("Composer cursor after an owner's change")
struct ZenComposerCursorFollowTests {
    @Test("the selection in characters: an insertion point, a range, none, or one left from another draft")
    func selectionOffsets() {
        let text = "ciao 👍🏽 café"
        let cursor = text.index(text.startIndex, offsetBy: 6)
        #expect(ZenComposerLogic.selectionOffsets(in: text, selection: cursor..<cursor) == 6..<6)
        let start = text.index(text.startIndex, offsetBy: 5)
        let end = text.endIndex
        #expect(ZenComposerLogic.selectionOffsets(in: text, selection: start..<end) == 5..<11)
        #expect(ZenComposerLogic.selectionOffsets(in: text, selection: nil) == nil)
        let longer = text + " and more"
        #expect(ZenComposerLogic.selectionOffsets(in: text, selection: longer.endIndex..<longer.endIndex) == nil)
    }

    @Test("the cursor goes where the owner puts it, clamped to the draft")
    func cursorMoves() {
        // To the end of the grown draft.
        #expect(ZenComposerLogic.followedSelection(4..<4, previousDraftCount: 4, draftCount: 10) { _ in 10 } == 10..<10)
        // Clamped to the draft.
        #expect(ZenComposerLogic.followedSelection(4..<4, previousDraftCount: 4, draftCount: 3) { _ in 20 } == 3..<3)
        #expect(ZenComposerLogic.followedSelection(4..<4, previousDraftCount: 4, draftCount: 3) { _ in -1 } == 0..<0)
    }

    @Test("without a selection the cursor moves from the end of the draft before the change")
    func noSelectionIsTheEnd() {
        var seen: Int?
        let followed = ZenComposerLogic.followedSelection(nil, previousDraftCount: 7, draftCount: 12) { cursor in
            seen = cursor
            return 12
        }
        #expect(seen == 7)
        #expect(followed == 12..<12)
    }

    @Test("a selection the owner leaves in place stays whole; one it moves collapses at the new cursor")
    func selectionStaysOrCollapses() {
        // The owner leaves the cursor (the selection's end) where it was.
        #expect(ZenComposerLogic.followedSelection(1..<3, previousDraftCount: 8, draftCount: 12) { $0 } == 1..<3)
        // The owner moves it: an insertion point at the new cursor.
        #expect(ZenComposerLogic.followedSelection(5..<8, previousDraftCount: 8, draftCount: 12) { _ in 12 } == 12..<12)
    }

    @Test("character offsets become string indices: an emoji or an accented letter is one character")
    func characterOffsetsToIndices() {
        // "e" + U+0301 is one character of two UTF-16 units; 👍🏽 one of four.
        let text = "cafe\u{301} 👍🏽 ok"
        #expect(text.count == 9)
        let afterAccent = ZenComposerLogic.index(in: text, characterOffset: 4)
        #expect(text.utf16.distance(from: text.startIndex, to: afterAccent) == 5)
        let afterEmoji = ZenComposerLogic.index(in: text, characterOffset: 6)
        #expect(text.utf16.distance(from: text.startIndex, to: afterEmoji) == 10)
        #expect(text[afterEmoji...] == " ok")
        // Clamped to the text.
        #expect(ZenComposerLogic.index(in: text, characterOffset: 50) == text.endIndex)
        #expect(ZenComposerLogic.index(in: text, characterOffset: -2) == text.startIndex)
    }

    @Test("the field's selection of character offsets: an insertion point or a range")
    func textSelection() {
        let text = "è 👍🏽 ok"
        let point = ZenComposerLogic.textSelection(2..<2, in: text)
        #expect(point.indices == .selection(text.index(text.startIndex, offsetBy: 2)..<text.index(text.startIndex, offsetBy: 2)))
        let range = ZenComposerLogic.textSelection(2..<3, in: text)
        let lower = text.index(text.startIndex, offsetBy: 2)
        let upper = text.index(text.startIndex, offsetBy: 3)
        #expect(range.indices == .selection(lower..<upper))
        #expect(String(text[lower..<upper]) == "👍🏽")
    }
}
