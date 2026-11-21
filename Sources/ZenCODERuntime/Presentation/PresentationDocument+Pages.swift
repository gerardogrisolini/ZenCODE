//
//  PresentationDocument+Pages.swift
//  ZenCODE
//
//  The split of a presentation document into ordered pages, each within the
//  budget of one message of a transport, and the cut of a plain text into
//  pieces within a length.
//

import Foundation

/// The room of one page of a document and the number of pages a document may
/// take. A transport adapter owns the values; the presentation layer only
/// applies them (``PresentationDocument/pages(within:)``).
struct PresentationPageBudget: Sendable, Equatable {
    /// UTF-8 bytes of text a page may hold: every text run, code block, and
    /// link URL, and every table row as its plain-text line (its cells joined
    /// by ` | `, with their link URLs) followed by a line break.
    var maximumTextBytes: Int
    /// Blocks a page may hold, counting every nested block, every list item,
    /// and every table row, the header row included.
    var maximumBlocks: Int
    /// Pages a document may take: beyond them the document is cut, and the
    /// last page ends with a paragraph of ``truncationNotice``.
    var maximumPages: Int
    /// The text of the paragraph that ends a document cut at
    /// ``maximumPages``.
    var truncationNotice: String

    /// The same room per page, with no limit on the number of pages.
    var withoutPageLimit: PresentationPageBudget {
        var budget = self
        budget.maximumPages = .max
        return budget
    }
}

/// What a block, a piece of it, or a page takes of a
/// ``PresentationPageBudget``.
struct PresentationPageCost: Sendable, Equatable {
    var bytes: Int
    var blocks: Int

    static let zero = PresentationPageCost(bytes: 0, blocks: 0)
    /// The block that holds others: a list, a quotation, a table.
    static let container = PresentationPageCost(bytes: 0, blocks: 1)

    static func + (lhs: Self, rhs: Self) -> Self {
        PresentationPageCost(bytes: lhs.bytes + rhs.bytes, blocks: lhs.blocks + rhs.blocks)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        PresentationPageCost(bytes: lhs.bytes - rhs.bytes, blocks: lhs.blocks - rhs.blocks)
    }

    func fits(in room: PresentationPageCost) -> Bool {
        bytes <= room.bytes && blocks <= room.blocks
    }
}

extension PresentationDocument {
    init(blocks: [PresentationBlock]) {
        self.blocks = blocks
    }

    /// What the whole document takes of a page.
    var pageCost: PresentationPageCost {
        blocks.reduce(PresentationPageCost.zero) { $0 + $1.pageCost }
    }

    /// The document as ordered pages, each within `budget`.
    ///
    /// A document that fits one page is its only page, unchanged. Otherwise
    /// its top-level blocks are packed in order, never reordered: a block
    /// that does not fit what is left of a page starts the next one, and a
    /// block larger than a whole page is split into pieces of its own kind,
    /// the first filling what is left of the page
    /// (``PresentationPageSplitter``). No text is lost and its order is kept;
    /// a page of blank text is left out. Beyond `budget.maximumPages` the
    /// document is cut: the last page ends with a paragraph of
    /// `budget.truncationNotice`, which takes the place of its last blocks
    /// when it would not fit after them.
    func pages(within budget: PresentationPageBudget) -> [PresentationDocument] {
        let room = PresentationPageCost(bytes: budget.maximumTextBytes, blocks: budget.maximumBlocks)
        guard !pageCost.fits(in: room) else { return [self] }
        var paginator = PresentationPaginator(room: room, maximumPages: max(budget.maximumPages, 1))
        return paginator.paginate(blocks, truncationNotice: budget.truncationNotice)
            .map(PresentationDocument.init(blocks:))
    }
}

extension PresentationBlock {
    /// What the block takes of a page (``PresentationPageBudget``).
    var pageCost: PresentationPageCost {
        switch self {
        case let .paragraph(text), let .heading(_, text):
            PresentationPageCost(bytes: text.pageBytes, blocks: 1)
        case let .preformatted(code, _):
            PresentationPageCost(bytes: code.utf8.count, blocks: 1)
        case let .list(list):
            list.items.reduce(PresentationPageCost.container) { $0 + $1.pageCost }
        case let .quote(blocks):
            blocks.reduce(PresentationPageCost.container) { $0 + $1.pageCost }
        case let .table(table):
            table.rows.reduce(PresentationPageCost.container + table.headerPageCost) {
                $0 + PresentationTable.pageCost(ofRow: $1)
            }
        case .divider:
            PresentationPageCost(bytes: 0, blocks: 1)
        }
    }

    /// A paragraph of plain `text`.
    static func plainParagraph(_ text: String) -> PresentationBlock {
        .paragraph(PresentationText(runs: [.plain(text)]))
    }
}

extension PresentationListItem {
    /// The item and its blocks.
    var pageCost: PresentationPageCost {
        blocks.reduce(PresentationPageCost(bytes: 0, blocks: 1)) { $0 + $1.pageCost }
    }
}

extension PresentationList {
    /// The items in `range`, numbered as they are in the whole list.
    func items(in range: Range<Int>) -> PresentationList {
        let pieceKind: Kind = switch kind {
        case .unordered: .unordered
        case let .ordered(start): .ordered(start: start + range.lowerBound)
        }
        return PresentationList(kind: pieceKind, items: Array(items[range]))
    }
}

extension PresentationTable {
    /// The header row; nothing for a table without one.
    var headerPageCost: PresentationPageCost {
        header.isEmpty ? .zero : Self.pageCost(ofRow: header)
    }

    /// One row: its plain-text line (``plainText(ofRow:)``) with the URLs of
    /// its links, and a line break.
    static func pageCost(ofRow row: [PresentationText]) -> PresentationPageCost {
        let separators = max(row.count - 1, 0) * 3
        let bytes = row.reduce(separators + 1) { $0 + $1.pageBytes }
        return PresentationPageCost(bytes: bytes, blocks: 1)
    }

    /// The table with the body rows in `range`, its header and alignments
    /// kept.
    func rows(in range: Range<Int>) -> PresentationTable {
        PresentationTable(alignments: alignments, header: header, rows: Array(rows[range]))
    }
}

extension PresentationText {
    /// UTF-8 bytes of its text and of its link URLs.
    var pageBytes: Int {
        runs.reduce(0) { $0 + $1.pageBytes }
    }
}

extension PresentationTextRun {
    /// UTF-8 bytes of its text and, for a link, of its URL.
    var pageBytes: Int {
        switch self {
        case let .plain(text), let .code(text): text.utf8.count
        case let .emphasis(text), let .strong(text), let .strikethrough(text): text.pageBytes
        case let .link(label, url): label.pageBytes + url.absoluteString.utf8.count
        }
    }
}

// MARK: - Packing

/// Packs blocks into pages in order (``PresentationDocument/pages(within:)``).
private struct PresentationPaginator {
    let room: PresentationPageCost
    let maximumPages: Int
    private var pages: [[PresentationBlock]] = []
    private var page: [PresentationBlock] = []
    private var used = PresentationPageCost.zero

    init(room: PresentationPageCost, maximumPages: Int) {
        self.room = room
        self.maximumPages = maximumPages
    }

    mutating func paginate(_ blocks: [PresentationBlock], truncationNotice: String) -> [[PresentationBlock]] {
        // Blocks still to place, the next one last.
        var pending = Array(blocks.reversed())
        var isCut = false
        while let block = pending.popLast() {
            if pages.count == maximumPages {
                isCut = !PresentationPaginator.isBlank(pending + [block])
                break
            }
            let cost = block.pageCost
            if cost.fits(in: room - used) {
                append(block, cost: cost)
                continue
            }
            if !page.isEmpty, cost.fits(in: room) {
                closePage()
                pending.append(block)
                continue
            }
            switch PresentationPageSplitter.split(block, room: room - used, pageRoom: room, isPageEmpty: page.isEmpty) {
            case .nextPage:
                if page.isEmpty {
                    // Never reached: an empty page always takes a piece.
                    append(block, cost: cost)
                } else {
                    closePage()
                    pending.append(block)
                }
            case let .pieces(head, tail):
                for piece in head {
                    append(piece, cost: piece.pageCost)
                }
                // The head is the most of the block the page takes: the rest
                // starts the next page, never a second piece on this one.
                if !tail.isEmpty { closePage() }
                pending.append(contentsOf: tail.reversed())
            case let .replaced(blocks):
                pending.append(contentsOf: blocks.reversed())
            }
        }
        closePage()
        if isCut {
            endLastPage(with: .plainParagraph(truncationNotice))
        }
        return pages
    }

    private mutating func append(_ block: PresentationBlock, cost: PresentationPageCost) {
        page.append(block)
        used = used + cost
    }

    /// Ends the page being filled; one of blank text is left out.
    private mutating func closePage() {
        if !Self.isBlank(page) {
            pages.append(page)
        }
        page = []
        used = .zero
    }

    /// Ends the last page with `notice`, which replaces its last blocks
    /// until it fits.
    private mutating func endLastPage(with notice: PresentationBlock) {
        guard var last = pages.popLast() else {
            pages = [[notice]]
            return
        }
        var cost = last.reduce(PresentationPageCost.zero) { $0 + $1.pageCost }
        while let block = last.last, !(cost + notice.pageCost).fits(in: room) {
            last.removeLast()
            cost = cost - block.pageCost
        }
        last.append(notice)
        pages.append(last)
    }

    private static func isBlank(_ blocks: [PresentationBlock]) -> Bool {
        PresentationBlock.plainText(of: blocks).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Splitting

/// How a block that does not fit what is left of a page goes on.
private enum PresentationPageSplit {
    /// Nothing of it fits what is left of the page, and its first part fits
    /// a whole one: it starts the next page.
    case nextPage
    /// `head` fits what is left of the page; `tail` is placed after it.
    case pieces(head: [PresentationBlock], tail: [PresentationBlock])
    /// Placed instead of the block, from what is left of the page: a part
    /// of it too large for any page, degraded to its plain text.
    case replaced([PresentationBlock])
}

/// Splits a block into pieces of its own kind. A part of a block is cut only
/// when it does not fit a whole page, and then its first piece fills what is
/// left of the page: a code block by lines, and a line by graphemes; a list by
/// items, an ordered one numbering on from where it stopped; a table by rows,
/// each piece with the header and the alignments; a quotation by its blocks,
/// recursively; a paragraph or a heading by its runs, a plain or code run by
/// whitespace and then by graphemes, a styled run as its plain text. A piece
/// of a heading after the first is a paragraph. An item or a row that alone
/// exceeds a page is its plain text, as paragraphs.
private enum PresentationPageSplitter {
    /// `room` is what is left of the page, `pageRoom` a whole page;
    /// `isPageEmpty` says the page holds nothing yet, so a piece of the block
    /// must be taken.
    static func split(
        _ block: PresentationBlock, room: PresentationPageCost, pageRoom: PresentationPageCost, isPageEmpty: Bool
    ) -> PresentationPageSplit {
        switch block {
        case let .paragraph(text):
            guard let (head, tail) = split(text, room: room, pageRoom: pageRoom, isPageEmpty: isPageEmpty) else {
                return .nextPage
            }
            return .pieces(head: [.paragraph(head)], tail: tail.runs.isEmpty ? [] : [.paragraph(tail)])
        case let .heading(level, text):
            guard let (head, tail) = split(text, room: room, pageRoom: pageRoom, isPageEmpty: isPageEmpty) else {
                return .nextPage
            }
            return .pieces(head: [.heading(level: level, text: head)], tail: tail.runs.isEmpty ? [] : [.paragraph(tail)])
        case let .preformatted(code, language):
            return splitCode(code, language: language, room: room, pageRoom: pageRoom, isPageEmpty: isPageEmpty)
        case let .list(list):
            return splitList(list, room: room, pageRoom: pageRoom, isPageEmpty: isPageEmpty)
        case let .table(table):
            return splitTable(table, room: room, pageRoom: pageRoom, isPageEmpty: isPageEmpty)
        case let .quote(blocks):
            return splitQuote(blocks, room: room, pageRoom: pageRoom, isPageEmpty: isPageEmpty)
        case .divider:
            return .nextPage
        }
    }

    /// The runs of `text` that fit `room`, and the rest; `nil` when none
    /// fits and the first one fits a whole page.
    private static func split(
        _ text: PresentationText, room: PresentationPageCost, pageRoom: PresentationPageCost, isPageEmpty: Bool
    ) -> (PresentationText, PresentationText)? {
        guard room.blocks >= 1, let first = text.runs.first else { return nil }
        var bytes = 0
        var count = 0
        for run in text.runs {
            let runBytes = run.pageBytes
            guard bytes + runBytes <= room.bytes else { break }
            bytes += runBytes
            count += 1
        }
        if count > 0 {
            return (PresentationText(runs: Array(text.runs[..<count])), PresentationText(runs: Array(text.runs[count...])))
        }
        guard isPageEmpty || first.pageBytes > pageRoom.bytes else { return nil }
        // The first run alone exceeds a page: a plain or code run is cut by
        // whitespace, a styled one as its plain text.
        let (source, isCode): (String, Bool) = switch first {
        case let .plain(value): (value, false)
        case let .code(value): (value, true)
        default: (first.plainText, false)
        }
        guard let (head, tail) = PresentationTextSplitter.splitAtWhitespace(
            source, limit: room.bytes, pageLimit: pageRoom.bytes, mustTake: isPageEmpty
        ) else { return nil }
        let piece: (String) -> PresentationTextRun = { isCode ? .code($0) : .plain($0) }
        let rest = (tail.isEmpty ? [] : [piece(tail)]) + text.runs.dropFirst()
        return (PresentationText(runs: [piece(head)]), PresentationText(runs: rest))
    }

    private static func splitCode(
        _ code: String, language: String?, room: PresentationPageCost, pageRoom: PresentationPageCost,
        isPageEmpty: Bool
    ) -> PresentationPageSplit {
        guard room.blocks >= 1 else { return .nextPage }
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        var bytes = 0
        var count = 0
        for line in lines {
            let lineBytes = line.utf8.count + (count > 0 ? 1 : 0)
            guard bytes + lineBytes <= room.bytes else { break }
            bytes += lineBytes
            count += 1
        }
        if count > 0 {
            let head = lines[..<count].joined(separator: "\n")
            let tail = count < lines.count ? [PresentationBlock.preformatted(
                code: lines[count...].joined(separator: "\n"), language: language
            )] : []
            return .pieces(head: [.preformatted(code: head, language: language)], tail: tail)
        }
        // The first line alone does not fit what is left of the page.
        let first = lines[0]
        guard isPageEmpty || first.utf8.count > pageRoom.bytes,
              let end = PresentationTextSplitter.Scan(first, limit: room.bytes, measure: .utf8Bytes)
                  .graphemeEnd(mustTake: isPageEmpty) else {
            return .nextPage
        }
        let rest = String(first[end...]) + (lines.count > 1 ? "\n" + lines[1...].joined(separator: "\n") : "")
        return .pieces(
            head: [.preformatted(code: String(first[..<end]), language: language)],
            tail: rest.isEmpty ? [] : [.preformatted(code: rest, language: language)]
        )
    }

    private static func splitList(
        _ list: PresentationList, room: PresentationPageCost, pageRoom: PresentationPageCost, isPageEmpty: Bool
    ) -> PresentationPageSplit {
        guard let first = list.items.first else { return .nextPage }
        var used = PresentationPageCost.container
        var count = 0
        for item in list.items {
            let next = used + item.pageCost
            guard next.fits(in: room) else { break }
            used = next
            count += 1
        }
        let total = list.items.count
        if count > 0 {
            return .pieces(
                head: [.list(list.items(in: 0 ..< count))],
                tail: count < total ? [.list(list.items(in: count ..< total))] : []
            )
        }
        guard isPageEmpty || !(PresentationPageCost.container + first.pageCost).fits(in: pageRoom) else {
            return .nextPage
        }
        // The first item alone exceeds a page: its plain text, as paragraphs.
        let rest: [PresentationBlock] = total > 1 ? [.list(list.items(in: 1 ..< total))] : []
        return .replaced([.plainParagraph(list.plainText(ofItemAt: 0))] + rest)
    }

    private static func splitTable(
        _ table: PresentationTable, room: PresentationPageCost, pageRoom: PresentationPageCost, isPageEmpty: Bool
    ) -> PresentationPageSplit {
        let base = PresentationPageCost.container + table.headerPageCost
        guard base.fits(in: pageRoom), let first = table.rows.first else {
            // The header alone exceeds a page: its plain text, as paragraphs,
            // then the rows without a header.
            let rows: [PresentationBlock] = table.rows.isEmpty ? [] : [.table(PresentationTable(
                alignments: table.alignments, header: [], rows: table.rows
            ))]
            return .replaced([.plainParagraph(PresentationTable.plainText(ofRow: table.header))] + rows)
        }
        var used = base
        var count = 0
        for row in table.rows {
            let next = used + PresentationTable.pageCost(ofRow: row)
            guard next.fits(in: room) else { break }
            used = next
            count += 1
        }
        let total = table.rows.count
        if count > 0 {
            return .pieces(
                head: [.table(table.rows(in: 0 ..< count))],
                tail: count < total ? [.table(table.rows(in: count ..< total))] : []
            )
        }
        guard isPageEmpty || !(base + PresentationTable.pageCost(ofRow: first)).fits(in: pageRoom) else {
            return .nextPage
        }
        // The first row with the header exceeds a page: the row's plain text,
        // as paragraphs.
        let rest: [PresentationBlock] = total > 1 ? [.table(table.rows(in: 1 ..< total))] : []
        return .replaced([.plainParagraph(PresentationTable.plainText(ofRow: first))] + rest)
    }

    private static func splitQuote(
        _ blocks: [PresentationBlock], room: PresentationPageCost, pageRoom: PresentationPageCost, isPageEmpty: Bool
    ) -> PresentationPageSplit {
        guard let first = blocks.first else { return .nextPage }
        var used = PresentationPageCost.container
        var count = 0
        for block in blocks {
            let next = used + block.pageCost
            guard next.fits(in: room) else { break }
            used = next
            count += 1
        }
        if count > 0 {
            return .pieces(
                head: [.quote(Array(blocks[..<count]))],
                tail: count < blocks.count ? [.quote(Array(blocks[count...]))] : []
            )
        }
        guard room.blocks >= 2,
              isPageEmpty || !(PresentationPageCost.container + first.pageCost).fits(in: pageRoom) else {
            return .nextPage
        }
        // The first block alone exceeds a page: it is split inside the
        // quotation, which takes one block of the room.
        let rest = blocks.dropFirst()
        switch split(
            first, room: room - .container, pageRoom: pageRoom - .container, isPageEmpty: isPageEmpty
        ) {
        case .nextPage:
            return .nextPage
        case let .pieces(head, tail):
            let remainder = tail + rest
            return .pieces(head: [.quote(head)], tail: remainder.isEmpty ? [] : [.quote(remainder)])
        case let .replaced(replacement):
            return .replaced([.quote(replacement + rest)])
        }
    }
}

// MARK: - Plain text

/// Cuts a plain text into pieces within a length, measured in UTF-8 bytes or
/// in UTF-16 code units, always on grapheme boundaries.
enum PresentationTextSplitter {
    enum Measure: Sendable {
        case utf8Bytes
        case utf16Units

        func width(of character: Character) -> Int {
            switch self {
            case .utf8Bytes: character.utf8.count
            case .utf16Units: character.utf16.count
            }
        }
    }

    /// One pass over the start of a text, up to the first character that
    /// would take it past `limit`: where the longest prefix within the limit
    /// ends, and the last blank line, line break, and whitespace in it.
    struct Scan {
        let text: Substring
        /// Whether the whole text is within the limit.
        let fitsWhole: Bool
        /// The end of the longest prefix within the limit.
        let end: String.Index
        /// After the last line break that ends a blank line.
        let afterBlankLine: String.Index?
        /// After the last line break.
        let afterLineBreak: String.Index?
        /// After the last whitespace, a line break included.
        let afterWhitespace: String.Index?

        init(_ text: Substring, limit: Int, measure: Measure) {
            var width = 0
            var index = text.startIndex
            var afterBlankLine: String.Index?
            var afterLineBreak: String.Index?
            var afterWhitespace: String.Index?
            // Whether only whitespace follows the last line break.
            var lineIsBlank = false
            while index < text.endIndex {
                let character = text[index]
                width += measure.width(of: character)
                guard width <= limit else { break }
                let next = text.index(after: index)
                if character.isNewline {
                    if lineIsBlank { afterBlankLine = next }
                    afterLineBreak = next
                    lineIsBlank = true
                } else if !character.isWhitespace {
                    lineIsBlank = false
                }
                if character.isWhitespace { afterWhitespace = next }
                index = next
            }
            self.text = text
            fitsWhole = index == text.endIndex
            end = index
            self.afterBlankLine = afterBlankLine
            self.afterLineBreak = afterLineBreak
            self.afterWhitespace = afterWhitespace
        }

        /// The end of the longest prefix within the limit; when not even the
        /// first grapheme fits, the end of that grapheme if `mustTake`, else
        /// `nil`.
        func graphemeEnd(mustTake: Bool) -> String.Index? {
            if end > text.startIndex { return end }
            guard mustTake, !text.isEmpty else { return nil }
            return text.index(after: text.startIndex)
        }
    }

    /// `text` cut where the longest prefix within `limit` UTF-8 bytes ends
    /// after whitespace; the whole text and nothing when it fits. A first
    /// word longer than the limit is cut by graphemes only when it exceeds
    /// `pageLimit` too, or when `mustTake` asks for a piece anyway; otherwise
    /// `nil`: the word fits a whole page.
    static func splitAtWhitespace(
        _ text: String, limit: Int, pageLimit: Int, mustTake: Bool
    ) -> (String, String)? {
        let scan = Scan(text[...], limit: limit, measure: .utf8Bytes)
        if scan.fitsWhole { return (text, "") }
        if let end = scan.afterWhitespace {
            return (String(text[..<end]), String(text[end...]))
        }
        guard mustTake || firstWordWidth(text, measure: .utf8Bytes) > pageLimit,
              let end = scan.graphemeEnd(mustTake: mustTake) else {
            return nil
        }
        return (String(text[..<end]), String(text[end...]))
    }

    /// `text` as pieces of at most `limit` each, in order, trimmed and none
    /// blank: each one cut after the last blank line within the limit, else
    /// the last line break, else the last whitespace, else the last grapheme
    /// that fits. A single grapheme wider than the limit is a piece of its
    /// own.
    static func pieces(of text: String, limit: Int, measure: Measure) -> [String] {
        var pieces: [String] = []
        var rest = text[...].drop(while: \.isWhitespace)
        while !rest.isEmpty {
            let scan = Scan(rest, limit: limit, measure: measure)
            let end = scan.fitsWhole
                ? rest.endIndex
                : scan.afterBlankLine ?? scan.afterLineBreak ?? scan.afterWhitespace
                    ?? scan.graphemeEnd(mustTake: true) ?? rest.endIndex
            let piece = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            rest = rest[end...].drop(while: \.isWhitespace)
        }
        return pieces
    }

    /// The width of the text up to its first whitespace, that whitespace
    /// included.
    private static func firstWordWidth(_ text: String, measure: Measure) -> Int {
        var width = 0
        for character in text {
            width += measure.width(of: character)
            if character.isWhitespace { break }
        }
        return width
    }
}
