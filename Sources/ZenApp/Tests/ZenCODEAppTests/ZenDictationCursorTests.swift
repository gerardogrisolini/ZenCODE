//
//  ZenDictationCursorTests.swift
//  ZenApp
//
//  Where a window's composer puts its cursor after voice mode's dictation
//  changed the draft (`ZenDictationCursor`): the terminal's rule for the
//  latest change, and a preview that started between two renders.
//

import Foundation
import Testing
import ZenAppControls
import ZenAppSession

@testable import ZenCODEApp

@Suite("Dictation cursor")
struct ZenDictationCursorTests {
    private func update(_ revision: Int, _ previewID: UInt64?) -> ZenComposerDraftUpdate {
        ZenComposerDraftUpdate(revision: revision, regionID: previewID)
    }

    @Test("one change per render: the terminal's rule for it")
    func oneChangePerRender() {
        // "hello" typed, the preview "world" starts after a separator: the
        // draft is "hello world", the preview starts at 6.
        #expect(ZenDictationCursor.cursor(5, from: update(0, nil), to: update(1, 1), latest: .started, draftCount: 11) == 11)
        // An update: a cursor inside the preview follows its end...
        #expect(
            ZenDictationCursor.cursor(11, from: update(1, 1), to: update(2, 1), latest: .updated(previewStart: 6), draftCount: 15)
                == 15
        )
        // ...one moved back into the typed text stays.
        #expect(
            ZenDictationCursor.cursor(2, from: update(1, 1), to: update(2, 1), latest: .updated(previewStart: 6), draftCount: 15)
                == 2
        )
        // Removed: clamped to the typed text; taken: the start of the empty draft.
        #expect(ZenDictationCursor.cursor(15, from: update(2, 1), to: update(3, nil), latest: .removed, draftCount: 5) == 5)
        #expect(ZenDictationCursor.cursor(15, from: update(2, 1), to: update(3, nil), latest: .taken, draftCount: 0) == 0)
    }

    @Test("a start and an update seen in one render: the preview is new, so the cursor goes to the end")
    func startAndUpdateInOneRender() {
        // Seen alone, the update would leave the cursor before the inserted
        // separator, outside the preview for good.
        #expect(
            ZenDictationCursor.cursor(5, from: update(1, 1), to: update(2, 1), latest: .updated(previewStart: 6), draftCount: 15)
                == 5
        )
        // The revision grew by two and the preview was not shown before.
        #expect(
            ZenDictationCursor.change(from: update(0, nil), to: update(2, 1), latest: .updated(previewStart: 6)) == .started
        )
        #expect(
            ZenDictationCursor.cursor(5, from: update(0, nil), to: update(2, 1), latest: .updated(previewStart: 6), draftCount: 15)
                == 15
        )
        // Another dictation than the one shown before is new too.
        #expect(
            ZenDictationCursor.cursor(5, from: update(3, 1), to: update(6, 2), latest: .updated(previewStart: 6), draftCount: 15)
                == 15
        )
    }

    @Test("several changes of the same preview in one render: the latest change's rule")
    func samePreviewInOneRender() {
        #expect(
            ZenDictationCursor.change(from: update(1, 1), to: update(4, 1), latest: .updated(previewStart: 6))
                == .updated(previewStart: 6)
        )
        #expect(
            ZenDictationCursor.cursor(2, from: update(1, 1), to: update(4, 1), latest: .updated(previewStart: 6), draftCount: 20)
                == 2
        )
        #expect(
            ZenDictationCursor.cursor(9, from: update(1, 1), to: update(4, 1), latest: .updated(previewStart: 6), draftCount: 20)
                == 20
        )
    }

    @Test("several changes ending without a preview: the latest change's rule")
    func endingWithoutPreview() {
        #expect(ZenDictationCursor.change(from: update(0, nil), to: update(3, nil), latest: .removed) == .removed)
        #expect(ZenDictationCursor.cursor(12, from: update(0, nil), to: update(3, nil), latest: .removed, draftCount: 4) == 4)
        #expect(ZenDictationCursor.change(from: update(1, 1), to: update(3, nil), latest: .taken) == .taken)
        #expect(ZenDictationCursor.cursor(12, from: update(1, 1), to: update(3, nil), latest: .taken, draftCount: 0) == 0)
    }

    @Test("without a latest change the cursor stays, clamped")
    func noLatestChange() {
        #expect(ZenDictationCursor.cursor(8, from: update(0, nil), to: update(1, nil), latest: nil, draftCount: 5) == 5)
        #expect(ZenDictationCursor.cursor(3, from: update(0, nil), to: update(1, nil), latest: nil, draftCount: 5) == 3)
    }
}
