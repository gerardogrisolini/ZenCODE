import Foundation
import Testing
@testable import ZenCODECore

/// The Markdown-to-presentation-tree conversion and its plain-text projection,
/// the text the Telegram fallback sends, for every construct the parser
/// recognizes.
@Suite
struct PresentationDocumentTests {

    @Test
    func tableKeepsAlignmentsHeaderAndCells() throws {
        let document = PresentationDocument(markdown: """
        | Name | Qty | Note | Plain |
        |:-----|:---:|-----:|-------|
        | a | **1** |  | z |
        """)
        #expect(document.blocks == [.table(PresentationTable(
            alignments: [.left, .center, .right, .left],
            header: [plain("Name"), plain("Qty"), plain("Note"), plain("Plain")],
            rows: [[plain("a"), PresentationText(runs: [.strong(plain("1"))]), PresentationText(runs: []), plain("z")]]
        ))])
        #expect(document.plainText == "Name | Qty | Note | Plain\na | 1 |  | z")
    }

    @Test
    func quotationKeepsItsListAndCodeBlock() throws {
        let document = PresentationDocument(markdown: """
        > quoted **text**
        >
        > - item
        >
        > ```swift
        > let x = 1
        > ```
        """)
        #expect(document.blocks == [.quote([
            .paragraph(PresentationText(runs: [.plain("quoted "), .strong(plain("text"))])),
            .list(PresentationList(kind: .unordered, items: [PresentationListItem(blocks: [.paragraph(plain("item"))])])),
            .preformatted(code: "let x = 1", language: "swift"),
        ])])
        #expect(document.plainText == "> quoted text\n> \n> • item\n> \n> let x = 1")
    }

    @Test
    func thematicBreakBecomesDivider() throws {
        let document = PresentationDocument(markdown: "before\n\n---\n\nafter")
        #expect(document.blocks == [.paragraph(plain("before")), .divider, .paragraph(plain("after"))])
        #expect(document.plainText == "before\n\n———\n\nafter")
    }

    @Test
    func strikethroughKeepsItsStyle() throws {
        let document = PresentationDocument(markdown: "~~gone~~ kept")
        #expect(document.blocks == [.paragraph(PresentationText(runs: [.strikethrough(plain("gone")), .plain(" kept")]))])
        #expect(document.plainText == "gone kept")
    }

    @Test
    func taskListItemsKeepTheirCheckbox() throws {
        let document = PresentationDocument(markdown: "- [ ] todo\n- [x] done\n- plain")
        #expect(document.blocks == [.list(PresentationList(kind: .unordered, items: [
            PresentationListItem(blocks: [.paragraph(plain("todo"))], checkbox: .unchecked),
            PresentationListItem(blocks: [.paragraph(plain("done"))], checkbox: .checked),
            PresentationListItem(blocks: [.paragraph(plain("plain"))]),
        ]))])
        #expect(document.plainText == "☐ todo\n☑ done\n• plain")
    }

    @Test
    func orderedListKeepsItsStart() throws {
        let document = PresentationDocument(markdown: "3. three\n4. four\n5. [x] five")
        #expect(document.blocks == [.list(PresentationList(kind: .ordered(start: 3), items: [
            PresentationListItem(blocks: [.paragraph(plain("three"))]),
            PresentationListItem(blocks: [.paragraph(plain("four"))]),
            PresentationListItem(blocks: [.paragraph(plain("five"))], checkbox: .checked),
        ]))])
        #expect(document.plainText == "3. three\n4. four\n☑ five")
    }

    @Test
    func inlineHTMLStaysVisibleAsText() throws {
        let document = PresentationDocument(markdown: "Use Array<Int> or `Array<Int>`, a <b>tag</b>")
        #expect(document.blocks == [.paragraph(PresentationText(runs: [
            .plain("Use Array"), .plain("<Int>"), .plain(" or "), .code("Array<Int>"), .plain(", a "),
            .plain("<b>"), .plain("tag"), .plain("</b>"),
        ]))])
        #expect(document.plainText == "Use Array<Int> or Array<Int>, a <b>tag</b>")
    }

    @Test
    func htmlBlockStaysVisibleAsAParagraph() throws {
        let document = PresentationDocument(markdown: "<details>\n<summary>Hi</summary>\n</details>\n\nafter")
        #expect(document.blocks == [
            .paragraph(plain("<details>\n<summary>Hi</summary>\n</details>")),
            .paragraph(plain("after")),
        ])
        #expect(document.plainText == "<details>\n<summary>Hi</summary>\n</details>\n\nafter")
    }

    @Test
    func httpLinkKeepsItsURLAsTextAndOtherSchemesAreUnchanged() throws {
        let document = PresentationDocument(markdown: """
        [**docs**](http://example.com/a), <http://example.com/b>, [s](https://example.com/s), \
        [m](mailto:a@example.com), [r](docs/readme.md)
        """)
        let secure = try #require(URL(string: "https://example.com/s"))
        #expect(document.blocks == [.paragraph(PresentationText(runs: [
            .strong(plain("docs")), .plain(" (http://example.com/a)"), .plain(", "),
            .plain("http://example.com/b"), .plain(", "),
            .link(label: plain("s"), url: secure), .plain(", "),
            .plain("m"), .plain(", "),
            .plain("r"),
        ]))])
        #expect(document.plainText == "docs (http://example.com/a), http://example.com/b, s, m, r")
    }

    @Test
    func imageIsALinkLabelledWithItsAlternativeText() throws {
        let document = PresentationDocument(markdown: """
        ![logo](https://example.com/logo.png) ![](http://example.com/i.png) ![shot](http://example.com/s.png) \
        ![alt](img/a.png) ![](https://example.com/bare.png)
        """)
        let logo = try #require(URL(string: "https://example.com/logo.png"))
        let bare = try #require(URL(string: "https://example.com/bare.png"))
        #expect(document.blocks == [.paragraph(PresentationText(runs: [
            .link(label: plain("logo"), url: logo), .plain(" "),
            .plain("http://example.com/i.png"), .plain(" "),
            .plain("shot"), .plain(" (http://example.com/s.png)"), .plain(" "),
            .plain("alt"), .plain(" "),
            .link(label: plain("https://example.com/bare.png"), url: bare),
        ]))])
        #expect(document.plainText == """
        logo http://example.com/i.png shot (http://example.com/s.png) alt https://example.com/bare.png
        """)
    }

    private func plain(_ text: String) -> PresentationText {
        PresentationText(runs: [.plain(text)])
    }
}
