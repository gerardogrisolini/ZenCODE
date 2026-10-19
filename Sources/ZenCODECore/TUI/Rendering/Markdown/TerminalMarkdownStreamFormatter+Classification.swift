//
//  TerminalMarkdownStreamFormatter+Classification.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/05/26.
//

import Foundation
import Markdown

extension TerminalMarkdownStreamFormatter {
    func lineContinuesBlock(_ line: String, trimmed: String) -> Bool {
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
    func shouldStreamIncrementally(
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
        line.first != " " && line.first != "\t" && isListMarker(trimmed)
    }

    func blockKind(forStartLine trimmed: String) -> BlockKind? {
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
        ["-", "*", "+"].contains { trimmed == $0 || trimmed.hasPrefix("\($0) ") }
            || isOrderedListMarker(in: trimmed)
    }

    private func isPotentialTableHeader(_ trimmed: String) -> Bool {
        !isTableDelimiterRow(trimmed) && isPotentialTableRow(trimmed)
    }

    private func isPotentialTableRow(_ trimmed: String) -> Bool {
        // A table candidate is confirmed only if the following line is a markdown
        // delimiter row. This one-line candidate state avoids buffering ordinary
        // prose or shell pipelines that happen to contain pipe characters.
        pipeCountOutsideInlineCode(in: trimmed) > 0
    }

    func isTableDelimiterRow(_ trimmed: String) -> Bool {
        let cells = tableCells(in: trimmed)
        return cells.count >= 2 && cells.allSatisfy(isTableDelimiterCell)
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
        line[start...].prefix { $0 == "`" }.count
    }

    /// Index of the last top-level (column-0) list marker in `lines`, or nil
    /// when there is none. Used to split completed items from the still-open one.
    func lastTopLevelItemStartIndex(in lines: [String]) -> Int? {
        var lastIndex: Int?
        for (index, line) in lines.enumerated() {
            guard line.first != " ", line.first != "\t" else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, isListMarker(trimmed) else { continue }
            lastIndex = index
        }
        return lastIndex
    }

    /// Rewrites the leading number of every top-level ordered-list marker so a
    /// list streamed item-by-item keeps ascending numbers. Unordered markers and
    /// indented continuation lines are left untouched. Renumbering stops once the
    /// ascending number would reach 10 digits (1_000_000_000): beyond that Swift
    /// Markdown treats the marker as plain text, so leaving it verbatim keeps the
    /// rendered output coherent with the document parser.
    func renumberTopLevelOrderedMarkers(
        _ lines: [String],
        from start: Int
    ) -> (lines: [String], next: Int) {
        var current = start
        var result: [String] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            if line.first != " ", line.first != "\t",
               current <= OrderedListMarkerPolicy.maximumValue,
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
        guard let marker = orderedListMarkerScan(in: line) else { return nil }
        return "\(number)." + line[marker.afterDot...]
    }

    /// The leading integer of an ordered-list marker (e.g. "1." -> 1), or nil
    /// when the trimmed line is not an ordered marker. Values beyond a safe
    /// threshold are treated as non-markers: no real list has millions of items,
    /// and incrementing such a number during renumbering would overflow Int.
    func leadingOrderedNumber(in trimmed: String) -> Int? {
        guard let marker = orderedListMarkerScan(in: trimmed) else { return nil }
        // Clamp to a safe range: Swift Markdown accepts up to 9 digits, so valid
        // markers up to 999_999_999 are supported. Beyond that the number can't
        // be a real list index, and incrementing it during renumbering would risk
        // overflow. Treat out-of-range values as plain markers (verbatim render).
        guard marker.digitCount <= OrderedListMarkerPolicy.maximumDigitCount,
              let value = Int(marker.digits),
              value <= OrderedListMarkerPolicy.maximumValue else {
            return nil
        }
        return value
    }

    /// True when the `**` strong markers accumulated in the current block buffer
    /// are all paired. When unbalanced, an inline span is still open across
    /// lines and the block must keep buffering instead of streaming line-by-line.
    func bufferedStrongMarkersAreBalanced() -> Bool {
        hasBalancedStrongMarkers(in: blockLines.joined(separator: "\n"))
    }

    /// Whether every `**` marker in `source` (outside inline code) is paired
    /// with an opener/closer, using the same pairing rules as the sanitizer.
    private func hasBalancedStrongMarkers(in source: String) -> Bool {
        let markers = strongMarkersOutsideInlineCode(in: source)
        guard !markers.isEmpty else {
            return true
        }
        return pairedStrongMarkerIndexes(markers).count == markers.count
    }

    func compactListBlockLines(_ lines: [String]) -> [String] {
        lines.filter { line in
            !line.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Renders the tail of a partially-streamed line as inline markdown.
    ///
    /// - Note: Once a line has started streaming it can no longer become a block
    ///   construct (e.g. a table header): its already-written prefix cannot be
    ///   retracted, so a later `|` renders as literal inline text.
    func renderInlineFragment(_ fragment: String) -> String {
        // `fragment` follows text already written directly to the terminal. A
        // leading mark, joiner, regional indicator, or emoji modifier can
        // therefore complete the final grapheme in that emitted text. Do not
        // put that cluster after `inlineParsingSentinel`: the Markdown parser
        // is allowed to coalesce or discard otherwise-invisible Unicode at a
        // synthetic boundary (and its behaviour has differed between the
        // Darwin and Linux implementations). Emit the continuation unchanged,
        // then parse only the markdown-capable remainder.
        let continuation = leadingGraphemeContinuation(in: fragment)
        if !continuation.prefix.isEmpty {
            return continuation.prefix + renderInlineFragment(continuation.remainder)
        }
        guard mayContainMarkdown(in: fragment) else {
            return fragment
        }
        // A partial tail starts in the middle of an already-emitted logical
        // line. Prefixing a zero-width, non-whitespace sentinel keeps leading
        // `-`, `#`, `>` and similar characters as inline prose rather than
        // allowing the document parser to create a fresh block. Remove only the
        // synthetic first occurrence after rendering; user content remains
        // untouched.
        let source = Self.inlineParsingSentinel + sanitizedMarkdownSource(fragment)
        var renderer = makeRenderer()
        let rendered = renderer.visit(Document(parsing: source))
        guard let sentinelRange = rendered.range(of: Self.inlineParsingSentinel) else {
            return rendered
        }
        return rendered.replacingCharacters(in: sentinelRange, with: "")
    }

    /// Separates the first independently-segmented `Character` when its first
    /// scalar can continue the grapheme cluster emitted in the preceding
    /// stream delta. `String` cannot expose a grapheme that spans two distinct
    /// values, so preserve this small raw prefix before Markdown sees it.
    private func leadingGraphemeContinuation(
        in fragment: String
    ) -> (prefix: String, remainder: String) {
        guard let firstScalar = fragment.unicodeScalars.first,
              Self.isGraphemeContinuationStarter(firstScalar) else {
            return ("", fragment)
        }
        let end = fragment.index(after: fragment.startIndex)
        return (
            String(fragment[..<end]),
            String(fragment[end...])
        )
    }

    /// Unicode scalars which may extend a grapheme begun in a previous delta.
    /// General-category marks cover combining accents and script-specific
    /// marks; the explicit ranges cover joiner-based emoji, flags, modifiers,
    /// variation selectors, tag sequences, and Hangul medial/final jamo.
    private static func isGraphemeContinuationStarter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            break
        }

        let value = scalar.value
        return value == 0x200C // ZERO WIDTH NON-JOINER
            || value == 0x200D // ZERO WIDTH JOINER
            || (0x1100...0x11FF).contains(value) // Hangul jamo
            || (0x1F1E6...0x1F1FF).contains(value) // Regional indicators
            || (0x1F3FB...0x1F3FF).contains(value) // Emoji modifiers
            || (0xFE00...0xFE0F).contains(value) // Variation selectors
            || (0xE0020...0xE007F).contains(value) // Emoji tag sequence
            || (0xE0100...0xE01EF).contains(value) // Variation Selectors Supplement
    }

    /// End of the newly safe pending-line prefix: nothing while a line-start block
    /// marker is unresolved (cached in `pendingLineStartState`), otherwise up to
    /// the first `streamingStopChars` character.
    func safeStreamingEmitEnd(in line: String) -> String.Index {
        guard case .resolved = pendingLineStartState else {
            return line.startIndex
        }
        return line.firstIndex { Self.streamingStopChars.contains($0) } ?? line.endIndex
    }

    /// Feeds only newly appended characters into the block-marker classifier.
    /// It mirrors the prior full-line block-marker decisions without repeatedly
    /// trimming/scanning the complete pending line while a marker candidate is
    /// split across many small deltas.
    mutating func updatePendingLineStartState(with segment: Substring) {
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
                pendingLineStartState = character.isNumber ? .digitRun(1) : .resolved
            }
        case .hashRun(let count):
            pendingLineStartState = character == "#"
                ? (count >= 6 ? .resolved : .hashRun(count + 1))
                : stateAfterMarker(character)
        case .dashRun(let count):
            if character == "-" {
                pendingLineStartState = .dashRun(min(3, count + 1))
            } else if count >= 3 {
                pendingLineStartState = character.isWhitespace ? .ambiguousBlockMarker : .resolved
            } else {
                pendingLineStartState = stateAfterMarker(character)
            }
        case .plus, .orderedListDot:
            pendingLineStartState = stateAfterMarker(character)
        case .digitRun(let count):
            if character.isNumber {
                pendingLineStartState = count >= 9 ? .resolved : .digitRun(count + 1)
            } else if character == "." {
                pendingLineStartState = .orderedListDot
            } else {
                // Trimming removes a trailing whitespace run, so wait until a
                // later non-whitespace character proves this is not all digits.
                pendingLineStartState = isBlockMarkerWhitespace(character) ? .deferredWhitespace : .resolved
            }
        case .deferredWhitespace:
            if !isBlockMarkerWhitespace(character) {
                pendingLineStartState = .resolved
            }
        case .ambiguousBlockMarker, .resolved:
            return
        }
    }

    private func stateAfterMarker(_ character: Character) -> PendingLineStartState {
        if character == " " || character == "\t" {
            return .ambiguousBlockMarker
        }
        return isBlockMarkerWhitespace(character) ? .deferredWhitespace : .resolved
    }

    private func isBlockMarkerWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            Self.blockMarkerWhitespace.contains($0)
        }
    }

    func makeRenderer() -> TerminalSwiftMarkdownRenderer {
        // Structured surfaces (tables, thematic rules, code blocks) still need a
        // terminal width to preserve borders and padding; free conversational
        // prose is never reflowed here and relies on the terminal's own wrap.
        // Leave one column for the chat inset plus any presentation-only prefix
        // applied by the caller after Markdown has been laid out.
        TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: supportsHyperlinks,
            renderWidth: codeBlockWidth,
            palette: palette
        )
    }

    /// Code is emitted directly by the stream (rather than via `makeRenderer`)
    /// and therefore reserves the same chat inset and presentation prefix as a
    /// complete Markdown renderer created above.
    var codeBlockWidth: Int {
        renderWidth > 0 ? max(1, renderWidth - 1 - presentationPrefixWidth) : 0
    }

    func shouldFlushPendingLineForStreaming(_ line: String) -> Bool {
        activeCodeFence == nil && blockKind == nil && !mayContainMarkdown(in: line)
    }

    func mayContainMarkdown(in line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return false
        }

        if ["#", ">", "```", "<!--", "---", "***", "___", "- ", "* ", "+ "].contains(where: trimmed.hasPrefix)
            || isOrderedListMarker(in: trimmed) {
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
        // Swift Markdown accepts up to 9-digit ordered markers; 10+ digits are
        // plain text. Keep this consistent with leadingOrderedNumber so the
        // streaming classification matches the parser's list detection.
        guard let marker = orderedListMarkerScan(in: line) else { return false }
        return marker.digitCount <= OrderedListMarkerPolicy.maximumDigitCount
            && marker.hasWhitespaceBody
    }

    /// True when the line looks like an ordered-list marker (digits + "." +
    /// whitespace) but the leading number has 10+ digits, which Swift Markdown
    /// rejects as plain text rather than a list marker. Within an active list
    /// block such a line is buffered as a continuation line so the parser can
    /// decide whether it is a lazy continuation of the current item.
    private func isOutOfRangeOrderedLikeMarker(_ trimmed: String) -> Bool {
        guard let marker = orderedListMarkerScan(in: trimmed) else { return false }
        return marker.digitCount > OrderedListMarkerPolicy.maximumDigitCount
    }

    private func orderedListMarkerScan(in line: String) -> OrderedListMarkerScan? {
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
        return OrderedListMarkerScan(
            digits: line[..<index],
            afterDot: afterDot,
            hasWhitespaceBody: afterDot < line.endIndex
        )
    }

    func leadingIndent(in line: String) -> (indent: String, body: String) {
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

    private func pairedStrongMarkerIndexes(_ markers: [StrongMarker]) -> Set<Int> {
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
        return kept
    }

    func sanitizedMarkdownSource(_ source: String) -> String {
        guard removesUnbalancedStrongMarkers,
              source.contains("**") else {
            return source
        }

        let markers = strongMarkersOutsideInlineCode(in: source)
        guard !markers.isEmpty else {
            return source
        }

        let keptMarkerIndexes = pairedStrongMarkerIndexes(markers)
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
        return afterMarker < source.endIndex && !source[afterMarker].isWhitespace
    }

    private func strongMarkerCanClose(in source: String, at index: String.Index) -> Bool {
        index > source.startIndex && !source[source.index(before: index)].isWhitespace
    }

    func openingCodeFence(in line: String) -> CodeFence? {
        guard let run = codeFenceRun(in: line) else { return nil }
        let info = run.remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        // Backticks are forbidden in the info string of a backtick fence. A
        // tilde fence has no equivalent restriction.
        guard run.marker != "`" || !info.contains("`") else {
            return nil
        }
        return CodeFence(
            marker: run.marker,
            length: run.length,
            language: codeFenceLanguage(fromInfo: info)
        )
    }

    func isClosingCodeFence(_ line: String, for fence: CodeFence) -> Bool {
        guard let run = codeFenceRun(in: line),
              run.marker == fence.marker,
              run.length >= fence.length else {
            return false
        }
        return run.remainder.allSatisfy(\.isWhitespace)
    }

    /// Parses an opening/closing marker indented by at most three spaces. Tabs
    /// are not treated as partial indentation here: accepting one would require
    /// full CommonMark tab-stop expansion and could misclassify ordinary code.
    private func codeFenceRun(in line: String) -> CodeFenceRun? {
        var index = line.startIndex
        var indentation = 0
        while index < line.endIndex, line[index] == " " {
            indentation += 1
            guard indentation <= 3 else {
                return nil
            }
            index = line.index(after: index)
        }
        guard index < line.endIndex,
              line[index] == "`" || line[index] == "~" else {
            return nil
        }

        let marker = line[index]
        var length = 0
        while index < line.endIndex, line[index] == marker {
            length += 1
            index = line.index(after: index)
        }
        guard length >= 3 else {
            return nil
        }
        return CodeFenceRun(
            marker: marker,
            length: length,
            remainder: String(line[index...])
        )
    }

    private func codeFenceLanguage(fromInfo info: String) -> String? {
        info.split(whereSeparator: \.isWhitespace).first.map { String($0).lowercased() }
    }

    // MARK: - Terminal capabilities

    static func detectTerminalWidth() -> Int {
        TerminalWidth.current(descriptors: [1, 2, 0], fallback: 0)
    }

    static func detectHyperlinkSupport() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["TERM"] == "dumb" {
            return false
        }
        // Terminals with well-known OSC 8 hyperlink support.
        if let program = environment["TERM_PROGRAM"]?.lowercased() {
            if ["iterm", "wezterm", "vscode", "ghostty", "hyper"].contains(where: program.contains) {
                return true
            }
            if program.contains("apple_terminal") {
                return false
            }
        }
        return ["WT_SESSION", "KITTY_WINDOW_ID", "VTE_VERSION"].contains { environment[$0] != nil }
    }
}
