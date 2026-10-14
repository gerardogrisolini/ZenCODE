import Foundation

/// Small screen model for redraw regressions. Unlike raw write-count assertions,
/// this applies the cursor movement and erase controls emitted by the coordinator,
/// so it verifies what remains visible after an external terminal writer has
/// inserted rows between two coordinator phases.
func terminalScreenText(
    _ text: String,
    height: Int? = nil,
    width: Int? = nil
) -> String {
    var rows = [[Character]](repeating: [], count: height ?? 1)
    var row = 0
    var column = 0
    var scrollTop = 0
    var scrollBottom = height.map { $0 - 1 }
    var savedCursor = (row: 0, column: 0)
    let scalars = Array(text.unicodeScalars)
    var index = 0

    func ensureRow(_ target: Int) {
        while rows.count <= target { rows.append([]) }
    }

    func lineFeed() {
        if let bottom = scrollBottom, row == bottom {
            rows.remove(at: scrollTop)
            rows.insert([], at: bottom)
        } else {
            row = min(row + 1, height.map { $0 - 1 } ?? Int.max)
            ensureRow(row)
        }
        column = 0
    }

    while index < scalars.count {
        let scalar = scalars[index]
        if scalar == "\u{1B}", index + 1 < scalars.count {
            let next = scalars[index + 1]
            if next == "7" || next == "8" {
                if next == "7" {
                    savedCursor = (row, column)
                } else {
                    row = savedCursor.row
                    column = savedCursor.column
                }
                index += 2
                continue
            }
            if next == "[" {
                index += 2
                var parameter = ""
                while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) {
                    parameter.unicodeScalars.append(scalars[index])
                    index += 1
                }
                guard index < scalars.count else { break }
                let values = parameter.split(separator: ";", omittingEmptySubsequences: false)
                    .map { Int($0) ?? 0 }
                let first = values.first ?? 0
                let count = max(1, first)
                switch scalars[index] {
                case "A": row = max(0, row - count)
                case "B": row = min(row + count, height.map { $0 - 1 } ?? Int.max)
                case "H", "f":
                    row = min(count - 1, height.map { $0 - 1 } ?? Int.max)
                    column = max(1, values.count > 1 ? values[1] : 1) - 1
                case "r":
                    scrollTop = count - 1
                    scrollBottom = values.count > 1 && values[1] > 0 ? values[1] - 1 : height.map { $0 - 1 }
                    // DECSTBM homes the cursor even if the margins did not change.
                    row = 0
                    column = 0
                case "s": savedCursor = (row, column)
                case "u":
                    row = savedCursor.row
                    column = savedCursor.column
                case "K":
                    ensureRow(row)
                    if first == 0, column < rows[row].count {
                        rows[row].removeSubrange(column...)
                    } else if first == 1, !rows[row].isEmpty {
                        let end = min(column, rows[row].count - 1)
                        rows[row].replaceSubrange(0...end, with: repeatElement(" ", count: end + 1))
                    } else if first == 2 { rows[row].removeAll() }
                default: break // SGR and cursor visibility do not paint cells.
                }
                ensureRow(row)
                index += 1
                continue
            }
        }
        switch scalar {
        case "\r": column = 0
        case "\n": lineFeed()
        default:
            if let width, column >= width { lineFeed() }
            let character = Character(String(scalar))
            while rows[row].count < column { rows[row].append(" ") }
            if rows[row].count == column { rows[row].append(character) }
            else { rows[row][column] = character }
            column += 1
        }
        index += 1
    }
    return rows.map { String($0) }.joined(separator: "\n")
}
