import Foundation
@testable import WebToolsFeature
import Testing

extension WebHTMLNode {
    /// Raw text of a text node, `nil` for every other kind.
    var text: String? {
        if case .text(let value) = kind {
            return value
        }
        return nil
    }
}

/// Shared helpers for the platform-independent HTML pipeline tests.
enum ContentFixture {
    static let pageURL = URL(string: "https://example.com/docs/page.html")!

    /// A sentence repeated to clear the main-content length threshold.
    static func longText(_ word: String, count: Int = 12) -> String {
        Array(repeating: "\(word) lorem ipsum dolor sit amet.", count: count).joined(separator: " ")
    }

    static func convert(
        _ html: String,
        _ configure: (inout WebMarkdownOptions) -> Void = { _ in }
    ) throws -> WebMarkdownConversion {
        var options = WebMarkdownOptions()
        options.baseURL = pageURL
        configure(&options)
        return try WebMarkdownConverter.convert(html: html, options: options)
    }

    static func markdown(_ html: String, _ configure: (inout WebMarkdownOptions) -> Void = { _ in }) throws -> String {
        try convert(html, configure).content
    }

    static func text(_ html: String) throws -> String {
        try convert(html) { $0.format = .text }.content
    }

    static func elements(_ name: String, in root: WebHTMLNode) -> [WebHTMLNode] {
        root.descendants.filter { $0.tagName == name }
    }

    static func childTags(_ node: WebHTMLNode) -> [String] {
        node.children.compactMap(\.tagName)
    }

    /// Maximum depth of the tree, computed iteratively.
    static func maximumDepth(_ root: WebHTMLNode) -> Int {
        var deepest = 0
        var stack: [(WebHTMLNode, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            deepest = max(deepest, depth)
            for child in node.children {
                stack.append((child, depth + 1))
            }
        }
        return deepest
    }
}

/// Namespace suite so `swift test --filter WebContentConversion` selects every
/// parser, selector, converter and performance test below.
@Suite
enum WebContentConversionTests {}

extension WebContentConversionTests {
    @Suite
    struct WebHTMLParserTests {
        @Test
        func voidAndForeignSelfClosingElementsTakeNoChildren() throws {
            let document = WebHTMLParser.parse("<p>a<br>b<img src=x.png><input/>c<hr>e")
            let paragraph = try #require(ContentFixture.elements("p", in: document).first)

            #expect(ContentFixture.childTags(paragraph) == ["br", "img", "input"])
            #expect(paragraph.children.compactMap(\.text) == ["a", "b", "c"])
            for child in paragraph.children where child.isElement {
                #expect(child.children.isEmpty)
            }
            // <hr> is a block: it closes the open paragraph and becomes a sibling.
            #expect(ContentFixture.childTags(document) == ["p", "hr"])
            #expect(document.children.last?.text == "e")

            // Inside svg/math, `/>` closes the element.
            let svg = WebHTMLParser.parse("<svg><path d=x /><circle/></svg>")
            let root = try #require(ContentFixture.elements("svg", in: svg).first)
            #expect(ContentFixture.childTags(root) == ["path", "circle"])
            #expect(ContentFixture.elements("path", in: svg).allSatisfy { $0.children.isEmpty })
        }

        @Test
        func selfClosingSyntaxIsIgnoredOnHTMLElements() throws {
            // An unquoted value runs up to the whitespace or `>`, so `/` belongs to it.
            let link = try ContentFixture.markdown("<p><a href=x/>Text</a></p>")
            #expect(link == "[Text](https://example.com/docs/x/)")

            let spaced = try ContentFixture.markdown("<p><a href=x />Text</a></p>")
            #expect(spaced == "[Text](https://example.com/docs/x)")

            // <div/> opens a normal div: what follows is its content.
            let document = WebHTMLParser.parse("<div/>inside<span/>more")
            let div = try #require(ContentFixture.elements("div", in: document).first)
            #expect(div.children.first?.text == "inside")
            #expect(ContentFixture.childTags(div) == ["span"])
            let span = try #require(ContentFixture.elements("span", in: document).first)
            #expect(span.children.first?.text == "more")
        }

        @Test
        func impliedEndTagsCloseParagraphsItemsAndCells() throws {
            let document = WebHTMLParser.parse(
                "<p>one<p>two<div>three</div><ul><li>a<li>b</ul><dl><dt>t<dd>d<dt>t2</dl>"
                    + "<table><tr><td>1<td>2<tr><td>3</table><select><option>x<option>y</select>"
                    + "<h1>h<h2>i<a href=1>first<a href=2>second"
            )

            #expect(ContentFixture.childTags(document) == ["p", "p", "div", "ul", "dl", "table", "select", "h1", "h2"])
            let list = try #require(ContentFixture.elements("ul", in: document).first)
            #expect(ContentFixture.childTags(list) == ["li", "li"])
            let definitions = try #require(ContentFixture.elements("dl", in: document).first)
            #expect(ContentFixture.childTags(definitions) == ["dt", "dd", "dt"])
            let table = try #require(ContentFixture.elements("table", in: document).first)
            #expect(ContentFixture.childTags(table) == ["tr", "tr"])
            #expect(table.children.map { ContentFixture.childTags($0).count } == [2, 1])
            let select = try #require(ContentFixture.elements("select", in: document).first)
            #expect(ContentFixture.childTags(select) == ["option", "option"])
            let heading = try #require(ContentFixture.elements("h2", in: document).first)
            #expect(ContentFixture.childTags(heading) == ["a", "a"])
        }

        @Test
        func nestedListItemsDoNotCloseTheirParentItem() throws {
            let document = WebHTMLParser.parse("<ul><li>a<ul><li>b</ul><li>c</ul>")
            let outer = try #require(ContentFixture.elements("ul", in: document).first)

            #expect(ContentFixture.childTags(outer) == ["li", "li"])
            let first = try #require(outer.children.first)
            #expect(ContentFixture.childTags(first) == ["ul"])
            #expect(first.textContent == "ab")
        }

        @Test
        func rawTextElementsAreNotParsed() throws {
            let script = "if (a < b && c > d) { document.write('<p>x</p>') }"
            let document = WebHTMLParser.parse(
                "<script>\(script)</SCRIPT ><style>p > a { color: red }</style>"
                    + "<textarea><b>not bold</b></textarea><script>a</scripty>b</script><p>after</p>"
            )

            let scripts = ContentFixture.elements("script", in: document)
            #expect(scripts.count == 2)
            #expect(scripts.first?.children.count == 1)
            #expect(scripts.first?.children.first?.text == script)
            #expect(scripts.last?.textContent == "a</scripty>b")
            #expect(ContentFixture.elements("style", in: document).first?.textContent == "p > a { color: red }")
            #expect(ContentFixture.elements("textarea", in: document).first?.textContent == "<b>not bold</b>")
            #expect(ContentFixture.elements("b", in: document).isEmpty)
            #expect(ContentFixture.elements("p", in: document).count == 1)
        }

        @Test
        func attributesAreLowercasedDecodedAndFirstOccurrenceWins() throws {
            let document = WebHTMLParser.parse(
                "<a HREF=/path?a=1&amp;b=2 data-x = 'single' checked TITLE=\"q &quot;x&quot;\" data-x=dup "
                    + "class=' one  two ' id=main>t</a>"
            )
            let anchor = try #require(ContentFixture.elements("a", in: document).first)

            #expect(anchor.attributes["href"] == "/path?a=1&b=2")
            #expect(anchor.attributes["data-x"] == "single")
            #expect(anchor.attributes["checked"] == "")
            #expect(anchor.attributes["title"] == "q \"x\"")
            #expect(anchor.classList == ["one", "two"])
            #expect(anchor.attributes["id"] == "main")
            #expect(anchor.tagName == "a")
        }

        @Test
        func tagNamesAreCaseInsensitive() throws {
            let document = WebHTMLParser.parse("<DIV Class=x><P>text</p></Div>after")

            let div = try #require(ContentFixture.elements("div", in: document).first)
            #expect(div.attributes["class"] == "x")
            #expect(ContentFixture.childTags(div) == ["p"])
            #expect(document.children.last?.text == "after")
        }

        @Test
        func unclosedTagsNestUntilTheEnd() throws {
            let document = WebHTMLParser.parse("<div><p>open <b>bold <i>both")
            let italic = try #require(ContentFixture.elements("i", in: document).first)

            #expect(italic.textContent == "both")
            #expect(italic.parent?.tagName == "b")
            #expect(italic.parent?.parent?.tagName == "p")
            #expect(italic.parent?.parent?.parent?.tagName == "div")

            let implicit = WebHTMLParser.parse("<div><span>a</div>b")
            #expect(ContentFixture.childTags(implicit) == ["div"])
            #expect(implicit.children.last?.text == "b")
        }

        @Test
        func unmatchedEndTagsAreIgnoredAndScoped() throws {
            let document = WebHTMLParser.parse("<div>a</span>b</p>c</div>d")
            let div = try #require(ContentFixture.elements("div", in: document).first)
            #expect(div.textContent == "abc")
            #expect(document.children.last?.text == "d")

            // A stray </div> inside a cell cannot close a div outside the table.
            let table = WebHTMLParser.parse("<div><table><tr><td>a</div>b</td></tr></table>c</div>")
            let cell = try #require(ContentFixture.elements("td", in: table).first)
            #expect(cell.textContent == "ab")
            let outer = try #require(ContentFixture.elements("div", in: table).first)
            #expect(outer.children.last?.text == "c")
        }

        @Test
        func commentsDoctypeCDATAAndProcessingInstructions() throws {
            let html = "<!DOCTYPE html><?xml version='1.0'?><!-- a comment --><p>x<!-- inner -->y"
                + "<![CDATA[ 1 < 2 &amp; 3 ]]>z</p><!--unterminated <p>never"
            let document = WebHTMLParser.parse(html)

            #expect(document.children.map(\.kind) == [.comment, .element("p"), .comment])
            let paragraph = try #require(ContentFixture.elements("p", in: document).first)
            #expect(paragraph.children.filter { $0.kind == .comment }.count == 1)
            #expect(try ContentFixture.markdown(html) == "xy 1 < 2 &amp; 3 z")
        }

        @Test
        func headContentIsSeparatedFromBody() throws {
            let document = WebHTMLParser.parse(
                "<html><head><title>T</title><p>Body text</p></head><body class=b>more</body></html>"
            )

            let paragraph = try #require(ContentFixture.elements("p", in: document).first)
            #expect(paragraph.parent?.tagName == "body")
            let bodies = ContentFixture.elements("body", in: document)
            #expect(bodies.count == 1)
            #expect(bodies.first?.attributes["class"] == "b")
            #expect(try ContentFixture.markdown(
                "<html><head><title>T</title></head><p>Body text</p><body>more</body></html>"
            ) == "Body text\n\nmore")
        }

        @Test
        func junkInputNeverCrashes() throws {
            let junk = [
                "", "<", "</", "<<<>>>", "<!", "<!--", "<!-->", "<!--->", "<a href=\"unterminated", "<a b='c",
                "</>", "</ p>", "<?", "<![CDATA[x", "<a <b <c>", "&", "&#", "&#x;", "&#99999999999;", "&#0;",
                "\u{0}\u{FFFF}<p>\u{0}", "<p =x ==y>t", "<table><td><tr><th></caption></table></td>",
                "</div></div></body></html><p>tail", "<li></ul></li><dd><dt></dl>", "<svg><path/></svg>",
            ]
            for html in junk {
                _ = WebHTMLParser.parse(html)
                _ = try WebMarkdownConverter.convert(html: html)
            }

            // Deterministic pseudo-random markup soup.
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            let alphabet = Array("<>/!-=\"' &#;abcdpliultr\n\t?[]".utf8)
            for _ in 0..<50 {
                var bytes: [UInt8] = []
                for _ in 0..<2_000 {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    bytes.append(alphabet[Int(state >> 33) % alphabet.count])
                }
                let html = String(decoding: bytes, as: UTF8.self)
                _ = WebHTMLParser.parse(html)
                _ = try WebMarkdownConverter.convert(html: html)
            }
            #expect(try ContentFixture.markdown("a < b and c <= d") == "a < b and c <= d")
        }

        @Test
        func deepNestingIsCappedAndDoesNotCrash() throws {
            let html = String(repeating: "<div>", count: 50_000) + "deep text" + String(repeating: "</div>", count: 50_000)
            let document = WebHTMLParser.parse(html)

            #expect(ContentFixture.maximumDepth(document) <= WebHTMLParser.maximumTreeDepth + 1)
            #expect(document.textContent == "deep text")
            #expect(try WebMarkdownConverter.convert(html: html).content == "deep text")

            let lists = String(repeating: "<ul><li><blockquote>", count: 5_000) + "leaf"
            let converted = try WebMarkdownConverter.convert(html: lists).content
            #expect(converted.hasSuffix("leaf"))
        }

        @Test
        func inputIsTruncatedAtTheByteLimit() throws {
            let document = WebHTMLParser.parse("<p>abcdef</p>", maxInputBytes: 6)
            #expect(document.textContent == "abc")
            // Truncating inside a multi-byte scalar must not crash.
            _ = WebHTMLParser.parse("<p>\u{00E9}\u{1F600}</p>", maxInputBytes: 5)
            #expect(WebHTMLParser.defaultMaxInputBytes == 8 * 1024 * 1024)
        }

        @Test
        func descendantsAreInDocumentOrder() {
            let document = WebHTMLParser.parse("<div><p>a<b>b</b></p><span>c</span></div>")
            #expect(document.descendants.compactMap(\.tagName) == ["div", "p", "b", "span"])
            #expect(document.descendants.compactMap(\.text) == ["a", "b", "c"])
        }

        @Test
        func entityDecoderHandlesNamedNumericAndInvalidReferences() {
            #expect(WebHTMLEntities.decode("&amp;lt; &lt; &#169; &#xA9; &#x1F600; &eacute; &hellip; &rarr;")
                == "&lt; < \u{00A9} \u{00A9} \u{1F600} \u{00E9} \u{2026} \u{2192}")
            #expect(WebHTMLEntities.decode("&bogus; &amp &#; &#0; &#150; a&b") == "&bogus; &amp &#; \u{FFFD} \u{2013} a&b")
            #expect(WebHTMLEntities.decode("&#65") == "A")
        }
    }
}

extension WebContentConversionTests {
    @Suite
    struct WebCSSSelectorTests {
        private static let html = """
        <div id="root" class="page wide">
          <header><a href="/home" class="nav-link">Home</a></header>
          <article class="post featured" data-kind="news-item">
            <h2 class="title">First</h2>
            <p>Intro <a href="https://example.com/a" rel="external nofollow" lang="en-US">A</a></p>
            <div class="post"><p class="note">Nested</p></div>
          </article>
          <article class="post" data-kind="opinion"><h2 class="title">Second</h2></article>
          <SECTION><p>Upper</p></SECTION>
        </div>
        """

        private func select(_ selector: String) throws -> [WebHTMLNode] {
            try WebCSSSelector.select(selector, in: WebHTMLParser.parse(Self.html))
        }

        private func texts(_ selector: String) throws -> [String] {
            try select(selector).map { WebMarkdownRenderer.visibleText(of: $0) }
        }

        @Test
        func typeUniversalIdAndClassSelectors() throws {
            #expect(try texts("h2") == ["First", "Second"])
            #expect(try texts("H2") == ["First", "Second"])
            #expect(try texts("section") == ["Upper"])
            #expect(try select("#root").count == 1)
            #expect(try texts(".title") == ["First", "Second"])
            #expect(try texts("p.note") == ["Nested"])
            #expect(try select("div#root.page.wide").count == 1)
            #expect(try select("div#root.missing").isEmpty)
            // `*` matches the outermost element; descendants are not repeated.
            #expect(try select("*").map { $0.attributes["id"] } == ["root"])
        }

        @Test
        func attributeSelectors() throws {
            #expect(try texts("[data-kind]").count == 2)
            #expect(try texts("[data-kind=opinion]") == ["Second"])
            #expect(try texts("[data-kind=\"opinion\"]") == ["Second"])
            #expect(try texts("a[href^='https://']") == ["A"])
            #expect(try texts("a[href$=home]") == ["Home"])
            #expect(try texts("[data-kind*='ws-it']").count == 1)
            #expect(try texts("a[rel~=nofollow]") == ["A"])
            #expect(try texts("a[lang|=en]") == ["A"])
            #expect(try select("a[href^='']").isEmpty)
            #expect(try select("[HREF='/home']").count == 1)
        }

        @Test
        func combinatorsAndGroups() throws {
            #expect(try texts("article p") == ["Intro A", "Nested"])
            #expect(try texts("article > p") == ["Intro A"])
            #expect(try texts("div > article > h2") == ["First", "Second"])
            #expect(try texts("#root   header>a") == ["Home"])
            #expect(try texts("header a, h2.title") == ["Home", "First", "Second"])
        }

        @Test
        func resultsAreInDocumentOrderWithoutNestedDuplicates() throws {
            let posts = try select(".post")
            #expect(posts.count == 2)
            #expect(posts.map { $0.attributes["data-kind"] } == ["news-item", "opinion"])
            // `div` matches #root first, so the nested div.post is not repeated.
            #expect(try select("div").count == 1)
        }

        @Test
        func unsupportedSyntaxIsRejected() throws {
            for selector in ["", " ", ",", "div,", "a:hover", "p::before", "a + b", "a ~ b", "[x", "[x=]", "a|b", "#", ".", "a >", "[x=y i]"] {
                #expect(WebCSSSelector(selector) == nil, "\(selector) should be rejected")
                #expect(throws: WebContentError.invalidSelector(selector)) {
                    try WebCSSSelector.select(selector, in: WebHTMLParser.parse("<p>x</p>"))
                }
            }
            #expect(WebCSSSelector("div.a > p, [data-x='1']")?.groups.count == 2)
        }
    }
}

extension WebContentConversionTests {
    @Suite
    struct WebConverterPerformanceTests {
        /// ~1 MB of deliberately malformed markup: unclosed inline and block
        /// tags, implied list items and cells, comments, scripts and entities.
        private static func malformedDocument(minimumBytes: Int) -> String {
            var parts: [String] = []
            var size = 0
            var index = 0
            while size < minimumBytes {
                let chunk: String
                switch index % 5 {
                case 0:
                    chunk = "<p>Paragraph \(index) with <b>bold <i>italic</b> text &amp; entities &copy; <a href='/p/\(index)'>link \(index)</a>\n"
                case 1:
                    chunk = "<ul><li>item \(index)<ul><li>nested <li>more<ol><li>deep</ul></ul>\n"
                case 2:
                    chunk = "<table><tr><td>cell \(index)<td>other<tr><th>head</table>\n"
                case 3:
                    chunk = "<div><span>unclosed <em>stuff <div>inner \(index) <p>para</div>\n"
                default:
                    chunk = "<pre>code &lt;\(index)&gt;\n  more</pre><blockquote>quote <br> line</blockquote>"
                        + "<!-- comment --><script>var x = '<p>';</script>\n"
                }
                parts.append(chunk)
                size += chunk.utf8.count
                index += 1
            }
            return "<html><head><title>Big</title></head><body>" + parts.joined()
        }

        @Test
        func oneMegabyteMalformedDocumentConvertsQuickly() throws {
            let html = Self.malformedDocument(minimumBytes: 1_000_000)
            #expect(html.utf8.count >= 1_000_000)

            var result: WebMarkdownConversion?
            let elapsed = try ContinuousClock().measure {
                result = try WebMarkdownConverter.convert(html: html, options: .init(baseURL: URL(string: "https://example.com/")))
            }
            let conversion = try #require(result)

            // Wall-clock bound with headroom for contended CI runners (~0.5 s idle in
            // debug); quadratic behaviour on 1 MB would still exceed it by far.
            #expect(elapsed < .seconds(10), "parse + convert took \(elapsed)")
            #expect(conversion.title == "Big")
            #expect(conversion.content.count > 100_000)
            #expect(conversion.links.count == 80)
            #expect(!conversion.content.contains("\n\n\n"))
            #expect(!conversion.content.contains("var x"))
        }

        @Test
        func preformattedBlockWithHalfAMillionLeadingNewlinesConvertsQuickly() throws {
            let html = "<pre>" + String(repeating: "\n", count: 500_000) + "x"
            var result: String?
            let elapsed = try ContinuousClock().measure {
                result = try ContentFixture.markdown(html)
            }
            let content = try #require(result)

            #expect(elapsed < .seconds(1), "leading blank <pre> lines took \(elapsed)")
            #expect(content.hasPrefix("```\n"))
            #expect(content.contains("x"))
            #expect(content.hasSuffix("\n```"))
        }
    }
}
