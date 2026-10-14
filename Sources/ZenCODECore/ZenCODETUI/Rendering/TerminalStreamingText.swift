//  Created by Gerardo Grisolini on 30/05/26.
//
// TerminalStreamingText.swift
import Foundation

/// Retains only the unfinished paragraph, not terminal history. Bytes are
/// emitted on every append; only an incomplete escape is withheld. The final
/// grapheme is reconciled across chunks before any CUP can break its cluster.
struct TerminalStreamingText: Sendable {
    struct Glyph: Sendable { var text: String; var style: String
        var width: Int { TerminalANSIText.visibleWidth(text) }
    }
    enum Token { case glyph(String), carriageReturn, newline, tab, rendition(String) }
    private(set) var glyphs: [Glyph] = []
    private(set) var index = 0
    private(set) var rendition = ""
    private var escape = ""

    mutating func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        for scalar in text.unicodeScalars {
            if !escape.isEmpty {
                escape.unicodeScalars.append(scalar)
                let values = Array(escape.unicodeScalars)
                let isCSI = values.count > 1 && values[1] == "["
                let isOSC = values.count > 1 && values[1] == "]"
                let complete = isCSI ? (values.count > 2 && (0x40...0x7e).contains(scalar.value))
                    : isOSC ? (scalar.value == 7 || escape.hasSuffix("\u{1B}\\")) : values.count >= 2
                if complete || escape.utf8.count > 4096 {
                    if isCSI && escape.hasSuffix("m") || isOSC && escape.hasPrefix("\u{1B}]8;") {
                        result.append(.rendition(escape))
                    }
                    escape = ""
                }
                continue
            }
            switch scalar.value {
            case 27: escape = String(scalar)
            case 13: result.append(.carriageReturn)
            case 10: result.append(.newline)
            case 9: result.append(.tab)
            case 0x20...0x10ffff where scalar.value != 0x7f: result.append(.glyph(String(scalar)))
            default: break
            }
        }
        return result
    }

    mutating func setRendition(_ value: String) {
        if value == "\u{1B}[0m" || value == "\u{1B}[m" { rendition = "" }
        else if !rendition.hasSuffix(value) { rendition += value }
    }

    /// One scalar may extend an already displayed Character (accent, VS, ZWJ,
    /// flag). Return the replacement to repaint, not a duplicate append.
    func mergedGlyph(_ text: String) -> String? {
        guard index > 0, index == glyphs.count else { return nil }
        let joined = glyphs[index - 1].text + text
        return joined.count == 1 ? joined : nil
    }
    mutating func replaceLast(with text: String) { glyphs[index - 1].text = text }
    mutating func put(_ text: String) {
        let glyph = Glyph(text: text, style: rendition)
        if index < glyphs.count {
            var covered = 0
            while index < glyphs.count, covered < max(1, glyph.width) {
                covered += max(1, glyphs[index].width)
                glyphs.remove(at: index)
            }
            glyphs.insert(glyph, at: index)
            if covered > glyph.width {
                for _ in 0..<(covered - glyph.width) {
                    glyphs.insert(Glyph(text: " ", style: rendition), at: index + 1)
                }
            }
        } else { glyphs.append(glyph) }
        index += 1
    }
    mutating func newline() { glyphs.removeAll(keepingCapacity: true); index = 0 }
    mutating func carriageReturn(columns: Int) {
        let targetRow = position(columns: columns).row
        index = positions(columns: columns).firstIndex(where: { $0.row == targetRow }) ?? 0
    }
    struct Position { var row: Int; var column: Int }
    func positions(columns: Int) -> [Position] {
        let columns = max(1, columns)
        var row = 0, column = 1
        var result: [Position] = []
        for glyph in glyphs {
            let width = glyph.width
            if width > 0, column + width - 1 > columns { row += 1; column = 1 }
            result.append(Position(row: row, column: column))
            column += width
        }
        result.append(Position(row: row, column: column))
        return result
    }
    func position(columns: Int) -> Position { positions(columns: columns)[index] }
    func finalPosition(columns: Int) -> Position { positions(columns: columns).last! }
}
