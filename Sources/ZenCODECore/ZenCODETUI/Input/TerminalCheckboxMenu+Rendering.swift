//
//  TerminalCheckboxMenu+Rendering.swift
//  ZenCODE
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

extension TerminalCheckboxMenu {
    static func render<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selectedValues: Set<Value>,
        focusedIndex: Int,
        reservedBottomRows: Int,
        reserveSpaceBeforeDrawing: Bool
    ) -> RenderedFrame {
        let itemLines = groupedItemLines(items: items) { offset, item in
            let focus = offset == focusedIndex ? ">" : " "
            let checkbox = selectedValues.contains(item.value) ? "[x]" : "[ ]"
            return "\(focus) \(checkbox) \(item.title)\(detailSuffix(for: item))"
        }

        return renderFrame(
            title: title,
            helpLines: ["↑/↓ move · Space toggle · A all · N none · Enter confirm · Esc/Q cancel"],
            itemLines: itemLines,
            focusedIndex: focusedIndex,
            reservedBottomRows: reservedBottomRows,
            reserveSpaceBeforeDrawing: reserveSpaceBeforeDrawing
        )
    }

    static func renderSingle<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selectedValue: Value?,
        focusedIndex: Int,
        reservedBottomRows: Int,
        reserveSpaceBeforeDrawing: Bool
    ) -> RenderedFrame {
        let itemLines = groupedItemLines(items: items) { offset, item in
            let focus = offset == focusedIndex ? ">" : " "
            let marker = item.value == selectedValue ? "(x)" : "( )"
            return "\(focus) \(marker) \(item.title)\(detailSuffix(for: item))"
        }

        return renderFrame(
            title: title,
            helpLines: ["↑/↓ move · Enter select · Esc/Q cancel"],
            itemLines: itemLines,
            focusedIndex: focusedIndex,
            reservedBottomRows: reservedBottomRows,
            reserveSpaceBeforeDrawing: reserveSpaceBeforeDrawing
        )
    }

    static func renderInput(
        title: String,
        prompt: String,
        help: String?,
        reservedBottomRows: Int,
        reserveSpaceBeforeDrawing: Bool
    ) -> RenderedFrame {
        renderFrame(
            title: title,
            helpLines: inputHelpLines(help),
            itemLines: [RenderedMenuLine(text: prompt, itemIndex: nil)],
            focusedIndex: 0,
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

    static func renderFrame(
        title: String,
        helpLines: [String],
        itemLines: [RenderedMenuLine],
        focusedIndex: Int,
        reservedBottomRows: Int,
        reserveSpaceBeforeDrawing: Bool
    ) -> RenderedFrame {
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
        let borderColor = "\u{1B}[38;5;208m"
        let resetColor = "\u{1B}[0m"
        let horizontalRule = String(repeating: "─", count: max(0, boxWidth - 2))

        if reserveSpaceBeforeDrawing {
            AgentOutput.standardError.writeString(String(repeating: "\n", count: frameHeight))
        }

        writeLine(
            row: startRow,
            text: "\(borderColor)╭\(horizontalRule)╮\(resetColor)"
        )
        for (offset, line) in renderedLines.enumerated() {
            writeLine(
                row: startRow + offset + 1,
                text: "\(borderColor)│\(resetColor) \(line) \(borderColor)│\(resetColor)"
            )
        }
        writeLine(
            row: startRow + frameHeight - 1,
            text: "\(borderColor)╰\(horizontalRule)╯\(resetColor)"
        )
        return RenderedFrame(row: startRow, height: frameHeight)
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
        if ioctl(AgentOutput.standardError.fileDescriptor, TIOCGWINSZ, &size) == 0,
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

    static func longestLineLength(in lines: [String]) -> Int {
        lines.map(\.count).max() ?? 0
    }

    static func fitLine(_ text: String, width: Int) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard width > 3, singleLine.count > width else {
            return singleLine
        }
        return String(singleLine.prefix(width - 3)) + "..."
    }

    static func padded(_ text: String, width: Int) -> String {
        guard text.count < width else {
            return text
        }
        return text + String(repeating: " ", count: width - text.count)
    }

    static func clear(frame: RenderedFrame?) {
        guard let frame else {
            return
        }
        AgentOutput.standardError.writeString(
            clearFrameSequence(
                frame: frame,
                terminalRows: terminalGeometry().rows
            )
        )
    }

    static func clearFrameSequence(frame: RenderedFrame, terminalRows: Int) -> String {
        guard frame.height > 0, terminalRows > 0 else {
            return ""
        }

        let firstRow = min(max(1, frame.row), terminalRows)
        let lastRow = min(
            terminalRows,
            max(firstRow, frame.row + frame.height - 1)
        )
        var sequence = ""
        for row in firstRow...lastRow {
            sequence += "\u{1B}[\(row);1H\u{1B}[2K"
        }
        sequence += "\u{1B}[\(lastRow);1H"
        return sequence
    }

    static func writeLine(row: Int, text: String) {
        AgentOutput.standardError.writeString("\u{1B}[\(row);1H\u{1B}[2K\(text)")
    }
}
