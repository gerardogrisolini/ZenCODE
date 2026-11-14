//
//  TerminalSubAgentDetailPanel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 06/11/26.
//

import Foundation

/// Keys accepted by the sub-agent detail panel while it owns the input
/// panel. Public because `TerminalPromptInputEvent` carries it; the panel
/// model interprets only the navigation cases and leaves `confirm`, `close`
/// and `closeList` to the controller.
public enum TerminalSubAgentDetailAction: Sendable, Equatable {
    case scrollUp, scrollDown, pageUp, pageDown, top, bottom
    case focusPrevious, focusNext
    /// Opens the agent focused in the list (`Enter`).
    case confirm
    /// Closes the panel in every mode (`Esc`).
    case close
    /// Closes the agent list only (`q`/`Q` there); an agent's detail ignores
    /// it. It is distinct from ``close`` for the keys typed ahead: the panel
    /// keeps routing the list's keys until the chat loop tells it that the
    /// detail of the agent just confirmed is shown, so a `q` typed right
    /// after `Enter` still arrives as the list's key and must not close that
    /// detail.
    case closeList
}

/// Pure layout/state model for the `/subagent` detail panel, and for the
/// `/artifacts` panel that shares its layout under its own ``title``.
/// Terminal drawing and data loading stay in the controller; this type makes
/// the choice list, follow mode, scrolling and framing deterministic and
/// independent of TTY ownership.
///
/// Every frame shares one row budget, used identically by
/// ``bodyCapacity(frameRows:)``, ``apply(_:frameRows:)``,
/// ``replace(headerRows:bodyRows:frameRows:)`` and
/// ``frameLines(rows:columns:)``:
///
/// - the top and bottom borders take one row each, leaving
///   `interior = max(0, frameRows - 2)` rows;
/// - the header and its `├─┤` separator together take at most
///   `interior / 2` rows (rounded down), so the body always keeps at least
///   half of the interior rows, and at least one when `interior >= 1`;
/// - the first `min(headerRows.count, interior / 2 - 1)` header rows are
///   shown; when that is zero neither the header nor the separator is drawn;
/// - the body gets every remaining interior row.
///
/// The body capacity therefore depends only on the header and the frame
/// height, never on the body length, so a growing transcript does not move
/// the frame. `scrollOffset` and `isFollowing` always refer to `bodyRows`.
///
/// In ``Mode/choosing(entries:focusedIndex:)`` the body is the choice list
/// instead of `bodyRows`, and the list knows nothing of what its entries
/// stand for. Each ``ChoiceEntry`` is a block of rows: its title row, with
/// `▸ ` and the accent on the focused entry and two spaces on the others,
/// then its detail rows, indented four columns, behind an accent `┃` on the
/// focused entry. The window is derived from the focused entry:
///
/// - when every block fits the body with one blank row between consecutive
///   blocks, the whole list is shown that way;
/// - otherwise the blocks are shown without the blank rows, and only whole
///   ones: the focused entry, then its neighbours added alternately above
///   and below (above first on a tie) while they fit, so the focused entry
///   stays near the middle;
/// - a body shorter than the focused block shows the first rows of that
///   block alone.
struct TerminalSubAgentDetailPanel: Sendable, Equatable {
    /// One entry of the choice list: what the entry stands for, for the
    /// caller that confirms it, and its rows, already rendered. Each row is
    /// drawn on one frame row and may carry ANSI styling; the panel truncates
    /// a row wider than the frame.
    struct ChoiceEntry: Sendable, Equatable {
        /// The identity the caller resolves when the entry is confirmed.
        let id: String
        /// The first row of the entry, the one the focus marks.
        let title: String
        /// The rows drawn below the title, indented; none for a one-row
        /// entry.
        let details: [String]

        init(id: String, title: String, details: [String] = []) {
            self.id = id
            self.title = title
            self.details = details
        }
    }

    enum Mode: Sendable, Equatable {
        /// The operator picks one of `entries` first; `focusedIndex` is the
        /// entry the focus marks.
        case choosing(entries: [ChoiceEntry], focusedIndex: Int)
        /// The panel shows the selected agent's header and body rows.
        case showing
    }

    /// Whether the controller could read the selected agent. The panel only
    /// stores it; any related text is part of the rows the controller supplies.
    enum Availability: Sendable, Equatable {
        case loading, available, unavailable
    }

    var mode: Mode
    var availability: Availability
    /// The label of the top border, ``subAgentTitle`` unless the controller
    /// gives its own.
    var title: String
    var headerRows: [String]
    var bodyRows: [String]
    /// First body row shown when not following. Clamped on every update and
    /// re-clamped against the current frame height when drawing.
    var scrollOffset: Int
    /// While `true` the window sticks to the last body rows, so new rows
    /// appended by ``replace(headerRows:bodyRows:frameRows:)`` stay visible.
    var isFollowing: Bool

    /// The title of the `/subagent` detail panel.
    static let subAgentTitle = " 👥 Sub-agent "
    /// Narrowest frame whose interior row keeps one content column between
    /// `│ ` and ` │`; narrower terminals get this minimal frame.
    private static let minimumColumns = 5

    init(
        mode: Mode = .showing,
        availability: Availability = .loading,
        title: String = subAgentTitle,
        headerRows: [String] = [],
        bodyRows: [String] = []
    ) {
        self.mode = mode
        self.availability = availability
        self.title = title
        self.headerRows = headerRows
        self.bodyRows = bodyRows
        scrollOffset = 0
        isFollowing = true
    }

    /// Rows available to the body window in a frame `frameRows` rows tall.
    func bodyCapacity(frameRows: Int) -> Int {
        Self.layout(headerCount: headerRows.count, frameRows: frameRows).bodyCapacity
    }

    /// Applies a navigation key. In ``Mode/showing`` scrolling is clamped to
    /// the body and follow mode is re-derived after every scroll: it is on
    /// exactly when the window ends at the last body row. In
    /// ``Mode/choosing(entries:focusedIndex:)`` only the focus moves,
    /// cyclically. Every other action leaves the panel unchanged.
    mutating func apply(_ action: TerminalSubAgentDetailAction, frameRows: Int) {
        switch mode {
        case let .choosing(entries, focusedIndex):
            guard !entries.isEmpty else { return }
            let current = min(max(0, focusedIndex), entries.count - 1)
            switch action {
            case .focusPrevious:
                mode = .choosing(entries: entries, focusedIndex: current == 0 ? entries.count - 1 : current - 1)
            case .focusNext:
                mode = .choosing(entries: entries, focusedIndex: current == entries.count - 1 ? 0 : current + 1)
            case .scrollUp, .scrollDown, .pageUp, .pageDown, .top, .bottom, .confirm, .close, .closeList:
                return
            }
        case .showing:
            let capacity = bodyCapacity(frameRows: frameRows)
            let maximum = Self.maximumOffset(rowCount: bodyRows.count, capacity: capacity)
            // Scroll from the window actually on screen: while following it
            // sits at the bottom whatever the stored offset says.
            let current = isFollowing ? maximum : min(max(0, scrollOffset), maximum)
            let target: Int
            switch action {
            case .scrollUp: target = current - 1
            case .scrollDown: target = current + 1
            case .pageUp: target = current - max(1, capacity)
            case .pageDown: target = current + max(1, capacity)
            case .top: target = 0
            case .bottom: target = maximum
            case .focusPrevious, .focusNext, .confirm, .close, .closeList:
                return
            }
            scrollOffset = min(max(0, target), maximum)
            isFollowing = scrollOffset == maximum
        }
    }

    /// Replaces the rows with a fresh read. Follow mode keeps the window on
    /// the last body rows; otherwise the offset is only clamped, so the rows
    /// the operator is reading stay in place. `isFollowing` is unchanged.
    mutating func replace(headerRows: [String], bodyRows: [String], frameRows: Int) {
        self.headerRows = headerRows
        self.bodyRows = bodyRows
        let maximum = Self.maximumOffset(rowCount: bodyRows.count, capacity: bodyCapacity(frameRows: frameRows))
        scrollOffset = isFollowing ? maximum : min(max(0, scrollOffset), maximum)
    }

    /// Draws the framed panel as exactly `rows` lines, each `columns` visible
    /// columns wide (at least the minimal 5-column frame). One row draws only
    /// the top border, two rows draw both borders. When the body exceeds its
    /// window the bottom border carries a right-aligned 1-based indicator:
    /// `rows a–b/n` for the body rows in ``Mode/showing``, `a–b/n` for the
    /// entries in ``Mode/choosing(entries:focusedIndex:)`` while some of them
    /// are not shown.
    func frameLines(rows: Int, columns: Int) -> [String] {
        guard rows > 0 else { return [] }
        let columns = max(Self.minimumColumns, columns)
        let top = Self.borderLine(left: "╭", right: "╮", label: title, columns: columns)
        guard rows > 1 else { return [top] }

        let layout = Self.layout(headerCount: headerRows.count, frameRows: rows)
        let window = bodyWindow(capacity: layout.bodyCapacity)
        var lines = [top]
        if layout.headerCount > 0 {
            lines += headerRows.prefix(layout.headerCount).map { Self.interiorLine($0, columns: columns) }
            let border = TerminalStyle.Chrome.border, reset = TerminalStyle.reset
            lines.append(border + "├" + String(repeating: "─", count: columns - 2) + "┤" + reset)
        }
        lines += window.rows.map { Self.interiorLine($0, columns: columns) }
        lines += Array(
            repeating: Self.interiorLine("", columns: columns),
            count: max(0, layout.bodyCapacity - window.rows.count)
        )
        lines.append(
            Self.borderLine(left: "╰", right: "╯", label: window.indicator, trailing: true, columns: columns)
        )
        return lines
    }

    // MARK: - Layout

    private struct Layout {
        let headerCount: Int
        let bodyCapacity: Int
    }

    /// The shared row budget documented on the type.
    private static func layout(headerCount: Int, frameRows: Int) -> Layout {
        let interior = max(0, frameRows - 2)
        let headerBudget = interior / 2
        let visibleHeader = headerBudget >= 2 ? min(headerCount, headerBudget - 1) : 0
        let separator = visibleHeader > 0 ? 1 : 0
        return Layout(headerCount: visibleHeader, bodyCapacity: interior - visibleHeader - separator)
    }

    private static func maximumOffset(rowCount: Int, capacity: Int) -> Int {
        max(0, rowCount - capacity)
    }

    /// The body rows on screen and the indicator of the bottom border, `nil`
    /// while the whole body is on screen.
    private func bodyWindow(capacity: Int) -> (rows: [String], indicator: String?) {
        switch mode {
        case let .choosing(entries, focusedIndex):
            return Self.choiceWindow(entries, focusedIndex: focusedIndex, capacity: capacity)
        case .showing:
            let maximum = Self.maximumOffset(rowCount: bodyRows.count, capacity: capacity)
            let start = isFollowing ? maximum : min(max(0, scrollOffset), maximum)
            let end = min(bodyRows.count, start + capacity)
            let rows = start < end ? Array(bodyRows[start..<end]) : []
            let indicator = bodyRows.count > capacity && capacity > 0
                ? " rows \(start + 1)–\(start + rows.count)/\(bodyRows.count) "
                : nil
            return (rows, indicator)
        }
    }

    /// The choice list's window documented on the type, and its `a–b/n`
    /// indicator of the entries shown while some are not.
    private static func choiceWindow(
        _ entries: [ChoiceEntry],
        focusedIndex: Int,
        capacity: Int
    ) -> (rows: [String], indicator: String?) {
        guard capacity > 0, !entries.isEmpty else { return ([], nil) }
        let focused = min(max(0, focusedIndex), entries.count - 1)
        let blocks = entries.indices.map { choiceRows(entries[$0], isFocused: $0 == focused) }
        let separatedHeight = blocks.reduce(0) { $0 + $1.count } + blocks.count - 1
        if separatedHeight <= capacity {
            return (Array(blocks.joined(separator: [""])), nil)
        }
        var lower = focused, upper = focused
        var used = blocks[focused].count, above = 0, below = 0
        while used < capacity {
            let fitsAbove = lower > 0 && used + blocks[lower - 1].count <= capacity
            let fitsBelow = upper < blocks.count - 1 && used + blocks[upper + 1].count <= capacity
            if fitsAbove, above <= below || !fitsBelow {
                lower -= 1
                used += blocks[lower].count
                above += blocks[lower].count
            } else if fitsBelow {
                upper += 1
                used += blocks[upper].count
                below += blocks[upper].count
            } else {
                break
            }
        }
        // `prefix` only cuts a focused block taller than the body.
        let rows = Array(blocks[lower...upper].joined().prefix(capacity))
        let indicator = upper - lower + 1 < entries.count
            ? " \(lower + 1)–\(upper + 1)/\(entries.count) "
            : nil
        return (rows, indicator)
    }

    /// The rows of one entry's block: the title row, then the detail rows
    /// indented under it. The focused entry carries the accent `▸` on its
    /// title and an accent `┃` before each detail row, so the whole block
    /// stands out.
    private static func choiceRows(_ entry: ChoiceEntry, isFocused: Bool) -> [String] {
        let accent = TerminalStyle.Accent.primary, reset = TerminalStyle.reset
        let title = isFocused ? accent + "▸ " + entry.title + reset : "  " + entry.title
        let gutter = isFocused ? accent + "┃" + reset + "   " : "    "
        return [title] + entry.details.map { gutter + $0 }
    }

    // MARK: - Drawing

    /// An interior row of a frame `columns` wide: `│ `, the content padded to
    /// `columns - 4` columns, ` ` and the right `│`.
    ///
    /// The right border is placed with an absolute cursor move instead of
    /// relying on the padding: terminals disagree on the width of some emoji
    /// (`🛠️` is `U+1F6E0 U+FE0F`, which `TerminalANSIText.visibleWidth` counts
    /// as 2 columns while many terminals draw it 1 column wide), so a row with
    /// such a glyph would end one column short and the `│` would zigzag.
    /// `ESC[K` first clears whatever the glyph left to the right, then
    /// `ESC[<columns>G` jumps to the last column. Both are zero-width CSI
    /// sequences, so the row still measures exactly `columns` visible columns.
    private static func interiorLine(_ text: String, columns: Int) -> String {
        let width = columns - 4
        let border = TerminalStyle.Chrome.border, reset = TerminalStyle.reset
        return border + "│" + reset + " "
            + TerminalCheckboxMenu.padded(fitRow(text, width: width), width: width)
            + " " + "\u{1B}[K" + "\u{1B}[\(columns)G" + border + "│" + reset
    }

    /// A horizontal border `columns` wide, embedding `label` after the first
    /// rule segment when it fits with at least one trailing `─`. With
    /// `trailing` the label is right-aligned instead, before the last segment.
    private static func borderLine(
        left: String,
        right: String,
        label: String?,
        trailing: Bool = false,
        columns: Int
    ) -> String {
        let border = TerminalStyle.Chrome.border, reset = TerminalStyle.reset
        let inner = columns - 2
        var rule = String(repeating: "─", count: inner)
        if let label {
            let fill = inner - 1 - TerminalANSIText.visibleWidth(label)
            if fill >= 1 {
                let filler = String(repeating: "─", count: fill)
                rule = trailing ? filler + label + "─" : "─" + label + filler
            }
        }
        return border + left + rule + right + reset
    }

    /// `TerminalCheckboxMenu.fitLine` without the leading trim: newlines become
    /// spaces and trailing whitespace is dropped, but the leading indentation
    /// of list rows and transcript lines is preserved.
    private static func fitRow(_ text: String, width: Int) -> String {
        var singleLine = text.replacingOccurrences(of: "\n", with: " ")
        while singleLine.last?.isWhitespace == true {
            singleLine.removeLast()
        }
        guard TerminalANSIText.visibleWidth(singleLine) > width else { return singleLine }
        guard width > 3 else { return TerminalANSIText.truncate(singleLine, to: max(0, width)) }
        return TerminalANSIText.truncate(singleLine, to: width - 3) + "..."
    }
}
