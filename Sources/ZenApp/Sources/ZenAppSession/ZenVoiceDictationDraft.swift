//
//  ZenVoiceDictationDraft.swift
//  ZenApp
//
//  The voice dictation previewed live at the end of a window's draft: the
//  port, on a `String`, of the terminal's `TerminalPromptDictation`. Speech
//  recognized but not sent yet shows after whatever the operator typed, so a
//  voice send carries the whole visible draft and an edit turns the dictated
//  words into ordinary text.
//

import Foundation

/// The dictation previewed at the end of a window's draft
/// (``ZenWindowSession/draft``), with the terminal's semantics.
///
/// Pure value semantics: the window owns it with its draft and applies every
/// change to both at once. While a dictation is shown, the characters of the
/// draft before ``Preview/start`` are what the operator typed (the inserted
/// separator excluded) and the ones from it on are the preview; only
/// ``show(id:text:in:)``, ``take(id:text:from:)``, ``remove(from:)``, and
/// ``end()`` touch that region.
///
/// Every dictation carries the voice controller's id. Ending it (an edit of
/// the draft, a switch to another window) records its id in
/// ``endedThrough``, so the previews and sends still on their way for it are
/// ignored: its words became ordinary draft text and voice forgets them.
public struct ZenVoiceDictationDraft: Sendable, Equatable {
    /// The dictation the draft shows now.
    public struct Preview: Sendable, Equatable {
        /// The controller's id of the dictation.
        public let id: UInt64
        /// Where the preview starts in the draft, in characters.
        public let start: Int
        /// A space was inserted before the preview to separate it from the
        /// typed text; removing the preview removes it too.
        public let insertedSeparator: Bool
    }

    /// How the dictation changed the draft, so the composer can move its
    /// cursor as the terminal does (``cursor(_:after:draftCount:)``).
    public enum Change: Sendable, Equatable {
        /// A preview appeared at the end of the draft.
        case started
        /// The preview that starts at `previewStart` changed.
        case updated(previewStart: Int)
        /// The preview was removed; the typed text stays.
        case removed
        /// Voice sent the whole draft and cleared it.
        case taken
    }

    /// The dictation shown now; `nil` when the draft shows none.
    public private(set) var preview: Preview?
    /// Dictations with an id up to this one were ended or sent: their
    /// previews and sends are ignored.
    public private(set) var endedThrough: UInt64

    /// No dictation shown; the dictations up to `endedThrough` are ignored.
    public init(endedThrough: UInt64 = 0) {
        self.endedThrough = endedThrough
    }

    /// The draft shows a dictation.
    public var isActive: Bool {
        preview != nil
    }

    /// The characters of `draft` the preview covers; `nil` when none is
    /// shown.
    public func previewRange(in draft: String) -> Range<Int>? {
        guard let preview else { return nil }
        let count = draft.count
        guard preview.start <= count else { return nil }
        return preview.start..<count
    }

    /// Shows `text` as the preview of dictation `id` at the end of `draft`.
    /// An empty text removes the preview and its inserted separator; the
    /// first text of a dictation is appended after the draft, separated by
    /// one space when the draft does not already end in whitespace. Ignored
    /// for a dictation that ended, or older than the one shown. Returns how
    /// the draft changed, `nil` when it did not.
    public mutating func show(id: UInt64, text: String, in draft: inout String) -> Change? {
        guard id > endedThrough else { return nil }
        if let preview, id < preview.id { return nil }
        var characters = Array(draft)
        if text.isEmpty {
            guard let preview else { return nil }
            characters.removeSubrange(min(Self.baseEnd(of: preview), characters.count)...)
            self.preview = nil
            return Self.assign(characters, to: &draft) ? .removed : nil
        }
        if let preview {
            characters.replaceSubrange(min(preview.start, characters.count)..., with: Array(text))
            self.preview = Preview(id: id, start: preview.start, insertedSeparator: preview.insertedSeparator)
            return Self.assign(characters, to: &draft) ? .updated(previewStart: preview.start) : nil
        }
        let insertsSeparator = characters.last.map { !$0.isWhitespace } ?? false
        if insertsSeparator {
            characters.append(" ")
        }
        let start = characters.count
        characters.append(contentsOf: Array(text))
        preview = Preview(id: id, start: start, insertedSeparator: insertsSeparator)
        draft = String(characters)
        return .started
    }

    /// Voice sends dictation `id` with `text`, its final words: returns the
    /// whole draft to send, the typed text followed by `text` (one space
    /// between them when needed), and clears `draft`. `nil` when the
    /// dictation already ended: its words are ordinary draft text and the
    /// send is dropped. The result may be empty, e.g. the send keyword said
    /// alone on an empty draft.
    public mutating func take(id: UInt64, text: String, from draft: inout String) -> String? {
        guard id > endedThrough else { return nil }
        if let preview, id < preview.id { return nil }
        let characters = Array(draft)
        let typed = preview.map { Array(characters[..<min(Self.baseEnd(of: $0), characters.count)]) }
            ?? characters
        draft = ""
        preview = nil
        endedThrough = max(endedThrough, id)
        return Self.joined(String(typed), text)
    }

    /// Ends the dictation shown, if any: its preview stays in the draft as
    /// ordinary text, and its later previews and sends are ignored. Returns
    /// its id, so voice can forget what it collected for it.
    public mutating func end() -> UInt64? {
        guard let preview else { return nil }
        endedThrough = max(endedThrough, preview.id)
        self.preview = nil
        return preview.id
    }

    /// Voice mode stopped, or the window stopped being its host: the
    /// preview and its inserted separator leave `draft`, the typed text
    /// stays, and the dictation's later previews and sends are ignored.
    /// Returns whether `draft` changed.
    public mutating func remove(from draft: inout String) -> Bool {
        guard let preview else { return false }
        var characters = Array(draft)
        characters.removeSubrange(min(Self.baseEnd(of: preview), characters.count)...)
        endedThrough = max(endedThrough, preview.id)
        self.preview = nil
        return Self.assign(characters, to: &draft)
    }

    /// Where the composer's cursor goes after `change`, as in the terminal:
    /// to the end of the draft when a preview starts; to the end of the
    /// draft on an update only when it was inside the preview (at or after
    /// its start), so a cursor moved back into the typed text stays; clamped
    /// to the draft when the preview is removed; at the start of the empty
    /// draft once voice took it. `cursor` and `draftCount` are in characters,
    /// `draftCount` after the change.
    public static func cursor(_ cursor: Int, after change: Change, draftCount: Int) -> Int {
        switch change {
        case .started:
            draftCount
        case let .updated(previewStart):
            cursor >= previewStart ? draftCount : min(cursor, draftCount)
        case .removed:
            min(cursor, draftCount)
        case .taken:
            0
        }
    }

    /// Where the typed text ends: before the inserted separator, if any.
    private static func baseEnd(of preview: Preview) -> Int {
        preview.insertedSeparator ? preview.start - 1 : preview.start
    }

    /// Writes `characters` to `draft`; whether it changed.
    private static func assign(_ characters: [Character], to draft: inout String) -> Bool {
        let text = String(characters)
        guard text != draft else { return false }
        draft = text
        return true
    }

    /// The typed draft and the dictated text as one prompt.
    private static func joined(_ typed: String, _ text: String) -> String {
        guard !typed.isEmpty, !text.isEmpty else {
            return typed + text
        }
        return typed.last?.isWhitespace == true ? typed + text : typed + " " + text
    }
}

/// The latest change the dictation made to a window's draft
/// (``ZenWindowSession/voiceDictationUpdate``): a new revision for every
/// change, so the composer can move its cursor
/// (``ZenVoiceDictationDraft/cursor(_:after:draftCount:)``).
public struct ZenVoiceDictationUpdate: Sendable, Equatable {
    /// Grows by one with every change.
    public let revision: Int
    public let change: ZenVoiceDictationDraft.Change
}
