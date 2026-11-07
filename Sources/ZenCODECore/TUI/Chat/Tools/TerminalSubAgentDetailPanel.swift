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

/// Pure layout/state model for the `/subagent` detail panel. Terminal drawing
/// and data loading stay in the controller; this type makes the agent choice,
/// follow mode, scrolling and framing deterministic and independent of TTY
/// ownership.
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
/// the frame. In ``Mode/choosing(entries:focusedIndex:)`` the body is the
/// agent list, one row per entry. `scrollOffset` and `isFollowing` always
/// refer to `bodyRows`; the list window is derived from the focused entry.
struct TerminalSubAgentDetailPanel: Sendable, Equatable {
    struct ChoiceEntry: Sendable, Equatable {
        let agentID: String
        /// The already rendered row text; it may contain ANSI styling.
        let title: String
    }

    enum Mode: Sendable, Equatable {
        /// More than one agent can be shown: the operator picks one first.
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
    var headerRows: [String]
    var bodyRows: [String]
    /// First body row shown when not following. Clamped on every update and
    /// re-clamped against the current frame height when drawing.
    var scrollOffset: Int
    /// While `true` the window sticks to the last body rows, so new rows
    /// appended by ``replace(headerRows:bodyRows:frameRows:)`` stay visible.
    var isFollowing: Bool

    private static let title = " 👥 Sub-agent "
    /// Narrowest frame whose interior row keeps one content column between
    /// `│ ` and ` │`; narrower terminals get this minimal frame.
    private static let minimumColumns = 5

    init(
        mode: Mode = .showing,
        availability: Availability = .loading,
        headerRows: [String] = [],
        bodyRows: [String] = []
    ) {
        self.mode = mode
        self.availability = availability
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
    /// window the bottom border carries a 1-based `rows a–b/n` indicator.
    func frameLines(rows: Int, columns: Int) -> [String] {
        guard rows > 0 else { return [] }
        let columns = max(Self.minimumColumns, columns)
        let top = Self.borderLine(left: "╭", right: "╮", label: Self.title, columns: columns)
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
        let indicator: String? = window.total > layout.bodyCapacity && layout.bodyCapacity > 0
            ? " rows \(window.start + 1)–\(window.start + window.rows.count)/\(window.total) "
            : nil
        lines.append(Self.borderLine(left: "╰", right: "╯", label: indicator, columns: columns))
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

    /// The body rows on screen, the index of the first one and the total the
    /// window scrolls through.
    private func bodyWindow(capacity: Int) -> (rows: [String], start: Int, total: Int) {
        switch mode {
        case let .choosing(entries, focusedIndex):
            guard capacity > 0, !entries.isEmpty else { return ([], 0, entries.count) }
            let focused = min(max(0, focusedIndex), entries.count - 1)
            // Same centred window as `TerminalCheckboxMenu.visibleItemLines`.
            let start = min(max(0, focused - capacity / 2), max(0, entries.count - capacity))
            let end = min(entries.count, start + capacity)
            let rows = (start..<end).map { index in
                index == focused
                    ? TerminalStyle.Accent.primary + "▸ " + entries[index].title + TerminalStyle.reset
                    : "  " + entries[index].title
            }
            return (rows, start, entries.count)
        case .showing:
            let maximum = Self.maximumOffset(rowCount: bodyRows.count, capacity: capacity)
            let start = isFollowing ? maximum : min(max(0, scrollOffset), maximum)
            let end = min(bodyRows.count, start + capacity)
            return (start < end ? Array(bodyRows[start..<end]) : [], start, bodyRows.count)
        }
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
    /// rule segment when it fits with at least one trailing `─`.
    private static func borderLine(left: String, right: String, label: String?, columns: Int) -> String {
        let border = TerminalStyle.Chrome.border, reset = TerminalStyle.reset
        let inner = columns - 2
        var rule = String(repeating: "─", count: inner)
        if let label {
            let fill = inner - 1 - TerminalANSIText.visibleWidth(label)
            if fill >= 1 {
                rule = "─" + label + String(repeating: "─", count: fill)
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
