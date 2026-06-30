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
    
    
    private static func visibleWidth(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else {
            return 0
        }
        if scalars.allSatisfy(isZeroWidthScalar) {
            return 0
        }
        if scalars.contains(where: isEmojiPresentationScalar)
            || scalars.contains("\u{FE0F}")
            || scalars.contains("\u{200D}")
            || isWideOrFullwidthScalar(first) {
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
    
    private static func isEmojiPresentationScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x1F000...0x1FAFF).contains(value)
        || (0x2600...0x27BF).contains(value)
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

        let scalars = Array(text.unicodeScalars)
        var result = ""
        var visible = 0
        var index = 0
        var hasStyle = false
        let maxContent = width - ellipsisWidth

        while index < scalars.count {
            if scalars[index] == "\u{1B}" {
                let end = endOfEscapeSequence(in: scalars, from: index)
                let sequence = String(String.UnicodeScalarView(scalars[index..<end]))
                result += sequence
                if sequence.hasSuffix("m") && !sequence.contains("[0m") {
                    hasStyle = true
                } else if sequence == "\u{1B}[0m" {
                    hasStyle = false
                }
                index = end
                continue
            }
            let character = Character(scalars[index])
            let charWidth = visibleWidth(of: character)
            if visible + charWidth > maxContent {
                break
            }
            result.append(character)
            visible += charWidth
            index += 1
        }
        result += ellipsis
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
