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

    /// Markdown and the plain text it reads as, one construct per case.
    static let renderings: [(String, String)] = [
        // An empty or blank document is the empty string.
        ("", ""),
        ("  \n\n \t\n", ""),
        // Top-level blocks are separated by one blank line and the text ends with one line break.
        ("one\n\n\n\ntwo\n\n\n", "one\n\ntwo\n"),
        ("one", "one\n"),
        // A heading is its text on a line of its own.
        ("# Title\n\n## Sub **bold** `code`\n\n###### Deep\ntext", "Title\n\nSub bold code\n\nDeep\n\ntext\n"),
        // Strong, emphasis, strikethrough and code keep only their text.
        ("**bold** *it* _it_ ~~gone~~ `a < b` ***both***", "bold it it gone a < b both\n"),
        ("escaped \\*star\\* and &amp; entity", "escaped *star* and & entity\n"),
        // The author's characters are kept: no smart quotes, dashes or ellipses.
        (
            "say \"hi\" -- it's ... fine; run `zen --jsonl` or zen --jsonl",
            "say \"hi\" -- it's ... fine; run zen --jsonl or zen --jsonl\n"
        ),
        // Soft and hard line breaks of the source are kept as line breaks.
        ("line one\nline two", "line one\nline two\n"),
        ("hard  \nbreak", "hard\nbreak\n"),
        ("backslash\\\nbreak", "backslash\nbreak\n"),
        // A thematic break is a line of 40 box-drawing dashes.
        ("above\n\n---\n\nbelow", "above\n\n────────────────────────────────────────\n\nbelow\n"),
        // Bullets nest with the text column of the parent and change glyph after the first level.
        ("- one\n  - two\n    - three\n- four", "• one\n  ◦ two\n    ◦ three\n• four\n"),
        // A bullet list under a numbered item aligns with the text after the number.
        ("3. first\n4. second\n   - nested", "3. first\n4. second\n   ◦ nested\n"),
        // Numbered lists count from the start index of the list.
        ("1. a\n2. b\n3. c", "1. a\n2. b\n3. c\n"),
        ("7. a\n1. b\n1. c", "7. a\n8. b\n9. c\n"),
        ("0. zero\n1. one", "0. zero\n1. one\n"),
        // Items sit on consecutive lines and their paragraphs are separated by a blank line.
        ("- first\n\n  second paragraph\n- next\n\nOutside", "• first\n\n  second paragraph\n• next\n\nOutside\n"),
        // Continuation lines align with the text after the number, whatever its width.
        (
            "9. nine\n10. ten\n    line two\\\n    hard break\n\n    second paragraph",
            "9. nine\n10. ten\n    line two\n    hard break\n\n    second paragraph\n"
        ),
        // A task box replaces the bullet of a bulleted item and follows the number of a numbered one.
        ("- [x] done\n- [ ] to do\n  - nested\n- plain", "[x] done\n[ ] to do\n    ◦ nested\n• plain\n"),
        ("1. [x] done\n2. [ ] to do", "1. [x] done\n2. [ ] to do\n"),
        // A link reads text and url, and just one of them when the other adds nothing.
        ("[docs](https://example.com/docs)", "docs (https://example.com/docs)\n"),
        ("<https://example.com>", "https://example.com\n"),
        ("[https://example.com](https://example.com)", "https://example.com\n"),
        ("[**bold** link](https://example.com)", "bold link (https://example.com)\n"),
        ("[](https://example.com)", "https://example.com\n"),
        ("[only text]()", "only text\n"),
        // A mailto link whose text is the address is just the address.
        ("<user@example.com>", "user@example.com\n"),
        ("[user@example.com](mailto:user@example.com)", "user@example.com\n"),
        ("[write me](mailto:user@example.com)", "write me (mailto:user@example.com)\n"),
        // An image reads alt text and url, or just the url without alt text.
        ("![logo](https://example.com/logo.png)", "logo (https://example.com/logo.png)\n"),
        ("![](https://example.com/logo.png)", "https://example.com/logo.png\n"),
        ("![just alt]()", "just alt\n"),
        // Code keeps its content, indented by four spaces, with no fences and no trailing spaces.
        (
            "Before\n\n```swift\nlet x = 1\n\nprint(x)\u{20}\u{20}\u{20}\n```\n\nAfter",
            "Before\n\n    let x = 1\n\n    print(x)\n\nAfter\n"
        ),
        // Code inside a list item is indented relative to the item.
        ("- run:\n\n  ```\n  make\n\n  make test\n  ```", "• run:\n\n      make\n\n      make test\n"),
        // Every line of a quote starts with a bar, blank lines get just the bar.
        ("> quote\n\n> first\n>\n> second\n>\n> > nested", "│ quote\n\n│ first\n│\n│ second\n│\n│ │ nested\n"),
        // Each body row becomes a block of Header: value lines, empty cells and rows left out.
        (
            "| Task | Owner | Due |\n| --- | :---: | ---: |\n| Write docs | Ann | Friday |\n"
                + "| Fix bug | | Monday |\n|  |  |  |\n| Ship | Bob | |",
            "Task: Write docs\nOwner: Ann\nDue: Friday\n\nTask: Fix bug\nDue: Monday\n\nTask: Ship\nOwner: Bob\n"
        ),
        // A column without a header shows just the value.
        ("| | Status |\n| --- | --- |\n| Deploy | ok |", "Deploy\nStatus: ok\n"),
        // A table without body rows is its headers on one line.
        ("| Name | Owner | Due |\n| --- | --- | --- |", "Name · Owner · Due\n"),
        // A cell is rendered like inline text on a single line.
        (
            "| Item | Notes |\n| --- | --- |\n| **bold** | one<br>two<br/>three and [site](https://example.com) |",
            "Item: bold\nNotes: one two three and site (https://example.com)\n"
        ),
        // A table sits between its neighbours like any other block.
        ("Before\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter", "Before\n\nA: 1\nB: 2\n\nAfter\n"),
        // br tags are line breaks in any case and spelling.
        ("a<br>b<BR/>c<br />d<Br>e", "a\nb\nc\nd\ne\n"),
        // Any other raw HTML stays literal.
        ("x <span>y</span> z", "x <span>y</span> z\n"),
        ("<div>hello *there*</div>", "<div>hello *there*</div>\n"),
        ("a <br class=\"x\"> b", "a <br class=\"x\"> b\n")
    ]

    @Test("each Markdown construct reads as plain text", arguments: ZenCronMailPlainTextTests.renderings)
    func rendersEachMarkdownConstructAsPlainText(_ markdown: String, _ plainText: String) {
        #expect(render(markdown) == plainText)
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
