//
//  WebToolsFeatureMain.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import ToolCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(WebKit)
import WebKit
#endif
import FeatureKit

struct WebSearchTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let query: String?
        let limit: Int?
        let domains: [String]?
    }

    static let name = "web.search"
    static let description = "Searches the public web and returns matching results with titles, URLs, and snippets."
    static let inputSchema = buildInputSchema(
        [.string("query"), .number("limit"), .array("domains")],
        required: ["query"]
    )

    func run(_ input: Input, context _: FeatureContext) async throws -> String {
        guard let query = input.query?.nilIfBlank else {
            throw WebToolsFeatureError.missingArgument("query")
        }

        let limit = max(1, min(input.limit ?? 5, 10))
        let domains = WebToolsSupport.normalizedDomains(from: input.domains ?? [])
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "kl", value: "wt-wt")
        ]
        guard let url = components.url else {
            throw WebToolsFeatureError.permissionDenied("Unable to build the web search request.")
        }

        let (data, response) = try await WebToolsSupport.fetchWithRetry(url: url)
        try WebToolsSupport.validateHTTPResponse(response)

        let html = String(decoding: data, as: UTF8.self)
        let results = WebToolsSupport.parseDuckDuckGoHTMLResults(
            html,
            limit: limit,
            domains: domains
        )
        guard !results.isEmpty else {
            return "Query: \(query)\nNo public web results found."
        }

        let renderedResults = results.enumerated().map { index, result in
            var lines = [
                "\(index + 1). \(result.title)",
                "   URL: \(result.url)"
            ]
            if !result.snippet.isEmpty {
                lines.append("   Snippet: \(result.snippet)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")

        return "Query: \(query)\n\(renderedResults)"
    }
}

struct WebFetchTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let url: String?
        let maxBytes: Int?
        let timeoutSeconds: Int?
    }

    static let name = "web.fetch"
    static let description = "Opens an HTTP or HTTPS URL. On Apple platforms it renders the page in a silent in-process WebKit view (JavaScript executed) and returns extracted Markdown; on other platforms it falls back to a raw HTTP fetch preview."
    static let inputSchema = buildInputSchema(
        [.string("url"), .number("maxBytes"), .number("timeoutSeconds")],
        required: ["url"]
    )

    func run(_ input: Input, context _: FeatureContext) async throws -> String {
        guard let rawURL = input.url?.nilIfBlank else {
            throw WebToolsFeatureError.missingArgument("url")
        }
        guard let url = URL(string: rawURL) else {
            throw WebToolsFeatureError.invalidURL(rawURL)
        }
        let scheme = url.scheme?.lowercased()
        guard let scheme, ["http", "https"].contains(scheme) else {
            throw WebToolsFeatureError.unsupportedScheme(scheme ?? "(none)")
        }

        let maxBytes = max(1_024, min(input.maxBytes ?? 120_000, 1_000_000))
        let timeout = TimeInterval(max(1, min(input.timeoutSeconds ?? 20, 120)))

        #if canImport(WebKit)
        let page = try await WebKitPageRenderer.render(url: url, timeout: timeout)
        let markdown = String(page.markdown.prefix(maxBytes))
        let truncatedSuffix = page.markdown.utf8.count > markdown.utf8.count
            ? "\n\n<truncated: \(page.markdown.utf8.count - markdown.utf8.count) bytes omitted>"
            : ""
        return """
        url: \(page.finalURL)
        title: \(page.title)
        engine: WebKit (rendered, JavaScript executed)

        \(markdown)\(truncatedSuffix)
        """
        #else
        return try await WebToolsSupport.rawFetchPreview(
            url: url,
            maxBytes: maxBytes,
            timeout: timeout
        )
        #endif
    }
}

@main
struct WebToolsFeatureMain {
    static func main() async {
        await FeatureRunner.run([
            AnyFeatureTool(WebSearchTool()),
            AnyFeatureTool(WebFetchTool())
        ])
    }
}

// MARK: - WebKit rendering (Apple platforms only)

#if canImport(WebKit)

struct RenderedPage: Sendable {
    let finalURL: String
    let title: String
    let markdown: String
}

@MainActor
final class WebKitPageRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var didResume = false
    private var timeoutTask: Task<Void, Never>?

    private override init() {
        let configuration = WKWebViewConfiguration()
        self.webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1365, height: 900),
            configuration: configuration
        )
        super.init()
        self.webView.navigationDelegate = self
        self.webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) ZenCODE/1.0"
    }

    static func render(url: URL, timeout: TimeInterval) async throws -> RenderedPage {
        let renderer = WebKitPageRenderer()
        return try await renderer.load(url: url, timeout: timeout)
    }

    private func load(url: URL, timeout: TimeInterval) async throws -> RenderedPage {
        // Split the budget so a slow navigation doesn't starve JS settle.
        let navigationBudget = timeout * 0.6
        let settleBudget = min(timeout - navigationBudget, 6)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.loadContinuation = continuation
            self.didResume = false
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(navigationBudget * 1_000_000_000))
                self?.resume(.failure(WebToolsFeatureError.permissionDenied(
                    "Timed out loading the page after \(Int(navigationBudget))s."
                )))
            }
            self.webView.load(URLRequest(url: url))
        }

        // Wait for client-side scripts to settle instead of a fixed delay:
        // poll until the document is ready and the rendered text length is
        // stable, bounded by the remaining settle budget.
        await waitUntilSettled(timeout: settleBudget)

        let title = (try? await evaluateString("document.title")) ?? ""
        let finalURL = (try? await evaluateString("location.href")) ?? url.absoluteString
        let markdown = try await evaluateString(WebKitPageRenderer.extractionJS)
        return RenderedPage(finalURL: finalURL, title: title, markdown: markdown)
    }

    /// Polls the page until it reports a ready state and the rendered text
    /// length stops growing, so dynamically injected content is captured.
    /// Bounded by `timeout` (shared with the navigation budget).
    private func waitUntilSettled(timeout: TimeInterval) async {
        // Cap the settle wait so pages that mutate continuously (clocks,
        // animations) can't stall extraction for the full navigation budget.
        let start = Date()
        let deadline = start.addingTimeInterval(min(timeout, 6))
        let pollInterval: UInt64 = 200_000_000 // 200 ms
        // Always observe the page for at least this long before trusting a
        // stable measurement, so short delayed injections are still captured.
        let minSettle: TimeInterval = 0.8
        let requiredStableChecks = 2
        var lastLength = -1
        var stableChecks = 0

        // Minimal settle so very fast client scripts run at least once.
        try? await Task.sleep(nanoseconds: pollInterval)

        while Date() < deadline {
            let ready = (try? await evaluateString("document.readyState")) ?? ""
            let lengthString = (try? await evaluateString(
                "String(((document.body && document.body.innerText) || '').length)"
            )) ?? "0"
            let length = Int(lengthString) ?? 0
            let isReady = ready == "complete" || ready == "interactive"

            if isReady, length > 0, length == lastLength {
                stableChecks += 1
                if stableChecks >= requiredStableChecks,
                   Date().timeIntervalSince(start) >= minSettle {
                    return
                }
            } else {
                stableChecks = 0
            }
            lastLength = length
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private func resume(_ result: Result<Void, Error>) {
        guard !didResume else { return }
        didResume = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = loadContinuation
        loadContinuation = nil
        switch result {
        case .success:
            continuation?.resume()
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }

    private func evaluateString(_ javaScript: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(javaScript) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let string = value as? String {
                    continuation.resume(returning: string)
                } else if let value {
                    continuation.resume(returning: String(describing: value))
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resume(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resume(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resume(.failure(error))
    }

    // Extract a compact Markdown snapshot of the rendered DOM.
    static let extractionJS = #"""
    (() => {
      const clean = s => (s || '').replace(/\s+/g, ' ').trim();
      const visible = el => {
        const r = el.getBoundingClientRect();
        const st = getComputedStyle(el);
        return r.width > 0 && r.height > 0 &&
          st.display !== 'none' && st.visibility !== 'hidden' && st.opacity !== '0';
      };
      const lines = [
        '# ' + (clean(document.title) || location.href),
        '',
        'URL: ' + location.href,
        '',
        '## Content'
      ];
      const blocks = [...document.body.querySelectorAll(
        'h1,h2,h3,h4,h5,h6,p,li,pre,blockquote,td,th'
      )];
      const seen = new Set();
      for (const el of blocks) {
        if (!visible(el)) continue;
        const tag = el.tagName;
        let s = '';
        if (/^H[1-6]$/.test(tag)) s = '#'.repeat(Number(tag[1])) + ' ' + clean(el.innerText);
        else if (tag === 'LI') s = '- ' + clean(el.innerText);
        else if (tag === 'PRE') s = '```\n' + (el.innerText || '').replace(/\s+$/, '') + '\n```';
        else if (tag === 'BLOCKQUOTE') s = '> ' + clean(el.innerText);
        else s = clean(el.innerText);
        s = s.trim();
        if (!s || seen.has(s)) continue;
        seen.add(s);
        lines.push('', s);
        if (lines.join('\n').length > 400000) { lines.push('', '[Content truncated by extractor.]'); break; }
      }
      lines.push('', '## Visible links');
      let n = 0;
      const linkSeen = new Set();
      for (const a of document.querySelectorAll('a[href]')) {
        if (!visible(a)) continue;
        const text = clean(a.innerText || a.textContent);
        if (text.length < 3) continue;
        let u;
        try { u = new URL(a.href); } catch (e) { continue; }
        if (!/^https?:$/.test(u.protocol) || linkSeen.has(u.href)) continue;
        linkSeen.add(u.href);
        lines.push('- [' + text.slice(0, 160) + '](' + u.href + ')');
        if (++n >= 80) break;
      }
      return lines.join('\n');
    })()
    """#
}

#endif

private enum WebToolsFeatureError: LocalizedError {
    case missingArgument(String)
    case invalidURL(String)
    case unsupportedScheme(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(argument):
            return "Missing required argument: \(argument)"
        case let .invalidURL(value):
            return "Invalid URL: \(value)"
        case let .unsupportedScheme(scheme):
            return "Unsupported URL scheme '\(scheme)'. Only http and https are supported."
        case let .permissionDenied(message):
            return message
        }
    }
}

private struct WebSearchResult {
    let title: String
    let url: String
    let snippet: String
}

private enum WebToolsSupport {
    static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebToolsFeatureError.permissionDenied("The web response was not an HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WebToolsFeatureError.permissionDenied("The web request failed with HTTP status \(httpResponse.statusCode).")
        }
    }

    /// Fetches a URL with retry on transient failures (429, 5xx, network
    /// errors). Backs off exponentially before each retry.
    static func fetchWithRetry(
        url: URL,
        maxAttempts: Int = 3,
        timeout: TimeInterval = 20
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("ZenCODE/1.0", forHTTPHeaderField: "User-Agent")

        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse,
                   http.statusCode == 429 || (500..<600).contains(http.statusCode) {
                    lastError = WebToolsFeatureError.permissionDenied(
                        "The web request failed with HTTP status \(http.statusCode)."
                    )
                    if attempt < maxAttempts - 1 {
                        let backoff = UInt64(pow(2.0, Double(attempt))) * 500_000_000
                        try? await Task.sleep(nanoseconds: backoff)
                        continue
                    }
                }
                return (data, response)
            } catch {
                lastError = error
                if attempt < maxAttempts - 1 {
                    let backoff = UInt64(pow(2.0, Double(attempt))) * 500_000_000
                    try? await Task.sleep(nanoseconds: backoff)
                    continue
                }
            }
        }
        throw lastError ?? WebToolsFeatureError.permissionDenied("The web request failed after \(maxAttempts) attempts.")
    }

    /// Raw HTTP fetch used as the non-Apple fallback for `web.fetch`.
    static func rawFetchPreview(
        url: URL,
        maxBytes: Int,
        timeout: TimeInterval
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("ZenCODE/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        try validateHTTPResponse(response)
        let bodyData = Data(data.prefix(maxBytes))
        let body = String(data: bodyData, encoding: .utf8)
            ?? "<non-UTF-8 response body: \(bodyData.count) bytes>"
        let truncatedSuffix = data.count > bodyData.count
            ? "\n\n<truncated: \(data.count - bodyData.count) bytes omitted>"
            : ""

        return """
        url: \(response.url?.absoluteString ?? url.absoluteString)
        status: \(httpResponse?.statusCode ?? 0)
        content-type: \(httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "unknown")
        engine: URLSession (raw fetch)
        bytes: \(data.count)

        \(body)\(truncatedSuffix)
        """
    }

    static func normalizedDomains(from domains: [String]) -> [String] {
        domains
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
            .filter { !$0.isEmpty }
    }

    static func parseDuckDuckGoHTMLResults(
        _ html: String,
        limit: Int,
        domains: [String]
    ) -> [WebSearchResult] {
        let anchorPattern = #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<(?:a|div)[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</(?:a|div)>"#

        guard let anchorRegex = try? NSRegularExpression(
            pattern: anchorPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }
        let snippetRegex = try? NSRegularExpression(
            pattern: snippetPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = anchorRegex.matches(in: html, options: [], range: nsRange)
        var results: [WebSearchResult] = []
        for (index, match) in matches.enumerated() {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let resultURL = resolvedSearchResultURL(from: String(html[hrefRange])),
                  isAllowedSearchResultURL(resultURL, domains: domains) else {
                continue
            }

            let title = normalizeText(stripHTML(String(html[titleRange])))
            guard !title.isEmpty else {
                continue
            }

            let lowerBound = match.range.location + match.range.length
            let upperBound = index + 1 < matches.count ? matches[index + 1].range.location : nsRange.location + nsRange.length
            let searchRange = NSRange(location: lowerBound, length: max(upperBound - lowerBound, 0))
            let snippet: String
            if let snippetRegex,
               let snippetMatch = snippetRegex.firstMatch(in: html, options: [], range: searchRange),
               let snippetRange = Range(snippetMatch.range(at: 1), in: html) {
                snippet = normalizeText(stripHTML(String(html[snippetRange])))
            } else {
                snippet = ""
            }

            results.append(
                WebSearchResult(
                    title: title,
                    url: resultURL.absoluteString,
                    snippet: snippet
                )
            )
            if results.count >= limit {
                break
            }
        }
        return results
    }

    private static func resolvedSearchResultURL(from rawHref: String) -> URL? {
        let href = decodeHTMLEntities(rawHref)
        let normalizedHref = href.hasPrefix("//") ? "https:\(href)" : href
        guard let url = URL(string: normalizedHref) else {
            return nil
        }
        if let host = url.host?.lowercased(),
           host.contains("duckduckgo.com"),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let encodedTarget = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           let decodedTarget = encodedTarget.removingPercentEncoding,
           let targetURL = URL(string: decodedTarget) {
            return targetURL
        }
        return url
    }

    private static func isAllowedSearchResultURL(_ url: URL, domains: [String]) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return false
        }
        guard !domains.isEmpty else {
            return true
        }
        return domains.contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }

    private static func stripHTML(_ text: String) -> String {
        replacePattern(text, pattern: #"<[^>]+>"#, with: " ")
    }

    private static func normalizeText(_ text: String) -> String {
        decodeHTMLEntities(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacePattern(_ text: String, pattern: String, with replacement: String) -> String {
        (try? NSRegularExpression(pattern: pattern, options: []))?
            .stringByReplacingMatches(
                in: text,
                options: [],
                range: NSRange(text.startIndex..<text.endIndex, in: text),
                withTemplate: replacement
            ) ?? text
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var decoded = text
        let replacements = [
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&nbsp;": " "
        ]
        for (entity, replacement) in replacements {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }
        return decoded
    }
}
