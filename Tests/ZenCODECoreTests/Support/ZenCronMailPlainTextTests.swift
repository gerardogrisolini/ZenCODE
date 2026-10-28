//
//  ZenCronMailPlainTextTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Cron mail plain text")
struct ZenCronMailPlainTextTests {
    private func render(_ markdown: String) -> String {
        ZenCronMailPlainText.render(markdown: markdown)
    }

    // MARK: - Blocks

    @Test("an empty or blank document is the empty string")
    func emptyDocument() {
        #expect(render("") == "")
        #expect(render("  \n\n \t\n") == "")
    }

    @Test("top-level blocks are separated by one blank line and the text ends with one line break")
    func blocksAreSeparatedByOneBlankLine() {
        #expect(render("one\n\n\n\ntwo\n\n\n") == "one\n\ntwo\n")
        #expect(render("one") == "one\n")
    }

    @Test("a heading is its text on a line of its own")
    func headings() {
        #expect(
            render("# Title\n\n## Sub **bold** `code`\n\n###### Deep\ntext")
                == "Title\n\nSub bold code\n\nDeep\n\ntext\n"
        )
    }

    @Test("strong, emphasis, strikethrough and code keep only their text")
    func inlineStyles() {
        #expect(
            render("**bold** *it* _it_ ~~gone~~ `a < b` ***both***")
                == "bold it it gone a < b both\n"
        )
        #expect(render("escaped \\*star\\* and &amp; entity") == "escaped *star* and & entity\n")
    }

    @Test("the author's characters are kept: no smart quotes, dashes or ellipses")
    func noTypographicSubstitution() {
        #expect(
            render("say \"hi\" -- it's ... fine; run `zen --jsonl` or zen --jsonl")
                == "say \"hi\" -- it's ... fine; run zen --jsonl or zen --jsonl\n"
        )
    }

    @Test("soft and hard line breaks of the source are kept as line breaks")
    func lineBreaks() {
        #expect(render("line one\nline two") == "line one\nline two\n")
        #expect(render("hard  \nbreak") == "hard\nbreak\n")
        #expect(render("backslash\\\nbreak") == "backslash\nbreak\n")
    }

    @Test("a thematic break is a line of 40 box-drawing dashes")
    func thematicBreak() {
        #expect(render("above\n\n---\n\nbelow") == "above\n\n" + String(repeating: "─", count: 40) + "\n\nbelow\n")
    }

    // MARK: - Lists

    @Test("bullets nest with the text column of the parent and change glyph after the first level")
    func nestedBullets() {
        let markdown = """
        - one
          - two
            - three
        - four
        """
        #expect(render(markdown) == "• one\n  ◦ two\n    ◦ three\n• four\n")
    }

    @Test("a bullet list under a numbered item aligns with the text after the number")
    func bulletsUnderNumberedItems() {
        let markdown = """
        3. first
        4. second
           - nested
        """
        #expect(render(markdown) == "3. first\n4. second\n   ◦ nested\n")
    }

    @Test("numbered lists count from the start index of the list")
    func numberedLists() {
        #expect(render("1. a\n2. b\n3. c") == "1. a\n2. b\n3. c\n")
        #expect(render("7. a\n1. b\n1. c") == "7. a\n8. b\n9. c\n")
        #expect(render("0. zero\n1. one") == "0. zero\n1. one\n")
    }

    @Test("items sit on consecutive lines and their paragraphs are separated by a blank line")
    func itemParagraphs() {
        let markdown = """
        - first

          second paragraph
        - next

        Outside
        """
        #expect(render(markdown) == "• first\n\n  second paragraph\n• next\n\nOutside\n")
    }

    @Test("continuation lines align with the text after the number, whatever its width")
    func continuationUnderWideNumbers() {
        let markdown = """
        9. nine
        10. ten
            line two\\
            hard break

            second paragraph
        """
        #expect(render(markdown) == "9. nine\n10. ten\n    line two\n    hard break\n\n    second paragraph\n")
    }

    @Test("a task box replaces the bullet of a bulleted item")
    func taskBoxesReplaceBullets() {
        let markdown = """
        - [x] done
        - [ ] to do
          - nested
        - plain
        """
        #expect(render(markdown) == "[x] done\n[ ] to do\n    ◦ nested\n• plain\n")
    }

    @Test("a task box follows the number of a numbered item")
    func taskBoxesFollowNumbers() {
        #expect(render("1. [x] done\n2. [ ] to do") == "1. [x] done\n2. [ ] to do\n")
    }

    // MARK: - Links and images

    @Test("a link reads text and url, and just one of them when the other adds nothing")
    func links() {
        #expect(render("[docs](https://example.com/docs)") == "docs (https://example.com/docs)\n")
        #expect(render("<https://example.com>") == "https://example.com\n")
        #expect(render("[https://example.com](https://example.com)") == "https://example.com\n")
        #expect(render("[**bold** link](https://example.com)") == "bold link (https://example.com)\n")
        #expect(render("[](https://example.com)") == "https://example.com\n")
        #expect(render("[only text]()") == "only text\n")
    }

    @Test("a mailto link whose text is the address is just the address")
    func mailtoLinks() {
        #expect(render("<user@example.com>") == "user@example.com\n")
        #expect(render("[user@example.com](mailto:user@example.com)") == "user@example.com\n")
        #expect(
            render("[write me](mailto:user@example.com)") == "write me (mailto:user@example.com)\n"
        )
    }

    @Test("an image reads alt text and url, or just the url without alt text")
    func images() {
        #expect(render("![logo](https://example.com/logo.png)") == "logo (https://example.com/logo.png)\n")
        #expect(render("![](https://example.com/logo.png)") == "https://example.com/logo.png\n")
        #expect(render("![just alt]()") == "just alt\n")
    }

    // MARK: - Code and quotes

    @Test("code keeps its content, indented by four spaces, with no fences and no trailing spaces")
    func codeBlocks() {
        let markdown = """
        Before

        ```swift
        let x = 1

        print(x)\u{20}\u{20}\u{20}
        ```

        After
        """
        #expect(render(markdown) == "Before\n\n    let x = 1\n\n    print(x)\n\nAfter\n")
    }

    @Test("code inside a list item is indented relative to the item")
    func codeInListItem() {
        let markdown = """
        - run:

          ```
          make

          make test
          ```
        """
        #expect(render(markdown) == "• run:\n\n      make\n\n      make test\n")
    }

    @Test("every line of a quote starts with a bar, blank lines get just the bar")
    func blockQuotes() {
        let markdown = """
        > quote

        > first
        >
        > second
        >
        > > nested
        """
        #expect(
            render(markdown) == "│ quote\n\n│ first\n│\n│ second\n│\n│ │ nested\n"
        )
    }

    // MARK: - Tables

    @Test("each body row becomes a block of Header: value lines, empty cells and rows left out")
    func tables() {
        let markdown = """
        | Task | Owner | Due |
        | --- | :---: | ---: |
        | Write docs | Ann | Friday |
        | Fix bug | | Monday |
        |  |  |  |
        | Ship | Bob | |
        """
        #expect(
            render(markdown)
                == "Task: Write docs\nOwner: Ann\nDue: Friday\n\nTask: Fix bug\nDue: Monday\n\nTask: Ship\nOwner: Bob\n"
        )
    }

    @Test("a column without a header shows just the value")
    func tableWithAnEmptyHeader() {
        let markdown = """
        | | Status |
        | --- | --- |
        | Deploy | ok |
        """
        #expect(render(markdown) == "Deploy\nStatus: ok\n")
    }

    @Test("a table without body rows is its headers on one line")
    func tableWithoutBody() {
        #expect(render("| Name | Owner | Due |\n| --- | --- | --- |") == "Name · Owner · Due\n")
    }

    @Test("a cell is rendered like inline text on a single line")
    func tableCellContent() {
        let markdown = """
        | Item | Notes |
        | --- | --- |
        | **bold** | one<br>two<br/>three and [site](https://example.com) |
        """
        #expect(
            render(markdown) == "Item: bold\nNotes: one two three and site (https://example.com)\n"
        )
    }

    @Test("a table sits between its neighbours like any other block")
    func tableBetweenParagraphs() {
        let markdown = """
        Before

        | A | B |
        | --- | --- |
        | 1 | 2 |

        After
        """
        #expect(render(markdown) == "Before\n\nA: 1\nB: 2\n\nAfter\n")
    }

    // MARK: - Raw HTML

    @Test("br tags are line breaks in any case and spelling")
    func lineBreakTags() {
        #expect(render("a<br>b<BR/>c<br />d<Br>e") == "a\nb\nc\nd\ne\n")
    }

    @Test("any other raw HTML stays literal")
    func otherHTMLStaysLiteral() {
        #expect(render("x <span>y</span> z") == "x <span>y</span> z\n")
        #expect(render("<div>hello *there*</div>") == "<div>hello *there*</div>\n")
        #expect(render("a <br class=\"x\"> b") == "a <br class=\"x\"> b\n")
    }

    // MARK: - Trailing spaces

    @Test("no line of the output ends with a space or a tab")
    func noTrailingWhitespace() {
        let markdown = """
        # Title\u{20}\u{20}\u{20}

        hard break\u{20}\u{20}
        next line\u{20}
        another\t

        - item with trailing\u{20}\u{20}\u{20}
          continuation\u{20}\u{20}\u{20}
        - [ ] box\u{20}\u{20}\u{20}\u{20}

        ```
        code\u{20}\u{20}\u{20}
        \ttabbed\t
        ```

        > quote\u{20}\u{20}\u{20}
        >
        > more

        | A | B |
        | --- | --- |
        | x\u{20}\u{20}\u{20} |\u{20}\u{20}\u{20}\u{20}\u{20}|
        """
        let rendered = render(markdown)
        #expect(!rendered.isEmpty)
        #expect(rendered.hasSuffix("\n"))
        for line in rendered.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            #expect(line.last != " " && line.last != "\t", "line ends with whitespace: \(line.debugDescription)")
        }
    }

    // MARK: - Realistic briefing

    @Test("a briefing with headings, a table and lists reads as plain text")
    func briefing() {
        let markdown = """
        # Daily briefing – 2026-10-28

        ## Calendar

        | Time | Event | Place |
        |------|-------|-------|
        | 09:30 | Standup | Zoom |
        | 14:00 | **Review** with Ann | Room 3 |

        ## Tasks

        1. Reply to **Marco**
        2. Prepare the demo
           - slides
           - [ ] rehearse

        > Remember: the release is on Friday.

        See [the board](https://example.com/board).
        """
        let expected = """
        Daily briefing – 2026-10-28

        Calendar

        Time: 09:30
        Event: Standup
        Place: Zoom

        Time: 14:00
        Event: Review with Ann
        Place: Room 3

        Tasks

        1. Reply to Marco
        2. Prepare the demo
           ◦ slides
           [ ] rehearse

        │ Remember: the release is on Friday.

        See the board (https://example.com/board).

        """
        #expect(render(markdown) == expected)
    }
}
