//
//  PrimaryScreenTerminalModel.swift
//  ZenCODETests
//

import Foundation

/// Test-only VT subset used by the compositor. This is not a terminal library:
/// it models CUP/EL/ED2, margins, native LF history, delayed soft wrap and the
/// fixture's Unicode cells. `resize` reflows *before* the application handler.
/// Real Apple Terminal verification remains a separate release gate.
struct PrimaryScreenTerminalModel: Sendable {
    struct Row: Sendable {
        var cells: [String]
        var softWrapped = false
        var text: String { cells.joined().replacingOccurrences(of: " +$", with: "", options: .regularExpression) }
    }
    var rows: Int
    var columns: Int
    var viewport: [Row]
    var history: [Row] = []
    private var y = 0
    private var x = 0
    private var top = 0
    private var bottom: Int
    private var wrap = true
    private var pendingWrap = false
    private var saved = (x: 0, y: 0)

    init(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
        bottom = rows - 1
        viewport = Array(repeating: Row(cells: Array(repeating: " ", count: columns)), count: rows)
    }

    var cursorReport: String { "\u{1B}[\(y + 1);\(x + 1)R" }
    var visibleText: String { viewport.map(\.text).joined(separator: "\n") }
    var historyText: String { history.map(\.text).joined(separator: "\n") }

    mutating func write(_ text: String) {
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            i = text.index(after: i)
            if c == "\u{1B}", i < text.endIndex {
                let kind = text[i]
                i = text.index(after: i)
                if kind == "[" {
                    var parameters = ""
                    while i < text.endIndex {
                        let next = text[i]
                        i = text.index(after: i)
                        if let scalar = next.unicodeScalars.first, (0x40...0x7e).contains(scalar.value) {
                            csi(parameters, command: next)
                            break
                        }
                        parameters.append(next)
                    }
                } else if kind == "]" {
                    while i < text.endIndex {
                        let next = text[i]
                        i = text.index(after: i)
                        if next == "\u{7}" { break }
                        if next == "\u{1B}", i < text.endIndex, text[i] == "\\" {
                            i = text.index(after: i)
                            break
                        }
                    }
                } else if kind == "7" { saved = (x, y) }
                else if kind == "8" { x = saved.x; y = saved.y; pendingWrap = false }
                continue
            }
            if c == "\r\n" { x = 0; lineFeed(); continue }
            if c == "\r" { x = 0; pendingWrap = false; continue }
            if c == "\n" { lineFeed(); continue }
            put(String(c))
        }
    }

    private mutating func csi(_ parameters: String, command: Character) {
        let p = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        switch command {
        case "H", "f":
            y = min(rows - 1, max(0, (p.first ?? 1) - 1))
            x = min(columns - 1, max(0, (p.count > 1 ? p[1] : 1) - 1))
            pendingWrap = false
        case "J" where p.first == 2:
            viewport = Array(repeating: blank(), count: rows)
            pendingWrap = false
        case "J" where p.first == 0 || parameters.isEmpty:
            if x < columns { for column in x..<columns { viewport[y].cells[column] = " " } }
            viewport[y].softWrapped = false
            if y + 1 < rows { for row in (y + 1)..<rows { viewport[row] = blank() } }
            pendingWrap = false
        case "X":
            for column in x..<min(columns, x + max(1, p.first ?? 1)) { viewport[y].cells[column] = " " }
        case "K": viewport[y] = blank(); pendingWrap = false
        case "r":
            top = max(0, (p.first ?? 1) - 1)
            bottom = p.count > 1 ? min(rows - 1, p[1] - 1) : rows - 1
            x = 0; y = 0; pendingWrap = false
        case "h" where parameters == "?7": wrap = true
        case "l" where parameters == "?7": wrap = false; pendingWrap = false
        default: break // SGR and cursor visibility do not change cell contents.
        }
    }

    private func blank() -> Row { Row(cells: Array(repeating: " ", count: columns)) }

    private mutating func lineFeed() {
        pendingWrap = false
        if y == bottom {
            let removed = viewport.remove(at: top)
            if top == 0 { history.append(removed) }
            viewport.insert(blank(), at: bottom)
        } else { y = min(rows - 1, y + 1) }
    }

    private mutating func put(_ glyph: String) {
        let width = Self.width(glyph)
        guard width > 0 else { return }
        if wrap, pendingWrap || x + width > columns {
            viewport[y].softWrapped = true
            lineFeed()
            x = 0
        }
        guard x + width <= columns else { return }
        viewport[y].cells[x] = glyph
        if width == 2 { viewport[y].cells[x + 1] = "" }
        x += width
        if x >= columns { x = columns - 1; pendingWrap = wrap }
    }

    /// Fixture widths are independent of the product's TerminalANSIText helpers.
    private static func width(_ glyph: String) -> Int {
        guard let value = glyph.unicodeScalars.first?.value, value >= 0x20 else { return 0 }
        return (0x4e00...0x9fff).contains(value) || value >= 0x1f000 ? 2 : 1
    }

    mutating func resize(rows: Int, columns: Int) {
        var paragraphs: [String] = []
        var paragraph = ""
        var cursorParagraph = 0
        var cursorOffset = 0
        for (rowIndex, row) in viewport.enumerated() {
            if rowIndex == y {
                cursorParagraph = paragraphs.count
                cursorOffset = paragraph.reduce(0) { $0 + Self.width(String($1)) } + x
            }
            paragraph += row.text
            if !row.softWrapped { paragraphs.append(paragraph); paragraph = "" }
        }
        if !paragraph.isEmpty { paragraphs.append(paragraph) }
        var reflowed: [Row] = []
        var newCursorRow = 0
        var newCursorColumn = 0
        for (paragraphIndex, text) in paragraphs.enumerated() {
            let paragraphStart = reflowed.count
            var cells: [String] = []
            var consumed = 0
            for c in text {
                let glyph = String(c)
                let width = Self.width(glyph)
                if cells.count + width > columns {
                    cells += Array(repeating: " ", count: columns - cells.count)
                    reflowed.append(Row(cells: cells, softWrapped: true))
                    cells = []
                }
                if paragraphIndex == cursorParagraph, consumed == cursorOffset {
                    newCursorRow = reflowed.count
                    newCursorColumn = cells.count
                }
                cells.append(glyph)
                if width == 2 { cells.append("") }
                consumed += width
            }
            if paragraphIndex == cursorParagraph, cursorOffset >= consumed {
                newCursorRow = max(paragraphStart, reflowed.count)
                newCursorColumn = min(columns - 1, cells.count + cursorOffset - consumed)
            }
            cells += Array(repeating: " ", count: max(0, columns - cells.count))
            reflowed.append(Row(cells: cells))
        }
        if reflowed.count > rows {
            // Keep the real cursor's row visible. Cells below it may be clipped
            // by a terminal reflow; they are chrome, not application history.
            let removed = min(reflowed.count - rows, max(0, newCursorRow - 1))
            history += reflowed.prefix(removed)
            reflowed.removeFirst(removed)
            newCursorRow -= removed
            reflowed = Array(reflowed.prefix(rows))
        }
        self.rows = rows
        self.columns = columns
        viewport = reflowed + Array(repeating: blank(), count: max(0, rows - reflowed.count))
        top = 0; bottom = rows - 1
        y = min(newCursorRow, rows - 1); x = min(newCursorColumn, columns - 1); pendingWrap = false
    }
}
