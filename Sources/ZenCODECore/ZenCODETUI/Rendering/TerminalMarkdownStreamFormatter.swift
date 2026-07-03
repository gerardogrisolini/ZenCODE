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
    private static let maxBufferedBlockLineCount = 80
    private static let maxBufferedBlockCharacterCount = 12_000
    
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
            rendered += handleCompleteLine(line)
            pendingLine.removeSubrange(pendingLine.startIndex...newlineIndex)
        }
        
        if pendingLine.count > Self.maxBufferedLineLength {
            if shouldFlushPendingLineForStreaming(pendingLine) {
                rendered += flushBlock()
                rendered += pendingLine
                pendingLine = ""
            } else if pendingLine.count > Self.maxMarkdownBufferedLineLength {
                rendered += flushBlock()
                rendered += renderCompleteLine(pendingLine, appendsNewline: false)
                pendingLine = ""
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
        }
        var rendered = ""
        if !pendingLine.isEmpty {
            rendered += handleCompleteLine(pendingLine, appendsNewline: false)
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
            if lineContinuesBlock(line, trimmed: trimmed) {
                blockLines.append(line)
                if shouldFlushBufferedBlock() {
                    return flushBlock()
                }
                return ""
            }
            let flushed = flushBlock()
            return flushed + handleCompleteLine(line, appendsNewline: appendsNewline)
        }
        
        if let kind = blockKind(forStartLine: trimmed) {
            blockKind = kind
            blockLines = [line]
            if shouldFlushBufferedBlock() {
                return flushBlock()
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
            return line.first == " " || line.first == "\t"
        case .blockQuote:
            return trimmed.hasPrefix(">")
        case .table:
            return isPotentialTableRow(trimmed)
        }
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
        guard blockKind != nil, !blockLines.isEmpty else {
            blockKind = nil
            blockLines = []
            return ""
        }
        let sourceLines = blockKind == .list
            ? compactListBlockLines(blockLines)
            : blockLines
        let source = sanitizedMarkdownSource(sourceLines.joined(separator: "\n"))
        blockKind = nil
        blockLines = []
        
        var renderer = makeRenderer()
        let document = Document(parsing: source)
        let rendered = renderer.visit(document)
        return wrapIfNeeded(rendered) + "\n"
    }

    private func shouldFlushBufferedBlock() -> Bool {
        guard blockKind != .tableCandidate else {
            return false
        }
        if blockLines.count >= Self.maxBufferedBlockLineCount {
            return true
        }
        return blockLines.reduce(0) { $0 + $1.count } >= Self.maxBufferedBlockCharacterCount
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
    
    private func makeRenderer() -> TerminalSwiftMarkdownRenderer {
        TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: supportsHyperlinks,
            renderWidth: renderWidth
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
        var sawDigit = false
        while index < line.endIndex, line[index].isNumber {
            sawDigit = true
            index = line.index(after: index)
        }
        guard sawDigit,
              index < line.endIndex,
              line[index] == "." else {
            return false
        }
        let afterDot = line.index(after: index)
        return afterDot < line.endIndex && line[afterDot].isWhitespace
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
