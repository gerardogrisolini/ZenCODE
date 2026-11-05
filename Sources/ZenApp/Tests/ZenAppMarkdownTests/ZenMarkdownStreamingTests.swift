//
//  ZenMarkdownStreamingTests.swift
//  ZenApp
//
//  The incremental parse of streaming Markdown equals a full parse for every
//  prefix, parses only the tail, and keeps the highlighting of the blocks
//  that no longer change.
//

import Foundation
import Testing

@testable import ZenAppMarkdown

/// A document with every construct whose extent a blank line does not end,
/// or that a later line could join to an earlier one.
private let mixedDocument = """
# Streaming title

A paragraph with **bold**, *emphasis*, `code` and a [link](https://example.com).
It continues on a second line.

- first item
- second item

- loose item after a blank line
  continued inside the item

  second paragraph of the item
1. ordered after bullets

2. second ordered

10) other delimiter
* star bullet

+ plus bullet

> a quote
> on two lines

> a second quote
lazy continuation

```swift
let a = 1

let b = 2
```

~~~
tilde fence

~~~

- item with a fence
  ```
  inside the item

  still inside
```
the column-0 fence above closed the item and opened this block

still in that block
```

| a | b |
|:--|--:|
| 1 | 2 |

| x |
|---|
| y |
no pipes row

<!-- a comment

with a blank line -->

<div>
html block
</div>

    indented code

    more indented code

Setext heading
==============

Another setext
---

***
- - -

```ts
interface A { [key: string]: number }
```

- [x] done task

- [ ] open task

Final paragraph without a newline
"""

/// Streams `document` one character at a time, like the transcript does with
/// tokens, and checks every version against a full parse.
///
/// - Returns: The UTF-8 length parsed for each version.
@discardableResult
private func expectStreamsLikeAFullParse(_ document: String) -> [Int] {
    var anchor: ZenMarkdownStreamAnchor?
    var prefix = ""
    var parsedLengths: [Int] = []
    for character in document {
        prefix.append(character)
        let result = ZenMarkdownStreamingParser.parse(prefix, reusing: anchor)
        #expect(result.blocks == ZenMarkdownParser.blocks(from: prefix), "\(prefix.debugDescription)")
        parsedLengths.append(result.parsedLength)
        if let next = result.anchor {
            if next.length > 0, next.length != anchor?.length {
                // The anchor's blocks are those of a full parse of its prefix.
                #expect(ZenMarkdownParser.blocks(from: next.prefix) == next.blocks, "\(next.prefix.debugDescription)")
                #expect(next.prefix.hasSuffix("\n"))
            }
            anchor = next
        }
    }
    return parsedLengths
}

@Suite("ZenMarkdownStreamingParser")
struct ZenMarkdownStreamingParserTests {
    @Test("every prefix of a mixed document parses like a full parse")
    func mixedDocumentPrefixes() {
        let parsedLengths = expectStreamsLikeAFullParse(mixedDocument)
        // Only the tail is parsed: at most the longest run of blocks without
        // a split point (the lists), never the whole text.
        #expect(parsedLengths.max() ?? 0 < mixedDocument.utf8.count / 2)
        let fullParses = parsedLengths.indices.reduce(0) { $0 + $1 + 1 }
        #expect(parsedLengths.reduce(0, +) < fullParses / 2)
        // At the end the tail is the fenced block and the last paragraph.
        #expect(parsedLengths.last ?? .max < 160)
    }

    @Test("blank lines inside lists, fences and comments are not split points")
    func constructsSpanningBlankLines() {
        expectStreamsLikeAFullParse("- a\n\n- b\n\n- c\n\nafter\n")
        expectStreamsLikeAFullParse("1. a\n\n2. b\n\n3) c\n\nafter\n")
        expectStreamsLikeAFullParse("- a\n  ```\n  code\n\n```\nmore\n\nx\n\ny\n")
        expectStreamsLikeAFullParse("```\none\n\ntwo\n\n```\n\nafter\n\nend\n")
        expectStreamsLikeAFullParse("<!--\n\nhidden\n\n-->\n\nvisible\n\nend\n")
        expectStreamsLikeAFullParse("<pre>\n\nraw\n\n</pre>\n\nafter\n\nend\n")
        expectStreamsLikeAFullParse("    code\n\n    more\n\ntext\n\nend\n")
        expectStreamsLikeAFullParse("> a\n\n> b\n\nc\n\nd\n")
        expectStreamsLikeAFullParse("para\n\n- - -\n\n* * *\n\n---\n\nend\n")
    }

    @Test("link reference definitions fall back to whole-document parses")
    func referenceDefinitions() {
        expectStreamsLikeAFullParse("""
        See [the docs][docs] and [docs].

        ```
        [x]: inside code
        ```
        [docs]: https://example.com/docs

        Trailing [docs] text.

        > [q]: /quote

        A [q] link.
        """)
        // `]:` inside code does not disable the incremental parse.
        let code = "```ts\nlet a: { [k: string]: number }\n```\n\nafter\n\nend\n"
        let result = ZenMarkdownStreamingParser.parse(code, reusing: nil)
        #expect(result.anchor?.length ?? 0 > 0)
        #expect(result.blocks == ZenMarkdownParser.blocks(from: code))
        // Outside code it does.
        let definition = "[a]: /url\n\npara\n\nend\n"
        #expect(ZenMarkdownStreamingParser.parse(definition, reusing: nil).anchor == nil)
        // Right after an indented code block, whose range ends on the next
        // line, the definition is still seen.
        let afterIndented = "    code\n[a]: /url\n\nx\n\n[a]\n"
        #expect(ZenMarkdownStreamingParser.parse(afterIndented, reusing: nil).anchor == nil)
        expectStreamsLikeAFullParse(afterIndented)
    }

    @Test("CRLF line endings and Unicode text stream correctly")
    func lineEndingsAndUnicode() {
        expectStreamsLikeAFullParse("a\r\n\r\nb\r\n\r\n- c\r\n\r\nd\r\n")
        expectStreamsLikeAFullParse("Café ☕️ 東京\n\n- élan\n\nZoë 👩‍👩‍👧\n\n```\n✓\n\n✗\n```\n\ne\u{301}\n\nend\n")
    }

    @Test("a long document parses only its last block")
    func longDocumentParsesTheTail() {
        let paragraphs = (1...200).map { "Paragraph \($0) with **bold** text." }
        let document = paragraphs.joined(separator: "\n\n") + "\n\nlast"
        var anchor: ZenMarkdownStreamAnchor?
        var prefix = ""
        var result: ZenMarkdownStreamingParser.Result?
        for character in document {
            prefix.append(character)
            let next = ZenMarkdownStreamingParser.parse(prefix, reusing: anchor)
            anchor = next.anchor ?? anchor
            result = next
        }
        #expect(result?.blocks == ZenMarkdownParser.blocks(from: document))
        #expect(result?.blocks.count == 201)
        // The tail is the last two paragraphs, not the whole document.
        #expect(result?.parsedLength ?? .max < 60)
    }

    @Test("an anchor that is not a prefix of the text is ignored")
    func foreignAnchor() {
        let first = ZenMarkdownStreamingParser.parse("alpha\n\nbeta\n\ngamma\n", reusing: nil)
        let anchor = first.anchor
        #expect(anchor?.prefix == "alpha\n\nbeta\n\n")
        let other = "alpha\n\nBETA\n\ngamma"
        let result = ZenMarkdownStreamingParser.parse(other, reusing: anchor)
        #expect(result.blocks == ZenMarkdownParser.blocks(from: other))
        #expect(result.parsedLength == other.utf8.count)
    }

    @Test("list markers are recognized like CommonMark")
    func listMarkers() {
        func isMarker(_ line: String) -> Bool {
            ZenMarkdownStreamingParser.TailScan.isListMarker(ArraySlice(Array(line.utf8)))
        }
        for line in ["-", "- a", "+\tb", "* c", "1.", "1. a", "123) b", "123456789. c"] {
            #expect(isMarker(line), "\(line)")
        }
        for line in ["-a", "**bold**", "1234567890. long", "1.a", "a. b", "2024 was", "#", "> q", ""] {
            #expect(!isMarker(line), "\(line)")
        }
    }
}

@Suite("ZenMarkdownStreamAnchors")
struct ZenMarkdownStreamAnchorsTests {
    private func anchor(_ text: String, length: Int) -> ZenMarkdownStreamAnchor {
        ZenMarkdownStreamAnchor(source: text, length: length, blocks: [])
    }

    @Test("the longest matching anchor wins and replaces the anchors it grew from")
    func bestAnchor() {
        let store = ZenMarkdownStreamAnchors(capacity: 4)
        store.record(anchor("one\n\ntwo\n\nthree", length: 5))
        store.record(anchor("other\n\nstream", length: 7))
        #expect(store.bestAnchor(for: "one\n\ntwo\n\nthree and more")?.length == 5)

        store.record(anchor("one\n\ntwo\n\nthree", length: 10))
        #expect(store.count == 2)
        #expect(store.bestAnchor(for: "one\n\ntwo\n\nthree and more")?.length == 10)
        #expect(store.bestAnchor(for: "other\n\nstream!")?.length == 7)
        #expect(store.bestAnchor(for: "unrelated") == nil)
        #expect(store.bestAnchor(for: "one") == nil)

        store.removeAnchors(within: "one\n\ntwo\n\nthree, done")
        #expect(store.count == 1)
        #expect(store.bestAnchor(for: "one\n\ntwo\n\nthree and more") == nil)
    }

    @Test("the store is bounded")
    func bounded() {
        let store = ZenMarkdownStreamAnchors(capacity: 2)
        for name in ["a", "b", "c"] {
            store.record(anchor("\(name)\n\nrest", length: 3))
        }
        #expect(store.count == 2)
        #expect(store.bestAnchor(for: "a\n\nrest") == nil)
        #expect(store.bestAnchor(for: "c\n\nrest")?.length == 3)
    }

    @Test("the cached streaming parse equals a full parse for every prefix")
    func cachedStreaming() {
        var prefix = ""
        for character in mixedDocument {
            prefix.append(character)
            #expect(ZenMarkdownParser.cachedBlocks(from: prefix, isStreaming: true) == ZenMarkdownParser.blocks(from: prefix))
        }
        #expect(ZenMarkdownParser.cachedBlocks(from: mixedDocument, isStreaming: false) == ZenMarkdownParser.blocks(from: mixedDocument))
    }
}

@Suite("ZenMarkdownCodePresentation caching")
struct ZenMarkdownCodePresentationCachingTests {
    @Test("only the last block of a streaming view is open")
    func openBlock() {
        #expect(ZenMarkdownView.isOpenBlock(at: 2, count: 3, isStreaming: true))
        #expect(!ZenMarkdownView.isOpenBlock(at: 1, count: 3, isStreaming: true))
        #expect(!ZenMarkdownView.isOpenBlock(at: 2, count: 3, isStreaming: false))
    }

    @Test("a completed block keeps its highlighting while the last block grows")
    func completedBlocksStayCached() {
        let stable = "let stable\(UUID().uuidString.prefix(8)) = 1"
        let first = ZenMarkdownCodePresentation.make(
            language: "swift",
            code: stable,
            isStreaming: ZenMarkdownView.isOpenBlock(at: 0, count: 2, isStreaming: true)
        )
        // The growing last block churns through many versions.
        var growing = "let growing\(UUID().uuidString.prefix(8)) = ["
        for index in 0..<64 {
            growing += "\(index), "
            _ = ZenMarkdownCodePresentation.make(language: "swift", code: growing, isStreaming: true)
        }
        #expect(ZenMarkdownCodePresentation.cachedPresentation(language: "swift", code: stable) == first)
        // The open block's versions never reach the cache of completed blocks.
        #expect(ZenMarkdownCodePresentation.cachedPresentation(language: "swift", code: growing) == nil)
        #expect(ZenMarkdownCodePresentation.cachedPresentation(language: "swift", code: growing, isStreaming: true) != nil)
    }
}
