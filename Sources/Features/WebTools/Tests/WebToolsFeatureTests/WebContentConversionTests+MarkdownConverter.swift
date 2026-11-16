//
//  WebContentConversionTests+MarkdownConverter.swift
//  ZenCODE
//
//  Markdown converter suite of the platform-independent HTML pipeline tests.
//

import Foundation
@testable import WebToolsFeature
import Testing

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
        func titleAndDescriptionComeFromHead() throws {
            let result = try ContentFixture.convert(
                "<html><head><title>\n  Hello &amp;   World \n</title><meta name='Description' content='  Page   summary '>"
                    + "<meta property='og:description' content='OG text'>"
                    + "</head><body><h1>Heading</h1><svg><title>Icon</title></svg></body></html>"
            )
            #expect(result.title == "Hello & World")
            #expect(result.description == "Page summary")

            let fallback = try ContentFixture.convert(
                "<head><meta property='og:description' content='From  OG'></head><body><h1> First <b>heading</b> </h1><h1>Second</h1></body>"
            )
            #expect(fallback.title == "First heading")
            #expect(fallback.description == "From OG")

            let empty = try ContentFixture.convert("<p>No metadata</p>")
            #expect(empty.title == "")
            #expect(empty.description == nil)

            let metadata = WebMarkdownConverter.metadata(
                html: "<title>T</title><meta name=description content='D'>"
            )
            #expect(metadata == WebHTMLMetadata(title: "T", description: "D"))
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
