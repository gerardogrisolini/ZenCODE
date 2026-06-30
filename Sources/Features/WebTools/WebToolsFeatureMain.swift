//
//  WebToolsFeatureMain.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
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
    static let inputSchema = #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"number"},"domains":{"type":"array","items":{"type":"string"}}},"required":["query"]}"#

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

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("ZenCODE/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
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
    static let description = "Fetches an HTTP or HTTPS URL and returns response metadata plus a UTF-8 text preview."
    static let inputSchema = #"{"type":"object","properties":{"url":{"type":"string"},"maxBytes":{"type":"number"},"timeoutSeconds":{"type":"number"}},"required":["url"]}"#

    func run(_ input: Input, context _: FeatureContext) async throws -> String {
        guard let rawURL = input.url?.nilIfBlank,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw WebToolsFeatureError.missingArgument("url")
        }

        let maxBytes = max(1_024, min(input.maxBytes ?? 120_000, 1_000_000))
        let timeout = TimeInterval(max(1, min(input.timeoutSeconds ?? 20, 120)))
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("ZenCODE/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        try WebToolsSupport.validateHTTPResponse(response)
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
        bytes: \(data.count)

        \(body)\(truncatedSuffix)
        """
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

private enum WebToolsFeatureError: LocalizedError {
    case missingArgument(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(argument):
            return "Missing required argument: \(argument)"
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
