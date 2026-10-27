import Foundation
@testable import WebToolsFeature
import Testing

/// Shared helpers for the platform-independent HTML pipeline tests.
private enum ContentFixture {
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
            #expect(anchor.attribute("HREF") == "/path?a=1&b=2")
            #expect(anchor.attributes["data-x"] == "single")
            #expect(anchor.attributes["checked"] == "")
            #expect(anchor.attributes["title"] == "q \"x\"")
            #expect(anchor.classList == ["one", "two"])
            #expect(anchor.id == "main")
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
            #expect(try select("*").map(\.id) == ["root"])
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
    struct WebMarkdownConverterTests {
        @Test
        func headingsParagraphsBreaksAndRules() throws {
            #expect(try ContentFixture.markdown(
                "<h1>One</h1><h2>Two <em>x</em></h2><h3>Three</h3><h4>4</h4><h5>5</h5><h6>\n  Six\n  lines\n</h6>"
            ) == "# One\n\n## Two *x*\n\n### Three\n\n#### 4\n\n##### 5\n\n###### Six lines")

            #expect(try ContentFixture.markdown(
                "<p>First   paragraph\nwith newline</p><div>Div block</div><section><p>Nested</p></section>"
                    + "<p>Line one<br>Line two<br/>Line three</p><hr><p>After</p>"
            ) == "First paragraph with newline\n\nDiv block\n\nNested\n\nLine one\nLine two\nLine three\n\n---\n\nAfter")
        }

        @Test
        func neverMoreThanOneBlankLine() throws {
            #expect(try ContentFixture.markdown(
                "<div><p>a</p><div></div><p> </p><br><br><div><div>b<br><br><br><br>c</div></div></div>"
            ) == "a\n\nb\n\nc")
        }

        @Test
        func inlineFormatting() throws {
            #expect(try ContentFixture.markdown(
                "<p><strong>strong</strong> <b>b</b> <em>em</em> <i>i</i> <code>code</code> <del>del</del> <s>s</s> "
                    + "<strike>strike</strike> <mark>mark</mark> <u>u</u> <span>span</span> x<sup>2</sup> H<sub>2</sub>O "
                    + "long<wbr>word</p>"
            ) == "**strong** **b** *em* *i* `code` ~~del~~ ~~s~~ ~~strike~~ mark u span x2 H2O longword")

            // Whitespace moves outside markers; empty wrappers vanish.
            #expect(try ContentFixture.markdown("<p>a<strong> b </strong>c <em></em>d <b> </b>e <b><b>twice</b></b></p>")
                == "a **b** c d e **twice**")
        }

        @Test
        func inlineCodeFencesAreLengthened() throws {
            #expect(try ContentFixture.markdown("<p>Use <code>a ` b</code> and <code>`x`</code></p>")
                == "Use ``a ` b`` and `` `x` ``")
            #expect(try ContentFixture.markdown("<p><code>if <b>x</b> &lt; 1</code></p>") == "`if x < 1`")
        }

        @Test
        func linksAreResolvedAndFiltered() throws {
            let html = "<p><a href='guide.html'>Guide</a> <a href='/abs'>Abs</a> "
                + "<a href='https://other.org/x?a=1&amp;b=2'>Other</a> <a href='javascript:alert(1)'>JS</a> "
                + "<a href='mailto:me@example.com'>Mail me</a> <a href='https://example.com/e'></a> "
                + "<a href='https://example.com/same'>https://example.com/same</a> <a>no href</a> "
                + "<a href='#top'>Top</a></p>"

            #expect(try ContentFixture.markdown(html)
                == "[Guide](https://example.com/docs/guide.html) [Abs](https://example.com/abs) "
                + "[Other](https://other.org/x?a=1&b=2) JS Mail me <https://example.com/e> "
                + "<https://example.com/same> no href Top")

            let plain = try ContentFixture.convert(html) { $0.includeLinks = false }
            #expect(plain.content == "Guide Abs Other JS Mail me https://example.com/same no href Top")
            #expect(plain.links.isEmpty)
        }

        @Test
        func linksWrappingBlocksAndImages() throws {
            #expect(try ContentFixture.markdown("<a href='/post'><h3>Card title</h3><p>Excerpt</p></a>")
                == "### [Card title](https://example.com/post)\n\n[Excerpt](https://example.com/post)")
            #expect(try ContentFixture.markdown(
                "<p><a href='https://x.org/a'><img src='https://x.org/i.png' alt='logo'></a> "
                    + "<a href='https://x.org/b'><code>code link</code></a> <a href='/c'><b>bold</b> link</a></p>"
            ) == "[![logo](https://x.org/i.png)](https://x.org/a) [`code link`](https://x.org/b) "
                + "[**bold** link](https://example.com/c)")
        }

        @Test
        func listsNestAndNumber() throws {
            #expect(try ContentFixture.markdown(
                "<ul><li>One</li><li>Two<ul><li>Two A</li><li>Two B<ol><li>Deep</li></ol></li></ul></li>"
                    + "<li>  Three  </li></ul><ol start='7'><li>Seven</li><li>Eight</li></ol>"
                    + "<ol><li><p>Para one</p><p>Para two</p></li><li>Next</li></ol>"
            ) == """
            - One
            - Two
              - Two A
              - Two B
                1. Deep
            - Three

            7. Seven
            8. Eight

            1. Para one

               Para two
            2. Next
            """)

            // Malformed: a list directly inside a list, unclosed items, orphans.
            #expect(try ContentFixture.markdown("<ul><li>a</li><ul><li>inner</li></ul><li>b<li>c</ul>")
                == "- a\n  - inner\n- b\n- c")
            #expect(try ContentFixture.markdown("<li>orphan one<li>orphan two") == "- orphan one\n- orphan two")
            #expect(try ContentFixture.markdown("<ul><li><pre>code\n  line</pre></li><li>x<blockquote>q</blockquote></li></ul>")
                == "- ```\n  code\n    line\n  ```\n- x\n\n  > q")
        }

        @Test
        func preformattedBlocksAreFencedVerbatim() throws {
            #expect(try ContentFixture.markdown("<pre class='lang-python'>\ndef f():\n    return 1 &lt; 2\n</pre>")
                == "```python\ndef f():\n    return 1 < 2\n```")
            #expect(try ContentFixture.markdown("<pre><code class='language-swift'>let x = \"&amp;lt;\"\n\tindented</code></pre>")
                == "```swift\nlet x = \"&lt;\"\n\tindented\n```")
            #expect(try ContentFixture.markdown("<pre><span class=k>if</span>  <b>x</b><br>y</pre>")
                == "```\nif  x\ny\n```")
        }

        @Test
        func fencesAreLengthenedAroundBackticks() throws {
            #expect(try ContentFixture.markdown("<pre>```\ninner\n```</pre>") == "````\n```\ninner\n```\n````")
            #expect(try ContentFixture.markdown("<pre>a ``````</pre>") == "```````\na ``````\n```````")
        }

        @Test
        func entitiesAreDecodedExactlyOnce() throws {
            #expect(try ContentFixture.markdown("<pre>&amp;amp; &lt;tag&gt; &amp;lt;</pre>") == "```\n&amp; <tag> &lt;\n```")
            #expect(try ContentFixture.markdown("<p>&amp;amp; &lt;b&gt; caf&eacute; &copy; &#x1F600;</p>")
                == "&amp; <b> caf\u{00E9} \u{00A9} \u{1F600}")
            // No-break spaces collapse like ordinary whitespace outside <pre>.
            #expect(try ContentFixture.markdown("<p>a&nbsp;&nbsp;b\u{00A0}c</p>") == "a b c")
        }

        @Test
        func blockquotesPrefixEveryLine() throws {
            #expect(try ContentFixture.markdown(
                "<blockquote><p>Line one</p><p>Line two</p><blockquote>Nested</blockquote></blockquote>"
            ) == "> Line one\n>\n> Line two\n>\n> > Nested")
            #expect(try ContentFixture.markdown("<blockquote><ul><li>a</li><li>b</li></ul></blockquote>") == "> - a\n> - b")
        }

        @Test
        func tablesBecomeGFMTables() throws {
            #expect(try ContentFixture.markdown(
                "<table><caption>Caption</caption><thead><tr><th>Name</th><th>Value</th></tr></thead>"
                    + "<tbody><tr><td>a|b</td><td><p>one</p><p>two</p></td></tr><tr><td colspan=2>wide</td></tr></tbody></table>"
            ) == "Caption\n\n| Name | Value |\n| --- | --- |\n| a\\|b | one two |\n| wide |  |")

            // Without thead/th the first row is the header.
            #expect(try ContentFixture.markdown("<table><tr><td>h1</td><td>h2</td></tr><tr><td>v1</td><td>v2</td></tr></table>")
                == "| h1 | h2 |\n| --- | --- |\n| v1 | v2 |")
            // The first row is the header; a later th-only row is never relocated.
            #expect(try ContentFixture.markdown("<table><tr><td>x</td></tr><tr><th>H</th></tr></table>")
                == "| x |\n| --- |\n| H |")
            #expect(try ContentFixture.markdown(
                "<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr>"
                    + "<tr><th>C</th><th>D</th></tr><tr><td>3</td><td>4</td></tr></table>"
            ) == "| A | B |\n| --- | --- |\n| 1 | 2 |\n| C | D |\n| 3 | 4 |")
            // Implied cells/rows from malformed markup.
            #expect(try ContentFixture.markdown("<table><tr><td>a<td>b<tr><td>c</table>")
                == "| a | b |\n| --- | --- |\n| c |  |")
        }

        @Test
        func definitionListsDetailsAndFigures() throws {
            #expect(try ContentFixture.markdown(
                "<dl><dt>Term</dt><dd>Definition</dd><dt>Other</dt><dd>First</dd><dd>Second</dd></dl>"
            ) == "**Term**\n  Definition\n\n**Other**\n  First\n  Second")
            #expect(try ContentFixture.markdown("<details><summary>More info</summary><p>Body</p></details>")
                == "**More info**\n\nBody")
            #expect(try ContentFixture.markdown(
                "<figure><img src='/img/a.png' alt='Diagram'><figcaption>Figure 1</figcaption></figure>"
            ) == "![Diagram](https://example.com/img/a.png)\n\nFigure 1")
        }

        @Test
        func imagesUseAbsoluteSources() throws {
            let html = "<p><img src='x.png' alt=' Alt  text '> <img src='data:image/png;base64,AAAA' alt='inline'> "
                + "<img src='y.png'> <img alt='no source'> <img src='t.png' title='Titled'></p>"
            // Images without alt or title are decorative and emit nothing.
            #expect(try ContentFixture.markdown(html)
                == "![Alt text](https://example.com/docs/x.png) inline no source ![Titled](https://example.com/docs/t.png)")
            #expect(try ContentFixture.text(html) == "[image: Alt text] [image: inline] [image: no source] [image: Titled]")
        }

        @Test
        func invisibleAndNonContentElementsAreSkipped() throws {
            #expect(try ContentFixture.markdown(
                "<p>Visible</p><script>bad()</script><style>.x{}</style><noscript>ns</noscript>"
                    + "<template><p>tpl</p></template><svg><text>svg</text></svg><canvas>cv</canvas>"
                    + "<iframe src=x>if</iframe><object>obj</object><embed src=e><p hidden>h</p>"
                    + "<p aria-hidden=' TRUE '>ah</p><p style='color:red; DISPLAY : none'>dn</p>"
                    + "<p style='visibility:\thidden'>vh</p><p aria-hidden='false'>shown</p>"
                    + "<form><input value=in><select><option>opt</option></select><textarea>ta</textarea>"
                    + "<button>Press</button></form><!-- comment --><p>End</p>"
            ) == "Visible\n\nshown\n\nPress\n\nEnd")
        }

        @Test
        func mainElementIsPreferred() throws {
            let body = ContentFixture.longText("Main")
            let result = try ContentFixture.convert(
                "<body><nav><a href='/home'>Home page</a></nav><main><h1>Article</h1><p>\(body)</p>"
                    + "<a href='/more'>Read more</a></main><footer>Footer text</footer></body>"
            )

            #expect(result.scope == .mainContent("main"))
            #expect(result.content.hasPrefix("# Article\n\nMain lorem"))
            #expect(!result.content.contains("Home page"))
            #expect(!result.content.contains("Footer text"))
            #expect(result.links == [WebExtractedLink(text: "Read more", url: "https://example.com/more")])
        }

        @Test
        func roleMainAndLargestArticleAreCandidates() throws {
            let role = try ContentFixture.convert(
                "<body><div class=menu>Menu</div><div role='main'><p>\(ContentFixture.longText("Role"))</p></div></body>"
            )
            #expect(role.scope == .mainContent("[role=main]"))
            #expect(!role.content.contains("Menu"))

            let articles = try ContentFixture.convert(
                "<body><article><p>\(ContentFixture.longText("Short", count: 6))</p></article>"
                    + "<article><p>\(ContentFixture.longText("Long", count: 14))</p></article></body>"
            )
            #expect(articles.scope == .mainContent("article"))
            #expect(articles.content.hasPrefix("Long lorem"))
            #expect(!articles.content.contains("Short"))
        }

        @Test
        func smallMainFallsBackToFullPageWithoutLandmarks() throws {
            let page = "<body><header>Site header</header><nav>Navigation</nav><main><p>Tiny main</p></main>"
                + "<div>\(ContentFixture.longText("Body", count: 20))</div><aside>Aside</aside>"
                + "<div role='navigation'>Role nav</div><div role='banner'>Banner</div><div role='dialog'>Dialog</div>"
                + "<div role='complementary'>Comp</div><div role='contentinfo'>Info</div><footer>Footer</footer></body>"
            let result = try ContentFixture.convert(page)

            #expect(result.scope == .fullPage)
            #expect(result.content.hasPrefix("Tiny main\n\nBody lorem"))
            for removed in ["Site header", "Navigation", "Aside", "Role nav", "Banner", "Dialog", "Comp", "Info", "Footer"] {
                #expect(!result.content.contains(removed), "\(removed) should be removed")
            }

            // A long main that is under 20% of the page also falls back.
            let diluted = try ContentFixture.convert(
                "<body><main><p>\(ContentFixture.longText("Main", count: 8))</p></main>"
                    + "<div>\(ContentFixture.longText("Rest", count: 60))</div></body>"
            )
            #expect(diluted.scope == .fullPage)

            let everything = try ContentFixture.convert(page) { $0.mainContentOnly = false }
            #expect(everything.scope == .fullPage)
            #expect(everything.content.hasPrefix("Site header\n\nNavigation\n\nTiny main"))
            #expect(everything.content.hasSuffix("Footer"))
        }

        @Test
        func baseElementOverridesTheBaseURL() throws {
            let absolute = try ContentFixture.convert(
                "<head><base href='https://cdn.example.net/root/'></head><body><a href='page'>Page link</a> "
                    + "<img src='i.png' alt='i'></body>"
            )
            #expect(absolute.content == "[Page link](https://cdn.example.net/root/page) ![i](https://cdn.example.net/root/i.png)")
            #expect(absolute.links.map(\.url) == ["https://cdn.example.net/root/page"])

            let relative = try ContentFixture.convert("<base href='/sub/'><a href='x'>Sub link</a>")
            #expect(relative.content == "[Sub link](https://example.com/sub/x)")

            let unresolvable = try WebMarkdownConverter.convert(html: "<a href='relative/path'>Relative</a> <a href='https://ok.org/'>Absolute</a>")
            #expect(unresolvable.content == "Relative [Absolute](https://ok.org/)")
            #expect(unresolvable.links.map(\.url) == ["https://ok.org/"])
        }

        @Test
        func linksListIsUniqueFilteredAndCapped() throws {
            let html = "<p><a href='/one'>First text</a> <a href='https://example.com/one'>Second text</a> "
                + "<a href='/ic'>ab</a> <a href='/ic'>Icon label</a> <a href='#frag'>Fragment</a> "
                + "<a href='page.html#section'>Same page</a> <a href='ftp://example.com/f'>FTP file</a> "
                + "<a href='mailto:a@b.c'>Mail link</a> <span hidden><a href='/hidden'>Hidden link</a></span> "
                + "<a href='/two'>  Spaced\n  text  </a> <a href='/three'>Third</a></p>"
            let result = try ContentFixture.convert(html)

            #expect(result.links == [
                WebExtractedLink(text: "First text", url: "https://example.com/one"),
                WebExtractedLink(text: "Icon label", url: "https://example.com/ic"),
                WebExtractedLink(text: "Spaced text", url: "https://example.com/two"),
                WebExtractedLink(text: "Third", url: "https://example.com/three"),
            ])

            let capped = try ContentFixture.convert(html) { $0.maxLinks = 2 }
            #expect(capped.links.map(\.url) == ["https://example.com/one", "https://example.com/ic"])
            #expect(try ContentFixture.convert(html) { $0.maxLinks = 0 }.links.isEmpty)
        }

        @Test
        func plainTextFormatDropsMarkup() throws {
            #expect(try ContentFixture.text(
                "<h2>Heading</h2><p><b>Bold</b> <em>em</em> <code>co`de</code> <a href='/x'>Link text</a> <del>old</del></p>"
                    + "<ul><li>item</li></ul><ol><li>first</li></ol><blockquote>quote</blockquote>"
                    + "<pre class='language-js'>let a = 1;</pre><table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2|3</td></tr></table>"
                    + "<dl><dt>T</dt><dd>D</dd></dl><details><summary>S</summary>x</details>"
            ) == "Heading\n\nBold em co`de Link text old\n\n- item\n\n1. first\n\n> quote\n\nlet a = 1;\n\nA | B\n1 | 2|3\n\nT\n  D\n\nS\n\nx")
        }

        @Test
        func selectorScopeConcatenatesMatches() throws {
            let html = "<head><title>Doc title</title></head><body><div class='a'>First <span class='a'>nested</span></div>"
                + "<p>skip</p><div class='a'>Second <a href='/s'>Selected link</a></div><a href='/out'>Outside link</a></body>"
            let result = try ContentFixture.convert(html) { $0.selector = ".a" }

            #expect(result.scope == .selector(".a"))
            #expect(result.content == "First nested\n\nSecond [Selected link](https://example.com/s)")
            #expect(result.links.map(\.url) == ["https://example.com/s"])
            #expect(result.title == "Doc title")

            #expect(try ContentFixture.markdown(html) { $0.selector = "div > span.a" } == "nested")
            #expect(try ContentFixture.convert(html) { $0.selector = "  " }.scope == .fullPage)
            #expect(throws: WebContentError.selectorMatchedNothing(".missing")) {
                try ContentFixture.convert(html) { $0.selector = ".missing" }
            }
            #expect(throws: WebContentError.invalidSelector("a:hover")) {
                try ContentFixture.convert(html) { $0.selector = "a:hover" }
            }
        }

        @Test
        func titleDescriptionAndCanonicalComeFromHead() throws {
            let result = try ContentFixture.convert(
                "<html><head><title>\n  Hello &amp;   World \n</title><meta name='Description' content='  Page   summary '>"
                    + "<meta property='og:description' content='OG text'><link rel='alternate canonical' href='/canonical/path'>"
                    + "</head><body><h1>Heading</h1><svg><title>Icon</title></svg></body></html>"
            )
            #expect(result.title == "Hello & World")
            #expect(result.description == "Page summary")
            #expect(result.canonicalURL == "https://example.com/canonical/path")

            let fallback = try ContentFixture.convert(
                "<head><meta property='og:description' content='From  OG'></head><body><h1> First <b>heading</b> </h1><h1>Second</h1></body>"
            )
            #expect(fallback.title == "First heading")
            #expect(fallback.description == "From OG")
            #expect(fallback.canonicalURL == nil)

            let empty = try ContentFixture.convert("<p>No metadata</p>")
            #expect(empty.title == "")
            #expect(empty.description == nil)
            #expect(empty.canonicalURL == nil)

            let metadata = WebMarkdownConverter.metadata(
                html: "<title>T</title><meta name=description content='D'><link rel=canonical href='/c'>",
                baseURL: ContentFixture.pageURL
            )
            #expect(metadata == WebHTMLMetadata(title: "T", description: "D", canonicalURL: "https://example.com/c"))
        }

        @Test
        func layoutTablesRenderAsBlocks() throws {
            // Hacker News shape: an outer table nesting a header table and a
            // sparse story table (empty vote and indent cells): all layout.
            // The vote cell's empty icon block neither splits the row nor
            // renders the link's URL.
            let html = "<table id=hnmain><tr><td><table><tr><td><a href='/news'>Hacker News</a> "
                + "<a href='/new'>new</a></td><td>login</td></tr></table></td></tr>"
                + "<tr><td><table><tr><td>1.</td><td><center><a href='vote?id=1'><div class=votearrow title=upvote></div>"
                + "</a></center></td><td><a href='https://a.example/'>Story A</a></td></tr>"
                + "<tr><td colspan=2></td><td>10 points</td></tr><tr class=spacer></tr>"
                + "<tr><td>2.</td><td><center><a href='vote?id=2'><div class=votearrow></div></a></center></td>"
                + "<td><a href='https://b.example/'>Story B</a></td></tr><tr><td colspan=2></td><td>5 points</td></tr>"
                + "</table></td></tr></table>"
            let result = try ContentFixture.convert(html)
            #expect(result.content == """
            [Hacker News](https://example.com/news) [new](https://example.com/new) login

            1. [Story A](https://a.example/)

            10 points

            2. [Story B](https://b.example/)

            5 points
            """)
            #expect(!result.links.contains { $0.url.contains("vote") })

            // Single-row and single-column tables are layout: rows become
            // paragraphs, cells run inline, nested blocks stay blocks.
            #expect(try ContentFixture.markdown("<table><tr><td>Left</td><td>Right</td></tr></table>") == "Left Right")
            #expect(try ContentFixture.markdown("<table><tr><td>One</td></tr><tr><td>Two</td></tr></table>") == "One\n\nTwo")
            #expect(try ContentFixture.markdown(
                "<table><tr><td><h2>Title</h2><p>Body text</p></td><td><ul><li>a</li></ul></td></tr></table>"
            ) == "## Title\n\nBody text\n\n- a")
            #expect(try ContentFixture.markdown(
                "<table><tr><td>Label <div>Block value</div> tail <div></div> end</td></tr></table>"
            ) == "Label\n\nBlock value\n\ntail end")
            #expect(try ContentFixture.text("<table><tr><td>Left</td><td>Right</td></tr></table>") == "Left Right")
            // Outside layout cells empty blocks still end the paragraph.
            #expect(try ContentFixture.markdown("<div>a<div></div>b</div>") == "a\n\nb")
        }

        @Test
        func sparseGridsAreLayoutTables() throws {
            func grid(_ cells: [[String]]) -> String {
                "<table>" + cells.map { "<tr>" + $0.map { "<td>\($0)</td>" }.joined() + "</tr>" }.joined() + "</table>"
            }
            // Fewer than a third of the cells empty: still a data table.
            #expect(try ContentFixture.markdown(grid([["a", "b", "c"], ["d", "", "f"], ["g", "", "i"]]))
                == "| a | b | c |\n| --- | --- | --- |\n| d |  | f |\n| g |  | i |")
            // A third or more empty: layout.
            #expect(try ContentFixture.markdown(grid([["a", "", "c"], ["d", "", "f"], ["g", "", "i"]]))
                == "a c\n\nd f\n\ng i")
            // An image with alt text is content; one without is not.
            let icons = grid([["Feature", "<img src=y.png alt=yes>"], ["Other", "<img src=n.png alt=no>"]])
            #expect(try ContentFixture.markdown(icons).hasPrefix("| Feature | ![yes](https://example.com/docs/y.png) |"))
            #expect(try ContentFixture.markdown(grid([["Feature", "<img src=y.png>"], ["Other", "<img src=n.png>"]]))
                == "Feature\n\nOther")
            // Header markup wins over sparseness.
            #expect(try ContentFixture.markdown("<table><tr><th>H</th><th></th></tr><tr><td></td><td>x</td></tr></table>")
                == "| H |  |\n| --- | --- |\n|  | x |")
        }

        @Test
        func textlessAnchorsRenderTheirURLOnlyWhenEmpty() throws {
            let html = "<p>A <a href='/e'></a> B <a href='/i'><img src='i.png'></a> C <a href='/d'><span class=icon></span></a> "
                + "D <a href='/x'><img src='x.png' alt='X logo'></a> E <a href='/t'>Text link</a></p>"
            let result = try ContentFixture.convert(html)
            #expect(result.content == "A <https://example.com/e> B C D "
                + "[![X logo](https://example.com/docs/x.png)](https://example.com/x) E [Text link](https://example.com/t)")
            // Links without text are never listed, whatever they render.
            #expect(result.links == [WebExtractedLink(text: "Text link", url: "https://example.com/t")])
        }

        @Test
        func dataTablesAreRecognizedByMarkupOrShape() throws {
            // A th, caption, thead, tfoot, summary or grid role makes even a
            // single row or a table with nested tables a data table.
            #expect(try ContentFixture.markdown("<table><tr><th>Only</th></tr></table>") == "| Only |\n| --- |")
            #expect(try ContentFixture.markdown("<table summary='s'><tr><td>a</td><td>b</td></tr></table>")
                == "| a | b |\n| --- | --- |")
            #expect(try ContentFixture.markdown("<table role=grid><tr><td>a</td></tr></table>") == "| a |\n| --- |")
            #expect(try ContentFixture.markdown("<table><caption>Cap</caption><tr><td>a</td></tr></table>")
                == "Cap\n\n| a |\n| --- |")
            #expect(try ContentFixture.markdown("<table><tfoot><tr><td>f</td></tr></tfoot></table>") == "| f |\n| --- |")
            // A plain 2x2 grid is data; the same grid nesting a table is layout.
            let nested = "<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>"
                + "<table><tr><td>x</td><td>y</td></tr><tr><td>z</td><td>w</td></tr></table></td></tr></table>"
            #expect(try ContentFixture.markdown(nested) == "a b\n\nc\n\n| x | y |\n| --- | --- |\n| z | w |")
            let grid = try #require(WebHTMLParser.parse("<table><tr><td>1<td>2<tr><td>3</table>").descendants
                .first { $0.tagName == "table" })
            #expect(WebMarkdownRenderer.isDataTable(grid))
        }

        @Test
        func landmarksAreStrippedInsideMainContent() throws {
            let body = ContentFixture.longText("Main")
            let html = "<body><main><header><h1>Article title</h1><p>By someone</p></header>"
                + "<header><nav><a href='/x'>Crumb</a></nav><p>Header with nav</p></header>"
                + "<nav>Inner nav</nav><p>\(body)</p><aside>Aside text</aside><footer>Inner footer</footer>"
                + "<div role='navigation'>Role nav</div><ul role='menu'><li>Menu item</li></ul>"
                + "<div role='menubar'>Menubar</div><div role='complementary'>Comp</div>"
                + "<div role='contentinfo'>Info</div><div role='dialog'>Dialog</div><div role='alert'>Alert</div>"
                + "<div role='banner'>Banner kept</div></main></body>"
            let result = try ContentFixture.convert(html)

            #expect(result.scope == .mainContent("main"))
            #expect(result.content.hasPrefix("# Article title\n\nBy someone\n\nMain lorem"))
            #expect(result.content.hasSuffix("Banner kept"))
            for removed in ["Crumb", "Header with nav", "Inner nav", "Aside text", "Inner footer", "Role nav",
                            "Menu item", "Menubar", "Comp", "Info", "Dialog", "Alert"] {
                #expect(!result.content.contains(removed), "\(removed) should be removed")
            }
            #expect(result.links.isEmpty)

            // The scope root itself is never stripped, selector matches keep
            // everything, and mainContentOnly=false keeps everything.
            let rooted = try ContentFixture.convert("<body><article role='dialog'><p>\(body)</p><nav>N</nav></article></body>")
            #expect(rooted.scope == .mainContent("article"))
            #expect(rooted.content.hasPrefix("Main lorem"))
            #expect(!rooted.content.contains("\n\nN"))
            #expect(try ContentFixture.markdown(html) { $0.selector = "main" }.contains("Inner nav"))
            #expect(try ContentFixture.markdown(html) { $0.mainContentOnly = false }.contains("Aside text"))
        }

        @Test
        func samePageLinksRenderAsText() throws {
            let html = "<p>Swift<sup><a href='#cite_note-1'>[1]</a></sup> see <a href='page.html#History'>History</a>, "
                + "<a href='https://example.com/docs/page.html'>this page</a>, "
                + "<a href='https://example.com/docs/other.html#x'>Other page</a>.</p>"
            let result = try ContentFixture.convert(html)
            #expect(result.content == "Swift[1] see History, this page, [Other page](https://example.com/docs/other.html#x).")
            #expect(result.links == [WebExtractedLink(text: "Other page", url: "https://example.com/docs/other.html#x")])

            // An explicit pageURL overrides the base URL for this check.
            let explicit = try ContentFixture.convert(html) { $0.pageURL = URL(string: "https://example.com/docs/other.html") }
            #expect(explicit.content.contains("[History](https://example.com/docs/page.html#History)"))
            #expect(explicit.content.contains("Other page."))
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

            #expect(elapsed < .seconds(2), "parse + convert took \(elapsed)")
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
