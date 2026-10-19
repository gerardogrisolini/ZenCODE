//
//  TerminalMarkdownStreamFormatter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/05/26.
//

import Foundation
import Markdown

public struct TerminalMarkdownStreamFormatter {
    private static let reset = TerminalStyle.reset
    private static let dim = TerminalStyle.Markdown.dim
    private static let maxBufferedLineLength = 240
    private static let maxMarkdownBufferedLineLength = 2_000
    // Soft cap driving incremental streaming; only constructs still open (a list
    // item with many children) are affected, as lists/quotes flush per item/line.
    private static let maxBufferedBlockLineCount = 16
    private static let maxBufferedBlockCharacterCount = 2_000
    // Last-resort cap: the soft cap never truncates a block mid-structure, so a
    // single deeply-nested item keeps buffering until this force-flush bound.
    private static let hardBufferedBlockLineCount = 80
    private static let hardBufferedBlockCharacterCount = 12_000
    // Dedicated cap for GFM tables, which need the whole block for column widths
    // and are therefore exempt from the soft cap. Exceeding it degrades
    // explicitly (see `flushTruncatedTable`).
    private static let maxBufferedTableLineCount = 64
    private static let maxBufferedTableCharacterCount = 8_000
    private static let tableTruncationMarker = "… table truncated"
    /// Characters that halt incremental streaming of a prose line: they could
    /// begin an inline element or a table cell separator, so everything from
    /// the first one stays buffered. Markers split across deltas are covered
    /// because their first character already halts emission.
    static let streamingStopChars: Set<Character> = [
        "`", "*", "_", "~", "[", "<", "|", "\r"
    ]
    /// A zero-width non-whitespace prefix used only while parsing an inline
    /// tail. It prevents the tail from being reinterpreted as a new block when
    /// its logical line has already streamed prose before it.
    static let inlineParsingSentinel = "\u{200B}"
    /// Keep the whitespace definition used by `trimmingCharacters(in:)` while
    /// incrementally classifying a line start for safe prose streaming.
    static let blockMarkerWhitespace = CharacterSet.whitespaces

    /// One policy shared by classification and streamed renumbering. CommonMark
    /// accepts at most nine digits in an ordered-list marker.
    enum OrderedListMarkerPolicy {
        static let maximumDigitCount = 9
        static let maximumValue = 999_999_999
    }

    /// Multi-line markdown constructs that must be parsed as a whole block
    /// rather than one isolated line at a time. Buffering these lets the
    /// renderer handle nested lists, multi-line blockquotes, and GFM tables.
    enum BlockKind {
        case list
        case blockQuote
        case tableCandidate
        case table
    }

    /// The exact marker that opened a fenced code block. CommonMark requires a
    /// matching marker and a closing run at least as long as the opening run;
    /// retaining both prevents an inner shorter run from terminating the block.
    struct CodeFence {
        let marker: Character
        let length: Int
        let language: String?
        var diffState = TerminalCodeBlockRenderer.DiffState()
    }

    struct CodeFenceRun {
        let marker: Character
        let length: Int
        let remainder: String
    }

    /// Shared lexical scan of an ordered-list-like prefix. Callers retain their
    /// distinct policy for an empty body and the CommonMark nine-digit limit.
    struct OrderedListMarkerScan {
        let digits: Substring
        let afterDot: String.Index
        let hasWhitespaceBody: Bool

        var digitCount: Int { digits.count }
    }

    /// Incremental classification of the still-unemitted line start. A line
    /// can only move from an unresolved marker candidate to either a known
    /// block marker or a known-safe prose prefix. Once it is known safe, later
    /// deltas cannot turn that already-observed prefix into a block marker.
    enum PendingLineStartState {
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
    let supportsHyperlinks: Bool
    let removesUnbalancedStrongMarkers: Bool
    /// Visible columns occupied by presentation added after Markdown rendering,
    /// such as nested sub-agent response indentation.
    let presentationPrefixWidth: Int
    let palette: TerminalMarkdownPalette

    /// Visible terminal width used for structured Markdown reflow. When no fixed
    /// width was injected (production), this is re-read on each access so output
    /// adapts to live terminal resizes instead of being frozen at startup. A
    /// fixed zero disables width-based reflow while preserving Markdown styling.
    var renderWidth: Int {
        fixedRenderWidth ?? Self.detectTerminalWidth()
    }
    var pendingLine = ""
    var activeCodeFence: CodeFence?
    var blockLines: [String] = []
    var blockKind: BlockKind?
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
    /// Cached, incremental block-marker classification for the current line.
    /// It is reset only when that line is completed or force-flushed.
    var pendingLineStartState: PendingLineStartState = .leadingWhitespace

    public init(
        isEnabled: Bool,
        removesUnbalancedStrongMarkers: Bool = false,
        usesTerminalWidthForStructuredContent: Bool = true,
        presentationPrefixWidth: Int = 0
    ) {
        self.isEnabled = isEnabled
        self.fixedRenderWidth = usesTerminalWidthForStructuredContent ? nil : 0
        self.supportsHyperlinks = Self.detectHyperlinkSupport()
        self.removesUnbalancedStrongMarkers = removesUnbalancedStrongMarkers
        self.presentationPrefixWidth = max(0, presentationPrefixWidth)
        self.palette = .detected
    }

    init(
        isEnabled: Bool,
        renderWidth: Int,
        supportsHyperlinks: Bool,
        removesUnbalancedStrongMarkers: Bool = false,
        usesTerminalWidthForStructuredContent: Bool = true,
        presentationPrefixWidth: Int = 0,
        palette: TerminalMarkdownPalette? = nil
    ) {
        self.isEnabled = isEnabled
        self.fixedRenderWidth = usesTerminalWidthForStructuredContent ? renderWidth : 0
        self.supportsHyperlinks = supportsHyperlinks
        self.removesUnbalancedStrongMarkers = removesUnbalancedStrongMarkers
        self.presentationPrefixWidth = max(0, presentationPrefixWidth)
        self.palette = palette ?? .detected
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
                rendered += pendingLine
                clearPendingTailPreservingLineContext()
            } else if pendingLineScalarCount > Self.maxMarkdownBufferedLineLength {
                rendered += flushBlock()
                rendered += hasEmittedPendingPrefix
                    ? renderInlineFragment(pendingLine)
                    : renderCompleteLine(pendingLine, appendsNewline: false)
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
            activeCodeFence = nil
            resetPendingLineState()
        }
        var rendered = ""
        if !pendingLine.isEmpty {
            rendered += hasEmittedPendingPrefix
                ? completePartiallyEmittedLine(pendingLine, appendsNewline: false)
                : handleCompleteLine(pendingLine, appendsNewline: false)
        }
        return rendered + flushBlock()
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
        // A CR immediately before the observed LF belongs to the same line
        // ending. Keeping CR buffered (it is a streaming stop character) makes
        // this normalization work even when the pair spans two deltas.
        let completedLine = pendingLine.hasSuffix("\r")
            ? String(pendingLine.dropLast())
            : pendingLine
        let rendered = hasEmittedPendingPrefix
            ? completePartiallyEmittedLine(completedLine)
            : handleCompleteLine(completedLine)
        resetPendingLineState()
        return rendered
    }

    /// Emits only the newly safe prose range. The emitted source is removed
    /// immediately, so a later append sees only the un-emitted tail and cannot
    /// invalidate a stored index into `pendingLine`.
    private mutating func streamPendingLineIfSafe() -> String {
        guard activeCodeFence == nil,
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
        hasEmittedPendingPrefix = true
        return fragment
    }

    /// Clears the full set of line-local streaming state. It is deliberately
    /// shared by normal newline handling, safety flushes, and `finish()` so a
    /// formatter can safely be reused after any of those paths.
    private mutating func resetPendingLineState() {
        pendingLine = ""
        pendingLineScalarCount = 0
        hasEmittedPendingPrefix = false
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

    /// Routes a complete line either into the pending multi-line block buffer
    /// or to immediate rendering, flushing the block when the line no longer
    /// belongs to it.
    mutating func handleCompleteLine(
        _ line: String,
        appendsNewline: Bool = true
    ) -> String {
        let newline = appendsNewline ? "\n" : ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Fences are presentation boundaries, never literal terminal output.
        // The exact opening marker/run is retained so shorter inner runs and
        // fence-looking payload text remain code rather than being discarded.
        if var activeCodeFence {
            if isClosingCodeFence(line, for: activeCodeFence) {
                self.activeCodeFence = nil
                return flushBlock() + newline
            }
            let diffKind = TerminalCodeBlockRenderer.isDiffLanguage(activeCodeFence.language)
                ? activeCodeFence.diffState.classify(
                    TerminalCodeBlockRenderer.diffSourceLine(line, language: activeCodeFence.language)
                ) : nil
            self.activeCodeFence = activeCodeFence
            return TerminalCodeBlockRenderer.renderCodeLine(
                line,
                language: activeCodeFence.language,
                width: codeBlockWidth,
                palette: palette,
                diffKind: diffKind
            ).joined(separator: "\n") + newline
        }

        if let openingFence = openingCodeFence(in: line) {
            let flushed = flushBlock()
            activeCodeFence = openingFence
            let header = TerminalCodeBlockRenderer.renderHeader(
                language: openingFence.language,
                width: codeBlockWidth,
                palette: palette
            )
            return flushed + header + newline
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
                return shouldFlushBufferedBlock() ? flushBufferedBlockForSafety() : ""
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
                // A blockquote with an open `**` span keeps buffering until it
                // closes, otherwise the bold run would be lost; the hard cap
                // bounds the wait for a stray closer.
                if blockKind == .blockQuote, !bufferedStrongMarkersAreBalanced() {
                    blockLines.append(line)
                    return isPastHardBufferCap() ? flushBlock() : ""
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
                return shouldFlushBufferedBlock() ? flushBufferedBlockForSafety() : ""
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
            return shouldFlushBufferedBlock() ? flushBufferedBlockForSafety() : ""
        }

        return renderCompleteLine(line, appendsNewline: appendsNewline)
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
        var sourceLines = kind == .list ? compactListBlockLines(lines) : lines
        if kind == .list, streamingOrderedStart != nil {
            let renumbered = renumberTopLevelOrderedMarkers(sourceLines, from: nextOrderedNumber)
            sourceLines = renumbered.lines
            nextOrderedNumber = renumbered.next
        }
        let source = sanitizedMarkdownSource(sourceLines.joined(separator: "\n"))
        var renderer = makeRenderer()
        return renderer.visit(Document(parsing: source)) + "\n"
    }

    private func shouldFlushBufferedBlock() -> Bool {
        // Tables need the whole block for layout, so both a confirmed table and
        // its one-line candidate (an arbitrarily long header awaiting a
        // delimiter) use the dedicated cap; a partial table never takes the
        // generic flush, which would yield an incoherent layout.
        if blockKind == .table || blockKind == .tableCandidate {
            return exceedsBufferCap(
                lineCount: Self.maxBufferedTableLineCount,
                characterCount: Self.maxBufferedTableCharacterCount
            )
        }
        return exceedsBufferCap(
            lineCount: Self.maxBufferedBlockLineCount,
            characterCount: Self.maxBufferedBlockCharacterCount
        )
    }

    private func exceedsBufferCap(lineCount: Int, characterCount: Int) -> Bool {
        blockLines.count >= lineCount
            || blockLines.reduce(0) { $0 + $1.count } >= characterCount
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
            return isPastHardBufferCap() ? flushBlock() : ""
        }
        // A blockquote with an open `**` span must defer flush until the span
        // closes (or the hard cap), matching the guard in handleCompleteLine.
        if blockKind == .blockQuote, !bufferedStrongMarkersAreBalanced() {
            return isPastHardBufferCap() ? flushBlock() : ""
        }
        return flushBlock()
    }

    /// Explicit degradation for a table past its buffering cap: the buffered rows
    /// render as one coherent table followed by a dim truncation marker. The
    /// block stays `.table` so further rows are discarded (bounded memory),
    /// while a following non-table line ends it normally and is never lost.
    private mutating func flushTruncatedTable() -> String {
        let lines = blockLines
        blockLines = []
        tableTruncated = true
        return renderBlock(lines: lines, kind: .table)
            + "\(Self.dim)\(Self.tableTruncationMarker)\(Self.reset)\n"
    }

    /// Whether the buffered block has exceeded the much higher hard cap used
    /// only as a last resort to bound buffering on pathological inputs.
    private func isPastHardBufferCap() -> Bool {
        exceedsBufferCap(
            lineCount: Self.hardBufferedBlockLineCount,
            characterCount: Self.hardBufferedBlockCharacterCount
        )
    }

    /// Whether the incoming top-level list marker is a different type (ordered
    /// vs unordered) than the current list block. In markdown such a change
    /// starts a new list block, so the old one should be flushed in full and
    /// numbering state reset.
    private func listMarkerTypeChanged(toOrdered newIsOrdered: Bool) -> Bool {
        newIsOrdered != (streamingOrderedStart != nil)
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

    private mutating func renderCompleteLine(
        _ line: String,
        appendsNewline: Bool
    ) -> String {
        let newline = appendsNewline ? "\n" : ""

        guard mayContainMarkdown(in: line) else {
            return "\(line)\(newline)"
        }

        let parsed = leadingIndent(in: sanitizedMarkdownSource(line))
        var renderer = makeRenderer()
        return "\(parsed.indent)\(renderer.visit(Document(parsing: parsed.body)))\(newline)"
    }

    // MARK: - Incremental prose streaming

    /// Completes a line whose prefix was already streamed as plain text: only the
    /// un-emitted tail is output, rendered inline so late markers are formatted.
    private func completePartiallyEmittedLine(
        _ tail: String,
        appendsNewline: Bool = true
    ) -> String {
        let newline = appendsNewline ? "\n" : ""
        return (tail.isEmpty ? "" : renderInlineFragment(tail)) + newline
    }

}
