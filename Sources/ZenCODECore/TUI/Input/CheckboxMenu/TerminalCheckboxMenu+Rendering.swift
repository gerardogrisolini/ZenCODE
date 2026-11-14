//
//  TerminalCheckboxMenu+Rendering.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

extension TerminalCheckboxMenu {
    static func groupedItemLines<Value: Hashable>(
        items: [TerminalCheckboxMenuItem<Value>],
        itemLine: (Int, TerminalCheckboxMenuItem<Value>) -> String
    ) -> [RenderedMenuLine] {
        var lines: [RenderedMenuLine] = []
        var currentGroupTitle: String?
        for (offset, item) in items.enumerated() {
            let groupTitle = normalizedGroupTitle(item.groupTitle)
            if groupTitle != currentGroupTitle {
                if !lines.isEmpty {
                    lines.append(RenderedMenuLine(text: "", itemIndex: nil))
                }
                if let groupTitle {
                    lines.append(RenderedMenuLine(text: groupTitle, itemIndex: nil))
                }
                currentGroupTitle = groupTitle
            }
            lines.append(RenderedMenuLine(text: itemLine(offset, item), itemIndex: offset))
        }

        return lines
    }

    static func visibleItemLines(
        _ itemLines: [RenderedMenuLine],
        focusedIndex: Int,
        capacity: Int
    ) -> [String] {
        guard capacity > 0 else {
            return []
        }
        guard itemLines.count > capacity else {
            return itemLines.map(\.text)
        }

        let focusedLineIndex = itemLines.firstIndex { line in
            line.itemIndex == focusedIndex
        } ?? 0
        let windowStart = min(
            max(0, focusedLineIndex - capacity / 2),
            max(0, itemLines.count - capacity)
        )
        let windowEnd = min(itemLines.count, windowStart + capacity)
        var visibleLines = itemLines[windowStart..<windowEnd].map(\.text)
        let canShowOverflowIndicators = capacity >= 3
        if canShowOverflowIndicators, windowStart > 0, !visibleLines.isEmpty {
            visibleLines[0] = "↑ more"
        }
        if canShowOverflowIndicators, windowEnd < itemLines.count, !visibleLines.isEmpty {
            visibleLines[visibleLines.count - 1] = "↓ more"
        }
        return visibleLines
    }

    /// Rows a non-selectable header occupies in a menu frame, with the largest
    /// scroll offset it accepts.
    struct HeaderLayout: Equatable {
        /// Header rows followed by a blank separator; empty when the header is
        /// omitted.
        let lines: [String]
        /// Largest accepted scroll offset. `0` means the header is not
        /// scrollable: it is whole, or too short on room to show anything.
        let scrollLimit: Int
    }

    /// Lays a non-selectable header out in the rows shared with the items.
    ///
    /// A header that fits entirely beside the items is shown whole. Otherwise
    /// it becomes a scrollable window that keeps at least half of the rows
    /// (and every row the items leave free), so a long table stays reachable
    /// instead of being cut. `offset` is clamped to the valid range, which
    /// keeps a stale value safe after a resize.
    /// - Parameters:
    ///   - header: Header rows, already styled.
    ///   - offset: First header row shown.
    ///   - itemLineCount: Rows the items would occupy without a header.
    ///   - itemCapacity: Rows available to the header and the items together.
    static func headerLayout(
        _ header: [String],
        offset: Int,
        itemLineCount: Int,
        itemCapacity: Int
    ) -> HeaderLayout {
        guard !header.isEmpty else {
            return HeaderLayout(lines: [], scrollLimit: 0)
        }
        if header.count + 1 + itemLineCount <= itemCapacity {
            return HeaderLayout(lines: header + [""], scrollLimit: 0)
        }
        let reserved = min(
            header.count + 1,
            max(itemCapacity - min(itemLineCount, itemCapacity), itemCapacity / 2)
        )
        let viewport = reserved - 1
        guard viewport >= 1 else {
            return HeaderLayout(lines: [], scrollLimit: 0)
        }
        let limit = max(0, header.count - viewport)
        let start = min(max(0, offset), limit)
        let end = start + viewport
        var visible = Array(header[start..<end])
        if viewport >= 3 {
            if start > 0 {
                visible[0] = "↑ more"
            }
            if end < header.count {
                visible[visible.count - 1] = "↓ more"
            }
        }
        return HeaderLayout(lines: visible + [""], scrollLimit: limit)
    }

    /// Key-help lines for a menu whose header table can scroll. The line
    /// count never changes, since it takes part in the frame layout: the first
    /// line gains the Tab hint, and names the arrows' target while the table
    /// has control.
    static func scrollableHeaderHelpLines(_ help: [String], tableFocused: Bool) -> [String] {
        guard var first = help.first else {
            return help
        }
        let movePrefix = "↑/↓ move"
        if first.hasPrefix(movePrefix) {
            let rest = first.dropFirst(movePrefix.count)
            first = (tableFocused ? "↑/↓ scroll table · Tab list" : "↑/↓ move · Tab table") + rest
        } else {
            first += tableFocused ? " · Tab list" : " · Tab table"
        }
        return [first] + help.dropFirst()
    }

    static func detailSuffix<Value: Hashable>(
        for item: TerminalCheckboxMenuItem<Value>
    ) -> String {
        guard let detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty else {
            return ""
        }
        return " - \(detail)"
    }

    static func normalizedGroupTitle(_ value: String?) -> String? {
        guard let title = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return title
    }

    static func inputHelpLines(_ help: String?) -> [String] {
        guard let help = help?.trimmingCharacters(in: .whitespacesAndNewlines),
              !help.isEmpty else {
            return []
        }
        return [help]
    }

    static func terminalGeometry() -> (rows: Int, columns: Int) {
        var size = winsize()
        if ioctl(AgentOutput.standardError.fileDescriptor, UInt(TIOCGWINSZ), &size) == 0,
           size.ws_row > 0,
           size.ws_col > 0 {
            return (Int(size.ws_row), Int(size.ws_col))
        }

        let environment = ProcessInfo.processInfo.environment
        if let rawRows = environment["LINES"],
           let rows = Int(rawRows),
           rows > 0,
           let rawColumns = environment["COLUMNS"],
           let columns = Int(rawColumns),
           columns > 0 {
            return (rows, columns)
        }

        return (24, 100)
    }

    static func fitLine(_ text: String, width: Int) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard TerminalANSIText.visibleWidth(singleLine) > width else { return singleLine }
        guard width > 3 else { return TerminalANSIText.truncate(singleLine, to: max(0, width)) }
        return TerminalANSIText.truncate(singleLine, to: width - 3) + "..."
    }

    static func padded(_ text: String, width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - TerminalANSIText.visibleWidth(text)))
    }

    static func writeTerminal(_ text: String) {
        TerminalOutputSynchronization.writeOverlay(text, to: AgentOutput.standardError)
    }
}
