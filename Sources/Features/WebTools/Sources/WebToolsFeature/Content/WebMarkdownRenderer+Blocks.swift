import Foundation

extension WebMarkdownRenderer {
    // MARK: Blocks

    /// Ends the current paragraph (if any) as a block of `kind`.
    mutating func flushInline(_ kind: BlockKind) {
        deferredFlush = false
        while !applied.isEmpty {
            finalizeLastAppliedWrapper()
        }
        pendingSpace = false
        guard !inline.isEmpty else { return }
        var lines: [String] = []
        inline.withUnsafeBufferPointer { buffer in
            var lineStart = 0
            for index in 0...buffer.count where index == buffer.count || buffer[index] == 0x0A {
                if index > lineStart {
                    lines.append(String(decoding: UnsafeBufferPointer(rebasing: buffer[lineStart..<index]), as: UTF8.self))
                } else if let last = lines.last, !last.isEmpty {
                    // Several <br> in a row: at most one blank line.
                    lines.append("")
                }
                lineStart = index + 1
            }
        }
        inline.removeAll(keepingCapacity: true)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return }
        appendBlock(Block(lines: lines, kind: kind))
    }

    mutating func appendBlock(_ block: Block) {
        guard !block.lines.isEmpty else { return }
        producedCount += 1
        frames[frames.count - 1].blocks.append(block)
    }

    mutating func pushFrame(_ frame: Frame) -> ExitAction {
        flushInline(.flow)
        producedCount += 1
        frames.append(frame)
        return .popFrame
    }

    mutating func popFrame() {
        guard frames.count > 1 else { return }
        if frames[frames.count - 1].kind == .preformatted {
            preDepth -= 1
        } else {
            flushInline(.flow)
        }
        let frame = frames.removeLast()
        let top = frames.count - 1
        switch frame.kind {
        case .root:
            break
        case .heading:
            let text = Self.joinedText(frame.blocks)
            guard !text.isEmpty else { return }
            let line = isMarkdown ? String(repeating: "#", count: frame.level) + " " + text : text
            appendBlock(Block(lines: [line], kind: .paragraph))
        case .summary, .term:
            let text = Self.joinedText(frame.blocks)
            guard !text.isEmpty else { return }
            let line = isMarkdown ? "**\(text)**" : text
            appendBlock(Block(lines: [line], kind: frame.kind == .term ? .term : .paragraph))
        case .blockquote:
            let lines = Self.compose(frame.blocks, style: .loose)
            appendBlock(Block(lines: Self.prefixed(lines, first: "> ", rest: "> "), kind: .paragraph))
        case .list:
            appendBlock(Block(lines: Self.compose(frame.blocks, style: .list), kind: .list))
        case .listItem:
            let lines = Self.compose(frame.blocks, style: .item)
            let indent = String(repeating: " ", count: frame.marker.count)
            appendBlock(Block(
                lines: Self.prefixed(lines, first: frame.marker, rest: indent),
                kind: .listItem,
                indent: frame.marker.count
            ))
        case .definitionList:
            appendBlock(Block(lines: Self.compose(frame.blocks, style: .definitionList), kind: .list))
        case .definition:
            let lines = Self.compose(frame.blocks, style: .item)
            appendBlock(Block(lines: Self.prefixed(lines, first: "  ", rest: "  "), kind: .definition))
        case .table:
            tableHeadDepth = frame.savedTableHeadDepth
            if !openTables.isEmpty {
                openTables.removeLast()
            }
            // Captions and stray (foster-parented) content precede the table.
            for block in frame.blocks {
                appendBlock(block)
            }
            appendBlock(Block(lines: tableLines(frame.rows), kind: .paragraph))
        case .row:
            guard frame.cells.contains(where: { !$0.isEmpty }) else { return }
            let isHeader = frame.inTableHead || frame.headerCellCount == frame.cells.count
            if frames[top].kind == .table {
                frames[top].rows.append(TableRow(cells: frame.cells, isHeader: isHeader))
            } else {
                appendBlock(Block(lines: [frame.cells.joined(separator: " | ")], kind: .flow))
            }
        case .cell:
            let text = Self.joinedText(frame.blocks)
            if frames[top].kind == .row {
                frames[top].cells.append(text)
                if frame.isHeaderCell {
                    frames[top].headerCellCount += 1
                }
            } else if !text.isEmpty {
                appendBlock(Block(lines: [text], kind: .flow))
            }
        case .preformatted:
            appendBlock(Block(lines: preformattedLines(language: frame.language), kind: .paragraph))
        }
    }

    private mutating func preformattedLines(language: String?) -> [String] {
        var bytes = preformatted
        preformatted.removeAll(keepingCapacity: true)
        // A newline right after <pre> is not content.
        if bytes.first == 0x0A {
            bytes.removeFirst()
        }
        while let last = bytes.last, last == 0x0A || last == 0x20 || last == 0x09 || last == 0x0C {
            bytes.removeLast()
        }
        var lines = String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        lines = Array(lines.drop(while: { $0.allSatisfy { $0 == " " || $0 == "\t" } }))
        guard !lines.isEmpty else { return [] }
        guard isMarkdown else { return lines }

        var longestRun = 0
        var run = 0
        for byte in bytes {
            run = byte == Self.backtick ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return [fence + (language ?? "")] + lines + [fence]
    }

    private func tableLines(_ rows: [TableRow]) -> [String] {
        guard !rows.isEmpty else { return [] }
        guard isMarkdown else {
            return rows.map { $0.cells.joined(separator: " | ") }
        }
        // Markdown tables need exactly one header row, and it must be the first
        // one: a later all-<th> row is never relocated, document order is kept.
        let header = rows[0]
        let body = Array(rows.dropFirst())
        let columns = max(1, rows.map(\.cells.count).max() ?? 1)

        func line(_ cells: [String]) -> String {
            var escaped = cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }
            while escaped.count < columns {
                escaped.append("")
            }
            return "| " + escaped.joined(separator: " | ") + " |"
        }

        let separator = "|" + String(repeating: " --- |", count: columns)
        return [line(header.cells), separator] + body.map { line($0.cells) }
    }

    // MARK: Composition

    enum ComposeStyle {
        /// Blank line between blocks (root, blockquote).
        case loose
        /// List item / definition content: tight unless a paragraph-like block.
        case item
        /// List frame: items stacked; stray blocks indented under the last item.
        case list
        /// Definition list: blank line before each new group of terms.
        case definitionList
    }

    static func compose(_ blocks: [Block], style: ComposeStyle) -> [String] {
        var lines: [String] = []
        var previous: BlockKind?
        var itemIndent: Int?
        for block in blocks where !block.lines.isEmpty {
            if let previous {
                let tight: Bool
                switch style {
                case .loose:
                    tight = (previous == .listItem && block.kind == .listItem)
                        || (block.kind == .definition && (previous == .term || previous == .definition))
                case .item:
                    tight = previous != .paragraph && block.kind != .paragraph
                case .list:
                    tight = true
                case .definitionList:
                    tight = block.kind != .term || previous == .term
                }
                if !tight {
                    lines.append("")
                }
            }
            if style == .list, block.kind != .listItem, let itemIndent {
                let indent = String(repeating: " ", count: itemIndent)
                lines.append(contentsOf: block.lines.map { $0.isEmpty ? $0 : indent + $0 })
            } else {
                lines.append(contentsOf: block.lines)
            }
            if block.kind == .listItem {
                itemIndent = block.indent
            }
            previous = block.kind
        }
        return lines
    }

    static func prefixed(_ lines: [String], first: String, rest: String) -> [String] {
        var result: [String] = []
        result.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            let prefix = index == 0 ? first : rest
            if line.isEmpty {
                var trimmed = prefix
                while trimmed.last == " " {
                    trimmed.removeLast()
                }
                result.append(trimmed)
            } else {
                result.append(prefix + line)
            }
        }
        return result
    }
}
