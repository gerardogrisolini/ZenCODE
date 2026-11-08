//
//  ZenComposerActions.swift
//  ZenApp
//
//  What the composer asks its owner to do (``ZenComposerActions``) and the
//  shared-chat reader keys it forwards (``ZenReaderKey``).
//

import Foundation

/// A key of the shared-chat reader, as the terminal maps it while its reader
/// is open: ← and → move between messages, Home and End go to the first and
/// the last one, ↑ and ↓ scroll the message shown.
public enum ZenReaderKey: Sendable, Equatable {
    /// ←: the message before the one shown.
    case previousMessage
    /// →: the message after the one shown.
    case nextMessage
    /// Home: the oldest message.
    case firstMessage
    /// End: the newest message.
    case lastMessage
    /// ↑: scroll the message shown up.
    case scrollUp
    /// ↓: scroll the message shown down.
    case scrollDown
}

/// What the composer asks its owner to do. Every closure runs on the main
/// actor and defaults to a no-op.
public struct ZenComposerActions {
    /// Sends the current draft (the `draft` binding already holds the text to
    /// send; the owner clears it). Never called for a blank draft.
    public var submit: @MainActor () -> Void
    /// Stops the running generation.
    public var stop: @MainActor () -> Void
    /// Opens the attachment picker.
    public var attach: @MainActor () -> Void
    /// File URLs dropped onto the composer.
    public var dropFiles: @MainActor ([URL]) -> Void
    /// Recalls the previous history entry into the draft; `false` when there
    /// is none, so the key keeps its ordinary meaning.
    public var historyPrevious: @MainActor () -> Bool
    /// Recalls the next history entry (or the draft typed before the
    /// recall); `false` when there is none.
    public var historyNext: @MainActor () -> Bool
    /// Removes a queued prompt.
    public var removeQueued: @MainActor (UUID) -> Void
    /// The cursor started completing the leading `@mention` of the draft
    /// (the operator starts typing one, or comes back to edit it): the
    /// operator may be addressing a live participant, so the owner refreshes
    /// the mention roster it passes as ``ZenComposer``'s `mentions`.
    public var refreshMentions: @MainActor () -> Void
    /// An unmodified reader key (``ZenComposerLogic/readerKey(for:modifiers:)``)
    /// pressed in the field: `true` when the owner's shared-chat reader
    /// consumed it, so the key neither moves the cursor nor recalls the
    /// history nor moves the suggestion highlight; `false` (the default)
    /// leaves the key its ordinary meaning.
    public var readerKey: @MainActor (ZenReaderKey) -> Bool
    /// Where the cursor goes, in characters, once the owner changed the
    /// draft itself (``ZenComposer``'s `draftUpdate` went from the first
    /// update to the second, maybe skipping some in one render): from the
    /// cursor before the change and the number of characters of the draft
    /// after it, both in characters. The default keeps the cursor, clamped
    /// to the draft.
    public var cursorAfterDraftUpdate: @MainActor (
        _ cursor: Int,
        _ from: ZenComposerDraftUpdate,
        _ to: ZenComposerDraftUpdate,
        _ draftCount: Int
    ) -> Int

    public init(
        submit: @escaping @MainActor () -> Void = {},
        stop: @escaping @MainActor () -> Void = {},
        attach: @escaping @MainActor () -> Void = {},
        dropFiles: @escaping @MainActor ([URL]) -> Void = { _ in },
        historyPrevious: @escaping @MainActor () -> Bool = { false },
        historyNext: @escaping @MainActor () -> Bool = { false },
        removeQueued: @escaping @MainActor (UUID) -> Void = { _ in },
        refreshMentions: @escaping @MainActor () -> Void = {},
        readerKey: @escaping @MainActor (ZenReaderKey) -> Bool = { _ in false },
        cursorAfterDraftUpdate: @escaping @MainActor (
            Int, ZenComposerDraftUpdate, ZenComposerDraftUpdate, Int
        ) -> Int = { cursor, _, _, draftCount in min(cursor, draftCount) }
    ) {
        self.submit = submit
        self.stop = stop
        self.attach = attach
        self.dropFiles = dropFiles
        self.historyPrevious = historyPrevious
        self.historyNext = historyNext
        self.removeQueued = removeQueued
        self.refreshMentions = refreshMentions
        self.readerKey = readerKey
        self.cursorAfterDraftUpdate = cursorAfterDraftUpdate
    }
}
