import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct WebSearchResult {
    let title: String
    let url: String
    let snippet: String
}

extension WebToolsSupport {
    static func normalizedDomains(from domains: [String]) -> [String] {
        domains
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
            .filter { !$0.isEmpty }
    }

    static func parseDuckDuckGoHTMLResults(_ html: String, limit: Int, domains: [String]) -> [WebSearchResult] {
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
            guard !title.isEmpty else { continue }

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
                WebSearchResult(title: title, url: resultURL.absoluteString, snippet: snippet)
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
        guard let url = URL(string: normalizedHref) else { return nil }
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
        guard !domains.isEmpty else { return true }
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
