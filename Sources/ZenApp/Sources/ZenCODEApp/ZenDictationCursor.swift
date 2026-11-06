//
//  ZenDictationCursor.swift
//  ZenApp
//
//  Where the composer's cursor goes after voice mode's dictation changed a
//  window's draft: the terminal's rule, also when the composer saw several
//  changes in one render.
//

import Foundation
import ZenAppControls
import ZenAppSession

/// The cursor of a window's composer after the voice dictation changed its
/// draft (``ZenWindowSession/voiceDictationUpdate``).
///
/// The rule is the terminal's (``ZenVoiceDictationDraft/cursor(_:after:draftCount:)``)
/// for the latest change: the cursor goes to the end when a preview starts,
/// follows the end of the preview when it was inside it, and otherwise stays.
/// The composer sees the draft once per render, though, and the window may
/// change it more than once in between: when the revision grew by more than
/// one and the dictation shown is new since the previous render (absent then,
/// or another one), a preview started meanwhile, and the cursor goes to the
/// end as after ``ZenVoiceDictationDraft/Change/started``, whatever the
/// latest change.
enum ZenDictationCursor {
    /// The change to apply for the move from `previous` to `current`, the
    /// updates the composer saw at two renders; `latest` is the change of
    /// `current`.
    static func change(
        from previous: ZenComposerDraftUpdate,
        to current: ZenComposerDraftUpdate,
        latest: ZenVoiceDictationDraft.Change
    ) -> ZenVoiceDictationDraft.Change {
        guard current.revision - previous.revision > 1,
              let previewID = current.regionID,
              previewID != previous.regionID else {
            return latest
        }
        return .started
    }

    /// The cursor after the move from `previous` to `current`, in characters:
    /// from `cursor`, the one before it, with `draftCount` characters in the
    /// draft now. Without a latest change it stays, clamped to the draft.
    static func cursor(
        _ cursor: Int,
        from previous: ZenComposerDraftUpdate,
        to current: ZenComposerDraftUpdate,
        latest: ZenVoiceDictationDraft.Change?,
        draftCount: Int
    ) -> Int {
        guard let latest else { return min(cursor, draftCount) }
        return ZenVoiceDictationDraft.cursor(
            cursor,
            after: change(from: previous, to: current, latest: latest),
            draftCount: draftCount
        )
    }

    /// What the composer of `session` observes of the dictation: the
    /// revision of its latest change and the dictation shown.
    @MainActor
    static func draftUpdate(of session: ZenWindowSession) -> ZenComposerDraftUpdate {
        ZenComposerDraftUpdate(
            revision: session.voiceDictationUpdate?.revision ?? 0,
            regionID: session.voiceDictation.preview?.id
        )
    }
}
