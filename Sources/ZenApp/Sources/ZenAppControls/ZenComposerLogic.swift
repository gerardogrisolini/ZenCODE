//
//  ZenComposerLogic.swift
//  ZenApp
//
//  The pure rules behind the composer: button visibility, the key hint,
//  cursor and selection arithmetic, the meaning of Return and the reader keys.
//

import AppKit
import Foundation
import SwiftUI

/// The pure rules behind ``ZenComposer``.
public enum ZenComposerLogic {
    /// Which of Send and Stop are on screen: Send when idle, Stop while busy,
    /// both while busy with a draft to queue.
    struct ButtonVisibility: Equatable {
        let showsSend: Bool
        let showsStop: Bool
    }

    static func buttons(isBusy: Bool, draft: String) -> ButtonVisibility {
        guard isBusy else {
            return ButtonVisibility(showsSend: true, showsStop: false)
        }
        return ButtonVisibility(showsSend: canSend(draft: draft), showsStop: true)
    }

    /// The key hint under the field, in the terminal's words: its input-panel
    /// help (`TerminalInteractiveLineReader.panelHelpTextLocked`) for the
    /// keys of the composer and its window, listing, like the terminal, only
    /// the keys that do something now. Ctrl+G is Session > Full Access and
    /// Ctrl+Y the chat reader, both menu key equivalents that also work from
    /// the field.
    struct KeyHint: Equatable {
        /// The whole hint.
        let full: String
        /// The hint when the whole one does not fit (`Esc stop` or
        /// `Esc stop reading` ahead of the other keys, as the terminal's
        /// compact help); `nil` when the whole one is the only form.
        let compact: String?
    }

    /// The hint for the composer's state:
    /// - with suggestions on screen, their keys (Esc hides them, busy,
    ///   reading aloud, or not);
    /// - while busy, Return queues and Esc stops the turn, the reading aloud
    ///   too, as in the terminal, where the turn's help wins;
    /// - while voice mode reads aloud (`isSpeaking`), Return sends and Esc
    ///   stops the reading;
    /// - otherwise Return sends, and Esc, which has nothing to stop and does
    ///   not clear the draft, is not listed.
    static func keyHint(isBusy: Bool, isSpeaking: Bool, hasSuggestions: Bool) -> KeyHint {
        if hasSuggestions {
            return KeyHint(full: "↑/↓ select · Tab complete · Enter choose · Esc dismiss", compact: nil)
        }
        if isBusy {
            return KeyHint(
                full: "Enter queue · Ctrl+G access · Ctrl+Y chat · Esc stop",
                compact: "Enter queue · Esc stop · Ctrl+G access · Ctrl+Y chat"
            )
        }
        if isSpeaking {
            return KeyHint(
                full: "Enter send · Ctrl+G access · Ctrl+Y chat · Esc stop reading",
                compact: "Enter send · Esc stop reading · Ctrl+G access · Ctrl+Y chat"
            )
        }
        return KeyHint(full: "Enter send · Ctrl+G access · Ctrl+Y chat", compact: nil)
    }

    /// A draft with something other than whitespace.
    static func canSend(draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The file URLs of a drop.
    static func droppedFiles(_ urls: [URL]) -> [URL] {
        urls.filter(\.isFileURL)
    }

    /// A queued prompt on one line.
    static func chipText(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whether the cursor is on the first line (moving up) or on the last line
    /// (moving down) of `text`, so the arrow recalls the history instead of
    /// moving between lines. Without a selection, or with one outside `text`
    /// (left over from an older draft), the cursor is at the end.
    static func cursorIsOnBoundaryLine(
        _ text: String,
        selection: Range<String.Index>?,
        movingUp: Bool
    ) -> Bool {
        let cursor = selection.flatMap {
            position(movingUp ? $0.lowerBound : $0.upperBound, in: text)
        } ?? text.endIndex
        return movingUp
            ? !text[..<cursor].contains("\n")
            : !text[cursor...].contains("\n")
    }

    /// `text` with the selection (or the end, without one) replaced by a
    /// newline, and the cursor after it. A bound outside `text` (a selection
    /// left over from an older draft) is the end.
    static func insertingNewline(
        into text: String,
        replacing selection: Range<String.Index>?
    ) -> (text: String, cursor: String.Index) {
        var result = text
        let lower = selection.flatMap { position($0.lowerBound, in: text) } ?? text.endIndex
        let upper = max(selection.flatMap { position($0.upperBound, in: text) } ?? text.endIndex, lower)
        let offset = text.distance(from: text.startIndex, to: lower)
        result.replaceSubrange(lower..<upper, with: "\n")
        let cursor = result.index(result.startIndex, offsetBy: offset + 1)
        return (result, cursor)
    }

    /// The cursor of `selection` in `text`, in characters: the insertion
    /// point inside the text. `nil`, which completion reads as the end of
    /// the draft, without a selection, for a range, or for an index outside
    /// `text` (a selection left over from an older draft).
    static func cursorOffset(in text: String, selection: Range<String.Index>?) -> Int? {
        guard let selection,
              selection.isEmpty,
              let cursor = position(selection.lowerBound, in: text) else {
            return nil
        }
        return text.distance(from: text.startIndex, to: cursor)
    }

    /// The selection of `selection` in `text`, in characters; `nil` without
    /// one, or for an index outside `text` (a selection left over from an
    /// older draft).
    static func selectionOffsets(in text: String, selection: Range<String.Index>?) -> Range<Int>? {
        guard let selection,
              let lower = position(selection.lowerBound, in: text),
              let upper = position(selection.upperBound, in: text) else {
            return nil
        }
        let start = text.distance(from: text.startIndex, to: lower)
        return start..<(start + text.distance(from: lower, to: max(upper, lower)))
    }

    /// `index` as an index of `text`, when it lies within the bounds of
    /// `text` counted in the encoding of the index; `nil` otherwise. A
    /// `String.Index` counts UTF-8 bytes (a native string) or UTF-16 units
    /// (the field's selection, from its bridged text), and `String` converts
    /// one into the other, but `<` and `<=` compare the numbers alone: a
    /// selection left over from an older draft can pass `<= text.endIndex`
    /// and trap when `text` measures from it. The encoding is read from the
    /// index's debug description (`12[utf16]`, `7[utf8]`, `0[any]`): an
    /// index valid in both encodings, or in one not recognized, is held to
    /// the UTF-16 count, which is never more than the UTF-8 one. An index
    /// inside a scalar (`+1` after the encoding) is refused: the field never
    /// puts the cursor there. The index returned is in the encoding of
    /// `text`, rounded down to a character, so comparing it with `text`'s
    /// own indices compares positions. Should the description change format
    /// and its offset no longer read, every index is refused: the composer
    /// then works at the end of the draft, without trapping.
    private static func position(_ index: String.Index, in text: String) -> String.Index? {
        let description = index.debugDescription
        let digits = description.prefix { $0.isASCII && $0.isNumber }
        let rest = description.dropFirst(digits.count)
        guard let offset = Int(digits), !rest.contains("+") else {
            return nil
        }
        let count = rest.hasPrefix("[utf8]") ? text.utf8.count : text.utf16.count
        guard offset <= count else {
            return nil
        }
        return text.index(index, offsetBy: 0)
    }

    /// The selection, in characters, once the owner changed the draft
    /// itself: the cursor (the end of `selection`; without one, the end of
    /// the draft before the change, `previousDraftCount` characters) goes
    /// where `place` puts it, clamped to the draft, now `draftCount`
    /// characters. A selection whose end `place` leaves where it was stays
    /// whole.
    static func followedSelection(
        _ selection: Range<Int>?,
        previousDraftCount: Int,
        draftCount: Int,
        place: (Int) -> Int
    ) -> Range<Int> {
        let range = selection ?? previousDraftCount..<previousDraftCount
        let cursor = range.upperBound
        let target = min(max(place(cursor), 0), draftCount)
        guard target != cursor else { return range }
        return target..<target
    }

    /// The index `characterOffset` characters into `text`, clamped to it. A
    /// character is a `Character`: an emoji or an accented letter is one,
    /// however many UTF-16 units the field counts for it.
    static func index(in text: String, characterOffset: Int) -> String.Index {
        text.index(text.startIndex, offsetBy: min(max(characterOffset, 0), text.count))
    }

    /// The field's selection of `offsets`, characters of `text`: string
    /// indices, which the field maps to its UTF-16 range.
    static func textSelection(_ offsets: Range<Int>, in text: String) -> TextSelection {
        let lower = index(in: text, characterOffset: offsets.lowerBound)
        let upper = index(in: text, characterOffset: offsets.upperBound)
        return lower == upper ? TextSelection(insertionPoint: lower) : TextSelection(range: lower..<upper)
    }

    /// What Return does in the field.
    enum ReturnAction: Equatable {
        /// Shift+Return, Option+Return.
        case insertNewline
        /// Accept the highlighted suggestion (sending the draft when it is
        /// complete).
        case acceptSuggestion
        /// Leave the key to the field: an input method is composing.
        case passThrough
        /// Send the draft.
        case submit
    }

    /// The meaning of Return: Shift or Option inserts a newline; while an
    /// input method composes (marked text) a plain Return belongs to the
    /// input method, which commits the composition, even over a highlighted
    /// suggestion; with a highlighted suggestion it accepts it; otherwise it
    /// sends the draft.
    static func returnAction(
        modifiers: EventModifiers,
        hasSuggestion: Bool,
        hasMarkedText: Bool
    ) -> ReturnAction {
        if modifiers.contains(.shift) || modifiers.contains(.option) {
            return .insertNewline
        }
        if hasMarkedText {
            return .passThrough
        }
        if hasSuggestion {
            return .acceptSuggestion
        }
        return .submit
    }

    /// The reader key of a key press, as the terminal maps it while its reader
    /// is open: ← previous, → next, Home first, End last message, ↑/↓ scroll.
    /// Only unmodified keys: with Shift, Option, Command or Control a key
    /// keeps its text-editing meaning (`nil`). Caps Lock and the numeric-pad
    /// and function flags the arrow keys carry do not count.
    public static func readerKey(for key: KeyEquivalent, modifiers: EventModifiers) -> ZenReaderKey? {
        guard modifiers.isDisjoint(with: [.shift, .option, .command, .control]) else {
            return nil
        }
        switch key {
        case .leftArrow: return .previousMessage
        case .rightArrow: return .nextMessage
        case .home: return .firstMessage
        case .end: return .lastMessage
        case .upArrow: return .scrollUp
        case .downArrow: return .scrollDown
        default: return nil
        }
    }

    /// Whether the focused text input of the key window holds marked text,
    /// i.e. an input method (IME, dead keys, press-and-hold accents) is
    /// composing in the field editor. While it does, Return, ↑, ↓, Tab and
    /// Esc belong to the input method, in the composer and in the window.
    @MainActor
    public static func focusedInputHasMarkedText() -> Bool {
        guard let responder = NSApplication.shared.keyWindow?.firstResponder,
              let input = responder as? any NSTextInputClient else {
            return false
        }
        return input.hasMarkedText()
    }
}
