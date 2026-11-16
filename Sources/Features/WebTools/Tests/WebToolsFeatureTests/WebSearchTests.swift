import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WebToolsFeature
import Testing

private func parameters(
    _ query: String = "swift",
    limit: Int = 10,
    domains: [String] = [],
    timeRange: WebSearchTimeRange? = nil,
    region: String? = nil
) -> WebSearchParameters {
    WebSearchParameters(query: query, limit: limit, domains: domains, timeRange: timeRange, region: region)
}

private func bodyString(of request: URLRequest) -> String {
    request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
}

// MARK: - Request building

@Suite
struct WebSearchRequestBuildingTests {
    @Test
    func limitDefaultsToFiveAndIsClampedToOneThroughThirty() {
        #expect(WebToolsSupport.clampedSearchLimit(nil) == 5)
        #expect(WebToolsSupport.clampedSearchLimit(0) == 1)
        #expect(WebToolsSupport.clampedSearchLimit(-4) == 1)
        #expect(WebToolsSupport.clampedSearchLimit(1) == 1)
        #expect(WebToolsSupport.clampedSearchLimit(12) == 12)
        #expect(WebToolsSupport.clampedSearchLimit(30) == 30)
        #expect(WebToolsSupport.clampedSearchLimit(31) == 30)
        #expect(WebToolsSupport.clampedSearchLimit(10_000) == 30)
    }

    @Test
    func queryGetsNoSiteTermWithoutDomains() {
        #expect(WebToolsSupport.searchQuery("swift testing", domains: []) == "swift testing")
    }

    @Test
    func queryGetsOneSiteTermForASingleDomain() {
        #expect(WebToolsSupport.searchQuery("swift testing", domains: ["swift.org"]) == "swift testing site:swift.org")
    }

    @Test
    func queryGetsAnOrGroupForSeveralDomains() {
        #expect(
            WebToolsSupport.searchQuery("swift testing", domains: ["swift.org", "github.com"])
                == "swift testing (site:swift.org OR site:github.com)"
        )
        #expect(
            WebToolsSupport.searchQuery("q", domains: ["a.com", "b.org", "c.net"])
                == "q (site:a.com OR site:b.org OR site:c.net)"
        )
    }

    @Test
    func duplicateDomainsCollapseAndUnsafeEntriesAreNotTurnedIntoOperators() {
        #expect(WebToolsSupport.searchQuery("q", domains: ["a.com", "a.com"]) == "q site:a.com")
        #expect(WebToolsSupport.searchQuery("q", domains: ["a.com b.com"]) == "q")
        #expect(WebToolsSupport.searchQuery("q", domains: ["a.com)", "b.org"]) == "q site:b.org")
        let normalized = WebToolsSupport.normalizedDomains(from: ["https://Docs.Swift.org/x", " GitHub.com. "])
        #expect(WebToolsSupport.searchQuery("q", domains: normalized) == "q (site:docs.swift.org OR site:github.com)")
    }

    @Test
    func timeRangeMapsToTheDfParameter() throws {
        #expect(try WebSearchTimeRange.parse("day") == .day)
        #expect(try WebSearchTimeRange.parse("week") == .week)
        #expect(try WebSearchTimeRange.parse("month") == .month)
        #expect(try WebSearchTimeRange.parse("year") == .year)
        #expect(try WebSearchTimeRange.parse("  Week ") == .week)
        #expect(WebSearchTimeRange.allCases.map(\.dfValue) == ["d", "w", "m", "y"])
        #expect(try WebSearchTimeRange.parse(nil) == nil)
        #expect(try WebSearchTimeRange.parse("   ") == nil)
    }

    @Test
    func unknownTimeRangeIsRejectedWithAClearError() {
        #expect(throws: WebSearchError.invalidTimeRange("decade")) {
            try WebSearchTimeRange.parse("decade")
        }
        #expect(throws: WebSearchError.invalidTimeRange("d")) {
            try WebSearchTimeRange.parse("d")
        }
        let message = WebSearchError.invalidTimeRange("decade").errorDescription ?? ""
        #expect(message.contains("decade"))
        #expect(message.contains("day, week, month, year"))
    }

    @Test
    func regionIsLowercasedAndValidated() throws {
        #expect(try WebToolsSupport.normalizedSearchRegion("it-it") == "it-it")
        #expect(try WebToolsSupport.normalizedSearchRegion("US-EN") == "us-en")
        #expect(try WebToolsSupport.normalizedSearchRegion(" wt-wt ") == "wt-wt")
        #expect(try WebToolsSupport.normalizedSearchRegion(nil) == nil)
        #expect(try WebToolsSupport.normalizedSearchRegion("  ") == nil)
        for invalid in ["italy", "it_it", "it-ita", "i-it", "1t-it", "it-it\nx", "it-it&df=d", "it", "it-", "-it"] {
            #expect(throws: WebSearchError.self, "\(invalid) should be rejected") {
                try WebToolsSupport.normalizedSearchRegion(invalid)
            }
        }
        let message = WebSearchError.invalidRegion("italy").errorDescription ?? ""
        #expect(message.contains("italy"))
        #expect(message.contains("it-it"))
    }

    @Test
    func firstPageIsAGetWithEncodedQueryDefaultRegionAndHeaders() throws {
        let request = try WebToolsSupport.makeSearchRequest(
            engine: .html,
            parameters: parameters("c++ & swift (site:a.com OR site:b.com)"),
            formFields: nil,
            timeout: 7
        )
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.timeoutInterval == 7)
        let url = try #require(request.url?.absoluteString)
        #expect(url == "https://html.duckduckgo.com/html/?q=c%2B%2B+%26+swift+%28site%3Aa.com+OR+site%3Ab.com%29&kl=wt-wt")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == WebToolsSupport.userAgent)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9,*;q=0.5")
    }

    @Test
    func timeRangeAndRegionAreSentOnTheFirstPage() throws {
        let request = try WebToolsSupport.makeSearchRequest(
            engine: .lite,
            parameters: parameters("swift", timeRange: .week, region: "it-it"),
            formFields: nil,
            timeout: 5
        )
        #expect(request.url?.absoluteString == "https://lite.duckduckgo.com/lite/?q=swift&kl=it-it&df=w")
    }

    @Test
    func laterPagesPostTheFormFieldsToTheSameEndpoint() throws {
        let fields = [(name: "q", value: "a b&c"), (name: "s", value: "10"), (name: "nextParams", value: ""), (name: "df", value: "d")]
        let html = try WebToolsSupport.makeSearchRequest(engine: .html, parameters: parameters(), formFields: fields, timeout: 5)
        #expect(html.httpMethod == "POST")
        #expect(html.url?.absoluteString == "https://html.duckduckgo.com/html/")
        #expect(bodyString(of: html) == "q=a+b%26c&s=10&nextParams=&df=d")
        #expect(html.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(html.value(forHTTPHeaderField: "User-Agent") == WebToolsSupport.userAgent)

        let lite = try WebToolsSupport.makeSearchRequest(engine: .lite, parameters: parameters(), formFields: fields, timeout: 5)
        #expect(lite.httpMethod == "POST")
        #expect(lite.url?.absoluteString == "https://lite.duckduckgo.com/lite/")
    }

    @Test
    func formEncodingKeepsUnreservedCharactersAndEncodesTheRest() {
        #expect(WebToolsSupport.formURLEncoded([]) == "")
        #expect(WebToolsSupport.formURLEncoded([(name: "k", value: "AZaz09-._~")]) == "k=AZaz09-._~")
        #expect(WebToolsSupport.formURLEncoded([(name: "a b", value: "x y")]) == "a+b=x+y")
        #expect(WebToolsSupport.formURLEncoded([(name: "q", value: "+&=%")]) == "q=%2B%26%3D%25")
        #expect(WebToolsSupport.formURLEncoded([(name: "q", value: "è日")]) == "q=%C3%A8%E6%97%A5")
    }

    @Test
    func nextPageFieldsCarryTimeRangeAndRegion() {
        let form = [(name: "q", value: "swift"), (name: "s", value: "10"), (name: "kl", value: "wt-wt")]
        #expect(pairs(WebToolsSupport.nextSearchPageFields(from: form, timeRange: nil, region: nil)) == ["q=swift", "s=10", "kl=wt-wt"])
        #expect(
            pairs(WebToolsSupport.nextSearchPageFields(from: form, timeRange: .month, region: "it-it"))
                == ["q=swift", "s=10", "kl=it-it", "df=m"]
        )
        let withDF = form + [(name: "df", value: "d")]
        #expect(pairs(WebToolsSupport.nextSearchPageFields(from: withDF, timeRange: .year, region: nil))?.last == "df=y")
    }

    @Test
    func searchToolAdvertisesTheNewInputsWithDescriptions() throws {
        let schema = try #require(
            try JSONSerialization.jsonObject(with: Data(WebSearchTool.inputSchema.utf8)) as? [String: Any]
        )
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        #expect(Set(properties.keys) == ["query", "limit", "domains", "timeRange", "region"])
        for (name, property) in properties {
            #expect((property["description"] as? String)?.isEmpty == false, "\(name) needs a description")
        }
        #expect(properties["timeRange"]?["enum"] as? [String] == ["day", "week", "month", "year"])
        #expect(schema["required"] as? [String] == ["query"])
    }
}

// MARK: - Merging, pagination and rendering

@Suite
struct WebSearchPaginationTests {
    private typealias Run = (result: Result<WebSearchOutcome, Error>, requests: [URLRequest])

    private func run(
        _ parameters: WebSearchParameters,
        deadline: ContinuousClock.Instant = ContinuousClock.now + WebToolsSupport.maxSearchDuration,
        responses: [WebSearchPageResponse]
    ) async -> Run {
        struct Unscripted: Error {}
        var requests: [URLRequest] = []
        let result: Result<WebSearchOutcome, Error>
        do {
            let outcome = try await WebToolsSupport.performDuckDuckGoSearch(parameters, timeout: 5, deadline: deadline) { request in
                let index = requests.count
                requests.append(request)
                guard index < responses.count else { throw Unscripted() }
                return responses[index]
            }
            result = .success(outcome)
        } catch {
            result = .failure(error)
        }
        return (result, requests)
    }

    private func ok(_ body: String) -> WebSearchPageResponse {
        WebSearchPageResponse(statusCode: 200, body: body)
    }

    private func botCheckResponse() -> WebSearchPageResponse {
        WebSearchPageResponse(statusCode: 202, body: SearchFixtures.anomalyPage)
    }

    @Test
    func mergeDeduplicatesByURLKeepsOrderAndRespectsTheLimit() {
        func result(_ url: String) -> WebSearchResult { WebSearchResult(title: url, url: url, snippet: "") }
        let first = [result("https://a.example/"), result("https://b.example/")]
        let second = [result("https://b.example/"), result("https://c.example/"), result("https://d.example/")]
        #expect(WebToolsSupport.mergeSearchResults(first, with: second, limit: 10).map(\.url) == [
            "https://a.example/", "https://b.example/", "https://c.example/", "https://d.example/"
        ])
        #expect(WebToolsSupport.mergeSearchResults(first, with: second, limit: 3).map(\.url) == [
            "https://a.example/", "https://b.example/", "https://c.example/"
        ])
        #expect(WebToolsSupport.mergeSearchResults([], with: [first[0], first[0]], limit: 5).count == 1)
    }

    @Test
    func enoughResultsOnTheFirstPageMeansASingleRequest() async throws {
        let page = SearchFixtures.htmlPage(["https://a.example/", "https://b.example/", "https://c.example/"], nextOffset: 10)
        let run = await run(parameters(limit: 2), responses: [ok(page)])
        let outcome = try run.result.get()
        #expect(outcome.results.map(\.url) == ["https://a.example/", "https://b.example/"])
        #expect(outcome.pages == 1)
        #expect(outcome.note == nil)
        #expect(run.requests.count == 1)
        #expect(run.requests[0].httpMethod == "GET")
    }

    @Test
    func secondPageIsPostedWithTheFormFieldsAndResultsAreDeduplicated() async throws {
        let page1 = SearchFixtures.htmlPage(["https://a.example/", "https://b.example/"], nextOffset: 10)
        let page2 = SearchFixtures.htmlPage(["https://b.example/", "https://c.example/", "https://d.example/"])
        let run = await run(
            parameters(limit: 10, timeRange: .week, region: "it-it"),
            responses: [ok(page1), ok(page2)]
        )
        let outcome = try run.result.get()
        #expect(outcome.results.map(\.url) == ["https://a.example/", "https://b.example/", "https://c.example/", "https://d.example/"])
        #expect(outcome.pages == 2)
        #expect(outcome.engine == .html)
        #expect(run.requests.count == 2)

        #expect(run.requests[0].httpMethod == "GET")
        #expect(run.requests[0].url?.absoluteString == "https://html.duckduckgo.com/html/?q=swift&kl=it-it&df=w")
        #expect(run.requests[1].httpMethod == "POST")
        #expect(run.requests[1].url?.absoluteString == "https://html.duckduckgo.com/html/")
        #expect(bodyString(of: run.requests[1]) == "q=swift&s=10&vqd=4-123&kl=it-it&df=w")
    }

    @Test
    func paginationStopsAtThreePages() async throws {
        let pages = (0..<5).map { index in
            ok(SearchFixtures.htmlPage(["https://p\(index).example/"], nextOffset: (index + 1) * 10))
        }
        let run = await run(parameters(limit: 30), responses: pages)
        let outcome = try run.result.get()
        #expect(run.requests.count == 3)
        #expect(outcome.pages == 3)
        #expect(outcome.results.count == 3)
        #expect(run.requests.map { $0.httpMethod ?? "" } == ["GET", "POST", "POST"])
        #expect(bodyString(of: run.requests[2]).contains("s=20"))
    }

    @Test
    func paginationStopsWhenThereIsNoNextForm() async throws {
        let run = await run(parameters(limit: 30), responses: [ok(SearchFixtures.htmlPage(["https://a.example/"]))])
        let outcome = try run.result.get()
        #expect(run.requests.count == 1)
        #expect(outcome.pages == 1)
        #expect(outcome.results.count == 1)
    }

    @Test
    func domainFilterAppliesToEveryPage() async throws {
        let page1 = SearchFixtures.htmlPage(["https://docs.swift.org/a", "https://other.example/b"], nextOffset: 10)
        let page2 = SearchFixtures.htmlPage(["https://swift.org/c", "https://another.example/d"])
        let run = await run(
            parameters("swift site:swift.org", limit: 10, domains: ["swift.org"]),
            responses: [ok(page1), ok(page2)]
        )
        let outcome = try run.result.get()
        #expect(outcome.results.map(\.url) == ["https://docs.swift.org/a", "https://swift.org/c"])
    }

    @Test
    func botCheckOnTheHTMLEndpointFallsBackToLite() async throws {
        let lite1 = SearchFixtures.litePage(["https://a.example/"], nextOffset: 10)
        let lite2 = SearchFixtures.litePage(["https://b.example/"])
        let run = await run(parameters(limit: 10), responses: [botCheckResponse(), ok(lite1), ok(lite2)])
        let outcome = try run.result.get()
        #expect(outcome.results.map(\.url) == ["https://a.example/", "https://b.example/"])
        #expect(outcome.results.first?.snippet == "Lite snippet of https://a.example/")
        #expect(outcome.engine == .lite)
        #expect(outcome.pages == 2)
        #expect(run.requests.map { $0.url?.absoluteString } == [
            "https://html.duckduckgo.com/html/?q=swift&kl=wt-wt",
            "https://lite.duckduckgo.com/lite/?q=swift&kl=wt-wt",
            "https://lite.duckduckgo.com/lite/"
        ])
        #expect(run.requests.map { $0.httpMethod ?? "" } == ["GET", "GET", "POST"])
    }

    @Test
    func anomalyMarkupWithStatus200AlsoTriggersTheFallback() async throws {
        let run = await run(
            parameters(),
            responses: [ok(SearchFixtures.anomalyPage), ok(SearchFixtures.litePage(["https://a.example/"]))]
        )
        let outcome = try run.result.get()
        #expect(outcome.engine == .lite)
        #expect(outcome.results.map(\.url) == ["https://a.example/"])
    }

    @Test
    func botCheckOnBothEndpointsThrowsTheRateLimitError() async {
        let run = await run(parameters(), responses: [botCheckResponse(), botCheckResponse()])
        guard case let .failure(error) = run.result else {
            Issue.record("expected a failure")
            return
        }
        #expect(error as? WebSearchError == .botCheck)
        #expect(run.requests.count == 2)
        let message = error.localizedDescription.lowercased()
        #expect(message.contains("bot check"))
        #expect(message.contains("minute"))
    }

    @Test
    func botCheckOnALaterPageKeepsEarlierResultsAndSaysSo() async throws {
        let page1 = SearchFixtures.htmlPage(["https://a.example/"], nextOffset: 10)
        let run = await run(parameters(limit: 10), responses: [ok(page1), botCheckResponse(), botCheckResponse()])
        let outcome = try run.result.get()
        #expect(outcome.results.map(\.url) == ["https://a.example/"])
        #expect(outcome.pages == 1)
        #expect(outcome.engine == .html)
        #expect(outcome.note?.contains("bot check") == true)
        #expect(run.requests.count == 3)
    }

    @Test
    func botCheckOnALaterHTMLPageRestartsOnLiteWithAGetAndMergesBothEngines() async throws {
        let html1 = SearchFixtures.htmlPage(["https://a.example/", "https://b.example/"], nextOffset: 10)
        let lite1 = SearchFixtures.litePage(["https://b.example/", "https://c.example/"], nextOffset: 10)
        let lite2 = SearchFixtures.litePage(["https://c.example/", "https://d.example/"])
        let run = await run(
            parameters(limit: 10, timeRange: .week, region: "it-it"),
            responses: [ok(html1), botCheckResponse(), ok(lite1), ok(lite2)]
        )
        let outcome = try run.result.get()

        // Results of both engines, in order, without duplicates.
        #expect(outcome.results.map(\.url) == [
            "https://a.example/", "https://b.example/", "https://c.example/", "https://d.example/"
        ])
        #expect(outcome.results[0].snippet.hasPrefix("Snippet of "))
        #expect(outcome.results[2].snippet.hasPrefix("Lite snippet of "))
        #expect(outcome.engine == .lite)
        #expect(outcome.pages == 3)
        #expect(outcome.note == nil)

        #expect(run.requests.map { $0.httpMethod ?? "" } == ["GET", "POST", "GET", "POST"])
        #expect(run.requests.map { $0.url?.absoluteString } == [
            "https://html.duckduckgo.com/html/?q=swift&kl=it-it&df=w",
            "https://html.duckduckgo.com/html/",
            "https://lite.duckduckgo.com/lite/?q=swift&kl=it-it&df=w",
            "https://lite.duckduckgo.com/lite/"
        ])
        // The HTML form fields (the bot-checked POST) are never sent to Lite:
        // the restart is a plain GET and the next page uses Lite's own form.
        #expect(run.requests[2].httpBody == nil)
        #expect(bodyString(of: run.requests[1]) == "q=swift&s=10&vqd=4-123&kl=it-it&df=w")
        #expect(bodyString(of: run.requests[3]) == "q=swift&s=10&vqd=4-123&df=w&kl=it-it")
    }

    @Test
    func noPageBeyondTheFirstIsStartedAfterTheDeadline() async throws {
        let page1 = SearchFixtures.htmlPage(["https://a.example/"], nextOffset: 10)
        let page2 = SearchFixtures.htmlPage(["https://b.example/"])
        let expired = ContinuousClock.now - .seconds(1)
        let early = await run(parameters(limit: 10), deadline: expired, responses: [ok(page1), ok(page2)])
        let outcome = try early.result.get()

        // Page 1 is always attempted; the Next form is ignored once time is up.
        #expect(early.requests.count == 1)
        #expect(outcome.results.map(\.url) == ["https://a.example/"])
        #expect(outcome.pages == 1)
        #expect(outcome.note == "Stopped after 1 page(s): the time budget for the search was exhausted.")
        #expect(WebToolsSupport.renderSearchOutput(parameters: parameters(limit: 10), outcome: outcome)
            .contains("Note: Stopped after 1 page(s): the time budget for the search was exhausted."))

        // A deadline in the future changes nothing.
        let later = await run(
            parameters(limit: 10),
            deadline: ContinuousClock.now + .seconds(60),
            responses: [ok(page1), ok(page2)]
        )
        let full = try later.result.get()
        #expect(full.pages == 2 && full.note == nil && later.requests.count == 2)
        #expect(WebToolsSupport.maxSearchDuration == .seconds(45))
    }

    @Test
    func httpErrorOnTheFirstPageThrowsAndOnLaterPagesIsReportedAsANote() async throws {
        let failed = await run(parameters(), responses: [WebSearchPageResponse(statusCode: 503, body: "")])
        guard case let .failure(error) = failed.result else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.localizedDescription.contains("HTTP status 503"))

        let page1 = SearchFixtures.htmlPage(["https://a.example/"], nextOffset: 10)
        let partial = await run(parameters(), responses: [ok(page1), WebSearchPageResponse(statusCode: 500, body: "")])
        let outcome = try partial.result.get()
        #expect(outcome.results.count == 1)
        #expect(outcome.note?.contains("HTTP status 500") == true)
    }

    @Test
    func cancellationIsNeverSwallowed() async {
        let page1 = SearchFixtures.htmlPage(["https://a.example/"], nextOffset: 10)
        var calls = 0
        do {
            _ = try await WebToolsSupport.performDuckDuckGoSearch(parameters(), timeout: 5) { _ in
                calls += 1
                if calls == 2 { throw CancellationError() }
                return WebSearchPageResponse(statusCode: 200, body: page1)
            }
            Issue.record("expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }
}

@Suite
struct WebSearchRenderingTests {
    private func result(_ index: Int, snippet: String = "snippet") -> WebSearchResult {
        WebSearchResult(title: "Title \(index)", url: "https://example.com/\(index)", snippet: snippet)
    }

    @Test
    func summaryLineOmitsUnsetParts() {
        #expect(
            WebToolsSupport.searchSummaryLine(resultCount: 7, engine: .html, timeRange: .week, region: "it-it", pages: 2)
                == "Results: 7 (engine: DuckDuckGo, range: week, region: it-it, pages: 2)"
        )
        #expect(
            WebToolsSupport.searchSummaryLine(resultCount: 3, engine: .html, timeRange: nil, region: nil, pages: 1)
                == "Results: 3 (engine: DuckDuckGo, pages: 1)"
        )
        #expect(
            WebToolsSupport.searchSummaryLine(resultCount: 0, engine: .lite, timeRange: .year, region: nil, pages: 1)
                == "Results: 0 (engine: DuckDuckGo Lite, range: year, pages: 1)"
        )
        #expect(
            WebToolsSupport.searchSummaryLine(resultCount: 1, engine: .html, timeRange: nil, region: "wt-wt", pages: 3)
                == "Results: 1 (engine: DuckDuckGo, region: wt-wt, pages: 3)"
        )
    }

    @Test
    func outputStartsWithQueryAndSummaryThenNumberedResults() {
        let parameters = parameters(
            "swift testing (site:swift.org OR site:github.com)",
            domains: ["swift.org", "github.com"],
            timeRange: .week,
            region: "it-it"
        )
        let outcome = WebSearchOutcome(
            results: [result(1), result(2, snippet: "")],
            engine: .html,
            pages: 2,
            note: nil
        )
        let lines = WebToolsSupport.renderSearchOutput(parameters: parameters, outcome: outcome).components(separatedBy: "\n")
        #expect(lines == [
            "Query: swift testing (site:swift.org OR site:github.com)",
            "Results: 2 (engine: DuckDuckGo, range: week, region: it-it, pages: 2)",
            "",
            "1. Title 1",
            "   URL: https://example.com/1",
            "   Snippet: snippet",
            "",
            "2. Title 2",
            "   URL: https://example.com/2"
        ])
    }

    @Test
    func noteIsPlacedBelowTheSummary() {
        let outcome = WebSearchOutcome(results: [result(1)], engine: .html, pages: 1, note: "only one page")
        let lines = WebToolsSupport.renderSearchOutput(parameters: parameters(), outcome: outcome).components(separatedBy: "\n")
        #expect(lines[0] == "Query: swift")
        #expect(lines[1] == "Results: 1 (engine: DuckDuckGo, pages: 1)")
        #expect(lines[2] == "Note: only one page")
        #expect(lines[3] == "")
        #expect(lines[4] == "1. Title 1")
    }

    @Test
    func emptyResultsSuggestBroadeningTheSearch() {
        let outcome = WebSearchOutcome(results: [], engine: .html, pages: 1, note: nil)

        let plain = WebToolsSupport.renderSearchOutput(parameters: parameters("obscure"), outcome: outcome)
        #expect(plain == "Query: obscure\nResults: 0 (engine: DuckDuckGo, pages: 1)\nNo public web results found. Try broadening the query.")

        let filtered = WebToolsSupport.renderSearchOutput(
            parameters: parameters("obscure site:a.com", domains: ["a.com"], timeRange: .day),
            outcome: outcome
        )
        #expect(filtered.contains("No public web results found."))
        #expect(filtered.contains("broadening the query, removing the domain filter, or widening or removing timeRange"))
        #expect(filtered.hasPrefix("Query: obscure site:a.com\nResults: 0 (engine: DuckDuckGo, range: day, pages: 1)\n"))

        let domainOnly = WebToolsSupport.renderSearchOutput(
            parameters: parameters("obscure", domains: ["a.com"]),
            outcome: outcome
        )
        #expect(domainOnly.contains("broadening the query or removing the domain filter."))
    }
}
