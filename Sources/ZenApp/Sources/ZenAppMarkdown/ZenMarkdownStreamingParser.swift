//
//  ZenMarkdownStreamingParser.swift
//  ZenApp
//
//  Incremental parsing of a Markdown document that is still streaming: the
//  blocks of a stable prefix are reused and only the tail is parsed again,
//  so each token costs the size of the tail instead of the whole document.
//

import Foundation
import Markdown
import Synchronization

/// The parsed stable prefix of a streaming document.
///
/// `blocks` always equals a full parse of ``prefix``, and no text appended
/// after the prefix can change them: the prefix ends right before a
/// top-level block that starts a line after a blank line (see
/// ``ZenMarkdownStreamingParser``).
struct ZenMarkdownStreamAnchor: Sendable {
    /// The text the anchor was taken from; only its first `length` bytes
    /// belong to the anchor. Keeping the whole string avoids copying the
    /// prefix every time the anchor moves forward.
    let source: String
    /// The UTF-8 length of the prefix.
    let length: Int
    /// The blocks of the prefix.
    let blocks: [ZenMarkdownBlock]

    /// No prefix: the whole text is the tail.
    static let empty = ZenMarkdownStreamAnchor(source: "", length: 0, blocks: [])

    /// The stable prefix.
    var prefix: String {
        String(decoding: source.utf8.prefix(length), as: UTF8.self)
    }

    /// Whether `text` starts with the prefix, compared byte for byte.
    func isPrefix(of text: String) -> Bool {
        guard length > 0 else {
            return true
        }
        guard text.utf8.count >= length else {
            return false
        }
        var text = text
        var source = source
        let length = length
        return text.withUTF8 { textBytes in
            source.withUTF8 { sourceBytes in
                memcmp(textBytes.baseAddress!, sourceBytes.baseAddress!, length) == 0
            }
        }
    }
}

/// Parses a streaming document from the anchor of an earlier, shorter
/// version of it.
///
/// The text after the anchor (the tail) is parsed on its own and its
/// top-level blocks are appended to the anchor's. This equals a full parse
/// because the anchor ends where CommonMark closes every open block for
/// good: before a top-level block that
/// - starts at the first column of a complete line (the line ends with a
///   newline, so its first characters are final),
/// - follows a blank line (no lazy continuation, setext underline, or table
///   row can join it to the block before),
/// - is not a list marker (`-`, `+`, `*` or `1.`/`1)` followed by a space,
///   which could continue a list above the blank line),
/// - is reported by the parser itself as a top-level block, so it is not
///   inside a fenced code block, an HTML block, a list item or a quote.
///
/// Link reference definitions are the only document-wide construct: when
/// `]:` appears outside code and HTML blocks, the whole document is parsed
/// instead and no anchor is kept. A `\r` (CR or CRLF line endings) does the
/// same, since the line bookkeeping counts `\n` only.
enum ZenMarkdownStreamingParser {
    struct Result {
        /// The blocks of the whole text, equal to `ZenMarkdownParser.blocks(from:)`.
        let blocks: [ZenMarkdownBlock]
        /// The anchor for the next, longer version of the text; `nil` when
        /// the text must be parsed whole.
        let anchor: ZenMarkdownStreamAnchor?
        /// The UTF-8 length of the text parsed this time.
        let parsedLength: Int
    }

    /// Parses `markdown`, reusing `anchor` when it is a prefix of it.
    static func parse(_ markdown: String, reusing anchor: ZenMarkdownStreamAnchor?) -> Result {
        let base = anchor.flatMap { $0.isPrefix(of: markdown) ? $0 : nil } ?? .empty
        let utf8 = markdown.utf8
        let tailStart = utf8.index(utf8.startIndex, offsetBy: base.length)
        let tail = String(markdown[tailStart...])
        let scan = TailScan(tail)

        guard !scan.containsCarriageReturn else {
            return wholeDocument(markdown)
        }
        let document = Document(parsing: tail)
        if !scan.definitionLines.isEmpty,
           !scan.definitionLines.isSubset(of: verbatimLines(of: document)) {
            return wholeDocument(markdown)
        }

        var builder = ZenMarkdownBlockBuilder()
        var tailBlocks: [ZenMarkdownBlock] = []
        var stableBlockCount = 0
        var splitOffset: Int?
        for (index, child) in document.children.enumerated() {
            if index > 0, let offset = scan.safeSplitOffset(before: child) {
                stableBlockCount = tailBlocks.count
                splitOffset = offset
            }
            tailBlocks += builder.visit(child)
        }

        let next = splitOffset.map { offset in
            ZenMarkdownStreamAnchor(
                source: markdown,
                length: base.length + offset,
                blocks: base.blocks + tailBlocks[..<stableBlockCount]
            )
        } ?? base
        return Result(blocks: base.blocks + tailBlocks, anchor: next, parsedLength: scan.bytes.count)
    }

    private static func wholeDocument(_ markdown: String) -> Result {
        Result(
            blocks: ZenMarkdownParser.blocks(from: markdown),
            anchor: nil,
            parsedLength: markdown.utf8.count
        )
    }

    /// The lines (1-based) covered by code and HTML blocks at any depth: a
    /// `]:` there is verbatim text, never a link reference definition.
    ///
    /// A range that ends at the first column of a line (an indented code
    /// block ends at the start of the line after it) stops at the line
    /// before.
    private static func verbatimLines(of document: Document) -> Set<Int> {
        var lines = Set<Int>()
        func visit(_ markup: any Markup) {
            if markup is CodeBlock || markup is HTMLBlock {
                if let range = markup.range {
                    let first = range.lowerBound.line
                    let last = range.upperBound.column == 1 && range.upperBound.line > first
                        ? range.upperBound.line - 1
                        : range.upperBound.line
                    lines.formUnion(first...max(first, last))
                }
                return
            }
            for child in markup.children {
                visit(child)
            }
        }
        visit(document)
        return lines
    }

    /// One pass over the bytes of the tail: line starts, line endings and
    /// the lines that could hold a link reference definition.
    struct TailScan {
        let bytes: [UInt8]
        /// The byte offset where each line starts; line `n` (1-based) starts
        /// at `lineStarts[n - 1]`. A newline at the very end adds an empty
        /// last line.
        private(set) var lineStarts: [Int] = [0]
        private(set) var containsCarriageReturn = false
        /// The lines (1-based) that contain `]:`.
        private(set) var definitionLines = Set<Int>()

        init(_ tail: String) {
            bytes = Array(tail.utf8)
            var previous: UInt8 = 0
            for (offset, byte) in bytes.enumerated() {
                switch byte {
                case UInt8(ascii: "\n"):
                    lineStarts.append(offset + 1)
                case UInt8(ascii: "\r"):
                    containsCarriageReturn = true
                case UInt8(ascii: ":") where previous == UInt8(ascii: "]"):
                    definitionLines.insert(lineStarts.count)
                default:
                    break
                }
                previous = byte
            }
        }

        /// The byte offset of the line where `block` starts, when the text
        /// can be split there for good; `nil` otherwise.
        func safeSplitOffset(before block: any Markup) -> Int? {
            guard let start = block.range?.lowerBound, start.column == 1 else {
                return nil
            }
            let line = start.line
            // A previous line, and a newline that completes this one.
            guard line >= 2, line < lineStarts.count else {
                return nil
            }
            let lineStart = lineStarts[line - 1]
            let lineEnd = lineStarts[line] - 1
            guard lineStart < lineEnd,
                  bytes[lineStart] != UInt8(ascii: " "),
                  bytes[lineStart] != UInt8(ascii: "\t"),
                  !Self.isListMarker(bytes[lineStart..<lineEnd]) else {
                return nil
            }
            let previousLine = bytes[lineStarts[line - 2]..<(lineStart - 1)]
            guard previousLine.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }) else {
                return nil
            }
            return lineStart
        }

        /// Whether `line` starts with a bullet (`-`, `+`, `*`) or an ordered
        /// marker (1–9 digits and `.` or `)`) followed by a space, a tab or
        /// the end of the line.
        static func isListMarker(_ line: ArraySlice<UInt8>) -> Bool {
            func endsMarker(at index: Int) -> Bool {
                index == line.endIndex || line[index] == UInt8(ascii: " ") || line[index] == UInt8(ascii: "\t")
            }
            guard let first = line.first else {
                return false
            }
            if first == UInt8(ascii: "-") || first == UInt8(ascii: "+") || first == UInt8(ascii: "*") {
                return endsMarker(at: line.startIndex + 1)
            }
            var index = line.startIndex
            while index < line.endIndex, index - line.startIndex < 9,
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(line[index]) {
                index += 1
            }
            guard index > line.startIndex, index < line.endIndex,
                  line[index] == UInt8(ascii: ".") || line[index] == UInt8(ascii: ")") else {
                return false
            }
            return endsMarker(at: index + 1)
        }
    }
}

/// The anchors of the documents streaming now, so each new version of a
/// stream starts from the anchor of the previous one. Bounded; the least
/// recently used anchor is dropped first.
final class ZenMarkdownStreamAnchors: Sendable {
    private let capacity: Int
    private let anchors = Mutex<[ZenMarkdownStreamAnchor]>([])

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// The longest anchor that is a prefix of `markdown`.
    func bestAnchor(for markdown: String) -> ZenMarkdownStreamAnchor? {
        let length = markdown.utf8.count
        return anchors.withLock { anchors in
            anchors
                .filter { $0.length <= length }
                .sorted { $0.length > $1.length }
                .first { $0.isPrefix(of: markdown) }
        }
    }

    /// Records `anchor`, dropping the anchors it grew from (those that are a
    /// prefix of it), then the least recently recorded beyond the capacity.
    func record(_ anchor: ZenMarkdownStreamAnchor) {
        guard anchor.length > 0 else {
            return
        }
        anchors.withLock { anchors in
            anchors.removeAll { $0.length <= anchor.length && $0.isPrefix(of: anchor.source) }
            anchors.append(anchor)
            if anchors.count > capacity {
                anchors.removeFirst(anchors.count - capacity)
            }
        }
    }

    /// The number of anchors kept.
    var count: Int {
        anchors.withLock { $0.count }
    }

    /// Removes the anchors of the stream that produced `markdown`, once it
    /// is complete.
    func removeAnchors(within markdown: String) {
        let length = markdown.utf8.count
        anchors.withLock { anchors in
            anchors.removeAll { $0.length <= length && $0.isPrefix(of: markdown) }
        }
    }

    /// Removes every anchor.
    func removeAll() {
        anchors.withLock { $0.removeAll() }
    }
}
