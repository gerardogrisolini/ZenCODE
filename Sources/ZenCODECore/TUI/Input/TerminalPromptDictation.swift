//
//  TerminalPromptDictation.swift
//  ZenCODE
//
//  The voice dictation shown live at the end of the prompt draft. Speech
//  recognized but not sent yet is previewed after whatever the operator
//  typed, so a voice send carries the whole visible draft and an edit can
//  turn the dictated words into ordinary text.
//

import Foundation

/// The dictation previewed at the end of a ``TerminalPromptEditor`` draft.
///
/// Pure value semantics, like the editor itself: the reader owns it under
/// the panel lock. While a dictation is active, `buffer[..<start]` is the
/// draft it was appended to and `buffer[start...]` its preview; only
/// ``show(id:text:in:)``, ``take(id:text:from:)`` and edits that end it
/// touch that region.
///
/// Every dictation carries the voice controller's id. An edit ends it and
/// records its id in `endedThrough`, so previews and sends that were already
/// on their way for that dictation are ignored: the dictated words became
/// ordinary draft text and voice forgets them.
struct TerminalPromptDictation: Equatable, Sendable {
    struct Active: Equatable, Sendable {
        let id: UInt64
        /// Buffer index where the preview starts.
        let start: Int
        /// A space was inserted before the preview to separate it from the
        /// typed text; removing the preview removes it too.
        let insertedSeparator: Bool
    }

    private(set) var active: Active?
    /// Dictations with an id up to this one were ended or sent.
    private(set) var endedThrough: UInt64 = 0

    var isActive: Bool {
        active != nil
    }

    /// Shows `text` as the preview of dictation `id`. Empty text removes the
    /// preview and its inserted separator; the first text of a dictation is
    /// appended after the draft, separated by one space when the draft does
    /// not already end in whitespace. Returns whether the editor changed.
    mutating func show(id: UInt64, text: String, in editor: inout TerminalPromptEditor) -> Bool {
        guard id > endedThrough else {
            return false
        }
        if let active, id < active.id {
            return false
        }
        let before = editor
        if text.isEmpty {
            guard let active else {
                return false
            }
            editor.replaceTrailingText(from: Self.baseEnd(of: active), with: [])
            self.active = nil
            return editor != before
        }
        if let active {
            // The operator may have moved into the typed text to read it:
            // only a cursor inside the dictation follows its end.
            let followsDictation = editor.cursorIndex >= active.start
            editor.replaceTrailingText(from: active.start, with: Array(text))
            if followsDictation {
                editor.cursorIndex = editor.buffer.count
            }
            self.active = Active(id: id, start: active.start, insertedSeparator: active.insertedSeparator)
        } else {
            let insertsSeparator = editor.buffer.last.map { !$0.isWhitespace } ?? false
            let separator: [Character] = insertsSeparator ? [" "] : []
            let start = editor.buffer.count + separator.count
            editor.replaceTrailingText(from: editor.buffer.count, with: separator + Array(text))
            editor.cursorIndex = editor.buffer.count
            active = Active(id: id, start: start, insertedSeparator: insertsSeparator)
        }
        return editor != before
    }

    /// Voice sends dictation `id` with `text`, its final words: returns the
    /// whole draft to send, the typed text followed by `text` (one space
    /// between them when needed), and clears the draft like a submit, without
    /// recording history. Nil when an edit already ended the dictation: its
    /// words are ordinary draft text now and the send is dropped. The result
    /// may be empty, e.g. the keyword said alone on an empty draft.
    mutating func take(id: UInt64, text: String, from editor: inout TerminalPromptEditor) -> String? {
        guard id > endedThrough else {
            return nil
        }
        if let active, id < active.id {
            return nil
        }
        let base = active.map { Array(editor.buffer[..<min(Self.baseEnd(of: $0), editor.buffer.count)]) }
            ?? editor.buffer
        editor.replaceTrailingText(from: 0, with: [])
        editor.cursorIndex = 0
        editor.draftBeforeHistory.removeAll()
        active = nil
        endedThrough = max(endedThrough, id)
        return Self.joined(String(base), text)
    }

    /// Ends the dictation shown, if any: its preview stays in the draft as
    /// ordinary text and later previews or sends of that dictation are
    /// ignored. Returns its id so voice can forget what it accumulated.
    mutating func end() -> UInt64? {
        guard let active else {
            return nil
        }
        endedThrough = max(endedThrough, active.id)
        self.active = nil
        return active.id
    }

    /// Where the typed text ends: before the inserted separator, if any.
    private static func baseEnd(of active: Active) -> Int {
        active.insertedSeparator ? active.start - 1 : active.start
    }

    /// The typed draft and the dictated text as one prompt.
    private static func joined(_ base: String, _ text: String) -> String {
        guard !base.isEmpty, !text.isEmpty else {
            return base + text
        }
        return base.last?.isWhitespace == true ? base + text : base + " " + text
    }
}
