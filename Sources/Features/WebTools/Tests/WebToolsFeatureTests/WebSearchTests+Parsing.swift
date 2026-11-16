//
//  WebSearchTests+Parsing.swift
//  ZenCODE
//
//  Search fixtures trimmed from live DuckDuckGo responses, plus the header
//  and retry, next-form, lite-parsing and bot-check test suites of the
//  web.search tool.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WebToolsFeature
import Testing

// MARK: - Fixtures (trimmed from live DuckDuckGo responses)

enum SearchFixtures {
    /// HTML endpoint, first page: a header form (no Next button) and the
    /// Next form with hidden inputs in the engine's own attribute order.
    static let htmlFirstPage = """
    <form name="x" class="header__form" action="/html/" method="post">
      <input name="q" autocomplete="off" class="search__input" type="text" value="swift testing framework" />
      <input name="b" id="search_button_homepage" class="search__button" value="" title="Search" type="submit" />
    </form>
    <div class="result results_links results_links_deep web-result ">
      <h2 class="result__title">
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.apple.com%2Fdocumentation%2Ftesting%2F&amp;rut=e3f3">Swift Testing | Apple Developer Documentation</a>
      </h2>
      <a class="result__url" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.apple.com%2Fdocumentation%2Ftesting%2F&amp;rut=e3f3">developer.apple.com/documentation/testing/</a>
      <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.apple.com%2Fdocumentation%2Ftesting%2F&amp;rut=e3f3">With <b>Swift</b> <b>Testing</b> you leverage powerful and expressive capabilities, and ...</a>
    </div>
    <div class="nav-link">
      <form action="/html/" method="post">
        <input type="submit" class='btn btn--alt' value="Next" />
        <input type="hidden" name="q" value="swift testing framework" />
        <input type="hidden" name="s" value="10" />
        <input type="hidden" name="nextParams" value="" />
        <input type="hidden" name="v" value="l" />
        <input type="hidden" name="o" value="json" />
        <input type="hidden" name="dc" value="11" />
        <input type="hidden" name="api" value="d.js" />
        <input type="hidden" name="vqd" value="4-79106108642940171165729162763734084234" />
          <input name="kl" value="wt-wt" type="hidden" />
      </form>
    </div>
    """

    /// HTML endpoint after a POST: a Previous form (s=0) and a Next form (s=25).
    static let htmlSecondPageForms = """
    <div class="nav-link">
      <form action="/html/" method="post">
        <input type="submit" class='btn btn--alt' value="Previous" />
        <input type="hidden" name="q" value="swift testing framework" />
        <input type="hidden" name="s" value="0" />
        <input type="hidden" name="vqd" value="4-79106108642940171165729162763734084234" />
      </form>
    </div>
    <div class="nav-link">
      <form action="/html/" method="post">
        <input type="submit" class='btn btn--alt' value="Next" />
        <input type="hidden" name="q" value="swift testing framework" />
        <input type="hidden" name="s" value="25" />
        <input type="hidden" name="vqd" value="4-79106108642940171165729162763734084234" />
      </form>
    </div>
    """

    /// Last HTML page: only a Previous form, so there is nothing more to load.
    static let htmlLastPageForms = """
    <div class="nav-link">
      <form action="/html/" method="post">
        <input type="submit" class='btn btn--alt' value="Previous" />
        <input type="hidden" name="q" value="swift testing framework" />
        <input type="hidden" name="s" value="25" />
      </form>
    </div>
    """

    /// Lite endpoint: single-quoted `class`, `href` before `class`, snippet in
    /// a following `<td class='result-snippet'>`, the Next form (repeated at
    /// the bottom of the page) labelled "Next Page &gt;".
    static let liteFirstPage = #"""
    <form class="next_form" action="/lite/" method="post">
        <input type="submit" class='navbutton' value="Next Page &gt;">
        <input type="hidden" name="q" value="swift testing &amp; more">
        <input type="hidden" name="s" value="10">
        <input type="hidden" name="nextParams" value="">
        <input type="hidden" name="v" value="l">
        <input type="hidden" name="o" value="json">
        <input type="hidden" name="dc" value="11">
        <input type="hidden" name="api" value="d.js">
        <input type="hidden" name="vqd" value="4-79106108642940171165729162763734084234">
        &nbsp;&nbsp;&nbsp;&nbsp;
          <input name="kl" value="wt-wt" type="hidden">
    </form>
    <table>
      <tr><td valign="top">1.&nbsp;</td>
        <td>
          <a rel="nofollow" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.apple.com%2Fdocumentation%2Ftesting%2F&amp;rut=e3f3" class='result-link'>Swift Testing | Apple Developer Documentation</a>
        </td>
      </tr>
      <tr>
        <td>&nbsp;&nbsp;&nbsp;</td>
        <td class='result-snippet'>
          With <b>Swift</b> <b>Testing</b> you leverage powerful and expressive
          capabilities of the <b>Swift</b> programming language &amp; more, and ...
        </td>
      </tr>
      <tr><td>&nbsp;</td><td><span class='link-text'>developer.apple.com/documentation/testing/</span></td></tr>
      <tr><td valign="top">2.&nbsp;</td>
        <td><a rel="nofollow" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.swift.org%2Fpackages%2Ftesting.html&amp;rut=21f5" class='result-link'>Testing - Swift.org</a></td>
      </tr>
      <tr><td valign="top">3.&nbsp;</td>
        <td><a rel="nofollow" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fgithub.com%2Fswiftlang%2Fswift%2Dtesting&amp;rut=070e" class='result-link'>Swift Testing - GitHub</a></td>
      </tr>
      <tr>
        <td>&nbsp;&nbsp;&nbsp;</td>
        <td class='result-snippet'>A Swift package for testing.</td>
      </tr>
    </table>
    <form class="next_form" action="/lite/" method="post">
        <input type="submit" class='navbutton' value="Next Page &gt;">
        <input type="hidden" name="q" value="swift testing &amp; more">
        <input type="hidden" name="s" value="10">
        <input type="hidden" name="vqd" value="4-79106108642940171165729162763734084234">
    </form>
    """#

    /// The bot-check page DuckDuckGo serves with HTTP 202.
    static let anomalyPage = """
    <form id="challenge-form" action="//duckduckgo.com/anomaly.js?sv=html&cc=botnet" method="POST">
      <div class="anomaly-modal__mask">
        <div class="anomaly-modal__modal  is-ie" data-testid="anomaly-modal">
          <div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div>
          <div class="anomaly-modal__description">Please complete the following challenge to confirm this search was made by a human.</div>
        </div>
      </div>
    </form>
    """

    /// A synthetic HTML-endpoint page with the given result URLs and an
    /// optional Next form (`s` = `nextOffset`).
    static func htmlPage(_ urls: [String], nextOffset: Int? = nil) -> String {
        let results = urls.map { url -> String in
            let encoded = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url
            return """
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=\(encoded)&amp;rut=x">Title of \(url)</a>
            <a class="result__snippet" href="//duckduckgo.com/l/?uddg=\(encoded)&amp;rut=x">Snippet of <b>\(url)</b></a>
            """
        }.joined(separator: "\n")
        guard let nextOffset else { return results }
        return results + """

        <form action="/html/" method="post">
          <input type="submit" class='btn btn--alt' value="Next" />
          <input type="hidden" name="q" value="swift" />
          <input type="hidden" name="s" value="\(nextOffset)" />
          <input type="hidden" name="vqd" value="4-123" />
          <input name="kl" value="wt-wt" type="hidden" />
        </form>
        """
    }

    static func litePage(_ urls: [String], nextOffset: Int? = nil) -> String {
        let results = urls.map { url -> String in
            let encoded = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url
            return """
            <tr><td><a rel="nofollow" href="//duckduckgo.com/l/?uddg=\(encoded)&amp;rut=x" class='result-link'>Lite title of \(url)</a></td></tr>
            <tr><td class='result-snippet'>Lite snippet of \(url)</td></tr>
            """
        }.joined(separator: "\n")
        guard let nextOffset else { return results }
        return results + """

        <form class="next_form" action="/lite/" method="post">
          <input type="submit" class='navbutton' value="Next Page &gt;">
          <input type="hidden" name="q" value="swift">
          <input type="hidden" name="s" value="\(nextOffset)">
          <input type="hidden" name="vqd" value="4-123">
        </form>
        """
    }
}

func pairs(_ fields: [(name: String, value: String)]?) -> [String]? {
    fields?.map { "\($0.name)=\($0.value)" }
}

// MARK: - Headers and retry

@Suite
struct WebSearchHeadersAndRetryTests {
    @Test
    func userAgentMatchesTheBrowserLikeString() {
        #expect(
            WebToolsSupport.userAgent
                == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) ZenCODE/1.0"
        )
    }

    @Test
    func plainRequestsCarryTheBrowserHeaders() throws {
        let url = try #require(URL(string: "https://example.com/"))
        let request = WebToolsSupport.makeRequest(url: url, timeout: 9)
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 9)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == WebToolsSupport.userAgent)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9,*;q=0.5")
    }

    @Test
    func retryAfterAcceptsDeltaSecondsAndCapsAtTenSeconds() {
        #expect(WebToolsSupport.retryAfterDelay(from: "5") == 5)
        #expect(WebToolsSupport.retryAfterDelay(from: " 3 ") == 3)
        #expect(WebToolsSupport.retryAfterDelay(from: "0") == 0)
        #expect(WebToolsSupport.retryAfterDelay(from: "1.5") == 1.5)
        #expect(WebToolsSupport.retryAfterDelay(from: "10") == 10)
        #expect(WebToolsSupport.retryAfterDelay(from: "11") == 10)
        #expect(WebToolsSupport.retryAfterDelay(from: "120") == 10)
        #expect(WebToolsSupport.retryAfterDelay(from: "99999999999999999999") == 10)
    }

    @Test
    func retryAfterIgnoresMissingMalformedAndDateValues() {
        #expect(WebToolsSupport.retryAfterDelay(from: nil) == nil)
        #expect(WebToolsSupport.retryAfterDelay(from: "") == nil)
        #expect(WebToolsSupport.retryAfterDelay(from: "   ") == nil)
        #expect(WebToolsSupport.retryAfterDelay(from: "-1") == nil)
        #expect(WebToolsSupport.retryAfterDelay(from: "abc") == nil)
        #expect(WebToolsSupport.retryAfterDelay(from: "inf") == nil)
        #expect(WebToolsSupport.retryAfterDelay(from: "1e3") == nil)
        #expect(WebToolsSupport.retryAfterDelay(from: "1.2.3") == nil)
        #expect(WebToolsSupport.retryAfterDelay(from: "Wed, 21 Oct 2015 07:28:00 GMT") == nil)
    }
}

// MARK: - Parsing

@Suite
struct WebSearchNextFormTests {
    @Test
    func htmlFirstPageYieldsTheNextFormFieldsInOrder() {
        let fields = WebToolsSupport.parseDuckDuckGoNextForm(SearchFixtures.htmlFirstPage)
        #expect(pairs(fields) == [
            "q=swift testing framework",
            "s=10",
            "nextParams=",
            "v=l",
            "o=json",
            "dc=11",
            "api=d.js",
            "vqd=4-79106108642940171165729162763734084234",
            "kl=wt-wt"
        ])
    }

    @Test
    func htmlSecondPageSelectsTheNextFormNotThePreviousOne() {
        let fields = WebToolsSupport.parseDuckDuckGoNextForm(SearchFixtures.htmlSecondPageForms)
        #expect(pairs(fields)?.contains("s=25") == true)
        #expect(pairs(fields)?.contains("s=0") == false)
    }

    @Test
    func pageWithOnlyAPreviousFormHasNoNextForm() {
        #expect(WebToolsSupport.parseDuckDuckGoNextForm(SearchFixtures.htmlLastPageForms) == nil)
    }

    @Test
    func liteFormIsFoundAndItsValuesAreEntityDecoded() {
        let fields = WebToolsSupport.parseDuckDuckGoNextForm(SearchFixtures.liteFirstPage)
        // Two identical-purpose forms: the last one (bottom of the page) wins.
        #expect(pairs(fields) == [
            "q=swift testing & more",
            "s=10",
            "vqd=4-79106108642940171165729162763734084234"
        ])
    }

    @Test
    func missingOrUnrelatedFormsYieldNil() {
        #expect(WebToolsSupport.parseDuckDuckGoNextForm("") == nil)
        #expect(WebToolsSupport.parseDuckDuckGoNextForm("<p>no forms here</p>") == nil)
        let searchBoxOnly = #"<form action="/html/" method="post"><input name="q" type="text" value="x" /><input type="submit" value="Search" /></form>"#
        #expect(WebToolsSupport.parseDuckDuckGoNextForm(searchBoxOnly) == nil)
        let nextWithoutFields = #"<form><input type="submit" value="Next" /></form>"#
        #expect(WebToolsSupport.parseDuckDuckGoNextForm(nextWithoutFields) == nil)
    }

    @Test
    func attributeOrderQuotingAndLabelCaseDoNotMatter() {
        let html = """
        <FORM METHOD=post ACTION='/html/'>
          <INPUT VALUE='NEXT' TYPE='SUBMIT'>
          <input value='a &quot;b&quot; &#38; c' name=q type=hidden>
          <input value="" name="nextParams" type="hidden"/>
        </FORM>
        """
        #expect(pairs(WebToolsSupport.parseDuckDuckGoNextForm(html)) == ["q=a \"b\" & c", "nextParams="])
    }

    @Test
    func inputsOutsideTheNextFormAreNotCollected() {
        let html = """
        <form><input type="hidden" name="outside" value="1"></form>
        <form><input type="submit" value="Next"><input type="hidden" name="q" value="x"></form>
        <form><input type="hidden" name="after" value="2"></form>
        """
        #expect(pairs(WebToolsSupport.parseDuckDuckGoNextForm(html)) == ["q=x"])
    }
}

@Suite
struct WebSearchLiteParsingTests {
    @Test
    func liteResultsWithSingleQuotedClassAndFollowingSnippetAreParsed() throws {
        let results = WebToolsSupport.parseDuckDuckGoLiteResults(SearchFixtures.liteFirstPage, limit: 10, domains: [])
        #expect(results.map(\.url) == [
            "https://developer.apple.com/documentation/testing/",
            "https://www.swift.org/packages/testing.html",
            "https://github.com/swiftlang/swift-testing"
        ])
        #expect(results.map(\.title) == [
            "Swift Testing | Apple Developer Documentation",
            "Testing - Swift.org",
            "Swift Testing - GitHub"
        ])
        // Tags stripped, entities decoded, whitespace (including newlines) collapsed.
        #expect(results[0].snippet == "With Swift Testing you leverage powerful and expressive capabilities of the Swift programming language & more, and ...")
        // The second result has no snippet row of its own; the next result's snippet must not leak into it.
        #expect(results[1].snippet == "")
        #expect(results[2].snippet == "A Swift package for testing.")
    }

    @Test
    func liteParserHonoursLimitAndDomainFilter() {
        let page = SearchFixtures.liteFirstPage
        #expect(WebToolsSupport.parseDuckDuckGoLiteResults(page, limit: 2, domains: []).count == 2)
        #expect(WebToolsSupport.parseDuckDuckGoLiteResults(page, limit: 10, domains: ["swift.org"]).map(\.url) == ["https://www.swift.org/packages/testing.html"])
        #expect(WebToolsSupport.parseDuckDuckGoLiteResults(page, limit: 10, domains: ["example.invalid"]).isEmpty)
        #expect(WebToolsSupport.parseDuckDuckGoLiteResults("", limit: 5, domains: []).isEmpty)
        #expect(WebToolsSupport.parseDuckDuckGoLiteResults(page, limit: 0, domains: []).isEmpty)
    }

    @Test
    func liteParserIgnoresTheHTMLMarkupAndViceVersa() {
        #expect(WebToolsSupport.parseDuckDuckGoLiteResults(SearchFixtures.htmlFirstPage, limit: 10, domains: []).isEmpty)
        #expect(WebToolsSupport.parseDuckDuckGoHTMLResults(SearchFixtures.liteFirstPage, limit: 10, domains: []).isEmpty)
    }

    @Test
    func htmlParserReadsTheRealResultMarkup() throws {
        let results = WebToolsSupport.parseDuckDuckGoHTMLResults(SearchFixtures.htmlFirstPage, limit: 10, domains: [])
        let first = try #require(results.first)
        #expect(results.count == 1)
        #expect(first.url == "https://developer.apple.com/documentation/testing/")
        #expect(first.title == "Swift Testing | Apple Developer Documentation")
        #expect(first.snippet == "With Swift Testing you leverage powerful and expressive capabilities, and ...")
    }

    @Test
    func htmlParserToleratesHrefBeforeClassAndSingleQuotes() throws {
        let html = """
        <a href='https://one.example/a' class='result__a js-title'>One</a>
        <div class='result__snippet'>First <i>snippet</i></div>
        <a rel="nofollow" href="https://two.example/b" class="x result__a">Two</a>
        <a href="https://three.example/c" class="result__abstract">not a result</a>
        """
        let results = WebToolsSupport.parseDuckDuckGoHTMLResults(html, limit: 10, domains: [])
        #expect(results.map(\.url) == ["https://one.example/a", "https://two.example/b"])
        #expect(results.first?.snippet == "First snippet")
        #expect(results.last?.snippet == "")
    }

    @Test
    func sponsoredClickTrackerLinksAreDropped() {
        let html = """
        <a class="result__a" href="//duckduckgo.com/y.js?ad_domain=shop.example&amp;u3=x">Ad</a>
        <a class="result__a" href="https://real.example/page">Real</a>
        """
        #expect(WebToolsSupport.parseDuckDuckGoHTMLResults(html, limit: 10, domains: []).map(\.url) == ["https://real.example/page"])
    }

    @Test
    func snippetsAreCappedAtFourHundredCharacters() throws {
        let long = String(repeating: "word ", count: 200)
        let html = #"<a class="result__a" href="https://x.example/">T</a><a class="result__snippet" href="https://x.example/">\#(long)</a>"#
        let snippet = try #require(WebToolsSupport.parseDuckDuckGoHTMLResults(html, limit: 1, domains: []).first?.snippet)
        #expect(snippet.count <= WebToolsSupport.maxSnippetCharacters)
        #expect(snippet.hasSuffix("\u{2026}"))
        #expect(snippet.hasPrefix("word word"))

        #expect(WebToolsSupport.cappedSnippet("short") == "short")
        let exact = String(repeating: "a", count: 400)
        #expect(WebToolsSupport.cappedSnippet(exact) == exact)
        #expect(WebToolsSupport.cappedSnippet(exact + "b").count == 400)
        #expect(WebToolsSupport.plainText(fromHTML: " a <b>b</b>\n\n  c &amp; d\t") == "a b c & d")
    }

    @Test
    func inlineTagsLeaveNoStraySpacesButBlockTagsSeparateWords() {
        #expect(WebToolsSupport.plainText(fromHTML: "for <b>Swift</b>. Contribute to swiftlang/<b>swift</b>-<b>testing</b>") == "for Swift. Contribute to swiftlang/swift-testing")
        #expect(WebToolsSupport.plainText(fromHTML: "one<br>two<BR/>three</p><p class=\"x\">four<div>five</div>") == "one two three four five")
        #expect(WebToolsSupport.plainText(fromHTML: "x &lt;b&gt; y") == "x <b> y")
    }
}

// MARK: - Bot check

@Suite
struct WebSearchBotCheckTests {
    @Test
    func status202IsABotCheck() {
        #expect(WebToolsSupport.isSearchBotCheck(statusCode: 202, body: ""))
        #expect(WebToolsSupport.isSearchBotCheck(statusCode: 202, body: SearchFixtures.htmlFirstPage))
    }

    @Test
    func anomalyMarkupIsABotCheckEvenWithStatus200() {
        #expect(WebToolsSupport.isSearchBotCheck(statusCode: 200, body: SearchFixtures.anomalyPage))
        #expect(WebToolsSupport.parseDuckDuckGoHTMLResults(SearchFixtures.anomalyPage, limit: 10, domains: []).isEmpty)
    }

    @Test
    func ordinaryPagesAreNotABotCheck() {
        #expect(!WebToolsSupport.isSearchBotCheck(statusCode: 200, body: SearchFixtures.htmlFirstPage))
        #expect(!WebToolsSupport.isSearchBotCheck(statusCode: 200, body: SearchFixtures.liteFirstPage))
        #expect(!WebToolsSupport.isSearchBotCheck(statusCode: 200, body: ""))
        #expect(!WebToolsSupport.isSearchBotCheck(statusCode: 500, body: ""))
    }

    @Test
    func botCheckErrorExplainsWhatToDo() {
        let message = (WebSearchError.botCheck.errorDescription ?? "").lowercased()
        #expect(message.contains("duckduckgo"))
        #expect(message.contains("bot check"))
        #expect(message.contains("rate limit"))
        #expect(message.contains("wait about a minute"))
        #expect(message.contains("narrow the query"))
    }
}
