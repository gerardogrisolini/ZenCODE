//
//  TerminalANSIText.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/05/26.
//

import Foundation

enum TerminalANSIText {
    private static let reset = "\u{1B}[0m"
    
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
    
    /// Truncates `text` to at most `width` visible columns, appending an
    /// ellipsis (`…`) when content is cut. ANSI escape sequences are preserved
    /// and a reset is emitted at the end so styles never leak past the cut.
    static func truncate(_ text: String, to width: Int) -> String {
        let ellipsis = "…"
        let ellipsisWidth = 1
        guard width > ellipsisWidth else {
            return ellipsis
        }
        guard visibleWidth(stripANSI(text)) > width else {
            return text
        }
        return truncate(
            text,
            to: width,
            ellipsis: ellipsis,
            ellipsisWidth: ellipsisWidth
        )
    }

    /// Width-aware truncation core with a parametric ellipsis glyph. Shared by
    /// ``truncate(_:to:)`` (`…`, width 1) and `TerminalChat.fitDisplayWidth`
    /// (`...`, width 3) so both cut at identical grapheme boundaries. Callers
    /// are responsible for the "already fits" short-circuit and for any
    /// glyph-specific short-width fallback; this core assumes `width` leaves at
    /// least `width - ellipsisWidth` columns of content budget and that `text`
    /// exceeds `width` visible columns.
    ///
    /// Iterates by extended grapheme cluster (Character), not by scalar, so
    /// that multi-scalar clusters — ZWJ families, skin-tone modifiers, flag
    /// pairs and keycap sequences — are never split across the cut and are
    /// measured consistently with `visibleWidth(_:)`. ANSI escape sequences are
    /// preserved verbatim in between, and a reset is emitted when a style is
    /// still open at the cut so styling never leaks past the truncation. Per
    /// grapheme width is measured with `visibleWidth(of:)` to avoid allocating
    /// a `String` for every character.
    static func truncate(
        _ text: String,
        to width: Int,
        ellipsis: String,
        ellipsisWidth: Int
    ) -> String {
        var result = ""
        var visible = 0
        var index = text.startIndex
        var hasStyle = false
        var hyperlinkClosure: String?
        let maxContent = width - ellipsisWidth

        while index < text.endIndex {
            let character = text[index]
            if character.unicodeScalars.first == "\u{1B}" {
                let end = endOfEscapeSequence(in: text, from: index)
                let sequence = String(text[index..<end])
                result += sequence
                if sequence.hasSuffix("m") && !sequence.contains("[0m") {
                    hasStyle = true
                } else if sequence == "\u{1B}[0m" {
                    hasStyle = false
                }
                if let hyperlink = osc8HyperlinkState(for: sequence) {
                    switch hyperlink {
                    case let .open(closure):
                        hyperlinkClosure = closure
                    case .close:
                        hyperlinkClosure = nil
                    }
                }
                index = end
                continue
            }
            let charWidth = visibleWidth(of: character)
            if visible + charWidth > maxContent {
                break
            }
            result.append(character)
            visible += charWidth
            index = text.index(after: index)
        }
        result += ellipsis
        // OSC 8 state is independent from SGR. A terminal reset does not close
        // a hyperlink, so emit the matching BEL/ST closure when a cut falls in
        // its label. Keep it after the ellipsis, mirroring the existing SGR
        // contract where the ellipsis remains part of the active rendition.
        if let hyperlinkClosure {
            result += hyperlinkClosure
        }
        if hasStyle {
            result += reset
        }
        return result
    }

    /// Reflows `text` to `width` visible columns, breaking on spaces and
    /// preserving the active SGR style across wrap boundaries. Continuation
    /// lines are prefixed with `hangingIndent`. Existing newlines are honored
    /// and wrapped independently.
    static func wrap(
        _ text: String,
        width: Int,
        hangingIndent: String = ""
    ) -> String {
        guard width > 4 else {
            return text
        }
        // OSC 8 hyperlinks embed spaces inside the escape wrapper; wrapping
        // them would corrupt the sequence, so leave such lines untouched.
        let containsHyperlink = text.contains("\u{1B}]8")
        return text
            .components(separatedBy: "\n")
            .map { line -> String in
                if containsHyperlink && line.contains("\u{1B}]8") {
                    return line
                }
                return wrapSingleLine(line, width: width, hangingIndent: hangingIndent)
            }
            .joined(separator: "\n")
    }

    /// Reflows text at visible-cell boundaries without collapsing whitespace or
    /// dropping long unbroken tokens. This is used by in-place terminal blocks,
    /// where every emitted logical line must have a predictable physical row
    /// count. Active SGR styles are reset before a wrap and restored on the
    /// continuation line.
    static func wrapPreservingWhitespace(
        _ text: String,
        width: Int,
        hangingIndent: String = ""
    ) -> [String] {
        guard width > 0 else {
            return text.components(separatedBy: "\n")
        }

        return text
            .components(separatedBy: "\n")
            .flatMap {
                wrapSingleLinePreservingWhitespace(
                    $0,
                    width: width,
                    hangingIndent: hangingIndent
                )
            }
    }
    
    private static func wrapSingleLine(
        _ line: String,
        width: Int,
        hangingIndent: String
    ) -> String {
        guard visibleWidth(line) > width else {
            return line
        }
        
        let leadingWhitespace = String(line.prefix { $0 == " " })
        let body = String(line.dropFirst(leadingWhitespace.count))
        let words = body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else {
            return line
        }
        
        var lines: [String] = []
        var current = leadingWhitespace
        var currentWidth = leadingWhitespace.count
        var active = ""
        var lineHasWord = false
        
        for word in words {
            let wordWidth = visibleWidth(word)
            let needsSpace = lineHasWord
            let projected = currentWidth + (needsSpace ? 1 : 0) + wordWidth
            
            if lineHasWord && projected > width {
                if !active.isEmpty {
                    current += reset
                }
                lines.append(current)
                current = hangingIndent + active
                currentWidth = hangingIndent.count
                lineHasWord = false
            }
            
            if lineHasWord {
                current += " "
                currentWidth += 1
            }
            current += word
            currentWidth += wordWidth
            lineHasWord = true
            active = updatedActiveStyle(active, scanning: word)
        }
        
        lines.append(current)
        return lines.joined(separator: "\n")
    }

    private static func wrapSingleLinePreservingWhitespace(
        _ line: String,
        width: Int,
        hangingIndent: String
    ) -> [String] {
        guard visibleWidth(line) > width else {
            return [line]
        }

        // Never let an indentation consume the entire row. The normal TUI
        // geometry always has ample width, but retaining this guard keeps the
        // helper well-defined for narrow deterministic tests too.
        let continuationIndent = visibleWidth(hangingIndent) < width
            ? hangingIndent
            : ""
        var lines: [String] = []
        var current = ""
        var currentWidth = 0
        var activeStyle = ""
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character.unicodeScalars.first == "\u{1B}" {
                let end = endOfEscapeSequence(in: line, from: index)
                let sequence = String(line[index..<end])
                current += sequence
                activeStyle = updatedActiveStyle(activeStyle, scanning: sequence)
                index = end
                continue
            }

            let characterWidth = visibleWidth(of: character)
            if currentWidth > 0, currentWidth + characterWidth > width {
                if !activeStyle.isEmpty {
                    current += reset
                }
                lines.append(current)
                // An otherwise valid indent can leave too little room for a
                // double-width grapheme. Fit its continuation copy to the
                // remaining budget of this row rather than emitting a row wider
                // than `width`.
                let fittedIndent = prefixFittingVisibleWidth(
                    continuationIndent,
                    width: max(0, width - characterWidth)
                )
                current = fittedIndent + activeStyle
                currentWidth = visibleWidth(fittedIndent)
            }

            current.append(character)
            currentWidth += characterWidth
            index = line.index(after: index)
        }

        if !current.isEmpty || lines.isEmpty {
            lines.append(current)
        }
        return lines
    }
    
    /// Tracks the SGR sequences that remain active after `fragment` so a wrap
    /// boundary can re-open them on the next line.
    private static func updatedActiveStyle(_ current: String, scanning fragment: String) -> String {
        var active = current
        let scalars = Array(fragment.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\u{1B}",
                  index + 1 < scalars.count,
                  scalars[index + 1] == "[" else {
                index += 1
                continue
            }
            let end = endOfEscapeSequence(in: scalars, from: index)
            let sequenceScalars = scalars[index..<end]
            let sequence = String(String.UnicodeScalarView(sequenceScalars))
            if sequence.hasSuffix("m") {
                if isResetSequence(sequence) {
                    active = ""
                } else {
                    active += sequence
                }
            }
            index = end
        }
        return active
    }
    
    private static func isResetSequence(_ sequence: String) -> Bool {
        let codes = sequence
            .dropFirst(2)
            .dropLast()
            .split(separator: ";")
        return codes.isEmpty || codes.contains("0") || codes.contains("")
    }

    /// Returns the longest prefix of `text` whose visible width does not exceed
    /// `width`. ANSI escapes remain intact and do not consume the budget.
    private static func prefixFittingVisibleWidth(_ text: String, width: Int) -> String {
        guard width > 0 else {
            return ""
        }

        var result = ""
        var used = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.unicodeScalars.first == "\u{1B}" {
                let end = endOfEscapeSequence(in: text, from: index)
                result += String(text[index..<end])
                index = end
                continue
            }

            let characterWidth = visibleWidth(of: character)
            guard used + characterWidth <= width else {
                break
            }
            result.append(character)
            used += characterWidth
            index = text.index(after: index)
        }
        return result
    }

    private enum OSC8HyperlinkState {
        case open(closure: String)
        case close
    }

    /// Identifies a complete OSC 8 hyperlink sequence and, for an opener,
    /// returns the matching closure using its original terminator convention.
    /// OSC 8 accepts both BEL and ST (`ESC \\`) terminators; preserving the
    /// opener's convention avoids injecting a mixed sequence into the stream.
    private static func osc8HyperlinkState(for sequence: String) -> OSC8HyperlinkState? {
        guard sequence.hasPrefix("\u{1B}]") else {
            return nil
        }

        let terminator: String
        let payloadEnd: String.Index
        if sequence.hasSuffix("\u{07}") {
            terminator = "\u{07}"
            payloadEnd = sequence.index(before: sequence.endIndex)
        } else if sequence.hasSuffix("\u{1B}\\") {
            terminator = "\u{1B}\\"
            payloadEnd = sequence.index(sequence.endIndex, offsetBy: -2)
        } else {
            return nil
        }

        let payloadStart = sequence.index(sequence.startIndex, offsetBy: 2)
        let fields = sequence[payloadStart..<payloadEnd].split(
            separator: ";",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard fields.count == 3, fields[0] == "8" else {
            return nil
        }
        if fields[2].isEmpty {
            return .close
        }
        return .open(closure: "\u{1B}]8;;\(terminator)")
    }
    
    
    private static func endOfEscapeSequence(
        in text: String,
        from start: String.Index
    ) -> String.Index {
        let scalars = text.unicodeScalars
        let afterEscape = scalars.index(after: start)
        guard afterEscape < scalars.endIndex else {
            return afterEscape
        }
        let marker = scalars[afterEscape]
        if marker == "[" {
            var index = scalars.index(after: afterEscape)
            while index < scalars.endIndex {
                let scalar = scalars[index]
                if scalar.value >= 0x40 && scalar.value <= 0x7E {
                    return scalars.index(after: index)
                }
                index = scalars.index(after: index)
            }
            return index
        }
        if marker == "]" {
            var index = scalars.index(after: afterEscape)
            while index < scalars.endIndex {
                let scalar = scalars[index]
                if scalar == "\u{07}" {
                    return scalars.index(after: index)
                }
                if scalar == "\u{1B}" {
                    let next = scalars.index(after: index)
                    if next < scalars.endIndex, scalars[next] == "\\" {
                        return scalars.index(after: next)
                    }
                }
                index = scalars.index(after: index)
            }
            return index
        }
        return scalars.index(after: afterEscape)
    }
    
    /// Counts trailing visible newlines while skipping ANSI escape sequences,
    /// without materializing the stripped string. Mirrors the visibility rules
    /// of `stripANSI` but only accumulates counters, which keeps the streaming
    /// hot path allocation-free.
    ///
    /// - Returns: `hasVisible` indicates whether any visible (non-ANSI)
    ///   character exists; `trailingNewlines` is the number of `\n` at the end
    ///   of the visible text.
    static func trailingVisibleNewlineInfo(
        _ text: String
    ) -> (hasVisible: Bool, trailingNewlines: Int) {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var hasVisible = false
        var trailingNewlines = 0
        while index < scalars.count {
            if scalars[index] == "\u{1B}" {
                index = endOfEscapeSequence(in: scalars, from: index)
                continue
            }
            hasVisible = true
            if scalars[index] == "\n" {
                trailingNewlines += 1
            } else {
                trailingNewlines = 0
            }
            index += 1
        }
        return (hasVisible, trailingNewlines)
    }

    /// Strips all ANSI escape sequences (CSI and OSC) from `text`, returning
    /// only the visible characters. Used to compare rendered labels against raw
    /// URLs so autolinks are not annotated with a redundant `<url>`.
    static func stripANSI(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = ""
        var index = 0
        while index < scalars.count {
            if scalars[index] == "\u{1B}" {
                index = endOfEscapeSequence(in: scalars, from: index)
                continue
            }
            result.append(Character(scalars[index]))
            index += 1
        }
        return result
    }

    /// Returns the index just past the end of the escape sequence that starts
    /// at `start`. Handles CSI (`ESC [ … letter`) and OSC (`ESC ] … BEL`/`ESC \`)
    /// sequences; falls back to consuming the single ESC for anything else.
    private static func endOfEscapeSequence(
        in scalars: [Unicode.Scalar],
        from start: Int
    ) -> Int {
        guard start + 1 < scalars.count else {
            return start + 1
        }
        let marker = scalars[start + 1]
        if marker == "[" {
            var index = start + 2
            while index < scalars.count {
                let scalar = scalars[index]
                if (scalar.value >= 0x40 && scalar.value <= 0x7E) {
                    return index + 1
                }
                index += 1
            }
            return index
        }
        if marker == "]" {
            var index = start + 2
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "\u{07}" {
                    return index + 1
                }
                if scalar == "\u{1B}",
                   index + 1 < scalars.count,
                   scalars[index + 1] == "\\" {
                    return index + 2
                }
                index += 1
            }
            return index
        }
        return start + 2
    }
}
