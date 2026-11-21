import Foundation
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

/// The split of a document into ordered pages within a budget
/// (`PresentationDocument.pages(within:)`), and the cut of a plain text into
/// pieces within a length (`PresentationTextSplitter`).
extension PresentationDocumentTests {
    // MARK: - Pages

    /// A document within the budget, up to its last byte and block, is its
    /// only page, unchanged.
    @Test
    func aDocumentWithinTheBudgetIsItsOnlyPageUnchanged() {
        let document = PresentationDocument(markdown: """
        # Title

        Some **bold** text with [a link](https://example.com/a).

        1. one
        2. [x] two

        > quoted `code`

        | a | b |
        |---|--:|
        | 1 | 2 |

        ---

        ```swift
        let x = 1
        ```
        """)
        let cost = document.pageCost
        #expect(document.pages(within: Self.budget(bytes: cost.bytes, blocks: cost.blocks)) == [document])
        #expect(document.pages(within: Self.budget(bytes: 30_000, blocks: 450)) == [document])
    }

    /// Top-level blocks are packed in order, never reordered nor split when
    /// each fits a page: every page is filled until the next block does not
    /// fit it.
    @Test
    func topLevelBlocksArePackedInOrderWithinTheBudget() {
        let blocks = (1 ... 12).map { PresentationBlock.plainParagraph("Paragraph \($0)") }
        let document = PresentationDocument(blocks: blocks)
        let budget = Self.budget(bytes: 40, blocks: 450)

        let pages = document.pages(within: budget)

        #expect(pages.map(\.blocks.count) == [3, 3, 3, 3])
        #expect(pages.flatMap(\.blocks) == blocks)
        Self.expectPages(pages, within: budget)
        for (page, next) in zip(pages, pages.dropFirst()) {
            #expect(!(page.pageCost + next.blocks[0].pageCost).fits(in: Self.room(budget)))
        }
    }

    /// A code block larger than a page is split by lines, each piece with
    /// the block's language, and a line larger than a page on grapheme
    /// boundaries.
    @Test
    func aCodeBlockIsSplitByLinesKeepingItsLanguage() {
        let lines = (1 ... 20).map { String(format: "line %02d", $0) }
        let code = lines.joined(separator: "\n")
        let budget = Self.budget(bytes: 30, blocks: 450)

        let pages = PresentationDocument(blocks: [.preformatted(code: code, language: "swift")]).pages(within: budget)

        Self.expectPages(pages, within: budget)
        let pieces = pages.flatMap(\.blocks).compactMap { block -> (String, String?)? in
            guard case let .preformatted(code, language) = block else { return nil }
            return (code, language)
        }
        #expect(pages.allSatisfy { $0.blocks.count == 1 })
        #expect(pieces.count == 7)
        #expect(pieces.allSatisfy { $0.1 == "swift" })
        #expect(pieces.first?.0 == lines[0 ..< 3].joined(separator: "\n"))
        #expect(pieces.map(\.0).joined(separator: "\n") == code)

        // 👍🏽 is one grapheme of 8 bytes: three of them fit 30 bytes.
        let line = String(repeating: "👍🏽", count: 20)
        let long = PresentationDocument(blocks: [.preformatted(code: "short\n" + line, language: nil)]).pages(within: budget)
        Self.expectPages(long, within: budget)
        let codes = long.flatMap(\.blocks).compactMap { block -> String? in
            guard case let .preformatted(code, nil) = block else { return nil }
            return code
        }
        #expect(codes == ["short"] + Array(repeating: "👍🏽👍🏽👍🏽", count: 6) + ["👍🏽👍🏽"])
    }

    /// An ordered list larger than a page is split by items, every piece
    /// numbering on from where the previous one stopped.
    @Test
    func anOrderedListGoesOnNumberingInTheNextPiece() {
        let document = PresentationDocument(markdown: (3 ... 12).map { "\($0). item \($0)" }.joined(separator: "\n"))
        // A list and three items of one paragraph each: 7 blocks.
        let budget = Self.budget(bytes: 1_000, blocks: 7)

        let pages = document.pages(within: budget)

        Self.expectPages(pages, within: budget)
        let lists = pages.flatMap(\.blocks).compactMap { block -> PresentationList? in
            guard case let .list(list) = block else { return nil }
            return list
        }
        #expect(lists.map(\.kind) == [.ordered(start: 3), .ordered(start: 6), .ordered(start: 9), .ordered(start: 12)])
        #expect(lists.map(\.items.count) == [3, 3, 3, 1])
        #expect(lists.map(\.plainText).joined(separator: "\n") == document.plainText)
    }

    /// A table larger than a page is split by rows, every piece with the
    /// header and the alignments.
    @Test
    func aTableIsSplitByRowsRepeatingItsHeaderAndAlignments() throws {
        let document = PresentationDocument(markdown: """
        | Name | Qty |
        |:-----|----:|
        \((1 ... 6).map { "| a\($0) | \($0) |" }.joined(separator: "\n"))
        """)
        guard case let .table(table) = try #require(document.blocks.first) else {
            Issue.record("Not a table: \(document.blocks)")
            return
        }
        // The header line and a line break take 11 bytes, each row 7.
        let budget = Self.budget(bytes: 30, blocks: 450)

        let pages = document.pages(within: budget)

        Self.expectPages(pages, within: budget)
        let pieces = pages.flatMap(\.blocks).compactMap { block -> PresentationTable? in
            guard case let .table(piece) = block else { return nil }
            return piece
        }
        #expect(pieces.count == 3)
        #expect(pieces.allSatisfy { $0.header == table.header && $0.alignments == [.left, .right] })
        #expect(pieces.map(\.rows.count) == [2, 2, 2])
        #expect(pieces.flatMap(\.rows) == table.rows)
    }

    /// A quotation larger than a page is split by its blocks, and a block of
    /// it larger than a page inside the quotation, recursively.
    @Test
    func aQuotationIsSplitByItsBlocksRecursively() {
        let document = PresentationDocument(blocks: [.quote([
            .plainParagraph("alpha one"),
            .plainParagraph("beta two"),
            .quote([.plainParagraph("gamma three"), .plainParagraph("delta four")]),
            .plainParagraph("epsilon"),
        ])])
        let budget = Self.budget(bytes: 20, blocks: 450)

        let pages = document.pages(within: budget)

        #expect(pages.map(\.blocks) == [
            [.quote([.plainParagraph("alpha one"), .plainParagraph("beta two")])],
            [.quote([.quote([.plainParagraph("gamma three")])])],
            [.quote([.quote([.plainParagraph("delta four")]), .plainParagraph("epsilon")])],
        ])
        Self.expectPages(pages, within: budget)
        #expect(Self.leafText(pages.flatMap(\.blocks)) == Self.leafText(document.blocks))
    }

    /// A paragraph without spaces is cut on grapheme boundaries: a letter
    /// and its combining accent stay together.
    @Test
    func aParagraphWithoutSpacesIsCutOnGraphemeBoundaries() {
        // `e` and a combining acute accent: one grapheme of 3 bytes.
        let text = String(repeating: "e\u{301}", count: 20)
        let budget = Self.budget(bytes: 20, blocks: 450)

        let pages = PresentationDocument(blocks: [.plainParagraph(text)]).pages(within: budget)

        Self.expectPages(pages, within: budget)
        let texts = pages.flatMap(\.blocks).map(\.plainText)
        #expect(texts.map(\.count) == [6, 6, 6, 2])
        #expect(texts.allSatisfy { $0.unicodeScalars.count == 2 * $0.count })
        #expect(texts.joined() == text)
    }

    /// A heading larger than a page is cut at spaces; its pieces after the
    /// first are paragraphs.
    @Test
    func aHeadingIsCutAtSpacesAndItsLaterPiecesAreParagraphs() {
        let heading = PresentationBlock.heading(level: 2, text: Self.pageText("alpha beta gamma delta epsilon"))

        let pages = PresentationDocument(blocks: [heading]).pages(within: Self.budget(bytes: 12, blocks: 450))

        #expect(pages.map(\.blocks) == [
            [.heading(level: 2, text: Self.pageText("alpha beta "))],
            [.plainParagraph("gamma delta ")],
            [.plainParagraph("epsilon")],
        ])
    }

    /// A paragraph is split by its runs; a styled run larger than a page is
    /// cut as its plain text.
    @Test
    func aStyledRunLargerThanAPageIsCutAsItsPlainText() {
        let paragraph = PresentationBlock.paragraph(PresentationText(runs: [
            .plain("Lead "), .strong(Self.pageText("one two three four five six")),
        ]))

        let pages = PresentationDocument(blocks: [paragraph]).pages(within: Self.budget(bytes: 15, blocks: 450))

        #expect(pages.map(\.blocks) == [
            [.plainParagraph("Lead ")],
            [.plainParagraph("one two three ")],
            [.plainParagraph("four five six")],
        ])
    }

    /// A list item that alone exceeds a page is its plain text, marker
    /// included, as paragraphs; the list goes on numbering after it.
    @Test
    func aListItemLargerThanAPageIsItsPlainTextInParagraphs() {
        let list = PresentationList(kind: .ordered(start: 1), items: [
            PresentationListItem(blocks: [.plainParagraph("short")]),
            PresentationListItem(blocks: [.plainParagraph("one two three four five six seven")]),
            PresentationListItem(blocks: [.plainParagraph("last")]),
        ])

        let pages = PresentationDocument(blocks: [.list(list)]).pages(within: Self.budget(bytes: 20, blocks: 450))

        #expect(pages.map(\.blocks) == [
            [.list(PresentationList(kind: .ordered(start: 1), items: [list.items[0]]))],
            [.plainParagraph("2. one two three ")],
            [.plainParagraph("four five six seven")],
            [.list(PresentationList(kind: .ordered(start: 3), items: [list.items[2]]))],
        ])
    }

    /// A table row that with the header exceeds a page is its plain text, as
    /// paragraphs; the rows before and after it stay tables with the header.
    @Test
    func aTableRowLargerThanAPageIsItsPlainTextInParagraphs() {
        let table = PresentationTable(
            alignments: [.left, .left],
            header: [Self.pageText("k"), Self.pageText("v")],
            rows: [
                [Self.pageText("a"), Self.pageText("1")],
                [Self.pageText("b"), Self.pageText("one two three four five six")],
                [Self.pageText("c"), Self.pageText("3")],
            ]
        )

        let pages = PresentationDocument(blocks: [.table(table)]).pages(within: Self.budget(bytes: 20, blocks: 450))

        #expect(pages.map(\.blocks) == [
            [.table(PresentationTable(alignments: table.alignments, header: table.header, rows: [table.rows[0]]))],
            [.plainParagraph("b | one two three ")],
            [.plainParagraph("four five six")],
            [.table(PresentationTable(alignments: table.alignments, header: table.header, rows: [table.rows[2]]))],
        ])
    }

    /// Every nested block, list item, and table row counts against the
    /// block budget.
    @Test
    func nestedBlocksListItemsAndTableRowsCountAgainstTheBlockBudget() {
        let item = { (text: String) in PresentationListItem(blocks: [.plainParagraph(text)]) }
        let quote = PresentationBlock.quote([
            .list(PresentationList(kind: .unordered, items: [item("a"), item("b")])),
            .plainParagraph("text"),
        ])
        // The quotation, the list, two items with a paragraph each, a paragraph.
        #expect(quote.pageCost == PresentationPageCost(bytes: 6, blocks: 7))
        let table = PresentationTable(
            alignments: [.left], header: [Self.pageText("h")], rows: [[Self.pageText("1")], [Self.pageText("2")]]
        )
        // The table, the header row, two rows; each row its text and a line break.
        #expect(PresentationBlock.table(table).pageCost == PresentationPageCost(bytes: 6, blocks: 4))
        #expect(PresentationBlock.divider.pageCost == PresentationPageCost(bytes: 0, blocks: 1))

        let list = PresentationList(kind: .unordered, items: (1 ... 10).map { item("item \($0)") })
        let budget = Self.budget(bytes: 1_000, blocks: 7)
        let pages = PresentationDocument(blocks: [.list(list)]).pages(within: budget)
        Self.expectPages(pages, within: budget)
        #expect(pages.map(\.pageCost.blocks) == [7, 7, 7, 3])
    }

    /// Beyond the page limit the document is cut: the last page ends with
    /// the notice, after its blocks when it fits, in place of its last block
    /// otherwise. A document of exactly the limit is not cut.
    @Test
    func beyondThePageLimitTheLastPageEndsWithTheTruncationNotice() {
        let notice = PresentationBlock.plainParagraph("… cut.")
        let paragraphs = (1 ... 7).map { PresentationBlock.plainParagraph("p\($0)") }
        let byBlocks = Self.budget(bytes: 1_000, blocks: 3, pages: 2)
        #expect(PresentationDocument(blocks: paragraphs).pages(within: byBlocks).map(\.blocks) == [
            Array(paragraphs[0 ..< 3]), [paragraphs[3], paragraphs[4], notice],
        ])
        #expect(PresentationDocument(blocks: Array(paragraphs[0 ..< 6])).pages(within: byBlocks).map(\.blocks) == [
            Array(paragraphs[0 ..< 3]), Array(paragraphs[3 ..< 6]),
        ])

        let twelve = ["A", "B", "C", "D"].map { PresentationBlock.plainParagraph(String(repeating: $0, count: 12)) }
        let byBytes = Self.budget(bytes: 20, blocks: 450, pages: 2)
        #expect(PresentationDocument(blocks: twelve).pages(within: byBytes).map(\.blocks) == [
            [twelve[0]], [twelve[1], notice],
        ])
    }

    /// No text is lost and its order is kept, whatever the blocks.
    @Test
    func pagesKeepEveryTextInOrder() {
        let document = PresentationDocument(markdown: """
        # A heading that is long enough to be cut

        \((1 ... 30).map { "word\($0)" }.joined(separator: " "))

        - [x] first item
        - second item with **bold words** and `code`

        > quoted paragraph one
        >
        > ```
        > code line one
        > code line two
        > ```

        | col | other |
        |-----|-------|
        \((1 ... 8).map { "| r\($0) | value \($0) |" }.joined(separator: "\n"))
        """)
        let budget = Self.budget(bytes: 40, blocks: 6)

        let pages = document.pages(within: budget)

        #expect(pages.count > 1)
        Self.expectPages(pages, within: budget)
        let original = Self.stripped(Self.leafText(document.blocks))
        let split = Self.stripped(Self.leafText(pages.flatMap(\.blocks)))
        #expect(Self.isSubsequence(original, of: split), "\(split)")
    }

    // MARK: - Plain-text pieces

    /// A plain text is cut after the last blank line within the limit, else
    /// the last line break, else the last whitespace, else on a grapheme
    /// boundary; every piece is within the limit, trimmed, and nothing is
    /// lost.
    @Test
    func plainTextPiecesPreferBlankLinesThenLineBreaksThenSpacesThenGraphemes() {
        let text = "first part\n\nsecond line\nthird words here and more"
        let pieces = PresentationTextSplitter.pieces(of: text, limit: 20, measure: .utf16Units)
        #expect(pieces == ["first part", "second line", "third words here", "and more"])
        #expect(Self.stripped(pieces.joined()) == Self.stripped(text))

        // The family emoji is one grapheme of 11 UTF-16 units.
        let family = "👨‍👩‍👧‍👦"
        #expect(PresentationTextSplitter.pieces(of: String(repeating: family, count: 3), limit: 20, measure: .utf16Units)
            == [family, family, family])
        #expect(PresentationTextSplitter.pieces(of: " \n \n ", limit: 20, measure: .utf16Units).isEmpty)
    }

    // MARK: - Helpers

    private static func budget(bytes: Int, blocks: Int, pages: Int = .max) -> PresentationPageBudget {
        PresentationPageBudget(maximumTextBytes: bytes, maximumBlocks: blocks, maximumPages: pages, truncationNotice: "… cut.")
    }

    private static func room(_ budget: PresentationPageBudget) -> PresentationPageCost {
        PresentationPageCost(bytes: budget.maximumTextBytes, blocks: budget.maximumBlocks)
    }

    private static func pageText(_ text: String) -> PresentationText {
        PresentationText(runs: [.plain(text)])
    }

    private static func expectPages(
        _ pages: [PresentationDocument], within budget: PresentationPageBudget,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for page in pages {
            #expect(page.pageCost.fits(in: room(budget)), "\(page.pageCost)", sourceLocation: sourceLocation)
            #expect(!page.blocks.isEmpty, sourceLocation: sourceLocation)
        }
    }

    /// The text of the blocks without what the plain-text projection adds:
    /// list markers, quotation prefixes, cell separators.
    private static func leafText(_ blocks: [PresentationBlock]) -> String {
        blocks.map { block in
            switch block {
            case let .paragraph(text), let .heading(_, text): text.plainText
            case let .preformatted(code, _): code
            case let .list(list): list.items.map { leafText($0.blocks) }.joined()
            case let .quote(inner): leafText(inner)
            case let .table(table): ([table.header] + table.rows).joined().map(\.plainText).joined()
            case .divider: ""
            }
        }.joined()
    }

    private static func stripped(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    /// Whether every character of `needle` appears in `haystack`, in order.
    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = haystack[...]
        for character in needle {
            guard let index = remaining.firstIndex(of: character) else { return false }
            remaining = remaining[remaining.index(after: index)...]
        }
        return true
    }
}
