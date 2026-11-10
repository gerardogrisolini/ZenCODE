//  Created by Gerardo Grisolini on 30/05/26.
//
// TerminalStreamingText.swift
import Foundation

/// Retains only the unfinished paragraph, not terminal history. Bytes are
/// emitted on every append; only an incomplete escape is withheld. The final
/// grapheme is reconciled across chunks before any CUP can break its cluster.
struct TerminalStreamingText: Sendable {
    struct Glyph: Sendable {
        var text: String { didSet { width = TerminalANSIText.visibleWidth(text) } }
        var style: String
        /// `TerminalANSIText.visibleWidth(text)`, measured once per text.
        private(set) var width: Int

        init(text: String, style: String) {
            self.text = text
            self.style = style
            width = TerminalANSIText.visibleWidth(text)
        }
    }
    enum Token {
        case glyph(String), carriageReturn, newline, tab, rendition(String)
        /// `ESC[K` / `ESC[0K`: extends the active rendition to the right edge.
        case eraseToEndOfLine
    }
    private(set) var glyphs: [Glyph] = []
    private(set) var index = 0
    private(set) var rendition = ""
    private var escape = ""
    /// Unicode scalars in `escape` and its second scalar (the CSI/OSC marker),
    /// tracked so a long escape is not re-scanned for every scalar.
    private var escapeLength = 0
    private var escapeMarker: Unicode.Scalar?
    /// Pen states of `glyphs` for one column count, kept in step by every
    /// mutation so the cursor and the paragraph end need no full relayout.
    private var layout: Layout?

    mutating func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        for scalar in text.unicodeScalars {
            if !escape.isEmpty {
                escape.unicodeScalars.append(scalar)
                escapeLength += 1
                if escapeLength == 2 { escapeMarker = scalar }
                let isCSI = escapeLength > 1 && escapeMarker == "["
                let isOSC = escapeLength > 1 && escapeMarker == "]"
                let complete = isCSI ? (escapeLength > 2 && (0x40...0x7e).contains(scalar.value))
                    : isOSC ? (scalar.value == 7 || escape.hasSuffix("\u{1B}\\")) : escapeLength >= 2
                if complete || escape.utf8.count > 4096 {
                    if isCSI && escape.hasSuffix("m") || isOSC && escape.hasPrefix("\u{1B}]8;") {
                        result.append(.rendition(escape))
                    } else if escape == "\u{1B}[K" || escape == "\u{1B}[0K" {
                        // Only EL 0 is forwarded; EL 1/2 would erase cells the
                        // screen model owns, so they stay discarded like any
                        // other CSI.
                        result.append(.eraseToEndOfLine)
                    }
                    escape = ""
                    escapeLength = 0
                    escapeMarker = nil
                }
                continue
            }
            switch scalar.value {
            case 27: escape = String(scalar); escapeLength = 1; escapeMarker = nil
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
    /// `columns` only selects the layout kept up to date; the glyphs are the same.
    mutating func replaceLast(with text: String, columns: Int) {
        guard index == glyphs.count else {
            glyphs[index - 1].text = text
            layout = Self.measure(glyphs, index: index, columns: columns)
            return
        }
        // The pen before the last glyph does not depend on that glyph, so
        // only its own wrap decision and advance are recomputed.
        syncLayout(columns: columns)
        glyphs[index - 1].text = text
        if var layout {
            layout.end = Self.advance(layout.beforeLast, by: glyphs[index - 1].width, columns: layout.columns)
            layout.cursor = layout.end
            self.layout = layout
        }
    }
    /// `columns` only selects the layout kept up to date; the glyphs are the same.
    mutating func put(_ text: String, columns: Int) {
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
            index += 1
            layout = Self.measure(glyphs, index: index, columns: columns)
        } else {
            syncLayout(columns: columns)
            glyphs.append(glyph)
            index += 1
            if var layout {
                layout.beforeLast = layout.end
                layout.end = Self.advance(layout.end, by: glyph.width, columns: layout.columns)
                layout.cursor = layout.end
                self.layout = layout
            }
        }
    }
    mutating func newline() {
        glyphs.removeAll(keepingCapacity: true); index = 0
        if let columns = layout?.columns { layout = Layout(columns: columns) }
    }
    mutating func carriageReturn(columns: Int) {
        let starts = positions(columns: columns)
        let targetRow = starts[index].row
        index = starts.firstIndex(where: { $0.row == targetRow }) ?? 0
        layout = Self.measure(glyphs, index: index, columns: columns)
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
    /// `positions(columns:)[index]`; O(1) while the layout matches `columns`.
    func position(columns: Int) -> Position {
        let layout = currentLayout(columns: columns)
        guard index < glyphs.count else { return layout.cursor }
        return Self.place(glyphs[index].width, at: layout.cursor, columns: layout.columns)
    }
    /// `positions(columns:).last`; O(1) while the layout matches `columns`.
    func finalPosition(columns: Int) -> Position { currentLayout(columns: columns).end }
    /// `positions(columns:)[offset]`; O(1) for the last glyph.
    func glyphPosition(at offset: Int, columns: Int) -> Position {
        guard offset >= 0, offset == glyphs.count - 1 else { return positions(columns: columns)[offset] }
        let layout = currentLayout(columns: columns)
        return Self.place(glyphs[offset].width, at: layout.beforeLast, columns: layout.columns)
    }

    /// Pen states of a paragraph for one column count. A pen state is where
    /// the next glyph would start before its own wrap decision, so the end
    /// state can sit in the delayed-wrap column (`columns + 1`).
    private struct Layout: Sendable {
        var columns: Int
        /// Pen after `glyphs[..<index]`.
        var cursor = TerminalStreamingText.origin
        /// Pen after every glyph but the last (the origin when empty).
        var beforeLast = TerminalStreamingText.origin
        /// Pen after every glyph: `positions(columns:).last`.
        var end = TerminalStreamingText.origin
    }
    private static let origin = Position(row: 0, column: 1)

    /// Same rule as `positions(columns:)`: a glyph that would cross the last
    /// column starts the next row; a zero-width glyph never wraps.
    private static func place(_ width: Int, at pen: Position, columns: Int) -> Position {
        width > 0 && pen.column + width - 1 > columns ? Position(row: pen.row + 1, column: 1) : pen
    }
    private static func advance(_ pen: Position, by width: Int, columns: Int) -> Position {
        var next = place(width, at: pen, columns: columns)
        next.column += width
        return next
    }
    /// Full relayout, used when the column count changes and after a carriage
    /// return or an overwrite in the middle of the paragraph.
    private static func measure(_ glyphs: [Glyph], index: Int, columns: Int) -> Layout {
        var layout = Layout(columns: max(1, columns))
        var pen = origin
        for (offset, glyph) in glyphs.enumerated() {
            if offset == index { layout.cursor = pen }
            if offset == glyphs.count - 1 { layout.beforeLast = pen }
            pen = advance(pen, by: glyph.width, columns: layout.columns)
        }
        layout.end = pen
        if index >= glyphs.count { layout.cursor = pen }
        return layout
    }
    private func currentLayout(columns: Int) -> Layout {
        if let layout, layout.columns == max(1, columns) { return layout }
        return Self.measure(glyphs, index: index, columns: columns)
    }
    private mutating func syncLayout(columns: Int) {
        if layout?.columns != max(1, columns) { layout = Self.measure(glyphs, index: index, columns: columns) }
    }
}
