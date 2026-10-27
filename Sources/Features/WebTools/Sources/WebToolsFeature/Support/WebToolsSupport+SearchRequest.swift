import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Time filter accepted by `web.search`; `dfValue` is DuckDuckGo's `df` parameter.
enum WebSearchTimeRange: String, CaseIterable, Sendable {
    case day
    case week
    case month
    case year

    var dfValue: String {
        switch self {
        case .day: "d"
        case .week: "w"
        case .month: "m"
        case .year: "y"
        }
    }

    /// Parses the tool argument. A missing or blank value means "no filter";
    /// anything that is not one of the four names is an error.
    static func parse(_ raw: String?) throws -> WebSearchTimeRange? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard let value = WebSearchTimeRange(rawValue: trimmed.lowercased()) else {
            throw WebSearchError.invalidTimeRange(trimmed)
        }
        return value
    }
}

/// The two DuckDuckGo front-ends that return plain HTML results.
enum WebSearchEngine: Sendable, Equatable {
    case html
    case lite

    var endpoint: String {
        switch self {
        case .html: "https://html.duckduckgo.com/html/"
        case .lite: "https://lite.duckduckgo.com/lite/"
        }
    }

    var displayName: String {
        switch self {
        case .html: "DuckDuckGo"
        case .lite: "DuckDuckGo Lite"
        }
    }
}

enum WebSearchError: LocalizedError, Equatable {
    case invalidTimeRange(String)
    case invalidRegion(String)
    case botCheck
    case requestBuildFailed

    var errorDescription: String? {
        switch self {
        case let .invalidTimeRange(value):
            return "Invalid timeRange '\(value)'. Use one of: day, week, month, year."
        case let .invalidRegion(value):
            return "Invalid region '\(value)'. Use a DuckDuckGo region code made of two letters, a hyphen and two letters, such as us-en, it-it or wt-wt."
        case .botCheck:
            return "DuckDuckGo requested a bot check (rate limit) and the search could not be completed. "
                + "Wait about a minute before searching again, and narrow the query (fewer terms, a specific domain, or a smaller limit) to send fewer requests."
        case .requestBuildFailed:
            return "Unable to build the web search request."
        }
    }
}

/// Everything that identifies one search; `query` is the text sent to the
/// engine (including `site:` terms).
struct WebSearchParameters: Sendable {
    let query: String
    let limit: Int
    let domains: [String]
    let timeRange: WebSearchTimeRange?
    let region: String?
}

/// One fetched search page, reduced to what pagination needs.
struct WebSearchPageResponse: Sendable {
    let statusCode: Int
    let body: String
}

struct WebSearchOutcome: Sendable {
    let results: [WebSearchResult]
    /// The engine that served the last page that was used.
    let engine: WebSearchEngine
    let pages: Int
    /// Set when pagination stopped early but earlier pages produced results.
    let note: String?
}

extension WebToolsSupport {
    static let defaultSearchLimit = 5
    static let maxSearchLimit = 30
    /// Page fetches per search (the first page plus at most two Next pages).
    static let maxSearchPages = 3
    /// Overall budget after which no further page is started.
    static let maxSearchDuration: Duration = .seconds(45)

    static func clampedSearchLimit(_ requested: Int?) -> Int {
        max(1, min(requested ?? defaultSearchLimit, maxSearchLimit))
    }

    /// Lowercases and validates a `kl` region code (`it-it`, `us-en`, `wt-wt`).
    /// A missing or blank value means "no region".
    static func normalizedSearchRegion(_ raw: String?) throws -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let value = trimmed.lowercased()
        guard value.range(of: #"^[a-z]{2}-[a-z]{2}$"#, options: .regularExpression) != nil else {
            throw WebSearchError.invalidRegion(trimmed)
        }
        return value
    }

    /// The query as sent to the engine: the user's text followed by a
    /// `site:` restriction for the domains, `site:a.com` for one and
    /// `(site:a.com OR site:b.com)` for several. Entries that would break out
    /// of the operator (whitespace, quotes, parentheses) are not turned into
    /// `site:` terms; the host post-filter still applies to them.
    static func searchQuery(_ query: String, domains: [String]) -> String {
        var seen = Set<String>()
        let terms = domains.compactMap { domain -> String? in
            guard seen.insert(domain).inserted,
                  !domain.contains(where: { $0.isWhitespace || "()\"'".contains($0) }) else {
                return nil
            }
            return "site:\(domain)"
        }
        switch terms.count {
        case 0: return query
        case 1: return "\(query) \(terms[0])"
        default: return "\(query) (\(terms.joined(separator: " OR ")))"
        }
    }

    /// `application/x-www-form-urlencoded` encoding: unreserved characters
    /// stay, space becomes `+`, every other byte is percent-encoded.
    static func formURLEncoded(_ fields: [(name: String, value: String)]) -> String {
        fields.map { "\(formEncode($0.name))=\(formEncode($0.value))" }.joined(separator: "&")
    }

    private static func formEncode(_ text: String) -> String {
        let hex = Array("0123456789ABCDEF")
        var encoded = ""
        for byte in text.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            case 0x20:
                encoded.append("+")
            default:
                encoded.append("%")
                encoded.append(hex[Int(byte >> 4)])
                encoded.append(hex[Int(byte & 0x0F)])
            }
        }
        return encoded
    }

    /// First page: GET with `q`, `kl` (default worldwide) and optional `df`.
    /// Later pages: POST of the form fields scraped from the previous page.
    static func makeSearchRequest(
        engine: WebSearchEngine,
        parameters: WebSearchParameters,
        formFields: [(name: String, value: String)]?,
        timeout: TimeInterval
    ) throws -> URLRequest {
        if let formFields {
            guard let url = URL(string: engine.endpoint) else { throw WebSearchError.requestBuildFailed }
            return makeFormPostRequest(url: url, fields: formFields, timeout: timeout)
        }
        var items: [(name: String, value: String)] = [
            (name: "q", value: parameters.query),
            (name: "kl", value: parameters.region ?? "wt-wt")
        ]
        if let timeRange = parameters.timeRange {
            items.append((name: "df", value: timeRange.dfValue))
        }
        guard let url = URL(string: "\(engine.endpoint)?\(formURLEncoded(items))") else {
            throw WebSearchError.requestBuildFailed
        }
        return makeRequest(url: url, timeout: timeout)
    }

    /// The Next form's fields with the user's time range and region carried
    /// over (the engine normally echoes them, this makes it certain).
    static func nextSearchPageFields(
        from form: [(name: String, value: String)],
        timeRange: WebSearchTimeRange?,
        region: String?
    ) -> [(name: String, value: String)] {
        var fields = form
        func set(_ name: String, to value: String) {
            if let index = fields.firstIndex(where: { $0.name == name }) {
                fields[index].value = value
            } else {
                fields.append((name: name, value: value))
            }
        }
        if let timeRange { set("df", to: timeRange.dfValue) }
        if let region { set("kl", to: region) }
        return fields
    }

    /// DuckDuckGo answers an automated-looking client with HTTP 202 and a
    /// challenge page (`anomaly-modal`) instead of results.
    static func isSearchBotCheck(statusCode: Int, body: String) -> Bool {
        statusCode == 202 || body.contains("anomaly-modal")
    }

    /// Appends `new` to `existing`, skipping URLs already present, and keeps
    /// at most `limit` results in engine order.
    static func mergeSearchResults(_ existing: [WebSearchResult], with new: [WebSearchResult], limit: Int) -> [WebSearchResult] {
        var merged = existing
        var seen = Set(existing.map(\.url))
        for result in new where merged.count < limit {
            if seen.insert(result.url).inserted {
                merged.append(result)
            }
        }
        return merged
    }

    /// Runs a search: page 1 by GET, then, while fewer than `limit` results
    /// are collected and the page offers a Next form, up to
    /// ``maxSearchPages`` pages in total by POSTing that form. No further page
    /// is started once `deadline` has passed (page 1 is always attempted); the
    /// results so far are returned with a note. A bot check on the HTML
    /// endpoint is retried once on the Lite endpoint, which then serves the
    /// remaining pages: on page 1 by the same GET, on a later page by
    /// restarting from Lite's first page (the HTML form fields do not belong
    /// to Lite; the merge drops results already collected). A bot check there
    /// too throws ``WebSearchError/botCheck`` when nothing was collected yet.
    /// A failure on a later page keeps the results already collected and says
    /// so in ``WebSearchOutcome/note``.
    ///
    /// `fetch` performs one request; keeping it a parameter makes the paging
    /// logic testable without a network.
    static func performDuckDuckGoSearch(
        _ parameters: WebSearchParameters,
        timeout: TimeInterval,
        deadline: ContinuousClock.Instant = ContinuousClock.now + maxSearchDuration,
        fetch: (URLRequest) async throws -> WebSearchPageResponse
    ) async throws -> WebSearchOutcome {
        var engine = WebSearchEngine.html
        var results: [WebSearchResult] = []
        var pages = 0
        var note: String?
        var formFields: [(name: String, value: String)]?

        while true {
            if pages > 0, ContinuousClock.now >= deadline {
                note = "Stopped after \(pages) page(s): the time budget for the search was exhausted."
                break
            }
            let body: String
            var pageEngine = engine
            do {
                try Task.checkCancellation()
                var response = try await fetch(makeSearchRequest(
                    engine: pageEngine, parameters: parameters, formFields: formFields, timeout: timeout
                ))
                if isSearchBotCheck(statusCode: response.statusCode, body: response.body), pageEngine == .html {
                    pageEngine = .lite
                    // The HTML form fields are not Lite's: start over from its
                    // first page; mergeSearchResults drops what was collected.
                    formFields = nil
                    response = try await fetch(makeSearchRequest(
                        engine: pageEngine, parameters: parameters, formFields: nil, timeout: timeout
                    ))
                }
                if isSearchBotCheck(statusCode: response.statusCode, body: response.body) {
                    throw WebSearchError.botCheck
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw WebToolsFeatureError.permissionDenied(
                        "The web request failed with HTTP status \(response.statusCode)."
                    )
                }
                body = response.body
            } catch let error as CancellationError {
                throw error
            } catch {
                guard pages > 0 else { throw error }
                if let searchError = error as? WebSearchError, searchError == .botCheck {
                    note = "DuckDuckGo requested a bot check, so only \(pages) result page(s) were loaded."
                } else {
                    note = "Loading more results failed after \(pages) page(s): \(error.localizedDescription)"
                }
                break
            }

            engine = pageEngine
            pages += 1
            let pageResults = engine == .html
                ? parseDuckDuckGoHTMLResults(body, limit: .max, domains: parameters.domains)
                : parseDuckDuckGoLiteResults(body, limit: .max, domains: parameters.domains)
            results = mergeSearchResults(results, with: pageResults, limit: parameters.limit)

            guard results.count < parameters.limit,
                  pages < maxSearchPages,
                  let form = parseDuckDuckGoNextForm(body) else {
                break
            }
            formFields = nextSearchPageFields(from: form, timeRange: parameters.timeRange, region: parameters.region)
        }
        return WebSearchOutcome(results: results, engine: engine, pages: pages, note: note)
    }

    // MARK: Rendering

    /// `Results: 7 (engine: DuckDuckGo, range: week, region: it-it, pages: 2)`;
    /// range and region are left out when they were not requested.
    static func searchSummaryLine(
        resultCount: Int,
        engine: WebSearchEngine,
        timeRange: WebSearchTimeRange?,
        region: String?,
        pages: Int
    ) -> String {
        var details = ["engine: \(engine.displayName)"]
        if let timeRange { details.append("range: \(timeRange.rawValue)") }
        if let region { details.append("region: \(region)") }
        details.append("pages: \(pages)")
        return "Results: \(resultCount) (\(details.joined(separator: ", ")))"
    }

    /// The text returned to the model: query as sent, summary line, an
    /// optional note, then the numbered results (or a hint when empty).
    static func renderSearchOutput(parameters: WebSearchParameters, outcome: WebSearchOutcome) -> String {
        var lines = [
            "Query: \(parameters.query)",
            searchSummaryLine(
                resultCount: outcome.results.count,
                engine: outcome.engine,
                timeRange: parameters.timeRange,
                region: parameters.region,
                pages: outcome.pages
            )
        ]
        if let note = outcome.note {
            lines.append("Note: \(note)")
        }
        guard !outcome.results.isEmpty else {
            var suggestions = ["broadening the query"]
            if !parameters.domains.isEmpty { suggestions.append("removing the domain filter") }
            if parameters.timeRange != nil { suggestions.append("widening or removing timeRange") }
            lines.append("No public web results found. Try \(naturalList(suggestions)).")
            return lines.joined(separator: "\n")
        }

        let rendered = outcome.results.enumerated().map { index, result in
            var entry = [
                "\(index + 1). \(result.title)",
                "   URL: \(result.url)"
            ]
            if !result.snippet.isEmpty {
                entry.append("   Snippet: \(result.snippet)")
            }
            return entry.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return lines.joined(separator: "\n") + "\n\n" + rendered
    }

    private static func naturalList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) or \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", or " + items[items.count - 1]
        }
    }
}
