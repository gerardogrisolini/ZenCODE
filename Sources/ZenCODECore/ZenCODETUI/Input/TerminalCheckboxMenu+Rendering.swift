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
    static func renderMenuSequence<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selection: SelectionState<Value>,
        focusedIndex: Int,
        reservedBottomRows: Int,
        reserveSpaceBeforeDrawing: Bool
    ) -> (frame: RenderedFrame, sequence: String) {
        let itemLines = groupedItemLines(items: items) { offset, item in
            let focus = offset == focusedIndex ? ">" : " "
            let marker: String
            switch selection {
            case let .multiple(selectedValues):
                marker = selectedValues.contains(item.value) ? "[x]" : "[ ]"
            case let .single(selectedValue):
                marker = item.value == selectedValue ? "(x)" : "( )"
            }
            return "\(focus) \(marker) \(item.title)\(detailSuffix(for: item))"
        }
        return renderFrameSequence(
            title: title,
            helpLines: selection.helpLines,
            itemLines: itemLines,
            focusedIndex: focusedIndex,
            reservedBottomRows: reservedBottomRows,
            reserveSpaceBeforeDrawing: reserveSpaceBeforeDrawing
        )
    }

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

    static func renderFrameSequence(
        title: String,
        helpLines: [String],
        itemLines: [RenderedMenuLine],
        focusedIndex: Int,
        reservedBottomRows: Int,
        reserveSpaceBeforeDrawing: Bool
    ) -> (frame: RenderedFrame, sequence: String) {
        let geometry = terminalGeometry()
        let availableRows = max(3, geometry.rows - max(0, reservedBottomRows))
        let fixedLines = [title] + helpLines + [""]
        let contentCapacity = max(1, availableRows - 2)
        let itemCapacity = max(0, contentCapacity - fixedLines.count)
        let visibleItemLines = visibleItemLines(
            itemLines,
            focusedIndex: focusedIndex,
            capacity: itemCapacity
        )
        let lines = Array((fixedLines + visibleItemLines).prefix(contentCapacity))
        let boxWidth = max(20, geometry.columns)
        let contentWidth = max(1, boxWidth - 4)
        let renderedLines = lines.map { padded(fitLine($0, width: contentWidth), width: contentWidth) }
        let frameHeight = renderedLines.count + 2
        let startRow = max(1, availableRows - frameHeight + 1)
        let borderColor = TerminalStyle.Chrome.border
        let resetColor = TerminalStyle.reset
        let horizontalRule = String(repeating: "─", count: max(0, boxWidth - 2))

        var sequence = reserveSpaceBeforeDrawing
            ? String(repeating: "\n", count: frameHeight)
            : ""
        sequence += terminalLine(
            row: startRow,
            text: "\(borderColor)╭\(horizontalRule)╮\(resetColor)"
        )
        for (offset, line) in renderedLines.enumerated() {
            sequence += terminalLine(
                row: startRow + offset + 1,
                text: "\(borderColor)│\(resetColor) \(line) \(borderColor)│\(resetColor)"
            )
        }
        sequence += terminalLine(
            row: startRow + frameHeight - 1,
            text: "\(borderColor)╰\(horizontalRule)╯\(resetColor)"
        )
        return (
            frame: RenderedFrame(
                row: startRow,
                height: frameHeight,
                terminalRows: geometry.rows,
                terminalColumns: boxWidth,
                reservedBottomRows: reservedBottomRows
            ),
            sequence: sequence
        )
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

    /// Fits non-selectable header lines into `capacity` rows, followed by a
    /// blank separator. A header that does not fit is cut with an ellipsis
    /// line; without room for at least one line plus markers it is omitted.
    static func visibleHeaderLines(_ header: [String], capacity: Int) -> [String] {
        guard !header.isEmpty, capacity >= 2 else {
            return []
        }
        if header.count + 1 <= capacity {
            return header + [""]
        }
        guard capacity >= 3 else {
            return []
        }
        return Array(header.prefix(capacity - 2)) + ["…", ""]
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

    static func clearFrameSequence(
        frame: RenderedFrame,
        terminalRows: Int,
        terminalColumns: Int? = nil,
        transcriptBottomRow: Int? = nil
    ) -> String {
        guard frame.height > 0, terminalRows > 0 else {
            return ""
        }

        let currentWidth = max(1, terminalColumns ?? terminalGeometry().columns)
        let frameWidth = frame.terminalColumns > 0 ? frame.terminalColumns : currentWidth
        let physicalRowsPerFrameRow = frameWidth > currentWidth
            ? (frameWidth + currentWidth - 1) / currentWidth
            : 1
        let rowsToClear = frame.height * physicalRowsPerFrameRow
        let maximumRow = min(terminalRows, transcriptBottomRow ?? terminalRows)
        guard maximumRow > 0, frame.row <= maximumRow else {
            return ""
        }
        let firstRow = min(max(1, frame.row), maximumRow)
        let lastRow = min(
            maximumRow,
            max(firstRow, frame.row + rowsToClear - 1)
        )
        var sequence = ""
        for row in firstRow...lastRow {
            sequence += "\u{1B}[\(row);1H\u{1B}[2K"
        }
        sequence += "\u{1B}[\(lastRow);1H"
        return sequence
    }

    static func terminalLine(row: Int, text: String) -> String {
        "\u{1B}[\(row);1H\u{1B}[2K\(text)"
    }

    static func writeTerminal(_ text: String) {
        TerminalOutputSynchronization.writeOverlay(text, to: AgentOutput.standardError)
    }
}
