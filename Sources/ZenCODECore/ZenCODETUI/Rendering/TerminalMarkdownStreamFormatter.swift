//
//  TerminalMarkdownStreamFormatter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Markdown
import Synchronization

public struct TerminalMarkdownStreamFormatter {
    private static let reset = "\u{1B}[0m"
    private static let dim = "\u{1B}[90m"
    private static let code = "\u{1B}[38;5;180m"
    private static let maxBufferedLineLength = 240
    private static let maxMarkdownBufferedLineLength = 2_000
    // Soft safety net that drives incremental streaming. Kept low so list-heavy
    // model responses stay responsive: lists and blockquotes are already flushed
    // incrementally as each item/line completes, so this only nudges buffering
    // for constructs that are still open (a list item with many children).
    private static let maxBufferedBlockLineCount = 16
    private static let maxBufferedBlockCharacterCount = 2_000
    // Much higher last-resort cap. The soft limit above never truncates a block
    // mid-structure: for lists it flushes only completed items, and for a single
    // deeply-nested item it keeps buffering (preserving hierarchy) until this
    // hard cap is reached. Only then does it force-flush to avoid unbounded
    // buffering on pathological inputs.
    private static let hardBufferedBlockLineCount = 80
    private static let hardBufferedBlockCharacterCount = 12_000
    // Dedicated buffering cap for GFM tables. Tables can only be laid out once
    // the whole block is known (column widths), so they are exempt from the
    // soft cap above. To avoid unbounded buffering on a pathological table that
    // never ends, this dedicated cap triggers an explicit degradation (see
    // `flushTruncatedTable`): the rows accumulated so far are rendered as a
    // complete, coherent table followed by a dim "… table truncated" marker,
    // and further rows of the same block are discarded (the marker already
    // signals the loss). Generous 4x multiple of the soft cap so realistic
    // tables render in full while still bounding memory.
    private static let maxBufferedTableLineCount = 64
    private static let maxBufferedTableCharacterCount = 8_000
    private static let tableTruncationMarker = "… table truncated"
    /// Characters that halt incremental streaming of a prose line. The safe
    /// prefix ends before any of these: they could begin an inline markdown
    /// element (emphasis, code span, link, HTML) or a GFM table cell separator
    /// (`|`), all of which must stay buffered until the line is complete so
    /// inline formatting and table layout are preserved. Markers that span
    /// two deltas (e.g. `**` arriving as two separate deltas) are handled
    /// because the first marker character already halts emission.
    private static let streamingStopChars: Set<Character> = [
        "`", "*", "_", "~", "[", "<", "|"
    ]
    
    /// Multi-line markdown constructs that must be parsed as a whole block
    /// rather than one isolated line at a time. Buffering these lets the
    /// renderer handle nested lists, multi-line blockquotes, and GFM tables.
    private enum BlockKind {
        case list
        case blockQuote
        case tableCandidate
        case table
    }
    
    private let isEnabled: Bool
    private let fixedRenderWidth: Int?
    private let supportsHyperlinks: Bool
    private let removesUnbalancedStrongMarkers: Bool
    
    /// Visible terminal width used for reflow. When no fixed width was injected
    /// (production), this is re-read on each access so output adapts to live
    /// terminal resizes instead of being frozen at startup.
    private var renderWidth: Int {
        fixedRenderWidth ?? Self.detectTerminalWidth()
    }
    private var pendingLine = ""
    private var isInCodeFence = false
    private var codeFenceLanguage: String?
    private var blockLines: [String] = []
    private var blockKind: BlockKind?
    // Streaming ordered-list state. While flushing an ordered list item-by-item,
    // `streamingOrderedStart` holds the list's original start number and
    // `nextOrderedNumber` the number to assign to the next flushed top-level
    // item. This keeps ascending numbers (1./2./3.) even when the source uses
    // the common lazy "1./1./1." convention, which would otherwise render as
    // 1./1./1. because each item is parsed as a standalone document.
    private var streamingOrderedStart: Int?
    private var nextOrderedNumber = 0
    // Set once the active table block has hit its cap and emitted its
    // truncation marker. While true the block stays open (blockKind == .table)
    // so further table rows are routed here and discarded instead of being
    // flushed as new prose, keeping buffering bounded. A following non-table
    // line ends the block normally and resets this flag (see `flushBlock`).
    private var tableTruncated = false
    /// Number of characters at the start of the current `pendingLine` already
    /// emitted as plain streaming text. When the line completes (newline), only
    /// the un-emitted tail is rendered, preventing duplication.
    private var emittedPendingPrefixCount = 0
    
    public init(
        isEnabled: Bool,
        removesUnbalancedStrongMarkers: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.fixedRenderWidth = nil
        self.supportsHyperlinks = Self.detectHyperlinkSupport()
        self.removesUnbalancedStrongMarkers = removesUnbalancedStrongMarkers
    }
    
    init(
        isEnabled: Bool,
        renderWidth: Int,
        supportsHyperlinks: Bool,
        removesUnbalancedStrongMarkers: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.fixedRenderWidth = renderWidth
        self.supportsHyperlinks = supportsHyperlinks
        self.removesUnbalancedStrongMarkers = removesUnbalancedStrongMarkers
    }
    
    public mutating func consume(_ text: String) -> String {
        guard isEnabled else {
            return text
        }
        
        pendingLine += text
        var rendered = ""
        
        while let newlineIndex = pendingLine.firstIndex(of: "\n") {
            let line = String(pendingLine[..<newlineIndex])
            if emittedPendingPrefixCount > 0 {
                // Part of this line was already streamed as plain text.
                // Emit only the un-emitted tail to avoid duplication.
                rendered += completePartiallyEmittedLine(line)
            } else {
                rendered += handleCompleteLine(line)
            }
            pendingLine.removeSubrange(pendingLine.startIndex...newlineIndex)
            emittedPendingPrefixCount = 0
        }

        // Incremental streaming: emit the safe prefix of the pending prose
        // line as soon as it arrives, without waiting for the newline. Only
        // active outside code fences and buffered blocks (lists, blockquotes,
        // tables), which have their own streaming/buffering strategies.
        if !isInCodeFence, blockKind == nil, !pendingLine.isEmpty {
            let newEmitCount = safeStreamingEmitCount(
                in: pendingLine,
                alreadyEmitted: emittedPendingPrefixCount
            )
            if newEmitCount > emittedPendingPrefixCount {
                let emitStart = pendingLine.index(
                    pendingLine.startIndex,
                    offsetBy: emittedPendingPrefixCount
                )
                let emitEnd = pendingLine.index(
                    pendingLine.startIndex,
                    offsetBy: newEmitCount
                )
                rendered += String(pendingLine[emitStart..<emitEnd])
                emittedPendingPrefixCount = newEmitCount
            }
        }
        
        if pendingLine.count > Self.maxBufferedLineLength {
            if shouldFlushPendingLineForStreaming(pendingLine) {
                rendered += flushBlock()
                // The safe prefix was already streamed incrementally; emit
                // only the un-flushed tail to avoid duplication.
                if emittedPendingPrefixCount < pendingLine.count {
                    rendered += String(pendingLine.dropFirst(emittedPendingPrefixCount))
                }
                pendingLine = ""
                emittedPendingPrefixCount = 0
            } else if pendingLine.count > Self.maxMarkdownBufferedLineLength {
                rendered += flushBlock()
                let tail = String(pendingLine.dropFirst(emittedPendingPrefixCount))
                rendered += renderCompleteLine(tail, appendsNewline: false)
                pendingLine = ""
                emittedPendingPrefixCount = 0
            }
        }
        
        return rendered
    }
    
    public mutating func finish() -> String {
        guard isEnabled else {
            return ""
        }
        defer {
            isInCodeFence = false
            codeFenceLanguage = nil
            emittedPendingPrefixCount = 0
        }
        var rendered = ""
        if !pendingLine.isEmpty {
            if emittedPendingPrefixCount > 0 {
                rendered += completePartiallyEmittedLine(
                    pendingLine,
                    appendsNewline: false
                )
            } else {
                rendered += handleCompleteLine(pendingLine, appendsNewline: false)
            }
            pendingLine = ""
        }
        rendered += flushBlock()
        return rendered
    }
    
    /// Routes a complete line either into the pending multi-line block buffer
    /// or to immediate rendering, flushing the block when the line no longer
    /// belongs to it.
    private mutating func handleCompleteLine(
        _ line: String,
        appendsNewline: Bool = true
    ) -> String {
        let newline = appendsNewline ? "\n" : ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        
        // Code fences take precedence and are handled line by line.
        if trimmed.hasPrefix("```") {
            let flushed = flushBlock()
            if isInCodeFence {
                isInCodeFence = false
                codeFenceLanguage = nil
            } else {
                isInCodeFence = true
                codeFenceLanguage = codeFenceLanguage(from: trimmed)
            }
            return flushed + "\(Self.dim)\(line)\(Self.reset)\(newline)"
        }
        
        if isInCodeFence {
            return "\(TerminalCodeBlockRenderer.renderLine(line, language: codeFenceLanguage))\(newline)"
        }
        
        // Continue or start a multi-line block.
        if blockKind == .tableCandidate {
            if isTableDelimiterRow(trimmed) {
                blockKind = .table
                blockLines.append(line)
                return ""
            }

            let flushed = flushBlock()
            return flushed + handleCompleteLine(line, appendsNewline: appendsNewline)
        }

        if blockKind != nil {
            // Lists and blockquotes stream incrementally: when a new top-level
            // item or quote line begins, the buffered content is already a
            // complete, self-contained block and can be rendered right away.
            // This keeps list-heavy model responses from appearing only at the
            // end of the stream. Tables still buffer fully (layout needs it).
            if shouldStreamIncrementally(forLine: line, trimmed: trimmed) {
                // A blockquote whose buffered lines still hold an open `**` span
                // must keep buffering until the span closes; otherwise each line
                // would be parsed in isolation and the bold run (or, for the
                // thinking formatter, both markers) would be lost. A stray closer
                // that can never pair is still bounded by the hard cap below so a
                // malformed marker degrades to bounded latency, not unbounded
                // buffering.
                if blockKind == .blockQuote, !bufferedStrongMarkersAreBalanced() {
                    blockLines.append(line)
                    if isPastHardBufferCap() {
                        return flushBlock()
                    }
                    return ""
                }
                // A change in top-level list type (bullet ↔ ordered) starts a new
                // markdown list block: flush the whole previous block (keeping
                // the visual separation between the two list types) and restart
                // with fresh numbering state.
                if blockKind == .list,
                   listMarkerTypeChanged(toOrdered: leadingOrderedNumber(in: trimmed) != nil) {
                    // Flush the previous list block, adding a blank line after it
                    // so the visual separation between the two list types matches
                    // what the markdown document renderer produces.
                    let flushed = flushBlock()
                    beginListBlock(line: line, trimmed: trimmed)
                    return flushed + "\n"
                }
                let kind = blockKind
                let flushed = flushBlock()
                blockKind = kind
                // Restart the block with the incoming line so its continuation
                // lines (nested items, wrapped quote text) stay buffered until
                // they close, preserving nested-list and multi-paragraph runs.
                blockLines = [line]
                return flushed
            }
            if lineContinuesBlock(line, trimmed: trimmed) {
                if tableTruncated {
                    // The active table block already hit its cap and emitted a
                    // truncation marker. Discard further table rows so buffering
                    // stays bounded; the block stays open until a non-table line
                    // ends it (preserving that text). The marker already signals
                    // the data loss, so emitting these rows as raw prose would
                    // only add noise and could never reconstruct the table.
                    return ""
                }
                blockLines.append(line)
                if shouldFlushBufferedBlock() {
                    return flushBufferedBlockForSafety()
                }
                return ""
            }
            let flushed = flushBlock()
            return flushed + handleCompleteLine(line, appendsNewline: appendsNewline)
        }
        
        if let kind = blockKind(forStartLine: trimmed) {
            if kind == .list {
                // Record ordered-list state up front so incremental flushes can
                // keep ascending numbers across separately-rendered items.
                beginListBlock(line: line, trimmed: trimmed)
            } else {
                blockKind = kind
                blockLines = [line]
            }
            if shouldFlushBufferedBlock() {
                return flushBufferedBlockForSafety()
            }
            return ""
        }
        
        return renderCompleteLine(line, appendsNewline: appendsNewline)
    }
    
    private func lineContinuesBlock(_ line: String, trimmed: String) -> Bool {
        guard let kind = blockKind else {
            return false
        }
        if trimmed.isEmpty {
            return kind == .list
        }
        switch kind {
        case .tableCandidate:
            return false
        case .list:
            // List markers, indented continuation lines, or nested content.
            if isListMarker(trimmed) {
                return true
            }
            // An out-of-range "ordered-like" line (10+ digits) is not a real
            // marker, but within an active list the markdown parser treats it as
            // a lazy continuation of the current item. Keep it buffered so the
            // parser makes that decision instead of flushing the list early and
            // rendering the line as a separate paragraph.
            if isOutOfRangeOrderedLikeMarker(trimmed) {
                return true
            }
            return line.first == " " || line.first == "\t"
        case .blockQuote:
            return trimmed.hasPrefix(">")
        case .table:
            return isPotentialTableRow(trimmed)
        }
    }

    /// Returns true when the incoming line begins a fresh top-level item or
    /// quote line within the active block, meaning the previously buffered
    /// content is already complete and can be rendered immediately (incremental
    /// streaming). Tables never stream incrementally: their column layout can
    /// only be computed once the whole table is known.
    private func shouldStreamIncrementally(
        forLine line: String,
        trimmed: String
    ) -> Bool {
        guard !blockLines.isEmpty else {
            return false
        }
        switch blockKind {
        case .list:
            // A non-indented list marker starts a new top-level item; indented
            // lines belong to the current item and must stay buffered until the
            // next top-level marker arrives.
            return isTopLevelListMarker(line, trimmed: trimmed)
        case .blockQuote:
            // Each ">" line can render independently as a blockquote, so the
            // previous line flushes as soon as the next one arrives — unless an
            // inline `**` span is still open across lines (see the balance guard
            // in handleCompleteLine), in which case the block keeps buffering.
            return trimmed.hasPrefix(">")
        case .tableCandidate, .table, .none:
            return false
        }
    }

    /// A list marker at column 0 (no leading indentation): a top-level item
    /// rather than a nested or indented continuation line.
    private func isTopLevelListMarker(_ line: String, trimmed: String) -> Bool {
        guard line.first != " ", line.first != "\t" else {
            return false
        }
        return isListMarker(trimmed)
    }
    
    private func blockKind(forStartLine trimmed: String) -> BlockKind? {
        if trimmed.hasPrefix(">") {
            return .blockQuote
        }
        if isListMarker(trimmed) {
            return .list
        }
        if isPotentialTableHeader(trimmed) {
            return .tableCandidate
        }
        return nil
    }
    
    private func isListMarker(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("- ")
            || trimmed.hasPrefix("* ")
            || trimmed.hasPrefix("+ ")
            || trimmed == "-"
            || trimmed == "*"
            || trimmed == "+" {
            return true
        }
        return isOrderedListMarker(in: trimmed)
    }
    
    private func isPotentialTableHeader(_ trimmed: String) -> Bool {
        guard !isTableDelimiterRow(trimmed) else {
            return false
        }
        return isPotentialTableRow(trimmed)
    }

    private func isPotentialTableRow(_ trimmed: String) -> Bool {
        // A table candidate is confirmed only if the following line is a markdown
        // delimiter row. This one-line candidate state avoids buffering ordinary
        // prose or shell pipelines that happen to contain pipe characters.
        pipeCountOutsideInlineCode(in: trimmed) > 0
    }

    private func isTableDelimiterRow(_ trimmed: String) -> Bool {
        let cells = tableCells(in: trimmed)
        guard cells.count >= 2 else {
            return false
        }
        return cells.allSatisfy(isTableDelimiterCell)
    }

    private func tableCells(in row: String) -> [String] {
        var body = row.trimmingCharacters(in: .whitespaces)
        if body.first == "|" {
            body.removeFirst()
        }
        if body.last == "|" {
            body.removeLast()
        }
        return body
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func isTableDelimiterCell(_ cell: String) -> Bool {
        var body = cell.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else {
            return false
        }
        if body.first == ":" {
            body.removeFirst()
        }
        if body.last == ":" {
            body.removeLast()
        }
        return body.count >= 3 && body.allSatisfy { $0 == "-" }
    }

    private func pipeCountOutsideInlineCode(in line: String) -> Int {
        var count = 0
        var activeBacktickRunLength: Int?
        var index = line.startIndex

        while index < line.endIndex {
            if line[index] == "`" {
                let runLength = backtickRunLength(in: line, from: index)
                if activeBacktickRunLength == runLength {
                    activeBacktickRunLength = nil
                } else if activeBacktickRunLength == nil {
                    activeBacktickRunLength = runLength
                }
                index = line.index(index, offsetBy: runLength)
                continue
            }

            if line[index] == "|", activeBacktickRunLength == nil {
                count += 1
            }
            index = line.index(after: index)
        }

        return count
    }

    private func backtickRunLength(in line: String, from start: String.Index) -> Int {
        var length = 0
        var index = start
        while index < line.endIndex, line[index] == "`" {
            length += 1
            index = line.index(after: index)
        }
        return length
    }
    
    /// Renders and clears the buffered multi-line block, parsing it as a single
    /// markdown document so nested structure is preserved.
    private mutating func flushBlock() -> String {
        guard let kind = blockKind, !blockLines.isEmpty else {
            blockKind = nil
            blockLines = []
            tableTruncated = false
            return ""
        }
        let lines = blockLines
        blockKind = nil
        blockLines = []
        tableTruncated = false
        return renderBlock(lines: lines, kind: kind)
    }

    /// Renders an arbitrary slice of buffered lines as a single markdown
    /// document. Shared by the full-block flush and the incremental/partial
    /// list flushes so ordered-list renumbering is applied consistently.
    private mutating func renderBlock(lines: [String], kind: BlockKind) -> String {
        var sourceLines = kind == .list
            ? compactListBlockLines(lines)
            : lines
        if kind == .list, streamingOrderedStart != nil {
            let renumbered = renumberTopLevelOrderedMarkers(sourceLines, from: nextOrderedNumber)
            sourceLines = renumbered.lines
            nextOrderedNumber = renumbered.next
        }
        let source = sanitizedMarkdownSource(sourceLines.joined(separator: "\n"))
        var renderer = makeRenderer()
        let document = Document(parsing: source)
        return wrapIfNeeded(renderer.visit(document)) + "\n"
    }

    private func shouldFlushBufferedBlock() -> Bool {
        // Tables require the complete block to compute column layout, so they
        // are exempt from the soft list/blockquote caps. They use a dedicated,
        // more generous cap: a table is rendered whole or, once the cap is
        // exceeded, explicitly truncated (see `flushTruncatedTable`). We never
        // route a partial table through the generic flush, which would yield an
        // incoherent AST/layout. A confirmed table (.table) uses the dedicated
        // table cap; a one-line candidate (.tableCandidate) holds a single
        // unresolved header line and is never flushed here.
        if blockKind == .table {
            if blockLines.count >= Self.maxBufferedTableLineCount {
                return true
            }
            return blockLines.reduce(0) { $0 + $1.count } >= Self.maxBufferedTableCharacterCount
        }
        guard blockKind != .tableCandidate else {
            return false
        }
        if blockLines.count >= Self.maxBufferedBlockLineCount {
            return true
        }
        return blockLines.reduce(0) { $0 + $1.count } >= Self.maxBufferedBlockCharacterCount
    }

    /// Handles the safety-limit trigger. For lists, flush only the completed
    /// top-level items and keep the still-open item buffered so its nested
    /// children are never promoted to the top level. Only fall back to a full
    /// flush past the much higher hard cap to avoid unbounded buffering.
    private mutating func flushBufferedBlockForSafety() -> String {
        // Tables: render the rows accumulated so far as a complete table and
        // append an explicit dim truncation marker, then mark the block as
        // truncated so subsequent rows are discarded. This never flushes a
        // half-table as raw markdown, which would corrupt the column layout.
        if blockKind == .table {
            return flushTruncatedTable()
        }
        if blockKind == .list {
            if let partial = flushCompletedListItems(), !partial.isEmpty {
                return partial
            }
            // No completed item to split off (a single deeply-nested item).
            // Keep buffering until the hard cap, preserving hierarchy in the
            // common case; force-flush only as a last resort.
            if isPastHardBufferCap() {
                return flushBlock()
            }
            return ""
        }
        // A blockquote with an open `**` span must defer flush until the span
        // closes (or the hard cap), matching the guard in handleCompleteLine.
        // Without this, a single quote line beyond the soft char cap would be
        // flushed in isolation and the multiline bold run would be lost.
        if blockKind == .blockQuote, !bufferedStrongMarkersAreBalanced() {
            if isPastHardBufferCap() {
                return flushBlock()
            }
            return ""
        }
        return flushBlock()
    }

    /// Explicit degradation for a table that exceeded its buffering cap. The
    /// rows buffered so far (header + delimiter + as many body rows as fit) are
    /// rendered as a single, coherent table, followed by a dim
    /// "… table truncated" marker line. The block is then marked truncated:
    /// `blockKind` stays `.table` so further rows are routed back here and
    /// discarded (bounded memory), while a following non-table line ends the
    /// block normally and is never lost. We discard rather than emit subsequent
    /// rows as literal text because raw `| a | b |` prose would be visually
    /// noisy and could not reconstruct the table; the marker communicates the
    /// loss unambiguously and keeps output coherent with the formatter's style.
    private mutating func flushTruncatedTable() -> String {
        let lines = blockLines
        blockLines = []
        tableTruncated = true
        var rendered = renderBlock(lines: lines, kind: .table)
        rendered += "\(Self.dim)\(Self.tableTruncationMarker)\(Self.reset)\n"
        return rendered
    }

    /// Whether the buffered block has exceeded the much higher hard cap used
    /// only as a last resort to bound buffering on pathological inputs.
    private func isPastHardBufferCap() -> Bool {
        blockLines.count >= Self.hardBufferedBlockLineCount
            || blockLines.reduce(0) { $0 + $1.count } >= Self.hardBufferedBlockCharacterCount
    }

    /// Whether the incoming top-level list marker is a different type (ordered
    /// vs unordered) than the current list block. In markdown such a change
    /// starts a new list block, so the old one should be flushed in full and
    /// numbering state reset.
    private func listMarkerTypeChanged(toOrdered newIsOrdered: Bool) -> Bool {
        let blockIsOrdered = streamingOrderedStart != nil
        return newIsOrdered != blockIsOrdered
    }

    /// Flushes every completed top-level list item, leaving the last
    /// (still-open) item and its continuation/nested lines buffered. Returns nil
    /// when there is no completed item to split off (only one open item).
    private mutating func flushCompletedListItems() -> String? {
        guard blockKind == .list,
              let split = lastTopLevelItemStartIndex(in: blockLines),
              split > 0 else {
            return nil
        }
        let toFlush = Array(blockLines[..<split])
        blockLines = Array(blockLines[split...])
        return renderBlock(lines: toFlush, kind: .list)
    }

    /// Index of the last top-level (column-0) list marker in `lines`, or nil
    /// when there is none. Used to split completed items from the still-open one.
    private func lastTopLevelItemStartIndex(in lines: [String]) -> Int? {
        var lastIndex: Int?
        for (index, line) in lines.enumerated() {
            guard line.first != " ", line.first != "\t" else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, isListMarker(trimmed) else { continue }
            lastIndex = index
        }
        return lastIndex
    }

    /// Starts a fresh list block and records whether it is an ordered list so
    /// the streaming flush can keep ascending numbers across separately-rendered
    /// items (the common "1./1./1." lazy convention renders as 1./2./3.).
    private mutating func beginListBlock(line: String, trimmed: String) {
        blockKind = .list
        blockLines = [line]
        if let start = leadingOrderedNumber(in: trimmed) {
            streamingOrderedStart = start
            nextOrderedNumber = start
        } else {
            streamingOrderedStart = nil
            nextOrderedNumber = 0
        }
    }

    /// Rewrites the leading number of every top-level ordered-list marker so a
    /// list streamed item-by-item keeps ascending numbers. Unordered markers and
    /// indented continuation lines are left untouched. Renumbering stops once the
    /// ascending number would reach 10 digits (1_000_000_000): beyond that Swift
    /// Markdown treats the marker as plain text, so leaving it verbatim keeps the
    /// rendered output coherent with the document parser.
    private func renumberTopLevelOrderedMarkers(
        _ lines: [String],
        from start: Int
    ) -> (lines: [String], next: Int) {
        var current = start
        var result: [String] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            if line.first != " ", line.first != "\t",
               current <= 999_999_999,
               let replaced = renumberLeadingOrderedMarker(in: line, to: current) {
                result.append(replaced)
                current += 1
            } else {
                result.append(line)
            }
        }
        return (result, current)
    }

    /// Replaces the leading "<digits>." of an ordered marker with `number.`.
    /// Returns nil when the line does not start with an ordered marker.
    private func renumberLeadingOrderedMarker(in line: String, to number: Int) -> String? {
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            index = line.index(after: index)
        }
        guard index > line.startIndex,
              index < line.endIndex,
              line[index] == "." else {
            return nil
        }
        let afterDot = line.index(after: index)
        guard afterDot == line.endIndex || line[afterDot].isWhitespace else {
            return nil
        }
        return "\(number)." + line[afterDot...]
    }

    /// The leading integer of an ordered-list marker (e.g. "1." -> 1), or nil
    /// when the trimmed line is not an ordered marker. Values beyond a safe
    /// threshold are treated as non-markers: no real list has millions of items,
    /// and incrementing such a number during renumbering would overflow Int.
    private func leadingOrderedNumber(in trimmed: String) -> Int? {
        var digits = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index].isNumber {
            digits.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        guard !digits.isEmpty,
              index < trimmed.endIndex,
              trimmed[index] == "." else {
            return nil
        }
        let afterDot = trimmed.index(after: index)
        guard afterDot == trimmed.endIndex || trimmed[afterDot].isWhitespace else {
            return nil
        }
        // Clamp to a safe range: Swift Markdown accepts up to 9 digits, so valid
        // markers up to 999_999_999 are supported. Beyond that the number can't
        // be a real list index, and incrementing it during renumbering would risk
        // overflow. Treat out-of-range values as plain markers (verbatim render).
        guard digits.count <= 9, let value = Int(digits), value <= 999_999_999 else {
            return nil
        }
        return value
    }

    /// True when the `**` strong markers accumulated in the current block buffer
    /// are all paired. When unbalanced, an inline span is still open across
    /// lines and the block must keep buffering instead of streaming line-by-line.
    private func bufferedStrongMarkersAreBalanced() -> Bool {
        hasBalancedStrongMarkers(in: blockLines.joined(separator: "\n"))
    }

    /// Whether every `**` marker in `source` (outside inline code) is paired
    /// with an opener/closer, using the same pairing rules as the sanitizer.
    private func hasBalancedStrongMarkers(in source: String) -> Bool {
        let markers = strongMarkersOutsideInlineCode(in: source)
        guard !markers.isEmpty else {
            return true
        }
        var openStack: [Int] = []
        var kept = Set<Int>()
        for (index, marker) in markers.enumerated() {
            if marker.canClose, let opener = openStack.popLast() {
                kept.insert(opener)
                kept.insert(index)
            } else if marker.canOpen {
                openStack.append(index)
            }
        }
        return kept.count == markers.count
    }

    private func compactListBlockLines(_ lines: [String]) -> [String] {
        lines.filter { line in
            !line.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
    
    private mutating func renderCompleteLine(
        _ line: String,
        appendsNewline: Bool
    ) -> String {
        let newline = appendsNewline ? "\n" : ""
        
        guard mayContainMarkdown(in: line) else {
            return "\(wrapIfNeeded(line))\(newline)"
        }
        
        let parsed = leadingIndent(in: sanitizedMarkdownSource(line))
        var renderer = makeRenderer()
        let document = Document(parsing: parsed.body)
        let rendered = "\(parsed.indent)\(renderer.visit(document))"
        return "\(wrapIfNeeded(rendered))\(newline)"
    }
    
    // MARK: - Incremental prose streaming

    /// Completes a line whose prefix was already emitted as plain streaming
    /// text. Only the un-emitted tail is output, preventing duplication. The
    /// tail is rendered through the inline markdown renderer so that inline
    /// markers (`**bold**`, `` `code` ``, `[link](url)`) that arrived after the
    /// safe prefix are formatted rather than appearing literally. Unbalanced
    /// `**` markers are sanitized (for the thought formatter) exactly as they
    /// would be on a normally-rendered line. The already-emitted prefix is
    /// never re-output.
    private func completePartiallyEmittedLine(
        _ line: String,
        appendsNewline: Bool = true
    ) -> String {
        let newline = appendsNewline ? "\n" : ""
        if emittedPendingPrefixCount >= line.count {
            return newline
        }
        let tail = String(line.dropFirst(emittedPendingPrefixCount))
        let rendered = renderInlineFragment(
            tail,
            startingAtColumn: emittedPendingPrefixCount
        )
        return "\(rendered)\(newline)"
    }

    /// Renders an inline markdown fragment — the tail of a partially-streamed
    /// line — through the markdown renderer so inline markers are formatted.
    /// `startColumn` adjusts the wrapping width to account for the columns
    /// already occupied by the plain-text prefix emitted earlier in the same
    /// line, so the combined line respects the terminal width.
    ///
    /// - Note: Once a line has started streaming incrementally it can no longer
    ///   be treated as a block construct (e.g. a GFM table header). A pipe
    ///   (`|`) arriving in the tail is therefore rendered as inline markdown
    ///   (literal text in a paragraph), not buffered as a table candidate.
    ///   This is an inherent limitation of immediate prose streaming: the
    ///   prefix has already been written to the terminal and cannot be
    ///   retracted. In practice this only affects table headers whose first
    ///   cell text arrives before a `|` separator — the table rendering path
    ///   is exercised when the entire line (or at least its leading `|`)
    ///   arrives in a single delta.
    private func renderInlineFragment(
        _ fragment: String,
        startingAtColumn column: Int
    ) -> String {
        guard mayContainMarkdown(in: fragment) else {
            return wrapWithColumnOffset(fragment, startingAtColumn: column)
        }
        let source = sanitizedMarkdownSource(fragment)
        var renderer = makeRenderer()
        let document = Document(parsing: source)
        return wrapWithColumnOffset(
            renderer.visit(document),
            startingAtColumn: column
        )
    }

    /// Wraps text accounting for the columns already occupied on the current
    /// visual line by the streamed prefix. The prefix was emitted as plain
    /// text, so the tail starts at approximately column `column`; we reduce the
    /// available width accordingly so the first visual line does not overflow
    /// the terminal. Continuation lines use the same reduced width — a minor
    /// cosmetic trade-off, since the tail rarely wraps in practice and
    /// preventing overflow on the first line is the primary concern.
    private func wrapWithColumnOffset(
        _ text: String,
        startingAtColumn column: Int
    ) -> String {
        guard renderWidth > 0,
              !text.contains("│"),
              !text.contains("─") else {
            return text
        }
        let available = max(8, renderWidth - 1 - column)
        return TerminalANSIText.wrap(text, width: available)
    }

    /// Computes how many characters from the start of `pendingLine` can be
    /// safely emitted as plain streaming text. Returns a count >=
    /// `alreadyEmitted`.
    ///
    /// The safe prefix ends before:
    /// 1. Any potential block marker at the line start (buffered until the
    ///    ambiguity resolves, so headings/lists/quotes/fences are never
    ///    emitted raw).
    /// 2. Any character in `streamingStopChars` (`` ` ``, `*`, `_`, `~`, `[`,
    ///    `<`, `|`) that could be the start of an inline element or table
    ///    separator completed by a later delta.
    private func safeStreamingEmitCount(
        in line: String,
        alreadyEmitted: Int
    ) -> Int {
        // When nothing has been emitted yet, buffer the line start until block
        // markers are ruled out. This prevents headings, lists, blockquotes,
        // code fences, and thematic breaks from being emitted as raw text.
        if alreadyEmitted == 0 {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || lineStartCouldBeBlockMarker(trimmed) {
                return 0
            }
        }

        var count = alreadyEmitted
        var index = line.index(line.startIndex, offsetBy: alreadyEmitted)
        while index < line.endIndex {
            if Self.streamingStopChars.contains(line[index]) {
                break
            }
            count += 1
            index = line.index(after: index)
        }
        return count
    }

    /// Returns true when the trimmed line prefix could still develop into a
    /// markdown block marker (heading, list, blockquote, code fence, or
    /// thematic break). While true the line start is buffered to avoid
    /// emitting block markers as raw text. Characters that are also inline
    /// markers (`*`, `` ` ``, `_`, `<`) need no explicit check here because
    /// `streamingStopChars` already halts emission at them.
    private func lineStartCouldBeBlockMarker(_ trimmed: String) -> Bool {
        guard let first = trimmed.first else { return true }

        switch first {
        case ">":
            // Blockquote: ">" at the start always indicates a blockquote.
            return true
        case "#":
            // Heading: 1-6 '#' chars. Ambiguous while all chars are '#'
            // (could be followed by a space to form a heading).
            // 7+ '#' can never be a heading.
            let hashRun = trimmed.prefix(while: { $0 == "#" }).count
            if hashRun > 6 { return false }
            if hashRun == trimmed.count { return true }
            let afterHashes = trimmed.index(trimmed.startIndex, offsetBy: hashRun)
            return trimmed[afterHashes] == " " || trimmed[afterHashes] == "\t"
        case "-":
            // Could be list "- ", thematic break "---", or plain "-text".
            let dashRun = trimmed.prefix(while: { $0 == "-" }).count
            if dashRun == trimmed.count {
                return true // "-", "--", or "---", all ambiguous until more
            }
            let afterDashes = trimmed.index(trimmed.startIndex, offsetBy: dashRun)
            let nextChar = trimmed[afterDashes]
            if dashRun >= 3 {
                // "---" is a thematic break only when the rest of the line is
                // whitespace. "---option" is plain text: the dash run is too
                // long for a list marker ("- ") and too short-bodied for a
                // thematic break, so it should stream immediately instead of
                // being buffered until the newline.
                return nextChar.isWhitespace
            }
            // dashRun 1-2: "- " could be a list marker; anything else is plain.
            return nextChar == " " || nextChar == "\t"
        case "+":
            // Could be list "+ " or plain "+text".
            if trimmed.count == 1 { return true } // "+", ambiguous
            let afterPlus = trimmed.index(after: trimmed.startIndex)
            return trimmed[afterPlus] == " " || trimmed[afterPlus] == "\t"
        default:
            if first.isNumber {
                // Ordered list: digits + "." + whitespace. Ambiguous while we
                // only see digits or "digits.". 10+ digits can't be a marker.
                let digitRun = trimmed.prefix(while: { $0.isNumber }).count
                if digitRun > 9 { return false }
                if digitRun == trimmed.count { return true } // all digits
                let afterDigits = trimmed.index(trimmed.startIndex, offsetBy: digitRun)
                if trimmed[afterDigits] != "." { return false }
                let afterDot = trimmed.index(after: afterDigits)
                if afterDot == trimmed.endIndex { return true } // "12.", ambiguous
                return trimmed[afterDot] == " " || trimmed[afterDot] == "\t"
            }
            return false
        }
    }

    private func makeRenderer() -> TerminalSwiftMarkdownRenderer {
        // Chat output receives a leading inset after Markdown is rendered. Give
        // tables the same one-column reservation already used by wrapIfNeeded,
        // otherwise their right edge can extend beyond the terminal viewport.
        let rendererWidth = renderWidth > 0 ? max(1, renderWidth - 1) : 0
        return TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: supportsHyperlinks,
            renderWidth: rendererWidth
        )
    }
    
    /// Reflows rendered output to the terminal width, but never tables or other
    /// box-drawing content where wrapping would corrupt the layout.
    private func wrapIfNeeded(_ text: String) -> String {
        guard renderWidth > 0,
              !text.contains("│"),
              !text.contains("─") else {
            return text
        }
        // Leave one column for the chat inset prefix.
        return TerminalANSIText.wrap(text, width: max(8, renderWidth - 1))
    }
    
    private func shouldFlushPendingLineForStreaming(_ line: String) -> Bool {
        !isInCodeFence && blockKind == nil && !mayContainMarkdown(in: line)
    }
    
    private func mayContainMarkdown(in line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return false
        }
        
        if trimmed.hasPrefix("#")
            || trimmed.hasPrefix(">")
            || trimmed.hasPrefix("```")
            || trimmed.hasPrefix("<!--")
            || trimmed.hasPrefix("---")
            || trimmed.hasPrefix("***")
            || trimmed.hasPrefix("___")
            || trimmed.hasPrefix("- ")
            || trimmed.hasPrefix("* ")
            || trimmed.hasPrefix("+ ") {
            return true
        }
        
        if isOrderedListMarker(in: trimmed) {
            return true
        }
        
        // Single pass over the line looking for inline markers (`, **, __, ~~,
        // ](), exiting at the first match instead of scanning the string once
        // per marker.
        var previous: Character?
        for character in trimmed {
            switch character {
            case "`":
                return true
            case "*" where previous == "*",
                 "_" where previous == "_",
                 "~" where previous == "~",
                 "(" where previous == "]":
                return true
            default:
                break
            }
            previous = character
        }
        return false
    }
    
    private func isOrderedListMarker(in line: String) -> Bool {
        var index = line.startIndex
        var digits = 0
        while index < line.endIndex, line[index].isNumber {
            digits += 1
            index = line.index(after: index)
        }
        // Swift Markdown accepts up to 9-digit ordered markers; 10+ digits are
        // plain text. Keep this consistent with leadingOrderedNumber so the
        // streaming classification matches the parser's list detection.
        guard digits > 0, digits <= 9,
              index < line.endIndex,
              line[index] == "." else {
            return false
        }
        let afterDot = line.index(after: index)
        return afterDot < line.endIndex && line[afterDot].isWhitespace
    }

    /// True when the line looks like an ordered-list marker (digits + "." +
    /// whitespace) but the leading number has 10+ digits, which Swift Markdown
    /// rejects as plain text rather than a list marker. Within an active list
    /// block such a line is buffered as a continuation line so the parser can
    /// decide whether it is a lazy continuation of the current item.
    private func isOutOfRangeOrderedLikeMarker(_ trimmed: String) -> Bool {
        var digits = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index].isNumber {
            digits += 1
            index = trimmed.index(after: index)
        }
        guard digits > 9,
              index < trimmed.endIndex,
              trimmed[index] == "." else {
            return false
        }
        let afterDot = trimmed.index(after: index)
        return afterDot == trimmed.endIndex || trimmed[afterDot].isWhitespace
    }
    
    private func leadingIndent(in line: String) -> (indent: String, body: String) {
        let bodyStart = line.firstIndex { !$0.isWhitespace } ?? line.endIndex
        return (
            String(line[..<bodyStart]),
            String(line[bodyStart...])
        )
    }
    
    
    private struct StrongMarker {
        let range: Range<String.Index>
        let canOpen: Bool
        let canClose: Bool
    }
    
    private func sanitizedMarkdownSource(_ source: String) -> String {
        guard removesUnbalancedStrongMarkers,
              source.contains("**") else {
            return source
        }
        
        let markers = strongMarkersOutsideInlineCode(in: source)
        guard !markers.isEmpty else {
            return source
        }
        
        var openStack: [Int] = []
        var keptMarkerIndexes = Set<Int>()
        for (markerIndex, marker) in markers.enumerated() {
            if marker.canClose, let openerIndex = openStack.popLast() {
                keptMarkerIndexes.insert(openerIndex)
                keptMarkerIndexes.insert(markerIndex)
            } else if marker.canOpen {
                openStack.append(markerIndex)
            }
        }
        
        guard keptMarkerIndexes.count != markers.count else {
            return source
        }
        
        var sanitized = ""
        var markerIndex = 0
        var index = source.startIndex
        while index < source.endIndex {
            if markerIndex < markers.count,
               index == markers[markerIndex].range.lowerBound {
                if keptMarkerIndexes.contains(markerIndex) {
                    sanitized += "**"
                }
                index = markers[markerIndex].range.upperBound
                markerIndex += 1
                continue
            }
            sanitized.append(source[index])
            index = source.index(after: index)
        }
        return sanitized
    }
    
    private func strongMarkersOutsideInlineCode(in source: String) -> [StrongMarker] {
        var markers: [StrongMarker] = []
        var index = source.startIndex
        var isInInlineCode = false
        while index < source.endIndex {
            let character = source[index]
            if character == "`" {
                isInInlineCode.toggle()
                index = source.index(after: index)
                continue
            }
            if !isInInlineCode,
               source[index...].hasPrefix("**") {
                let upperBound = source.index(index, offsetBy: 2)
                markers.append(
                    StrongMarker(
                        range: index..<upperBound,
                        canOpen: strongMarkerCanOpen(in: source, at: index),
                        canClose: strongMarkerCanClose(in: source, at: index)
                    )
                )
                index = upperBound
                continue
            }
            index = source.index(after: index)
        }
        return markers
    }
    
    private func strongMarkerCanOpen(in source: String, at index: String.Index) -> Bool {
        let afterMarker = source.index(index, offsetBy: 2)
        guard afterMarker < source.endIndex else {
            return false
        }
        return !source[afterMarker].isWhitespace
    }
    
    private func strongMarkerCanClose(in source: String, at index: String.Index) -> Bool {
        guard index > source.startIndex else {
            return false
        }
        let beforeMarker = source.index(before: index)
        return !source[beforeMarker].isWhitespace
    }
    
    private func codeFenceLanguage(from line: String) -> String? {
        let info = String(line.dropFirst(3))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let language = info.split(whereSeparator: { $0.isWhitespace }).first else {
            return nil
        }
        return String(language).lowercased()
    }
    
    // MARK: - Terminal capabilities
    
    private struct CachedTerminalWidth {
        var value: Int
        var timestamp: Date
    }

    /// Short-lived cache so streaming a long response does not issue one `ioctl`
    /// per rendered line. The TTL keeps width adaptive to live terminal resizes.
    private static let terminalWidthCacheTTL: TimeInterval = 0.25
    private static let terminalWidthCache = Mutex<CachedTerminalWidth?>(nil)

    private static func detectTerminalWidth() -> Int {
        let now = Date()
        let cached = terminalWidthCache.withLock { cache -> Int? in
            guard let cache,
                  now.timeIntervalSince(cache.timestamp) < terminalWidthCacheTTL else {
                return nil
            }
            return cache.value
        }
        if let cached {
            return cached
        }

        let measured = measureTerminalWidth()
        terminalWidthCache.withLock { cache in
            cache = CachedTerminalWidth(value: measured, timestamp: now)
        }
        return measured
    }

    private static func measureTerminalWidth() -> Int {
        var size = winsize()
        let descriptors: [Int32] = [1, 2, 0]
        for descriptor in descriptors {
            if ioctl(descriptor, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
                return Int(size.ws_col)
            }
        }
        return 0
    }
    
    private static func detectHyperlinkSupport() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if let term = environment["TERM"], term == "dumb" {
            return false
        }
        // Terminals with well-known OSC 8 hyperlink support.
        if let program = environment["TERM_PROGRAM"]?.lowercased() {
            if program.contains("iterm")
                || program.contains("wezterm")
                || program.contains("vscode")
                || program.contains("ghostty")
                || program.contains("hyper") {
                return true
            }
            if program.contains("apple_terminal") {
                return false
            }
        }
        if environment["WT_SESSION"] != nil
            || environment["KITTY_WINDOW_ID"] != nil
            || environment["VTE_VERSION"] != nil {
            return true
        }
        return false
    }
}
