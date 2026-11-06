//
//  ZenVoiceDictationDraftTests.swift
//  ZenAppSessionTests
//
//  The dictation previewed at the end of a window's draft, as a pure value:
//  the preview after the typed text, its live updates, the send that takes
//  the whole draft, an edit that ends it, the removal on a stop, the ids
//  already ended, and where the composer's cursor goes.
//

import Testing
@testable import ZenAppSession

@Suite("Voice dictation draft")
struct ZenVoiceDictationDraftTests {
    @Test("The preview goes after the typed text, with one space when needed, and follows the speech")
    func previewAfterTypedText() {
        var dictation = ZenVoiceDictationDraft()
        var draft = "Nota:"
        #expect(dictation.show(id: 1, text: "ciao", in: &draft) == .started)
        #expect(draft == "Nota: ciao")
        #expect(dictation.preview == .init(id: 1, start: 6, insertedSeparator: true))
        #expect(dictation.previewRange(in: draft) == 6..<10)

        #expect(dictation.show(id: 1, text: "ciao mondo", in: &draft) == .updated(previewStart: 6))
        #expect(draft == "Nota: ciao mondo")
        // The same text again changes nothing.
        #expect(dictation.show(id: 1, text: "ciao mondo", in: &draft) == nil)

        // A draft that ends in whitespace gets no separator.
        var spaced = ZenVoiceDictationDraft()
        var typed = "@reviewer "
        #expect(spaced.show(id: 1, text: "controlla", in: &typed) == .started)
        #expect(typed == "@reviewer controlla")
        #expect(spaced.preview?.insertedSeparator == false)

        // An empty draft too.
        var empty = ZenVoiceDictationDraft()
        var blank = ""
        #expect(empty.show(id: 1, text: "ciao", in: &blank) == .started)
        #expect(blank == "ciao")
        #expect(empty.previewRange(in: blank) == 0..<4)
    }

    @Test("An empty preview removes the dictation and its separator; the typed text stays")
    func emptyPreviewRemoves() {
        var dictation = ZenVoiceDictationDraft()
        var draft = "Nota:"
        _ = dictation.show(id: 1, text: "ciao", in: &draft)
        #expect(dictation.show(id: 1, text: "", in: &draft) == .removed)
        #expect(draft == "Nota:")
        #expect(!dictation.isActive)
        #expect(dictation.show(id: 1, text: "", in: &draft) == nil)
    }

    @Test("Take returns the whole visible draft, typed text then the final words, and clears it")
    func takeReturnsTheWholeDraft() {
        var dictation = ZenVoiceDictationDraft()
        var draft = "Nota:"
        _ = dictation.show(id: 1, text: "ciao", in: &draft)
        #expect(dictation.take(id: 1, text: "ciao mondo", from: &draft) == "Nota: ciao mondo")
        #expect(draft.isEmpty)
        #expect(!dictation.isActive)
        #expect(dictation.endedThrough == 1)
        // The same dictation is never sent twice.
        #expect(dictation.take(id: 1, text: "ciao", from: &draft) == nil)

        // Without a preview (the keyword said alone), the typed text goes.
        var keyword = ZenVoiceDictationDraft(endedThrough: 1)
        var typed = "Controlla il diff"
        #expect(keyword.take(id: 2, text: "", from: &typed) == "Controlla il diff")
        #expect(typed.isEmpty)
        // A draft that ends in whitespace gets no extra space.
        var spaced = ZenVoiceDictationDraft()
        var mention = "@reviewer "
        #expect(spaced.take(id: 1, text: "controlla", from: &mention) == "@reviewer controlla")
        // Nothing at all: empty.
        var none = ZenVoiceDictationDraft()
        var nothing = ""
        #expect(none.take(id: 1, text: "", from: &nothing) == "")
    }

    @Test("Ending the dictation keeps its words as text and ignores its later previews and sends")
    func endKeepsTheText() {
        var dictation = ZenVoiceDictationDraft()
        var draft = "Nota:"
        _ = dictation.show(id: 3, text: "ciao", in: &draft)
        #expect(dictation.end() == 3)
        #expect(draft == "Nota: ciao")
        #expect(dictation.end() == nil)
        // Late previews and sends of dictation 3 are dropped.
        #expect(dictation.show(id: 3, text: "ciao mondo", in: &draft) == nil)
        #expect(dictation.take(id: 3, text: "ciao mondo", from: &draft) == nil)
        #expect(draft == "Nota: ciao")
        // The next dictation is appended after it.
        #expect(dictation.show(id: 4, text: "di nuovo", in: &draft) == .started)
        #expect(draft == "Nota: ciao di nuovo")
    }

    @Test("Removing the dictation (pause, off, another window) keeps the typed text and ignores its id")
    func removeKeepsTypedText() {
        var dictation = ZenVoiceDictationDraft()
        var draft = "Nota:"
        _ = dictation.show(id: 2, text: "ciao", in: &draft)
        let removed = dictation.remove(from: &draft)
        #expect(removed)
        #expect(draft == "Nota:")
        #expect(dictation.endedThrough == 2)
        let removedAgain = dictation.remove(from: &draft)
        #expect(!removedAgain)
        #expect(dictation.show(id: 2, text: "ciao", in: &draft) == nil)
    }

    @Test("An older dictation than the one shown, or one already ended, is ignored")
    func staleIDsAreIgnored() {
        var dictation = ZenVoiceDictationDraft(endedThrough: 5)
        var draft = ""
        #expect(dictation.show(id: 5, text: "vecchio", in: &draft) == nil)
        #expect(draft.isEmpty)
        #expect(dictation.show(id: 7, text: "nuovo", in: &draft) == .started)
        #expect(dictation.show(id: 6, text: "vecchio", in: &draft) == nil)
        #expect(dictation.take(id: 6, text: "vecchio", from: &draft) == nil)
        #expect(draft == "nuovo")
    }

    @Test("The cursor follows the dictation as in the terminal")
    func cursorFollowsTheDictation() {
        // A new preview moves the cursor to the end.
        #expect(ZenVoiceDictationDraft.cursor(2, after: .started, draftCount: 10) == 10)
        // An update moves it only from inside the preview.
        #expect(ZenVoiceDictationDraft.cursor(8, after: .updated(previewStart: 6), draftCount: 16) == 16)
        #expect(ZenVoiceDictationDraft.cursor(6, after: .updated(previewStart: 6), draftCount: 16) == 16)
        #expect(ZenVoiceDictationDraft.cursor(3, after: .updated(previewStart: 6), draftCount: 16) == 3)
        // A removal clamps it; a take empties the draft.
        #expect(ZenVoiceDictationDraft.cursor(9, after: .removed, draftCount: 5) == 5)
        #expect(ZenVoiceDictationDraft.cursor(2, after: .removed, draftCount: 5) == 2)
        #expect(ZenVoiceDictationDraft.cursor(9, after: .taken, draftCount: 0) == 0)
    }
}
