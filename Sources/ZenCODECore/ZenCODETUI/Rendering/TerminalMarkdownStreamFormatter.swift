//
//  TerminalMarkdownStreamFormatter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/05/26.
//

import Foundation
import Markdown

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
    /// A zero-width non-whitespace prefix used only while parsing an inline
    /// tail. It prevents the tail from being reinterpreted as a new block when
    /// its logical line has already streamed prose before it.
    private static let inlineParsingSentinel = "\u{200B}"
    /// Keep the whitespace definition used by `trimmingCharacters(in:)` while
    /// incrementally classifying a line start for safe prose streaming.
    private static let blockMarkerWhitespace = CharacterSet.whitespaces
    
    /// Multi-line markdown constructs that must be parsed as a whole block
    /// rather than one isolated line at a time. Buffering these lets the
    /// renderer handle nested lists, multi-line blockquotes, and GFM tables.
    private enum BlockKind {
        case list
        case blockQuote
        case tableCandidate
        case table
    }

    /// Incremental classification of the still-unemitted line start. A line
    /// can only move from an unresolved marker candidate to either a known
    /// block marker or a known-safe prose prefix. Once it is known safe, later
    /// deltas cannot turn that already-observed prefix into a block marker.
    private enum PendingLineStartState {
        case leadingWhitespace
        case hashRun(Int)
        case dashRun(Int)
        case plus
        case digitRun(Int)
        case orderedListDot
        case deferredWhitespace
        case ambiguousBlockMarker
        case resolved
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
    /// Scalar length of the un-emitted pending tail. Scalar counts do not change
    /// when a subsequent delta completes a grapheme cluster, unlike
    /// `String.count`; that makes the buffering limit stable across combining,
    /// ZWJ, and regional-indicator boundaries.
    private var pendingLineScalarCount = 0
    /// Whether part of the current logical line was already written. The
    /// emitted text is removed from `pendingLine` immediately, so no
    /// `String.Index` survives an append mutation of that string.
    private var hasEmittedPendingPrefix = false
    /// Terminal-column offset of the un-emitted tail, not a character count.
    /// This accounts for CJK/emoji width and combining marks when an inline tail
    /// must be wrapped after streamed prose.
    private var emittedPendingPrefixColumn = 0
    /// Cached, incremental block-marker classification for the current line.
    /// It is reset only when that line is completed or force-flushed.
    private var pendingLineStartState: PendingLineStartState = .leadingWhitespace
    
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

        var rendered = ""

        // Search only the newly received text for line boundaries. Looking for
        // a newline in the whole accumulated pending line on every micro-delta
        // makes a long no-newline prose response quadratic.
        var segmentStart = text.startIndex
        while let newlineIndex = text[segmentStart...].firstIndex(of: "\n") {
            appendToPendingLine(text[segmentStart..<newlineIndex])
            rendered += completePendingLine()
            segmentStart = text.index(after: newlineIndex)
        }
        appendToPendingLine(text[segmentStart...])

        // Incremental streaming: emit the safe prefix of the pending prose
        // line as soon as it arrives, without waiting for the newline. Only
        // active outside code fences and buffered blocks (lists, blockquotes,
        // tables), which have their own streaming/buffering strategies.
        rendered += streamPendingLineIfSafe()

        if pendingLineScalarCount > Self.maxBufferedLineLength {
            if shouldFlushPendingLineForStreaming(pendingLine) {
                rendered += flushBlock()
                // The normal prose tail has not been parsed as a block and can
                // be emitted directly. Preserve the fact that this logical line
                // already has output, so the next delta is never reclassified as
                // a fresh heading/list/quote marker.
                let tail = pendingLine
                rendered += tail
                recordEmittedPendingPrefix(tail)
                clearPendingTailPreservingLineContext()
            } else if pendingLineScalarCount > Self.maxMarkdownBufferedLineLength {
                rendered += flushBlock()
                let tail = pendingLine
                let tailRendered: String
                if hasEmittedPendingPrefix {
                    tailRendered = renderInlineFragment(
                        tail,
                        startingAtColumn: emittedPendingPrefixColumn
                    )
                } else {
                    tailRendered = renderCompleteLine(
                        tail,
                        appendsNewline: false
                    )
                }
                rendered += tailRendered
                recordEmittedPendingPrefix(tailRendered)
                clearPendingTailPreservingLineContext()
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
            resetPendingLineState()
        }
        var rendered = ""
        if !pendingLine.isEmpty {
            if hasEmittedPendingPrefix {
                rendered += completePartiallyEmittedLine(
                    pendingLine,
                    startingAtColumn: emittedPendingPrefixColumn,
                    appendsNewline: false
                )
            } else {
                rendered += handleCompleteLine(pendingLine, appendsNewline: false)
            }
        }
        rendered += flushBlock()
        return rendered
    }

    /// Appends a no-newline input segment and updates all state whose cost must
    /// be proportional to that segment, never to the complete pending line.
    private mutating func appendToPendingLine(_ segment: Substring) {
        guard !segment.isEmpty else {
            return
        }
        pendingLine.append(contentsOf: segment)
        pendingLineScalarCount += segment.unicodeScalars.count
        updatePendingLineStartState(with: segment)
    }

    /// Renders the pending line at a known newline boundary, then clears every
    /// line-local cache. This keeps consecutive newlines and multiple complete
    /// lines in one input delta equivalent to the former buffered path.
    private mutating func completePendingLine() -> String {
        let rendered: String
        if hasEmittedPendingPrefix {
            rendered = completePartiallyEmittedLine(
                pendingLine,
                startingAtColumn: emittedPendingPrefixColumn
            )
        } else {
            rendered = handleCompleteLine(pendingLine)
        }
        resetPendingLineState()
        return rendered
    }

    /// Emits only the newly safe prose range. The emitted source is removed
    /// immediately, so a later append sees only the un-emitted tail and cannot
    /// invalidate a stored index into `pendingLine`.
    private mutating func streamPendingLineIfSafe() -> String {
        guard !isInCodeFence,
              blockKind == nil,
              !pendingLine.isEmpty else {
            return ""
        }

        let safeEnd = safeStreamingEmitEnd(in: pendingLine)
        guard safeEnd > pendingLine.startIndex else {
            return ""
        }

        let fragment = String(pendingLine[..<safeEnd])
        pendingLine.removeSubrange(pendingLine.startIndex..<safeEnd)
        pendingLineScalarCount = max(
            0,
            pendingLineScalarCount - fragment.unicodeScalars.count
        )
        recordEmittedPendingPrefix(fragment)
        return fragment
    }

    /// Clears the full set of line-local streaming state. It is deliberately
    /// shared by normal newline handling, safety flushes, and `finish()` so a
    /// formatter can safely be reused after any of those paths.
    private mutating func resetPendingLineState() {
        pendingLine = ""
        pendingLineScalarCount = 0
        hasEmittedPendingPrefix = false
        emittedPendingPrefixColumn = 0
        pendingLineStartState = .leadingWhitespace
    }

    /// Drops an already-rendered tail after a safety flush without pretending
    /// that the following delta begins a new logical line. This is distinct from
    /// `resetPendingLineState()`, which is only valid at a real newline or end
    /// of stream.
    private mutating func clearPendingTailPreservingLineContext() {
        pendingLine = ""
        pendingLineScalarCount = 0
        hasEmittedPendingPrefix = true
        pendingLineStartState = .resolved
    }

    /// Records the terminal column after output already emitted for this
    /// logical line. `TerminalANSIText.visibleWidth` counts visible cells rather
    /// than Swift `Character`s, so wide CJK/emoji clusters and zero-width
    /// combining marks get the same treatment as the renderer's wrapper.
    private mutating func recordEmittedPendingPrefix(_ rendered: String) {
        guard !rendered.isEmpty else {
            hasEmittedPendingPrefix = true
            return
        }
        hasEmittedPendingPrefix = true
        emittedPendingPrefixColumn = endingTerminalColumn(
            after: rendered,
            startingAtColumn: emittedPendingPrefixColumn
        )
    }

    /// Finds the visual column after `rendered`, honoring any wrapping/newlines
    /// produced while flushing a long inline fragment.
    private func endingTerminalColumn(
        after rendered: String,
        startingAtColumn column: Int
    ) -> Int {
        let physicalLines = rendered.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard let finalLine = physicalLines.last else {
            return column
        }
        let startsNewPhysicalLine = physicalLines.count > 1
        let start = startsNewPhysicalLine ? 0 : column
        let visible = TerminalANSIText.visibleWidth(String(finalLine))
        guard renderWidth > 0 else {
            return start + visible
        }
        // Match the one-column reservation used by both wrapping paths. The
        // streamed prefix is raw terminal text, so reducing the accumulated
        // column after a full visual row avoids treating a wrapped prefix as an
        // ever-growing offset for its later inline tail.
        let contentWidth = max(1, renderWidth - 1)
        return (start + visible) % contentWidth
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
                // The delimiter itself can be the oversized line. Enforce the
                // table cap at confirmation time rather than waiting for a body
                // row, otherwise a two-line pathological table remains buffered
                // indefinitely until another delta arrives.
                if shouldFlushBufferedBlock() {
                    return flushBufferedBlockForSafety()
                }
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
        // incoherent AST/layout. A confirmed table (.table) and its one-line
        // candidate (.tableCandidate) both use the dedicated cap: a candidate
        // can itself contain an arbitrarily long header while it waits for a
        // delimiter, so exempting it would leave an unbounded hole.
        if blockKind == .table || blockKind == .tableCandidate {
            if blockLines.count >= Self.maxBufferedTableLineCount {
                return true
            }
            return blockLines.reduce(0) { $0 + $1.count } >= Self.maxBufferedTableCharacterCount
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
        _ tail: String,
        startingAtColumn: Int,
        appendsNewline: Bool = true
    ) -> String {
        let newline = appendsNewline ? "\n" : ""
        guard !tail.isEmpty else {
            return newline
        }
        let rendered = renderInlineFragment(
            tail,
            startingAtColumn: startingAtColumn
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
        // A partial tail starts in the middle of an already-emitted logical
        // line. Prefixing a zero-width, non-whitespace sentinel keeps leading
        // `-`, `#`, `>` and similar characters as inline prose rather than
        // allowing the document parser to create a fresh block. Remove only the
        // synthetic first occurrence after rendering; user content remains
        // untouched.
        let source = Self.inlineParsingSentinel + sanitizedMarkdownSource(fragment)
        var renderer = makeRenderer()
        let document = Document(parsing: source)
        let rendered = renderer.visit(document)
        let withoutSentinel: String
        if let sentinelRange = rendered.range(of: Self.inlineParsingSentinel) {
            withoutSentinel = rendered.replacingCharacters(
                in: sentinelRange,
                with: ""
            )
        } else {
            withoutSentinel = rendered
        }
        return wrapWithColumnOffset(
            withoutSentinel,
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

    /// Computes the end of the newly safe pending-line prefix.
    ///
    /// Block-marker ambiguity is classified as input arrives and cached in
    /// `pendingLineStartState`; emitted prose has already been removed from
    /// `pendingLine`, so the scanner below only walks fresh text.
    ///
    /// The safe prefix ends before:
    /// 1. Any potential block marker at the line start (buffered until the
    ///    ambiguity resolves, so headings/lists/quotes/fences are never
    ///    emitted raw).
    /// 2. Any character in `streamingStopChars` (`` ` ``, `*`, `_`, `~`, `[`,
    ///    `<`, `|`) that could be the start of an inline element or table
    ///    separator completed by a later delta.
    private func safeStreamingEmitEnd(in line: String) -> String.Index {
        guard case .resolved = pendingLineStartState else {
            return line.startIndex
        }

        var index = line.startIndex
        while index < line.endIndex {
            if Self.streamingStopChars.contains(line[index]) {
                break
            }
            index = line.index(after: index)
        }
        return index
    }

    /// Feeds only newly appended characters into the block-marker classifier.
    /// It mirrors the prior full-line block-marker decisions without repeatedly
    /// trimming/scanning the complete pending line while a marker candidate is
    /// split across many small deltas.
    private mutating func updatePendingLineStartState(with segment: Substring) {
        for character in segment {
            switch pendingLineStartState {
            case .ambiguousBlockMarker, .resolved:
                return
            default:
                advancePendingLineStartState(with: character)
            }
        }
    }

    private mutating func advancePendingLineStartState(with character: Character) {
        switch pendingLineStartState {
        case .leadingWhitespace:
            guard !isBlockMarkerWhitespace(character) else {
                return
            }
            switch character {
            case ">":
                pendingLineStartState = .ambiguousBlockMarker
            case "#":
                pendingLineStartState = .hashRun(1)
            case "-":
                pendingLineStartState = .dashRun(1)
            case "+":
                pendingLineStartState = .plus
            default:
                pendingLineStartState = character.isNumber
                    ? .digitRun(1)
                    : .resolved
            }

        case .hashRun(let count):
            if character == "#" {
                pendingLineStartState = count >= 6
                    ? .resolved
                    : .hashRun(count + 1)
            } else if character == " " || character == "\t" {
                pendingLineStartState = .ambiguousBlockMarker
            } else if isBlockMarkerWhitespace(character) {
                pendingLineStartState = .deferredWhitespace
            } else {
                pendingLineStartState = .resolved
            }

        case .dashRun(let count):
            if character == "-" {
                pendingLineStartState = .dashRun(min(3, count + 1))
            } else if count >= 3 {
                pendingLineStartState = character.isWhitespace
                    ? .ambiguousBlockMarker
                    : .resolved
            } else if character == " " || character == "\t" {
                pendingLineStartState = .ambiguousBlockMarker
            } else if isBlockMarkerWhitespace(character) {
                pendingLineStartState = .deferredWhitespace
            } else {
                pendingLineStartState = .resolved
            }

        case .plus:
            if character == " " || character == "\t" {
                pendingLineStartState = .ambiguousBlockMarker
            } else if isBlockMarkerWhitespace(character) {
                pendingLineStartState = .deferredWhitespace
            } else {
                pendingLineStartState = .resolved
            }

        case .digitRun(let count):
            if character.isNumber {
                pendingLineStartState = count >= 9
                    ? .resolved
                    : .digitRun(count + 1)
            } else if character == "." {
                pendingLineStartState = .orderedListDot
            } else if isBlockMarkerWhitespace(character) {
                // Trimming removes a trailing whitespace run, so wait until a
                // later non-whitespace character proves this is not all digits.
                pendingLineStartState = .deferredWhitespace
            } else {
                pendingLineStartState = .resolved
            }

        case .orderedListDot:
            if character == " " || character == "\t" {
                pendingLineStartState = .ambiguousBlockMarker
            } else if isBlockMarkerWhitespace(character) {
                pendingLineStartState = .deferredWhitespace
            } else {
                pendingLineStartState = .resolved
            }

        case .deferredWhitespace:
            if !isBlockMarkerWhitespace(character) {
                pendingLineStartState = .resolved
            }

        case .ambiguousBlockMarker, .resolved:
            return
        }
    }

    private func isBlockMarkerWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            Self.blockMarkerWhitespace.contains($0)
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
        
        // Single pass over the line looking for inline markers (`, *, _, **,
        // __, ~~ and ]()), exiting at the first match instead of scanning the
        // string once per marker. A lone `*`/`_` is passed to the Markdown
        // parser rather than interpreted here: that preserves parser delimiter
        // rules for literal punctuation and intraword underscores while enabling
        // genuine single-delimiter emphasis.
        var previous: Character?
        for character in trimmed {
            switch character {
            case "`", "*", "_":
                return true
            case "~" where previous == "~",
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
        // Markdown code spans are delimited by matching runs, not individual
        // backticks. Toggling for each ` incorrectly exposes strong markers
        // inside ``...`` spans to the thought sanitizer.
        var activeBacktickRunLength: Int?
        while index < source.endIndex {
            let character = source[index]
            if character == "`" {
                let runLength = backtickRunLength(in: source, from: index)
                if activeBacktickRunLength == runLength {
                    activeBacktickRunLength = nil
                } else if activeBacktickRunLength == nil {
                    activeBacktickRunLength = runLength
                }
                index = source.index(index, offsetBy: runLength)
                continue
            }
            if activeBacktickRunLength == nil,
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
    
    private static func detectTerminalWidth() -> Int {
        TerminalWidth.current(
            descriptors: [1, 2, 0],
            fallback: 0
        )
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
