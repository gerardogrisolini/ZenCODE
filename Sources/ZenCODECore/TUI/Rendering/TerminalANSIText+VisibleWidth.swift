//
//  TerminalANSIText+VisibleWidth.swift
//  ZenCODE
//
//  Visible terminal width of text and characters, ignoring ANSI escape
//  sequences and counting double-width graphemes.
//

import Foundation

extension TerminalANSIText {
    /// Number of visible terminal columns in `text`, ignoring ANSI escape
    /// sequences and accounting for common double-width grapheme clusters such
    /// as emoji and CJK/fullwidth characters.
    static func visibleWidth(_ text: String) -> Int {
        var width = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.unicodeScalars.first == "\u{1B}" {
                index = endOfEscapeSequence(in: text, from: index)
                continue
            }
            width += visibleWidth(of: character)
            index = text.index(after: index)
        }
        return width
    }


    /// Number of visible terminal columns occupied by a single extended
    /// grapheme cluster, applying the same double-width policy as
    /// ``visibleWidth(_:)``. Exposed so width-aware callers (truncation,
    /// fitting) can measure per-character without materializing a `String`.
    static func visibleWidth(of character: Character) -> Int {
        // Printable ASCII is the bulk of what is measured and matches none of
        // the rules below. Only a one-byte cluster qualifies: one that merely
        // starts with ASCII (a keycap such as `#` + VS16 + U+20E3, a letter
        // with a combining mark, CR-LF) is longer and takes the full path.
        let utf8 = character.utf8
        if utf8.count == 1, let byte = utf8.first, (0x20...0x7E).contains(byte) {
            return 1
        }
        let scalars = character.unicodeScalars
        guard let first = scalars.first else {
            return 0
        }
        if scalars.allSatisfy(isZeroWidthScalar) {
            return 0
        }
        if isWideOrFullwidthScalar(first) {
            return 2
        }
        // A text-presentation selector overrides the default emoji presentation
        // for symbol characters such as U+23F3 (⏳). Conversely, VS16 selects
        // emoji presentation for normally narrow symbols such as U+2702 (✂).
        // Keep the selector checks ahead of the scalar property so the rendered
        // width follows the explicit presentation requested by the text.
        if scalars.contains("\u{FE0F}")
            || scalars.contains("\u{200D}")
            || scalars.contains("\u{20E3}")
            || (!scalars.contains("\u{FE0E}")
                && scalars.contains(where: isEmojiPresentationScalar)) {
            return 2
        }
        return 1
    }

    private static func isZeroWidthScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value == 0
        || value == 0x200B
        || value == 0x200C
        || value == 0x200D
        || value == 0xFE0E
        || value == 0xFE0F
        || (0x0300...0x036F).contains(value)
        || (0x1AB0...0x1AFF).contains(value)
        || (0x1DC0...0x1DFF).contains(value)
        || (0x20D0...0x20FF).contains(value)
        || (0xFE20...0xFE2F).contains(value)
    }

    /// Returns `true` when Unicode assigns an emoji presentation by default.
    ///
    /// This deliberately uses Unicode's `Emoji_Presentation` property rather
    /// than treating entire symbol blocks as emoji. Many symbols in U+2600…
    /// U+27BF are text-presentation by default and occupy one terminal cell
    /// until a VS16 selector explicitly requests their emoji presentation.
    private static func isEmojiPresentationScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmojiPresentation
    }

    private static func isWideOrFullwidthScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x1100...0x115F).contains(value)
        || value == 0x2329
        || value == 0x232A
        || (0x2E80...0xA4CF).contains(value)
        || (0xAC00...0xD7A3).contains(value)
        || (0xF900...0xFAFF).contains(value)
        || (0xFE10...0xFE19).contains(value)
        || (0xFE30...0xFE6F).contains(value)
        || (0xFF00...0xFF60).contains(value)
        || (0xFFE0...0xFFE6).contains(value)
        || (0x20000...0x2FFFD).contains(value)
        || (0x30000...0x3FFFD).contains(value)
    }
}
